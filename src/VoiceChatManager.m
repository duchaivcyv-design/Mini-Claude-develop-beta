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
@property (copy, nonatomic) void (^speakCompletionBlock)(void);
@property (strong, nonatomic) AVSpeechSynthesizer *synthesizer;
@property (assign, nonatomic) BOOL recording;
@property (assign, nonatomic) NSInteger currentVoiceIndex;
@property (assign, nonatomic) BOOL manualVoiceSelection;
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
            _recognizer = [[SFSpeechRecognizer alloc] initWithLocale:[NSLocale currentLocale]];
        }
        if (_recognizer) {
            _recognizer.delegate = self;
        }
        _engine = [[AVAudioEngine alloc] init];
        _synthesizer = [[AVSpeechSynthesizer alloc] init];
        _synthesizer.delegate = self;
        _currentVoiceIndex = 0;
        _manualVoiceSelection = NO;
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
    [self stopSpeaking];
    self.partialBlock = partial;
    self.finalBlock = final;
    self.errorBlock = error;

    NSError *sessionError = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryPlayAndRecord
                    mode:AVAudioSessionModeMeasurement
                 options:AVAudioSessionCategoryOptionDefaultToSpeaker | AVAudioSessionCategoryOptionAllowBluetooth
                   error:&sessionError];
    [session setActive:YES withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:&sessionError];

    if (!self.engine) {
        self.engine = [[AVAudioEngine alloc] init];
    }

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
    @try {
        [node removeTapOnBus:0];
    } @catch (__unused NSException *ex) {}
    [node installTapOnBus:0 bufferSize:1024 format:nil block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
        [weakSelf.request appendAudioPCMBuffer:buffer];
    }];

    [self.engine prepare];
    NSError *startError = nil;
    if (![self.engine startAndReturnError:&startError]) {
        @try {
            [node removeTapOnBus:0];
        } @catch (__unused NSException *ex) {}
        self.recording = NO;
        if (error) error(startError.localizedDescription ?: @"Không khởi động được ghi âm.");
        return;
    }
    self.recording = YES;
}

- (void)stopRecording {
    self.recording = NO;
    if (self.engine.isRunning) {
        [self.engine stop];
    }
    @try {
        [self.engine.inputNode removeTapOnBus:0];
    } @catch (__unused NSException *ex) {}
    [self.request endAudio];
    [self.task cancel];
    self.task = nil;
    self.request = nil;
}

#pragma mark - Đọc văn bản AI bằng giọng nói (TTS)

- (void)activatePlaybackSession {
    NSError *err = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    AVAudioSessionCategoryOptions opts = AVAudioSessionCategoryOptionDefaultToSpeaker |
                                     AVAudioSessionCategoryOptionAllowBluetooth;
    [session setCategory:AVAudioSessionCategoryPlayAndRecord
                    mode:AVAudioSessionModeSpokenAudio
                 options:opts
                   error:&err];
    [session setActive:YES withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:&err];
}

- (NSString *)cleanTextForSpeech:(NSString *)raw {
    if (raw.length == 0) return @"";
    NSString *cleaned = raw;
    NSError *regexError = nil;
    NSRegularExpression *codeBlockRegex = [NSRegularExpression regularExpressionWithPattern:@"```[\\s\\S]*?```" options:0 error:&regexError];
    if (codeBlockRegex) {
        cleaned = [codeBlockRegex stringByReplacingMatchesInString:cleaned options:0 range:NSMakeRange(0, cleaned.length) withTemplate:@" Đoạn mã nguồn. "];
    }
    NSRegularExpression *mdSymRegex = [NSRegularExpression regularExpressionWithPattern:@"[#*_`~>]+" options:0 error:&regexError];
    if (mdSymRegex) {
        cleaned = [mdSymRegex stringByReplacingMatchesInString:cleaned options:0 range:NSMakeRange(0, cleaned.length) withTemplate:@" "];
    }
    cleaned = [cleaned stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (cleaned.length > 4000) {
        NSRange r = [cleaned rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, 4000)];
        cleaned = [[cleaned substringWithRange:r] stringByAppendingString:@"... Hết phần tóm tắt."];
    }
    return cleaned;
}

- (void)speak:(NSString *)text voiceIndex:(NSInteger)voiceIndex completion:(void (^)(void))completion {
    NSString *spoken = [self cleanTextForSpeech:text];
    if (spoken.length == 0) {
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), completion);
        }
        return;
    }

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        VoiceChatManager *me = weakSelf;
        if (!me) return;
        [me stopRecording];
        [me stopSpeaking];
        [me activatePlaybackSession];

        me.speakCompletionBlock = completion;
        NSInteger idx = ((voiceIndex % 3) + 3) % 3;

        if (!me.synthesizer) {
            me.synthesizer = [[AVSpeechSynthesizer alloc] init];
            me.synthesizer.delegate = me;
        }

        AVSpeechUtterance *utter = [[AVSpeechUtterance alloc] initWithString:spoken];
        NSArray<AVSpeechSynthesisVoice *> *voices = [AVSpeechSynthesisVoice speechVoices];
        NSMutableArray<AVSpeechSynthesisVoice *> *viVoices = [NSMutableArray array];
        for (AVSpeechSynthesisVoice *v in voices) {
            if ([v.language hasPrefix:@"vi"]) [viVoices addObject:v];
        }
        if (viVoices.count > 0) {
            utter.voice = viVoices[(NSUInteger)idx % viVoices.count];
        } else {
            utter.voice = [AVSpeechSynthesisVoice voiceWithLanguage:@"vi-VN"] ?: [AVSpeechSynthesisVoice voiceWithLanguage:@"en-US"];
        }

        switch (idx) {
            case 0:
                utter.rate = AVSpeechUtteranceDefaultSpeechRate * 1.02;
                utter.pitchMultiplier = 1.12;
                break;
            case 1:
                utter.rate = AVSpeechUtteranceDefaultSpeechRate * 0.94;
                utter.pitchMultiplier = 0.80;
                break;
            default:
                utter.rate = AVSpeechUtteranceDefaultSpeechRate * 1.10;
                utter.pitchMultiplier = 1.25;
                break;
        }

        [me.synthesizer speakUtterance:utter];
    });
}

- (void)speak:(NSString *)text completion:(void (^)(void))completion {
    NSInteger idx = self.currentVoiceIndex;
    if (!self.manualVoiceSelection) {
        self.currentVoiceIndex = (self.currentVoiceIndex + 1) % 3;
    }
    [self speak:text voiceIndex:idx completion:completion];
}

- (void)speak:(NSString *)text {
    [self speak:text completion:nil];
}

- (void)stopSpeaking {
    if (self.synthesizer.isSpeaking) {
        [self.synthesizer stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
    }
    self.speakCompletionBlock = nil;
}

#pragma mark - AVSpeechSynthesizerDelegate

- (void)speechSynthesizer:(AVSpeechSynthesizer *)synthesizer didFinishSpeechUtterance:(AVSpeechUtterance *)utterance {
    void (^done)(void) = self.speakCompletionBlock;
    self.speakCompletionBlock = nil;
    if (done) {
        dispatch_async(dispatch_get_main_queue(), done);
    }
}

- (void)speechSynthesizer:(AVSpeechSynthesizer *)synthesizer didCancelSpeechUtterance:(AVSpeechUtterance *)utterance {
    void (^done)(void) = self.speakCompletionBlock;
    self.speakCompletionBlock = nil;
    if (done) {
        dispatch_async(dispatch_get_main_queue(), done);
    }
}

- (void)speechRecognizer:(SFSpeechRecognizer *)recognizer availabilityDidChange:(BOOL)available {
    if (!available && self.recording) {
        [self stopRecording];
    }
}

@end
