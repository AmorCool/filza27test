#import "AirliftBrowseViewController.h"
#import "AirliftBridge.h"
#import "AirliftIndex.h"

static NSInteger const kSectionIndex = 0;
static NSInteger const kSectionImports = 1;
static NSInteger const kSectionStaging = 2;

@interface AirliftBrowseViewController () <UISearchBarDelegate>
@property (strong, nonatomic) UISearchBar *searchBar;
@property (copy, nonatomic) NSString *query;
@property (copy, nonatomic) NSArray<AirliftIndexEntry *> *filtered;
@property (copy, nonatomic) NSArray<NSString *> *imports;
@property (copy, nonatomic) NSArray<NSString *> *staging;
@end

@implementation AirliftBrowseViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    _searchBar = [UISearchBar new];
    _searchBar.delegate = self;
    _searchBar.placeholder = @"搜索已知设备路径（IconState、prefs…）";
    _searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
    _searchBar.showsCancelButton = NO;
    self.tableView.tableHeaderView = _searchBar;

    if ([AirliftIndex.shared entries].count == 0) {
        [AirliftIndex.shared loadFromBundle];
    }

    if (@available(iOS 11.0, *)) {
        self.tableView.estimatedRowHeight = 44;
        self.tableView.rowHeight = UITableViewAutomaticDimension;
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadLocal];
    [self applyQuery];
}

#pragma mark - Data

- (void)reloadLocal {
    _imports = [self namesInDir:AirliftBridge.shared.airliftImportsPath onlyDirectories:NO];
    _staging = [self namesInDir:AirliftBridge.shared.airliftStagingPath onlyDirectories:YES];
    [self.tableView reloadData];
}

- (NSArray<NSString *> *)namesInDir:(NSString *)dir onlyDirectories:(BOOL)dirs {
    NSArray *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:NULL];
    NSMutableArray *result = [NSMutableArray array];
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *name in names) {
        if (name.length == 0 || [name hasPrefix:@"."]) continue;
        BOOL isDir = NO;
        [fm fileExistsAtPath:[dir stringByAppendingPathComponent:name] isDirectory:&isDir];
        if (dirs == isDir) [result addObject:name];
    }
    [result sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    return result;
}

- (void)applyQuery {
    NSString *q = [_query stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    _filtered = q.length ? [AirliftIndex.shared search:q] : AirliftIndex.shared.entries;
    [self.tableView reloadData];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 3;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case kSectionIndex:  return @"索引 — 设备上的已知路径";
        case kSectionImports: return @"导入 — 从设备拉取下来的文件";
        default: return @"暂存 — 待推送到设备的文件夹";
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case kSectionIndex:  return _filtered.count;
        case kSectionImports: return _imports.count;
        default: return _staging.count;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"alCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:@"alCell"];
    }
    cell.textLabel.text = @"";
    cell.detailTextLabel.text = @"";
    cell.textLabel.font = [UIFont systemFontOfSize:14];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:11];
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

    switch (indexPath.section) {
        case kSectionIndex: {
            AirliftIndexEntry *entry = _filtered[indexPath.row];
            cell.textLabel.text = entry.isDir
                ? [NSString stringWithFormat:@"📁 %@", entry.leafName]
                : [NSString stringWithFormat:@"📄 %@", entry.leafName];
            NSString *detail = entry.note.length
                ? [NSString stringWithFormat:@"%@ — %@", entry.path, entry.note]
                : entry.path;
            cell.detailTextLabel.text = detail;
            cell.detailTextLabel.numberOfLines = 2;
            break;
        }
        case kSectionImports:
            cell.textLabel.text = _imports[indexPath.row];
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%@/%@",
                AirliftBridge.shared.airliftImportsPath, _imports[indexPath.row]];
            break;
        default:
            cell.textLabel.text = [NSString stringWithFormat:@"📁 %@", _staging[indexPath.row]];
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%@/%@",
                AirliftBridge.shared.airliftStagingPath, _staging[indexPath.row]];
            break;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    switch (indexPath.section) {
        case kSectionIndex:
            [self indexRowSelected:indexPath.row];
            break;
        case kSectionImports:
            [self importsRowSelected:indexPath.row];
            break;
        case kSectionStaging:
            [self stagingRowSelected:indexPath.row];
            break;
    }
}

#pragma mark - Index actions

- (void)indexRowSelected:(NSInteger)row {
    AirliftIndexEntry *entry = _filtered[row];
    if (entry.isDir) {
        [self alert:[NSString stringWithFormat:@"📁 %@", entry.path]
            message:entry.note.length ? entry.note : @"已配对设备上的目录。AirTraffic 通道无法列目录 — 请在「设置」中输入文件名，或从索引中挑选文件。"];
        return;
    }
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:entry.leafName
                         message:entry.path
                  preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"拉取到 Imports（提取并还原）"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [self pullEntry:entry];
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"删除设备上的文件"
        style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            [self deleteEntry:entry];
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.sourceView = self.view;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)pullEntry:(AirliftIndexEntry *)entry {
    NSString *outPath = [AirliftBridge.shared.airliftImportsPath
        stringByAppendingPathComponent:entry.leafName];
    [self note:[NSString stringWithFormat:@"正在拉取 %@…", entry.path]];
    [AirliftBridge.shared readFileAtDir:entry.parentDirPath leaf:entry.leafName toPath:outPath
        completion:^(NSInteger rc, NSDictionary *json, NSString *error) {
            if (error.length) [self note:error];
            if ([json[@"outputPath"] isKindOfClass:NSString.class])
                [self note:[NSString stringWithFormat:@"已拉取 → %@", json[@"outputPath"]]];
            if ([json[@"restored"] boolValue]) [self note:@"已在设备上还原 ✔"];
            [self reloadLocal];
        }];
}

- (void)deleteEntry:(AirliftIndexEntry *)entry {
    [self note:[NSString stringWithFormat:@"正在删除 %@…", entry.path]];
    [AirliftBridge.shared removeFileAtDir:entry.parentDirPath leaf:entry.leafName
        completion:^(NSInteger rc, NSDictionary *json, NSString *error) {
            if (error.length) [self note:error];
            if ([json[@"removed"] boolValue]) [self note:@"已删除 ✔"];
            if ([json[@"targetAbsent"] boolValue]) [self note:@"目标文件原本就不存在。"];
        }];
}

#pragma mark - Local actions

- (void)importsRowSelected:(NSInteger)row {
    NSString *name = _imports[row];
    NSString *localPath = [AirliftBridge.shared.airliftImportsPath
        stringByAppendingPathComponent:name];

    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:localPath error:NULL];
    long long size = ((NSNumber *)attrs[NSFileSize]).longLongValue;

    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:name
                         message:[NSString stringWithFormat:@"%@ · %lld 字节", localPath, size]
                  preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"推送到设备…"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [self pushPromptForSourceFolder:localPath];
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"复制路径"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            UIPasteboard.generalPasteboard.string = localPath;
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"删除本地文件"
        style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            [NSFileManager.defaultManager removeItemAtPath:localPath error:NULL];
            [self reloadLocal];
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.sourceView = self.view;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)stagingRowSelected:(NSInteger)row {
    NSString *name = _staging[row];
    NSString *localPath = [AirliftBridge.shared.airliftStagingPath
        stringByAppendingPathComponent:name];
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:[NSString stringWithFormat:@"📁 %@", name]
                         message:localPath
                  preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"推送到设备…"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [self pushPromptForSourceFolder:localPath];
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"删除本地文件"
        style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            [NSFileManager.defaultManager removeItemAtPath:localPath error:NULL];
            [self reloadLocal];
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.sourceView = self.view;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)pushPromptForSourceFolder:(NSString *)source {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"推送到设备"
                         message:@"已配对设备上的目标目录"
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = @"/var/mobile/Library/Caches";
        field.placeholder = @"设备上的目标目录";
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"推送" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *action) {
            NSString *target = [alert.textFields.firstObject.text
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (!target.length) return;
            [self note:[NSString stringWithFormat:@"正在推送 %@ → %@", source, target]];
            [AirliftBridge.shared writeDirectory:source toTarget:target
                completion:^(NSInteger rc, NSString *error) {
                    if (error.length) [self note:error];
                    if (rc == 0) [self note:@"已推送 ✔"];
                }];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Helpers

- (void)note:(NSString *)text {
    NSLog(@"[Airlift] %@", text);
    [AirliftBridge.shared appendLog:text];
}

- (void)alert:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Search

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    _query = searchText;
    [self applyQuery];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
}

@end