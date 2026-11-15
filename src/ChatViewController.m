#import "ChatViewController.h"
#import <WebKit/WebKit.h>
#import "Strings.h"
#import "Theme.h"
#import "KeyStore.h"
#import "GeminiClient.h"
#import "GeminiStream.h"
#import "ClaudeClient.h"
#import "ClaudeStream.h"
#import "ChatStreaming.h"
#import "Provider.h"
#import "AppSettings.h"
#import "ImageViewerViewController.h"
#import "DiagnosticLog.h"
#import "ModelStore.h"
#import "ConversationStore.h"
#import "AttachmentStore.h"
#import "HistoryViewController.h"
#import "ModelPickerViewController.h"
#import "OfficeExport.h"
#import <math.h>

static const CGFloat kMaxInputHeight = 120;
static const CGFloat kStripHeight = 64;               // chip row above the text box (56 pt chips + spacing)
static const CGFloat kToolsRowHeight = 34;
static const NSUInteger kGreetingCount = 6;           // how many different lines can appear under the greeting

#pragma mark - Weak script handler (WKUserContentController retains its handlers)

@protocol ScriptMessageTarget <NSObject>
- (void)handleScriptMessage:(WKScriptMessage *)message;
@end

@interface WeakScriptHandler : NSObject <WKScriptMessageHandler>
@property (weak, nonatomic) id<ScriptMessageTarget> target;
- (instancetype)initWithTarget:(id<ScriptMessageTarget>)target;
@end

@implementation WeakScriptHandler
- (instancetype)initWithTarget:(id<ScriptMessageTarget>)target {
    self = [super init];
    if (self) _target = target;
    return self;
}
- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message {
    [self.target handleScriptMessage:message];
}
@end

static NSString *StreamErrorName(GeminiStreamError error) {
    switch (error) {
        case GeminiStreamErrorNone:             return @"ok";
        case GeminiStreamErrorCancelled:        return @"cancelled";
        case GeminiStreamErrorInvalidKey:       return @"invalid_key";
        case GeminiStreamErrorPermissionDenied: return @"permission_denied";
        case GeminiStreamErrorModelNotFound:    return @"model_not_found";
        case GeminiStreamErrorRateLimited:      return @"rate_limited";
        case GeminiStreamErrorNetwork:          return @"network";
        case GeminiStreamErrorBlocked:          return @"blocked";
        case GeminiStreamErrorServer:           return @"server";
        case GeminiStreamErrorEmptyReply:       return @"empty_reply";
        case GeminiStreamErrorTooLarge:         return @"too_large";
        case GeminiStreamErrorNoCredit:         return @"no_credit";
        default:                                return @"unknown";
    }
}

static NSString *ClippedForLog(NSString *text) {
    if (text.length == 0) return @"-";
    NSString *oneLine = [[text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]] componentsJoinedByString:@" "];
    return oneLine.length > 200 ? [[oneLine substringToIndex:200] stringByAppendingString:@"…"] : oneLine;
}

#pragma mark - ChatViewController

@interface ChatViewController () <WKNavigationDelegate, ScriptMessageTarget, UITextViewDelegate,
                                  UIImagePickerControllerDelegate, UINavigationControllerDelegate, UIDocumentPickerDelegate>
@property (strong, nonatomic) WKWebView *webView;
@property (assign, nonatomic) BOOL webReady;
@property (copy, nonatomic) NSString *lastWebError;

@property (strong, nonatomic) UIView *inputBar;
@property (strong, nonatomic) UIScrollView *attachStrip;
@property (strong, nonatomic) UIView *inputBox;
@property (strong, nonatomic) UIButton *attachButton;
@property (strong, nonatomic) UIView *toolRow;
@property (strong, nonatomic) UIButton *reasoningButton;
@property (strong, nonatomic) UIButton *searchButton;
@property (strong, nonatomic) UIButton *fastButton;
@property (strong, nonatomic) UIButton *mentionButton;
@property (strong, nonatomic) UILabel *reasoningValueLabel;
@property (strong, nonatomic) UIButton *reasoningFastButton;
@property (strong, nonatomic) UILabel *reasoningFastHintLabel;
@property (strong, nonatomic) UITextView *textView;
@property (strong, nonatomic) UILabel *placeholderLabel;
@property (strong, nonatomic) UIButton *sendButton;
@property (strong, nonatomic) UIButton *modelButton;
@property (assign, nonatomic) CGFloat keyboardOverlap;
@property (copy, nonatomic) NSString *selectedMentionItem; // Lưu mục được chọn từ @

@property (strong, nonatomic) NSMutableDictionary *conversation;
@property (copy, nonatomic) NSString *model;
@property (strong, nonatomic) id<ChatStreaming> stream;
@property (assign, nonatomic) BOOL streaming;
@property (assign, nonatomic) CFAbsoluteTime requestStartTime;
@property (assign, nonatomic) NSUInteger greetingIndex;
@property (copy, nonatomic) NSString *shownGreeting;
@property (assign, nonatomic) BOOL attemptIsStreaming;
@property (assign, nonatomic) NSInteger streamRetryCount;
@property (assign, nonatomic) BOOL didRecoverModel404;
@property (assign, nonatomic) BOOL didFallbackFromFastMode;
@property (strong, nonatomic) NSMutableString *streamBuffer;
@property (strong, nonatomic) NSMutableArray *streamGeneratedAttachments;

@property (strong, nonatomic) NSMutableArray *pendingAttachments;
@property (assign, nonatomic) NSInteger importsInFlight;
@end

@implementation ChatViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [Theme background];
    self.navigationItem.backBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"" style:UIBarButtonItemStylePlain target:nil action:nil];
    self.pendingAttachments = [NSMutableArray array];
    self.greetingIndex = arc4random_uniform((uint32_t)kGreetingCount);

    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithImage:[Theme iconMenu] style:UIBarButtonItemStylePlain target:self action:@selector(historyTapped)];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithImage:[Theme iconCompose] style:UIBarButtonItemStylePlain target:self action:@selector(newChatTapped)];

    self.modelButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.modelButton.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    self.modelButton.titleLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [self.modelButton setTitleColor:[Theme text] forState:UIControlStateNormal];
    [self.modelButton addTarget:self action:@selector(modelTapped) forControlEvents:UIControlEventTouchUpInside];
    self.navigationItem.titleView = self.modelButton;

    [self setupWebView];
    [self setupInputBar];

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(keyboardWillChange:) name:UIKeyboardWillChangeFrameNotification object:nil];
    [center addObserver:self selector:@selector(keyboardWillHide:) name:UIKeyboardWillHideNotification object:nil];
    [center addObserver:self selector:@selector(appWillEnterForeground:) name:UIApplicationWillEnterForegroundNotification object:nil];
    [center addObserver:self selector:@selector(historyCleared:) name:kNotifHistoryCleared object:nil];
    [center addObserver:self selector:@selector(conversationDeleted:) name:kNotifConversationDeleted object:nil];

    NSMutableSet *keep = [NSMutableSet set];
    for (NSDictionary *entry in [ConversationStore allEntries]) {
        if (entry[@"id"]) [keep addObject:entry[@"id"]];
    }
    [AttachmentStore removeOrphansKeepingConversationIds:keep];

    self.model = [ModelStore selectedModelId];
    [self ensureModelMatchesKeys];
    self.conversation = [ConversationStore newConversationWithModel:self.model];
    [self updateModelTitle];
    [self updateSendButton];
    [self updateDailyTokenPrompt];
    [self updateToolButtons];

    [self loadWebPage];
    [self refreshModels];

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ChatViewController *me = weakSelf;
        if (!me || me.webReady) return;
        [DiagnosticLog log:@"chat page did not report ready within 12 s (last web error: %@)", me.lastWebError ?: @"none"];
        [me showAlertMessage:[NSString stringWithFormat:L(@"web_fail_msg"), me.lastWebError ?: @"-"] title:L(@"web_fail_title")];
    });
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.webView.configuration.userContentController removeScriptMessageHandlerForName:@"native"];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self ensureModelMatchesKeys];
    [self updateModelTitle];
    [self updateDailyTokenPrompt];
    [self updateToolButtons];
    [self refreshGreetingIfEmpty];
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleDefault;
}

#pragma mark - Setup

- (void)setupWebView {
    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    WKUserContentController *controller = [[WKUserContentController alloc] init];
    [controller addScriptMessageHandler:[[WeakScriptHandler alloc] initWithTarget:self] name:@"native"];
    config.userContentController = controller;

    self.webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:config];
    self.webView.navigationDelegate = self;
    self.webView.opaque = NO;
    self.webView.backgroundColor = [Theme background];
    self.webView.scrollView.backgroundColor = [Theme background];
    self.webView.scrollView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    self.webView.scrollView.alwaysBounceVertical = YES;
    if (@available(iOS 11.0, *)) {
        self.webView.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    }
    [self.view addSubview:self.webView];
}

- (void)setupInputBar {
    self.inputBar = [[UIView alloc] init];
    self.inputBar.backgroundColor = [Theme background];
    [self.view addSubview:self.inputBar];

    UIView *line = [[UIView alloc] init];
    line.backgroundColor = [Theme border];
    line.tag = 1001;
    [self.inputBar addSubview:line];

    self.attachStrip = [[UIScrollView alloc] init];
    self.attachStrip.showsHorizontalScrollIndicator = NO;
    self.attachStrip.alwaysBounceHorizontal = YES;
    self.attachStrip.hidden = YES;
    [self.inputBar addSubview:self.attachStrip];

    self.toolRow = [[UIView alloc] init];
    self.toolRow.backgroundColor = [UIColor clearColor];
    [self.inputBar addSubview:self.toolRow];

    self.reasoningButton = [self toolButtonWithTitle:@"🧠 Suy luận" action:@selector(reasoningTapped)];
    self.searchButton = [self toolButtonWithTitle:@"⌕ Tìm kiếm" action:@selector(searchTapped)];
    self.fastButton = [self toolButtonWithTitle:@"⚡" action:@selector(fastTapped)];
    self.mentionButton = [self toolButtonWithTitle:@"@" action:@selector(mentionTapped)];
    [self.toolRow addSubview:self.reasoningButton];
    [self.toolRow addSubview:self.searchButton];
    [self.toolRow addSubview:self.fastButton];
    [self.toolRow addSubview:self.mentionButton];

    self.inputBox = [[UIView alloc] init];
    self.inputBox.backgroundColor = [Theme surface];
    self.inputBox.layer.cornerRadius = 22;
    self.inputBox.layer.borderWidth = 1;
    self.inputBox.layer.borderColor = [Theme border].CGColor;
    [self.inputBar addSubview:self.inputBox];

    self.attachButton = [UIButton buttonWithType:UIButtonTypeCustom];
    [self.attachButton setImage:[Theme iconPlus] forState:UIControlStateNormal];
    self.attachButton.tintColor = [Theme secondaryText];
    [self.attachButton addTarget:self action:@selector(attachTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.inputBox addSubview:self.attachButton];

    self.textView = [[UITextView alloc] init];
    self.textView.backgroundColor = [UIColor clearColor];
    self.textView.font = [UIFont systemFontOfSize:17];
    self.textView.textColor = [Theme text];
    self.textView.tintColor = [Theme accent];
    self.textView.textContainerInset = UIEdgeInsetsMake(9, 6, 9, 6);
    self.textView.delegate = self;
    [self.inputBox addSubview:self.textView];

    self.placeholderLabel = [[UILabel alloc] init];
    self.placeholderLabel.text = L(@"chat_placeholder");
    self.placeholderLabel.font = [UIFont systemFontOfSize:17];
    self.placeholderLabel.textColor = [UIColor colorWithWhite:0.6 alpha:1];
    [self.inputBox addSubview:self.placeholderLabel];

    self.sendButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.sendButton.layer.cornerRadius = 18;
    self.sendButton.tintColor = [UIColor whiteColor];
    [self.sendButton addTarget:self action:@selector(sendTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.inputBox addSubview:self.sendButton];
}

#pragma mark - Layout

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    CGFloat width = self.view.bounds.size.width;
    CGFloat height = self.view.bounds.size.height;
    CGFloat safeBottom = 0;
    if (@available(iOS 11.0, *)) safeBottom = self.view.safeAreaInsets.bottom;
    CGFloat bottomInset = self.keyboardOverlap > 0 ? self.keyboardOverlap : safeBottom;

    BOOL showStrip = self.pendingAttachments.count > 0 || self.importsInFlight > 0;
    CGFloat stripHeight = showStrip ? kStripHeight : 0;

    CGFloat boxWidth = width - 24;
    CGFloat leftPad = 40;
    CGFloat rightPad = 44;
    CGFloat textWidth = boxWidth - leftPad - rightPad;
    CGFloat fit = [self.textView sizeThatFits:CGSizeMake(textWidth, CGFLOAT_MAX)].height;
    CGFloat textHeight = MIN(MAX(fit, 38), kMaxInputHeight);
    self.textView.scrollEnabled = fit > kMaxInputHeight;

    CGFloat boxHeight = textHeight + 8;
    CGFloat toolsY = 8 + stripHeight;
    CGFloat boxY = toolsY + kToolsRowHeight + 4;
    CGFloat barHeight = boxY + boxHeight + 8;
    self.inputBar.frame = CGRectMake(0, height - bottomInset - barHeight, width, barHeight);
    [self.inputBar viewWithTag:1001].frame = CGRectMake(0, 0, width, 1);

    self.attachStrip.hidden = !showStrip;
    self.attachStrip.frame = CGRectMake(0, 8, width, stripHeight);
    self.toolRow.frame = CGRectMake(12, toolsY, width - 24, kToolsRowHeight);
    CGFloat toolWidth = floor((width - 24) / 4.0);
    self.reasoningButton.frame = CGRectMake(0, 0, toolWidth, kToolsRowHeight);
    self.searchButton.frame = CGRectMake(toolWidth, 0, toolWidth, kToolsRowHeight);
    self.fastButton.frame = CGRectMake(toolWidth * 2, 0, toolWidth, kToolsRowHeight);
    self.mentionButton.frame = CGRectMake(toolWidth * 3, 0, toolWidth, kToolsRowHeight);
    self.inputBox.frame = CGRectMake(12, boxY, boxWidth, boxHeight);
    self.attachButton.frame = CGRectMake(5, boxHeight - 36 - 5, 36, 36);
    self.textView.frame = CGRectMake(leftPad, 4, textWidth, textHeight);
    self.placeholderLabel.frame = CGRectMake(leftPad + 11, 13, textWidth - 12, 20);
    self.sendButton.frame = CGRectMake(boxWidth - 36 - 5, boxHeight - 36 - 5, 36, 36);
    [self updateToolButtons];

    self.webView.frame = CGRectMake(0, 0, width, CGRectGetMinY(self.inputBar.frame));
}

- (UIButton *)toolButtonWithTitle:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    button.layer.cornerRadius = 9;
    button.backgroundColor = [Theme surface];
    [button setTitleColor:[Theme secondaryText] forState:UIControlStateNormal];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (BOOL)currentModelSupportsFastMode {
    if ([Provider forModelId:self.model] != AIProviderClaude) return NO;
    NSString *model = self.model.lowercaseString ?: @"";
    return [model containsString:@"claude-opus-5-5"] ||
           [model containsString:@"claude-fable-5-2"] ||
           [model containsString:@"claude-mythos-5-2"] ||
           [model isEqualToString:@"claude-opus-5"] ||
           ([model containsString:@"claude-opus-5-"] && ![model containsString:@"claude-opus-5-5"]) ||
           [model containsString:@"claude-opus-4-8"];
}

- (void)updateToolButtons {
    UIColor *active = [Theme accent];
    [self.reasoningButton setTitleColor:active forState:UIControlStateNormal];
    [self.searchButton setTitleColor:[AppSettings webSearchEnabled] ? active : [Theme secondaryText] forState:UIControlStateNormal];
    BOOL supportsFast = [self currentModelSupportsFastMode];
    self.fastButton.enabled = YES;
    self.fastButton.alpha = supportsFast ? 1.0 : 0.42;
    [self.fastButton setTitleColor:(supportsFast && [AppSettings fastModeEnabled]) ? active : [Theme secondaryText] forState:UIControlStateNormal];
    NSString *level = @[@"Thấp", @"Trung bình", @"Cao", @"Siêu cao", @"MAX ×8"][(NSUInteger)[AppSettings reasoningLevel]];
    [self.reasoningButton setTitle:[NSString stringWithFormat:@"🧠 %@", level] forState:UIControlStateNormal];
    [self.searchButton setTitle:[AppSettings webSearchEnabled] ? @"⌕ Tìm ✓" : @"⌕ Tìm kiếm" forState:UIControlStateNormal];
}

- (void)reasoningTapped {
    [self.view endEditing:YES];

    UIViewController *panel = [[UIViewController alloc] init];
    panel.view.frame = self.view.bounds;
    panel.view.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.28];
    panel.modalPresentationStyle = UIModalPresentationOverFullScreen;
    panel.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;

    CGFloat cardWidth = MIN(CGRectGetWidth(self.view.bounds) - 36.0, 420.0);
    CGFloat cardHeight = 370.0;
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake((CGRectGetWidth(self.view.bounds) - cardWidth) / 2.0,
                                                            (CGRectGetHeight(self.view.bounds) - cardHeight) / 2.0,
                                                            cardWidth, cardHeight)];
    card.backgroundColor = [Theme surface];
    card.layer.cornerRadius = 25.0;
    card.layer.borderWidth = 1.0;
    card.layer.borderColor = [Theme border].CGColor;
    card.layer.shadowColor = [UIColor blackColor].CGColor;
    card.layer.shadowOpacity = 0.10;
    card.layer.shadowRadius = 18.0;
    card.layer.shadowOffset = CGSizeMake(0, 7);
    [panel.view addSubview:card];

    CGFloat contentWidth = cardWidth - 44.0;
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(22, 22, contentWidth, 36)];
    title.text = @"Mức suy luận";
    title.font = [UIFont systemFontOfSize:25 weight:UIFontWeightBold];
    title.textColor = [Theme text];
    [card addSubview:title];

    self.reasoningValueLabel = [[UILabel alloc] initWithFrame:CGRectMake(22, 75, contentWidth, 34)];
    self.reasoningValueLabel.textAlignment = NSTextAlignmentCenter;
    self.reasoningValueLabel.font = [UIFont systemFontOfSize:22 weight:UIFontWeightSemibold];
    self.reasoningValueLabel.textColor = [Theme text];
    [card addSubview:self.reasoningValueLabel];

    UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(28, 126, contentWidth - 12, 34)];
    slider.minimumValue = 0;
    slider.maximumValue = 4;
    slider.minimumTrackTintColor = [Theme accent];
    slider.maximumTrackTintColor = [Theme border];
    slider.value = [AppSettings reasoningLevel];
    [slider addTarget:self action:@selector(reasoningSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [card addSubview:slider];

    UILabel *low = [[UILabel alloc] initWithFrame:CGRectMake(22, 169, 100, 25)];
    low.text = @"Thấp";
    low.font = [UIFont systemFontOfSize:15];
    low.textColor = [Theme secondaryText];
    [card addSubview:low];
    UILabel *maximum = [[UILabel alloc] initWithFrame:CGRectMake(cardWidth - 122, 169, 100, 25)];
    maximum.text = @"MAX ×8";
    maximum.textAlignment = NSTextAlignmentRight;
    maximum.font = [UIFont systemFontOfSize:15];
    maximum.textColor = [Theme secondaryText];
    [card addSubview:maximum];

    self.reasoningFastButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.reasoningFastButton.frame = CGRectMake(20, 213, cardWidth - 40, 52);
    self.reasoningFastButton.backgroundColor = [Theme background];
    self.reasoningFastButton.layer.cornerRadius = 16;
    self.reasoningFastButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    self.reasoningFastButton.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    [self.reasoningFastButton setTitleColor:[Theme text] forState:UIControlStateNormal];
    [self.reasoningFastButton addTarget:self action:@selector(fastTapped) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:self.reasoningFastButton];
    [self updateReasoningFastButton];

    self.reasoningFastHintLabel = [[UILabel alloc] initWithFrame:CGRectMake(22, 277, contentWidth, 42)];
    self.reasoningFastHintLabel.text = @"Ưu tiên tốc độ; token/chi phí có thể tăng. Tốc độ thực tế phụ thuộc model và API, không bảo đảm đạt ×10.";
    self.reasoningFastHintLabel.font = [UIFont systemFontOfSize:13];
    self.reasoningFastHintLabel.numberOfLines = 2;
    self.reasoningFastHintLabel.textColor = [Theme secondaryText];
    [card addSubview:self.reasoningFastHintLabel];

    UIButton *done = [UIButton buttonWithType:UIButtonTypeSystem];
    done.frame = CGRectMake(20, 329, cardWidth - 40, 30);
    [done setTitle:L(@"done") forState:UIControlStateNormal];
    done.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightMedium];
    [done addTarget:self action:@selector(dismissReasoningPanel) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:done];

    [self reasoningSliderChanged:slider];
    [self presentViewController:panel animated:YES completion:nil];
}

- (void)reasoningSliderChanged:(UISlider *)slider {
    NSInteger level = (NSInteger)lrintf(slider.value);
    [AppSettings setReasoningLevel:(AIReasoningLevel)level];
    NSArray *names = @[@"Thấp", @"Trung bình", @"Cao", @"Siêu cao", @"MAX ×8"];
    self.reasoningValueLabel.text = names[(NSUInteger)level];
    [self updateToolButtons];
    [self pushStrings];
}

- (void)updateReasoningFastButton {
    if (!self.reasoningFastButton) return;
    BOOL supported = [self currentModelSupportsFastMode];
    NSString *status = supported ? ([AppSettings fastModeEnabled] ? @"Đang bật" : @"Đang tắt") : @"Model/API không hỗ trợ";
    [self.reasoningFastButton setTitle:[NSString stringWithFormat:@"⚡  Tăng tốc ×10     %@", status] forState:UIControlStateNormal];
    self.reasoningFastButton.enabled = supported;
    self.reasoningFastButton.alpha = supported ? 1.0 : 0.55;
}

- (void)dismissReasoningPanel {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)searchTapped {
    [AppSettings setWebSearchEnabled:![AppSettings webSearchEnabled]];
    [self updateToolButtons];
    [self showAlertMessage:[AppSettings webSearchEnabled] ? @"Tìm kiếm web đã bật cho các API hỗ trợ công cụ tìm kiếm." : @"Tìm kiếm web đã tắt."];
}

- (void)fastTapped {
    if (![self currentModelSupportsFastMode]) {
        [self showAlertMessage:@"Tăng tốc hiện chỉ gửi được qua Fast mode của một số model Claude tương thích. Gemini và model khác không có tham số tăng tốc tương đương trong API hiện tại."];
        return;
    }
    [AppSettings setFastModeEnabled:![AppSettings fastModeEnabled]];
    [self updateToolButtons];
    [self updateReasoningFastButton];
}

- (void)mentionTapped {
    [self.view endEditing:YES];
    
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"@ Công cụ" 
                                                                    message:@"Chọn tác vụ hoặc tích hợp" 
                                                             preferredStyle:UIAlertControllerStyleActionSheet];
    
    __weak typeof(self) weakSelf = self;
    NSArray *recent = self.conversation[@"messages"];
    NSString *lastReply = nil;
    
    if ([recent isKindOfClass:[NSArray class]]) {
        for (NSInteger i = (NSInteger)recent.count - 1; i >= 0; i--) {
            NSDictionary *message = recent[(NSUInteger)i];
            if ([message isKindOfClass:[NSDictionary class]]) {
                NSString *role = message[@"role"];
                NSString *text = message[@"text"];
                if (![role isEqualToString:@"user"] && [text isKindOfClass:[NSString class]] && text.length > 0) {
                    lastReply = text;
                    break;
                }
            }
        }
    }
    
    // Tạo hành động xuất tệp TXT
    [sheet addAction:[UIAlertAction actionWithTitle:@"Tạo tệp TXT" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        NSString *source = lastReply.length > 0 ? lastReply : [strongSelf trimmedInput];
        if (source.length > 0) {
            [strongSelf exportText:source asWord:NO];
        } else {
            [strongSelf showAlertMessage:@"Hãy nhập nội dung hoặc tạo câu trả lời trước khi xuất tệp TXT."];
        }
    }]];
    
    // Tạo hành động xuất tệp DOCX
    [sheet addAction:[UIAlertAction actionWithTitle:@"Tạo tệp DOCX" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        NSString *source = lastReply.length > 0 ? lastReply : [strongSelf trimmedInput];
        if (source.length > 0) {
            [strongSelf exportText:source asWord:YES];
        } else {
            [strongSelf showAlertMessage:@"Hãy nhập nội dung hoặc tạo câu trả lời trước khi xuất tệp DOCX."];
        }
    }]];
    
    // Chọn tệp đính kèm
    [sheet addAction:[UIAlertAction actionWithTitle:@"Chọn tệp để đính kèm…" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        [strongSelf attachTapped];
    }]];
    
    // Lệnh tạo ảnh nhanh
    [sheet addAction:[UIAlertAction actionWithTitle:@"/tạo ảnh" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.textView.text = @"/tạo ảnh ";
        [strongSelf textViewDidChange:strongSelf.textView];
        [strongSelf.textView becomeFirstResponder];
    }]];
    
    // Bật/tắt tìm kiếm web động theo trạng thái AppSettings
    BOOL isWebSearchActive = [AppSettings webSearchEnabled];
    NSString *searchActionTitle = isWebSearchActive ? @"Tắt tìm kiếm web" : @"Bật tìm kiếm web";
    [sheet addAction:[UIAlertAction actionWithTitle:searchActionTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        [strongSelf searchTapped];
    }]];
    
    // Danh sách các dịch vụ bên ngoài yêu cầu OAuth/API
    NSArray *external = @[@"Gmail", @"Google Calendar", @"Google Docs", @"Google Drive", @"Google Home", @"Google Keep", @"Google Photos", @"Google Sheets", @"Google Tasks"];
    for (NSString *name in external) {
        [sheet addAction:[UIAlertAction actionWithTitle:name style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            [strongSelf showAlertMessage:[NSString stringWithFormat:@"%@ cần kết nối OAuth/API riêng. Phiên bản này chưa có thông tin xác thực để truy cập tài khoản.", name]];
        }]];
    }
    
    [sheet addAction:[UIAlertAction actionWithTitle:L(@"cancel") style:UIAlertActionStyleCancel handler:nil]];
    
    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.sourceView = self.mentionButton;
        sheet.popoverPresentationController.sourceRect = self.mentionButton.bounds;
        sheet.popoverPresentationController.permittedArrowDirections = UIPopoverArrowDirectionAny;
    }
    
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)updateDailyTokenPrompt {
    long long used = [AppSettings dailyTokenUsage];
    long long budget = [AppSettings dailyTokenBudget];
    
    NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
    formatter.numberStyle = NSNumberFormatterDecimalStyle;
    
    NSString *usedText = nil;
    NSString *budgetText = nil;
    
    if (used >= 1000000000LL) {
        usedText = [NSString stringWithFormat:@"%.2fB", used / 1000000000.0];
    } else {
        usedText = [formatter stringFromNumber:@(used)] ?: [NSString stringWithFormat:@"%lld", used];
    }
    
    if (budget >= 1000000000LL) {
        budgetText = [NSString stringWithFormat:@"%.0fB", budget / 1000000000.0];
    } else {
        budgetText = [formatter stringFromNumber:@(budget)] ?: [NSString stringWithFormat:@"%lld", budget];
    }
    
    self.navigationItem.prompt = [NSString stringWithFormat:@"Token hôm nay: %@/%@", usedText, budgetText];
}

- (void)relayoutAnimated {
    [self.view setNeedsLayout];
    [UIView animateWithDuration:0.15 animations:^{
        [self.view layoutIfNeeded];
    }];
}

#pragma mark - Keyboard

- (void)keyboardWillChange:(NSNotification *)note {
    CGRect endFrame = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect local = [self.view convertRect:endFrame fromView:nil];
    self.keyboardOverlap = MAX(0, CGRectGetMaxY(self.view.bounds) - local.origin.y);
    [self animateLayoutForKeyboardNote:note];
}

- (void)keyboardWillHide:(NSNotification *)note {
    self.keyboardOverlap = 0;
    [self animateLayoutForKeyboardNote:note];
}

- (void)animateLayoutForKeyboardNote:(NSNotification *)note {
    NSTimeInterval duration = [note.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    NSUInteger curve = [note.userInfo[UIKeyboardAnimationCurveUserInfoKey] unsignedIntegerValue];
    [self.view setNeedsLayout];
    [UIView animateWithDuration:duration
                          delay:0
                        options:(curve << 16) | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{ [self.view layoutIfNeeded]; }
                     completion:^(BOOL finished) { [self callJS:@"scrollEnd" args:@[]]; }];
}

#pragma mark - Alerts

- (void)showAlertMessage:(NSString *)message {
    [self showAlertMessage:message title:nil];
}

- (void)showAlertMessage:(NSString *)message title:(NSString *)title {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    UIViewController *top = self;
    while (top.presentedViewController) top = top.presentedViewController;
    [top presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Web page

- (NSString *)resourceText:(NSString *)name ext:(NSString *)ext {
    NSString *path = [[NSBundle mainBundle] pathForResource:name ofType:ext inDirectory:@"web"];
    if (!path) return @"";
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    return text ?: @"";
}

- (void)loadWebPage {
    self.webReady = NO;
    NSString *html = [self resourceText:@"index" ext:@"html"];
    NSString *css = [[self resourceText:@"vendor" ext:@"css"] stringByAppendingFormat:@"\n%@", [self resourceText:@"chat" ext:@"css"]];
    NSString *js = [NSString stringWithFormat:@"%@\n%@\n%@", [self resourceText:@"vendor" ext:@"js"],
                                              [self resourceText:@"render" ext:@"js"], [self resourceText:@"chat" ext:@"js"]];

    NSString *logoPath = [[NSBundle mainBundle] pathForResource:@"logo_small" ofType:@"png"];
    NSData *logoData = logoPath ? [NSData dataWithContentsOfFile:logoPath] : nil;
    NSString *logoURI = logoData ? [@"data:image/png;base64," stringByAppendingString:[logoData base64EncodedStringWithOptions:0]] : @"";
    css = [css stringByReplacingOccurrencesOfString:@"{{LOGO}}" withString:logoURI];

    html = [html stringByReplacingOccurrencesOfString:@"{{CSS}}" withString:css];
    html = [html stringByReplacingOccurrencesOfString:@"{{JS}}" withString:js];
    [self.webView loadHTMLString:html baseURL:nil];
}

- (void)callJS:(NSString *)function args:(NSArray *)args {
    if (!self.webReady) return;
    NSData *data = [NSJSONSerialization dataWithJSONObject:args options:0 error:nil];
    if (!data) return;
    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    json = [json stringByReplacingOccurrencesOfString:@"\u2028" withString:@"\\u2028"];
    json = [json stringByReplacingOccurrencesOfString:@"\u2029" withString:@"\\u2029"];
    NSString *script = [NSString stringWithFormat:@"ChatUI.%@.apply(null,%@);", function, json];
    [self.webView evaluateJavaScript:script completionHandler:nil];
}

#pragma mark - Greeting

- (NSString *)greetingTitle {
    NSInteger hour = [[NSCalendar currentCalendar] component:NSCalendarUnitHour fromDate:[NSDate date]];
    if (hour >= 23 || hour < 3) return L(@"greeting_night");
    if (hour < 11) return L(@"greeting_morning");
    if (hour < 14) return L(@"greeting_noon");
    if (hour < 18) return L(@"greeting_afternoon");
    return L(@"greeting_evening");
}

- (NSString *)greetingSubtitle {
    switch (self.greetingIndex) {
        case 0:  return L(@"empty_sub_1");
        case 1:  return L(@"empty_sub_2");
        case 2:  return L(@"empty_sub_3");
        case 3:  return L(@"empty_sub_4");
        case 4:  return L(@"empty_sub_5");
        default: return L(@"empty_sub_6");
    }
}

- (void)rerollGreeting {
    NSUInteger previous = self.greetingIndex;
    NSUInteger next = previous;
    while (next == previous) next = arc4random_uniform((uint32_t)kGreetingCount);
    self.greetingIndex = next;
}

- (void)refreshGreetingIfEmpty {
    if (!self.webReady || [self.conversation[@"messages"] count] > 0) return;
    NSString *current = [NSString stringWithFormat:@"%@|%@", [self greetingTitle], [self greetingSubtitle]];
    if ([current isEqualToString:self.shownGreeting]) return;
    [self pushStrings];
    [self callJS:@"clear" args:@[]];
}

- (void)appWillEnterForeground:(NSNotification *)note {
    [self refreshGreetingIfEmpty];
}

- (void)pushStrings {
    self.shownGreeting = [NSString stringWithFormat:@"%@|%@", [self greetingTitle], [self greetingSubtitle]];
    [self callJS:@"setStrings" args:@[@{ @"emptyTitle": [self greetingTitle],
                                          @"emptySub": [self greetingSubtitle],
                                          @"copy": L(@"copy"),
                                          @"copyCode": L(@"copy"),
                                          @"copied": L(@"copied"),
                                          @"regenerate": L(@"regenerate"),
                                          @"retry": L(@"retry"),
                                          @"edit": L(@"edit"),
                                          @"save": L(@"save_reply"),
                                          @"share": L(@"share_image"),
                                          @"thinking": ([AppSettings reasoningLevel] >= AIReasoningLevelHigh) ? @"Đang suy luận sâu…" : @"Đang xử lý…" }]];
}

- (NSArray *)webAttachmentsFrom:(NSArray *)attachments conversation:(NSString *)cid {
    NSMutableArray *out = [NSMutableArray array];
    if (![attachments isKindOfClass:[NSArray class]]) return out;
    for (NSDictionary *att in attachments) {
        if (![att isKindOfClass:[NSDictionary class]]) continue;
        NSString *kind = [att[@"kind"] isKindOfClass:[NSString class]] ? att[@"kind"] : @"text";
        NSString *name = [att[@"name"] isKindOfClass:[NSString class]] ? att[@"name"] : @"";
        NSString *thumb = [kind isEqualToString:@"image"] ? [AttachmentStore thumbnailDataURIForAttachment:att conversation:cid] : @"";
        NSString *attachmentId = [att[@"id"] isKindOfClass:[NSString class]] ? att[@"id"] : @"";
        [out addObject:@{ @"id": attachmentId, @"kind": kind, @"name": name, @"thumb": thumb }];
    }
    return out;
}

- (void)renderConversation {
    NSString *cid = self.conversation[@"id"];
    NSArray *messages = self.conversation[@"messages"];
    NSMutableArray *list = [NSMutableArray array];
    for (NSUInteger messageIndex = 0; messageIndex < messages.count; messageIndex++) {
        NSDictionary *message = messages[messageIndex];
        NSString *role = message[@"role"];
        NSString *text = message[@"text"];
        if (![role isKindOfClass:[NSString class]] || ![text isKindOfClass:[NSString class]]) continue;
        NSMutableDictionary *item = [@{ @"role": role, @"text": text, @"index": @(messageIndex) } mutableCopy];
        NSArray *attachments = message[@"attachments"];
        if ([attachments isKindOfClass:[NSArray class]] && attachments.count > 0) {
            item[@"attachments"] = [self webAttachmentsFrom:attachments conversation:cid];
        }
        [list addObject:item];
    }
    [self callJS:@"load" args:@[list]];
}

- (void)handleScriptMessage:(WKScriptMessage *)message {
    if (![message.body isKindOfClass:[NSDictionary class]]) return;
    NSDictionary *body = message.body;
    NSString *type = body[@"type"];
    if ([type isEqualToString:@"ready"]) {
        [DiagnosticLog log:@"chat page ready"];
        self.webReady = YES;
        [self pushStrings];
        [self renderConversation];
        [self updateSendButton];
    } else if ([type isEqualToString:@"copy"]) {
        NSString *text = body[@"text"];
        if ([text isKindOfClass:[NSString class]]) [UIPasteboard generalPasteboard].string = text;
    } else if ([type isEqualToString:@"regenerate"]) {
        [self regenerate];
    } else if ([type isEqualToString:@"edit"]) {
        [self editMessageAtIndex:[body[@"index"] integerValue]];
    } else if ([type isEqualToString:@"save"]) {
        NSString *text = body[@"text"];
        if ([text isKindOfClass:[NSString class]] && text.length > 0) [self offerExportForText:text];
    } else if ([type isEqualToString:@"image"]) {
        [self showImageForAttachmentId:body[@"id"]];
    } else if ([type isEqualToString:@"shareImage"]) {
        [self shareImageForAttachmentId:body[@"id"]];
    } else if ([type isEqualToString:@"jserror"]) {
        [DiagnosticLog log:@"page script error: %@ (line %@)", ClippedForLog(body[@"message"]), body[@"line"] ?: @"?"];
    }
}

- (void)shareImageForAttachmentId:(NSString *)attachmentId {
    if (![attachmentId isKindOfClass:[NSString class]] || attachmentId.length == 0) return;
    NSString *cid = self.conversation[@"id"];
    for (NSDictionary *message in self.conversation[@"messages"]) {
        NSArray *attachments = [message[@"attachments"] isKindOfClass:[NSArray class]] ? message[@"attachments"] : @[];
        for (NSDictionary *attachment in attachments) {
            if (![attachment[@"id"] isEqualToString:attachmentId] || ![attachment[@"kind"] isEqualToString:@"image"]) continue;
            NSString *path = [AttachmentStore pathForFile:attachment[@"file"] conversation:cid];
            if (!path) return;
            UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:path]] applicationActivities:nil];
            activity.popoverPresentationController.sourceView = self.view;
            activity.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
            [self presentViewController:activity animated:YES completion:nil];
            return;
        }
    }
}

- (void)offerExportForText:(NSString *)text {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:L(@"export_file")
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:L(@"export_txt") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [weakSelf exportText:text asWord:NO];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:L(@"export_docx") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [weakSelf exportText:text asWord:YES];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:L(@"cancel") style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMaxY(self.view.bounds) - 80, 1, 1);
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)exportText:(NSString *)text asWord:(BOOL)asWord {
    NSError *error = nil;
    NSURL *url = asWord ? [OfficeExport writeWordFile:text error:&error] : [OfficeExport writeTextFile:text error:&error];
    if (!url) {
        [self showAlertMessage:L(@"export_failed")];
        [DiagnosticLog log:@"reply export failed: %@", error.localizedDescription ?: @"unknown"];
        return;
    }
    UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
    activity.popoverPresentationController.sourceView = self.view;
    activity.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
    [self presentViewController:activity animated:YES completion:nil];
}

- (void)showImageForAttachmentId:(NSString *)attachmentId {
    if (![attachmentId isKindOfClass:[NSString class]] || attachmentId.length == 0) return;
    NSString *cid = self.conversation[@"id"];
    for (NSDictionary *message in self.conversation[@"messages"]) {
        NSArray *atts = message[@"attachments"];
        if (![atts isKindOfClass:[NSArray class]]) continue;
        for (NSDictionary *att in atts) {
            if (![att[@"id"] isEqualToString:attachmentId] || ![att[@"kind"] isEqualToString:@"image"]) continue;
            NSString *path = [AttachmentStore pathForFile:att[@"file"] conversation:cid];
            if (!path) return;
            [self.view endEditing:YES];
            [self presentViewController:[[ImageViewerViewController alloc] initWithImagePath:path] animated:YES completion:nil];
            return;
        }
    }
}

#pragma mark - WKNavigationDelegate

- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
                                                    decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    if (navigationAction.navigationType == WKNavigationTypeLinkActivated) {
        NSURL *url = navigationAction.request.URL;
        if (url) [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
        decisionHandler(WKNavigationActionPolicyCancel);
        return;
    }
    decisionHandler(WKNavigationActionPolicyAllow);
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    self.lastWebError = error.localizedDescription;
    [DiagnosticLog log:@"web view failed: %@ [%@ %ld]", error.localizedDescription, error.domain, (long)error.code];
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    self.lastWebError = error.localizedDescription;
    [DiagnosticLog log:@"web view failed to start: %@ [%@ %ld]", error.localizedDescription, error.domain, (long)error.code];
}

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
    [DiagnosticLog log:@"web content process was terminated by iOS (probably memory): reloading the page"];
    [self loadWebPage];
}

#pragma mark - Models

- (void)updateModelTitle {
    NSString *name = self.model.length > 0 ? self.model : L(@"choose_model");
    [self.modelButton setTitle:[name stringByAppendingString:@" \u25BE"] forState:UIControlStateNormal];
    CGFloat maxWidth = MIN(240, self.view.bounds.size.width - 120);
    CGSize size = [self.modelButton sizeThatFits:CGSizeMake(maxWidth, 44)];
    self.modelButton.frame = CGRectMake(0, 0, MIN(ceil(size.width) + 8, maxWidth), 44);
}

- (void)ensureModelMatchesKeys {
    BOOL usable = self.model.length > 0 && [KeyStore hasKeyForProvider:[Provider forModelId:self.model]];
    if (usable) return;
    NSString *fallback = [ModelStore defaultModelIdAcrossProviders];
    self.model = fallback;
    if (fallback.length > 0) [ModelStore setSelectedModelId:fallback];
    self.conversation[@"model"] = fallback ?: @"";
    [self updateModelTitle];
}

- (void)refreshModels {
    for (NSNumber *value in [Provider all]) {
        AIProvider provider = (AIProvider)value.integerValue;
        NSString *key = [KeyStore loadKeyForProvider:provider];
        if (key.length == 0) continue;
        __weak typeof(self) weakSelf = self;
        GeminiModelsCompletion completion = ^(NSArray *models, GeminiCheckResult result) {
            ChatViewController *me = weakSelf;
            if (!me) return;
            if (result != GeminiCheckOK || models.count == 0) {
                [DiagnosticLog log:@"model list: %@ failed (check result %ld, %lu models)", [Provider nameFor:provider], (long)result, (unsigned long)models.count];
                return;
            }
            [ModelStore saveModels:models forProvider:provider];
            [me ensureModelMatchesKeys];
        };
        if (provider == AIProviderClaude) [ClaudeClient fetchModelsWithKey:key completion:completion];
        else [GeminiClient fetchModelsWithKey:key completion:completion];
    }
}

- (void)modelTapped {
    [self.view endEditing:YES];
    ModelPickerViewController *picker = [[ModelPickerViewController alloc] initWithSelectedModel:self.model];
    __weak typeof(self) weakSelf = self;
    picker.onSelect = ^(NSString *modelId) {
        ChatViewController *me = weakSelf;
        if (!me) return;
        me.model = modelId;
        [ModelStore setSelectedModelId:modelId];
        me.conversation[@"model"] = modelId;
        if ([me.conversation[@"messages"] count] > 0) [ConversationStore saveConversation:me.conversation];
        [me updateModelTitle];
    };
    picker.chatPrompt = [self.conversation[@"system"] isKindOfClass:[NSString class]] ? self.conversation[@"system"] : @"";
    picker.onChatPromptChange = ^(NSString *text) {
        ChatViewController *me = weakSelf;
        if (!me) return;
        me.conversation[@"system"] = text ?: @"";
        if ([me.conversation[@"messages"] count] > 0) [ConversationStore saveConversation:me.conversation];
    };
    [self.navigationController pushViewController:picker animated:YES];
}

#pragma mark - Navigation buttons

- (void)historyTapped {
    [self.view endEditing:YES];
    HistoryViewController *history = [[HistoryViewController alloc] init];
    __weak typeof(self) weakSelf = self;
    history.onSelect = ^(NSString *cid) { [weakSelf openConversationWithId:cid]; };
    [self.navigationController pushViewController:history animated:YES];
}

- (void)newChatTapped {
    [self startNewChat];
}

- (void)historyCleared:(NSNotification *)note {
    [self startNewChat];
}

- (void)conversationDeleted:(NSNotification *)note {
    NSString *cid = note.userInfo[@"id"];
    if ([cid isEqualToString:self.conversation[@"id"]]) [self startNewChat];
}

- (void)discardPendingAttachments {
    NSString *cid = self.conversation[@"id"];
    for (NSDictionary *att in self.pendingAttachments) [AttachmentStore deleteAttachment:att conversation:cid];
    [self.pendingAttachments removeAllObjects];
    [self refreshAttachStrip];
}

- (void)startNewChat {
    [self abandonStream];
    [self discardPendingAttachments];
    self.conversation = [ConversationStore newConversationWithModel:self.model];
    [self rerollGreeting];
    [self pushStrings];
    [self callJS:@"clear" args:@[]];
    [self updateSendButton];
}

- (void)openConversationWithId:(NSString *)cid {
    NSMutableDictionary *loaded = [ConversationStore loadConversationWithId:cid];
    if (!loaded) return;
    [self abandonStream];
    [self discardPendingAttachments];
    self.conversation = loaded;
    NSString *savedModel = loaded[@"model"];
    if ([savedModel isKindOfClass:[NSString class]] && savedModel.length > 0) {
        self.model = savedModel;
        [ModelStore setSelectedModelId:savedModel];
    }
    [self ensureModelMatchesKeys];
    [self updateModelTitle];
    [self renderConversation];
    [self updateSendButton];
}

#pragma mark - Input

- (void)textViewDidChange:(UITextView *)textView {
    self.placeholderLabel.hidden = textView.text.length > 0;
    [self updateSendButton];
    [self relayoutAnimated];
}

- (NSString *)trimmedInput {
    return [self.textView.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

- (void)updateSendButton {
    BOOL hasContent = [self trimmedInput].length > 0 || self.pendingAttachments.count > 0;
    BOOL canSend = hasContent && self.webReady && self.importsInFlight == 0;
    if (self.streaming) {
        [self.sendButton setImage:[Theme iconStop] forState:UIControlStateNormal];
        self.sendButton.backgroundColor = [Theme accent];
    } else {
        [self.sendButton setImage:[Theme iconSend] forState:UIControlStateNormal];
        self.sendButton.backgroundColor = canSend ? [Theme accent] : [Theme accentDisabled];
    }
    self.attachButton.enabled = !self.streaming;
    self.attachButton.alpha = self.streaming ? 0.4 : 1.0;
}

#pragma mark - Attachments

- (NSUInteger)inlineBytesOf:(NSArray *)attachments {
    NSUInteger total = 0;
    for (NSDictionary *att in attachments) {
        NSString *kind = att[@"kind"];
        if ([kind isEqualToString:@"image"] || [kind isEqualToString:@"pdf"]) total += [att[@"bytes"] unsignedIntegerValue];
    }
    return total;
}

- (NSString *)extLabelForAttachment:(NSDictionary *)att {
    if ([att[@"kind"] isEqualToString:@"pdf"]) return @"PDF";
    if ([att[@"kind"] isEqualToString:@"image"]) return @"IMG";
    NSString *ext = [[att[@"name"] pathExtension] uppercaseString];
    return (ext.length > 0 && ext.length <= 5) ? ext : @"TXT";
}

- (UIView *)chipForAttachment:(NSDictionary *)att conversation:(NSString *)cid index:(NSUInteger)index {
    BOOL isImage = [att[@"kind"] isEqualToString:@"image"];
    CGFloat width = isImage ? 56 : 168;
    UIView *chip = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, 56)];
    chip.layer.cornerRadius = 10;
    chip.clipsToBounds = YES;

    if (isImage) {
        NSString *thumbPath = [AttachmentStore pathForFile:att[@"thumb"] conversation:cid];
        UIImageView *imageView = [[UIImageView alloc] initWithFrame:chip.bounds];
        imageView.image = thumbPath ? [UIImage imageWithContentsOfFile:thumbPath] : nil;
        imageView.contentMode = UIViewContentModeScaleAspectFill;
        imageView.clipsToBounds = YES;
        imageView.backgroundColor = [Theme selection];
        [chip addSubview:imageView];
    } else {
        chip.backgroundColor = [Theme selection];

        UILabel *badge = [[UILabel alloc] init];
        badge.text = [self extLabelForAttachment:att];
        badge.font = [UIFont systemFontOfSize:10 weight:UIFontWeightBold];
        badge.textColor = [UIColor whiteColor];
        badge.backgroundColor = [Theme accent];
        badge.textAlignment = NSTextAlignmentCenter;
        badge.layer.cornerRadius = 4;
        badge.clipsToBounds = YES;
        CGSize badgeSize = [badge sizeThatFits:CGSizeMake(80, 16)];
        badge.frame = CGRectMake(8, 8, ceil(badgeSize.width) + 10, 16);
        [chip addSubview:badge];

        UILabel *name = [[UILabel alloc] initWithFrame:CGRectMake(8, 28, width - 16, 20)];
        name.text = att[@"name"];
        name.font = [UIFont systemFontOfSize:12];
        name.textColor = [Theme text];
        name.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [chip addSubview:name];
    }

    UIButton *remove = [UIButton buttonWithType:UIButtonTypeCustom];
    remove.frame = CGRectMake(width - 24, 4, 20, 20);
    remove.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    remove.layer.cornerRadius = 10;
    remove.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBold];
    [remove setTitle:@"\u00D7" forState:UIControlStateNormal];
    [remove setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    remove.tag = (NSInteger)index;
    [remove addTarget:self action:@selector(removeAttachmentTapped:) forControlEvents:UIControlEventTouchUpInside];
    [chip addSubview:remove];
    return chip;
}

- (void)refreshAttachStrip {
    for (UIView *view in [self.attachStrip.subviews copy]) [view removeFromSuperview];
    NSString *cid = self.conversation[@"id"];
    CGFloat x = 12;
    for (NSUInteger i = 0; i < self.pendingAttachments.count; i++) {
        UIView *chip = [self chipForAttachment:self.pendingAttachments[i] conversation:cid index:i];
        chip.frame = CGRectMake(x, 4, chip.frame.size.width, 56);
        [self.attachStrip addSubview:chip];
        x += chip.frame.size.width + 8;
    }
    if (self.importsInFlight > 0) {
        UIView *busy = [[UIView alloc] initWithFrame:CGRectMake(x, 4, 56, 56)];
        busy.backgroundColor = [Theme selection];
        busy.layer.cornerRadius = 10;
        UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
        spinner.center = CGPointMake(28, 28);
        [spinner startAnimating];
        [busy addSubview:spinner];
        [self.attachStrip addSubview:busy];
        x += 64;
    }
    self.attachStrip.contentSize = CGSizeMake(x + 4, kStripHeight);
    [self relayoutAnimated];
}

- (void)removeAttachmentTapped:(UIButton *)sender {
    NSInteger index = sender.tag;
    if (index < 0 || index >= (NSInteger)self.pendingAttachments.count) return;
    [AttachmentStore deleteAttachment:self.pendingAttachments[index] conversation:self.conversation[@"id"]];
    [self.pendingAttachments removeObjectAtIndex:index];
    [self refreshAttachStrip];
    [self updateSendButton];
}

- (void)attachTapped {
    if (self.streaming) return;
    [self.view endEditing:YES];
    if ((NSInteger)self.pendingAttachments.count + self.importsInFlight >= kMaxAttachmentsPerMessage) {
        [self showAlertMessage:[NSString stringWithFormat:L(@"att_err_limit"), (long)kMaxAttachmentsPerMessage]];
        return;
    }

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:L(@"attach_title")
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    if ([UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypeCamera]) {
        [sheet addAction:[UIAlertAction actionWithTitle:L(@"attach_camera") style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [DiagnosticLog log:@"attach: camera chosen"];
            [weakSelf presentImagePickerWithSource:UIImagePickerControllerSourceTypeCamera];
        }]];
    }
    if ([UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypePhotoLibrary]) {
        [sheet addAction:[UIAlertAction actionWithTitle:L(@"attach_photo") style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [DiagnosticLog log:@"attach: photo library chosen"];
            [weakSelf presentImagePickerWithSource:UIImagePickerControllerSourceTypePhotoLibrary];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:L(@"attach_file") style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [DiagnosticLog log:@"attach: file picker chosen"];
        [weakSelf presentDocumentPicker];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:L(@"cancel") style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.attachButton;
    sheet.popoverPresentationController.sourceRect = self.attachButton.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)presentImagePickerWithSource:(UIImagePickerControllerSourceType)source {
    UIImagePickerController *picker = [[UIImagePickerController alloc] init];
    picker.sourceType = source;
    picker.mediaTypes = @[@"public.image"];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)presentDocumentPicker {
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.data", @"public.content", @"public.movie", @"public.video", @"com.apple.quicktime-movie", @"public.mpeg-4"]
                                                               inMode:UIDocumentPickerModeImport];
    picker.delegate = self;
    picker.allowsMultipleSelection = YES;
    [self presentViewController:picker animated:YES completion:nil];
}

#pragma mark UIImagePickerControllerDelegate

- (void)imagePickerController:(UIImagePickerController *)picker
didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey, id> *)info {
    NSURL *imageURL = info[UIImagePickerControllerImageURL];
    UIImage *original = info[UIImagePickerControllerOriginalImage];
    [picker dismissViewControllerAnimated:YES completion:nil];

    [self runImportWithWork:^NSDictionary *(NSString *cid, NSString **errorKey) {
        NSData *data = imageURL ? [NSData dataWithContentsOfURL:imageURL] : nil;
        if (data.length == 0 && original) data = UIImageJPEGRepresentation(original, 0.9);
        return [AttachmentStore importImageData:data name:imageURL.lastPathComponent conversation:cid errorKey:errorKey];
    }];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark UIDocumentPickerDelegate

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    for (NSURL *url in urls) {
        [self runImportWithWork:^NSDictionary *(NSString *cid, NSString **errorKey) {
            return [AttachmentStore importDocumentAtURL:url conversation:cid errorKey:errorKey];
        }];
    }
}

#pragma mark Import pipeline

- (void)runImportWithWork:(NSDictionary *(^)(NSString *cid, NSString **errorKey))work {
    NSString *cid = self.conversation[@"id"];
    self.importsInFlight++;
    [self refreshAttachStrip];
    [self updateSendButton];

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *errorKey = nil;
        NSDictionary *attachment = work(cid, &errorKey);
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf finishImport:attachment conversation:cid errorKey:errorKey];
        });
    });
}

- (void)finishImport:(NSDictionary *)attachment conversation:(NSString *)cid errorKey:(NSString *)errorKey {
    self.importsInFlight = MAX(0, self.importsInFlight - 1);
    NSString *problem = nil;

    if (attachment) {
        if (![cid isEqualToString:self.conversation[@"id"]]) {
            [AttachmentStore deleteAttachment:attachment conversation:cid];
        } else if ((NSInteger)self.pendingAttachments.count >= kMaxAttachmentsPerMessage) {
            [AttachmentStore deleteAttachment:attachment conversation:cid];
            problem = [NSString stringWithFormat:L(@"att_err_limit"), (long)kMaxAttachmentsPerMessage];
        } else if ([self inlineBytesOf:self.pendingAttachments] + [self inlineBytesOf:@[attachment]] > kMaxInlineBytesPerMessage) {
            [AttachmentStore deleteAttachment:attachment conversation:cid];
            problem = L(@"att_err_budget");
        } else {
            [self.pendingAttachments addObject:attachment];
        }
    } else {
        problem = L(errorKey ?: @"att_err_unreadable");
    }

    [DiagnosticLog log:@"attachment: %@", attachment ? [NSString stringWithFormat:@"ok kind=%@ bytes=%@", attachment[@"kind"], attachment[@"bytes"]]
                                                       : [NSString stringWithFormat:@"failed (%@)", errorKey ?: @"unknown"]];
    if (attachment && problem) [DiagnosticLog log:@"attachment rejected after import: %@", ClippedForLog(problem)];
    [self refreshAttachStrip];
    [self updateSendButton];
    if (problem) [self showAlertMessage:problem];
}

#pragma mark - Sending

- (void)sendTapped {
    if (self.streaming) {
        [self.stream cancel];
        return;
    }
    NSString *text = [self trimmedInput];
    BOOL hasAttachments = self.pendingAttachments.count > 0;
    if ((text.length == 0 && !hasAttachments) || !self.webReady || self.importsInFlight > 0) return;

    NSString *lowerText = text.lowercaseString;
    if ([lowerText hasPrefix:@"/tạo ảnh"]) {
        NSString *imagePrompt = [[text substringFromIndex:([@"/tạo ảnh" length])] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (imagePrompt.length == 0) { [self showAlertMessage:@"Hãy nhập mô tả ảnh sau lệnh /tạo ảnh."]; return; }
        if (![KeyStore hasKeyForProvider:AIProviderGemini]) {
            [self showAlertMessage:@"Tạo ảnh cần Gemini API key. Hãy thêm key Gemini trong Cài đặt."];
            return;
        }
        NSString *currentModel = self.model.lowercaseString;
        NSString *imageModel = ([currentModel containsString:@"image"] || [currentModel containsString:@"nano-banana"])
            && [Provider forModelId:self.model] == AIProviderGemini ? self.model : nil;
        if (!imageModel) {
            for (NSDictionary *model in [ModelStore cachedModelsForProvider:AIProviderGemini]) {
                NSString *mid = [model[@"id"] isKindOfClass:[NSString class]] ? model[@"id"] : @"";
                NSString *name = [model[@"name"] isKindOfClass:[NSString class]] ? model[@"name"] : @"";
                NSString *lowerID = mid.lowercaseString;
                NSString *lowerName = name.lowercaseString;
                if ([lowerID containsString:@"image"] || [lowerID containsString:@"nano-banana"] ||
                    [lowerName containsString:@"image generation"] || [lowerName containsString:@"nano banana"]) { imageModel = mid; break; }
            }
        }
        if (imageModel.length == 0) {
            [self showAlertMessage:@"Danh sách model Gemini hiện tại chưa có model tạo ảnh. Hãy làm mới danh sách model hoặc chọn model Gemini hỗ trợ tạo ảnh."];
            [self refreshModels];
            return;
        }
        self.model = imageModel;
        [ModelStore setSelectedModelId:imageModel];
        self.conversation[@"model"] = imageModel;
        [self updateModelTitle];
        text = [NSString stringWithFormat:@"Create an image based on this prompt: %@", imagePrompt];
    }

    if (![KeyStore hasAnyKey]) {
        [[NSNotificationCenter defaultCenter] postNotificationName:kNotifKeyChanged object:nil];
        return;
    }
    if (self.model.length == 0) {
        [self modelTapped];
        return;
    }
    if (![self checkKeyForCurrentModel]) return;

    NSString *cid = self.conversation[@"id"];
    NSArray *attachments = [self.pendingAttachments copy];
    NSMutableDictionary *message = [@{ @"role": @"user", @"text": text, @"ts": @([[NSDate date] timeIntervalSince1970]) } mutableCopy];
    if (hasAttachments) message[@"attachments"] = attachments;

    NSMutableArray *messages = self.conversation[@"messages"];
    [messages addObject:message];
    if ([self.conversation[@"title"] length] == 0) {
        NSString *source = text.length > 0 ? text : (attachments.firstObject[@"name"] ?: @"");
        self.conversation[@"title"] = [self titleFromText:source];
    }
    self.conversation[@"model"] = self.model;
    self.conversation[@"updated"] = @([[NSDate date] timeIntervalSince1970]);
    [ConversationStore saveConversation:self.conversation];

    [self callJS:@"addUser" args:@[text, [self webAttachmentsFrom:attachments conversation:cid], @([messages count] - 1)]];
    [self.pendingAttachments removeAllObjects];
    [self refreshAttachStrip];
    self.textView.text = @"";
    [self textViewDidChange:self.textView];
    [self startStreamingReply];
}

- (NSString *)titleFromText:(NSString *)text {
    NSString *firstLine = [[text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]] firstObject];
    firstLine = [firstLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (firstLine.length <= 40) return firstLine;
    NSRange range = [firstLine rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, 40)];
    return [[firstLine substringWithRange:range] stringByAppendingString:@"…"];
}

#pragma mark - Request contents

- (void)addPartsForAttachment:(NSDictionary *)att
                 conversation:(NSString *)cid
                    inlineIds:(NSSet *)inlineIds
                           to:(NSMutableArray *)parts {
    if (![att isKindOfClass:[NSDictionary class]]) return;
    NSString *kind = att[@"kind"];
    NSString *name = [att[@"name"] isKindOfClass:[NSString class]] ? att[@"name"] : @"file";
    NSString *path = [AttachmentStore pathForFile:att[@"file"] conversation:cid];

    if ([kind isEqualToString:@"text"]) {
        NSString *content = path ? [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] : nil;
        NSString *text = content.length > 0
            ? [NSString stringWithFormat:@"[Attached file: %@]\n%@", name, content]
            : [NSString stringWithFormat:@"[Attached file unavailable: %@]", name];
        [parts addObject:@{ @"type": @"text", @"text": text }];
    } else if ([kind isEqualToString:@"video"]) {
        NSArray *frames = [att[@"frames"] isKindOfClass:[NSArray class]] ? att[@"frames"] : @[];
        if ([inlineIds containsObject:att[@"id"]] && frames.count > 0) {
            NSUInteger addedFrames = 0;
            for (NSString *frameFile in frames) {
                NSString *framePath = [AttachmentStore pathForFile:frameFile conversation:cid];
                NSData *frameData = framePath ? [NSData dataWithContentsOfFile:framePath] : nil;
                if (frameData.length == 0) continue;
                [parts addObject:@{ @"type": @"image", @"mime": @"image/jpeg",
                                    @"data": [frameData base64EncodedStringWithOptions:0] }];
                addedFrames++;
            }
            if (addedFrames == 0) [parts addObject:@{ @"type": @"text", @"text": [NSString stringWithFormat:@"[Video frames unavailable: %@]", name] }];
        } else {
            [parts addObject:@{ @"type": @"text", @"text": [NSString stringWithFormat:@"[Earlier video not included: %@]", name] }];
        }
    } else if ([kind isEqualToString:@"image"] || [kind isEqualToString:@"pdf"]) {
        NSData *data = ([inlineIds containsObject:att[@"id"]] && path) ? [NSData dataWithContentsOfFile:path] : nil;
        if (data.length > 0) {
            NSString *encoded = [data base64EncodedStringWithOptions:0];
            if ([kind isEqualToString:@"pdf"]) {
                [parts addObject:@{ @"type": @"pdf", @"data": encoded }];
            } else {
                NSString *mime = [att[@"mime"] isKindOfClass:[NSString class]] ? att[@"mime"] : @"image/jpeg";
                [parts addObject:@{ @"type": @"image", @"mime": mime, @"data": encoded }];
                [DiagnosticLog log:@"image attachment inlined for API: %@ bytes=%lu mime=%@", name, (unsigned long)data.length, mime];
            }
        } else {
            [parts addObject:@{ @"type": @"text", @"text": [NSString stringWithFormat:@"[Earlier attachment not included: %@]", name] }];
            [DiagnosticLog log:@"image/pdf attachment not inlined: %@ id=%@ pathReadable=%@", name, att[@"id"] ?: @"-", path && [[NSFileManager defaultManager] isReadableFileAtPath:path] ? @"yes" : @"no"];
        }
    }
}

- (NSArray *)buildTurns {
    NSString *cid = self.conversation[@"id"];
    NSArray *messages = self.conversation[@"messages"];

    NSInteger memory = [AppSettings attachmentMemory];
    NSInteger mediaMessages = 0;
    NSMutableSet *inlineIds = [NSMutableSet set];
    NSUInteger remaining = kMaxInlineBytesPerMessage;
    for (NSInteger i = (NSInteger)messages.count - 1; i >= 0; i--) {
        NSArray *atts = messages[i][@"attachments"];
        if (![atts isKindOfClass:[NSArray class]]) continue;
        BOOL hasMedia = NO;
        for (NSDictionary *att in atts) {
            NSString *kind = att[@"kind"];
            if ([kind isEqualToString:@"image"] || [kind isEqualToString:@"pdf"] || [kind isEqualToString:@"video"]) { hasMedia = YES; break; }
        }
        if (!hasMedia) continue;
        mediaMessages++;
        if (memory > 0 && mediaMessages > memory) continue;
        for (NSDictionary *att in atts) {
            NSString *kind = att[@"kind"];
            if (![kind isEqualToString:@"image"] && ![kind isEqualToString:@"pdf"] && ![kind isEqualToString:@"video"]) continue;
            NSUInteger bytes = [att[@"bytes"] unsignedIntegerValue];
            if (bytes <= remaining && att[@"id"]) {
                remaining -= bytes;
                [inlineIds addObject:att[@"id"]];
            }
        }
    }

    NSMutableArray *turns = [NSMutableArray array];
    for (NSDictionary *message in messages) {
        NSString *role = message[@"role"];
        if (![role isKindOfClass:[NSString class]]) continue;
        NSString *text = [message[@"text"] isKindOfClass:[NSString class]] ? message[@"text"] : @"";
        NSString *turnRole = [role isEqualToString:@"user"] ? @"user" : @"assistant";

        NSMutableArray *parts = [NSMutableArray array];
        NSArray *atts = [message[@"attachments"] isKindOfClass:[NSArray class]] ? message[@"attachments"] : @[];
        for (NSDictionary *att in atts) [self addPartsForAttachment:att conversation:cid inlineIds:inlineIds to:parts];
        if (text.length > 0) [parts addObject:@{ @"type": @"text", @"text": text }];
        if (parts.count == 0) continue;

        NSMutableDictionary *last = turns.lastObject;
        if (last && [last[@"role"] isEqualToString:turnRole]) {
            [last[@"parts"] addObjectsFromArray:parts];
        } else {
            [turns addObject:[@{ @"role": turnRole, @"parts": parts } mutableCopy]];
        }
    }

    NSUInteger contextLimit = [AppSettings contextLimitChars];
    AIProvider provider = [Provider forModelId:self.model];
    NSInteger inputTokenCap = [ModelStore maxInputTokensForModelId:self.model provider:provider];
    if (inputTokenCap > 0) {
        NSUInteger modelCharCap = (NSUInteger)inputTokenCap * 2;
        NSUInteger reservedChars = [self effectiveSystemPrompt].length + 4096;
        modelCharCap = modelCharCap > reservedChars ? modelCharCap - reservedChars : 4096;
        contextLimit = MIN(contextLimit, modelCharCap);
    } else {
        contextLimit = MIN(contextLimit, (NSUInteger)32000);
    }

    while (turns.count > 1 && [self totalTextChars:turns] > contextLimit) [turns removeObjectAtIndex:0];
    while (turns.count > 1 && [turns.firstObject[@"role"] isEqualToString:@"assistant"]) [turns removeObjectAtIndex:0];

    if (turns.count == 1 && [self totalTextChars:turns] > contextLimit) {
        NSMutableArray *parts = turns.firstObject[@"parts"];
        NSString *marker = @"[Earlier text omitted to fit the model context]\n";
        for (NSInteger i = 0; i < (NSInteger)parts.count && [self totalTextChars:turns] > contextLimit; i++) {
            NSMutableDictionary *part = parts[(NSUInteger)i];
            NSString *content = [part[@"text"] isKindOfClass:[NSString class]] ? part[@"text"] : nil;
            if (content.length == 0) continue;

            NSUInteger total = [self totalTextChars:turns];
            NSUInteger excess = total - contextLimit;
            if (content.length <= excess) {
                [parts removeObjectAtIndex:(NSUInteger)i];
                i--;
                continue;
            }

            NSUInteger otherChars = total - content.length;
            NSUInteger available = contextLimit > otherChars + marker.length
                ? contextLimit - otherChars - marker.length : 0;
            NSUInteger keep = MIN(available, content.length - excess);
            if (keep > 0) {
                NSUInteger start = content.length - keep;
                NSRange safe = [content rangeOfComposedCharacterSequencesForRange:NSMakeRange(start, keep)];
                part[@"text"] = [marker stringByAppendingString:[content substringWithRange:safe]];
                break;
            }

            [parts removeObjectAtIndex:(NSUInteger)i];
            i--;
        }
    }
    return turns;
}

- (NSUInteger)totalTextChars:(NSArray *)turns {
    NSUInteger total = 0;
    for (NSDictionary *turn in turns) {
        for (NSDictionary *part in turn[@"parts"]) {
            NSString *text = part[@"text"];
            if ([text isKindOfClass:[NSString class]]) total += text.length;
        }
    }
    return total;
}

#pragma mark - Streaming

- (BOOL)checkKeyForCurrentModel {
    AIProvider provider = [Provider forModelId:self.model];
    if ([KeyStore hasKeyForProvider:provider]) return YES;
    [self showAlertMessage:[NSString stringWithFormat:L(@"err_no_key_for_provider"), [Provider nameFor:provider]]];
    return NO;
}

- (void)startStreamingReply {
    if (![self checkKeyForCurrentModel]) return;
    self.streamBuffer = [NSMutableString string];
    self.streamRetryCount = 0;
    self.didRecoverModel404 = NO;
    self.didFallbackFromFastMode = NO;
    self.streaming = YES;
    [self updateSendButton];
    [self callJS:@"begin" args:@[]];
    [self launchRequestStreaming:YES];
}

- (NSString *)effectiveSystemPrompt {
    NSString *own = self.conversation[@"system"];
    NSString *prompt = ([own isKindOfClass:[NSString class]] && own.length > 0) ? own : [AppSettings systemPrompt];
    NSInteger inputTokenCap = [ModelStore maxInputTokensForModelId:self.model provider:[Provider forModelId:self.model]];
    NSUInteger promptBudget = inputTokenCap > 0
        ? MIN((NSUInteger)48000, MAX((NSUInteger)6000, ((NSUInteger)inputTokenCap * 2) / 5))
        : 16000;
    NSString *query = @"";
    NSArray *messages = self.conversation[@"messages"];
    for (NSInteger i = (NSInteger)messages.count - 1; i >= 0; i--) {
        NSDictionary *message = messages[(NSUInteger)i];
        if ([message[@"role"] isEqualToString:@"user"] && [message[@"text"] isKindOfClass:[NSString class]]) {
            query = message[@"text"];
            break;
        }
    }
    return [AppSettings promptText:prompt forQuery:query characterBudget:promptBudget];
}

- (NSString *)summaryOfTurns:(NSArray *)turns {
    NSUInteger images = 0, pdfs = 0, mediaChars = 0, textChars = 0;
    for (NSDictionary *turn in turns) {
        for (NSDictionary *part in turn[@"parts"]) {
            NSString *type = part[@"type"];
            if ([type isEqualToString:@"image"]) { images++; mediaChars += [part[@"data"] length]; }
            else if ([type isEqualToString:@"pdf"]) { pdfs++; mediaChars += [part[@"data"] length]; }
            else textChars += [part[@"text"] length];
        }
    }
    return [NSString stringWithFormat:@"turns=%lu images=%lu pdfs=%lu media=%.1fMB textChars=%lu",
            (unsigned long)turns.count, (unsigned long)images, (unsigned long)pdfs, mediaChars / 1048576.0, (unsigned long)textChars];
}

- (void)launchRequestStreaming:(BOOL)useStreaming {
    self.attemptIsStreaming = useStreaming;
    AIProvider provider = [Provider forModelId:self.model];
    NSString *key = [KeyStore loadKeyForProvider:provider] ?: @"";
    NSArray *turns = [self buildTurns];
    NSString *system = [self effectiveSystemPrompt];
    id<ChatStreaming> stream = (provider == AIProviderClaude)
        ? (id<ChatStreaming>)[[ClaudeStream alloc] initWithKey:key model:self.model turns:turns system:system]
        : (id<ChatStreaming>)[[GeminiStream alloc] initWithKey:key model:self.model turns:turns system:system];
    if (provider == AIProviderClaude) {
        ((ClaudeStream *)stream).useFastSpeed = [AppSettings fastModeEnabled] && !self.didFallbackFromFastMode;
    }
    stream.useStreaming = useStreaming;
    self.stream = stream;
    if (!self.streamGeneratedAttachments) self.streamGeneratedAttachments = [NSMutableArray array];
    self.requestStartTime = CFAbsoluteTimeGetCurrent();
    [DiagnosticLog log:@"request: %@ model=%@ mode=%@ %@ systemChars=%lu", [Provider nameFor:provider], self.model,
                       useStreaming ? @"stream" : @"single", [self summaryOfTurns:turns], (unsigned long)system.length];
    __weak typeof(self) weakSelf = self;
    __weak id<ChatStreaming> weakStream = stream;
    stream.onDelta = ^(NSString *text) {
        ChatViewController *me = weakSelf;
        if (!me || me.stream != weakStream) return;
        [me.streamBuffer appendString:text];
        [me callJS:@"delta" args:@[text]];
    };
    stream.onImage = ^(NSData *data, NSString *mimeType) {
        ChatViewController *me = weakSelf;
        if (!me || me.stream != weakStream || data.length == 0) return;
        NSString *errorKey = nil;
        NSString *imageName = @"generated-image.jpg";
        NSDictionary *attachment = [AttachmentStore importImageData:data name:imageName
                                                         conversation:me.conversation[@"id"] errorKey:&errorKey];
        if (attachment) {
            [me.streamGeneratedAttachments addObject:attachment];
            [DiagnosticLog log:@"generated image saved: bytes=%@ mime=%@", attachment[@"bytes"], mimeType ?: @"image/*"];
        } else {
            [DiagnosticLog log:@"generated image could not be stored: %@", errorKey ?: @"unknown"];
        }
    };
    stream.onUsage = ^(long long inputTokens, long long outputTokens) {
        ChatViewController *me = weakSelf;
        if (!me || me.stream != weakStream) return;
        [AppSettings addDailyTokenUsage:(inputTokens + outputTokens)];
        [me updateDailyTokenPrompt];
        [DiagnosticLog log:@"usage: input=%lld output=%lld dayTotal=%lld", inputTokens, outputTokens, [AppSettings dailyTokenUsage]];
    };
    stream.onFinish = ^(GeminiStreamError error, NSInteger status, NSString *detail) {
        ChatViewController *me = weakSelf;
        if (!me || me.stream != weakStream) return;
        [me streamFinishedWithError:error status:status detail:detail];
    };
    [stream start];
}

- (void)streamFinishedWithError:(GeminiStreamError)error status:(NSInteger)status detail:(NSString *)detail {
    NSString *partial = [self.streamBuffer copy] ?: @"";
    [DiagnosticLog log:@"reply: model=%@ mode=%@ result=%@ http=%ld textChars=%lu elapsed=%.0fms detail=%@", self.model,
                       self.attemptIsStreaming ? @"stream" : @"single", StreamErrorName(error), (long)status,
                       (unsigned long)partial.length, (CFAbsoluteTimeGetCurrent() - self.requestStartTime) * 1000, ClippedForLog(detail)];

    AIProvider currentProvider = [Provider forModelId:self.model];
    BOOL largeClaudeReply = currentProvider == AIProviderClaude && [AppSettings maxOutputTokens] > 21333;

    BOOL wasFastRequest = currentProvider == AIProviderClaude && self.stream && ((ClaudeStream *)self.stream).useFastSpeed;
    NSString *fastErrorText = [detail lowercaseString] ?: @"";
    BOOL fastRateLimited = wasFastRequest && (status == 429 || status == 529);
    BOOL fastRejected = wasFastRequest && (status == 400 || status == 403) &&
                        ([fastErrorText containsString:@"fast"] || [fastErrorText containsString:@"speed"]);
    if ((fastRateLimited || fastRejected) && partial.length == 0 &&
        self.streamGeneratedAttachments.count == 0 && !self.didFallbackFromFastMode) {
        self.didFallbackFromFastMode = YES;
        NSTimeInterval fastRetryAfter = self.stream.retryAfterSeconds;
        self.stream = nil;
        if (fastRejected) {
            [AppSettings setFastModeEnabled:NO];
            [self updateToolButtons];
        }
        [DiagnosticLog log:fastRateLimited
            ? @"Claude Fast mode capacity unavailable; retrying once at standard speed"
            : @"Claude Fast mode rejected by model/account; retrying once at standard speed and disabling Fast mode"];
        NSTimeInterval fallbackDelay = fastRateLimited ? MAX(1.0, MIN(60.0, fastRetryAfter)) : 1.0;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(fallbackDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (self.streaming && self.stream == nil) [self launchRequestStreaming:self.attemptIsStreaming];
        });
        return;
    }

    BOOL retryableStatus = (status == 429 || status == 500 || status == 502 || status == 503 || status == 504 || status == 529);
    BOOL transientServer = (error == GeminiStreamErrorServer || error == GeminiStreamErrorRateLimited) && retryableStatus;
    if (transientServer && partial.length == 0 && self.streamGeneratedAttachments.count == 0 && self.streamRetryCount < 3) {
        NSTimeInterval providerDelay = self.stream.retryAfterSeconds;
        self.stream = nil;
        self.streamRetryCount++;
        NSTimeInterval backoff = self.streamRetryCount == 1 ? 2.0 : (self.streamRetryCount == 2 ? 5.0 : 10.0);
        NSTimeInterval delay = MAX(backoff, MIN(60.0, providerDelay));
        [DiagnosticLog log:@"server overload HTTP %ld: retry %ld after %.0fs", (long)status, (long)self.streamRetryCount, delay];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (self.streaming && self.stream == nil) [self launchRequestStreaming:YES];
        });
        return;
    }

    if (error == GeminiStreamErrorModelNotFound && status == 404 && partial.length == 0 && !self.didRecoverModel404) {
        self.stream = nil;
        self.didRecoverModel404 = YES;
        NSString *key = [KeyStore loadKeyForProvider:currentProvider] ?: @"";
        __weak typeof(self) weakSelf = self;
        GeminiModelsCompletion completion = ^(NSArray *models, GeminiCheckResult result) {
            ChatViewController *me = weakSelf;
            if (!me || !me.streaming) return;
            if (result != GeminiCheckOK || models.count == 0) {
                me.streaming = NO;
                me.stream = nil;
                me.streamBuffer = nil;
                me.streamGeneratedAttachments = nil;
                [me callJS:@"end" args:@[@""]];
                NSString *reason = result == GeminiCheckRateLimited
                    ? @"API đang giới hạn yêu cầu khi làm mới danh sách model. Hãy đợi rồi thử lại."
                    : @"Không làm mới được danh sách model để khôi phục lỗi 404. Kiểm tra API key, quyền truy cập và kết nối.";
                [me callJS:@"error" args:@[reason, @YES]];
                [me updateSendButton];
                [DiagnosticLog log:@"404 recovery model refresh failed: result=%ld models=%lu", (long)result, (unsigned long)models.count];
                return;
            }
            [ModelStore saveModels:models forProvider:currentProvider];
            BOOL selectedStillExists = NO;
            for (NSDictionary *item in models) if ([item[@"id"] isEqualToString:me.model]) { selectedStillExists = YES; break; }
            if (!selectedStillExists) {
                NSString *fallback = [ModelStore defaultModelIdForProvider:currentProvider models:models];
                if (fallback.length > 0) {
                    me.model = fallback;
                    [ModelStore setSelectedModelId:fallback];
                    me.conversation[@"model"] = fallback;
                    [me updateModelTitle];
                    [DiagnosticLog log:@"stale model recovered from HTTP 404: switched to %@", fallback];
                    [me launchRequestStreaming:me.attemptIsStreaming];
                    return;
                }
            }
            me.streaming = NO;
            me.streamBuffer = nil;
            [me callJS:@"end" args:@[@""]];
            [me callJS:@"error" args:@[[me messageForError:GeminiStreamErrorModelNotFound status:404 detail:detail], @YES]];
            [me updateSendButton];
        };
        if (currentProvider == AIProviderClaude) [ClaudeClient fetchModelsWithKey:key completion:completion];
        else [GeminiClient fetchModelsWithKey:key completion:completion];
        return;
    }

    if (error == GeminiStreamErrorNetwork && partial.length == 0 && self.streamGeneratedAttachments.count == 0 && self.attemptIsStreaming) {
        self.stream = nil;
        if (largeClaudeReply && self.streamRetryCount < 1) {
            self.streamRetryCount++;
            [DiagnosticLog log:@"large Claude stream failed before first event: retrying stream once"];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (self.streaming && self.stream == nil) [self launchRequestStreaming:YES];
            });
            return;
        }
        if (!largeClaudeReply) {
            [DiagnosticLog log:@"live stream failed before any text: retrying once as a single request"];
            [self launchRequestStreaming:NO];
            return;
        }
    }

    self.stream = nil;
    self.streamBuffer = nil;
    self.streaming = NO;

    NSArray *generatedAttachments = [self.streamGeneratedAttachments copy] ?: @[];
    if (partial.length > 0 || generatedAttachments.count > 0) {
        [self appendAssistantMessage:partial attachments:generatedAttachments];
    }
    self.streamGeneratedAttachments = nil;
    [self callJS:@"end" args:@[partial]];
    if (generatedAttachments.count > 0) [self renderConversation];
    if (error != GeminiStreamErrorNone && error != GeminiStreamErrorCancelled) {
        [self callJS:@"error" args:@[[self messageForError:error status:status detail:detail], @YES]];
    }
    [self updateSendButton];
}

- (void)appendAssistantMessage:(NSString *)text {
    [self appendAssistantMessage:text attachments:@[]];
}

- (void)appendAssistantMessage:(NSString *)text attachments:(NSArray *)attachments {
    NSMutableDictionary *message = [@{ @"role": @"model", @"text": text ?: @"",
                                        @"ts": @([[NSDate date] timeIntervalSince1970]) } mutableCopy];
    if (attachments.count > 0) message[@"attachments"] = attachments;
    NSMutableArray *messages = self.conversation[@"messages"];
    [messages addObject:message];
    self.conversation[@"updated"] = @([[NSDate date] timeIntervalSince1970]);
    [ConversationStore saveConversation:self.conversation];
}

- (void)abandonStream {
    if (!self.stream) return;
    NSString *partial = [self.streamBuffer copy] ?: @"";
    id<ChatStreaming> old = self.stream;
    old.onDelta = nil;
    old.onFinish = nil;
    self.stream = nil;
    self.streamBuffer = nil;
    self.streaming = NO;
    [old cancel];
    NSArray *generatedAttachments = [self.streamGeneratedAttachments copy] ?: @[];
    if (partial.length > 0 || generatedAttachments.count > 0) [self appendAssistantMessage:partial attachments:generatedAttachments];
    self.streamGeneratedAttachments = nil;
    [self updateSendButton];
}

- (void)editMessageAtIndex:(NSInteger)index {
    if (self.streaming || !self.webReady) return;
    NSMutableArray *messages = self.conversation[@"messages"];
    if (index < 0 || index >= (NSInteger)messages.count) return;
    NSDictionary *target = messages[(NSUInteger)index];
    if (![target[@"role"] isEqualToString:@"user"]) return;

    NSString *cid = self.conversation[@"id"];
    for (NSDictionary *att in self.pendingAttachments) [AttachmentStore deleteAttachment:att conversation:cid];
    [self.pendingAttachments removeAllObjects];

    NSString *text = [target[@"text"] isKindOfClass:[NSString class]] ? target[@"text"] : @"";
    NSArray *attachments = [target[@"attachments"] isKindOfClass:[NSArray class]] ? [target[@"attachments"] copy] : @[];

    for (NSInteger i = (NSInteger)messages.count - 1; i >= index; i--) {
        if (i != index) {
            NSArray *laterAttachments = [messages[(NSUInteger)i][@"attachments"] isKindOfClass:[NSArray class]]
                ? messages[(NSUInteger)i][@"attachments"] : @[];
            for (NSDictionary *att in laterAttachments) [AttachmentStore deleteAttachment:att conversation:cid];
        }
    }
    [messages removeObjectsInRange:NSMakeRange((NSUInteger)index, messages.count - (NSUInteger)index)];
    [self.pendingAttachments addObjectsFromArray:attachments];

    self.conversation[@"updated"] = @([[NSDate date] timeIntervalSince1970]);
    [ConversationStore saveConversation:self.conversation];
    [self renderConversation];
    [self refreshAttachStrip];
    self.textView.text = text;
    [self textViewDidChange:self.textView];
    [self updateSendButton];
    [self.textView becomeFirstResponder];
}

- (void)regenerate {
    if (self.streaming || !self.webReady) return;
    NSMutableArray *messages = self.conversation[@"messages"];
    if ([messages.lastObject[@"role"] isEqualToString:@"model"]) [messages removeLastObject];
    if (![messages.lastObject[@"role"] isEqualToString:@"user"]) return;
    self.conversation[@"updated"] = @([[NSDate date] timeIntervalSince1970]);
    [ConversationStore saveConversation:self.conversation];
    [self renderConversation];
    [self startStreamingReply];
}

#pragma mark - Error text

- (NSString *)messageForError:(GeminiStreamError)error status:(NSInteger)status detail:(NSString *)detail {
    NSString *base = nil;
    BOOL showDetail = NO;
    switch (error) {
        case GeminiStreamErrorInvalidKey:       base = L(@"err_invalid_key"); break;
        case GeminiStreamErrorPermissionDenied: base = L(@"err_permission"); showDetail = YES; break;
        case GeminiStreamErrorModelNotFound:    base = L(@"err_model_not_found"); break;
        case GeminiStreamErrorRateLimited:      base = L(@"err_rate"); break;
        case GeminiStreamErrorNetwork:          base = L(@"err_network"); showDetail = YES; break;
        case GeminiStreamErrorBlocked:          base = L(@"err_blocked"); break;
        case GeminiStreamErrorEmptyReply:       base = L(@"err_empty_reply"); break;
        case GeminiStreamErrorTooLarge:         base = L(@"err_too_large"); break;
        case GeminiStreamErrorNoCredit:         base = L(@"err_no_credit"); break;
        case GeminiStreamErrorServer:
            base = [NSString stringWithFormat:L(@"err_server"), (long)status];
            showDetail = YES;
            break;
        default:
            base = [NSString stringWithFormat:L(@"err_unknown"), (long)status];
            showDetail = YES;
            break;
    }
    if (showDetail && detail.length > 0) {
        NSString *clipped = detail.length > 240 ? [[detail substringToIndex:240] stringByAppendingString:@"…"] : detail;
        base = [base stringByAppendingFormat:@"\n\n%@", [NSString stringWithFormat:L(@"err_detail"), clipped]];
    }
    return base;
}

@end
