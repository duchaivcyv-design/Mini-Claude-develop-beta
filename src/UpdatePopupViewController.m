#import "UpdatePopupViewController.h"
#import "UpdateManager.h"
#import "Strings.h"
#import "Theme.h"

// Down-pointing arrow over a tray, drawn with code (template image, tinted by the caller).
static UIImage *DrawUpdateIcon(CGFloat size) {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(size, size), NO, 0);
    UIBezierPath *p = [UIBezierPath bezierPath];
    p.lineWidth = 2.4;
    p.lineCapStyle = kCGLineCapRound;
    p.lineJoinStyle = kCGLineJoinRound;
    [p moveToPoint:CGPointMake(size * 0.5, size * 0.16)];
    [p addLineToPoint:CGPointMake(size * 0.5, size * 0.62)];
    [p moveToPoint:CGPointMake(size * 0.32, size * 0.46)];
    [p addLineToPoint:CGPointMake(size * 0.5, size * 0.64)];
    [p addLineToPoint:CGPointMake(size * 0.68, size * 0.46)];
    [p moveToPoint:CGPointMake(size * 0.2, size * 0.66)];
    [p addLineToPoint:CGPointMake(size * 0.2, size * 0.82)];
    [p addLineToPoint:CGPointMake(size * 0.8, size * 0.82)];
    [p addLineToPoint:CGPointMake(size * 0.8, size * 0.66)];
    [[UIColor blackColor] setStroke];
    [p stroke];
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

static NSString *SizeText(long long bytes) {
    if (bytes <= 0) return @"";
    return [NSString stringWithFormat:@"%.1f MB", (double)bytes / (1024.0 * 1024.0)];
}

@interface UpdatePopupViewController ()
@property (strong, nonatomic) UIView *card;
@property (strong, nonatomic) UIView *iconBadge;
@property (strong, nonatomic) UIImageView *iconView;
@property (strong, nonatomic) UILabel *titleLabel;
@property (strong, nonatomic) UILabel *messageLabel;
@property (strong, nonatomic) UIView *progressTrack;
@property (strong, nonatomic) UIView *progressFill;
@property (strong, nonatomic) UIButton *secondaryButton;
@property (strong, nonatomic) UIButton *primaryButton;
@property (copy, nonatomic) void (^primaryHandler)(void);
@property (copy, nonatomic) void (^secondaryHandler)(void);
@property (assign, nonatomic) BOOL showsProgress;
@property (assign, nonatomic) BOOL showsSecondary;
@property (assign, nonatomic) BOOL showsPrimary;
@end

@implementation UpdatePopupViewController

- (instancetype)init {
    self = [super init];
    if (self) {
        self.modalPresentationStyle = UIModalPresentationOverFullScreen;
        self.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0 alpha:0.42];

    self.card = [[UIView alloc] init];
    self.card.backgroundColor = [Theme background];
    self.card.layer.cornerRadius = 24;
    self.card.layer.borderWidth = 1;
    self.card.layer.borderColor = [Theme border].CGColor;
    self.card.layer.shadowColor = [UIColor blackColor].CGColor;
    self.card.layer.shadowOpacity = 0.28;
    self.card.layer.shadowRadius = 24;
    self.card.layer.shadowOffset = CGSizeMake(0, 10);
    [self.view addSubview:self.card];

    self.iconBadge = [[UIView alloc] init];
    self.iconBadge.backgroundColor = [[Theme accent] colorWithAlphaComponent:0.14];
    self.iconBadge.layer.cornerRadius = 28;
    [self.card addSubview:self.iconBadge];
    self.iconView = [[UIImageView alloc] initWithImage:DrawUpdateIcon(30)];
    self.iconView.tintColor = [Theme accent];
    self.iconView.contentMode = UIViewContentModeCenter;
    [self.iconBadge addSubview:self.iconView];

    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.font = [Theme serifFontOfSize:23];
    self.titleLabel.textColor = [Theme text];
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
    self.titleLabel.numberOfLines = 0;
    [self.card addSubview:self.titleLabel];

    self.messageLabel = [[UILabel alloc] init];
    self.messageLabel.font = [UIFont systemFontOfSize:15];
    self.messageLabel.textColor = [Theme secondaryText];
    self.messageLabel.textAlignment = NSTextAlignmentCenter;
    self.messageLabel.numberOfLines = 12;
    [self.card addSubview:self.messageLabel];

    self.progressTrack = [[UIView alloc] init];
    self.progressTrack.backgroundColor = [Theme border];
    self.progressTrack.layer.cornerRadius = 3;
    self.progressTrack.clipsToBounds = YES;
    [self.card addSubview:self.progressTrack];
    self.progressFill = [[UIView alloc] init];
    self.progressFill.backgroundColor = [Theme accent];
    [self.progressTrack addSubview:self.progressFill];

    self.secondaryButton = [UIButton buttonWithType:UIButtonTypeCustom];
    [self.secondaryButton setTitleColor:[Theme accent] forState:UIControlStateNormal];
    self.secondaryButton.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    self.secondaryButton.titleLabel.adjustsFontSizeToFitWidth = YES;
    self.secondaryButton.titleLabel.minimumScaleFactor = 0.8;
    self.secondaryButton.layer.cornerRadius = 14;
    self.secondaryButton.layer.borderWidth = 1.5;
    self.secondaryButton.layer.borderColor = [Theme accent].CGColor;
    [self.secondaryButton addTarget:self action:@selector(secondaryTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.card addSubview:self.secondaryButton];

    self.primaryButton = [UIButton buttonWithType:UIButtonTypeCustom];
    [self.primaryButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.primaryButton.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    self.primaryButton.titleLabel.adjustsFontSizeToFitWidth = YES;
    self.primaryButton.titleLabel.minimumScaleFactor = 0.8;
    self.primaryButton.backgroundColor = [Theme accent];
    self.primaryButton.layer.cornerRadius = 14;
    [self.primaryButton addTarget:self action:@selector(primaryTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.card addSubview:self.primaryButton];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(closeTapped)];
    tap.delegate = self;
    [self.view addGestureRecognizer:tap];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(stateChanged) name:kNotifUpdateChanged object:nil];
    [self refresh];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.card.transform = CGAffineTransformMakeScale(0.94, 0.94);
    [UIView animateWithDuration:0.28 delay:0 usingSpringWithDamping:0.85 initialSpringVelocity:0 options:0 animations:^{
        self.card.transform = CGAffineTransformIdentity;
    } completion:nil];
}

#pragma mark - State

- (void)stateChanged {
    [self refresh];
}

- (void)refresh {
    if (!self.isViewLoaded) return;
    UpdateManager *m = [UpdateManager shared];
    NSString *title = @"", *message = @"";
    NSString *primary = nil, *secondary = nil;
    __weak typeof(self) weakSelf = self;
    void (^close)(void) = ^{ [weakSelf closeTapped]; };
    void (^primaryHandler)(void) = close;
    void (^secondaryHandler)(void) = close;
    BOOL progress = NO;
    NSString *kind = m.installKindName;

    switch (m.state) {
        case UpdateStateChecking: {
            title = L(@"update_checking");
            message = L(@"update_checking_msg");
            primary = L(@"update_close");
            break;
        }
        case UpdateStateUpToDate: {
            title = L(@"update_uptodate");
            message = [NSString stringWithFormat:L(@"update_uptodate_msg"), m.currentVersion];
            primary = L(@"update_close");
            secondary = L(@"update_check_again");
            secondaryHandler = ^{ [weakSelf checkAgainTapped]; };
            break;
        }
        case UpdateStateAvailable: {
            title = L(@"update_available");
            NSMutableString *text = [NSMutableString stringWithFormat:@"%@  →  %@", m.currentVersion, m.latestLabel];
            NSString *size = SizeText(m.assetSize);
            [text appendFormat:@"\n%@", [NSString stringWithFormat:L(@"update_kind_line"), kind, size.length > 0 ? [@" · " stringByAppendingString:size] : @""]];
            if (m.releaseNotes.length > 0) [text appendFormat:@"\n\n%@", m.releaseNotes];
            message = text;
            primary = L(@"update_now");
            primaryHandler = ^{ [weakSelf downloadTapped]; };
            secondary = L(@"update_later");
            break;
        }
        case UpdateStateDownloading: {
            title = L(@"update_downloading");
            NSString *size = SizeText(m.assetSize);
            message = [NSString stringWithFormat:@"%d%%%@", (int)lround(m.progress * 100.0),
                       size.length > 0 ? [NSString stringWithFormat:@" · %@ / %@", SizeText(m.receivedBytes), size] : @""];
            progress = YES;
            primary = L(@"update_cancel");
            primaryHandler = ^{ [weakSelf cancelTapped]; };
            break;
        }
        case UpdateStateDownloaded: {
            title = L(@"update_downloaded");
            if (m.installKind == UpdateInstallKindIPA) {
                message = L(@"update_ipa_msg");
                primary = L(@"update_open_files");
                secondary = L(@"update_open_in");
            } else {
                message = L(@"update_deb_msg");
                primary = L(@"update_install_now");
                secondary = L(@"update_later");
            }
            primaryHandler = ^{ [weakSelf installTapped]; };
            if (m.installKind == UpdateInstallKindIPA) secondaryHandler = ^{ [weakSelf openInTapped]; };
            break;
        }
        case UpdateStateFailed: {
            title = L(@"update_failed");
            message = m.errorMessage.length > 0 ? m.errorMessage : L(@"update_err_network");
            primary = L(@"update_retry");
            primaryHandler = ^{ [weakSelf retryTapped]; };
            secondary = L(@"update_close");
            break;
        }
        default: {
            title = L(@"update_checking");
            primary = L(@"update_close");
            break;
        }
    }
    self.titleLabel.text = title;
    self.messageLabel.text = message;
    [self.primaryButton setTitle:primary forState:UIControlStateNormal];
    [self.secondaryButton setTitle:secondary forState:UIControlStateNormal];
    self.primaryHandler = primaryHandler;
    self.secondaryHandler = secondaryHandler;
    self.showsPrimary = primary.length > 0;
    self.showsSecondary = secondary.length > 0;
    BOOL progressChanged = self.showsProgress != progress;
    self.showsProgress = progress;
    // Only a change of layout (not every progress tick) needs a new layout pass.
    if (progressChanged || m.state != UpdateStateDownloading) [self.view setNeedsLayout];
    [self updateProgressFill];
}

- (void)updateProgressFill {
    double p = MIN(1.0, MAX(0.0, [UpdateManager shared].progress));
    CGFloat w = self.progressTrack.bounds.size.width;
    self.progressFill.frame = CGRectMake(0, 0, w * p, self.progressTrack.bounds.size.height);
}

#pragma mark - Layout

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect bounds = self.view.bounds;
    UIEdgeInsets safe = self.view.safeAreaInsets;
    CGFloat cardWidth = MIN(bounds.size.width - 48, 340);
    CGFloat inner = cardWidth - 40;

    CGFloat y = 24;
    self.iconBadge.frame = CGRectMake((cardWidth - 56) / 2, y, 56, 56);
    self.iconView.frame = self.iconBadge.bounds;
    y += 56 + 14;

    CGSize titleSize = [self.titleLabel sizeThatFits:CGSizeMake(inner, CGFLOAT_MAX)];
    self.titleLabel.frame = CGRectMake(20, y, inner, ceil(titleSize.height));
    y += ceil(titleSize.height) + 8;

    CGSize messageSize = [self.messageLabel sizeThatFits:CGSizeMake(inner, CGFLOAT_MAX)];
    self.messageLabel.frame = CGRectMake(20, y, inner, ceil(messageSize.height));
    y += ceil(messageSize.height);

    self.progressTrack.hidden = !self.showsProgress;
    if (self.showsProgress) {
        y += 14;
        self.progressTrack.frame = CGRectMake(20, y, inner, 6);
        y += 6;
    }
    y += 22;

    CGFloat gap = 10;
    BOOL both = self.showsPrimary && self.showsSecondary;
    CGFloat buttonWidth = both ? (inner - gap) / 2 : inner;
    self.secondaryButton.hidden = !self.showsSecondary;
    self.primaryButton.hidden = !self.showsPrimary;
    if (both) {
        self.secondaryButton.frame = CGRectMake(20, y, buttonWidth, 48);
        self.primaryButton.frame = CGRectMake(20 + buttonWidth + gap, y, buttonWidth, 48);
    } else if (self.showsPrimary) {
        self.primaryButton.frame = CGRectMake(20, y, inner, 48);
    } else {
        self.secondaryButton.frame = CGRectMake(20, y, inner, 48);
    }
    y += 48 + 20;

    CGFloat centerY = safe.top + (bounds.size.height - safe.top - safe.bottom) / 2;
    self.card.frame = CGRectMake((bounds.size.width - cardWidth) / 2, MAX(safe.top + 12, centerY - y / 2), cardWidth, y);
    [self updateProgressFill];
}

#pragma mark - Actions

- (void)primaryTapped {
    if (self.primaryHandler) self.primaryHandler();
}

- (void)secondaryTapped {
    if (self.secondaryHandler) self.secondaryHandler();
}

- (void)closeTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)checkAgainTapped {
    [[UpdateManager shared] checkForUpdateForce:YES];
}

- (void)retryTapped {
    [[UpdateManager shared] checkForUpdateForce:YES];   // look again, then the update button is offered again
}

- (void)downloadTapped {
    [[UpdateManager shared] startDownload];
}

- (void)cancelTapped {
    [[UpdateManager shared] cancelDownload];
}

- (void)installTapped {
    [[UpdateManager shared] installFromViewController:self anchor:self.primaryButton];
}

- (void)openInTapped {
    [[UpdateManager shared] presentOpenInFromViewController:self anchor:self.secondaryButton];
}

// A tap outside the card closes it; taps on the card do not. A download keeps running in the background.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    return touch.view == self.view;
}

@end
