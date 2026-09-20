#import "AirliftIndex.h"

@implementation AirliftIndexEntry

- (instancetype)initWithPath:(NSString *)path
                       label:(NSString *)label
                        note:(NSString *)note
                        kind:(NSString *)kind {
    if ((self = [super init])) {
        _path = [path copy];
        _label = [label copy];
        _note = [note copy];
        _kind = [kind copy];
    }
    return self;
}

- (BOOL)isFile { return [self.kind isEqualToString:@"file"] || [self.kind hasSuffix:@"file"]; }
- (BOOL)isDir  { return [self.kind isEqualToString:@"dir"]; }
- (NSString *)parentDirPath { return [self.path stringByDeletingLastPathComponent]; }
- (NSString *)leafName { return self.path.lastPathComponent; }

@end

@interface AirliftIndex ()
@property (copy, nonatomic, readwrite) NSArray<AirliftIndexEntry *> *entries;
@property (copy, nonatomic) NSDictionary<NSString *, NSArray<AirliftIndexEntry *> *> *sections;
@end

@implementation AirliftIndex

+ (instancetype)shared {
    static AirliftIndex *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[AirliftIndex alloc] init];
    });
    return instance;
}

- (BOOL)loadFromBundle {
    NSString *path = [[NSBundle mainBundle] pathForResource:@"AirliftIndex" ofType:@"json"];
    if (!path) return NO;
    return [self loadFromPath:path];
}

- (BOOL)loadFromPath:(NSString *)path {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return NO;
    NSError *error = NULL;
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (![root isKindOfClass:NSDictionary.class]) return NO;

    NSArray *raw = root[@"entries"];
    if (![raw isKindOfClass:NSArray.class]) return NO;

    NSMutableArray<AirliftIndexEntry *> *built = [NSMutableArray array];
    for (id row in raw) {
        if (![row isKindOfClass:NSDictionary.class]) continue;
        NSString *path = row[@"path"];
        if (![path isKindOfClass:NSString.class] || !path.length) continue;
        NSString *label = [row[@"label"] isKindOfClass:NSString.class] ? row[@"label"] : nil;
        NSString *note = [row[@"note"] isKindOfClass:NSString.class] ? row[@"note"] : nil;
        NSString *kind = [row[@"kind"] isKindOfClass:NSString.class] ? row[@"kind"] : @"file";
        [built addObject:[[AirliftIndexEntry alloc] initWithPath:path
                                                           label:label
                                                            note:note
                                                            kind:kind]];
    }
    [built sortUsingComparator:^NSComparisonResult(AirliftIndexEntry *a, AirliftIndexEntry *b) {
        return [a.path compare:b.path options:NSLiteralSearch];
    }];
    self.entries = built;

    NSMutableDictionary<NSString *, NSMutableArray<AirliftIndexEntry *> *> *map =
        [NSMutableDictionary dictionary];
    for (AirliftIndexEntry *entry in built) {
        NSString *parent = entry.parentDirPath;
        [(map[parent] ?: (map[parent] = [NSMutableArray array])) addObject:entry];
    }
    NSMutableDictionary *ordered = [NSMutableDictionary dictionary];
    NSArray *parents = [map.allKeys sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *parent in parents) {
        ordered[parent] = [map[parent] copy];
    }
    self.sections = ordered;
    return YES;
}

- (NSArray<NSString *> *)sectionTitles {
    return self.sections.allKeys;
}

- (NSArray<AirliftIndexEntry *> *)entriesInSection:(NSString *)parentDir {
    return self.sections[parentDir] ?: @[];
}

- (NSArray<AirliftIndexEntry *> *)search:(NSString *)query {
    NSString *needle = [query stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!needle.length) return @[];
    NSString *lower = needle.lowercaseString;
    NSMutableArray *hits = [NSMutableArray array];
    for (AirliftIndexEntry *entry in self.entries) {
        NSString *hay = [NSString stringWithFormat:@"%@ %@",
            entry.path.lowercaseString, entry.label.lowercaseString ?: @""];
        if ([hay containsString:lower]) [hits addObject:entry];
    }
    return hits;
}

@end