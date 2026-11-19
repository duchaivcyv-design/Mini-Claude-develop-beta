#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Chat bằng giọng nói: ghi âm -> văn bản (Speech, locale vi-VN) và đọc lời trả lời của AI bằng giọng nói (TTS).
@interface VoiceChatManager : NSObject

+ (instancetype)shared;

- (void)requestAuthorization:(void (^)(BOOL granted))completion;

// Bắt đầu ghi âm. partial được gọi liên tục với văn bản tạm thời; final được gọi 1 lần khi dừng.
- (void)startRecordingWithPartial:(void (^ _Nullable)(NSString *text))partial
                            final:(void (^ _Nullable)(NSString *text))final
                            error:(void (^ _Nullable)(NSString *message))error;
- (void)stopRecording;
- (BOOL)isRecording;

- (void)speak:(NSString *)text;        // đọc văn bản bằng giọng nói (tiếng Việt)
- (void)speak:(NSString *)text completion:(void (^ _Nullable)(void))completion;
- (void)speak:(NSString *)text voiceIndex:(NSInteger)voiceIndex completion:(void (^ _Nullable)(void))completion;
- (void)stopSpeaking;
- (BOOL)isSpeaking;

@end

NS_ASSUME_NONNULL_END
