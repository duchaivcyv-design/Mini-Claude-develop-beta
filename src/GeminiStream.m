#import "GeminiStream.h"
#import "AppSettings.h"
#import "ModelStore.h"
#import "Provider.h"

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
@property (assign, nonatomic) NSTimeInterval retryAfterSeconds;
@property (assign, nonatomic) BOOL cancelled;
@property (assign, nonatomic) BOOL finished;
@property (assign, nonatomic) BOOL gotText;
@property (copy, nonatomic) NSString *blockReason;         // promptFeedback.blockReason or a blocking finishReason
@property (assign, nonatomic) NSInteger inStreamErrorStatus;   // error object delivered inside a 200 stream
@property (copy, nonatomic) NSString *inStreamErrorMessage;
@property (assign, nonatomic) long long inputTokenUsage;
@property (assign, nonatomic) long long outputTokenUsage;
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

    NSInteger requestedOutputTokens = [AppSettings maxOutputTokens];
    NSInteger modelCap = [ModelStore maxOutputTokensForModelId:self.model provider:AIProviderGemini];
    // Older cached model lists may not include token metadata yet; stay conservative until the list refreshes.
    if (modelCap <= 0) modelCap = 8192;
    NSString *lowerModel = self.model.lowercaseString;
    AIReasoningLevel reasoning = [AppSettings reasoningLevel];

    NSMutableDictionary *generationConfig = [NSMutableDictionary dictionary];
    // maxOutputTokens includes hidden reasoning tokens. Keep an answer reserve and
    // clamp the reasoning budget to the model's true output ceiling to avoid invalid
    // requests (a common source of 400s on older cached model metadata).
    BOOL supportsThinking = [lowerModel containsString:@"gemini-2.5"] ||
                            [lowerModel containsString:@"gemini-3"] ||
                            [lowerModel containsString:@"gemini-4"];
    NSInteger answerReserve = supportsThinking
        ? MIN(requestedOutputTokens, MAX(1024, (modelCap * 2) / 3))
        : MIN(requestedOutputTokens, modelCap);
    NSInteger availableThinking = supportsThinking ? MAX(0, modelCap - answerReserve) : 0;
    NSInteger thinkingBudget = 0;
    // Gemini 3 uses lowercase thinkingLevel values. Gemini 2.5 uses explicit budgets.
    // Keep model-specific documented ranges: Pro up to 32,768; Flash variants up to 24,576.
    if ([lowerModel containsString:@"gemini-4"]) {
        NSArray *levels = @[@"low", @"low", @"medium", @"high", @"high"];
        generationConfig[@"thinkingConfig"] = @{ @"thinkingLevel": levels[(NSUInteger)reasoning] };
    } else if ([lowerModel containsString:@"gemini-3"]) {
        // Gemini 3.1 Pro does not accept "minimal"; other listed Gemini 3 Flash models do.
        NSArray *levels = [lowerModel containsString:@"pro"]
            ? @[@"low", @"low", @"medium", @"high", @"high"]
            : @[@"minimal", @"low", @"medium", @"high", @"high"];
        generationConfig[@"thinkingConfig"] = @{ @"thinkingLevel": levels[(NSUInteger)reasoning] };
    } else if ([lowerModel containsString:@"gemini-2.5"]) {
        BOOL proModel = [lowerModel containsString:@"pro"];
        NSArray *budgets = proModel
            ? @[@128, @1024, @8192, @24576, @32768]
            : @[@0, @1024, @4096, @16384, @24576];
        NSInteger desiredBudget = [budgets[(NSUInteger)reasoning] integerValue];
        thinkingBudget = MIN(desiredBudget, availableThinking);
        // Gemini 2.5 Pro requires at least 128 tokens when explicit thinking is enabled.
        if (proModel && thinkingBudget > 0 && thinkingBudget < 128) thinkingBudget = 0;
        if (!proModel || thinkingBudget >= 128) {
            generationConfig[@"thinkingConfig"] = @{ @"thinkingBudget": @(thinkingBudget) };
        }
    }

    NSInteger reasoningHeadroom = thinkingBudget;
    if ([lowerModel containsString:@"gemini-3"] || [lowerModel containsString:@"gemini-4"]) {
        NSInteger desiredHeadroom = reasoning >= AIReasoningLevelMax ? 16384 :
                                    (reasoning >= AIReasoningLevelVeryHigh ? 12288 :
                                     (reasoning >= AIReasoningLevelHigh ? 8192 : 2048));
        reasoningHeadroom = MIN(desiredHeadroom, availableThinking);
    }
    NSInteger outputTokens = MIN(modelCap, answerReserve + reasoningHeadroom);
    generationConfig[@"maxOutputTokens"] = @(MAX(1, outputTokens));

    // Gemini image-generation models require both text and image response modalities.
    if ([lowerModel containsString:@"image"] || [lowerModel containsString:@"nano-banana"]) {
        generationConfig[@"responseModalities"] = @[@"TEXT", @"IMAGE"];
    }
    BOOL imageGenerationModel = [lowerModel containsString:@"image"] || [lowerModel containsString:@"nano-banana"];
    NSMutableDictionary *payload = [@{ @"contents": [GeminiStream contentsFromTurns:self.turns],
                                       @"generationConfig": generationConfig } mutableCopy];
    if (self.system.length > 0) payload[@"systemInstruction"] = @{ @"parts": @[ @{ @"text": self.system } ] };
    if ([AppSettings webSearchEnabled] && !imageGenerationModel) payload[@"tools"] = @[@{ @"google_search": @{} }];
    NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];

    // High-effort reasoning and grounded searches can take longer before the first SSE event.
    // Use a generous inactivity timeout; the delegate resets it as data continues to arrive.
    NSTimeInterval timeout = self.useStreaming ? 180 : 240;
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
    self.retryAfterSeconds = 0;
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSDictionary *headers = [(NSHTTPURLResponse *)response allHeaderFields];
        for (id key in headers) {
            if ([[key description] caseInsensitiveCompare:@"Retry-After"] != NSOrderedSame) continue;
            id rawValue = headers[key];
            NSTimeInterval delay = [rawValue respondsToSelector:@selector(doubleValue)] ? [rawValue doubleValue] : 0;
            if (delay <= 0) {
                // Retry-After may be delta-seconds or an HTTP-date (RFC 7231).
                NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
                formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
                formatter.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"GMT"];
                formatter.dateFormat = @"EEE, dd MMM yyyy HH:mm:ss z";
                NSDate *retryDate = [formatter dateFromString:[rawValue description]];
                if (retryDate) delay = [retryDate timeIntervalSinceNow];
            }
            self.retryAfterSeconds = MIN(60.0, MAX(0.0, delay));
            break;
        }
    }
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

    if (self.onUsage && (self.inputTokenUsage > 0 || self.outputTokenUsage > 0)) {
        self.onUsage(self.inputTokenUsage, self.outputTokenUsage);
    }
    void (^finish)(GeminiStreamError, NSInteger, NSString *) = self.onFinish;
    // Streaming endpoints can return HTTP 200 and then send an error object in an SSE frame.
    // Surface its embedded status (e.g. 503/429) to the controller's retry policy.
    NSInteger status = self.inStreamErrorStatus > 0 ? self.inStreamErrorStatus : self.status;
    self.onDelta = nil;
    self.onImage = nil;
    self.onUsage = nil;
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
    NSDictionary *usage = [chunk[@"usageMetadata"] isKindOfClass:[NSDictionary class]] ? chunk[@"usageMetadata"] : nil;
    if (usage) {
        self.inputTokenUsage = MAX(self.inputTokenUsage, [usage[@"promptTokenCount"] longLongValue]);
        long long output = [usage[@"candidatesTokenCount"] longLongValue] + [usage[@"thoughtsTokenCount"] longLongValue];
        self.outputTokenUsage = MAX(self.outputTokenUsage, output);
    }
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
        BOOL isThought = [part[@"thought"] respondsToSelector:@selector(boolValue)] && [part[@"thought"] boolValue];
        NSString *text = part[@"text"];
        if (!isThought && [text isKindOfClass:[NSString class]] && text.length > 0) {
            self.gotText = YES;
            if (self.onDelta) self.onDelta(text);
        }
        NSDictionary *inlineData = [part[@"inlineData"] isKindOfClass:[NSDictionary class]] ? part[@"inlineData"] : nil;
        NSString *mime = [inlineData[@"mimeType"] isKindOfClass:[NSString class]] ? inlineData[@"mimeType"] : @"";
        NSString *encoded = [inlineData[@"data"] isKindOfClass:[NSString class]] ? inlineData[@"data"] : nil;
        if ([mime hasPrefix:@"image/"] && encoded.length > 0) {
            NSData *imageData = [[NSData alloc] initWithBase64EncodedString:encoded options:NSDataBase64DecodingIgnoreUnknownCharacters];
            if (imageData.length > 0) {
                self.gotText = YES; // A generated image is a successful model response even when no text accompanies it.
                if (self.onImage) self.onImage(imageData, mime);
            }
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
