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

// Thu nhỏ / phóng to chữ & giao diện (0.85 = nhỏ, 1.0 = mặc định, 1.15 = lớn). Áp dụng cho tin nhắn và ô nhập.
+ (CGFloat)uiScale;
+ (void)setUiScale:(CGFloat)scale;

// Tự đọc lời trả lời của AI bằng giọng nói (TTS) sau khi nhận được tin nhắn.
+ (BOOL)voiceAutoPlayEnabled;
+ (void)setVoiceAutoPlayEnabled:(BOOL)enabled;

+ (long long)dailyTokenUsage;
+ (void)addDailyTokenUsage:(long long)count;
+ (long long)dailyTokenBudget;
+ (void)setDailyTokenBudget:(long long)count;

@end
