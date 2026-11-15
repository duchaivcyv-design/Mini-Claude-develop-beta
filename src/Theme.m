#import "Theme.h"
#import "Strings.h"
#import <ImageIO/ImageIO.h>
#import <math.h>
#import <spawn.h>
#import <errno.h>
#import <sys/stat.h>
#import <sys/wait.h>

extern char **environ;

// ---------------------------------------------------------------------------------------------
// Palettes. Order of fields: background, surface, border, accent, text, secondary text, selection.
// [skin][0] = light, [skin][1] = dark.
// ---------------------------------------------------------------------------------------------
typedef struct {
    uint32_t bg, surface, border, accent, text, secondary, selection;
} ThemePalette;

static const ThemePalette kPalettes[ThemeSkinCount][2] = {
    // Claude (original look)
    { { 0xFAF9F5, 0xFFFFFF, 0xE3E0D5, 0xC96442, 0x29261B, 0x6F6B5E, 0xF0EEE6 },
      { 0x1F1E1B, 0x2B2A26, 0x3F3D38, 0xD9774F, 0xEEECE5, 0xA9A598, 0x34322E } },
    // SideStore Skin (purple)
    { { 0xF5F1FE, 0xFFFFFF, 0xE1D7F6, 0x8A3FFC, 0x20172F, 0x66597F, 0xEBE3FA },
      { 0x130F1E, 0x1D1730, 0x33294D, 0xA878FF, 0xEFEAFB, 0xA99DC8, 0x2A2142 } },
    // LiveContainer Skin (sea blue)
    { { 0xEFF5FF, 0xFFFFFF, 0xD3E1F7, 0x0A6CFF, 0x10213B, 0x52668A, 0xE1ECFD },
      { 0x0B1220, 0x131C2E, 0x22324D, 0x4A98FF, 0xE7EFFC, 0x94A7C8, 0x1B2840 } },
    // Dopamine Skin (green)
    { { 0xEFF8F4, 0xFFFFFF, 0xCFE6DC, 0x14A36F, 0x0F2B26, 0x4D6F65, 0xDFF1E9 },
      { 0x0A1B1B, 0x112626, 0x1E3F3C, 0x2ED08E, 0xE2F4EE, 0x8DB4A9, 0x193431 } },
    // Chimera Skin (white)
    { { 0xF8F9FB, 0xFFFFFF, 0xE3E6EB, 0x2D9A92, 0x1B232B, 0x5F6B77, 0xEEF1F5 },
      { 0x141619, 0x1D2024, 0x2F333A, 0x45BDB3, 0xEDF0F3, 0x9EA6B0, 0x282C32 } },
    // Sileo Skin (cyan / teal)
    { { 0xEDF9FA, 0xFFFFFF, 0xCBE7EA, 0x0A9FAA, 0x0E2A2E, 0x4A6E73, 0xDDF1F3 },
      { 0x08191C, 0x0F2A2E, 0x1C4248, 0x1FCAD4, 0xE0F5F7, 0x8AB8BD, 0x163539 } },
    // Github Skin (red)
    { { 0xFBF3F5, 0xFFFFFF, 0xEBD3D9, 0xBE2748, 0x2A1418, 0x7A5A61, 0xF4E3E7 },
      { 0x1A0E12, 0x281820, 0x44272F, 0xE8506F, 0xF6E7EB, 0xBF9BA4, 0x372029 } },
};

static NSString *const kSkinKey = @"theme.skin";
static NSString *const kDarkKey = @"theme.dark";
static NSString *const kAutoKey = @"theme.auto";
static NSString *const kWallpaperKey = @"theme.wallpaper";
static NSString *const kHelperIconKey = @"theme.helperIconSkin";

static ThemeSkin gSkin = ThemeSkinClaude;
static BOOL gDark = NO;        // the manual choice (used when auto mode is off)
static BOOL gAuto = NO;        // follow the device clock: dark from 18:00 to 05:59
static BOOL gLastDark = NO;    // what the screens were last styled with (to notice the clock crossing 18:00 / 06:00)
static NSInteger gWallpaper = -1;
static dispatch_once_t gPrefsOnce;

static BOOL IsNightNow(void);

static void LoadPrefs(void) {
    dispatch_once(&gPrefsOnce, ^{
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        NSInteger skin = [defaults integerForKey:kSkinKey];
        gSkin = (skin >= 0 && skin < ThemeSkinCount) ? (ThemeSkin)skin : ThemeSkinClaude;
        gDark = [defaults boolForKey:kDarkKey];
        gAuto = [defaults boolForKey:kAutoKey];
        NSNumber *wallpaper = [defaults objectForKey:kWallpaperKey];
        NSInteger choice = [wallpaper isKindOfClass:[NSNumber class]] ? wallpaper.integerValue : -1;
        gWallpaper = (choice >= -1 && choice < ThemeSkinCount) ? choice : -1;
        gLastDark = gAuto ? IsNightNow() : gDark;
    });
}

// Device clock: night is 18:00-05:59 (same hour boundaries as the "Chào buổi tối" greeting).
static BOOL IsNightNow(void) {
    NSInteger hour = [[NSCalendar currentCalendar] component:NSCalendarUnitHour fromDate:[NSDate date]];
    return hour >= 18 || hour < 6;
}

static BOOL EffectiveDark(void) {
    LoadPrefs();
    return gAuto ? IsNightNow() : gDark;
}

static ThemePalette CurrentPalette(void) {
    LoadPrefs();
    return kPalettes[gSkin][EffectiveDark() ? 1 : 0];
}

static UIColor *HexColor(uint32_t hex) {
    return [UIColor colorWithRed:((hex >> 16) & 0xFF) / 255.0
                           green:((hex >> 8) & 0xFF) / 255.0
                            blue:(hex & 0xFF) / 255.0
                           alpha:1.0];
}

// t = 0 gives a, t = 1 gives b.
static uint32_t MixHex(uint32_t a, uint32_t b, double t) {
    double r = ((a >> 16) & 0xFF) * (1 - t) + ((b >> 16) & 0xFF) * t;
    double g = ((a >> 8) & 0xFF) * (1 - t) + ((b >> 8) & 0xFF) * t;
    double bl = (a & 0xFF) * (1 - t) + (b & 0xFF) * t;
    return ((uint32_t)lround(r) << 16) | ((uint32_t)lround(g) << 8) | (uint32_t)lround(bl);
}

static uint32_t ScaleHex(uint32_t a, double factor) {
    double r = MIN(255.0, ((a >> 16) & 0xFF) * factor);
    double g = MIN(255.0, ((a >> 8) & 0xFF) * factor);
    double b = MIN(255.0, (a & 0xFF) * factor);
    return ((uint32_t)lround(r) << 16) | ((uint32_t)lround(g) << 8) | (uint32_t)lround(b);
}

static NSString *CSSHex(uint32_t hex) {
    return [NSString stringWithFormat:@"#%06X", (unsigned)(hex & 0xFFFFFF)];
}

static NSString *CSSRGBA(uint32_t hex, double alpha) {
    return [NSString stringWithFormat:@"rgba(%u,%u,%u,%.2f)", (unsigned)((hex >> 16) & 0xFF),
            (unsigned)((hex >> 8) & 0xFF), (unsigned)(hex & 0xFF), alpha];
}

static NSString *WallpaperFileKey(NSInteger index) {
    static NSString *const keys[] = { @"", @"sidestore", @"livecontainer", @"dopamine", @"chimera", @"sileo", @"github" };
    if (index < 1 || index >= ThemeSkinCount) return nil;
    return keys[index];
}

@implementation Theme

#pragma mark - Palette

+ (UIColor *)background     { return HexColor(CurrentPalette().bg); }
+ (UIColor *)surface        { return HexColor(CurrentPalette().surface); }
+ (UIColor *)border         { return HexColor(CurrentPalette().border); }
+ (UIColor *)accent         { return HexColor(CurrentPalette().accent); }
+ (UIColor *)accentPressed  { return HexColor(ScaleHex(CurrentPalette().accent, 0.84)); }
+ (UIColor *)accentDisabled { ThemePalette p = CurrentPalette(); return HexColor(MixHex(p.accent, p.bg, 0.55)); }
+ (UIColor *)text           { return HexColor(CurrentPalette().text); }
+ (UIColor *)secondaryText  { return HexColor(CurrentPalette().secondary); }
+ (UIColor *)success        { LoadPrefs(); return HexColor(EffectiveDark() ? 0x5CB985 : 0x3F7D58); }
+ (UIColor *)error          { LoadPrefs(); return HexColor(EffectiveDark() ? 0xE8705A : 0xB3402A); }
+ (UIColor *)selection      { return HexColor(CurrentPalette().selection); }

+ (UIFont *)serifFontOfSize:(CGFloat)size {
    UIFont *font = [UIFont fontWithName:@"Georgia" size:size];
    return font ? font : [UIFont systemFontOfSize:size weight:UIFontWeightSemibold];
}

+ (UIImage *)imageWithColor:(UIColor *)color {
    CGRect rect = CGRectMake(0, 0, 1, 1);
    UIGraphicsBeginImageContextWithOptions(rect.size, NO, 0);
    [color setFill];
    UIRectFill(rect);
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return [image resizableImageWithCapInsets:UIEdgeInsetsZero];
}

+ (UIKeyboardAppearance)keyboardAppearance {
    LoadPrefs();
    return EffectiveDark() ? UIKeyboardAppearanceDark : UIKeyboardAppearanceLight;
}

#pragma mark - Icons

+ (UIImage *)iconWithSize:(CGSize)size draw:(void (^)(CGContextRef ctx))draw {
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *rendererContext) {
        draw(rendererContext.CGContext);
    }];
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

+ (UIImage *)iconMenu {
    return [self iconWithSize:CGSizeMake(24, 24) draw:^(CGContextRef c) {
        CGContextSetStrokeColorWithColor(c, [UIColor blackColor].CGColor);
        CGContextSetLineWidth(c, 2);
        CGContextSetLineCap(c, kCGLineCapRound);
        CGFloat ys[3] = {6.5, 12, 17.5};
        for (int i = 0; i < 3; i++) {
            CGContextMoveToPoint(c, 4, ys[i]);
            CGContextAddLineToPoint(c, 20, ys[i]);
        }
        CGContextStrokePath(c);
    }];
}

+ (UIImage *)iconPlus {
    return [self iconWithSize:CGSizeMake(24, 24) draw:^(CGContextRef c) {
        CGContextSetStrokeColorWithColor(c, [UIColor blackColor].CGColor);
        CGContextSetLineWidth(c, 2);
        CGContextSetLineCap(c, kCGLineCapRound);
        CGContextMoveToPoint(c, 12, 5);
        CGContextAddLineToPoint(c, 12, 19);
        CGContextMoveToPoint(c, 5, 12);
        CGContextAddLineToPoint(c, 19, 12);
        CGContextStrokePath(c);
    }];
}

+ (UIImage *)iconCompose {
    return [self iconWithSize:CGSizeMake(24, 24) draw:^(CGContextRef c) {
        CGContextSetStrokeColorWithColor(c, [UIColor blackColor].CGColor);
        CGContextSetLineWidth(c, 2);
        CGContextSetLineCap(c, kCGLineCapRound);
        CGContextSetLineJoin(c, kCGLineJoinRound);
        UIBezierPath *path = [UIBezierPath bezierPath];
        // rounded square, open at the top-right where the pencil goes
        [path moveToPoint:CGPointMake(11, 5)];
        [path addLineToPoint:CGPointMake(7, 5)];
        [path addQuadCurveToPoint:CGPointMake(4, 8) controlPoint:CGPointMake(4, 5)];
        [path addLineToPoint:CGPointMake(4, 17)];
        [path addQuadCurveToPoint:CGPointMake(7, 20) controlPoint:CGPointMake(4, 20)];
        [path addLineToPoint:CGPointMake(16, 20)];
        [path addQuadCurveToPoint:CGPointMake(19, 17) controlPoint:CGPointMake(19, 20)];
        [path addLineToPoint:CGPointMake(19, 13)];
        // pencil
        [path moveToPoint:CGPointMake(10.5, 13.5)];
        [path addLineToPoint:CGPointMake(19.5, 4.5)];
        CGContextAddPath(c, path.CGPath);
        CGContextStrokePath(c);
    }];
}

+ (UIImage *)iconSend {
    return [self iconWithSize:CGSizeMake(20, 20) draw:^(CGContextRef c) {
        CGContextSetStrokeColorWithColor(c, [UIColor blackColor].CGColor);
        CGContextSetLineWidth(c, 2.2);
        CGContextSetLineCap(c, kCGLineCapRound);
        CGContextSetLineJoin(c, kCGLineJoinRound);
        CGContextMoveToPoint(c, 10, 16.5);
        CGContextAddLineToPoint(c, 10, 4);
        CGContextMoveToPoint(c, 4.5, 9.5);
        CGContextAddLineToPoint(c, 10, 4);
        CGContextAddLineToPoint(c, 15.5, 9.5);
        CGContextStrokePath(c);
    }];
}

+ (UIImage *)iconStop {
    return [self iconWithSize:CGSizeMake(16, 16) draw:^(CGContextRef c) {
        CGContextSetFillColorWithColor(c, [UIColor blackColor].CGColor);
        UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(2, 2, 12, 12) cornerRadius:3];
        CGContextAddPath(c, path.CGPath);
        CGContextFillPath(c);
    }];
}

#pragma mark - Navigation bar

+ (void)styleNavigationBar:(UINavigationBar *)bar {
    LoadPrefs();
    bar.barStyle = EffectiveDark() ? UIBarStyleBlack : UIBarStyleDefault;   // also decides the status bar text colour
    bar.barTintColor = [self background];
    bar.tintColor = [self accent];
    bar.translucent = NO;
    // A custom shadow image is only honored together with a custom background image.
    [bar setBackgroundImage:[self imageWithColor:[self background]] forBarMetrics:UIBarMetricsDefault];
    bar.shadowImage = [[UIImage alloc] init];
    bar.titleTextAttributes = @{ NSForegroundColorAttributeName: [self text],
                                 NSFontAttributeName: [self serifFontOfSize:18] };
}

#pragma mark - Skin, dark mode, wallpaper

+ (ThemeSkin)skin { LoadPrefs(); return gSkin; }

+ (void)setSkin:(ThemeSkin)skin {
    LoadPrefs();
    if (skin < 0 || skin >= ThemeSkinCount) skin = ThemeSkinClaude;
    gSkin = skin;
    [[NSUserDefaults standardUserDefaults] setInteger:skin forKey:kSkinKey];
}

+ (BOOL)darkMode { return EffectiveDark(); }

+ (BOOL)autoMode { LoadPrefs(); return gAuto; }

+ (void)setAutoMode:(BOOL)automatic {
    LoadPrefs();
    gAuto = automatic;
    [[NSUserDefaults standardUserDefaults] setBool:automatic forKey:kAutoKey];
    gLastDark = EffectiveDark();
}

// YES once when auto mode crosses day <-> night while the app is open (then the screens must be restyled).
+ (BOOL)consumeAutoModeChange {
    LoadPrefs();
    BOOL now = EffectiveDark();
    if (now == gLastDark) return NO;
    gLastDark = now;
    return YES;
}

+ (void)setDarkMode:(BOOL)dark {
    LoadPrefs();
    gDark = dark;
    [[NSUserDefaults standardUserDefaults] setBool:dark forKey:kDarkKey];
    gLastDark = EffectiveDark();
}

+ (NSInteger)wallpaperChoice { LoadPrefs(); return gWallpaper; }

+ (void)setWallpaperChoice:(NSInteger)choice {
    LoadPrefs();
    if (choice < -1 || choice >= ThemeSkinCount) choice = -1;
    gWallpaper = choice;
    [[NSUserDefaults standardUserDefaults] setInteger:choice forKey:kWallpaperKey];
}

+ (NSInteger)effectiveWallpaperIndex {
    LoadPrefs();
    NSInteger index = gWallpaper < 0 ? (NSInteger)gSkin : gWallpaper;   // the Claude skin has no wallpaper (0)
    return (index >= 1 && index < ThemeSkinCount) ? index : 0;
}

+ (void)postChange {
    [[NSNotificationCenter defaultCenter] postNotificationName:kNotifThemeChanged object:nil];
}

+ (NSString *)skinName:(ThemeSkin)skin {
    switch (skin) {
        case ThemeSkinSideStore:     return @"SideStore Skin";
        case ThemeSkinLiveContainer: return @"LiveContainer Skin";
        case ThemeSkinDopamine:      return @"Dopamine Skin";
        case ThemeSkinChimera:       return @"Chimera Skin";
        case ThemeSkinSileo:         return @"Sileo Skin";
        case ThemeSkinGithub:        return @"Github Skin";
        default:                     return L(@"skin_claude");
    }
}

+ (NSString *)skinColorKey:(ThemeSkin)skin {
    switch (skin) {
        case ThemeSkinSideStore:     return @"skin_color_purple";
        case ThemeSkinLiveContainer: return @"skin_color_blue";
        case ThemeSkinDopamine:      return @"skin_color_green";
        case ThemeSkinChimera:       return @"skin_color_white";
        case ThemeSkinSileo:         return @"skin_color_cyan";
        case ThemeSkinGithub:        return @"skin_color_red";
        default:                     return @"skin_color_default";
    }
}

+ (UIColor *)swatchColorForSkin:(ThemeSkin)skin {
    LoadPrefs();
    if (skin < 0 || skin >= ThemeSkinCount) skin = ThemeSkinClaude;
    return HexColor(kPalettes[skin][EffectiveDark() ? 1 : 0].accent);
}

+ (NSString *)wallpaperName:(NSInteger)index {
    static NSString *const names[] = { @"", @"SideStore", @"LiveContainer", @"Dopamine", @"Chimera", @"Sileo", @"Github" };
    if (index < 1 || index >= ThemeSkinCount) return @"";
    return names[index];
}

+ (NSString *)wallpaperPathForIndex:(NSInteger)index {
    NSString *key = WallpaperFileKey(index);
    if (key.length == 0) return nil;
    return [[NSBundle mainBundle] pathForResource:[@"wp_" stringByAppendingString:key] ofType:@"jpg" inDirectory:@"Wallpapers"];
}

+ (UIImage *)wallpaperImage {
    static NSInteger cachedIndex = 0;
    static UIImage *cachedImage = nil;
    NSInteger index = [self effectiveWallpaperIndex];
    if (index == 0) {
        cachedIndex = 0;
        cachedImage = nil;   // free the decoded bitmap when no wallpaper is shown
        return nil;
    }
    if (cachedImage && cachedIndex == index) return cachedImage;
    NSString *path = [self wallpaperPathForIndex:index];
    UIImage *image = path ? [UIImage imageWithContentsOfFile:path] : nil;
    cachedImage = image;
    cachedIndex = image ? index : 0;
    return image;
}

+ (UIImage *)wallpaperThumbnail:(NSInteger)index {
    if (index < 1 || index >= ThemeSkinCount) return nil;
    static NSCache *cache = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [[NSCache alloc] init]; });
    UIImage *cached = [cache objectForKey:@(index)];
    if (cached) return cached;
    NSString *path = [self wallpaperPathForIndex:index];
    if (!path) return nil;
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
    if (!source) return nil;
    NSDictionary *options = @{ (id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
                               (id)kCGImageSourceCreateThumbnailWithTransform: @YES,
                               (id)kCGImageSourceShouldCacheImmediately: @YES,
                               (id)kCGImageSourceThumbnailMaxPixelSize: @240 };
    CGImageRef cg = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
    CFRelease(source);
    if (!cg) return nil;
    UIImage *image = [UIImage imageWithCGImage:cg scale:1 orientation:UIImageOrientationUp];
    CGImageRelease(cg);
    if (image) [cache setObject:image forKey:@(index)];
    return image;
}

+ (CGFloat)wallpaperDimAlpha {
    LoadPrefs();
    return EffectiveDark() ? 0.55 : 0.0;
}

#pragma mark - Light / dark preview (small phone mock-up in Settings > Appearance)

+ (UIImage *)modePreviewImageDark:(BOOL)dark size:(CGSize)size {
    LoadPrefs();
    ThemePalette p = kPalettes[gSkin][dark ? 1 : 0];
    NSInteger wallpaperIndex = [self effectiveWallpaperIndex];
    UIImage *wallpaper = wallpaperIndex > 0 ? [self wallpaperThumbnail:wallpaperIndex] : nil;
    CGRect rect = CGRectMake(0, 0, size.width, size.height);
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        UIBezierPath *outline = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(rect, 0.5, 0.5) cornerRadius:13];
        [outline addClip];

        [HexColor(p.bg) setFill];
        UIRectFill(rect);
        if (wallpaper) {
            CGFloat scale = MAX(size.width / wallpaper.size.width, size.height / wallpaper.size.height);
            CGSize drawn = CGSizeMake(wallpaper.size.width * scale, wallpaper.size.height * scale);
            [wallpaper drawInRect:CGRectMake((size.width - drawn.width) / 2, (size.height - drawn.height) / 2, drawn.width, drawn.height)];
            if (dark) {
                [[UIColor colorWithWhite:0 alpha:0.55] setFill];
                UIRectFill(rect);
            }
        }

        // title bar with the clock
        [HexColor(p.bg) setFill];
        UIRectFill(CGRectMake(0, 0, size.width, 24));
        NSDictionary *attrs = @{ NSFontAttributeName: [UIFont systemFontOfSize:9 weight:UIFontWeightSemibold],
                                 NSForegroundColorAttributeName: HexColor(p.text) };
        NSString *clock = @"09:41";
        CGSize clockSize = [clock sizeWithAttributes:attrs];
        [clock drawAtPoint:CGPointMake((size.width - clockSize.width) / 2, 7) withAttributes:attrs];

        // AI reply card with two text lines
        CGFloat margin = 8;
        [HexColor(p.surface) setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(margin, 34, size.width - margin * 2, 40) cornerRadius:8] fill];
        [HexColor(p.secondary) setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(margin + 6, 43, size.width - margin * 2 - 22, 4) cornerRadius:2] fill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(margin + 6, 53, size.width - margin * 2 - 36, 4) cornerRadius:2] fill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(margin + 6, 63, size.width - margin * 2 - 30, 4) cornerRadius:2] fill];

        // your message bubble
        [HexColor(p.accent) setFill];
        CGFloat bubbleWidth = size.width * 0.5;
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(size.width - margin - bubbleWidth, 84, bubbleWidth, 20) cornerRadius:9] fill];

        // input bar
        [HexColor(p.bg) setFill];
        UIRectFill(CGRectMake(0, size.height - 30, size.width, 30));
        UIBezierPath *field = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(margin, size.height - 25, size.width - margin * 2, 17) cornerRadius:8.5];
        [HexColor(p.surface) setFill];
        [field fill];
        [HexColor(p.border) setStroke];
        field.lineWidth = 1;
        [field stroke];

        // thin frame
        [HexColor(p.border) setStroke];
        outline.lineWidth = 1;
        [outline stroke];
    }];
}

#pragma mark - App icon

+ (NSString *)iconNameForSkin:(ThemeSkin)skin {
    switch (skin) {
        case ThemeSkinSideStore:     return @"SideStore";
        case ThemeSkinLiveContainer: return @"LiveContainer";
        case ThemeSkinDopamine:      return @"Dopamine";
        case ThemeSkinChimera:       return @"Chimera";
        case ThemeSkinSileo:         return @"Sileo";
        case ThemeSkinGithub:        return @"Github";
        default:                     return nil;
    }
}

+ (UIImage *)iconPreviewForSkin:(ThemeSkin)skin {
    NSString *name = [self iconNameForSkin:skin];
    NSString *file = [NSString stringWithFormat:@"Icon-%@@3x", name ?: @"Default"];
    NSString *path = [[NSBundle mainBundle] pathForResource:file ofType:@"png"];
    return path ? [UIImage imageWithContentsOfFile:path] : nil;
}

+ (NSString *)currentIconName {
    if (@available(iOS 10.3, *)) return [UIApplication sharedApplication].alternateIconName;
    return nil;
}

static NSString *HelperPath(void) {
    return [[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@"claudemini-icon"];
}

+ (BOOL)iconHelperAvailable {
    struct stat st;
    if (stat(HelperPath().fileSystemRepresentation, &st) != 0) return NO;
    return (st.st_mode & S_ISUID) != 0 && st.st_uid == 0;   // only the .deb install has it (owner root, setuid)
}

+ (ThemeSkin)helperIconSkin {
    NSInteger value = [[NSUserDefaults standardUserDefaults] integerForKey:kHelperIconKey];
    return (value >= 0 && value < ThemeSkinCount) ? (ThemeSkin)value : ThemeSkinClaude;
}

+ (BOOL)applyIconWithHelperForSkin:(ThemeSkin)skin message:(NSString **)message {
    if (![self iconHelperAvailable]) {
        if (message) *message = @"icon helper missing or not setuid";
        return NO;
    }
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSInteger previous = [defaults integerForKey:kHelperIconKey];
    [defaults setInteger:skin forKey:kHelperIconKey];   // saved first: uicache may restart the app
    [defaults synchronize];

    NSString *name = [self iconNameForSkin:skin] ?: @"Default";
    const char *path = HelperPath().fileSystemRepresentation;
    char *argv[] = { (char *)path, (char *)name.UTF8String, NULL };
    pid_t pid = 0;
    int spawnResult = posix_spawn(&pid, path, NULL, NULL, argv, environ);
    BOOL ok = NO;
    int code = -1;
    if (spawnResult == 0) {
        int status = 0;
        while (waitpid(pid, &status, 0) < 0) {
            if (errno != EINTR) break;
        }
        code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
        ok = (code == 0);
    } else {
        code = spawnResult;
    }
    if (!ok) {
        [defaults setInteger:previous forKey:kHelperIconKey];
        [defaults synchronize];
        if (message) *message = [NSString stringWithFormat:@"icon helper failed (code %d)", code];
    }
    return ok;
}

+ (void)reapplyHelperIconIfNeeded {
    if (![self iconHelperAvailable]) return;
    ThemeSkin skin = [self helperIconSkin];
    NSString *name = [self iconNameForSkin:skin] ?: @"Default";
    NSString *dir = [NSBundle mainBundle].bundlePath;
    NSData *current = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"AppIcon60x60@3x.png"]];
    NSData *wanted = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:[NSString stringWithFormat:@"Icon-%@@3x.png", name]]];
    if (current && wanted && ![current isEqualToData:wanted]) [self applyIconWithHelperForSkin:skin message:NULL];
}

#pragma mark - Web page

+ (NSString *)signature {
    LoadPrefs();
    return [NSString stringWithFormat:@"%ld-%d-%ld", (long)gSkin, EffectiveDark() ? 1 : 0, (long)[self effectiveWallpaperIndex]];
}

+ (NSString *)webThemeCSS {
    LoadPrefs();
    ThemePalette p = CurrentPalette();
    BOOL dark = EffectiveDark();
    BOOL hasWallpaper = [self effectiveWallpaperIndex] > 0;

    uint32_t bubble = (gSkin == ThemeSkinClaude) ? p.selection : MixHex(p.surface, p.accent, dark ? 0.30 : 0.16);
    uint32_t link = dark ? p.accent : ScaleHex(p.accent, 0.82);   // darker in light mode so links stay readable
    uint32_t codeBg = MixHex(p.bg, p.selection, 0.5);

    NSMutableString *css = [NSMutableString string];
    [css appendString:@":root{"];
    [css appendFormat:@"--bg:%@;--text:%@;--sec:%@;--border:%@;--sel:%@;--bubble:%@;",
        CSSHex(p.bg), CSSHex(p.text), CSSHex(p.secondary), CSSHex(p.border), CSSHex(p.selection), CSSHex(bubble)];
    [css appendFormat:@"--accent:%@;--onaccent:#FFFFFF;--link:%@;--card:%@;--code-bg:%@;",
        CSSHex(p.accent), CSSHex(link), CSSRGBA(p.surface, dark ? 0.88 : 0.90), CSSHex(codeBg)];
    if (dark) {
        [css appendString:@"--err-bg:#3A1D18;--err-border:#6B3328;--err-text:#F0A494;"];
        [css appendFormat:@"--toast-bg:%@;--toast-fg:%@;", CSSHex(p.text), CSSHex(p.bg)];
        [css appendString:@"--hl-kw:#E2896A;--hl-str:#7CC79A;--hl-com:#8F8B80;--hl-num:#6DB3DB;--hl-title:#B48AE0;--hl-attr:#E0A850;"];
    } else {
        [css appendString:@"--err-bg:#FCEDEA;--err-border:#EBC4BB;--err-text:#8F2F1D;"];
        [css appendFormat:@"--toast-bg:%@;--toast-fg:%@;", CSSHex(p.text), CSSHex(p.bg)];
        [css appendString:@"--hl-kw:#A5472B;--hl-str:#3F7D58;--hl-com:#8A8677;--hl-num:#2F6B8C;--hl-title:#7B4FA2;--hl-attr:#B0731A;"];
    }
    [css appendString:@"}"];

    if (hasWallpaper) {
        // Text sits on translucent cards so it stays readable on any wallpaper.
        [css appendString:@".row.assistant .body{background:var(--card);padding:12px 14px;border-radius:16px;}"];
        [css appendString:@".act{background:var(--card);}"];
        [css appendString:@".thinking-label{display:inline-block;background:var(--card);padding:3px 9px;border-radius:9px;}"];
        [css appendString:@".empty{background:var(--card);border-radius:22px;margin:14vh 6px 0 6px;padding:26px 16px 24px 16px;}"];
    }
    return css;
}

@end
