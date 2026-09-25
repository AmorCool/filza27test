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
- (void)refreshDisplay;
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

    _segments = [[UISegmentedControl alloc] initWithItems:@[ @"设置", @"浏览", @"日志" ]];
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
            browse.title = @"浏览";
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
    [stack addArrangedSubview:ALMakeSectionTitle(@"日志")];

    _logView = [[UITextView alloc] init];
    _logView.editable = NO;
    _logView.font = [UIFont fontWithName:@"Menlo" size:11] ?: [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    _logView.backgroundColor = UIColor.secondarySystemBackgroundColor;
    _logView.textContainerInset = UIEdgeInsetsMake(8, 8, 8, 8);
    _logView.layer.cornerRadius = 8;
    _logView.text = @"先配对，确认回环 VPN 已连接，然后即可任意读写。\n";
    _logView.translatesAutoresizingMaskIntoConstraints = NO;
    [stack addArrangedSubview:_logView];
    [NSLayoutConstraint activateConstraints:@[
        [_logView.heightAnchor constraintEqualToConstant:220],
    ]];

    for (NSString *line in _bridge.logLines) [self appendLogLine:line];
}

- (UIView *)buildVPNCard {
    UIStackView *card = ALMakeCard();
    [card addArrangedSubview:ALMakeSectionTitle(@"LocalDevVPN 回环")];

    _vpnLabel = [UILabel new];
    _vpnLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    _vpnLabel.text = @"…";

    _networkDetailLabel = [UILabel new];
    _networkDetailLabel.font = [UIFont systemFontOfSize:12];
    _networkDetailLabel.textColor = UIColor.secondaryLabelColor;
    _networkDetailLabel.numberOfLines = 0;

    UIButton *refresh = ALMakeButton(@"刷新状态", UIColor.systemBlueColor);
    [refresh addTarget:self action:@selector(refreshVPN) forControlEvents:UIControlEventTouchUpInside];

    UIButton *netPerm = ALMakeButton(@"请求本地网络权限", UIColor.systemBlueColor);
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
    [card addArrangedSubview:ALMakeSectionTitle(@"内置配对（RPPairing）")];

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

    _startPairingButton = ALMakeButton(@"开始配对", UIColor.systemGreenColor);
    [_startPairingButton addTarget:self action:@selector(startPairing)
                  forControlEvents:UIControlEventTouchUpInside];

    _stopPairingButton = ALMakeButton(@"停止", UIColor.systemRedColor);
    [_stopPairingButton addTarget:self action:@selector(stopPairing)
                 forControlEvents:UIControlEventTouchUpInside];
    _stopPairingButton.enabled = NO;

    [actions addArrangedSubview:_startPairingButton];
    [actions addArrangedSubview:_stopPairingButton];

    UIButton *importButton = ALMakeButton(@"导入配对文件…", UIColor.systemBlueColor);
    [importButton addTarget:self action:@selector(importPairingFile)
           forControlEvents:UIControlEventTouchUpInside];

    _pairingPathField = [self textFieldWithText:@""
                                      placeholder:@"/path/to/pairing_file.plist"];
    UIStackView *pathRow = [[UIStackView alloc] init];
    pathRow.axis = UILayoutConstraintAxisHorizontal;
    pathRow.spacing = 8;
    pathRow.alignment = UIStackViewAlignmentCenter;
    UIButton *usePath = ALMakeButton(@"使用该路径", UIColor.systemIndigoColor);
    [usePath addTarget:self action:@selector(usePairingPath)
      forControlEvents:UIControlEventTouchUpInside];
    [pathRow addArrangedSubview:_pairingPathField];
    [pathRow addArrangedSubview:usePath];
    [_pairingPathField.widthAnchor constraintGreaterThanOrEqualToConstant:150].active = YES;

    UILabel *pairHint = [UILabel new];
    pairHint.font = [UIFont systemFontOfSize:12];
    pairHint.textColor = UIColor.secondaryLabelColor;
    pairHint.numberOfLines = 0;
    pairHint.text = @"没有配对文件？把已有的 pairing plist 放进 Filza Airlift/"
                    @"Documents（或命名为 airlift_pairing.plist），也可以直接发起一次新配对。";

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
    [card addArrangedSubview:ALMakeSectionTitle(@"传输（读取 / 写入 / 删除）")];

    _targetField = [self textFieldWithText:@"/var/mobile/Library/SpringBoard"
                                 placeholder:@"金丝雀写入目标目录"];
    UIButton *canary = ALMakeButton(@"测试金丝雀写入（验证沙箱逃逸）", UIColor.systemBlueColor);
    [canary addTarget:self action:@selector(runCanary) forControlEvents:UIControlEventTouchUpInside];

    _readDirField = [self textFieldWithText:@"/var/mobile/Library/SpringBoard"
                                 placeholder:@"读取：目标目录"];
    _readLeafField = [self textFieldWithText:@"IconState.plist"
                                 placeholder:@"读取：文件名"];
    UIButton *read = ALMakeButton(@"拉取文件 → Imports/（提取并还原）", UIColor.systemGreenColor);
    [read addTarget:self action:@selector(runRead) forControlEvents:UIControlEventTouchUpInside];

    _deleteDirField = [self textFieldWithText:@"/var/mobile/Library/SpringBoard"
                                   placeholder:@"删除：目标目录"];
    _deleteLeafField = [self textFieldWithText:@"airlift_canary.cards"
                                   placeholder:@"删除：文件名"];
    UIButton *del = ALMakeButton(@"删除设备上的文件", UIColor.systemRedColor);
    [del addTarget:self action:@selector(runDelete) forControlEvents:UIControlEventTouchUpInside];

    _pushTargetField = [self textFieldWithText:@"/var/mobile/Library/Caches"
                                    placeholder:@"推送目标目录"];
    UIButton *push = ALMakeButton(@"推送 Staging 文件夹 → 目标目录", UIColor.systemPurpleColor);
    [push addTarget:self action:@selector(runPush) forControlEvents:UIControlEventTouchUpInside];

    UILabel *hint = [UILabel new];
    hint.font = [UIFont systemFontOfSize:12];
    hint.textColor = UIColor.secondaryLabelColor;
    hint.numberOfLines = 0;
    hint.text = @"读取会把文件拉进 Airlift/Imports，并在设备上还原（提取语义）。"
                @"写入则通过 com.apple.atc 把 Airlift/Staging 里的 Cairo "
                @"文件夹注入设备。该通道无法列目录 — "
                @"请用「浏览 ▸ 索引」查看已知路径。";

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
    [self appendLogLine:@"已刷新 LocalDevVPN 状态。"];
}

- (void)requestLocalNetwork {
    [_bridge requestLocalNetworkAccess];
    [self refreshDisplay];
    [self appendLogLine:@"已请求本地网络权限 — 请在弹窗中允许，然后再配对。"];
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
        [self appendLogLine:@"请先输入配对文件路径。"];
        return;
    }
    NSError *error = NULL;
    if ([_bridge importPairingFileAtPath:path errorOut:&error]) {
        [self appendLogLine:[NSString stringWithFormat:@"已从 %@ 导入配对文件", path]];
    } else {
        [self appendLogLine:[NSString stringWithFormat:@"导入失败：%@",
            error.localizedDescription ?: @"未知错误"]];
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
        [self appendLogLine:[NSString stringWithFormat:@"已从 %@ 导入配对文件", url.path]];
    } else {
        [self appendLogLine:[NSString stringWithFormat:@"导入失败：%@",
            error.localizedDescription ?: @"未知错误"]];
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
    [self appendLogLine:@"— 已请求金丝雀写入 —"];
    [_bridge canaryWriteAtTarget:target completion:^(NSInteger rc, NSDictionary *json, NSString *error) {
        [self appendLogLine:[NSString stringWithFormat:@"金丝雀 返回码=%ld", (long)rc]];
        if (error.length) [self appendLogLine:error];
        if (json[@"target"]) {
            [self appendLogLine:[NSString stringWithFormat:@"目标=%ld 个文件",
                ((NSNumber *)json[@"target"]).longValue]];
        }
        if (json[@"knownPaths"]) {
            [self appendLogLine:[NSString stringWithFormat:@"已写入=%ld",
                ((NSNumber *)json[@"knownPaths"]).longValue]];
        }
    }];
}

- (void)runRead {
    NSString *dir = _readDirField.text ?: @"";
    NSString *leaf = _readLeafField.text ?: @"";
    if (!dir.length || !leaf.length) {
        [self appendLogLine:@"读取需要同时填写目标目录和文件名。"];
        return;
    }
    NSString *outPath = [_bridge.airliftImportsPath stringByAppendingPathComponent:leaf];
    [self appendLogLine:@"— 已请求读取（提取并还原）—"];
    [_bridge readFileAtDir:dir leaf:leaf toPath:outPath
                completion:^(NSInteger rc, NSDictionary *json, NSString *error) {
        [self appendLogLine:[NSString stringWithFormat:@"读取 返回码=%ld", (long)rc]];
        if (error.length) [self appendLogLine:error];
        if (json[@"outputPath"]) {
            [self appendLogLine:[NSString stringWithFormat:@"已拉取 → %@", json[@"outputPath"]]];
        }
        if ([json[@"restored"] boolValue]) [self appendLogLine:@"文件已在设备上还原 ✔"];
    }];
}

- (void)runDelete {
    NSString *dir = _deleteDirField.text ?: @"";
    NSString *leaf = _deleteLeafField.text ?: @"";
    if (!dir.length || !leaf.length) {
        [self appendLogLine:@"删除需要同时填写目标目录和文件名。"];
        return;
    }
    [self appendLogLine:@"— 已请求删除 —"];
    [_bridge removeFileAtDir:dir leaf:leaf
                  completion:^(NSInteger rc, NSDictionary *json, NSString *error) {
        [self appendLogLine:[NSString stringWithFormat:@"删除 返回码=%ld", (long)rc]];
        if (error.length) [self appendLogLine:error];
        if ([json[@"removed"] boolValue]) [self appendLogLine:@"已删除 ✔"];
        if ([json[@"targetAbsent"] boolValue]) [self appendLogLine:@"目标文件原本就不存在"];
    }];
}

- (void)runPush {
    NSString *target = _pushTargetField.text ?: @"";
    if (!target.length) {
        [self appendLogLine:@"请先输入推送目标目录。"];
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
        [self appendLogLine:@"Airlift/Staging 里没有可推送的文件夹，请先放入一个。"];
        return;
    }
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"推送到设备"
                         message:[NSString stringWithFormat:@"选择一个 Staging 文件夹，写入 %@",
                             target]
                  preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSString *name in names) {
        [alert addAction:[UIAlertAction actionWithTitle:name style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *action) {
                NSString *src = [_bridge.airliftStagingPath stringByAppendingPathComponent:name];
                [self pushFolder:src toTarget:target];
            }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    if (alert.popoverPresentationController) {
        alert.popoverPresentationController.sourceView = self.view;
    }
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)pushFolder:(NSString *)source toTarget:(NSString *)target {
    [self appendLogLine:@"— 已请求文件夹推送 —"];
    [_bridge writeDirectory:source toTarget:target completion:^(NSInteger rc, NSString *error) {
        [self appendLogLine:[NSString stringWithFormat:@"推送 返回码=%ld", (long)rc]];
        if (error.length) [self appendLogLine:error];
    }];
}

#pragma mark - Panel display

- (void)refreshDisplay {
    _vpnLabel.text = _bridge.vpnUp
        ? @"● 回环隧道已连接"
        : @"○ 回环隧道未连接";
    _vpnLabel.textColor = _bridge.vpnUp
        ? UIColor.systemGreenColor
        : UIColor.systemRedColor;
    _networkDetailLabel.text = _bridge.networkDetail.length
        ? _bridge.networkDetail : @"没有隧道接口 — 请启动 LocalDevVPN (10.7.0.1)";

    if (_bridge.isPairing) {
        _pairingLabel.text = @"配对中…请打开 设置 › 隐私与安全性 › 开发者模式";
        _startPairingButton.enabled = NO;
        _stopPairingButton.enabled = YES;
    } else {
        _pairingLabel.text = _bridge.hasPairingFile
            ? [NSString stringWithFormat:@"已配对 ✅ 设备：%@",
                _bridge.pairedDeviceName ?: @"未知"]
            : @"未配对 — 请开始配对，或将 pairing plist 放入 Filza Airlift/Documents";
        _startPairingButton.enabled = YES;
        _stopPairingButton.enabled = NO;
    }

    if (_bridge.pairingPIN.length) {
        _pinLabel.text = [NSString stringWithFormat:@"请输入 PIN 码 %@", _bridge.pairingPIN];
    } else {
        _pinLabel.text = @"";
    }

    _pairingFileLabel.text = [NSString stringWithFormat:@"%@ · %@",
        _bridge.pairingFilePath,
        _bridge.hasPairingFile ? @"存在" : @"缺失"];
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