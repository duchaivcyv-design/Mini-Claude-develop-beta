#import <Foundation/Foundation.h>

// Chat bằng giọng nói: ghi âm -> văn bản (Speech, locale vi-VN) và đọc lời trả lời của AI bằng giọng nói (TTS).
@interface VoiceChatManager : NSObject

+ (instancetype)shared;

- (void)requestAuthorization:(void (^)(BOOL granted))completion;

// Bắt đầu ghi âm. partial được gọi liên tục với văn bản tạm thời; final được gọi 1 lần khi dừng.
- (void)startRecordingWithPartial:(void (^)(NSString *text))partial
                            final:(void (^)(NSString *text))final
                            error:(void (^)(NSString *message))error;
- (void)stopRecording;
- (BOOL)isRecording;

- (void)speak:(NSString *)text;        // đọc văn bản bằng giọng nói (tiếng Việt)
- (void)stopSpeaking;
- (BOOL)isSpeaking;

@end
