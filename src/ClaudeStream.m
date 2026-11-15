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
@property (assign, nonatomic) long long inputTokenUsage;
@property (assign, nonatomic) long long outputTokenUsage;
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

- (NSInteger)maxTokens {
    NSInteger requested = [AppSettings maxOutputTokens];
    NSInteger modelCap = [ModelStore maxOutputTokensForModelId:self.model provider:AIProviderClaude];
    if (modelCap <= 0) modelCap = [self.model hasPrefix:@"claude-3-"] ? 4096 : 8192;
    return MIN(requested, modelCap);
}

+ (NSArray *)messagesFromTurns:(NSArray *)turns {
    if (![turns isKindOfClass:[NSArray class]]) return @[];
    NSMutableArray *messages = [NSMutableArray array];
    for (NSDictionary *turn in turns) {
        if (![turn isKindOfClass:[NSDictionary class]]) continue;
        NSArray *turnParts = turn[@"parts"];
        if (![turnParts isKindOfClass:[NSArray class]]) continue;
        
        NSMutableArray *blocks = [NSMutableArray array];
        for (NSDictionary *part in turnParts) {
            if (![part isKindOfClass:[NSDictionary class]]) continue;
            NSString *type = part[@"type"];
            NSString *textVal = part[@"text"];
            NSString *dataVal = part[@"data"];
            
            if ([type isEqualToString:@"text"] && [textVal length] > 0) {
                [blocks addObject:@{ @"type": @"text", @"text": textVal }];
            } else if ([type isEqualToString:@"image"] && [dataVal length] > 0) {
                [blocks addObject:@{ @"type": @"image",
                                     @"source": @{ @"type": @"base64", @"media_type": part[@"mime"] ?: @"image/jpeg", @"data": dataVal } }];
            } else if ([type isEqualToString:@"pdf"] && [dataVal length] > 0) {
                [blocks addObject:@{ @"type": @"document",
                                     @"source": @{ @"type": @"base64", @"media_type": @"application/pdf", @"data": dataVal } }];
            }
        }
        if (blocks.count == 0) continue;
        NSString *roleStr = [turn[@"role"] isEqualToString:@"assistant"] ? @"assistant" : @"user";
        [messages addObject:@{ @"role": roleStr, @"content": blocks }];
    }
    return messages;
}

#pragma mark - Control

- (void)start {
    NSInteger maxTokens = [self maxTokens];
    NSArray *messagesArray = [ClaudeStream messagesFromTurns:self.turns];
    NSMutableDictionary *payload = [@{ @"model": self.model ?: @"",
                                       @"max_tokens": @(maxTokens),
                                       @"messages": messagesArray } mutableCopy];
    if (self.useStreaming) payload[@"stream"] = @YES;
    if (self.system.length > 0) payload[@"system"] = self.system;

    NSString *lowerModel = self.model.lowercaseString ?: @"";
    BOOL supportsFast = ([lowerModel containsString:@"claude-opus-5-5"] ||
                         [lowerModel containsString:@"claude-fable-5-2"] ||
                         [lowerModel containsString:@"claude-mythos-5-2"] ||
                         [lowerModel isEqualToString:@"claude-opus-5"] ||
                         [lowerModel containsString:@"claude-opus-5-"] ||
                         [lowerModel containsString:@"claude-opus-4-8"]);
    BOOL isOpus5Preview = [lowerModel isEqualToString:@"claude-opus-5"] ||
                          ([lowerModel containsString:@"claude-opus-5-"] && ![lowerModel containsString:@"claude-opus-5-5"]);
    BOOL needsFastBeta = isOpus5Preview || [lowerModel containsString:@"claude-opus-4-8"];
    if (self.useFastSpeed && supportsFast) payload[@"speed"] = @"fast";
    
    AIReasoningLevel level = [AppSettings reasoningLevel];
    BOOL adaptiveThinking = ([lowerModel containsString:@"-4-6"] || [lowerModel containsString:@"-4-7"] ||
                             [lowerModel containsString:@"-4-8"] || [lowerModel containsString:@"-5-"] ||
                             [lowerModel containsString:@"-6-"]);
    BOOL legacyThinking = ([lowerModel containsString:@"-3-7"] || [lowerModel containsString:@"-4-0"] ||
                           [lowerModel containsString:@"-4-1"] || [lowerModel containsString:@"-4-2"] ||
                           [lowerModel containsString:@"-4-3"] || [lowerModel containsString:@"-4-4"] ||
                           [lowerModel containsString:@"-4-5"]);
    if (adaptiveThinking) {
        NSArray *efforts = @[@"low", @"medium", @"high", @"xhigh", @"max"];
        NSString *effort = efforts[(NSUInteger)MIN(level, efforts.count - 1)];
        if ([lowerModel containsString:@"-4-6"] && level == AIReasoningLevelVeryHigh) effort = @"high";
        NSMutableDictionary *thinking = [@{ @"type": @"adaptive" } mutableCopy];
        if ([lowerModel containsString:@"-4-7"] || [lowerModel containsString:@"-4-8"] ||
            [lowerModel containsString:@"-5-"] || [lowerModel containsString:@"-6-"]) {
            thinking[@"display"] = @"summarized";
        }
        payload[@"thinking"] = thinking;
        payload[@"output_config"] = @{ @"effort": effort };
    } else if (legacyThinking && level > AIReasoningLevelLow) {
        NSArray *budgets = @[@0, @1024, @2048, @4096, @8192];
        NSInteger budget = [budgets[(NSUInteger)MIN(level, budgets.count - 1)] integerValue];
        budget = MIN(budget, MAX(0, maxTokens - 1024));
        if (budget >= 1024) payload[@"thinking"] = @{ @"type": @"enabled", @"budget_tokens": @(budget) };
    }

    if ([AppSettings webSearchEnabled]) {
        payload[@"tools"] = @[@{ @"type": @"web_search_20250305", @"name": @"web_search", @"max_uses": @3 }];
    }
    
    NSError *jsonError = nil;
    NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&jsonError];
    if (jsonError || !body) {
        body = [NSData data];
    }

    NSTimeInterval timeout = self.useStreaming ? 180 : 240;
    NSURL *requestURL = [NSURL URLWithString:kClaudeMessagesURL];
    if (!requestURL) return;

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:requestURL
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:timeout];
    request.HTTPMethod = @"POST";
    request.HTTPBody = body;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:self.useStreaming ? @"text/event-stream" : @"application/json" forHTTPHeaderField:@"Accept"];
    if (self.useStreaming) [request setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
    if (self.key.length > 0) [request setValue:self.key forHTTPHeaderField:@"x-api-key"];
    [request setValue:kAnthropicVersion forHTTPHeaderField:@"anthropic-version"];
    if (self.useFastSpeed && supportsFast && needsFastBeta) {
        [request setValue:@"fast-mode-2026-02-01" forHTTPHeaderField:@"anthropic-beta"];
    }

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
    if (self.task) {
        [self.task cancel];
    }
}

#pragma mark - NSURLSessionDataDelegate

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    self.status = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
    self.retryAfterSeconds = 0;
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSDictionary *headers = [(NSHTTPURLResponse *)response allHeaderFields];
        for (id key in headers) {
            if ([[key description] caseInsensitiveCompare:@"Retry-After"] != NSOrderedSame) continue;
            id rawValue = headers[key];
            NSTimeInterval delay = [rawValue respondsToSelector:@selector(doubleValue)] ? [rawValue doubleValue] : 0;
            if (delay <= 0 && [rawValue respondsToSelector:@selector(description)]) {
                NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
                formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
                formatter.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"GMT"];
                formatter.dateFormat = @"EEE, dd MMM yyyy HH:mm:ss z";
                NSDate *retryDate = [formatter dateFromString:[rawValue description]];
                if (retryDate) delay = [retryDate timeIntervalSinceNow];
            }
            self.retryAfterSeconds = MIN(900.0, MAX(0.0, delay));
            break;
        }
    }
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    if (!data || data.length == 0) return;
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
    if (self.session) {
        [self.session finishTasksAndInvalidate];
    }

    GeminiStreamError result = GeminiStreamErrorNone;
    NSString *detail = nil;

    if (self.cancelled) {
        result = GeminiStreamErrorCancelled;
    } else if (error != nil) {
        result = GeminiStreamErrorNetwork;
        detail = [NSString stringWithFormat:@"%@ [%@ %ld]", error.localizedDescription ?: @"Lỗi mạng", error.domain ?: @"", (long)error.code];
    } else if (self.status != 200) {
        NSString *type = nil, *message = nil;
        [self readErrorBody:self.errorBody type:&type message:&message];
        detail = (type.length && message.length)
            ? [NSString stringWithFormat:@"%@ | %@", type, message]
            : (message.length ? message : type);
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

    if (self.onUsage && (self.inputTokenUsage > 0 || self.outputTokenUsage > 0)) {
        self.onUsage(self.inputTokenUsage, self.outputTokenUsage);
    }
    void (^finish)(GeminiStreamError, NSInteger, NSString *) = self.onFinish;
    NSInteger reportedStatus = self.status;
    if (reportedStatus == 200 && [self.inStreamErrorType isEqualToString:@"overloaded_error"]) reportedStatus = 529;
    else if (reportedStatus == 200 && [self.inStreamErrorType isEqualToString:@"rate_limit_error"]) reportedStatus = 429;
    else if (reportedStatus == 200 && [self.inStreamErrorType isEqualToString:@"not_found_error"]) reportedStatus = 404;
    else if (reportedStatus == 200 && [self.inStreamErrorType isEqualToString:@"authentication_error"]) reportedStatus = 401;
    else if (reportedStatus == 200 && [self.inStreamErrorType isEqualToString:@"permission_error"]) reportedStatus = 403;
    else if (reportedStatus == 200 && [self.inStreamErrorType isEqualToString:@"request_too_large"]) reportedStatus = 413;
    else if (reportedStatus == 200 && [self.inStreamErrorType isEqualToString:@"api_error"]) reportedStatus = 500;
    NSInteger status = reportedStatus;
    self.onDelta = nil;
    self.onUsage = nil;
    self.onFinish = nil;
    if (finish) finish(result, status, detail);
}

#pragma mark - SSE parsing

- (void)drainBufferFinal:(BOOL)final {
    NSData *newline = [NSData dataWithBytes:"\n" length:1];
    while (self.buffer.length > 0) {
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

- (void)processLineData:(NSData *)lineData {
    if (!lineData || lineData.length == 0) return;
    NSString *line = [[NSString alloc] initWithData:lineData encoding:NSUTF8StringEncoding];
    if (line == nil) return;
    line = [line stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\r"]];
    if (![line hasPrefix:@"data:"]) return;
    NSString *payload = [[line substringFromIndex:5] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (payload.length == 0) return;

    NSData *payloadData = [payload dataUsingEncoding:NSUTF8StringEncoding];
    if (!payloadData) return;

    NSError *jsonError = nil;
    id json = [NSJSONSerialization JSONObjectWithData:payloadData options:0 error:&jsonError];
    if (jsonError || ![json isKindOfClass:[NSDictionary class]]) return;
    [self processEvent:json];
}

- (void)processEvent:(NSDictionary *)event {
    if (![event isKindOfClass:[NSDictionary class]]) return;
    NSString *type = [event[@"type"] isKindOfClass:[NSString class]] ? event[@"type"] : @"";

    if ([type isEqualToString:@"message_start"]) {
        NSDictionary *message = [event[@"message"] isKindOfClass:[NSDictionary class]] ? event[@"message"] : nil;
        NSDictionary *usage = [message[@"usage"] isKindOfClass:[NSDictionary class]] ? message[@"usage"] : nil;
        long long input = [usage[@"input_tokens"] longLongValue]
                        + [usage[@"cache_creation_input_tokens"] longLongValue]
                        + [usage[@"cache_read_input_tokens"] longLongValue];
        self.inputTokenUsage = MAX(self.inputTokenUsage, input);
        self.outputTokenUsage = MAX(self.outputTokenUsage, [usage[@"output_tokens"] longLongValue]);
    } else if ([type isEqualToString:@"content_block_delta"]) {
        NSDictionary *delta = [event[@"delta"] isKindOfClass:[NSDictionary class]] ? event[@"delta"] : nil;
        NSString *text = [delta[@"text"] isKindOfClass:[NSString class]] ? delta[@"text"] : nil;
        if ([delta[@"type"] isEqualToString:@"text_delta"] && text.length > 0) {
            self.gotText = YES;
            if (self.onDelta) self.onDelta(text);
        }
    } else if ([type isEqualToString:@"message_delta"]) {
        NSDictionary *delta = [event[@"delta"] isKindOfClass:[NSDictionary class]] ? event[@"delta"] : nil;
        NSDictionary *usage = [event[@"usage"] isKindOfClass:[NSDictionary class]] ? event[@"usage"] : nil;
        if ([delta[@"stop_reason"] isKindOfClass:[NSString class]]) self.stopReason = delta[@"stop_reason"];
        self.outputTokenUsage = MAX(self.outputTokenUsage, [usage[@"output_tokens"] longLongValue]);
    } else if ([type isEqualToString:@"error"]) {
        NSDictionary *err = [event[@"error"] isKindOfClass:[NSDictionary class]] ? event[@"error"] : nil;
        self.inStreamErrorType = [err[@"type"] isKindOfClass:[NSString class]] ? err[@"type"] : @"api_error";
        if ([err[@"message"] isKindOfClass:[NSString class]]) self.inStreamErrorMessage = err[@"message"];
    }
}

- (void)processWholeBody {
    if (self.buffer.length == 0) return;
    NSError *jsonError = nil;
    id json = [NSJSONSerialization JSONObjectWithData:self.buffer options:0 error:&jsonError];
    if (jsonError || ![json isKindOfClass:[NSDictionary class]]) return;
    
    NSDictionary *root = json;
    NSDictionary *usage = [root[@"usage"] isKindOfClass:[NSDictionary class]] ? root[@"usage"] : nil;
    long long input = [usage[@"input_tokens"] longLongValue]
                    + [usage[@"cache_creation_input_tokens"] longLongValue]
                    + [usage[@"cache_read_input_tokens"] longLongValue];
    self.inputTokenUsage = MAX(self.inputTokenUsage, input);
    self.outputTokenUsage = MAX(self.outputTokenUsage, [usage[@"output_tokens"] longLongValue]);
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
    if (!body || body.length == 0) return;
    NSError *jsonError = nil;
    id json = [NSJSONSerialization JSONObjectWithData:body options:0 error:&jsonError];
    if (jsonError || ![json isKindOfClass:[NSDictionary class]]) return;
    
    NSDictionary *err = [json[@"error"] isKindOfClass:[NSDictionary class]] ? json[@"error"] : nil;
    if ([err[@"type"] isKindOfClass:[NSString class]]) *type = err[@"type"];
    if ([err[@"message"] isKindOfClass:[NSString class]]) *message = err[@"message"];
}

+ (GeminiStreamError)errorForStatus:(NSInteger)status type:(NSString *)type message:(NSString *)message {
    NSString *lower = [message lowercaseString] ?: @"";
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
    if (status >= 500) return GeminiStreamErrorServer;
    return GeminiStreamErrorUnknown;
}

@end
