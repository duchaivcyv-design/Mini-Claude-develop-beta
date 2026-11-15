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

+ (NSInteger)maxOutputTokensForModelId:(NSString *)modelId provider:(AIProvider)provider {
    if (modelId.length == 0) return 0;
    NSString *field = provider == AIProviderClaude ? @"max_tokens" : @"outputTokenLimit";
    for (NSDictionary *model in [self cachedModelsForProvider:provider]) {
        if (![model[@"id"] isEqualToString:modelId]) continue;
        id value = model[field];
        if ([value respondsToSelector:@selector(integerValue)]) {
            NSInteger cap = [value integerValue];
            return cap > 0 ? cap : 0;
        }
        return 0;
    }
    return 0;
}

+ (NSInteger)maxInputTokensForModelId:(NSString *)modelId provider:(AIProvider)provider {
    if (modelId.length == 0) return 0;
    NSString *field = provider == AIProviderClaude ? @"max_input_tokens" : @"inputTokenLimit";
    for (NSDictionary *model in [self cachedModelsForProvider:provider]) {
        if (![model[@"id"] isEqualToString:modelId]) continue;
        id value = model[field];
        if ([value respondsToSelector:@selector(integerValue)]) {
            NSInteger cap = [value integerValue];
            return cap > 0 ? cap : 0;
        }
        return 0;
    }
    return 0;
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
    NSString *lower = [modelId lowercaseString];
    // Chấp nhận tất cả các model thuộc họ flash, nano hoặc có tiền tố gemini/nano
    if ([lower rangeOfString:@"flash"].location != NSNotFound || 
        [lower rangeOfString:@"nano"].location != NSNotFound ||
        [lower rangeOfString:@"gemini-"].location != NSNotFound) {
        
        // Các biến thể thu phí nặng (nếu có thể tùy chỉnh chặn ở đây)
        NSArray *paidVariants = @[@"omni-locked"];
        for (NSString *token in paidVariants) {
            if ([lower rangeOfString:token].location != NSNotFound) return NO;
        }
        return YES;
    }
    return NO;
}

+ (NSString *)defaultGeminiModelIdFrom:(NSArray *)models {
    // 1) Ưu tiên tìm các model flash hoặc nano mới nhất
    for (NSDictionary *model in models) {
        NSString *modelId = model[@"id"];
        NSString *lower = [modelId lowercaseString];
        if ([lower rangeOfString:@"flash"].location != NSNotFound || [lower rangeOfString:@"nano"].location != NSNotFound) {
            return modelId;
        }
    }

    // 2) Bất kỳ model nào hợp lệ từ danh sách
    for (NSDictionary *model in models) {
        if ([self isLikelyFreeModelId:model[@"id"]]) return model[@"id"];
    }

    // 3) Mặc định lấy model đầu tiên nếu không khớp
    return models.firstObject[@"id"];
}

+ (NSString *)defaultClaudeModelIdFrom:(NSArray *)models {
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
