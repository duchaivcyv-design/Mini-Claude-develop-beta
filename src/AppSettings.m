#import "AppSettings.h"

const NSUInteger kMaxSystemPromptChars = 4000;
static NSString *const kSystemPromptKey = @"systemPrompt";
static NSString *const kAttachmentMemoryKey = @"attachmentMemory";

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

@end
