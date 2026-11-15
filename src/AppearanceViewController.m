#import "AppearanceViewController.h"
#import "Strings.h"
#import "Theme.h"
#import "DiagnosticLog.h"

typedef NS_ENUM(NSInteger, AppearanceSection) {
    AppearanceSectionMode = 0,    // light / dark pictures + "Tự động"
    AppearanceSectionSkin,
    AppearanceSectionWallpaper,
    AppearanceSectionIcon,
    AppearanceSectionCount
};

// Wallpaper rows: 0 = follow the skin, 1 = none, 2...7 = wallpaper 1...6.
static const NSInteger kWallpaperRowCount = 2 + (ThemeSkinCount - 1);

#pragma mark - Light / dark picker cell (like iOS Settings > Display)

static UIImage *RadioImage(BOOL selected) {
    CGFloat side = 24;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side)];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGRect rect = CGRectMake(1.5, 1.5, side - 3, side - 3);
        if (selected) {
            [[Theme accent] setFill];
            [[UIBezierPath bezierPathWithOvalInRect:rect] fill];
            UIBezierPath *tick = [UIBezierPath bezierPath];
            [tick moveToPoint:CGPointMake(7, 12.5)];
            [tick addLineToPoint:CGPointMake(10.5, 16)];
            [tick addLineToPoint:CGPointMake(17, 8.5)];
            tick.lineWidth = 2.2;
            tick.lineCapStyle = kCGLineCapRound;
            tick.lineJoinStyle = kCGLineJoinRound;
            [[UIColor whiteColor] setStroke];
            [tick stroke];
        } else {
            UIBezierPath *ring = [UIBezierPath bezierPathWithOvalInRect:rect];
            ring.lineWidth = 1.5;
            [[Theme secondaryText] setStroke];
            [ring stroke];
        }
    }];
}

@interface AppearanceModeCell : UITableViewCell
@property (strong, nonatomic) UIButton *lightButton;
@property (strong, nonatomic) UIButton *darkButton;
@property (strong, nonatomic) UILabel *lightLabel;
@property (strong, nonatomic) UILabel *darkLabel;
@property (strong, nonatomic) UIImageView *lightRadio;
@property (strong, nonatomic) UIImageView *darkRadio;
@end

static const CGSize kModePreviewSize = { 84, 148 };

@implementation AppearanceModeCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.lightButton = [UIButton buttonWithType:UIButtonTypeCustom];
        self.darkButton = [UIButton buttonWithType:UIButtonTypeCustom];
        self.lightLabel = [[UILabel alloc] init];
        self.darkLabel = [[UILabel alloc] init];
        self.lightRadio = [[UIImageView alloc] init];
        self.darkRadio = [[UIImageView alloc] init];
        for (UILabel *label in @[self.lightLabel, self.darkLabel]) {
            label.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
            label.textAlignment = NSTextAlignmentCenter;
            [self.contentView addSubview:label];
        }
        for (UIButton *button in @[self.lightButton, self.darkButton]) {
            button.adjustsImageWhenHighlighted = NO;
            [self.contentView addSubview:button];
        }
        [self.contentView addSubview:self.lightRadio];
        [self.contentView addSubview:self.darkRadio];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.contentView.bounds.size.width;
    CGFloat centers[2] = { width * 0.25, width * 0.75 };
    UIButton *buttons[2] = { self.lightButton, self.darkButton };
    UILabel *labels[2] = { self.lightLabel, self.darkLabel };
    UIImageView *radios[2] = { self.lightRadio, self.darkRadio };
    for (int i = 0; i < 2; i++) {
        buttons[i].frame = CGRectMake(centers[i] - kModePreviewSize.width / 2, 16, kModePreviewSize.width, kModePreviewSize.height);
        labels[i].frame = CGRectMake(centers[i] - 60, 16 + kModePreviewSize.height + 8, 120, 20);
        radios[i].frame = CGRectMake(centers[i] - 12, 16 + kModePreviewSize.height + 36, 24, 24);
    }
}

@end

@interface AppearanceViewController ()
@property (strong, nonatomic) UITableView *tableView;
@property (assign, nonatomic) BOOL changingIcon;
@end

@implementation AppearanceViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = L(@"appearance_title");
    self.navigationItem.backBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"" style:UIBarButtonItemStylePlain target:nil action:nil];

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleGrouped];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [self.view addSubview:self.tableView];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applyTheme) name:kNotifThemeChanged object:nil];
    [self applyTheme];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)applyTheme {
    self.view.backgroundColor = [Theme background];
    self.tableView.backgroundColor = [Theme background];
    self.tableView.separatorColor = [Theme border];
    [self.tableView reloadData];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];   // the icon may have been changed from outside (e.g. the system reverted it)
}

#pragma mark - Helpers

- (BOOL)iconsSupported {
    if ([Theme iconHelperAvailable]) return YES;   // rootful .deb: the root helper does the work
    if (@available(iOS 10.3, *)) return [UIApplication sharedApplication].supportsAlternateIcons;
    return NO;
}

// Which skin's icon is on the Home Screen now (ThemeSkinClaude = the default icon).
- (ThemeSkin)currentIconSkin {
    if ([Theme iconHelperAvailable]) return [Theme helperIconSkin];
    NSString *name = [Theme currentIconName];
    if (name.length == 0) return ThemeSkinClaude;
    for (NSInteger i = ThemeSkinSideStore; i < ThemeSkinCount; i++) {
        if ([[Theme iconNameForSkin:(ThemeSkin)i] isEqualToString:name]) return (ThemeSkin)i;
    }
    return ThemeSkinClaude;
}

- (UIImage *)roundedIcon:(UIImage *)image side:(CGFloat)side {
    if (!image) return nil;
    CGRect rect = CGRectMake(0, 0, side, side);
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:rect.size];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [[UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:side * 0.225] addClip];
        [image drawInRect:rect];
    }];
}

- (UIImage *)swatchImageWithColor:(UIColor *)color {
    CGRect rect = CGRectMake(0, 0, 28, 28);
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:rect.size];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [color setFill];
        [[UIBezierPath bezierPathWithOvalInRect:rect] fill];
    }];
}

- (UIImage *)roundedThumbnail:(UIImage *)image size:(CGSize)size {
    if (!image) return nil;
    CGRect rect = CGRectMake(0, 0, size.width, size.height);
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [[UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:6] addClip];
        // aspect-fill
        CGFloat scale = MAX(size.width / image.size.width, size.height / image.size.height);
        CGSize drawn = CGSizeMake(image.size.width * scale, image.size.height * scale);
        [image drawInRect:CGRectMake((size.width - drawn.width) / 2, (size.height - drawn.height) / 2, drawn.width, drawn.height)];
    }];
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return AppearanceSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case AppearanceSectionSkin:      return ThemeSkinCount;
        case AppearanceSectionMode:      return 2;   // picture row + "Tự động"
        case AppearanceSectionWallpaper: return kWallpaperRowCount;
        default:                         return ThemeSkinCount;   // icons: default + one per skin
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case AppearanceSectionMode:      return L(@"appearance_mode_header");
        case AppearanceSectionSkin:      return L(@"appearance_skin_header");
        case AppearanceSectionWallpaper: return L(@"appearance_wallpaper_header");
        case AppearanceSectionIcon:      return L(@"appearance_icon_header");
        default:                         return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    switch (section) {
        case AppearanceSectionSkin:      return L(@"appearance_skin_footer");
        case AppearanceSectionMode:      return L(@"appearance_auto_footer");
        case AppearanceSectionIcon:
            if ([Theme iconHelperAvailable]) return L(@"appearance_icon_footer_helper");
            return [self iconsSupported] ? L(@"appearance_icon_footer") : L(@"appearance_icon_unsupported");
        default:                         return nil;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.backgroundColor = [Theme surface];
    cell.textLabel.font = [UIFont systemFontOfSize:17];
    cell.textLabel.textColor = [Theme text];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:13];
    cell.detailTextLabel.textColor = [Theme secondaryText];
    cell.tintColor = [Theme accent];
    UIView *selected = [[UIView alloc] init];
    selected.backgroundColor = [Theme selection];
    cell.selectedBackgroundView = selected;

    switch (indexPath.section) {
        case AppearanceSectionSkin: {
            ThemeSkin skin = (ThemeSkin)indexPath.row;
            cell.imageView.image = [self swatchImageWithColor:[Theme swatchColorForSkin:skin]];
            cell.textLabel.text = [Theme skinName:skin];
            cell.detailTextLabel.text = L([Theme skinColorKey:skin]);
            cell.accessoryType = (skin == [Theme skin]) ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
            break;
        }
        case AppearanceSectionMode: {
            if (indexPath.row == 0) {
                AppearanceModeCell *modeCell = [[AppearanceModeCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
                modeCell.backgroundColor = [Theme surface];
                BOOL dark = [Theme darkMode];
                [modeCell.lightButton setImage:[Theme modePreviewImageDark:NO size:kModePreviewSize] forState:UIControlStateNormal];
                [modeCell.darkButton setImage:[Theme modePreviewImageDark:YES size:kModePreviewSize] forState:UIControlStateNormal];
                [modeCell.lightButton addTarget:self action:@selector(lightTapped) forControlEvents:UIControlEventTouchUpInside];
                [modeCell.darkButton addTarget:self action:@selector(darkTapped) forControlEvents:UIControlEventTouchUpInside];
                modeCell.lightLabel.text = L(@"mode_light");
                modeCell.darkLabel.text = L(@"mode_dark");
                modeCell.lightLabel.textColor = [Theme text];
                modeCell.darkLabel.textColor = [Theme text];
                modeCell.lightRadio.image = RadioImage(!dark);
                modeCell.darkRadio.image = RadioImage(dark);
                return modeCell;
            }
            cell.textLabel.text = L(@"mode_auto");
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            UISwitch *toggle = [[UISwitch alloc] init];
            toggle.on = [Theme autoMode];
            toggle.onTintColor = [Theme accent];
            [toggle addTarget:self action:@selector(autoToggled:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = toggle;
            break;
        }
        case AppearanceSectionWallpaper: {
            NSInteger choice = [Theme wallpaperChoice];
            BOOL isSelected = NO;
            if (indexPath.row == 0) {
                cell.textLabel.text = L(@"wallpaper_follow");
                cell.detailTextLabel.text = L(@"wallpaper_follow_note");
                isSelected = (choice == -1);
            } else if (indexPath.row == 1) {
                cell.textLabel.text = L(@"wallpaper_none");
                cell.detailTextLabel.text = L(@"wallpaper_none_note");
                isSelected = (choice == 0);
            } else {
                NSInteger index = indexPath.row - 1;   // rows 2...7 -> wallpapers 1...6
                cell.textLabel.text = [Theme wallpaperName:index];
                cell.detailTextLabel.text = L(@"wallpaper_item_note");
                cell.imageView.image = [self roundedThumbnail:[Theme wallpaperThumbnail:index] size:CGSizeMake(28, 50)];
                isSelected = (choice == index);
            }
            cell.accessoryType = isSelected ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
            break;
        }
        default: {
            ThemeSkin skin = (ThemeSkin)indexPath.row;
            cell.imageView.image = [self roundedIcon:[Theme iconPreviewForSkin:skin] side:44];
            cell.textLabel.text = (skin == ThemeSkinClaude) ? L(@"icon_default") : [Theme skinName:skin];
            cell.detailTextLabel.text = nil;
            cell.accessoryType = (skin == [self currentIconSkin]) ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
            break;
        }
    }
    return cell;
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section {
    if ([view isKindOfClass:[UITableViewHeaderFooterView class]]) ((UITableViewHeaderFooterView *)view).textLabel.textColor = [Theme secondaryText];
}

- (void)tableView:(UITableView *)tableView willDisplayFooterView:(UIView *)view forSection:(NSInteger)section {
    if ([view isKindOfClass:[UITableViewHeaderFooterView class]]) ((UITableViewHeaderFooterView *)view).textLabel.textColor = [Theme secondaryText];
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == AppearanceSectionMode && indexPath.row == 0) return 16 + kModePreviewSize.height + 36 + 24 + 14;
    if (indexPath.section == AppearanceSectionIcon) return 62;
    if (indexPath.section == AppearanceSectionWallpaper && indexPath.row >= 1) return 64;
    return 56;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    switch (indexPath.section) {
        case AppearanceSectionSkin:
            [self chooseSkin:(ThemeSkin)indexPath.row];
            break;
        case AppearanceSectionWallpaper: {
            NSInteger choice;
            if (indexPath.row == 0) choice = -1;
            else if (indexPath.row == 1) choice = 0;
            else choice = indexPath.row - 1;
            [Theme setWallpaperChoice:choice];
            [Theme postChange];
            break;
        }
        case AppearanceSectionIcon:
            [self changeIconToSkin:(ThemeSkin)indexPath.row];
            break;
        default:
            break;
    }
}

#pragma mark - Actions

// Picking light or dark by hand turns "Tự động" off (like iOS).
- (void)lightTapped { [self chooseDark:NO]; }
- (void)darkTapped  { [self chooseDark:YES]; }

- (void)chooseDark:(BOOL)dark {
    if (![Theme autoMode] && [Theme darkMode] == dark) return;
    [Theme setAutoMode:NO];
    [Theme setDarkMode:dark];
    [Theme postChange];
}

- (void)autoToggled:(UISwitch *)toggle {
    if (!toggle.isOn) {
        [Theme setDarkMode:[Theme darkMode]];   // keep what is shown now as the manual choice
    }
    [Theme setAutoMode:toggle.isOn];
    [Theme postChange];
}

- (void)chooseSkin:(ThemeSkin)skin {
    if (skin == [Theme skin]) return;
    [Theme setSkin:skin];
    [Theme postChange];

    // Each skin has its own icon: offer to switch the Home Screen icon too (iOS shows its own confirmation).
    if (skin != ThemeSkinClaude && [self iconsSupported] && [self currentIconSkin] != skin) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:L(@"icon_offer_title")
                                                                       message:[NSString stringWithFormat:L(@"icon_offer_msg"), [Theme skinName:skin]]
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:L(@"icon_offer_no") style:UIAlertActionStyleCancel handler:nil]];
        __weak typeof(self) weakSelf = self;
        [alert addAction:[UIAlertAction actionWithTitle:L(@"icon_offer_yes") style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [weakSelf changeIconToSkin:skin];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

- (void)changeIconToSkin:(ThemeSkin)skin {
    if (self.changingIcon) return;
    if (![self iconsSupported]) {
        [self showMessage:L(@"appearance_icon_unsupported")];
        return;
    }
    if (skin == [self currentIconSkin]) return;

    if ([Theme iconHelperAvailable]) {
        self.changingIcon = YES;
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSString *failure = nil;
            BOOL ok = [Theme applyIconWithHelperForSkin:skin message:&failure];
            dispatch_async(dispatch_get_main_queue(), ^{
                AppearanceViewController *me = weakSelf;
                if (!me) return;
                me.changingIcon = NO;
                [me.tableView reloadData];
                if (ok) {
                    [DiagnosticLog log:@"icon changed through the root helper"];
                    [me showMessage:L(@"icon_helper_done")];
                } else {
                    [DiagnosticLog log:@"icon helper: %@", failure ?: @"-"];
                    [me showMessage:[NSString stringWithFormat:L(@"icon_error"), failure ?: @"-"]];
                }
            });
        });
        return;
    }
    if (@available(iOS 10.3, *)) {
        self.changingIcon = YES;
        NSString *name = [Theme iconNameForSkin:skin];   // nil = back to the default icon
        __weak typeof(self) weakSelf = self;
        [[UIApplication sharedApplication] setAlternateIconName:name completionHandler:^(NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                AppearanceViewController *me = weakSelf;
                if (!me) return;
                me.changingIcon = NO;
                if (error) {
                    [DiagnosticLog log:@"icon change failed: %@ (%ld)", error.localizedDescription, (long)error.code];
                    [me showMessage:[NSString stringWithFormat:L(@"icon_error"), error.localizedDescription ?: @"-"]];
                }
                [me.tableView reloadData];
            });
        }];
    }
}

- (void)showMessage:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
