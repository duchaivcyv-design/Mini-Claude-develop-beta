#import "ClaudeStream.h"
#import "Strings.h"
#import "AppSettings.h"
#import "ModelStore.h"

static NSString *const kClaudeMessagesURL = @"https://api.anthropic.com/v1/messages";
static NSString *const kAnthropicVersion = @"2023-06-01";

@interface ClaudeStream () <NSURLSessionDataDelegate>
@property (copy, nonatomic) NSString *key;
@property (copy, nonatomic) NSString *model;
@property (copy, nonatomic) NSArray *turns;
@property (copy, nonatomic) NSString *system;
@property (strong, nonatomic) NSURLSession *session;
@property (strong, nonatomic) NSURLSessionDataTask *task;
@property (strong, nonatomic) NSMutableData *buffer;       // unfinished SSE bytes (or the whole body in single-request mode)
@property (strong, nonatomic) NSMutableData *errorBody;    // body of a non-200 response
@property (assign, nonatomic) NSInteger status;
@property (assign, nonatomic) BOOL cancelled;
@property (assign, nonatomic) BOOL finished;
@property (assign, nonatomic) BOOL gotText;
@property (copy, nonatomic) NSString *stopReason;          // end_turn, max_tokens, refusal, ...
@property (copy, nonatomic) NSString *inStreamErrorType;   // an "error" event delivered inside a 200 stream
@property (copy, nonatomic) NSString *inStreamErrorMessage;
@end

@implementation ClaudeStream

- (instancetype)initWithKey:(NSString *)key model:(NSString *)model turns:(NSArray *)turns system:(NSString *)system {
    self = [super init];
    if (self) {
        _key = [key copy];
        _model = [model copy];
        _turns = [turns copy];
        _system = [system copy];
        _buffer = [NSMutableData data];
        _errorBody = [NSMutableData data];
        _useStreaming = YES;
    }
    return self;
}

#pragma mark - Request format

// Prefer the per-model cap returned by Anthropic's Models API; use a conservative fallback for older cached lists.
- (NSInteger)maxTokens {
    NSInteger requested = [AppSettings maxOutputTokens];
    NSInteger modelCap = [ModelStore maxOutputTokensForModelId:self.model provider:AIProviderClaude];
    if (modelCap <= 0) modelCap = [self.model hasPrefix:@"claude-3-"] ? 4096 : 8192;
    return MIN(requested, modelCap);
}

// Neutral turns -> Anthropic "messages": photos become image blocks, PDFs become document blocks.
+ (NSArray *)messagesFromTurns:(NSArray *)turns {
    NSMutableArray *messages = [NSMutableArray array];
    for (NSDictionary *turn in turns) {
        NSMutableArray *blocks = [NSMutableArray array];
        for (NSDictionary *part in turn[@"parts"]) {
            NSString *type = part[@"type"];
            if ([type isEqualToString:@"text"] && [part[@"text"] length] > 0) {
                [blocks addObject:@{ @"type": @"text", @"text": part[@"text"] }];
            } else if ([type isEqualToString:@"image"] && [part[@"data"] length] > 0) {
                [blocks addObject:@{ @"type": @"image",
                                     @"source": @{ @"type": @"base64", @"media_type": part[@"mime"] ?: @"image/jpeg", @"data": part[@"data"] } }];
            } else if ([type isEqualToString:@"pdf"] && [part[@"data"] length] > 0) {
                [blocks addObject:@{ @"type": @"document",
                                     @"source": @{ @"type": @"base64", @"media_type": @"application/pdf", @"data": part[@"data"] } }];
            }
        }
        if (blocks.count == 0) continue;
        [messages addObject:@{ @"role": [turn[@"role"] isEqualToString:@"assistant"] ? @"assistant" : @"user", @"content": blocks }];
    }
    return messages;
}

#pragma mark - Control

- (void)start {
    NSInteger maxTokens = [self maxTokens];
    NSMutableDictionary *payload = [@{ @"model": self.model ?: @"",
                                       @"max_tokens": @(maxTokens),
                                       @"messages": [ClaudeStream messagesFromTurns:self.turns] } mutableCopy];
    // Extended thinking is sent only to Claude model families that support it.
    NSString *lowerModel = self.model.lowercaseString;
    BOOL supportsThinking = [lowerModel containsString:@"claude-3-7"] ||
                            [lowerModel containsString:@"claude-sonnet-4"] ||
                            [lowerModel containsString:@"claude-opus-4"];
    if (supportsThinking) {
        AIReasoningLevel level = [AppSettings reasoningLevel];
        NSInteger requestedBudget = 4096;
        switch (level) {
            case AIReasoningLevelLow: requestedBudget = 1024; break;
            case AIReasoningLevelMedium: requestedBudget = 4096; break;
            case AIReasoningLevelHigh: requestedBudget = 8192; break;
            case AIReasoningLevelVeryHigh: requestedBudget = 16384; break;
            case AIReasoningLevelMax: requestedBudget = 24576; break;
        }
        NSInteger budget = MIN(requestedBudget, MAX(1024, maxTokens - 1024));
        payload[@"max_tokens"] = @(MAX(maxTokens, budget + 1024));
        payload[@"thinking"] = @{ @"type": @"enabled", @"budget_tokens": @(budget) };
    }
    if (self.useStreaming) payload[@"stream"] = @YES;
    if (self.system.length > 0) payload[@"system"] = self.system;
    NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];

    // Streaming: give up if nothing at all arrives for 45 s. Single request: the whole answer must arrive within 120 s.
    NSTimeInterval timeout = self.useStreaming ? 45 : 120;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kClaudeMessagesURL]
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:timeout];
    request.HTTPMethod = @"POST";
    request.HTTPBody = body;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:self.useStreaming ? @"text/event-stream" : @"application/json" forHTTPHeaderField:@"Accept"];
    if (self.useStreaming) [request setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
    [request setValue:self.key forHTTPHeaderField:@"x-api-key"];
    [request setValue:kAnthropicVersion forHTTPHeaderField:@"anthropic-version"];

    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    config.timeoutIntervalForRequest = timeout;
    config.timeoutIntervalForResource = 3600;
    self.session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:[NSOperationQueue mainQueue]];
    self.task = [self.session dataTaskWithRequest:request];
    [self.task resume];
}

- (void)cancel {
    if (self.finished) return;
    self.cancelled = YES;
    [self.task cancel];
}

#pragma mark - NSURLSessionDataDelegate

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    self.status = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    if (self.status != 200) {
        [self.errorBody appendData:data];
        return;
    }
    [self.buffer appendData:data];
    if (self.useStreaming) [self drainBufferFinal:NO];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (self.finished) return;
    self.finished = YES;
    [self.session finishTasksAndInvalidate];

    GeminiStreamError result = GeminiStreamErrorNone;
    NSString *detail = nil;

    if (self.cancelled) {
        result = GeminiStreamErrorCancelled;
    } else if (error != nil) {
        result = GeminiStreamErrorNetwork;
        detail = [NSString stringWithFormat:@"%@ [%@ %ld]", error.localizedDescription, error.domain, (long)error.code];
    } else if (self.status != 200) {
        NSString *type = nil, *message = nil;
        [self readErrorBody:self.errorBody type:&type message:&message];
        detail = message;
        result = [ClaudeStream errorForStatus:self.status type:type message:message];
    } else {
        if (self.useStreaming) [self drainBufferFinal:YES]; else [self processWholeBody];
        if (self.inStreamErrorType.length > 0 || self.inStreamErrorMessage.length > 0) {
            detail = self.inStreamErrorMessage;
            result = [ClaudeStream errorForStatus:0 type:self.inStreamErrorType message:self.inStreamErrorMessage];
        } else if (!self.gotText) {
            result = [self.stopReason isEqualToString:@"refusal"] ? GeminiStreamErrorBlocked : GeminiStreamErrorEmptyReply;
            detail = self.stopReason;
        } else if ([self.stopReason isEqualToString:@"max_tokens"] && self.onDelta) {
            self.onDelta([NSString stringWithFormat:@"\n\n%@", L(@"reply_truncated")]);
        }
    }

    void (^finish)(GeminiStreamError, NSInteger, NSString *) = self.onFinish;
    NSInteger status = self.status;
    self.onDelta = nil;
    self.onFinish = nil;
    if (finish) finish(result, status, detail);
}

#pragma mark - SSE parsing

- (void)drainBufferFinal:(BOOL)final {
    NSData *newline = [NSData dataWithBytes:"\n" length:1];
    while (YES) {
        NSRange range = [self.buffer rangeOfData:newline options:0 range:NSMakeRange(0, self.buffer.length)];
        if (range.location == NSNotFound) break;
        NSData *lineData = [self.buffer subdataWithRange:NSMakeRange(0, range.location)];
        [self.buffer replaceBytesInRange:NSMakeRange(0, range.location + 1) withBytes:NULL length:0];
        [self processLineData:lineData];
    }
    if (final && self.buffer.length > 0) {
        [self processLineData:[self.buffer copy]];
        self.buffer.length = 0;
    }
}

// Lines look like "event: content_block_delta" (ignored: the JSON carries the type) and "data: {...}".
- (void)processLineData:(NSData *)lineData {
    NSString *line = [[NSString alloc] initWithData:lineData encoding:NSUTF8StringEncoding];
    if (line == nil) return;
    line = [line stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\r"]];
    if (![line hasPrefix:@"data:"]) return;
    NSString *payload = [[line substringFromIndex:5] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (payload.length == 0) return;

    id json = [NSJSONSerialization JSONObjectWithData:[payload dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    if (![json isKindOfClass:[NSDictionary class]]) return;
    [self processEvent:json];
}

- (void)processEvent:(NSDictionary *)event {
    NSString *type = [event[@"type"] isKindOfClass:[NSString class]] ? event[@"type"] : @"";

    if ([type isEqualToString:@"content_block_delta"]) {
        NSDictionary *delta = [event[@"delta"] isKindOfClass:[NSDictionary class]] ? event[@"delta"] : nil;
        NSString *text = [delta[@"text"] isKindOfClass:[NSString class]] ? delta[@"text"] : nil;
        // Only plain text is shown (thinking deltas, tool JSON, etc. are not requested and would be ignored here).
        if ([delta[@"type"] isEqualToString:@"text_delta"] && text.length > 0) {
            self.gotText = YES;
            if (self.onDelta) self.onDelta(text);
        }
    } else if ([type isEqualToString:@"message_delta"]) {
        NSDictionary *delta = [event[@"delta"] isKindOfClass:[NSDictionary class]] ? event[@"delta"] : nil;
        if ([delta[@"stop_reason"] isKindOfClass:[NSString class]]) self.stopReason = delta[@"stop_reason"];
    } else if ([type isEqualToString:@"error"]) {
        // An error can arrive after the 200 response has started (for example overloaded_error).
        NSDictionary *err = [event[@"error"] isKindOfClass:[NSDictionary class]] ? event[@"error"] : nil;
        self.inStreamErrorType = [err[@"type"] isKindOfClass:[NSString class]] ? err[@"type"] : @"api_error";
        if ([err[@"message"] isKindOfClass:[NSString class]]) self.inStreamErrorMessage = err[@"message"];
    }
    // ping, message_start, content_block_start, content_block_stop, message_stop: nothing to do
}

// Single-request mode: the whole reply is one JSON object with a "content" array of blocks.
- (void)processWholeBody {
    if (self.buffer.length == 0) return;
    id json = [NSJSONSerialization JSONObjectWithData:self.buffer options:0 error:nil];
    if (![json isKindOfClass:[NSDictionary class]]) return;
    NSDictionary *root = json;
    if ([root[@"stop_reason"] isKindOfClass:[NSString class]]) self.stopReason = root[@"stop_reason"];
    if ([root[@"type"] isEqualToString:@"error"]) { [self processEvent:root]; return; }

    NSMutableString *all = [NSMutableString string];
    NSArray *blocks = [root[@"content"] isKindOfClass:[NSArray class]] ? root[@"content"] : @[];
    for (id block in blocks) {
        if (![block isKindOfClass:[NSDictionary class]] || ![block[@"type"] isEqualToString:@"text"]) continue;
        if ([block[@"text"] isKindOfClass:[NSString class]]) [all appendString:block[@"text"]];
    }
    if (all.length > 0) {
        self.gotText = YES;
        if (self.onDelta) self.onDelta(all);
    }
}

#pragma mark - Errors

- (void)readErrorBody:(NSData *)body type:(NSString **)type message:(NSString **)message {
    if (body.length == 0) return;
    id json = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
    if (![json isKindOfClass:[NSDictionary class]]) return;
    NSDictionary *err = [json[@"error"] isKindOfClass:[NSDictionary class]] ? json[@"error"] : nil;
    if ([err[@"type"] isKindOfClass:[NSString class]]) *type = err[@"type"];
    if ([err[@"message"] isKindOfClass:[NSString class]]) *message = err[@"message"];
}

// `status` is 0 for an error that arrived inside a stream: then only the error type is known.
+ (GeminiStreamError)errorForStatus:(NSInteger)status type:(NSString *)type message:(NSString *)message {
    NSString *lower = [message lowercaseString];
    // A key with no money left answers 400 invalid_request_error: say so instead of "unknown error".
    if (lower.length > 0 && [lower rangeOfString:@"credit balance"].location != NSNotFound) return GeminiStreamErrorNoCredit;

    if ([type isEqualToString:@"authentication_error"]) return GeminiStreamErrorInvalidKey;
    if ([type isEqualToString:@"permission_error"]) return GeminiStreamErrorPermissionDenied;
    if ([type isEqualToString:@"not_found_error"]) return GeminiStreamErrorModelNotFound;
    if ([type isEqualToString:@"rate_limit_error"]) return GeminiStreamErrorRateLimited;
    if ([type isEqualToString:@"request_too_large"]) return GeminiStreamErrorTooLarge;
    if ([type isEqualToString:@"overloaded_error"] || [type isEqualToString:@"api_error"]) return GeminiStreamErrorServer;

    if (status == 413) return GeminiStreamErrorTooLarge;
    if (status == 400) {
        if (lower.length > 0 && ([lower rangeOfString:@"too long"].location != NSNotFound ||
                                 [lower rangeOfString:@"too large"].location != NSNotFound ||
                                 [lower rangeOfString:@"exceeds"].location != NSNotFound)) {
            return GeminiStreamErrorTooLarge;
        }
        return GeminiStreamErrorUnknown;
    }
    if (status == 401) return GeminiStreamErrorInvalidKey;
    if (status == 403) return GeminiStreamErrorPermissionDenied;
    if (status == 404) return GeminiStreamErrorModelNotFound;
    if (status == 429) return GeminiStreamErrorRateLimited;
    if (status >= 500) return GeminiStreamErrorServer;   // includes 529 (overloaded)
    return GeminiStreamErrorUnknown;
}

@end
