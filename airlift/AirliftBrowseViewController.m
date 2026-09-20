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
    _searchBar.placeholder = @"Search known device paths (IconState, prefs…)";
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
        case kSectionIndex:  return @"Index — known paths on the device";
        case kSectionImports: return @"Imports — files pulled off the device";
        default: return @"Staging — folders to push onto the device";
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
            message:entry.note.length ? entry.note : @"Directory on the paired device. No listing via the AirTraffic bug — enter a leaf name in Setup or pick files from the catalog."];
        return;
    }
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:entry.leafName
                         message:entry.path
                  preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Pull to Imports (extract + restore)"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [self pullEntry:entry];
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Delete on device"
        style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            [self deleteEntry:entry];
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.sourceView = self.view;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)pullEntry:(AirliftIndexEntry *)entry {
    NSString *outPath = [AirliftBridge.shared.airliftImportsPath
        stringByAppendingPathComponent:entry.leafName];
    [self note:[NSString stringWithFormat:@"Pulling %@…", entry.path]];
    [AirliftBridge.shared readFileAtDir:entry.parentDirPath leaf:entry.leafName toPath:outPath
        completion:^(NSInteger rc, NSDictionary *json, NSString *error) {
            if (error.length) [self note:error];
            if ([json[@"outputPath"] isKindOfClass:NSString.class])
                [self note:[NSString stringWithFormat:@"Pulled → %@", json[@"outputPath"]]];
            if ([json[@"restored"] boolValue]) [self note:@"Restored on device ✔"];
            [self reloadLocal];
        }];
}

- (void)deleteEntry:(AirliftIndexEntry *)entry {
    [self note:[NSString stringWithFormat:@"Deleting %@…", entry.path]];
    [AirliftBridge.shared removeFileAtDir:entry.parentDirPath leaf:entry.leafName
        completion:^(NSInteger rc, NSDictionary *json, NSString *error) {
            if (error.length) [self note:error];
            if ([json[@"removed"] boolValue]) [self note:@"Removed ✔"];
            if ([json[@"targetAbsent"] boolValue]) [self note:@"Target was already absent."];
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
                         message:[NSString stringWithFormat:@"%@ · %lld bytes", localPath, size]
                  preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Push to device…"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [self pushPromptForSourceFolder:localPath];
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Copy path"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            UIPasteboard.generalPasteboard.string = localPath;
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Delete local"
        style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            [NSFileManager.defaultManager removeItemAtPath:localPath error:NULL];
            [self reloadLocal];
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
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
    [sheet addAction:[UIAlertAction actionWithTitle:@"Push to device…"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [self pushPromptForSourceFolder:localPath];
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Delete local"
        style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            [NSFileManager.defaultManager removeItemAtPath:localPath error:NULL];
            [self reloadLocal];
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.sourceView = self.view;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)pushPromptForSourceFolder:(NSString *)source {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Push to device"
                         message:@"Target dir on the paired device"
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = @"/var/mobile/Library/Caches";
        field.placeholder = @"target dir on device";
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Push" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *action) {
            NSString *target = [alert.textFields.firstObject.text
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (!target.length) return;
            [self note:[NSString stringWithFormat:@"Pushing %@ → %@", source, target]];
            [AirliftBridge.shared writeDirectory:source toTarget:target
                completion:^(NSInteger rc, NSString *error) {
                    if (error.length) [self note:error];
                    if (rc == 0) [self note:@"Pushed ✔"];
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
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
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