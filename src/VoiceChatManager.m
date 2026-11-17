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
        BOOL final = (result != nil && result.isFinal);
        if (result) {
            NSString *text = result.bestTranscription.formattedString ?: @"";
            if (final) { if (me.finalBlock) me.finalBlock(text); }
            else { if (me.partialBlock) me.partialBlock(text); }
        }
        if (err || final) {
            [me stopRecording];
            if (err && !final && me.errorBlock) me.errorBlock(err.localizedDescription ?: @"Lỗi nhận dạng giọng nói.");
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

- (void)speak:(NSString *)text {
    if (text.length == 0) return;
    [self stopSpeaking];
    AVSpeechUtterance *utter = [[AVSpeechUtterance alloc] initWithString:text];
    utter.voice = [AVSpeechSynthesisVoice voiceWithLanguage:@"vi-VN"] ?: [AVSpeechSynthesisVoice voiceWithLanguage:@"en-US"];
    utter.rate = AVSpeechUtteranceDefaultSpeechRate * 1.02;
    utter.pitchMultiplier = 1.0;
    [self.synthesizer speakUtterance:utter];
}

- (void)stopSpeaking {
    if (self.synthesizer.isSpeaking) [self.synthesizer stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
}

- (void)speechRecognizer:(SFSpeechRecognizer *)recognizer availabilityDidChange:(BOOL)available {
    if (!available && self.recording) [self stopRecording];
}

@end
