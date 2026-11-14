#import <Foundation/Foundation.h>

extern const NSUInteger kMaxSystemPromptChars;

typedef NS_ENUM(NSInteger, AIReasoningLevel) {
    AIReasoningLevelLow = 0,
    AIReasoningLevelMedium,
    AIReasoningLevelHigh,
    AIReasoningLevelVeryHigh,
    AIReasoningLevelMax
};

// Small app-wide preferences.
@interface AppSettings : NSObject

+ (NSString *)systemPrompt;                       // the general instructions; @"" when none is set
+ (void)setSystemPrompt:(NSString *)prompt;       // cleaned (see cleanedPrompt:)
+ (NSString *)cleanedPrompt:(NSString *)text;     // trimmed and cut to kMaxSystemPromptChars

// How many recent messages carrying photos/video frames/PDFs are re-sent with each request: 1, 3, or 0 for all.
// (The model only "sees" an attachment in the request that contains it, so older ones must be re-sent to stay visible.)
+ (NSInteger)attachmentMemory;                    // default 3
+ (void)setAttachmentMemory:(NSInteger)count;

// Provider output budget (2,048–128,000 tokens). The actual request is clamped to each model's API-reported cap.
+ (NSInteger)maxOutputTokens;
+ (void)setMaxOutputTokens:(NSInteger)count;

// Maximum text retained from the conversation when building a request (characters).
+ (NSUInteger)contextLimitChars;
+ (void)setContextLimitChars:(NSUInteger)count;

// Requested reasoning intensity. Providers/models may support only a subset.
+ (AIReasoningLevel)reasoningLevel;
+ (void)setReasoningLevel:(AIReasoningLevel)level;

@end
