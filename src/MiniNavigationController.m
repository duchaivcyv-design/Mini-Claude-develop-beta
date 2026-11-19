#import "MiniNavigationController.h"
#import "Theme.h"
#import "Strings.h"
#import "AppSettings.h"

@interface MiniNavigationController ()
@property (assign, nonatomic) BOOL transitioning;
@property (copy, nonatomic) NSString *barSignature;
@end

@implementation MiniNavigationController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.delegate = self;
    self.interactivePopGestureRecognizer.delegate = self;
}

#pragma mark - Back button

- (UIBarButtonItem *)makeBackItem {
    UIBarButtonItem *item = [[UIBarButtonItem alloc] initWithImage:[Theme iconBack] style:UIBarButtonItemStylePlain target:self action:@selector(backTapped)];
    item.accessibilityLabel = L(@"close");
    return item;
}

- (void)backTapped {
    if (self.viewControllers.count > 1) [self popViewControllerAnimated:YES];
}

#pragma mark - UINavigationControllerDelegate

- (void)navigationController:(UINavigationController *)navigationController willShowViewController:(UIViewController *)viewController animated:(BOOL)animated {
    self.transitioning = YES;
    // Screens above the first one get the plain back button unless they bring their own left item (the history list does).
    if (navigationController.viewControllers.count > 1 && viewController.navigationItem.leftBarButtonItem == nil && !viewController.navigationItem.hidesBackButton) {
        viewController.navigationItem.leftBarButtonItem = [self makeBackItem];
        viewController.navigationItem.hidesBackButton = YES;
    }
    // If the transition is cancelled (a half-done swipe), UIKit tells us through the coordinator.
    id<UIViewControllerTransitionCoordinator> coordinator = navigationController.transitionCoordinator;
    if (coordinator) {
        __weak typeof(self) weakSelf = self;
        [coordinator notifyWhenInteractionChangesUsingBlock:^(id<UIViewControllerTransitionCoordinatorContext> context) {
            if (context.isCancelled) weakSelf.transitioning = NO;
        }];
    }
}

- (void)navigationController:(UINavigationController *)navigationController didShowViewController:(UIViewController *)viewController animated:(BOOL)animated {
    self.transitioning = NO;
    self.interactivePopGestureRecognizer.enabled = YES;   // always back to a known state
    [self applyPendingBarStyle];
}

#pragma mark - Safe pushes

- (void)pushViewController:(UIViewController *)viewController animated:(BOOL)animated {
    if (self.transitionCoordinator) animated = NO;   // pushing during a transition would be dropped or crash
    [super pushViewController:viewController animated:animated];
}

#pragma mark - UIGestureRecognizerDelegate (edge swipe)

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer != self.interactivePopGestureRecognizer) return YES;
    if (self.viewControllers.count < 2) return NO;   // nothing to go back to: a swipe here would wedge the controller
    if (self.transitionCoordinator) return NO;
    UIViewController *top = self.topViewController;
    if ([top respondsToSelector:@selector(allowsBackSwipe)] && ![(id<MiniBackSwipeControl>)top allowsBackSwipe]) return NO;
    return YES;
}

#pragma mark - Bar style

// Restyles the bar only when the look really changed, and never in the middle of a push or pop.
- (void)restyleBarWhenIdle {
    if (self.transitionCoordinator) {
        __weak typeof(self) weakSelf = self;
        [self.transitionCoordinator animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> c) {
            [weakSelf applyPendingBarStyle];
        }];
        return;
    }
    [self applyPendingBarStyle];
}

- (void)applyPendingBarStyle {
    NSString *signature = [NSString stringWithFormat:@"%ld|%d|%ld", (long)[Theme skin], [Theme darkMode] ? 1 : 0, (long)[AppSettings fontStyle]];
    if ([signature isEqualToString:self.barSignature]) return;   // e.g. only the wallpaper changed
    self.barSignature = signature;
    [Theme styleNavigationBar:self.navigationBar];
    [self setNeedsStatusBarAppearanceUpdate];
}

@end
