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

static const CGFloat kMaxInputHeight = 120;
static const CGFloat kStripHeight = 64;               // chip row above the text box (56 pt chips + spacing)
static const NSUInteger kMaxContextChars = 400000;
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
@property (strong, nonatomic) UITextView *textView;
@property (strong, nonatomic) UILabel *placeholderLabel;
@property (strong, nonatomic) UIButton *sendButton;
@property (strong, nonatomic) UIButton *modelButton;
@property (assign, nonatomic) CGFloat keyboardOverlap;

@property (strong, nonatomic) NSMutableDictionary *conversation;
@property (copy, nonatomic) NSString *model;
@property (strong, nonatomic) id<ChatStreaming> stream;
@property (assign, nonatomic) BOOL streaming;
@property (assign, nonatomic) CFAbsoluteTime requestStartTime;
@property (assign, nonatomic) NSUInteger greetingIndex;     // which of the kGreetingCount lines this empty chat shows
@property (copy, nonatomic) NSString *shownGreeting;        // what the page currently shows, to avoid redrawing for nothing
@property (assign, nonatomic) BOOL attemptIsStreaming;   // the current request is a live stream (vs. single-shot fallback)
@property (strong, nonatomic) NSMutableString *streamBuffer;

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
    CGFloat leftPad = 40;     // room for the attach button
    CGFloat rightPad = 44;    // room for the send button
    CGFloat textWidth = boxWidth - leftPad - rightPad;
    CGFloat fit = [self.textView sizeThatFits:CGSizeMake(textWidth, CGFLOAT_MAX)].height;
    CGFloat textHeight = MIN(MAX(fit, 38), kMaxInputHeight);
    self.textView.scrollEnabled = fit > kMaxInputHeight;

    CGFloat boxHeight = textHeight + 8;
    CGFloat barHeight = 8 + stripHeight + boxHeight + 8;
    self.inputBar.frame = CGRectMake(0, height - bottomInset - barHeight, width, barHeight);
    [self.inputBar viewWithTag:1001].frame = CGRectMake(0, 0, width, 1);

    self.attachStrip.hidden = !showStrip;
    self.attachStrip.frame = CGRectMake(0, 8, width, stripHeight);
    self.inputBox.frame = CGRectMake(12, 8 + stripHeight, boxWidth, boxHeight);
    self.attachButton.frame = CGRectMake(5, boxHeight - 36 - 5, 36, 36);
    self.textView.frame = CGRectMake(leftPad, 4, textWidth, textHeight);
    self.placeholderLabel.frame = CGRectMake(leftPad + 11, 13, textWidth - 12, 20);
    self.sendButton.frame = CGRectMake(boxWidth - 36 - 5, boxHeight - 36 - 5, 36, 36);

    self.webView.frame = CGRectMake(0, 0, width, CGRectGetMinY(self.inputBar.frame));
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
                                          @"retry": L(@"retry") }]];
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
    NSMutableArray *list = [NSMutableArray array];
    for (NSDictionary *message in self.conversation[@"messages"]) {
        NSString *role = message[@"role"];
        NSString *text = message[@"text"];
        if (![role isKindOfClass:[NSString class]] || ![text isKindOfClass:[NSString class]]) continue;
        NSMutableDictionary *item = [@{ @"role": role, @"text": text } mutableCopy];
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
    } else if ([type isEqualToString:@"image"]) {
        [self showImageForAttachmentId:body[@"id"]];
    } else if ([type isEqualToString:@"jserror"]) {
        [DiagnosticLog log:@"page script error: %@ (line %@)", ClippedForLog(body[@"message"]), body[@"line"] ?: @"?"];
    }
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
        [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.data", @"public.content"]
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
    for (NSURL *url in urls) {
        [self runImportWithWork:^NSDictionary *(NSString *cid, NSString **errorKey) {
            return [AttachmentStore importDocumentAtURL:url conversation:cid errorKey:errorKey];
        }];
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

    [self callJS:@"addUser" args:@[text, [self webAttachmentsFrom:attachments conversation:cid]]];
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
//   photos and PDFs  -> base64 data, as long as they fit in the size budget (newest first)
//   text/Word/PPT    -> the extracted text
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
    } else if ([kind isEqualToString:@"image"] || [kind isEqualToString:@"pdf"]) {
        NSData *data = ([inlineIds containsObject:att[@"id"]] && path) ? [NSData dataWithContentsOfFile:path] : nil;
        if (data.length > 0) {
            NSString *encoded = [data base64EncodedStringWithOptions:0];
            if ([kind isEqualToString:@"pdf"]) {
                [parts addObject:@{ @"type": @"pdf", @"data": encoded }];
            } else {
                NSString *mime = [att[@"mime"] isKindOfClass:[NSString class]] ? att[@"mime"] : @"image/jpeg";
                [parts addObject:@{ @"type": @"image", @"mime": mime, @"data": encoded }];
            }
        } else {
            [parts addObject:@{ @"type": @"text", @"text": [NSString stringWithFormat:@"[Earlier attachment not included: %@]", name] }];
        }
    }
}

- (NSArray *)buildTurns {
    NSString *cid = self.conversation[@"id"];
    NSArray *messages = self.conversation[@"messages"];

    // Photos and PDFs are re-sent with every request, which costs quota. Only the newest messages that carry them
    // (as many as the setting allows, 0 = all) get to include the real data, within the byte budget; older ones
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
            if ([kind isEqualToString:@"image"] || [kind isEqualToString:@"pdf"]) { hasMedia = YES; break; }
        }
        if (!hasMedia) continue;
        mediaMessages++;
        if (memory > 0 && mediaMessages > memory) continue;
        for (NSDictionary *att in atts) {
            NSString *kind = att[@"kind"];
            if (![kind isEqualToString:@"image"] && ![kind isEqualToString:@"pdf"]) continue;
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

    // Keep the request a sensible size: drop the oldest turns first, and never start with an assistant turn.
    while (turns.count > 1 && [self totalTextChars:turns] > kMaxContextChars) [turns removeObjectAtIndex:0];
    while (turns.count > 1 && [turns.firstObject[@"role"] isEqualToString:@"assistant"]) [turns removeObjectAtIndex:0];
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
    self.streaming = YES;
    [self updateSendButton];
    [self callJS:@"begin" args:@[]];
    [self launchRequestStreaming:YES];
}

// Instructions of this conversation if it has its own, otherwise the general ones from Settings.
- (NSString *)effectiveSystemPrompt {
    NSString *own = self.conversation[@"system"];
    if ([own isKindOfClass:[NSString class]] && own.length > 0) return own;
    return [AppSettings systemPrompt];
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
    NSArray *turns = [self buildTurns];
    NSString *system = [self effectiveSystemPrompt];
    id<ChatStreaming> stream = (provider == AIProviderClaude)
        ? (id<ChatStreaming>)[[ClaudeStream alloc] initWithKey:key model:self.model turns:turns system:system]
        : (id<ChatStreaming>)[[GeminiStream alloc] initWithKey:key model:self.model turns:turns system:system];
    stream.useStreaming = useStreaming;
    self.stream = stream;
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

    if (error == GeminiStreamErrorNetwork && partial.length == 0 && self.attemptIsStreaming) {
        // The live stream failed before any text arrived (some networks stall long-lived responses).
        // Try once more as a normal single request; the typing indicator stays on screen meanwhile.
        [DiagnosticLog log:@"live stream failed before any text: retrying once as a single request"];
        self.stream = nil;
        [self launchRequestStreaming:NO];
        return;
    }

    self.stream = nil;
    self.streamBuffer = nil;
    self.streaming = NO;

    if (partial.length > 0) [self appendAssistantMessage:partial];
    [self callJS:@"end" args:@[partial]];
    if (error != GeminiStreamErrorNone && error != GeminiStreamErrorCancelled) {
        [self callJS:@"error" args:@[[self messageForError:error status:status detail:detail], @YES]];
    }
    [self updateSendButton];
}

- (void)appendAssistantMessage:(NSString *)text {
    NSMutableArray *messages = self.conversation[@"messages"];
    [messages addObject:@{ @"role": @"model", @"text": text, @"ts": @([[NSDate date] timeIntervalSince1970]) }];
    self.conversation[@"updated"] = @([[NSDate date] timeIntervalSince1970]);
    [ConversationStore saveConversation:self.conversation];
}

// Stops the current reply without touching the UI (used when switching chats); keeps what arrived so far.
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
    if (partial.length > 0) [self appendAssistantMessage:partial];
    [self updateSendButton];
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
