#import "SetupViewController.h"
#import "AirliftBridge.h"
#import "AirliftBrowseViewController.h"

#import <objc/runtime.h>

/// Filza Airlift setup — a tabbed window into the Airlift transport:
///
///   Setup   LocalDevVPN status, RPPairing, canary, read/pull, delete, staging push
///   Browse  AirliftIndex catalog + Imports (pulled) + Staging folders
///   Log     everything the Rust core says
///
/// Presented from a floating button injected into Filza's key window by
/// SPSetupAddFloatingButton().

static const CGFloat kMargin = 16.0;
static const CGFloat kSpacing = 10.0;

static UILabel *ALMakeSectionTitle(NSString *text);
static UIButton *ALMakeButton(NSString *title, UIColor *tint);
static UIStackView *ALMakeCard(void);

#pragma mark - Panel (Setup form + Log)

@interface AirliftPanelViewController : UIViewController <UIDocumentPickerDelegate>
@end

#pragma mark - Container

@interface SetupViewController ()
@property (strong, nonatomic) UISegmentedControl *segments;
@property (strong, nonatomic) UIView *hostView;
@property (strong, nonatomic) UIViewController *current;
@property (strong, nonatomic) UITextView *logView;
@property (strong, nonatomic) AirliftPanelViewController *panel;
@end

@implementation SetupViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.title = @"Airlift";

    UIBarButtonItem *done = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                             target:self action:@selector(dismissSelf)];
    self.navigationItem.leftBarButtonItem = done;

    _segments = [[UISegmentedControl alloc] initWithItems:@[ @"Setup", @"Browse", @"Log" ]];
    _segments.selectedSegmentIndex = 0;
    [_segments addTarget:self action:@selector(segmentChanged)
        forControlEvents:UIControlEventValueChanged];
    _segments.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_segments];
    [_segments.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor
                                        constant:8].active = YES;
    [_segments.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:kMargin].active = YES;
    [_segments.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-kMargin].active = YES;

    _hostView = [UIView new];
    _hostView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_hostView];
    [_hostView.topAnchor constraintEqualToAnchor:_segments.bottomAnchor constant:8].active = YES;
    [_hostView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor].active = YES;
    [_hostView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor].active = YES;
    [_hostView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor].active = YES;

    _panel = [AirliftPanelViewController new];
    [self swapTo:_panel];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [AirliftBridge.shared refreshVPNStatus];
    [AirliftBridge.shared refreshPairingFile];
    [_panel refreshDisplay];
}

- (void)dismissSelf {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)segmentChanged {
    switch (_segments.selectedSegmentIndex) {
        case 1: {
            AirliftBrowseViewController *browse = [AirliftBrowseViewController new];
            browse.title = @"Browse";
            [self swapTo:browse];
            break;
        }
        case 2: {
            UIViewController *log = [UIViewController new];
            log.view.backgroundColor = UIColor.systemBackgroundColor;
            _logView = [[UITextView alloc] initWithFrame:log.view.bounds];
            _logView.editable = NO;
            _logView.font = [UIFont fontWithName:@"Menlo" size:11] ?: [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
            _logView.backgroundColor = UIColor.secondarySystemBackgroundColor;
            _logView.textContainerInset = UIEdgeInsetsMake(8, 8, 8, 8);
            _logView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [log.view addSubview:_logView];
            for (NSString *line in AirliftBridge.shared.logLines) [self appendLogLine:line];
            [self swapTo:log];
            break;
        }
        default:
            [self swapTo:_panel];
            break;
    }
}

- (void)swapTo:(UIViewController *)child {
    if (_current == child) return;
    [_current willMoveToParentViewController:nil];
    [_current.view removeFromSuperview];
    [_current removeFromParentViewController];

    _current = child;
    [self addChildViewController:child];
    child.view.frame = _hostView.bounds;
    child.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [_hostView addSubview:child.view];
    [child didMoveToParentViewController:self];
}

- (void)appendLogLine:(NSString *)line {
    if (!line.length) return;
    NSString *text = _logView.text ?: @"";
    _logView.text = text.length
        ? [text stringByAppendingFormat:@"\n%@", line]
        : line;
    [_logView scrollRangeToVisible:NSMakeRange(_logView.text.length, 0)];
}

@end

#pragma mark - Panel implementation

@implementation AirliftPanelViewController {
    AirliftBridge *_bridge;

    UILabel *_vpnLabel;
    UILabel *_networkDetailLabel;
    UILabel *_pairingLabel;
    UILabel *_pairingFileLabel;
    UILabel *_pinLabel;
    UIButton *_startPairingButton;
    UIButton *_stopPairingButton;
    UITextField *_pairingPathField;
    UITextField *_targetField;
    UITextField *_readDirField;
    UITextField *_readLeafField;
    UITextField *_deleteDirField;
    UITextField *_deleteLeafField;
    UITextField *_pushTargetField;
    UITextView *_logView;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _bridge = AirliftBridge.shared;
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    [self buildInterface];

    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(logEntry:) name:ALBridgeLogEntryNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(refreshDisplay) name:ALBridgePairingStateChangeNotification object:nil];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)buildInterface {
    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:scroll];

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = kSpacing;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];

    UILayoutGuide *guide = scroll.contentLayoutGuide;
    UILayoutGuide *frame = scroll.frameLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:guide.topAnchor constant:8],
        [stack.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:kMargin],
        [stack.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-kMargin],
        [stack.bottomAnchor constraintEqualToAnchor:guide.bottomAnchor constant:-kMargin * 2],
        [stack.widthAnchor constraintEqualToAnchor:frame.widthAnchor constant:-kMargin * 2],
    ]];

    [stack addArrangedSubview:[self buildVPNCard]];
    [stack addArrangedSubview:[self buildPairingCard]];
    [stack addArrangedSubview:[self buildTransportCard]];
    [stack addArrangedSubview:ALMakeSectionTitle(@"Log")];

    _logView = [[UITextView alloc] init];
    _logView.editable = NO;
    _logView.font = [UIFont fontWithName:@"Menlo" size:11] ?: [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    _logView.backgroundColor = UIColor.secondarySystemBackgroundColor;
    _logView.textContainerInset = UIEdgeInsetsMake(8, 8, 8, 8);
    _logView.layer.cornerRadius = 8;
    _logView.text = @"Pair, confirm the loopback VPN is up, then read/write anything.\n";
    _logView.translatesAutoresizingMaskIntoConstraints = NO;
    [stack addArrangedSubview:_logView];
    [NSLayoutConstraint activateConstraints:@[
        [_logView.heightAnchor constraintEqualToConstant:220],
    ]];

    for (NSString *line in _bridge.logLines) [self appendLogLine:line];
}

- (UIView *)buildVPNCard {
    UIStackView *card = ALMakeCard();
    [card addArrangedSubview:ALMakeSectionTitle(@"LocalDevVPN Loopback")];

    _vpnLabel = [UILabel new];
    _vpnLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    _vpnLabel.text = @"…";

    _networkDetailLabel = [UILabel new];
    _networkDetailLabel.font = [UIFont systemFontOfSize:12];
    _networkDetailLabel.textColor = UIColor.secondaryLabelColor;
    _networkDetailLabel.numberOfLines = 0;

    UIButton *refresh = ALMakeButton(@"Refresh status", UIColor.systemBlueColor);
    [refresh addTarget:self action:@selector(refreshVPN) forControlEvents:UIControlEventTouchUpInside];

    UIButton *netPerm = ALMakeButton(@"Request Local Network access", UIColor.systemBlueColor);
    [netPerm addTarget:self action:@selector(requestLocalNetwork)
       forControlEvents:UIControlEventTouchUpInside];

    [card addArrangedSubview:_vpnLabel];
    [card addArrangedSubview:_networkDetailLabel];
    [card addArrangedSubview:refresh];
    [card addArrangedSubview:netPerm];
    return card;
}

- (UIView *)buildPairingCard {
    UIStackView *card = ALMakeCard();
    [card addArrangedSubview:ALMakeSectionTitle(@"Built-in Pairing (RPPairing)")];

    _pairingLabel = [UILabel new];
    _pairingLabel.font = [UIFont systemFontOfSize:14];
    _pairingLabel.numberOfLines = 0;

    _pinLabel = [UILabel new];
    _pinLabel.font = [UIFont monospacedDigitSystemFontOfSize:16 weight:UIFontWeightBold];
    _pinLabel.textColor = UIColor.systemOrangeColor;
    _pinLabel.numberOfLines = 0;

    _pairingFileLabel = [UILabel new];
    _pairingFileLabel.font = [UIFont systemFontOfSize:12];
    _pairingFileLabel.textColor = UIColor.secondaryLabelColor;
    _pairingFileLabel.numberOfLines = 0;

    UIStackView *actions = [[UIStackView alloc] init];
    actions.axis = UILayoutConstraintAxisHorizontal;
    actions.spacing = 10;
    actions.distribution = UIStackViewDistributionFillEqually;

    _startPairingButton = ALMakeButton(@"Start Pairing", UIColor.systemGreenColor);
    [_startPairingButton addTarget:self action:@selector(startPairing)
                  forControlEvents:UIControlEventTouchUpInside];

    _stopPairingButton = ALMakeButton(@"Stop", UIColor.systemRedColor);
    [_stopPairingButton addTarget:self action:@selector(stopPairing)
                 forControlEvents:UIControlEventTouchUpInside];
    _stopPairingButton.enabled = NO;

    [actions addArrangedSubview:_startPairingButton];
    [actions addArrangedSubview:_stopPairingButton];

    UIButton *importButton = ALMakeButton(@"Import pairing file…", UIColor.systemBlueColor);
    [importButton addTarget:self action:@selector(importPairingFile)
           forControlEvents:UIControlEventTouchUpInside];

    _pairingPathField = [self textFieldWithText:@""
                                      placeholder:@"/path/to/pairing_file.plist"];
    UIStackView *pathRow = [[UIStackView alloc] init];
    pathRow.axis = UILayoutConstraintAxisHorizontal;
    pathRow.spacing = 8;
    pathRow.alignment = UIStackViewAlignmentCenter;
    UIButton *usePath = ALMakeButton(@"Use path", UIColor.systemIndigoColor);
    [usePath addTarget:self action:@selector(usePairingPath)
      forControlEvents:UIControlEventTouchUpInside];
    [pathRow addArrangedSubview:_pairingPathField];
    [pathRow addArrangedSubview:usePath];
    [_pairingPathField.widthAnchor constraintGreaterThanOrEqualToConstant:150].active = YES;

    UILabel *pairHint = [UILabel new];
    pairHint.font = [UIFont systemFontOfSize:12];
    pairHint.textColor = UIColor.secondaryLabelColor;
    pairHint.numberOfLines = 0;
    pairHint.text = @"No pairing? Drop an existing pairing plist into Filza Airlift/"
                    @"Documents (or airlift_pairing.plist), or start a fresh pair.";

    [card addArrangedSubview:_pairingLabel];
    [card addArrangedSubview:_pinLabel];
    [card addArrangedSubview:_pairingFileLabel];
    [card addArrangedSubview:actions];
    [card addArrangedSubview:importButton];
    [card addArrangedSubview:pathRow];
    [card addArrangedSubview:pairHint];
    return card;
}

- (UIView *)buildTransportCard {
    UIStackView *card = ALMakeCard();
    [card addArrangedSubview:ALMakeSectionTitle(@"Transport (read / write / delete)")];

    _targetField = [self textFieldWithText:@"/var/mobile/Library/SpringBoard"
                                 placeholder:@"canary target dir"];
    UIButton *canary = ALMakeButton(@"Test canary write (verify escape)", UIColor.systemBlueColor);
    [canary addTarget:self action:@selector(runCanary) forControlEvents:UIControlEventTouchUpInside];

    _readDirField = [self textFieldWithText:@"/var/mobile/Library/SpringBoard"
                                 placeholder:@"read: target dir"];
    _readLeafField = [self textFieldWithText:@"IconState.plist"
                                 placeholder:@"read: file name"];
    UIButton *read = ALMakeButton(@"Pull file → Imp/ (extract + restore)", UIColor.systemGreenColor);
    [read addTarget:self action:@selector(runRead) forControlEvents:UIControlEventTouchUpInside];

    _deleteDirField = [self textFieldWithText:@"/var/mobile/Library/SpringBoard"
                                   placeholder:@"delete: target dir"];
    _deleteLeafField = [self textFieldWithText:@"airlift_canary.cards"
                                   placeholder:@"delete: file name"];
    UIButton *del = ALMakeButton(@"Delete file on device", UIColor.systemRedColor);
    [del addTarget:self action:@selector(runDelete) forControlEvents:UIControlEventTouchUpInside];

    _pushTargetField = [self textFieldWithText:@"/var/mobile/Library/Caches"
                                    placeholder:@"push target dir"];
    UIButton *push = ALMakeButton(@"Push Staging folder → target", UIColor.systemPurpleColor);
    [push addTarget:self action:@selector(runPush) forControlEvents:UIControlEventTouchUpInside];

    UILabel *hint = [UILabel new];
    hint.font = [UIFont systemFontOfSize:12];
    hint.textColor = UIColor.secondaryLabelColor;
    hint.numberOfLines = 0;
    hint.text = @"Reading pulls the file into Airlift/Imports and restores it on "
                @"the device (extract semantics). Writing injects Cairo folders "
                @"from Airlift/Staging via com.apple.atc. No directory listing is "
                @"possible — use Browse ▸ Index for known paths.";

    [card addArrangedSubview:_targetField];
    [card addArrangedSubview:canary];
    [card addArrangedSubview:_readDirField];
    [card addArrangedSubview:_readLeafField];
    [card addArrangedSubview:read];
    [card addArrangedSubview:_deleteDirField];
    [card addArrangedSubview:_deleteLeafField];
    [card addArrangedSubview:del];
    [card addArrangedSubview:_pushTargetField];
    [card addArrangedSubview:push];
    [card addArrangedSubview:hint];
    return card;
}

- (UITextField *)textFieldWithText:(NSString *)text placeholder:(NSString *)placeholder {
    UITextField *field = [UITextField new];
    field.text = text;
    field.placeholder = placeholder;
    field.borderStyle = UITextBorderStyleRoundedRect;
    field.font = [UIFont systemFontOfSize:13];
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    return field;
}

#pragma mark - Panel actions

- (void)refreshVPN {
    [_bridge refreshVPNStatus];
    [_bridge refreshPairingFile];
    [self refreshDisplay];
    [self appendLogLine:@"Refreshed LocalDevVPN status."];
}

- (void)requestLocalNetwork {
    [_bridge requestLocalNetworkAccess];
    [self refreshDisplay];
    [self appendLogLine:@"Requested Local Network access — allow the prompt, then pair."];
}

- (void)importPairingFile {
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:@[] asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)usePairingPath {
    NSString *path = [_pairingPathField.text
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!path.length) {
        [self appendLogLine:@"Enter a pairing file path first."];
        return;
    }
    NSError *error = NULL;
    if ([_bridge importPairingFileAtPath:path errorOut:&error]) {
        [self appendLogLine:[NSString stringWithFormat:@"Imported pairing file from %@", path]];
    } else {
        [self appendLogLine:[NSString stringWithFormat:@"Import failed: %@",
            error.localizedDescription ?: @"unknown error"]];
    }
    [self refreshDisplay];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
    didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) return;
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSError *error = NULL;
    BOOL ok = [_bridge importPairingFileAtPath:url.path errorOut:&error];
    if (scoped) [url stopAccessingSecurityScopedResource];
    if (ok) {
        [self appendLogLine:[NSString stringWithFormat:@"Imported pairing file from %@", url.path]];
    } else {
        [self appendLogLine:[NSString stringWithFormat:@"Import failed: %@",
            error.localizedDescription ?: @"unknown error"]];
    }
    [self refreshDisplay];
}

- (void)startPairing {
    [_bridge startPairing];
    [self refreshDisplay];
}

- (void)stopPairing {
    [_bridge stopPairing];
    [self refreshDisplay];
}

- (void)runCanary {
    NSString *target = _targetField.text.length ? _targetField.text : nil;
    [self appendLogLine:@"— canary write requested —"];
    [_bridge canaryWriteAtTarget:target completion:^(NSInteger rc, NSDictionary *json, NSString *error) {
        [self appendLogLine:[NSString stringWithFormat:@"canary rc=%ld", (long)rc]];
        if (error.length) [self appendLogLine:error];
        if (json[@"target"]) {
            [self appendLogLine:[NSString stringWithFormat:@"target=%ld files",
                ((NSNumber *)json[@"target"]).longValue]];
        }
        if (json[@"knownPaths"]) {
            [self appendLogLine:[NSString stringWithFormat:@"written=%ld",
                ((NSNumber *)json[@"knownPaths"]).longValue]];
        }
    }];
}

- (void)runRead {
    NSString *dir = _readDirField.text ?: @"";
    NSString *leaf = _readLeafField.text ?: @"";
    if (!dir.length || !leaf.length) {
        [self appendLogLine:@"Read needs a target dir and a file name."];
        return;
    }
    NSString *outPath = [_bridge.airliftImportsPath stringByAppendingPathComponent:leaf];
    [self appendLogLine:@"— read (extract + restore) requested —"];
    [_bridge readFileAtDir:dir leaf:leaf toPath:outPath
                completion:^(NSInteger rc, NSDictionary *json, NSString *error) {
        [self appendLogLine:[NSString stringWithFormat:@"read rc=%ld", (long)rc]];
        if (error.length) [self appendLogLine:error];
        if (json[@"outputPath"]) {
            [self appendLogLine:[NSString stringWithFormat:@"pulled → %@", json[@"outputPath"]]];
        }
        if ([json[@"restored"] boolValue]) [self appendLogLine:@"file restored on device ✔"];
    }];
}

- (void)runDelete {
    NSString *dir = _deleteDirField.text ?: @"";
    NSString *leaf = _deleteLeafField.text ?: @"";
    if (!dir.length || !leaf.length) {
        [self appendLogLine:@"Delete needs a target dir and a file name."];
        return;
    }
    [self appendLogLine:@"— delete requested —"];
    [_bridge removeFileAtDir:dir leaf:leaf
                  completion:^(NSInteger rc, NSDictionary *json, NSString *error) {
        [self appendLogLine:[NSString stringWithFormat:@"delete rc=%ld", (long)rc]];
        if (error.length) [self appendLogLine:error];
        if ([json[@"removed"] boolValue]) [self appendLogLine:@"removed ✔"];
        if ([json[@"targetAbsent"] boolValue]) [self appendLogLine:@"target was already absent"];
    }];
}

- (void)runPush {
    NSString *target = _pushTargetField.text ?: @"";
    if (!target.length) {
        [self appendLogLine:@"Enter a push target dir first."];
        return;
    }
    NSArray *folders = [NSFileManager.defaultManager
        contentsOfDirectoryAtPath:_bridge.airliftStagingPath error:NULL];
    NSMutableArray *names = [NSMutableArray array];
    for (NSString *name in folders) {
        if (name.length == 0 || [name hasPrefix:@"."]) continue;
        NSString *full = [_bridge.airliftStagingPath stringByAppendingPathComponent:name];
        BOOL isDir = NO;
        [NSFileManager.defaultManager fileExistsAtPath:full isDirectory:&isDir];
        if (isDir) [names addObject:name];
    }
    if (!names.count) {
        [self appendLogLine:@"No staging folders in Airlift/Staging. Put one there first."];
        return;
    }
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Push to device"
                         message:[NSString stringWithFormat:@"Pick a Staging folder to write into %@",
                             target]
                  preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSString *name in names) {
        [alert addAction:[UIAlertAction actionWithTitle:name style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *action) {
                NSString *src = [_bridge.airliftStagingPath stringByAppendingPathComponent:name];
                [self pushFolder:src toTarget:target];
            }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    if (alert.popoverPresentationController) {
        alert.popoverPresentationController.sourceView = self.view;
    }
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)pushFolder:(NSString *)source toTarget:(NSString *)target {
    [self appendLogLine:@"— folder push requested —"];
    [_bridge writeDirectory:source toTarget:target completion:^(NSInteger rc, NSString *error) {
        [self appendLogLine:[NSString stringWithFormat:@"push rc=%ld", (long)rc]];
        if (error.length) [self appendLogLine:error];
    }];
}

#pragma mark - Panel display

- (void)refreshDisplay {
    _vpnLabel.text = _bridge.vpnUp
        ? @"● Loopback tunnel up"
        : @"○ Loopback tunnel down";
    _vpnLabel.textColor = _bridge.vpnUp
        ? UIColor.systemGreenColor
        : UIColor.systemRedColor;
    _networkDetailLabel.text = _bridge.networkDetail.length
        ? _bridge.networkDetail : @"No tunnel interfaces — start LocalDevVPN (10.7.0.1)";

    if (_bridge.isPairing) {
        _pairingLabel.text = @"Pairing… open Settings › Privacy & Security › Developer Mode";
        _startPairingButton.enabled = NO;
        _stopPairingButton.enabled = YES;
    } else {
        _pairingLabel.text = _bridge.hasPairingFile
            ? [NSString stringWithFormat:@"Paired ✅ device: %@",
                _bridge.pairedDeviceName ?: @"unknown"]
            : @"Not paired — start pairing or drop a pairing plist into Filza Airlift/Documents";
        _startPairingButton.enabled = YES;
        _stopPairingButton.enabled = NO;
    }

    if (_bridge.pairingPIN.length) {
        _pinLabel.text = [NSString stringWithFormat:@"Enter PIN %@", _bridge.pairingPIN];
    } else {
        _pinLabel.text = @"";
    }

    _pairingFileLabel.text = [NSString stringWithFormat:@"%@ · %@",
        _bridge.pairingFilePath,
        _bridge.hasPairingFile ? @"present" : @"missing"];
}

- (void)appendLogLine:(NSString *)line {
    if (!line.length) return;
    NSString *text = _logView.text ?: @"";
    _logView.text = text.length
        ? [text stringByAppendingFormat:@"\n%@", line]
        : line;
    [_logView scrollRangeToVisible:NSMakeRange(_logView.text.length, 0)];
}

- (void)logEntry:(NSNotification *)note {
    [self appendLogLine:note.object];
}

@end

#pragma mark - Helpers

static UILabel *ALMakeSectionTitle(NSString *text) {
    UILabel *label = [UILabel new];
    label.text = text.uppercaseString;
    label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
    label.textColor = UIColor.systemGrayColor;
    return label;
}

static UIStackView *ALMakeCard(void) {
    UIStackView *card = [[UIStackView alloc] init];
    card.axis = UILayoutConstraintAxisVertical;
    card.spacing = 8;
    card.backgroundColor = UIColor.secondarySystemBackgroundColor;
    card.layer.cornerRadius = 10;
    card.layoutMargins = UIEdgeInsetsMake(12, 12, 12, 12);
    card.layoutMarginsRelativeArrangement = YES;
    return card;
}

static UIButton *ALMakeButton(NSString *title, UIColor *tint) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:tint forState:UIControlStateNormal];
    button.layer.cornerRadius = 8;
    button.layer.borderWidth = 1;
    button.layer.borderColor = tint.CGColor;
    button.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    button.contentEdgeInsets = UIEdgeInsetsMake(8, 10, 8, 10);
    return button;
}

#pragma mark - Floating entry button

/// Routes UIControl / UIGestureRecognizer events to blocks (no public block API
/// exists for either, so a tiny selector target bridges them).
@interface SPButtonTarget : NSObject
@property (copy, nonatomic) void (^onTap)(UIButton *button);
@property (copy, nonatomic) void (^onPanStart)(UIPanGestureRecognizer *g);
@property (copy, nonatomic) void (^onPanChange)(UIPanGestureRecognizer *g);
- (void)handleTap:(UIButton *)button;
- (void)handlePan:(UIPanGestureRecognizer *)g;
@end

@implementation SPButtonTarget
- (void)handleTap:(UIButton *)button { if (self.onTap) self.onTap(button); }
- (void)handlePan:(UIPanGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) {
        if (self.onPanStart) self.onPanStart(g);
    } else if (g.state == UIGestureRecognizerStateChanged) {
        if (self.onPanChange) self.onPanChange(g);
    }
}
@end

static UIViewController *ALSetupTopController(void) {
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
        if (!next && controller.childViewControllers.count == 1)
            next = controller.childViewControllers.firstObject;
        if (!next || next == controller) break;
        controller = next;
    }
    return controller;
}

static void ALSetupPresentFrom(UIViewController *controller) {
    SetupViewController *setup = [SetupViewController new];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:setup];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [controller presentViewController:nav animated:YES completion:nil];
}

static void ALSetupInstallButtonOnWindow(UIWindow *window) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.backgroundColor = [UIColor.systemBlueColor colorWithAlphaComponent:0.9];
    button.layer.cornerRadius = 26;
    button.clipsToBounds = YES;
    [button setTitle:@"⛁" forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.frame = CGRectMake(window.bounds.size.width - 58,
                               window.bounds.size.height - 90, 52, 52);
    button.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin |
                              UIViewAutoresizingFlexibleTopMargin;
    button.accessibilityLabel = @"Airlift";

    SPButtonTarget *target = [SPButtonTarget new];
    __weak typeof(button) weakButton = button;
    target.onTap = ^(UIButton *sender) {
        UIViewController *top = ALSetupTopController();
        if (top) ALSetupPresentFrom(top);
    };
    target.onPanChange = ^(UIPanGestureRecognizer *g) {
        UIButton *b = weakButton;
        if (!b) return;
        CGPoint translation = [g translationInView:b.superview];
        b.center = CGPointMake(b.center.x + translation.x, b.center.y + translation.y);
        [g setTranslation:CGPointZero inView:b.superview];
    };

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
        initWithTarget:target action:@selector(handlePan:)];
    [button addGestureRecognizer:pan];
    [button addTarget:target action:@selector(handleTap:)
        forControlEvents:UIControlEventTouchUpInside];

    // Keep the target alive for the lifetime of the window the button lives in.
    objc_setAssociatedObject(button, @selector(handleTap:), target,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    [window addSubview:button];
    [window bringSubviewToFront:button];
}

void SPSetupAddFloatingButton(void) {
    static BOOL installed = NO;
    if (installed) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        if (!UIApplication.sharedApplication) return;

        // Wait for Filza's key window to exist before injecting.
        __block NSUInteger attempts = 0;
        __block __weak dispatch_block_t weakPoll;
        dispatch_block_t poll = ^{
            UIWindow *window = nil;
            for (UIWindow *candidate in UIApplication.sharedApplication.windows) {
                if (candidate.isKeyWindow) { window = candidate; break; }
            }
            if (!window) {
                if (++attempts < 20) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
                        dispatch_get_main_queue(), weakPoll);
                }
                return;
            }
            ALSetupInstallButtonOnWindow(window);
            installed = YES;
        };
        weakPoll = poll;
        poll();
    });
}