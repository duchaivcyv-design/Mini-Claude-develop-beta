#import "VoiceChatManager.h"
#import <Speech/Speech.h>
#import <AVFoundation/AVFoundation.h>

@interface VoiceChatManager () <SFSpeechRecognizerDelegate, AVSpeechSynthesizerDelegate>
@property (strong, nonatomic) SFSpeechRecognizer *recognizer;
@property (strong, nonatomic) SFSpeechAudioBufferRecognitionRequest *request;
@property (strong, nonatomic) SFSpeechRecognitionTask *task;
@property (strong, nonatomic) AVAudioEngine *engine;
@property (copy, nonatomic) void (^partialBlock)(NSString *);
@property (copy, nonatomic) void (^finalBlock)(NSString *);
@property (copy, nonatomic) void (^errorBlock)(NSString *);
@property (strong, nonatomic) AVSpeechSynthesizer *synthesizer;
@property (assign, nonatomic) BOOL recording;
@property (assign, nonatomic) NSInteger currentVoiceIndex; // Dùng để xoay vòng 3 giọng nói AI khác nhau
@end

@implementation VoiceChatManager

+ (instancetype)shared {
    static VoiceChatManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[VoiceChatManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    if (self = [super init]) {
        NSLocale *vi = [[NSLocale alloc] initWithLocaleIdentifier:@"vi-VN"];
        _recognizer = [[SFSpeechRecognizer alloc] initWithLocale:vi];
        if (!_recognizer) {
            _recognizer = [[SFSpeechRecognizer alloc] initWithLocale:[NSLocale currentLocale]]; // fallback
        }
        if (_recognizer) {
            _recognizer.delegate = self;
        }
        _engine = [[AVAudioEngine alloc] init];
        _synthesizer = [[AVSpeechSynthesizer alloc] init];
        _synthesizer.delegate = self;
        _currentVoiceIndex = 0;
    }
    return self;
}

- (void)requestAuthorization:(void (^)(BOOL granted))completion {
    [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status) {
        BOOL speechOK = (status == SFSpeechRecognizerAuthorizationStatusAuthorized);
        [[AVAudioSession sharedInstance] requestRecordPermission:^(BOOL micOK) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(speechOK && micOK);
            });
        }];
    }];
}

- (BOOL)isRecording {
    return self.recording;
}

- (BOOL)isSpeaking {
    return self.synthesizer.isSpeaking;
}

#pragma mark - Ghi âm & Nhận dạng giọng nói (STT)

- (void)startRecordingWithPartial:(void (^)(NSString *text))partial
                            final:(void (^)(NSString *text))final
                            error:(void (^)(NSString *message))error {
    if (self.recording) {
        if (error) error(@"Đang ghi âm rồi.");
        return;
    }
    self.partialBlock = partial;
    self.finalBlock = final;
    self.errorBlock = error;

    NSError *sessionError = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryPlayAndRecord
             withOptions:AVAudioSessionCategoryOptionDefaultToSpeaker | AVAudioSessionCategoryOptionAllowBluetooth
                   error:&sessionError];
    [session setActive:YES error:&sessionError];

    self.request = [[SFSpeechAudioBufferRecognitionRequest alloc] init];
    self.request.shouldReportPartialResults = YES;
    if (@available(iOS 13, *)) {
        self.request.requiresOnDeviceRecognition = NO;
    }

    __weak typeof(self) weakSelf = self;
    self.task = [self.recognizer recognitionTaskWithRequest:self.request resultHandler:^(SFSpeechRecognitionResult *result, NSError *err) {
        VoiceChatManager *me = weakSelf;
        if (!me) return;
        BOOL isFinal = (result != nil && result.isFinal);
        if (result) {
            NSString *text = result.bestTranscription.formattedString ?: @"";
            if (isFinal) {
                if (me.finalBlock) me.finalBlock(text);
            } else {
                if (me.partialBlock) me.partialBlock(text);
            }
        }
        if (err || isFinal) {
            [me stopRecording];
            if (err && !isFinal && me.errorBlock) {
                me.errorBlock(err.localizedDescription ?: @"Lỗi nhận dạng giọng nói.");
            }
        }
    }];

    AVAudioInputNode *node = self.engine.inputNode;
    AVAudioFormat *format = [node outputFormatForBus:0];
    [node installTapOnBus:0 bufferSize:1024 format:format block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
        [weakSelf.request appendAudioPCMBuffer:buffer];
    }];
    
    [self.engine prepare];
    NSError *startError = nil;
    if (![self.engine startAndReturnError:&startError]) {
        [node removeTapOnBus:0];
        self.recording = NO;
        if (error) error(startError.localizedDescription ?: @"Không khởi động được ghi âm.");
        return;
    }
    self.recording = YES;
}

- (void)stopRecording {
    if (self.engine.isRunning) {
        [self.engine stop];
    }
    [self.engine.inputNode removeTapOnBus:0];
    [self.request endAudio];
    [self.task cancel];
    self.task = nil;
    self.request = nil;
    self.recording = NO;
    [[AVAudioSession sharedInstance] setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
}

#pragma mark - Đọc văn bản AI bằng giọng nói (TTS) với 3 phong cách

- (void)speak:(NSString *)text {
    if (text.length == 0) return;
    [self stopSpeaking];

    AVSpeechUtterance *utter = [[AVSpeechUtterance alloc] initWithString:text];
    
    // Lấy giọng tiếng Việt hệ thống
    NSArray<AVSpeechSynthesisVoice *> *voices = [AVSpeechSynthesisVoice speechVoices];
    AVSpeechSynthesisVoice *selectedVoice = nil;
    for (AVSpeechSynthesisVoice *v in voices) {
        if ([v.language hasPrefix:@"vi"]) {
            selectedVoice = v;
            break;
        }
    }
    utter.voice = selectedVoice ?: [AVSpeechSynthesisVoice voiceWithLanguage:@"vi-VN"] ?: [AVSpeechSynthesisVoice voiceWithLanguage:@"en-US"];

    // Xoay vòng tự động qua 3 phong cách giọng nói AI khác nhau
    // 0: Giọng nữ tự nhiên (Sáng, mượt mà)
    // 1: Giọng nam trầm ấm (Trầm, truyền cảm)
    // 2: Giọng hoạt bát/biểu cảm (Tốc độ nhanh, cao độ linh hoạt)
    switch (self.currentVoiceIndex % 3) {
        case 0:
            utter.rate = AVSpeechUtteranceDefaultSpeechRate * 1.02;
            utter.pitchMultiplier = 1.1;
            break;
        case 1:
            utter.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95;
            utter.pitchMultiplier = 0.82;
            break;
        case 2:
            utter.rate = AVSpeechUtteranceDefaultSpeechRate * 1.08;
            utter.pitchMultiplier = 1.25;
            break;
    }
    
    // Tăng chỉ số để lần gọi `speak:` tiếp theo đổi sang giọng khác
    self.currentVoiceIndex = (self.currentVoiceIndex + 1) % 3;

    [self.synthesizer speakUtterance:utter];
}

- (void)stopSpeaking {
    if (self.synthesizer.isSpeaking) {
        [self.synthesizer stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
    }
}

- (void)speechRecognizer:(SFSpeechRecognizer *)recognizer availabilityDidChange:(BOOL)available {
    if (!available && self.recording) {
        [self stopRecording];
    }
}

@end
