#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// One row in the Airlift catalog: a known path on the paired device.
@interface AirliftIndexEntry : NSObject
@property (copy, nonatomic, readonly) NSString *path;
@property (copy, nonatomic, readonly, nullable) NSString *label;
@property (copy, nonatomic, readonly, nullable) NSString *note;
@property (copy, nonatomic, readonly) NSString *kind;  // @"file" or @"dir"
@property (nonatomic, readonly) BOOL isFile;
@property (nonatomic, readonly) BOOL isDir;
@property (copy, nonatomic, readonly) NSString *parentDirPath;
@property (copy, nonatomic, readonly) NSString *leafName;
@end

/// Catalogue of interesting /var/mobile paths, embedded as AirliftIndex.json.
///
/// The AirTraffic bug cannot enumerate directories, so this catalog (plus
/// known-name probing) is how Browse works: each cheap to enumerate pattern is
/// replaced with a direct file/dir entry we can read, probe, or delete.
@interface AirliftIndex : NSObject

+ (instancetype)shared;

/// Load from the embedded AirliftIndex.json in the app bundle.
- (BOOL)loadFromBundle;

/// Entries grouped by parent directory, sorted by path.
@property (copy, nonatomic, readonly) NSArray<AirliftIndexEntry *> *entries;

/// Sections for a UITableView: title = parent dir, rows = entries.
- (NSArray<NSString *> *)sectionTitles;
- (NSArray<AirliftIndexEntry *> *)entriesInSection:(NSString *)parentDir;

/// Case- and substring-insensitive search over paths/labels.
- (NSArray<AirliftIndexEntry *> *)search:(NSString *)query;

@end

NS_ASSUME_NONNULL_END