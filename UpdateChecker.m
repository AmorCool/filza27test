#import "UpdateChecker.h"

#import <UIKit/UIKit.h>

static NSString *const kFSUpdateAPIURL =
    @"https://api.github.com/repos/0xjohnnydev/FilzaSlop/releases/latest";
static NSString *const kFSVersionInfoKey = @"FilzaSlopVersion";
static NSString *const kFSLastCheckDateKey = @"FilzaSlopUpdateLastCheckDate";
static NSString *const kFSLastCheckedVersionKey =
    @"FilzaSlopUpdateLastCheckedVersion";
static NSString *const kFSLastAlertedTagKey =
    @"FilzaSlopUpdateLastAlertedTag";
static const NSTimeInterval kFSUpdateCheckInterval = 24.0 * 60.0 * 60.0;

static BOOL gFSUpdateCheckerStarted;
static BOOL gFSUpdateCheckInFlight;
static BOOL gFSUpdatePresentationScheduled;
static NSDictionary<NSString *, NSString *> *gFSPendingRelease;

static NSString *FSUpdateVersion(NSString *value)
{
    if (![value isKindOfClass:NSString.class]) return nil;
    NSString *version = [value stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([version hasPrefix:@"v"] || [version hasPrefix:@"V"])
        version = [version substringFromIndex:1];
    return version.length > 0 ? version : nil;
}

static NSString *FSCurrentVersion(void)
{
    return FSUpdateVersion([NSBundle.mainBundle objectForInfoDictionaryKey:
        kFSVersionInfoKey]);
}

static BOOL FSUpdateVersionIsNewer(NSString *latest, NSString *current)
{
    NSString *latestVersion = FSUpdateVersion(latest);
    NSString *currentVersion = FSUpdateVersion(current);
    if (!latestVersion || !currentVersion) return NO;
    return [latestVersion compare:currentVersion options:NSNumericSearch] ==
        NSOrderedDescending;
}

static UIViewController *FSTopViewController(UIViewController *controller)
{
    UIViewController *current = controller;
    while (current) {
        UIViewController *next = nil;
        if (current.presentedViewController &&
            !current.presentedViewController.isBeingDismissed) {
            next = current.presentedViewController;
        } else if ([current isKindOfClass:UINavigationController.class]) {
            next = ((UINavigationController *)current).visibleViewController;
        } else if ([current isKindOfClass:UITabBarController.class]) {
            next = ((UITabBarController *)current).selectedViewController;
        }
        if (!next || next == current) break;
        current = next;
    }
    return current;
}

static UIViewController *FSUpdatePresenter(void)
{
    UIApplication *application = UIApplication.sharedApplication;
    UIWindow *selectedWindow = nil;
    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] ||
            scene.activationState != UISceneActivationStateForegroundActive)
            continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isHidden || window.alpha == 0.0 || !window.rootViewController)
                continue;
            if (window.isKeyWindow) return FSTopViewController(window.rootViewController);
            if (!selectedWindow) selectedWindow = window;
        }
    }
    return selectedWindow ? FSTopViewController(selectedWindow.rootViewController)
                          : nil;
}

static NSURL *FSReleaseURL(NSString *value)
{
    NSURL *url = [NSURL URLWithString:value ?: @""];
    NSString *host = url.host.lowercaseString;
    NSString *path = url.path.lowercaseString;
    if (![url.scheme.lowercaseString isEqualToString:@"https"] ||
        ![host isEqualToString:@"github.com"] ||
        ![path hasPrefix:@"/0xjohnnydev/filzaslop/releases/"])
        return nil;
    return url;
}

static void FSScheduleUpdatePresentation(NSUInteger attemptsRemaining);

static void FSPresentPendingUpdate(void)
{
    NSDictionary<NSString *, NSString *> *release = gFSPendingRelease;
    if (!release) return;

    UIViewController *presenter = FSUpdatePresenter();
    if (!presenter || !presenter.view.window || presenter.isBeingDismissed ||
        [presenter isKindOfClass:UIAlertController.class])
        return;

    NSString *tag = release[@"tag"];
    NSString *current = FSCurrentVersion();
    NSURL *releaseURL = FSReleaseURL(release[@"url"]);
    if (!tag.length || !current.length || !releaseURL) {
        gFSPendingRelease = nil;
        return;
    }

    NSString *message = [NSString stringWithFormat:
        @"Version %@ is available. You have version %@.", tag, current];
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"FilzaSlop Update Available"
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Later"
        style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"View Release"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [UIApplication.sharedApplication openURL:releaseURL options:@{}
                completionHandler:nil];
        }]];

    gFSPendingRelease = nil;
    [presenter presentViewController:alert animated:YES completion:^{
        [NSUserDefaults.standardUserDefaults setObject:tag
            forKey:kFSLastAlertedTagKey];
    }];
}

static void FSScheduleUpdatePresentation(NSUInteger attemptsRemaining)
{
    if (!gFSPendingRelease || gFSUpdatePresentationScheduled) return;
    gFSUpdatePresentationScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
        dispatch_get_main_queue(), ^{
            gFSUpdatePresentationScheduled = NO;
            FSPresentPendingUpdate();
            if (gFSPendingRelease && attemptsRemaining > 1)
                FSScheduleUpdatePresentation(attemptsRemaining - 1);
        });
}

static void FSHandleReleaseResponse(NSData *data, NSURLResponse *response,
                                    NSError *error)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        gFSUpdateCheckInFlight = NO;
        NSInteger statusCode = [response isKindOfClass:NSHTTPURLResponse.class]
            ? ((NSHTTPURLResponse *)response).statusCode : 0;
        if (error || statusCode != 200 || data.length == 0) {
            NSLog(@"[UpdateChecker] request failed status=%ld error=%@",
                  (long)statusCode, error);
            return;
        }

        NSError *jsonError = nil;
        NSDictionary *payload = [NSJSONSerialization JSONObjectWithData:data
            options:0 error:&jsonError];
        if (![payload isKindOfClass:NSDictionary.class]) {
            NSLog(@"[UpdateChecker] invalid response error=%@", jsonError);
            return;
        }

        NSString *tag = [payload[@"tag_name"] isKindOfClass:NSString.class]
            ? payload[@"tag_name"] : nil;
        NSString *releaseURL = [payload[@"html_url"] isKindOfClass:NSString.class]
            ? payload[@"html_url"] : nil;
        NSString *current = FSCurrentVersion();
        if (tag == nil || releaseURL == nil) {
            NSLog(@"[UpdateChecker] response omitted release metadata");
            return;
        }
        if (!FSUpdateVersionIsNewer(tag, current)) {
            NSLog(@"[UpdateChecker] current=%@ latest=%@", current, tag);
            return;
        }

        NSString *lastAlerted = [NSUserDefaults.standardUserDefaults
            stringForKey:kFSLastAlertedTagKey];
        if ([lastAlerted isEqualToString:tag]) return;
        if (!FSReleaseURL(releaseURL)) {
            NSLog(@"[UpdateChecker] rejected release URL %@", releaseURL);
            return;
        }

        gFSPendingRelease = @{ @"tag": tag, @"url": releaseURL };
        FSScheduleUpdatePresentation(10);
    });
}

static void FSCheckForUpdateIfNeeded(void)
{
    NSCAssert(NSThread.isMainThread,
              @"Update checks must start on the main thread");
    if (gFSUpdateCheckInFlight) return;

    NSString *current = FSCurrentVersion();
    if (!current.length) {
        NSLog(@"[UpdateChecker] %@ is missing; skipping update check",
              kFSVersionInfoKey);
        return;
    }

    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSDate *lastCheck = [defaults objectForKey:kFSLastCheckDateKey];
    if (![lastCheck isKindOfClass:NSDate.class]) lastCheck = nil;
    NSString *lastVersion = [defaults stringForKey:kFSLastCheckedVersionKey];
    NSTimeInterval elapsed = lastCheck
        ? [NSDate.date timeIntervalSinceDate:lastCheck] : kFSUpdateCheckInterval;
    BOOL sameVersion = [lastVersion isEqualToString:current];
    if (sameVersion && elapsed >= 0.0 && elapsed < kFSUpdateCheckInterval)
        return;

    [defaults setObject:NSDate.date forKey:kFSLastCheckDateKey];
    [defaults setObject:current forKey:kFSLastCheckedVersionKey];
    gFSUpdateCheckInFlight = YES;

    NSMutableURLRequest *request = [NSMutableURLRequest
        requestWithURL:[NSURL URLWithString:kFSUpdateAPIURL]
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:15.0];
    [request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"2022-11-28"
        forHTTPHeaderField:@"X-GitHub-Api-Version"];
    [request setValue:@"FilzaSlop-UpdateChecker" forHTTPHeaderField:@"User-Agent"];
    NSURLSessionDataTask *task = [NSURLSession.sharedSession
        dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response,
                            NSError *error) {
            FSHandleReleaseResponse(data, response, error);
        }];
    [task resume];
}

void FSUpdateCheckerStart(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gFSUpdateCheckerStarted) return;
        gFSUpdateCheckerStarted = YES;
        [NSNotificationCenter.defaultCenter
            addObserverForName:UIApplicationDidBecomeActiveNotification
            object:nil queue:NSOperationQueue.mainQueue
            usingBlock:^(__unused NSNotification *notification) {
                FSScheduleUpdatePresentation(10);
                FSCheckForUpdateIfNeeded();
            }];
        if (UIApplication.sharedApplication.applicationState ==
            UIApplicationStateActive)
            FSCheckForUpdateIfNeeded();
    });
}
