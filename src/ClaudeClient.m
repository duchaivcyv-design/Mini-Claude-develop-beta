#import "ClaudeClient.h"

static NSString *const kClaudeModelsURL = @"https://api.anthropic.com/v1/models";
static NSString *const kAnthropicVersion = @"2023-06-01";
static const NSInteger kMaxModelPages = 10;

static NSString *NormalizedKey(NSString *key) {
    if (![key isKindOfClass:[NSString class]]) return nil;
    NSString *trimmed = [key stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    BOOL asciiOnly = [trimmed canBeConvertedToEncoding:NSASCIIStringEncoding];
    BOOL hasInnerSpace = [trimmed rangeOfCharacterFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].location != NSNotFound;
    if (trimmed.length == 0 || !asciiOnly || hasInnerSpace) return nil;
    return trimmed;
}

static GeminiCheckResult ResultForStatus(NSInteger status) {
    if (status == 200) return GeminiCheckOK;
    if (status == 401 || status == 403) return GeminiCheckInvalidKey;
    if (status == 429) return GeminiCheckRateLimited;
    if (status >= 500) return GeminiCheckNetworkError;
    return GeminiCheckUnknown;
}

static NSMutableURLRequest *ModelsRequest(NSString *key, NSString *afterId) {
    NSMutableString *urlString = [NSMutableString stringWithFormat:@"%@?limit=1000", kClaudeModelsURL];
    if (afterId.length > 0) {
        NSString *escaped = [afterId stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
        [urlString appendFormat:@"&after_id=%@", escaped];
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:15.0];
    request.HTTPMethod = @"GET";
    [request setValue:key forHTTPHeaderField:@"x-api-key"];
    [request setValue:kAnthropicVersion forHTTPHeaderField:@"anthropic-version"];
    return request;
}

@implementation ClaudeClient

+ (void)verifyKey:(NSString *)key completion:(GeminiVerifyCompletion)completion {
    NSString *cleanKey = NormalizedKey(key);
    if (!cleanKey) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(GeminiCheckInvalidKey, 0, 0); });
        return;
    }
    [self verifyKey:cleanKey attempt:0 completion:completion];
}

+ (void)verifyKey:(NSString *)cleanKey attempt:(NSInteger)attempt completion:(GeminiVerifyCompletion)completion {
    NSURLSessionDataTask *task =
        [[NSURLSession sharedSession] dataTaskWithRequest:ModelsRequest(cleanKey, nil)
                                        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        GeminiCheckResult result = GeminiCheckUnknown;
        NSInteger count = 0;
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;

        if (error != nil) {
            result = GeminiCheckNetworkError;
        } else {
            result = ResultForStatus(status);
            if (result == GeminiCheckOK) {
                id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
                NSArray *models = [json isKindOfClass:[NSDictionary class]] ? json[@"data"] : nil;
                count = [models isKindOfClass:[NSArray class]] ? (NSInteger)models.count : 0;
            }
        }

        BOOL shouldRetry = (result == GeminiCheckNetworkError || result == GeminiCheckRateLimited) && attempt < 2;
        if (shouldRetry) {
            NSTimeInterval delay = 0.4 * (attempt + 1);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self verifyKey:cleanKey attempt:attempt + 1 completion:completion];
            });
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{ completion(result, count, status); });
    }];
    [task resume];
}

+ (void)fetchModelsWithKey:(NSString *)key completion:(GeminiModelsCompletion)completion {
    NSString *cleanKey = NormalizedKey(key);
    if (!cleanKey) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(@[], GeminiCheckInvalidKey); });
        return;
    }
    [self fetchPageAfter:nil
                     key:cleanKey
               collected:[NSMutableArray array]
                    seen:[NSMutableSet set]
                   depth:0
                 attempt:0
              completion:completion];
}

+ (void)fetchPageAfter:(NSString *)afterId
                   key:(NSString *)key
             collected:(NSMutableArray *)collected
                  seen:(NSMutableSet *)seen
                 depth:(NSInteger)depth
               attempt:(NSInteger)attempt
            completion:(GeminiModelsCompletion)completion {
    NSURLSessionDataTask *task =
        [[NSURLSession sharedSession] dataTaskWithRequest:ModelsRequest(key, afterId)
                                        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
        GeminiCheckResult result = (error != nil) ? GeminiCheckNetworkError : ResultForStatus(status);

        if (result != GeminiCheckOK) {
            BOOL shouldRetry = (result == GeminiCheckNetworkError || result == GeminiCheckRateLimited) && attempt < 2;
            if (shouldRetry) {
                NSTimeInterval delay = 0.4 * (attempt + 1);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [self fetchPageAfter:afterId
                                     key:key
                               collected:collected
                                    seen:seen
                                   depth:depth
                                 attempt:attempt + 1
                              completion:completion];
                });
                return;
            }
            dispatch_async(dispatch_get_main_queue(), ^{ completion(@[], result); });
            return;
        }

        id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSDictionary *root = [json isKindOfClass:[NSDictionary class]] ? json : @{};
        NSArray *items = [root[@"data"] isKindOfClass:[NSArray class]] ? root[@"data"] : @[];
        for (id item in items) {
            if (![item isKindOfClass:[NSDictionary class]]) continue;
            NSString *modelId = item[@"id"];
            if (![modelId isKindOfClass:[NSString class]] || ![modelId hasPrefix:@"claude"]) continue;
            if ([seen containsObject:modelId]) continue;
            [seen addObject:modelId];

            NSString *display = [item[@"display_name"] isKindOfClass:[NSString class]] ? item[@"display_name"] : modelId;
            NSMutableDictionary *model = [@{ @"id": modelId, @"name": display } mutableCopy];
            id maxTokens = item[@"max_tokens"];
            if ([maxTokens respondsToSelector:@selector(integerValue)] && [maxTokens integerValue] > 0) {
                model[@"max_tokens"] = maxTokens;
            }
            id maxInputTokens = item[@"max_input_tokens"];
            if ([maxInputTokens respondsToSelector:@selector(integerValue)] && [maxInputTokens integerValue] > 0) {
                model[@"max_input_tokens"] = maxInputTokens;
            }
            [collected addObject:model];
        }

        BOOL hasMore = [root[@"has_more"] respondsToSelector:@selector(boolValue)] && [root[@"has_more"] boolValue];
        NSString *lastId = [root[@"last_id"] isKindOfClass:[NSString class]] ? root[@"last_id"] : nil;
        if (hasMore && lastId.length > 0 && depth < kMaxModelPages) {
            [self fetchPageAfter:lastId
                             key:key
                       collected:collected
                            seen:seen
                           depth:depth + 1
                         attempt:0
                      completion:completion];
            return;
        }

        NSArray *result_ = [collected copy];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(result_, GeminiCheckOK); });
    }];
    [task resume];
}

@end
