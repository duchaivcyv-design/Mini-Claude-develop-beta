#import <Foundation/Foundation.h>
#import "ChatStreaming.h"

// Anthropic Claude: POST /v1/messages, as a live stream (SSE) or a single request.
@interface ClaudeStream : NSObject <ChatStreaming>

- (instancetype)initWithKey:(NSString *)key model:(NSString *)model turns:(NSArray *)turns system:(NSString *)system;

@property (assign, nonatomic) BOOL useStreaming;
@property (copy, nonatomic) void (^onDelta)(NSString *text);
@property (copy, nonatomic) void (^onFinish)(GeminiStreamError error, NSInteger httpStatus, NSString *detail);

- (void)start;
- (void)cancel;

@end
