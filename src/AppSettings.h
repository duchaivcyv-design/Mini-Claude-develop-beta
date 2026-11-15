#import <Foundation/Foundation.h>

extern const NSUInteger kMaxSystemPromptChars;

typedef NS_ENUM(NSInteger, AIReasoningLevel) {
    AIReasoningLevelLow = 0,
    AIReasoningLevelMedium,
    AIReasoningLevelHigh,
    AIReasoningLevelVeryHigh,
    AIReasoningLevelMax
};

@interface AppSettings : NSObject

+ (NSString *)systemPrompt;
+ (void)setSystemPrompt:(NSString *)prompt;
+ (NSString *)cleanedPrompt:(NSString *)text;
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

@end
