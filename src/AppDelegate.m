#import "AppDelegate.h"
#import "RootViewController.h"
#import "ChatViewController.h"
#import "KeyStore.h"
#import "Strings.h"
#import "Theme.h"
#import "DiagnosticLog.h"

@interface AppDelegate ()
@property (assign, nonatomic) BOOL showingMain;
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    [DiagnosticLog logLaunch];
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.backgroundColor = [Theme background];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applyKeyState)
                                                 name:kNotifKeyChanged
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(languageChanged)
                                                 name:kNotifLanguageChanged
                                               object:nil];

    [self applyKeyState];
    [self.window makeKeyAndVisible];
    return YES;
}

// Key present -> chat. No key -> key screen.
- (void)applyKeyState {
    BOOL hasKey = [KeyStore hasAnyKey];   // a Gemini key or a Claude key is enough
    if (self.window.rootViewController == nil) {
        if (hasKey) [self showMainAnimated:NO]; else [self showOnboardingAnimated:NO];
    } else if (hasKey && !self.showingMain) {
        [self showMainAnimated:YES];
    } else if (!hasKey && self.showingMain) {
        [self showOnboardingAnimated:YES];
    }
}

// The language was changed in Settings: rebuild the screens so every label uses it.
- (void)languageChanged {
    if (self.showingMain) [self showMainAnimated:YES]; else [self showOnboardingAnimated:YES];
}

- (void)setRoot:(UIViewController *)controller animated:(BOOL)animated {
    if (!animated || self.window.rootViewController == nil) {
        self.window.rootViewController = controller;
        return;
    }
    [UIView transitionWithView:self.window
                      duration:0.25
                       options:UIViewAnimationOptionTransitionCrossDissolve
                    animations:^{ self.window.rootViewController = controller; }
                    completion:nil];
}

- (void)showMainAnimated:(BOOL)animated {
    self.showingMain = YES;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[[ChatViewController alloc] init]];
    [Theme styleNavigationBar:nav.navigationBar];
    [self setRoot:nav animated:animated];
}

- (void)showOnboardingAnimated:(BOOL)animated {
    self.showingMain = NO;
    [self setRoot:[[RootViewController alloc] init] animated:animated];
}

@end
