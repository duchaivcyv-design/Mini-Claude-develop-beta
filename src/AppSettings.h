#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, AIReasoningLevel) {
    AIReasoningLevelLow = 0,
    AIReasoningLevelMedium,
    AIReasoningLevelHigh,
    AIReasoningLevelUltra,
    AIReasoningLevelMax
};

@interface AppSettings : NSObject

+ (NSString *)cleanedPrompt:(NSString *)text;
+ (NSString *)systemPrompt;
+ (void)setSystemPrompt:(NSString *)prompt;

+ (NSString *)systemPromptForQuery:(NSString *)query characterBudget:(NSUInteger)budget;
+ (NSString *)promptText:(NSString *)prompt forQuery:(NSString *)query characterBudget:(NSUInteger)budget;

+ (NSInteger)attachmentMemory;
+ (void)setAttachmentMemory:(NSInteger)count;

+ (NSInteger)maxOutputTokens;
+ (void)setMaxOutputTokens:(NSInteger)count;

+ (NSUInteger)contextLimitChars;
+ (void)setContextLimitChars:(NSUInteger)count;

+ (AIReasoningLevel)reasoningLevel;
+ (void)setReasoningLevel:(AIReasoningLevel)level;

+ (BOOL)fastModeEnabled;
+ (void)setFastModeEnabled:(BOOL)enabled;

+ (BOOL)webSearchEnabled;
+ (void)setWebSearchEnabled:(BOOL)enabled;

+ (long long)dailyTokenUsage;
+ (void)addDailyTokenUsage:(long long)count;
+ (long long)dailyTokenBudget;
+ (void)setDailyTokenBudget:(long long)count;

// Khai báo quản lý hạn mức tuần (1T)
+ (long long)weeklyTokenUsage;
+ (long long)weeklyTokenBudget;
+ (BOOL)isWeeklyBudgetExhausted;
+ (CGFloat)weeklyUsagePercentage;

@end

NS_ASSUME_NONNULL_END

