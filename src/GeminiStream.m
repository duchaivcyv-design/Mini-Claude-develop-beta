#import "GeminiStream.h"

@interface GeminiStream () <NSURLSessionDataDelegate>
@property (copy, nonatomic) NSString *key;
@property (copy, nonatomic) NSString *model;
@property (copy, nonatomic) NSArray *turns;
@property (copy, nonatomic) NSString *system;
@property (strong, nonatomic) NSURLSession *session;
@property (strong, nonatomic) NSURLSessionDataTask *task;
@property (strong, nonatomic) NSMutableData *buffer;       // unfinished SSE bytes
@property (strong, nonatomic) NSMutableData *errorBody;    // body of a non-200 response
@property (assign, nonatomic) NSInteger status;
@property (assign, nonatomic) BOOL cancelled;
@property (assign, nonatomic) BOOL finished;
@property (assign, nonatomic) BOOL gotText;
@property (copy, nonatomic) NSString *blockReason;         // promptFeedback.blockReason or a blocking finishReason
@property (assign, nonatomic) NSInteger inStreamErrorStatus;   // error object delivered inside a 200 stream
@property (copy, nonatomic) NSString *inStreamErrorMessage;
@end

@implementation GeminiStream

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

// Neutral turns -> Gemini "contents": assistant becomes "model"; photos and PDFs become inline_data.
+ (NSArray *)contentsFromTurns:(NSArray *)turns {
    NSMutableArray *contents = [NSMutableArray array];
    for (NSDictionary *turn in turns) {
        NSMutableArray *parts = [NSMutableArray array];
        for (NSDictionary *part in turn[@"parts"]) {
            NSString *type = part[@"type"];
            if ([type isEqualToString:@"text"] && [part[@"text"] length] > 0) {
                [parts addObject:@{ @"text": part[@"text"] }];
            } else if ([type isEqualToString:@"image"] && [part[@"data"] length] > 0) {
                [parts addObject:@{ @"inline_data": @{ @"mime_type": part[@"mime"] ?: @"image/jpeg", @"data": part[@"data"] } }];
            } else if ([type isEqualToString:@"pdf"] && [part[@"data"] length] > 0) {
                [parts addObject:@{ @"inline_data": @{ @"mime_type": @"application/pdf", @"data": part[@"data"] } }];
            }
        }
        if (parts.count == 0) continue;
        [contents addObject:@{ @"role": [turn[@"role"] isEqualToString:@"assistant"] ? @"model" : @"user", @"parts": parts }];
    }
    return contents;
}

#pragma mark - Control

- (void)start {
    NSString *escapedModel = [self.model stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
    NSString *method = self.useStreaming ? @"streamGenerateContent?alt=sse" : @"generateContent";
    NSString *urlString = [NSString stringWithFormat:
        @"https://generativelanguage.googleapis.com/v1beta/models/%@:%@", escapedModel, method];

    NSMutableDictionary *payload = [@{ @"contents": [GeminiStream contentsFromTurns:self.turns] } mutableCopy];
    if (self.system.length > 0) payload[@"system_instruction"] = @{ @"parts": @[ @{ @"text": self.system } ] };
    NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];

    // Streaming: give up if nothing at all arrives for 45 s. Single-shot: the whole answer must arrive within 120 s.
    NSTimeInterval timeout = self.useStreaming ? 45 : 120;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:timeout];
    request.HTTPMethod = @"POST";
    request.HTTPBody = body;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:self.useStreaming ? @"text/event-stream" : @"application/json" forHTTPHeaderField:@"Accept"];
    if (self.useStreaming) {
        // No compression on the live stream, so events are not held back inside compressor blocks.
        [request setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
    }
    [request setValue:self.key forHTTPHeaderField:@"x-goog-api-key"];

    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    config.timeoutIntervalForRequest = timeout;
    config.timeoutIntervalForResource = 600;
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
        // Keep the real reason (timeout, connection lost, TLS...) so it can be shown instead of a vague message.
        detail = [NSString stringWithFormat:@"%@ [%@ %ld]", error.localizedDescription, error.domain, (long)error.code];
    } else if (self.status != 200) {
        NSString *message = [self messageFromErrorBody:self.errorBody];
        detail = message;
        result = [GeminiStream errorForStatus:self.status message:message];
    } else {
        if (self.useStreaming) [self drainBufferFinal:YES]; else [self processWholeBody];
        if (self.inStreamErrorStatus != 0) {
            detail = self.inStreamErrorMessage;
            result = [GeminiStream errorForStatus:self.inStreamErrorStatus message:self.inStreamErrorMessage];
        } else if (!self.gotText) {
            result = self.blockReason.length > 0 ? GeminiStreamErrorBlocked : GeminiStreamErrorEmptyReply;
            detail = self.blockReason;
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

- (void)processLineData:(NSData *)lineData {
    NSString *line = [[NSString alloc] initWithData:lineData encoding:NSUTF8StringEncoding];
    if (line == nil) return;
    line = [line stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\r"]];
    if (![line hasPrefix:@"data:"]) return;

    NSString *payload = [[line substringFromIndex:5] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (payload.length == 0 || [payload isEqualToString:@"[DONE]"]) return;

    id json = [NSJSONSerialization JSONObjectWithData:[payload dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    if (![json isKindOfClass:[NSDictionary class]]) return;
    [self processChunk:json];
}

// One decoded JSON object from the model (a stream event, or the whole single-shot reply).
- (void)processChunk:(NSDictionary *)chunk {
    // An error can arrive inside the stream itself.
    NSDictionary *errorObject = [chunk[@"error"] isKindOfClass:[NSDictionary class]] ? chunk[@"error"] : nil;
    if (errorObject) {
        NSInteger code = [errorObject[@"code"] respondsToSelector:@selector(integerValue)] ? [errorObject[@"code"] integerValue] : 500;
        self.inStreamErrorStatus = code > 0 ? code : 500;
        if ([errorObject[@"message"] isKindOfClass:[NSString class]]) self.inStreamErrorMessage = errorObject[@"message"];
        return;
    }

    NSDictionary *feedback = [chunk[@"promptFeedback"] isKindOfClass:[NSDictionary class]] ? chunk[@"promptFeedback"] : nil;
    if ([feedback[@"blockReason"] isKindOfClass:[NSString class]]) self.blockReason = feedback[@"blockReason"];

    NSArray *candidates = [chunk[@"candidates"] isKindOfClass:[NSArray class]] ? chunk[@"candidates"] : @[];
    NSDictionary *candidate = [candidates.firstObject isKindOfClass:[NSDictionary class]] ? candidates.firstObject : nil;
    if (!candidate) return;

    NSDictionary *content = [candidate[@"content"] isKindOfClass:[NSDictionary class]] ? candidate[@"content"] : nil;
    NSArray *parts = [content[@"parts"] isKindOfClass:[NSArray class]] ? content[@"parts"] : @[];
    for (id part in parts) {
        if (![part isKindOfClass:[NSDictionary class]]) continue;
        if ([part[@"thought"] respondsToSelector:@selector(boolValue)] && [part[@"thought"] boolValue]) continue;   // skip thought summaries
        NSString *text = part[@"text"];
        if ([text isKindOfClass:[NSString class]] && text.length > 0) {
            self.gotText = YES;
            if (self.onDelta) self.onDelta(text);
        }
    }

    NSString *finishReason = [candidate[@"finishReason"] isKindOfClass:[NSString class]] ? candidate[@"finishReason"] : nil;
    if (finishReason.length > 0 && !self.gotText) {
        NSArray *blocking = @[@"SAFETY", @"PROHIBITED_CONTENT", @"BLOCKLIST", @"SPII", @"RECITATION", @"IMAGE_SAFETY"];
        if ([blocking containsObject:finishReason]) self.blockReason = finishReason;
    }
}

- (void)processWholeBody {
    if (self.buffer.length == 0) return;
    id json = [NSJSONSerialization JSONObjectWithData:self.buffer options:0 error:nil];
    if ([json isKindOfClass:[NSDictionary class]]) {
        [self processChunk:json];
    } else if ([json isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)json) {
            if ([item isKindOfClass:[NSDictionary class]]) [self processChunk:item];
        }
    }
}

#pragma mark - Errors

- (NSString *)messageFromErrorBody:(NSData *)body {
    if (body.length == 0) return nil;
    id json = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
    // Some responses wrap the error object in an array.
    if ([json isKindOfClass:[NSArray class]]) json = [(NSArray *)json firstObject];
    if ([json isKindOfClass:[NSDictionary class]]) {
        NSDictionary *err = json[@"error"];
        if ([err isKindOfClass:[NSDictionary class]] && [err[@"message"] isKindOfClass:[NSString class]]) return err[@"message"];
    }
    return nil;
}

+ (GeminiStreamError)errorForStatus:(NSInteger)status message:(NSString *)message {
    NSString *lower = [message lowercaseString];
    if (status == 413) return GeminiStreamErrorTooLarge;
    if (status == 400) {
        if (lower.length > 0 && [lower rangeOfString:@"api key"].location != NSNotFound) return GeminiStreamErrorInvalidKey;
        // "Request payload size exceeds the limit" and similar wording
        if (lower.length > 0 && ([lower rangeOfString:@"payload size"].location != NSNotFound ||
                                 [lower rangeOfString:@"too large"].location != NSNotFound ||
                                 [lower rangeOfString:@"exceeds the limit"].location != NSNotFound)) {
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
