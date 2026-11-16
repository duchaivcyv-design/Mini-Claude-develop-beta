#import "ChatViewController.h"
#import <WebKit/WebKit.h>
#import <PhotosUI/PhotosUI.h>
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
static const CGFloat kToolsRowHeight = 0;       // the row of 4 tool buttons is hidden
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
                                  UIImagePickerControllerDelegate, UINavigationControllerDelegate, UIDocumentPickerDelegate,
                                  PHPickerViewControllerDelegate>
@property (strong, nonatomic) WKWebView *webView;
@property (assign, nonatomic) BOOL webReady;
@property (copy, nonatomic) NSString *lastWebError;

@property (strong, nonatomic) UIView *inputBar;
@property (strong, nonatomic) UIScrollView *attachStrip;
@property (strong, nonatomic) UIView *inputBox;
@property (strong, nonatomic) UIButton *attachButton;
@property (strong, nonatomic) UIButton *searchChipButton;
@property (strong, nonatomic) UIView *toolMenuOverlay;
@property (strong, nonatomic) UIView *toolMenuCard;
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
@property (strong, nonatomic) UIImageView *wallpaperView;   // chat wallpaper, behind the (transparent) web page
@property (strong, nonatomic) UIView *dimView;                 // darkens the wallpaper in dark mode
@property (assign, nonatomic) CGFloat keyboardOverlap;

@property (strong, nonatomic) NSMutableDictionary *conversation;
@property (copy, nonatomic) NSString *model;
@property (strong, nonatomic) id<ChatStreaming> stream;
@property (assign, nonatomic) BOOL streaming;
@property (assign, nonatomic) CFAbsoluteTime requestStartTime;
@property (assign, nonatomic) NSUInteger greetingIndex;     // which of the kGreetingCount lines this empty chat shows
@property (copy, nonatomic) NSString *shownGreeting;        // what the page currently shows, to avoid redrawing for nothing
@property (assign, nonatomic) BOOL attemptIsStreaming;   // the current request is a live stream (vs. single-shot fallback)
@property (assign, nonatomic) NSInteger streamRetryCount;
@property (assign, nonatomic) BOOL didRecoverModel404;
@property (assign, nonatomic) BOOL didFallbackFromFastMode;
@property (strong, nonatomic) NSMutableString *streamBuffer;
@property (strong, nonatomic) NSMutableString *longReplyAccumulator; // completed chunks from provider output-limit continuations
@property (assign, nonatomic) NSUInteger longReplyContinuationCount;
@property (strong, nonatomic) NSMutableArray *streamGeneratedAttachments;

@property (strong, nonatomic) NSMutableArray *pendingAttachments;   // attachments waiting to be sent with the next message
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
    [center addObserver:self selector:@selector(applyTheme) name:kNotifThemeChanged object:nil];

    // Attachment folders left behind by chats that were never saved (e.g. the app was closed with files attached).
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
    [self applyTheme];

    [self loadWebPage];
    [self refreshModels];

    // If the chat page never reports in, tell the user instead of showing a blank screen.
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
    [self ensureModelMatchesKeys];   // a key may have been added or removed in Settings
    [self updateModelTitle];
    [self updateDailyTokenPrompt];
    [self updateToolButtons];
    [self refreshGreetingIfEmpty];
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return [Theme darkMode] ? UIStatusBarStyleLightContent : UIStatusBarStyleDefault;
}

#pragma mark - Setup

- (void)setupWebView {
    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    WKUserContentController *controller = [[WKUserContentController alloc] init];
    [controller addScriptMessageHandler:[[WeakScriptHandler alloc] initWithTarget:self] name:@"native"];
    config.userContentController = controller;

    // The wallpaper sits behind the web page; the page itself is transparent so the wallpaper (or the plain skin colour) shows through.
    self.wallpaperView = [[UIImageView alloc] init];
    self.wallpaperView.contentMode = UIViewContentModeScaleAspectFill;
    self.wallpaperView.clipsToBounds = YES;
    self.wallpaperView.userInteractionEnabled = NO;
    self.wallpaperView.hidden = YES;
    [self.view addSubview:self.wallpaperView];
    self.dimView = [[UIView alloc] init];
    self.dimView.userInteractionEnabled = NO;
    [self.wallpaperView addSubview:self.dimView];

    self.webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:config];
    self.webView.navigationDelegate = self;
    self.webView.opaque = NO;
    self.webView.backgroundColor = [UIColor clearColor];
    self.webView.scrollView.backgroundColor = [UIColor clearColor];
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
    self.toolRow.hidden = YES;
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

    self.searchChipButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.searchChipButton.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    self.searchChipButton.layer.cornerRadius = 11;
    self.searchChipButton.clipsToBounds = YES;
    self.searchChipButton.backgroundColor = [UIColor colorWithRed:0.10 green:0.48 blue:0.34 alpha:0.18];
    [self.searchChipButton setTitleColor:[UIColor colorWithRed:0.22 green:0.82 blue:0.60 alpha:1.0] forState:UIControlStateNormal];
    [self.searchChipButton setTitle:@"⌕ Tìm kiếm   ×" forState:UIControlStateNormal];
    [self.searchChipButton addTarget:self action:@selector(searchChipTapped) forControlEvents:UIControlEventTouchUpInside];
    self.searchChipButton.hidden = YES;
    [self.inputBox addSubview:self.searchChipButton];

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
    BOOL searchActive = [AppSettings webSearchEnabled];
    CGFloat leftPad = 40;     // room for the attach button
    CGFloat rightPad = 44;    // room for the send button
    CGFloat textWidth = boxWidth - leftPad - rightPad;
    CGFloat fit = [self.textView sizeThatFits:CGSizeMake(textWidth, CGFLOAT_MAX)].height;
    CGFloat textHeight = MIN(MAX(fit, 38), kMaxInputHeight);
    self.textView.scrollEnabled = fit > kMaxInputHeight;

    // Search is shown as a compact removable chip in its own first line of the composer.
    CGFloat searchRowHeight = searchActive ? 27.0 : 0.0;
    CGFloat boxHeight = textHeight + 8 + searchRowHeight;
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
    self.searchChipButton.hidden = !searchActive;
    if (searchActive) self.searchChipButton.frame = CGRectMake(46, 5, 94, 22);
    self.textView.frame = CGRectMake(leftPad, searchRowHeight + 4, textWidth, textHeight);
    self.placeholderLabel.frame = CGRectMake(leftPad + 11, searchRowHeight + 13, textWidth - 12, 20);
    self.sendButton.frame = CGRectMake(boxWidth - 36 - 5, boxHeight - 36 - 5, 36, 36);
    [self updateToolButtons];

    self.webView.frame = CGRectMake(0, 0, width, CGRectGetMinY(self.inputBar.frame));
    self.wallpaperView.frame = self.webView.frame;
    self.dimView.frame = self.wallpaperView.bounds;
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
    self.fastButton.enabled = YES; // Unsupported models remain tappable so the UI can explain the limitation.
    self.fastButton.alpha = supportsFast ? 1.0 : 0.42;
    [self.fastButton setTitleColor:(supportsFast && [AppSettings fastModeEnabled]) ? active : [Theme secondaryText] forState:UIControlStateNormal];
    NSString *level = @[@"Thấp", @"Trung bình", @"Cao", @"Siêu cao", @"MAX ×8"][(NSUInteger)[AppSettings reasoningLevel]];
    [self.reasoningButton setTitle:[NSString stringWithFormat:@"🧠 %@", level] forState:UIControlStateNormal];
    [self.searchButton setTitle:[AppSettings webSearchEnabled] ? @"⌕ Tìm ✓" : @"⌕ Tìm kiếm" forState:UIControlStateNormal];
    self.searchChipButton.hidden = ![AppSettings webSearchEnabled];
    [self.searchChipButton setTitle:@"⌕ Tìm kiếm   ×" forState:UIControlStateNormal];
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
    [self relayoutAnimated];
}

- (void)searchChipTapped {
    if (![AppSettings webSearchEnabled]) return;
    [AppSettings setWebSearchEnabled:NO];
    [self updateToolButtons];
    [self relayoutAnimated];
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
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"@ Công cụ" message:@"Chọn tác vụ hoặc tích hợp" preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    NSArray *recent = self.conversation[@"messages"];
    NSString *lastReply = nil;
    for (NSInteger i = (NSInteger)recent.count - 1; i >= 0; i--) {
        NSDictionary *message = recent[(NSUInteger)i];
        if (![message[@"role"] isEqualToString:@"user"] && [message[@"text"] isKindOfClass:[NSString class]] && [message[@"text"] length] > 0) { lastReply = message[@"text"]; break; }
    }
    // Always show file-creation commands. If there is no assistant reply yet, use the
    // draft currently in the input box instead of hiding these actions from the @ menu.
    [sheet addAction:[UIAlertAction actionWithTitle:@"Tạo tệp TXT" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *source = lastReply.length > 0 ? lastReply : [weakSelf trimmedInput];
        if (source.length > 0) [weakSelf exportText:source asWord:NO];
        else [weakSelf showAlertMessage:@"Hãy nhập nội dung hoặc tạo câu trả lời trước khi xuất tệp TXT."];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Tạo tệp DOCX" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *source = lastReply.length > 0 ? lastReply : [weakSelf trimmedInput];
        if (source.length > 0) [weakSelf exportText:source asWord:YES];
        else [weakSelf showAlertMessage:@"Hãy nhập nội dung hoặc tạo câu trả lời trước khi xuất tệp DOCX."];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Chọn tệp để đính kèm…" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [weakSelf attachTapped];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"/tạo ảnh" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        weakSelf.textView.text = @"/tạo ảnh ";
        [weakSelf textViewDidChange:weakSelf.textView];
        [weakSelf.textView becomeFirstResponder];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:[AppSettings webSearchEnabled] ? @"Tắt tìm kiếm web" : @"Bật tìm kiếm web" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [weakSelf searchTapped]; }]];
    NSArray *external = @[@"Gmail", @"Google Calendar", @"Google Docs", @"Google Drive", @"Google Home", @"Google Keep", @"Google Photos", @"Google Sheets", @"Google Tasks"];
    for (NSString *name in external) {
        [sheet addAction:[UIAlertAction actionWithTitle:name style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [weakSelf showAlertMessage:[NSString stringWithFormat:@"%@ cần kết nối OAuth/API riêng. Phiên bản này chưa có thông tin xác thực để truy cập tài khoản.", name]];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:L(@"cancel") style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.mentionButton;
    sheet.popoverPresentationController.sourceRect = self.mentionButton.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)updateDailyTokenPrompt {
    self.navigationItem.prompt = nil;   // the "Token hôm nay" line is no longer shown
}

- (void)relayoutAnimated {
    [self.view setNeedsLayout];
    [UIView animateWithDuration:0.15 animations:^{ [self.view layoutIfNeeded]; }];
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
    while (top.presentedViewController) top = top.presentedViewController;   // a picker may still be on screen
    [top presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Web page

- (NSString *)resourceText:(NSString *)name ext:(NSString *)ext {
    NSString *path = [[NSBundle mainBundle] pathForResource:name ofType:ext inDirectory:@"web"];
    if (!path) return @"";
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    return text ?: @"";
}

// The page is assembled in memory and loaded as a string, so WebKit never needs file access
// to the app bundle (which is the fragile part for unsandboxed jailbreak apps).
- (void)loadWebPage {
    self.webReady = NO;
    NSString *html = [self resourceText:@"index" ext:@"html"];
    // The skin goes in first, before the (large) CSS and JS are inserted.
    html = [html stringByReplacingOccurrencesOfString:@"{{THEME}}" withString:[Theme webThemeCSS]];
    // Order matters: the libraries first (markdown-it, highlight.js, KaTeX), then our renderer, then the chat page itself.
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
    // U+2028 / U+2029 are legal in JSON but break JavaScript string literals in older WebKit.
    json = [json stringByReplacingOccurrencesOfString:@"\u2028" withString:@"\\u2028"];
    json = [json stringByReplacingOccurrencesOfString:@"\u2029" withString:@"\\u2029"];
    NSString *script = [NSString stringWithFormat:@"ChatUI.%@.apply(null,%@);", function, json];
    [self.webView evaluateJavaScript:script completionHandler:nil];
}

#pragma mark - Skin

// Restyles everything on this screen for the current skin, light/dark mode and wallpaper.
- (void)applyTheme {
    self.view.backgroundColor = [Theme background];

    UIImage *wallpaper = [Theme wallpaperImage];
    self.wallpaperView.image = wallpaper;
    self.wallpaperView.hidden = (wallpaper == nil);
    self.dimView.backgroundColor = [UIColor colorWithWhite:0 alpha:[Theme wallpaperDimAlpha]];
    self.webView.scrollView.indicatorStyle = [Theme darkMode] ? UIScrollViewIndicatorStyleWhite : UIScrollViewIndicatorStyleDefault;

    [self.modelButton setTitleColor:[Theme text] forState:UIControlStateNormal];
    self.inputBar.backgroundColor = [Theme background];
    [self.inputBar viewWithTag:1001].backgroundColor = [Theme border];
    self.inputBox.backgroundColor = [Theme surface];
    self.inputBox.layer.borderColor = [Theme border].CGColor;
    self.attachButton.tintColor = [Theme secondaryText];
    self.textView.textColor = [Theme text];
    self.textView.tintColor = [Theme accent];
    UIKeyboardAppearance appearance = [Theme keyboardAppearance];
    if (self.textView.keyboardAppearance != appearance) {
        self.textView.keyboardAppearance = appearance;
        if (self.textView.isFirstResponder) [self.textView reloadInputViews];
    }
    self.placeholderLabel.textColor = [[Theme secondaryText] colorWithAlphaComponent:0.75];
    for (UIButton *button in @[self.reasoningButton, self.searchButton, self.fastButton, self.mentionButton]) {
        button.backgroundColor = [Theme surface];
    }
    [self updateToolButtons];
    [self updateSendButton];
    if (self.pendingAttachments.count > 0 || self.importsInFlight > 0) [self refreshAttachStrip];   // chips were drawn with the old colours

    [self setNeedsStatusBarAppearanceUpdate];
    [self pushThemeToWeb];
    [self.view setNeedsLayout];
}

// Swaps the skin's CSS in the chat page (the page keeps its messages and scroll position).
- (void)pushThemeToWeb {
    if (!self.webReady) return;
    NSData *data = [NSJSONSerialization dataWithJSONObject:@[[Theme webThemeCSS]] options:0 error:nil];
    if (!data) return;
    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSString *script = [NSString stringWithFormat:@"(function(){var s=document.getElementById('themevars');if(s){s.textContent=(%@)[0];}})();", json];
    [self.webView evaluateJavaScript:script completionHandler:nil];
}

#pragma mark - Greeting

// By the device's clock: 03:00-10:59 morning, 11:00-13:59 midday, 14:00-17:59 afternoon,
// 18:00-22:59 evening, 23:00-02:59 night owl.
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

// A new empty chat gets a different line than the previous one.
- (void)rerollGreeting {
    NSUInteger previous = self.greetingIndex;
    NSUInteger next = previous;
    while (next == previous) next = arc4random_uniform((uint32_t)kGreetingCount);
    self.greetingIndex = next;
}

// The empty chat is still showing: redraw it when the time of day (and so the greeting) has changed.
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

// What the page needs to draw a message's attachments: kind, name, and a small thumbnail for photos.
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
        [self pushThemeToWeb];
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

// Opens the stored (2048 px) photo of a message in the full-screen viewer.
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

// iOS may kill the web process under memory pressure (the iPhone 6 has 1 GB). Rebuild the page.
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

// The chosen model must belong to a provider that has a key. Otherwise pick a default from one that does.
- (void)ensureModelMatchesKeys {
    BOOL usable = self.model.length > 0 && [KeyStore hasKeyForProvider:[Provider forModelId:self.model]];
    if (usable) return;
    NSString *fallback = [ModelStore defaultModelIdAcrossProviders];   // nil until a model list has been fetched
    self.model = fallback;
    if (fallback.length > 0) [ModelStore setSelectedModelId:fallback];
    self.conversation[@"model"] = fallback ?: @"";
    [self updateModelTitle];
}

// Fetches the model list of every provider that has a key (in the background) and keeps the choice valid.
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

// Files picked for a message that was never sent belong to the conversation being left behind.
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
    [self pushStrings];   // a fresh greeting for the fresh chat
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
    if (self.streaming || self.toolMenuOverlay) return;
    [self.view endEditing:YES];
    if (self.keyboardOverlap <= 0) {
        [self showToolMenu];
    } else {
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(260 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            ChatViewController *me = weakSelf;
            if (me && !me.streaming) [me showToolMenu];
        });
    }
}

- (void)dismissToolMenu {
    if (!self.toolMenuOverlay) return;
    [UIView animateWithDuration:0.16 animations:^{
        self.toolMenuCard.alpha = 0.0;
        self.toolMenuCard.transform = CGAffineTransformMakeTranslation(0, 12);
        self.toolMenuOverlay.backgroundColor = [UIColor colorWithWhite:0 alpha:0.0];
    } completion:^(BOOL finished) {
        [self.toolMenuOverlay removeFromSuperview];
        self.toolMenuOverlay = nil;
        self.toolMenuCard = nil;
    }];
}

- (void)toolMenuItemTapped:(UIControl *)sender {
    NSInteger item = sender.tag;
    [self dismissToolMenu];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(190 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        ChatViewController *me = weakSelf;
        if (!me) return;
        if (item <= 3 && (NSInteger)me.pendingAttachments.count + me.importsInFlight >= kMaxAttachmentsPerMessage) {
            [me showAlertMessage:[NSString stringWithFormat:L(@"att_err_limit"), (long)kMaxAttachmentsPerMessage]];
            return;
        }
        switch (item) {
            case 0: // Photos — multi-select up to the configured per-message limit
                [DiagnosticLog log:@"attach menu: photos"];
                [me presentPhotoLibraryPicker];
                break;
            case 1: // Files
            case 2: // Library browser
                [DiagnosticLog log:@"attach menu: document picker"];
                [me presentDocumentPicker];
                break;
            case 3: // Camera
                if ([UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypeCamera]) {
                    [DiagnosticLog log:@"attach menu: camera"];
                    [me presentImagePickerWithSource:UIImagePickerControllerSourceTypeCamera];
                } else {
                    [me showAlertMessage:@"Camera không khả dụng trên thiết bị này."];
                }
                break;
            case 4: // Web search
                [AppSettings setWebSearchEnabled:![AppSettings webSearchEnabled]];
                [me updateToolButtons];
                [me relayoutAnimated];
                break;
            case 5: // Reasoning
                [me reasoningTapped];
                break;
            case 6: // More tools
                [me mentionTapped];
                break;
            case 7: // Image generation command
                me.textView.text = @"/tạo ảnh ";
                [me textViewDidChange:me.textView];
                [me.textView becomeFirstResponder];
                break;
            default:
                break;
        }
    });
}

- (void)addToolMenuRowToCard:(UIView *)card y:(CGFloat)y icon:(NSString *)icon title:(NSString *)title subtitle:(NSString *)subtitle tag:(NSInteger)tag width:(CGFloat)width {
    UIControl *row = [[UIControl alloc] initWithFrame:CGRectMake(10, y, width - 20, 46)];
    row.tag = tag;
    row.layer.cornerRadius = 13;
    row.backgroundColor = [UIColor clearColor];
    [row addTarget:self action:@selector(toolMenuItemTapped:) forControlEvents:UIControlEventTouchUpInside];

    UILabel *iconLabel = [[UILabel alloc] initWithFrame:CGRectMake(13, 0, 30, 46)];
    iconLabel.text = icon;
    iconLabel.font = [UIFont systemFontOfSize:21];
    iconLabel.textAlignment = NSTextAlignmentCenter;
    [row addSubview:iconLabel];

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(52, 0, width - 92, 46)];
    titleLabel.text = title;
    titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    titleLabel.textColor = [Theme text];
    [row addSubview:titleLabel];

    if (subtitle.length > 0) {
        titleLabel.frame = CGRectMake(52, 3, width - 92, 21);
        UILabel *detail = [[UILabel alloc] initWithFrame:CGRectMake(52, 23, width - 92, 18)];
        detail.text = subtitle;
        detail.font = [UIFont systemFontOfSize:11];
        detail.textColor = [Theme secondaryText];
        [row addSubview:detail];
    }
    [card addSubview:row];
}

- (void)showToolMenu {
    if (self.toolMenuOverlay) return;
    CGFloat width = CGRectGetWidth(self.view.bounds);
    CGFloat cardWidth = MIN(width - 28.0, 430.0);
    CGFloat rowHeight = 46.0;
    BOOL canUseCamera = [UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypeCamera];
    NSArray *items = @[
        @{@"icon":@"▧", @"title":@"Ảnh", @"subtitle":@"Chọn ảnh từ thư viện", @"tag":@0},
        @{@"icon":@"⌁", @"title":@"Tệp", @"subtitle":@"PDF, Word, video và tài liệu", @"tag":@1},
        @{@"icon":@"▣", @"title":@"Thêm từ thư viện", @"subtitle":@"Duyệt các tệp đã lưu", @"tag":@2},
        @{@"icon":@"◎", @"title":@"Camera", @"subtitle":@"Chụp ảnh mới", @"tag":@3},
        @{@"icon":@"◉", @"title":@"Tìm kiếm trên mạng", @"subtitle":@"Tìm thông tin mới trên web", @"tag":@4},
        @{@"icon":@"♧", @"title":@"Suy nghĩ đi", @"subtitle":@"Điều chỉnh mức suy luận", @"tag":@5},
        @{@"icon":@"✦", @"title":@"Tạo ảnh", @"subtitle":@"Nhập mô tả để tạo ảnh", @"tag":@7},
        @{@"icon":@"@", @"title":@"Công cụ khác", @"subtitle":@"Tạo tệp và lệnh bổ sung", @"tag":@6}
    ];
    CGFloat headerHeight = 42.0;
    CGFloat cancelHeight = 42.0;
    NSUInteger visibleItemCount = items.count - (canUseCamera ? 0 : 1);
    CGFloat cardHeight = headerHeight + rowHeight * visibleItemCount + cancelHeight + 12.0;
    CGFloat safeTop = 12.0;
    if (@available(iOS 11.0, *)) safeTop += self.view.safeAreaInsets.top;
    CGFloat bottomY = CGRectGetMinY(self.inputBar.frame) - 8.0;
    CGFloat cardY = MAX(safeTop, bottomY - cardHeight);
    if (cardY + cardHeight > bottomY) cardHeight = MAX(250.0, bottomY - safeTop);

    self.toolMenuOverlay = [[UIView alloc] initWithFrame:self.view.bounds];
    self.toolMenuOverlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.toolMenuOverlay.backgroundColor = [UIColor colorWithWhite:0 alpha:0.0];
    UIButton *outside = [UIButton buttonWithType:UIButtonTypeCustom];
    outside.frame = self.toolMenuOverlay.bounds;
    outside.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [outside addTarget:self action:@selector(dismissToolMenu) forControlEvents:UIControlEventTouchUpInside];
    [self.toolMenuOverlay addSubview:outside];

    self.toolMenuCard = [[UIView alloc] initWithFrame:CGRectMake((width - cardWidth) / 2.0, cardY, cardWidth, cardHeight)];
    self.toolMenuCard.backgroundColor = [Theme surface];
    self.toolMenuCard.layer.cornerRadius = 22.0;
    self.toolMenuCard.layer.borderWidth = 1.0;
    self.toolMenuCard.layer.borderColor = [Theme border].CGColor;
    self.toolMenuCard.layer.shadowColor = [UIColor blackColor].CGColor;
    self.toolMenuCard.layer.shadowOpacity = 0.22;
    self.toolMenuCard.layer.shadowRadius = 18.0;
    self.toolMenuCard.layer.shadowOffset = CGSizeMake(0, 6);
    [self.toolMenuOverlay addSubview:self.toolMenuCard];

    UILabel *heading = [[UILabel alloc] initWithFrame:CGRectMake(18, 8, cardWidth - 36, 30)];
    heading.text = @"Công cụ";
    heading.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    heading.textColor = [Theme secondaryText];
    [self.toolMenuCard addSubview:heading];

    CGFloat y = headerHeight;
    for (NSDictionary *item in items) {
        NSInteger tag = [item[@"tag"] integerValue];
        if (tag == 3 && !canUseCamera) continue;
        NSString *title = item[@"title"];
        NSString *subtitle = item[@"subtitle"];
        if (tag == 4 && [AppSettings webSearchEnabled]) {
            title = @"Tắt tìm kiếm trên mạng";
            subtitle = @"Tìm kiếm đang được bật";
        }
        [self addToolMenuRowToCard:self.toolMenuCard y:y icon:item[@"icon"] title:title subtitle:subtitle tag:tag width:cardWidth];
        y += rowHeight;
    }

    UIButton *cancel = [UIButton buttonWithType:UIButtonTypeSystem];
    cancel.frame = CGRectMake(12, cardHeight - cancelHeight - 2, cardWidth - 24, cancelHeight);
    [cancel setTitle:L(@"cancel") forState:UIControlStateNormal];
    cancel.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [cancel setTitleColor:[Theme accent] forState:UIControlStateNormal];
    [cancel addTarget:self action:@selector(dismissToolMenu) forControlEvents:UIControlEventTouchUpInside];
    [self.toolMenuCard addSubview:cancel];

    [self.view addSubview:self.toolMenuOverlay];
    self.toolMenuCard.transform = CGAffineTransformMakeTranslation(0, 12);
    self.toolMenuCard.alpha = 0.0;
    [UIView animateWithDuration:0.20 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self.toolMenuOverlay.backgroundColor = [UIColor colorWithWhite:0 alpha:0.20];
        self.toolMenuCard.transform = CGAffineTransformIdentity;
        self.toolMenuCard.alpha = 1.0;
    } completion:nil];
}

- (void)presentImagePickerWithSource:(UIImagePickerControllerSourceType)source {
    UIImagePickerController *picker = [[UIImagePickerController alloc] init];
    picker.sourceType = source;
    picker.mediaTypes = @[@"public.image"];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)presentPhotoLibraryPicker {
    if (@available(iOS 14.0, *)) {
        NSInteger available = MAX(0, kMaxAttachmentsPerMessage - (NSInteger)self.pendingAttachments.count - self.importsInFlight);
        if (available == 0) {
            [self showAlertMessage:[NSString stringWithFormat:L(@"att_err_limit"), (long)kMaxAttachmentsPerMessage]];
            return;
        }
        PHPickerConfiguration *configuration = [[PHPickerConfiguration alloc] init];
        configuration.filter = PHPickerFilter.imagesFilter;
        configuration.selectionLimit = available;
        PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:configuration];
        picker.delegate = self;
        [self presentViewController:picker animated:YES completion:nil];
    } else {
        [self presentImagePickerWithSource:UIImagePickerControllerSourceTypePhotoLibrary];
    }
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results API_AVAILABLE(ios(14.0)) {
    [picker dismissViewControllerAnimated:YES completion:nil];
    if (results.count == 0) return;

    NSString *cid = self.conversation[@"id"];
    NSInteger available = MAX(0, kMaxAttachmentsPerMessage - (NSInteger)self.pendingAttachments.count - self.importsInFlight);
    NSUInteger count = MIN(results.count, (NSUInteger)available);
    if (count == 0) {
        [self showAlertMessage:[NSString stringWithFormat:L(@"att_err_limit"), (long)kMaxAttachmentsPerMessage]];
        return;
    }

    self.importsInFlight += (NSInteger)count; // reserve slots before asynchronous PhotoKit loads finish
    [self refreshAttachStrip];
    [self updateSendButton];
    __weak typeof(self) weakSelf = self;
    for (NSUInteger index = 0; index < count; index++) {
        NSItemProvider *provider = results[index].itemProvider;
        NSString *displayName = provider.suggestedName.length ? provider.suggestedName : [NSString stringWithFormat:@"photo-%lu.jpg", (unsigned long)(index + 1)];
        [provider loadDataRepresentationForTypeIdentifier:@"public.image" completionHandler:^(NSData *data, NSError *loadError) {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                NSString *errorKey = nil;
                NSDictionary *attachment = data.length > 0
                    ? [AttachmentStore importImageData:data name:displayName conversation:cid errorKey:&errorKey]
                    : nil;
                if (!attachment && !errorKey) errorKey = loadError ? @"att_err_unreadable" : @"att_err_empty";
                dispatch_async(dispatch_get_main_queue(), ^{
                    [weakSelf finishImport:attachment conversation:cid errorKey:errorKey];
                });
            });
        }];
    }
    if (results.count > count) [self showAlertMessage:[NSString stringWithFormat:@"Chỉ nhận tối đa %ld ảnh/tệp trong một tin nhắn.", (long)kMaxAttachmentsPerMessage]];
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
    NSURL *imageURL = info[UIImagePickerControllerImageURL];      // photo library picks come as a file
    UIImage *original = info[UIImagePickerControllerOriginalImage];   // camera shots come as an image in memory
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
    NSInteger available = MAX(0, kMaxAttachmentsPerMessage - (NSInteger)self.pendingAttachments.count - self.importsInFlight);
    NSUInteger count = MIN(urls.count, (NSUInteger)available);
    for (NSUInteger index = 0; index < count; index++) {
        NSURL *url = urls[index];
        [self runImportWithWork:^NSDictionary *(NSString *cid, NSString **errorKey) {
            return [AttachmentStore importDocumentAtURL:url conversation:cid errorKey:errorKey];
        }];
    }
    if (urls.count > count) {
        [self showAlertMessage:[NSString stringWithFormat:@"Chỉ nhận tối đa %ld ảnh/tệp trong một tin nhắn.", (long)kMaxAttachmentsPerMessage]];
    }
}

#pragma mark Import pipeline

// Decoding, resizing and unzipping happen off the main thread; the chip shows a spinner meanwhile.
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
            // The person switched chats while the file was being processed: it belongs to a conversation they left.
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

    // /tạo ảnh explicitly routes to a Gemini image-generation model. Do not silently
    // send this command to a normal text-only model and pretend an image was generated.
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

// Turns the saved messages into provider-neutral "turns" (the stream class converts them to Gemini's or Claude's JSON).
// Attachments become parts that come before the typed text:
//   photos, sampled video frames and PDFs -> base64 data, as long as they fit in the size budget (newest first)
//   text/Word/PPT                      -> the extracted text
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

    // Photos, video keyframes and PDFs are re-sent with each request, which costs quota. Only the newest media
    // messages (as many as the setting allows, 0 = all) include their data, within the byte budget; older ones
    // become a short note. Text taken from Word/PowerPoint/text files is not affected.
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

    // Both providers expect alternating roles, so merge consecutive messages from the same side.
    // (The history file stores the assistant as "model"; the neutral turns call it "assistant".)
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

    // Respect both the user's chosen history size and the selected model's published input limit.
    // The conversion is deliberately conservative because characters are only an estimate of tokens.
    NSUInteger contextLimit = [AppSettings contextLimitChars];
    AIProvider provider = [Provider forModelId:self.model];
    NSInteger inputTokenCap = [ModelStore maxInputTokensForModelId:self.model provider:provider];
    if (inputTokenCap > 0) {
        NSUInteger modelCharCap = (NSUInteger)inputTokenCap * 2;
        NSUInteger reservedChars = [self effectiveSystemPrompt].length + 4096;
        modelCharCap = modelCharCap > reservedChars ? modelCharCap - reservedChars : 4096;
        contextLimit = MIN(contextLimit, modelCharCap);
    } else {
        // The cached model list may predate token metadata. Limit history until the user refreshes that list.
        contextLimit = MIN(contextLimit, (NSUInteger)32000);
    }

    // Drop the oldest turns first, and never start with an assistant turn.
    while (turns.count > 1 && [self totalTextChars:turns] > contextLimit) [turns removeObjectAtIndex:0];
    while (turns.count > 1 && [turns.firstObject[@"role"] isEqualToString:@"assistant"]) [turns removeObjectAtIndex:0];

    // A single very long newest turn cannot be dropped wholesale. Trim its oldest text while preserving the tail
    // (which normally contains the current question) so the request still fits the selected model's estimate.
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

            // Account for every other text part (especially the current question) before choosing the tail size.
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

// Explains what is missing when the chosen model's provider has no key (for example a Claude model after its key was deleted).
- (BOOL)checkKeyForCurrentModel {
    AIProvider provider = [Provider forModelId:self.model];
    if ([KeyStore hasKeyForProvider:provider]) return YES;
    [self showAlertMessage:[NSString stringWithFormat:L(@"err_no_key_for_provider"), [Provider nameFor:provider]]];
    return NO;
}

- (void)startStreamingReply {
    if (![self checkKeyForCurrentModel]) return;
    self.streamBuffer = [NSMutableString string];
    self.longReplyAccumulator = [NSMutableString string];
    self.longReplyContinuationCount = 0;
    self.streamRetryCount = 0;
    self.didRecoverModel404 = NO;
    self.didFallbackFromFastMode = NO;
    self.streaming = YES;
    [self updateSendButton];
    [self callJS:@"begin" args:@[]];
    [self launchRequestStreaming:YES];
}

// Instructions of this conversation if it has its own, otherwise the general ones from Settings.
- (NSString *)effectiveSystemPrompt {
    NSString *own = self.conversation[@"system"];
    NSString *prompt = ([own isKindOfClass:[NSString class]] && own.length > 0) ? own : [AppSettings systemPrompt];
    NSInteger inputTokenCap = [ModelStore maxInputTokensForModelId:self.model provider:[Provider forModelId:self.model]];
    // The complete prompt (up to 1M chars) stays on-device. Only a compact, query-selected
    // excerpt is sent per request. A hard cap keeps long custom instructions from making
    // requests unnecessarily slow or oversized; 404 is handled separately as a model/path error.
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
    NSString *selectedPrompt = [AppSettings promptText:prompt forQuery:query characterBudget:promptBudget];
    NSString *lowerQuery = query.lowercaseString ?: @"";
    NSArray *codingSignals = @[@"code", @"mã nguồn", @"sửa code", @"viết code", @"lập trình", @"objective-c", @"swift", @"theos", @"xcode", @"compile", @"build", @".m", @".h", @".swift", @"c++", @"debug", @"hàm", @"class", @"zip source"];
    BOOL codingTask = NO;
    for (NSString *signal in codingSignals) {
        if ([lowerQuery containsString:signal]) { codingTask = YES; break; }
    }
    NSString *responseDirective = @"\n\n[RESPONSE COMPLETENESS] Unless the user explicitly asks for a short answer, answer every part with enough useful detail to act on it. Do not substitute a long outline for the requested explanation, implementation, or deliverable. Include relevant steps, examples, assumptions, and limitations without filler. For technical topics, identify the actual cause before proposing a change; distinguish verified facts from hypotheses. Never claim a search, API action, file edit, or build succeeded unless it actually did.";
    selectedPrompt = [selectedPrompt stringByAppendingString:responseDirective];
    if (codingTask) {
        NSString *codingDirective = @"\n\n[CODING RESPONSE REQUIREMENTS] For a coding, debugging, or source-editing request, deliver implementation rather than an outline alone. Include the complete requested function or changed file sections with all required declarations/imports; do not replace code with ellipses, placeholders, TODOs, or pseudo-code. Do not describe a large architecture while returning only a tiny code fragment. When the user asks for a complete file or a large implementation, provide the full requested code, not a shortened sample. Do not arbitrarily stop after the design or first few functions; continue until every requested component is implemented. Preserve unrelated behavior and make only requested changes. Check method names, property declarations, types, API payload fields, and error paths for consistency. Explain the exact files and behavior changed, then clearly state anything not build-tested. Prefer complete, compilable code over an inflated architecture proposal. The app automatically requests continuation when the provider reports its output-token limit; continue from the exact next line without repeating earlier code. If continuation cannot proceed because the model context or provider limit is reached, state the precise remaining section instead of claiming the work is complete.";
        selectedPrompt = [selectedPrompt stringByAppendingString:codingDirective];
    }
    if ([AppSettings webSearchEnabled]) {
        selectedPrompt = [selectedPrompt stringByAppendingString:@"\n\n[WEB SEARCH ENABLED] A real provider-managed web search tool is attached to this request. When the user explicitly asks to search, or the answer depends on current, recent, external, or verifiable information, you MUST invoke the search tool before answering and base factual claims on the returned results. Do not claim to have searched unless the API actually returned results. If the selected model/provider rejects or does not support the tool, state that limitation plainly instead of pretending the search happened." ];
    }
    return selectedPrompt;
}

// Counts only: never the text itself.
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
    NSMutableArray *turns = [[self buildTurns] mutableCopy];
    NSString *system = [self effectiveSystemPrompt];
    if (self.longReplyAccumulator.length > 0) {
        // Continue from the exact accumulated output. Keep the provider conversation
        // format valid (assistant -> user) and prune only older context if needed.
        [turns addObject:[@{ @"role": @"assistant", @"parts": @[@{ @"type": @"text", @"text": [self.longReplyAccumulator copy] }] } mutableCopy]];
        NSString *continueInstruction = @"Continue the response exactly where the previous assistant message ended. Do not repeat, summarize, shorten, or rewrite any text already provided. If writing code, continue the same file/code block with identical indentation and complete syntax; include every remaining line, declaration, implementation, and closing delimiter. Do not replace code with placeholders or ellipses. Finish the original request fully.";
        [turns addObject:[@{ @"role": @"user", @"parts": @[@{ @"type": @"text", @"text": continueInstruction }] } mutableCopy]];

        NSInteger inputCap = [ModelStore maxInputTokensForModelId:self.model provider:[Provider forModelId:self.model]];
        NSUInteger safeCharCap = inputCap > 0 ? (NSUInteger)inputCap * 2 : 64000;
        NSUInteger reserve = system.length + 4096;
        safeCharCap = safeCharCap > reserve ? safeCharCap - reserve : 16000;
        while (turns.count > 3 && [self totalTextChars:turns] > safeCharCap) [turns removeObjectAtIndex:0];
        while (turns.count > 1 && [turns.firstObject[@"role"] isEqualToString:@"assistant"]) [turns removeObjectAtIndex:0];
    }
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
        NSString *imageName = @"generated-image.jpg"; // AttachmentStore normalizes all imported images to JPEG.
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
    if (error == GeminiStreamErrorNone && status == 200 && [detail isEqualToString:@"__OUTPUT_LIMIT_REACHED__"] && partial.length > 0) {
        // Provider stopped only because this response segment reached its output cap.
        // Automatically request the next segment while keeping one continuous UI bubble.
        const NSUInteger kMaxAutomaticContinuations = 10;
        NSInteger continuationInputCap = [ModelStore maxInputTokensForModelId:self.model provider:currentProvider];
        NSUInteger continuationCharCap = continuationInputCap > 0 ? (NSUInteger)continuationInputCap * 2 : 64000;
        NSUInteger continuationPromptChars = [self effectiveSystemPrompt].length + 8192;
        continuationCharCap = continuationCharCap > continuationPromptChars ? continuationCharCap - continuationPromptChars : 0;
        BOOL continuationFitsContext = continuationCharCap > 0 &&
            self.longReplyAccumulator.length + partial.length < (continuationCharCap * 3) / 4;
        if (self.longReplyContinuationCount < kMaxAutomaticContinuations &&
            self.longReplyAccumulator.length + partial.length < 2000000 && continuationFitsContext) {
            if (!self.longReplyAccumulator) self.longReplyAccumulator = [NSMutableString string];
            [self.longReplyAccumulator appendString:partial];
            self.longReplyContinuationCount++;
            self.stream = nil;
            self.streamBuffer = [NSMutableString string];
            [DiagnosticLog log:@"long response reached provider output cap; continuing segment %lu/%lu accumulatedChars=%lu",
                              (unsigned long)self.longReplyContinuationCount, (unsigned long)kMaxAutomaticContinuations,
                              (unsigned long)self.longReplyAccumulator.length];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self.streaming && self.stream == nil) [self launchRequestStreaming:YES];
            });
            return;
        }
        detail = @"Đã đạt giới hạn an toàn của chuỗi tự nối tiếp. Phần đã tạo được giữ lại; gửi 'tiếp tục' để lấy phần còn lại.";
    }
    NSInteger claudeModelOutputCap = [ModelStore maxOutputTokensForModelId:self.model provider:AIProviderClaude];
    NSInteger configuredOutputCap = [AppSettings maxOutputTokens];
    BOOL largeClaudeReply = currentProvider == AIProviderClaude &&
        (configuredOutputCap > 21333 || (configuredOutputCap == 0 && claudeModelOutputCap > 21333));

    // Classify permanent daily/billing quota errors before fallback so Fast mode
    // cannot trigger an unnecessary second request when the account is blocked.
    NSString *lowerDetail = detail.lowercaseString ?: @"";
    BOOL permanentQuota = status == 429 &&
        ([lowerDetail containsString:@"per day"] || [lowerDetail containsString:@"per_day"] ||
         [lowerDetail containsString:@"perday"] || [lowerDetail containsString:@"daily quota"] ||
         [lowerDetail containsString:@"per month"] || [lowerDetail containsString:@"per_month"] ||
         [lowerDetail containsString:@"monthly quota"] || [lowerDetail containsString:@"insufficient_quota"] ||
         [lowerDetail containsString:@"billing"] || [lowerDetail containsString:@"spend limit"] ||
         [lowerDetail containsString:@"spend cap"] || [lowerDetail containsString:@"usage limit"] ||
         [lowerDetail containsString:@"payment"] || [lowerDetail containsString:@"quota_exceeded"]);

    // A Fast-mode 429/529 can be caused by the separate speed pool. Retry once
    // at standard speed only for transient Fast capacity errors, never for a daily/spend cap.
    BOOL wasFastRequest = currentProvider == AIProviderClaude && self.stream && ((ClaudeStream *)self.stream).useFastSpeed;
    NSString *fastErrorText = lowerDetail;
    BOOL fastRateLimited = wasFastRequest && !permanentQuota && (status == 429 || status == 529);
    BOOL fastRejected = wasFastRequest && (status == 400 || status == 403) &&
                        ([fastErrorText containsString:@"fast"] || [fastErrorText containsString:@"speed"]);
    if ((fastRateLimited || fastRejected) && partial.length == 0 &&
        self.streamGeneratedAttachments.count == 0 && !self.didFallbackFromFastMode) {
        self.didFallbackFromFastMode = YES;
        NSTimeInterval fastRetryAfter = self.stream.retryAfterSeconds;
        self.stream = nil;
        if (fastRejected) {
            // The account/model may not have Fast-mode entitlement; stop requesting it on later turns.
            [AppSettings setFastModeEnabled:NO];
            [self updateToolButtons];
        }
        [DiagnosticLog log:fastRateLimited
            ? @"Claude Fast mode capacity unavailable; retrying once at standard speed"
            : @"Claude Fast mode rejected by model/account; retrying once at standard speed and disabling Fast mode"];
        NSTimeInterval fallbackDelay = fastRateLimited ? MAX(1.0, MIN(900.0, fastRetryAfter)) : 1.0;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(fallbackDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (self.streaming && self.stream == nil) [self launchRequestStreaming:self.attemptIsStreaming];
        });
        return;
    }

    // Transient provider overloads (500/502/503/504/529) are retried with exponential
    // backoff only before any content arrives, so a partial answer is never duplicated.
    BOOL retryableStatus = (status == 429 || status == 500 || status == 502 || status == 503 || status == 504 || status == 529);
    BOOL transientServer = (error == GeminiStreamErrorServer || error == GeminiStreamErrorRateLimited) && retryableStatus;
    NSInteger retryLimit = status == 429 ? 1 : 3;
    if (transientServer && !permanentQuota && partial.length == 0 && self.streamGeneratedAttachments.count == 0 && self.streamRetryCount < retryLimit) {
        NSTimeInterval providerDelay = self.stream.retryAfterSeconds;
        self.stream = nil;
        self.streamRetryCount++;
        NSTimeInterval backoff = status == 429 ? 8.0 : (self.streamRetryCount == 1 ? 2.0 : (self.streamRetryCount == 2 ? 5.0 : 10.0));
        NSTimeInterval delay = MAX(backoff, MIN(900.0, providerDelay));
        [DiagnosticLog log:@"server overload HTTP %ld: retry %ld after %.0fs", (long)status, (long)self.streamRetryCount, delay];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (self.streaming && self.stream == nil) [self launchRequestStreaming:self.attemptIsStreaming];
        });
        return;
    }

    // A 404 often means that a cached model id was removed. Refresh once and switch
    // only when the provider's live model list no longer contains the selected id.
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
            // Large Claude outputs must remain streamed. Retry the stream once rather than switching to a single response.
            self.streamRetryCount++;
            [DiagnosticLog log:@"large Claude stream failed before first event: retrying stream once"];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (self.streaming && self.stream == nil) [self launchRequestStreaming:self.attemptIsStreaming];
            });
            return;
        }
        if (!largeClaudeReply) {
            // Smaller replies can fall back to a normal response if a long-lived stream fails before any text arrives.
            [DiagnosticLog log:@"live stream failed before any text: retrying once as a single request"];
            [self launchRequestStreaming:NO];
            return;
        }
    }

    self.stream = nil;
    self.streamBuffer = nil;
    self.streaming = NO;

    NSString *completeReply = self.longReplyAccumulator.length > 0
        ? [self.longReplyAccumulator stringByAppendingString:(partial ?: @"")]
        : partial;
    NSArray *generatedAttachments = [self.streamGeneratedAttachments copy] ?: @[];
    if (completeReply.length > 0 || generatedAttachments.count > 0) {
        [self appendAssistantMessage:completeReply attachments:generatedAttachments];
    }
    self.longReplyAccumulator = nil;
    self.longReplyContinuationCount = 0;
    self.streamGeneratedAttachments = nil;
    [self callJS:@"end" args:@[(completeReply ?: @"")]];
    if (generatedAttachments.count > 0) [self renderConversation];
    if ([detail hasPrefix:@"Đã đạt giới hạn an toàn của chuỗi tự nối tiếp."]) {
        [self callJS:@"error" args:@[detail, @YES]];
    } else if (error != GeminiStreamErrorNone && error != GeminiStreamErrorCancelled) {
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

// Stops the current reply without touching the UI (used when switching chats); keeps what arrived so far.
- (void)abandonStream {
    if (!self.stream) return;
    NSString *partial = [self.streamBuffer copy] ?: @"";
    NSString *completeReply = self.longReplyAccumulator.length > 0
        ? [self.longReplyAccumulator stringByAppendingString:partial]
        : partial;
    id<ChatStreaming> old = self.stream;
    old.onDelta = nil;
    old.onFinish = nil;
    self.stream = nil;
    self.streamBuffer = nil;
    self.streaming = NO;
    [old cancel];
    NSArray *generatedAttachments = [self.streamGeneratedAttachments copy] ?: @[];
    if (completeReply.length > 0 || generatedAttachments.count > 0) [self appendAssistantMessage:completeReply attachments:generatedAttachments];
    self.longReplyAccumulator = nil;
    self.longReplyContinuationCount = 0;
    self.streamGeneratedAttachments = nil;
    [self updateSendButton];
}

- (void)editMessageAtIndex:(NSInteger)index {
    if (self.streaming || !self.webReady) return;
    NSMutableArray *messages = self.conversation[@"messages"];
    if (index < 0 || index >= (NSInteger)messages.count) return;
    NSDictionary *target = messages[(NSUInteger)index];
    if (![target[@"role"] isEqualToString:@"user"]) return;

    // Remove any unsent draft attachments before restoring the selected message's attachments.
    NSString *cid = self.conversation[@"id"];
    for (NSDictionary *att in self.pendingAttachments) [AttachmentStore deleteAttachment:att conversation:cid];
    [self.pendingAttachments removeAllObjects];

    NSString *text = [target[@"text"] isKindOfClass:[NSString class]] ? target[@"text"] : @"";
    NSArray *attachments = [target[@"attachments"] isKindOfClass:[NSArray class]] ? [target[@"attachments"] copy] : @[];

    // Keep attachments belonging to the edited message; delete files referenced only by later messages.
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
        case GeminiStreamErrorRateLimited:      base = L(@"err_rate"); showDetail = YES; break;
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
