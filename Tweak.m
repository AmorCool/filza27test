// Filza Airlift — entry tweak.
//
// This is a jailed, sideloadable build of Filza (bundle uk.nouvborne.filzaal).
// No MobileHouseArrest identity, no MCM container exploit, no kernel code:
// everything outside the app sandbox goes through the on-device AirTraffic
// transport (see airlift/ + rust-core/).
//
// What this file does:
//   * creates the default Airlift folder layout on first launch
//   * points Filza's browser at Documents/Airlift ("Airlift")
//   * injects the floating Airlift button (setup + browse/search)
//
// The whole transport is deliberately separated from Filza's own UI heuristics;
// the only Filza internals we touch are the harmless path selectors used by the
// original release to relocate the initial browser directory.

#import <UIKit/UIKit.h>
#import <objc/message.h>

#import "airlift/AirliftBridge.h"
#import "airlift/SetupViewController.h"

#define AL_DEFAULT_ROOT_REL @"Airlift"

static NSString *ALDefaultRoot(void) {
    NSString *documents = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject
        ?: [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    return [documents stringByAppendingPathComponent:AL_DEFAULT_ROOT_REL];
}

// Create Documents/Airlift/{Staging,Imports}. Called once at construct time so
// the "default folders" already fit the transport before Filza's browser opens.
void ALCreateDefaultLayout(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *root = ALDefaultRoot();
    if (![fm fileExistsAtPath:root]) [fm createDirectoryAtPath:root
                                   withIntermediateDirectories:YES
                                                    attributes:nil error:NULL];
    for (NSString *sub in @[ @"Staging", @"Imports", @"Index" ]) {
        NSString *path = [root stringByAppendingPathComponent:sub];
        if (![fm fileExistsAtPath:path]) [fm createDirectoryAtPath:path
                                       withIntermediateDirectories:YES
                                                        attributes:nil error:NULL];
    }
    NSLog(@"[Airlift] default folders ready at %@", root);
}

#pragma mark - Browser relocation

static UIViewController *ALActiveBrowserController(void) {
    UIWindow *window = nil;
    for (UIWindow *candidate in UIApplication.sharedApplication.windows) {
        if (candidate.isKeyWindow) { window = candidate; break; }
        if (!window && !candidate.hidden) window = candidate;
    }
    UIViewController *controller = window.rootViewController;
    while (controller) {
        UIViewController *next = controller.presentedViewController;
        if (!next && [controller isKindOfClass:UINavigationController.class])
            next = ((UINavigationController *)controller).visibleViewController;
        if (!next && [controller isKindOfClass:UITabBarController.class])
            next = ((UITabBarController *)controller).selectedViewController;
        if (!next && [controller isKindOfClass:UISplitViewController.class])
            next = ((UISplitViewController *)controller).viewControllers.lastObject;
        if (!next && controller.childViewControllers.count == 1)
            next = controller.childViewControllers.firstObject;
        if (!next || next == controller) break;
        controller = next;
    }
    return controller;
}

static BOOL ALRepairActiveBrowserPath(void) {
    UIViewController *controller = ALActiveBrowserController();
    SEL currentPathSelector = NSSelectorFromString(@"currentPath");
    SEL setCurrentPathSelector = NSSelectorFromString(@"setCurrentPath:");
    if (![controller respondsToSelector:currentPathSelector] ||
        ![controller respondsToSelector:setCurrentPathSelector]) {
        return NO;
    }
    NSString *root = ALDefaultRoot();
    id currentPath = ((id(*)(id, SEL))objc_msgSend)(controller, currentPathSelector);
    NSString *path = [currentPath isKindOfClass:NSString.class]
        ? (NSString *)currentPath : @"";
    BOOL inside = [path isEqualToString:root] ||
        [path hasPrefix:[root stringByAppendingString:@"/"]];
    if (!inside) {
        ((void(*)(id, SEL, id))objc_msgSend)(controller, setCurrentPathSelector, root);
        controller.navigationItem.title = @"Airlift";
    }
    SEL loadSelector = NSSelectorFromString(@"doLoadingPage");
    if ([controller respondsToSelector:loadSelector]) {
        ((void(*)(id, SEL))objc_msgSend)(controller, loadSelector);
    }
    return YES;
}

static void ALScheduleBrowserRepair(NSUInteger attemptsRemaining) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 400 * NSEC_PER_MSEC),
        dispatch_get_main_queue(), ^{
            if (!ALRepairActiveBrowserPath() && attemptsRemaining > 1)
                ALScheduleBrowserRepair(attemptsRemaining - 1);
        });
}

#pragma mark - Entry Point

__attribute__((constructor)) void TweakInit(void) {
    ALCreateDefaultLayout();
    [AirliftBridge.shared warmup];
    ALScheduleBrowserRepair(8);
    SPSetupAddFloatingButton();
}