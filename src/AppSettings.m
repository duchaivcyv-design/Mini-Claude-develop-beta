#import "AppSettings.h"
#import <limits.h>

const NSUInteger kMaxSystemPromptChars = 1000000;
static NSString *const kSystemPromptKey = @"systemPrompt";
static NSString *const kAttachmentMemoryKey = @"attachmentMemory";
static NSString *const kMaxOutputTokensKey = @"maxOutputTokens";
static NSString *const kContextLimitCharsKey = @"contextLimitChars";
static NSString *const kReasoningLevelKey = @"reasoningLevel";
static NSString *const kFastModeKey = @"fastMode";
static NSString *const kWebSearchKey = @"webSearchEnabled";
static NSString *const kDailyUsageKey = @"dailyTokenUsage";
static NSString *const kDailyDateKey = @"dailyTokenUsageDate";
static NSString *const kDailyBudgetKey = @"dailyTokenBudget";

// Keep a single in-memory copy and chunk index so a 100k-1M character prompt is
// not re-read and re-split for every chat turn. Cache is invalidated on save.
static NSString *gPromptTextCache = nil;
static BOOL gPromptTextCacheLoaded = NO;
static NSString *gPromptChunkSource = nil;
static NSArray<NSDictionary *> *gPromptChunkCache = nil;

static NSString *PromptFilePath(void) {
    static NSString *path = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *base = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
        NSString *directory = [base stringByAppendingPathComponent:@"ClaudeMini"];
        [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
        path = [directory stringByAppendingPathComponent:@"system-instructions.txt"];
    });
    return path;
}

static NSString *TodayKey(void) {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.timeZone = [NSTimeZone localTimeZone];
    formatter.dateFormat = @"yyyy-MM-dd";
    return [formatter stringFromDate:[NSDate date]];
}

static NSArray<NSDictionary *> *PromptChunkRecords(NSString *prompt) {
    @synchronized ([AppSettings class]) {
        if (gPromptChunkCache && gPromptChunkSource == prompt) return gPromptChunkCache;
    }

    NSMutableArray<NSDictionary *> *records = [NSMutableArray array];
    NSArray<NSString *> *paragraphs = [prompt componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSMutableString *current = [NSMutableString string];
    const NSUInteger maxChunk = 2400;
    void (^appendChunk)(NSString *) = ^(NSString *piece) {
        if (piece.length == 0) return;
        NSString *copy = [piece copy];
        [records addObject:@{@"text": copy, @"lower": copy.lowercaseString, @"length": @(copy.length)}];
    };

    for (NSString *line in paragraphs) {
        NSString *piece = line ?: @"";
        if (current.length > 0 && current.length + piece.length + 1 > maxChunk) {
            appendChunk(current);
            [current setString:@""];
        }
        while (piece.length > maxChunk) {
            NSRange safe = [piece rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, maxChunk)];
            appendChunk([piece substringWithRange:safe]);
            piece = [piece substringFromIndex:NSMaxRange(safe)];
        }
        if (piece.length > 0) {
            if (current.length > 0) [current appendString:@"\n"];
            [current appendString:piece];
        }
    }
    appendChunk(current);

    NSArray *result = [records copy];
    @synchronized ([AppSettings class]) {
        gPromptChunkSource = prompt;
        gPromptChunkCache = result;
    }
    return result;
}

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
    @synchronized ([AppSettings class]) {
        if (gPromptTextCacheLoaded) return gPromptTextCache ?: @"";
        NSString *path = PromptFilePath();
        NSString *fromFile = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        if (fromFile.length > 0) {
            gPromptTextCache = [[self cleanedPrompt:fromFile] copy];
        } else {
            // Migrate prompts saved by versions that stored the whole string in NSUserDefaults.
            NSString *legacy = [[NSUserDefaults standardUserDefaults] stringForKey:kSystemPromptKey];
            if (legacy.length > 0) {
                gPromptTextCache = [[self cleanedPrompt:legacy] copy];
                [gPromptTextCache writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
                [[NSUserDefaults standardUserDefaults] removeObjectForKey:kSystemPromptKey];
            } else {
                gPromptTextCache = @"";
            }
        }
        gPromptTextCacheLoaded = YES;
        return gPromptTextCache ?: @"";
    }
}

+ (void)setSystemPrompt:(NSString *)prompt {
    NSString *cleaned = [self cleanedPrompt:prompt];
    @synchronized ([AppSettings class]) {
        gPromptTextCache = [cleaned copy];
        gPromptTextCacheLoaded = YES;
        gPromptChunkSource = nil;
        gPromptChunkCache = nil;
    }
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (cleaned.length == 0) {
        [[NSFileManager defaultManager] removeItemAtPath:PromptFilePath() error:nil];
        [defaults removeObjectForKey:kSystemPromptKey];
    } else {
        NSError *error = nil;
        BOOL saved = [cleaned writeToFile:PromptFilePath() atomically:YES encoding:NSUTF8StringEncoding error:&error];
        if (saved) [defaults removeObjectForKey:kSystemPromptKey];
        else [defaults setObject:cleaned forKey:kSystemPromptKey];
    }
    [defaults synchronize];
}

// Keep the full 1M-character instruction file locally, but send only relevant excerpts
// that fit the selected model's input window. This avoids oversized requests and 503s.
+ (NSString *)systemPromptForQuery:(NSString *)query characterBudget:(NSUInteger)budget {
    return [self promptText:[self systemPrompt] forQuery:query characterBudget:budget];
}

+ (NSString *)promptText:(NSString *)prompt forQuery:(NSString *)query characterBudget:(NSUInteger)budget {
    prompt = [prompt isKindOfClass:[NSString class]] ? prompt : @"";
    if (prompt.length > kMaxSystemPromptChars) prompt = [self cleanedPrompt:prompt];
    if (prompt.length == 0 || budget == 0) return @"";
    if (prompt.length <= budget) return prompt;

    NSArray<NSDictionary *> *chunks = PromptChunkRecords(prompt);
    if (chunks.count == 0) return @"";
    NSMutableArray<NSString *> *terms = [NSMutableArray array];
    NSCharacterSet *separators = [[NSCharacterSet alphanumericCharacterSet] invertedSet];
    static NSSet<NSString *> *stopWords;
    static dispatch_once_t stopWordsOnce;
    dispatch_once(&stopWordsOnce, ^{
        stopWords = [NSSet setWithArray:@[@"the", @"and", @"for", @"with", @"that", @"this", @"from", @"you", @"your", @"cua", @"cho", @"voi", @"mot", @"nhung", @"cac", @"hay", @"la", @"va", @"duoc", @"giup"]];
    });
    for (NSString *term in [[query lowercaseString] componentsSeparatedByCharactersInSet:separators]) {
        if (term.length >= 3 && ![stopWords containsObject:term] && ![terms containsObject:term]) [terms addObject:term];
        if (terms.count >= 32) break;
    }

    NSMutableIndexSet *selected = [NSMutableIndexSet indexSet];
    NSMutableArray<NSDictionary *> *ranked = [NSMutableArray array];
    NSUInteger reserve = MIN((NSUInteger)2400, MAX((NSUInteger)800, budget / 12));
    NSUInteger used = 0;

    // Keep opening instructions plus a small final section, then select relevant chunks.
    [selected addIndex:0];
    used = [chunks[0][@"length"] unsignedIntegerValue];
    if (chunks.count > 1) {
        NSUInteger lastLength = [chunks.lastObject[@"length"] unsignedIntegerValue];
        if (lastLength + used + 96 <= budget) {
            [selected addIndex:chunks.count - 1];
            used += lastLength + 2;
        }
    }

    for (NSUInteger i = 0; i < chunks.count; i++) {
        if ([selected containsIndex:i]) continue;
        NSString *lower = chunks[i][@"lower"];
        NSUInteger score = 0;
        for (NSString *term in terms) {
            if ([lower rangeOfString:term].location != NSNotFound) score += term.length >= 6 ? 3 : 1;
        }
        if (score > 0) [ranked addObject:@{@"index": @(i), @"score": @(score), @"length": chunks[i][@"length"]}];
    }
    [ranked sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSInteger sa = [a[@"score"] integerValue], sb = [b[@"score"] integerValue];
        if (sa != sb) return sa > sb ? NSOrderedAscending : NSOrderedDescending;
        return [a[@"index"] compare:b[@"index"]];
    }];

    NSUInteger target = budget > reserve ? budget - reserve : budget;
    for (NSDictionary *item in ranked) {
        NSUInteger index = [item[@"index"] unsignedIntegerValue];
        NSUInteger length = [item[@"length"] unsignedIntegerValue] + 2;
        if (used + length > target) continue;
        [selected addIndex:index];
        used += length;
    }

    // If the query has no useful overlap, fill the remaining budget from newest chunks backwards.
    if (terms.count == 0 || selected.count <= 2) {
        for (NSInteger i = (NSInteger)chunks.count - 2; i >= 1; i--) {
            if ([selected containsIndex:(NSUInteger)i]) continue;
            NSUInteger length = [chunks[(NSUInteger)i][@"length"] unsignedIntegerValue] + 2;
            if (used + length > budget) continue;
            [selected addIndex:(NSUInteger)i];
            used += length;
        }
    }

    NSMutableString *result = [NSMutableString stringWithString:@"[Relevant excerpts selected from the full locally saved instructions; omitted sections remain saved.]\n\n"];
    [selected enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        NSString *chunkText = chunks[idx][@"text"];
        if (result.length + chunkText.length + 2 > budget) return;
        [result appendString:chunkText];
        [result appendString:@"\n\n"];
    }];
    if (result.length > budget) {
        NSRange safe = [result rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, budget)];
        result = [[result substringWithRange:safe] mutableCopy];
    }
    return result;
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
}
+ (NSInteger)maxOutputTokens {
    NSInteger value = [[NSUserDefaults standardUserDefaults] integerForKey:kMaxOutputTokensKey];
    return (value == 2048 || value == 4096 || value == 8192 || value == 16384 || value == 32768 || value == 65536 || value == 128000) ? value : 8192;
}
+ (void)setMaxOutputTokens:(NSInteger)count {
    if (count != 2048 && count != 4096 && count != 8192 && count != 16384 && count != 32768 && count != 65536 && count != 128000) count = 8192;
    [[NSUserDefaults standardUserDefaults] setInteger:count forKey:kMaxOutputTokensKey];
}
+ (NSUInteger)contextLimitChars {
    NSInteger value = [[NSUserDefaults standardUserDefaults] integerForKey:kContextLimitCharsKey];
    return (value >= 1000 && value <= 1000000) ? (NSUInteger)value : 600000;
}
+ (void)setContextLimitChars:(NSUInteger)count {
    if (count < 1000 || count > 1000000) count = 600000;
    [[NSUserDefaults standardUserDefaults] setInteger:(NSInteger)count forKey:kContextLimitCharsKey];
}

+ (AIReasoningLevel)reasoningLevel {
    NSInteger value = [[NSUserDefaults standardUserDefaults] integerForKey:kReasoningLevelKey];
    return (value >= AIReasoningLevelLow && value <= AIReasoningLevelMax) ? (AIReasoningLevel)value : AIReasoningLevelMedium;
}
+ (void)setReasoningLevel:(AIReasoningLevel)level {
    if (level < AIReasoningLevelLow || level > AIReasoningLevelMax) level = AIReasoningLevelMedium;
    [[NSUserDefaults standardUserDefaults] setInteger:level forKey:kReasoningLevelKey];
}
+ (BOOL)fastModeEnabled { return [[NSUserDefaults standardUserDefaults] boolForKey:kFastModeKey]; }
+ (void)setFastModeEnabled:(BOOL)enabled { [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kFastModeKey]; }
+ (BOOL)webSearchEnabled { return [[NSUserDefaults standardUserDefaults] boolForKey:kWebSearchKey]; }
+ (void)setWebSearchEnabled:(BOOL)enabled { [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kWebSearchKey]; }

+ (long long)dailyTokenUsage {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *today = TodayKey();

    if (![[defaults stringForKey:kDailyDateKey] isEqualToString:today]) {
        [defaults setObject:today forKey:kDailyDateKey];
        [defaults setObject:@0 forKey:kDailyUsageKey];
        return 0;
    }

    id usageObject = [defaults objectForKey:kDailyUsageKey];
    return usageObject ? [usageObject longLongValue] : 0;
}

+ (void)addDailyTokenUsage:(long long)count {
    if (count <= 0) return;

    long long current = [self dailyTokenUsage];

    if (LLONG_MAX - current < count)
        current = LLONG_MAX;
    else
        current += count;

    [[NSUserDefaults standardUserDefaults] setObject:@(current) forKey:kDailyUsageKey];
}

+ (long long)dailyTokenBudget {
    id budgetObject = [[NSUserDefaults standardUserDefaults] objectForKey:kDailyBudgetKey];
    long long value = [budgetObject longLongValue];

    return value > 0 ? value : 27000000000LL;
}

+ (void)setDailyTokenBudget:(long long)count {
    if (count < 1) count = 27000000000LL;

    [[NSUserDefaults standardUserDefaults] setObject:@(count) forKey:kDailyBudgetKey];
}

@end
