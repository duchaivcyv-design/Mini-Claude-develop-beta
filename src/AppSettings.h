#import <Foundation/Foundation.h>

extern const NSUInteger kMaxSystemPromptChars;

// Small app-wide preferences.
@interface AppSettings : NSObject

+ (NSString *)systemPrompt;                       // the general instructions; @"" when none is set
+ (void)setSystemPrompt:(NSString *)prompt;       // cleaned (see cleanedPrompt:)
+ (NSString *)cleanedPrompt:(NSString *)text;     // trimmed and cut to kMaxSystemPromptChars

// How many of the most recent messages that carry photos/PDFs are sent again with each request: 1, 3, or 0 for all.
// (The model only "sees" an attachment in the request that contains it, so older ones must be re-sent to stay visible.)
+ (NSInteger)attachmentMemory;                    // default 3
+ (void)setAttachmentMemory:(NSInteger)count;

@end
