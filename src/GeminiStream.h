#import <Foundation/Foundation.h>
#import "ChatStreaming.h"

// Google Gemini: streamGenerateContent (SSE) or generateContent.
@interface GeminiStream : NSObject <ChatStreaming>

- (instancetype)initWithKey:(NSString *)key model:(NSString *)model turns:(NSArray *)turns system:(NSString *)system;

@property (assign, nonatomic) BOOL useStreaming;
@property (copy, nonatomic) void (^onDelta)(NSString *text);
@property (copy, nonatomic) void (^onImage)(NSData *data, NSString *mimeType);
@property (copy, nonatomic) void (^onUsage)(long long inputTokens, long long outputTokens);
@property (copy, nonatomic) void (^onFinish)(GeminiStreamError error, NSInteger httpStatus, NSString *detail);

- (void)start;
- (void)cancel;

@end
