#import "AppSettings.h"

const NSUInteger kMaxSystemPromptChars = 100000;
static NSString *const kSystemPromptKey = @"systemPrompt";
static NSString *const kAttachmentMemoryKey = @"attachmentMemory";
static NSString *const kMaxOutputTokensKey = @"maxOutputTokens";
static NSString *const kContextLimitCharsKey = @"contextLimitChars";

@implementation AppSettings

+ (NSString *)cleanedPrompt:(NSString *)text {
    NSString *trimmed = [(text ?: @"") stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length > kMaxSystemPromptChars) {
        NSRange safe = [trimmed rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, kMaxSystemPromptChars)];
        trimmed = [trimmed substringWithRange:safe];
    }
    return trimmed;
}

+ (NSString *)systemPrompt {
    NSString *value = [[NSUserDefaults standardUserDefaults] stringForKey:kSystemPromptKey];
    return value ?: @"";
}

+ (void)setSystemPrompt:(NSString *)prompt {
    NSString *cleaned = [self cleanedPrompt:prompt];
    if (cleaned.length == 0) {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:kSystemPromptKey];
    } else {
        [[NSUserDefaults standardUserDefaults] setObject:cleaned forKey:kSystemPromptKey];
    }
    [[NSUserDefaults standardUserDefaults] synchronize];
}

+ (NSInteger)attachmentMemory {
    NSNumber *value = [[NSUserDefaults standardUserDefaults] objectForKey:kAttachmentMemoryKey];
    if (![value isKindOfClass:[NSNumber class]]) return 3;
    NSInteger count = value.integerValue;
    return (count == 0 || count == 1 || count == 3) ? count : 3;
}

+ (void)setAttachmentMemory:(NSInteger)count {
    if (count != 0 && count != 1 && count != 3) count = 3;
    [[NSUserDefaults standardUserDefaults] setInteger:count forKey:kAttachmentMemoryKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

+ (NSInteger)maxOutputTokens {
    NSInteger value = [[NSUserDefaults standardUserDefaults] integerForKey:kMaxOutputTokensKey];
    return (value == 2048 || value == 4096 || value == 8192 || value == 16384 || value == 32768 || value == 65536 || value == 128000) ? value : 8192;
}

+ (void)setMaxOutputTokens:(NSInteger)count {
    if (count != 2048 && count != 4096 && count != 8192 && count != 16384 && count != 32768 && count != 65536 && count != 128000) count = 8192;
    [[NSUserDefaults standardUserDefaults] setInteger:count forKey:kMaxOutputTokensKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

+ (NSUInteger)contextLimitChars {
    NSInteger value = [[NSUserDefaults standardUserDefaults] integerForKey:kContextLimitCharsKey];
    return (value == 200000 || value == 400000 || value == 600000) ? (NSUInteger)value : 400000;
}

+ (void)setContextLimitChars:(NSUInteger)count {
    if (count != 200000 && count != 400000 && count != 600000) count = 400000;
    [[NSUserDefaults standardUserDefaults] setInteger:(NSInteger)count forKey:kContextLimitCharsKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

@end
