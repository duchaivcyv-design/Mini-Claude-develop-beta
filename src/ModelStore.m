#import "ModelStore.h"
#import "KeyStore.h"

static NSString *const kSelectedModelKey = @"selectedModel";

// The Gemini key is the one earlier versions used, so a cached list survives an update.
static NSString *CacheKeyFor(AIProvider provider) {
    return provider == AIProviderClaude ? @"cachedModels.claude" : @"cachedModels";
}

@implementation ModelStore

+ (NSArray *)cachedModelsForProvider:(AIProvider)provider {
    id value = [[NSUserDefaults standardUserDefaults] objectForKey:CacheKeyFor(provider)];
    if (![value isKindOfClass:[NSArray class]]) return @[];
    NSMutableArray *out = [NSMutableArray array];
    for (id item in (NSArray *)value) {
        if ([item isKindOfClass:[NSDictionary class]] && [item[@"id"] isKindOfClass:[NSString class]]) [out addObject:item];
    }
    return out;
}

+ (void)saveModels:(NSArray *)models forProvider:(AIProvider)provider {
    [[NSUserDefaults standardUserDefaults] setObject:models forKey:CacheKeyFor(provider)];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

+ (NSString *)selectedModelId {
    NSString *value = [[NSUserDefaults standardUserDefaults] stringForKey:kSelectedModelKey];
    return value.length > 0 ? value : nil;
}

+ (void)setSelectedModelId:(NSString *)modelId {
    if (modelId.length > 0) {
        [[NSUserDefaults standardUserDefaults] setObject:modelId forKey:kSelectedModelKey];
    } else {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:kSelectedModelKey];
    }
    [[NSUserDefaults standardUserDefaults] synchronize];
}

+ (BOOL)isLikelyFreeModelId:(NSString *)modelId {
    if ([modelId rangeOfString:@"flash"].location == NSNotFound) return NO;
    // Flash-branded variants that Google lists as not available on the free tier.
    NSArray *paidVariants = @[@"omni", @"cyber"];
    for (NSString *token in paidVariants) {
        if ([modelId rangeOfString:token].location != NSNotFound) return NO;
    }
    return YES;
}

+ (NSString *)defaultGeminiModelIdFrom:(NSArray *)models {
    // 1) newest stable "gemini-<version>-flash"
    NSRegularExpression *stable =
        [NSRegularExpression regularExpressionWithPattern:@"^gemini-(\\d+(?:\\.\\d+)?)-flash$" options:0 error:nil];
    NSString *bestId = nil;
    double bestVersion = -1;
    for (NSDictionary *model in models) {
        NSString *modelId = model[@"id"];
        NSTextCheckingResult *match = [stable firstMatchInString:modelId options:0 range:NSMakeRange(0, modelId.length)];
        if (match) {
            double version = [[modelId substringWithRange:[match rangeAtIndex:1]] doubleValue];
            if (version > bestVersion) { bestVersion = version; bestId = modelId; }
        }
    }
    if (bestId) return bestId;

    // 2) any free-tier-family model that is not a preview/experimental/lite variant
    NSArray *avoid = @[@"lite", @"preview", @"exp", @"8b", @"thinking"];
    for (NSDictionary *model in models) {
        NSString *modelId = model[@"id"];
        if (![self isLikelyFreeModelId:modelId]) continue;
        BOOL skip = NO;
        for (NSString *token in avoid) {
            if ([modelId rangeOfString:token].location != NSNotFound) { skip = YES; break; }
        }
        if (!skip) return modelId;
    }

    // 3) any model from the free-tier families, even a lite/preview variant: better than a paid one
    for (NSDictionary *model in models) {
        if ([self isLikelyFreeModelId:model[@"id"]]) return model[@"id"];
    }

    // 4) nothing recognizable: whatever comes first
    return models.firstObject[@"id"];
}

+ (NSString *)defaultClaudeModelIdFrom:(NSArray *)models {
    // The API lists the newest models first, so the first Sonnet is the newest Sonnet.
    for (NSDictionary *model in models) {
        if ([model[@"id"] rangeOfString:@"sonnet"].location != NSNotFound) return model[@"id"];
    }
    return models.firstObject[@"id"];
}

+ (NSString *)defaultModelIdForProvider:(AIProvider)provider models:(NSArray *)models {
    if (models.count == 0) return nil;
    return provider == AIProviderClaude ? [self defaultClaudeModelIdFrom:models] : [self defaultGeminiModelIdFrom:models];
}

+ (NSString *)defaultModelIdAcrossProviders {
    for (NSNumber *value in [Provider all]) {
        AIProvider provider = (AIProvider)value.integerValue;
        if (![KeyStore hasKeyForProvider:provider]) continue;
        NSString *modelId = [self defaultModelIdForProvider:provider models:[self cachedModelsForProvider:provider]];
        if (modelId.length > 0) return modelId;
    }
    return nil;
}

@end
