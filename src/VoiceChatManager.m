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
@property (assign, nonatomic) VoiceStyle selectedVoiceStyle;
@end

@implementation VoiceChatManager

+ (instancetype)shared {
    static VoiceChatManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[VoiceChatManager alloc] init]; });
    return instance;
}

- (instancetype)init {
    if (self = [super init]) {
        NSLocale *vi = [[NSLocale alloc] initWithLocaleIdentifier:@"vi-VN"];
        _recognizer = [[SFSpeechRecognizer alloc] initWithLocale:vi];
        if (!_recognizer) _recognizer = [[SFSpeechRecognizer alloc] initWithLocale:[NSLocale currentLocale]]; // fallback
        if (_recognizer) _recognizer.delegate = self;
        _engine = [[AVAudioEngine alloc] init];
        _synthesizer = [[AVSpeechSynthesizer alloc] init];
        _synthesizer.delegate = self;
        _selectedVoiceStyle = VoiceStyleNaturalFemale; // Mặc định giọng nữ tự nhiên
    }
    return self;
}

- (void)requestAuthorization:(void (^)(BOOL))completion {
    [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status) {
        BOOL speechOK = (status == SFSpeechRecognizerAuthorizationStatusAuthorized);
        [[AVAudioSession sharedInstance] requestRecordPermission:^(BOOL micOK) {
            dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(speechOK && micOK); });
        }];
    }];
}

- (BOOL)isRecording { return self.recording; }
- (BOOL)isSpeaking { return self.synthesizer.isSpeaking; }

#pragma mark - Voice Selection (3 Giọng nói AI thật)

- (void)setVoiceStyle:(VoiceStyle)style {
    _selectedVoiceStyle = style;
}

- (AVSpeechSynthesisVoice *)selectedVoice {
    NSArray<AVSpeechSynthesisVoice *> *voices = [AVSpeechSynthesisVoice speechVoices];
    AVSpeechSynthesisVoice *fallbackVi = [AVSpeechSynthesisVoice voiceWithLanguage:@"vi-VN"];
    
    // Lọc các giọng tiếng Việt có sẵn trên hệ thống iOS (nếu có chất lượng cao / enhanced)
    NSMutableArray<AVSpeechSynthesisVoice *> *vietnameseVoices = [NSMutableArray array];
    for (AVSpeechSynthesisVoice *v in voices) {
        if ([v.language hasPrefix:@"vi"]) {
            [vietnameseVoices addObject:v];
        }
    }
    
    switch (self.selectedVoiceStyle) {
        case VoiceStyleNaturalFemale: {
            // Ưu tiên tìm giọng nữ tiếng Việt hoặc giọng Siri/Enhanced
            for (AVSpeechSynthesisVoice *v in vietnameseVoices) {
                if ([v.identifier containsString:@"female"] || [v.name containsString:@"Nam"] == NO) {
                    return v;
                }
            }
            return fallbackVi ?: [AVSpeechSynthesisVoice voiceWithLanguage:@"en-US"];
        }
        case VoiceStyleDeepMale: {
            // Ưu tiên tìm giọng nam trầm/ấm
            for (AVSpeechSynthesisVoice *v in vietnameseVoices) {
                if ([v.identifier containsString:@"male"] || [v.name containsString:@"Nam"] || [v.name containsString:@"HoaiMy"] == NO) {
                    return v;
                }
            }
            return fallbackVi;
        }
        case VoiceStyleExpressiveBot: {
            // Giọng biểu cảm cao / Hoặc fallback sang en-US cao cấp nếu tiếng Việt ít lựa chọn
            return vietnameseVoices.lastObject ?: fallbackVi;
        }
    }
    return fallbackVi;
}

#pragma mark - Recording

- (void)startRecordingWithPartial:(void (^)(NSString *))partial final:(void (^)(NSString *))final error:(void (^)(NSString *))error {
    if (self.recording) { if (error) error(@"Đang ghi âm rồi."); return; }
    self.partialBlock = partial; self.finalBlock = final; self.errorBlock = error;

    NSError *sessionError = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryPlayAndRecord withOptions:AVAudioSessionCategoryOptionDefaultToSpeaker | AVAudioSessionCategoryOptionAllowBluetooth error:&sessionError];
    [session setActive:YES error:&sessionError];

    self.request = [[SFSpeechAudioBufferRecognitionRequest alloc] init];
    self.request.shouldReportPartialResults = YES;
    if (@available(iOS 13, *)) self.request.requiresOnDeviceRecognition = NO;

    __weak typeof(self) weakSelf = self;
    self.task = [self.recognizer recognitionTaskWithRequest:self.request resultHandler:^(SFSpeechRecognitionResult *result, NSError *err) {
        VoiceChatManager *me = weakSelf; if (!me) return;
        BOOL isFinalResult = (result != nil && result.isFinal);
        if (result) {
            NSString *text = result.bestTranscription.formattedString ?: @"";
            if (isFinalResult) { if (me.finalBlock) me.finalBlock(text); }
            else { if (me.partialBlock) me.partialBlock(text); }
        }
        if (err || isFinalResult) {
            [me stopRecording];
            if (err && !isFinalResult && me.errorBlock) me.errorBlock(err.localizedDescription ?: @"Lỗi nhận dạng giọng nói.");
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
    if (self.engine.isRunning) [self.engine stop];
    [self.engine.inputNode removeTapOnBus:0];
    [self.request endAudio];
    [self.task cancel];
    self.task = nil; self.request = nil;
    self.recording = NO;
    [[AVAudioSession sharedInstance] setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
}

#pragma mark - Speech Synthesis (Text to Speech với 3 phong cách)

- (void)speak:(NSString *)text {
    if (text.length == 0) return;
    [self stopSpeaking];
    
    AVSpeechUtterance *utter = [[AVSpeechUtterance alloc] initWithString:text];
    utter.voice = [self selectedVoice];
    
    // Tùy chỉnh ngữ điệu, tốc độ theo từng phong cách giọng nói AI thật
    switch (self.selectedVoiceStyle) {
        case VoiceStyleNaturalFemale:
            utter.rate = AVSpeechUtteranceDefaultSpeechRate * 1.02;
            utter.pitchMultiplier = 1.1; // Tone sáng, tự nhiên
            break;
        case VoiceStyleDeepMale:
            utter.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95;
            utter.pitchMultiplier = 0.82; // Tone trầm ấm, nam tính
            break;
        case VoiceStyleExpressiveBot:
            utter.rate = AVSpeechUtteranceDefaultSpeechRate * 1.08;
            utter.pitchMultiplier = 1.25; // Nhanh hoạt bát, biểu cảm
            break;
    }
    
    [self.synthesizer speakUtterance:utter];
}

- (void)stopSpeaking {
    if (self.synthesizer.isSpeaking) [self.synthesizer stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
}

- (void)speechRecognizer:(SFSpeechRecognizer *)recognizer availabilityDidChange:(BOOL)available {
    if (!available && self.recording) [self stopRecording];
}

@end
