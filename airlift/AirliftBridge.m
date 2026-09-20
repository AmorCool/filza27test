#import "AirliftBridge.h"

#import <UIKit/UIKit.h>
#import <arpa/inet.h>
#import <errno.h>
#import <fcntl.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <sys/socket.h>
#import <sys/param.h>

#include <unistd.h>

#import "airlift.h"

NSString *const ALBridgeLogEntryNotification = @"ALBridgeLogEntryNotification";
NSString *const ALBridgePairingStateChangeNotification = @"ALBridgePairingStateChangeNotification";

static NSString *const kAltIRKDefaultsKey = @"filzaal.airliftAltIRK";
static NSString *const kPairingFileName = @"airlift_pairing.plist";
static NSString *const kDefaultTarget = @"/var/mobile/Library/SpringBoard";

/// Port RSD is advertised on inside the LocalDevVPN loopback tunnel.
static const uint16_t kRsdPort = 49152;

/// On-device default folders — the "Airlift" layout the jailbreak-free Filza
/// build lives in. Staging holds local folders to push, Imports holds pulled
/// files, Index is transport scratch space.
static NSString *const kAirliftRootRel = @"Airlift";

@interface AirliftBridge ()
@property (nonatomic, readwrite) BOOL vpnUp;
@property (copy, nonatomic, readwrite) NSString *networkDetail;
@property (nonatomic, readwrite) BOOL isPairing;
@property (nonatomic, readwrite) BOOL hasPairingFile;
@property (copy, nonatomic, readwrite, nullable) NSString *pairingPIN;
@property (copy, nonatomic, readwrite, nullable) NSString *pairedDeviceName;
@property (strong, nonatomic, nullable) NSNetService *service;
@property (strong, nonatomic, nullable) NSNetService *probeService;
@property (strong, nonatomic, readonly) NSMutableArray<NSString *> *logStorage;
@end

static void ALBridgeLogCallback(void *ctx, const char *msg);
static void ALBridgePairReady(void *ctx, const char *serviceID, uint16_t port,
                              const char *const *txtKeys, const char *const *txtVals,
                              size_t txtCount);
static void ALBridgePairPin(const char *pin, void *ctx);

@implementation AirliftBridge {
    BOOL _pairingFinished;
}

@synthesize logStorage = _logStorage;

#pragma mark - Singleton

+ (instancetype)shared {
    static AirliftBridge *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[AirliftBridge alloc] init];
    });
    return instance;
}

- (instancetype)init {
    if ((self = [super init])) {
        _logStorage = [NSMutableArray array];
        _pairingFinished = NO;
        // Install the global tracing subscriber: routes every Rust log line
        // into our sink (safe to call repeatedly; returns 1 if already set).
        al_log_init(ALBridgeLogCallback, (__bridge void *)self);
        [self refreshVPNStatus];
        [self refreshPairingFile];
    }
    return self;
}

#pragma mark - Warmup / default layout

- (void)warmup {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *root = self.airliftRootPath;
    if (![fm fileExistsAtPath:root]) {
        [fm createDirectoryAtPath:root withIntermediateDirectories:YES
                        attributes:nil error:NULL];
    }
    for (NSString *sub in @[ @"Staging", @"Imports", @"Index" ]) {
        NSString *path = [root stringByAppendingPathComponent:sub];
        if (![fm fileExistsAtPath:path]) {
            [fm createDirectoryAtPath:path withIntermediateDirectories:YES
                            attributes:nil error:NULL];
        }
    }
    [self appendLog:[NSString stringWithFormat:
        @"airlift: default layout ready under %@", root]];
}

- (NSString *)airliftRootPath {
    NSString *docs = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject
        ?: [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    return [docs stringByAppendingPathComponent:kAirliftRootRel];
}

- (NSString *)airliftStagingPath {
    return [self.airliftRootPath stringByAppendingPathComponent:@"Staging"];
}

- (NSString *)airliftImportsPath {
    return [self.airliftRootPath stringByAppendingPathComponent:@"Imports"];
}

- (NSString *)airliftIndexPath {
    return [self.airliftRootPath stringByAppendingPathComponent:@"Index"];
}

#pragma mark - Networking / LocalDevVPN

- (BOOL)canConnectToHost:(NSString *)host port:(uint16_t)port {
    struct in_addr addr;
    if (inet_pton(AF_INET, host.UTF8String, &addr) != 1) return NO;

    int fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (fd < 0) return NO;

    struct sockaddr_in remote;
    memset(&remote, 0, sizeof(remote));
    remote.sin_len = sizeof(remote);
    remote.sin_family = AF_INET;
    remote.sin_port = htons(port);
    remote.sin_addr = addr;

    [self setNonBlocking:fd];
    int connected = connect(fd, (struct sockaddr *)&remote, sizeof(remote));
    if (connected != 0 && errno != EINPROGRESS) {
        close(fd);
        return NO;
    }

    fd_set set;
    FD_ZERO(&set);
    FD_SET(fd, &set);
    struct timeval tv = { .tv_sec = 0, .tv_usec = 300000 }; // 300ms
    int ready = select(fd + 1, NULL, &set, NULL, &tv);
    int success = 0;
    if (ready > 0) {
        int soError = 0;
        socklen_t soLen = sizeof(soError);
        if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &soLen) == 0 && soError == 0)
            success = 1;
    }
    close(fd);
    return success != 0;
}

- (void)setNonBlocking:(int)fd {
    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

- (BOOL)refreshVPNStatus {
    __block BOOL tunnelUp = NO;
    __block NSString *detail = @"";

    struct ifaddrs *addrs = NULL;
    if (getifaddrs(&addrs) == 0) {
        NSMutableArray *seen = [NSMutableArray array];
        for (struct ifaddrs *cur = addrs; cur; cur = cur->ifa_next) {
            if (!cur->ifa_name) continue;
            NSString *name = [NSString stringWithUTF8String:cur->ifa_name];
            if (name.length) [seen addObject:name];
            if ([name hasPrefix:@"utun"] || [name hasPrefix:@"ipsec"] ||
                [name hasPrefix:@"tap"] || [name hasPrefix:@"ppp"])
                tunnelUp = YES;
        }
        freeifaddrs(addrs);
        detail = [seen componentsJoinedByString:@", "];
    }

    NSArray *loopbackTargets = @[ @"10.7.0.1", @"10.7.0.2", @"127.0.0.1" ];
    for (NSString *host in loopbackTargets) {
        if ([self canConnectToHost:host port:kRsdPort]) {
            tunnelUp = YES;
            detail = [detail length]
                ? [NSString stringWithFormat:@"%@ · %@:%u reachable", detail, host, kRsdPort]
                : [NSString stringWithFormat:@"%@:%u reachable", host, kRsdPort];
            break;
        }
    }

    self.vpnUp = tunnelUp;
    self.networkDetail = detail;
    return tunnelUp;
}

#pragma mark - Pairing file

- (NSString *)pairingFilePath {
    NSString *docs = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject
        ?: [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    return [docs stringByAppendingPathComponent:kPairingFileName];
}

- (BOOL)refreshPairingFile {
    NSString *path = self.pairingFilePath;
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:NULL];
    BOOL exists = (attrs != nil) && (((NSNumber *)attrs[NSFileSize]).longLongValue > 0);
    if (!exists) {
        // Adopt a pairing file the user dropped into Filza's Documents
        // (mirrors AirCard: scan for any CandidateHost device's plist).
        NSString *found = [self adoptFirstPairingCandidate];
        if (found) {
            [self appendLog:[NSString stringWithFormat:
                @"airlift: adopted pairing file from %@", found]];
            attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:NULL];
            exists = (attrs != nil) && (((NSNumber *)attrs[NSFileSize]).longLongValue > 0);
        }
    }
    self.hasPairingFile = exists;
    return exists;
}

- (NSString *)adoptFirstPairingCandidate {
    NSArray<NSString *> *skanTypes = @[ @"plist", @"mobiledevicepairing", @"mobilepair",
                                        @"mobiledevicepair" ];
    NSString *skip = self.pairingFilePath.lastPathComponent;
    NSArray *docs = [NSFileManager.defaultManager
        contentsOfDirectoryAtPath:[self.pairingFilePath stringByDeletingLastPathComponent]
                            error:NULL];
    for (NSString *file in docs) {
        if ([file hasPrefix:@"."] || [file isEqualToString:skip]) continue;
        NSString *ext = file.pathExtension.lowercaseString;
        if (![skanTypes containsObject:ext]) continue;
        NSString *src = [[self.pairingFilePath stringByDeletingLastPathComponent]
            stringByAppendingPathComponent:file];
        NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:src error:NULL];
        if (!attrs || ((NSNumber *)attrs[NSFileSize]).longLongValue <= 0) continue;
        NSError *error = NULL;
        if ([[NSFileManager defaultManager] copyItemAtPath:src toPath:self.pairingFilePath
                                                    error:&error]) {
            return src;
        }
    }
    return nil;
}

- (BOOL)importPairingFileAtPath:(NSString *)sourcePath errorOut:(NSError **)errorOut {
    if (!sourcePath.length) {
        if (errorOut) *errorOut = [NSError errorWithDomain:@"airlift" code:1
                            userInfo:@{NSLocalizedDescriptionKey: @"No path given."}];
        return NO;
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    NSDictionary *attrs = [fm attributesOfItemAtPath:sourcePath error:NULL];
    if (!attrs) {
        if (errorOut) *errorOut = [NSError errorWithDomain:@"airlift" code:2
                            userInfo:@{NSLocalizedDescriptionKey:
                                [NSString stringWithFormat:@"%@ not readable.", sourcePath]}];
        return NO;
    }
    NSError *copyError = NULL;
    if (![fm copyItemAtPath:sourcePath toPath:self.pairingFilePath error:&copyError]) {
        // Path may sit on another volume / read-only; fall back to reading
        // and writing the bytes.
        NSData *data = [NSData dataWithContentsOfFile:sourcePath options:0 error:&copyError];
        if (!data || data.length == 0) {
            if (errorOut) *errorOut = copyError ?: [NSError errorWithDomain:@"airlift" code:3
                                userInfo:@{NSLocalizedDescriptionKey: @"Import failed."}];
            return NO;
        }
        if (![data writeToFile:self.pairingFilePath atomically:YES]) {
            if (errorOut) *errorOut = [NSError errorWithDomain:@"airlift" code:4
                                userInfo:@{NSLocalizedDescriptionKey: @"Write failed."}];
            return NO;
        }
    }
    [self appendLog:[NSString stringWithFormat:
        @"airlift: imported pairing file %@ → %@", sourcePath, self.pairingFilePath]];
    return [self refreshPairingFile];
}

#pragma mark - Local Network permission

- (void)requestLocalNetworkAccess {
    [self.probeService stop];
    self.probeService = nil;

    NSString *probeType = @"_filzaairliftprobe._tcp.";
    NSNetService *probe = [[NSNetService alloc]
        initWithDomain:@"" type:probeType name:@"FilzaAirliftProbe" port:0];
    self.probeService = probe;
    [self appendLog:@"airlift: requesting Local Network access (allow the prompt)…"];

    // A short-lived throwaway advertisement triggers the iOS "Local Network"
    // authorization dialog, just like AirCard's NWListener probe. Without this
    // the actual RPPairing host may be silently blocked from advertising.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [probe stop];
        if (self.probeService == probe) self.probeService = nil;
    });
    [probe publish];
}

#pragma mark - Logging

- (void)appendLog:(NSString *)line {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_logStorage addObject:line];
        if (self->_logStorage.count > 800) {
            [self->_logStorage removeObjectsInRange:NSMakeRange(0, self->_logStorage.count - 800)];
        }
        [NSNotificationCenter.defaultCenter postNotificationName:ALBridgeLogEntryNotification
                                                          object:line];
    });
}

- (NSArray<NSString *> *)logLines {
    return [self->_logStorage copy];
}

- (void)clearLog {
    [self->_logStorage removeAllObjects];
}

- (NSString *)alString:(char *)ptr {
    if (!ptr) return @"";
    NSString *s = [NSString stringWithUTF8String:ptr] ?: @"";
    return s;
}

- (NSDictionary *)reportFromJson:(NSString *)jsonText fallback:(NSDictionary *)fallback {
    if (jsonText.length) {
        NSData *data = [jsonText dataUsingEncoding:NSUTF8StringEncoding];
        if (data) {
            NSError *error = NULL;
            id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
            if (parsed && [parsed isKindOfClass:NSDictionary.class]) return parsed;
        }
    }
    return fallback;
}

#pragma mark - Pairing

- (void)startPairing {
    if (self.isPairing) return;
    [self appendLog:@"airlift: starting RPPairing host on 0.0.0.0…"];
    self.isPairing = YES;
    self.pairingPIN = nil;
    self.pairedDeviceName = nil;
    _pairingFinished = NO;

    NSString *bind = @"0.0.0.0";
    NSString *name = @"FilzaAirlift";
    NSString *model = @"Mac17,7";
    NSString *outPath = self.pairingFilePath;
    NSString *altIRK = [NSUserDefaults.standardUserDefaults stringForKey:kAltIRKDefaultsKey] ?: @"";
    AirliftBridge *bridge = self;

    // Apple's RPPairing host must advertise through Bonjour; iOS 14+ requires
    // a granted Local Network permission. Trigger it before binding so the
    // host becomes visible in Settings → Developer Mode on the first try.
    [self requestLocalNetworkAccess];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        ALPairResult result;
        memset(&result, 0, sizeof(result));

        int32_t rc = bind.UTF8String
            ? al_pairing_run_host(bind.UTF8String, 0, name.UTF8String, model.UTF8String,
                                  outPath.UTF8String, altIRK.UTF8String,
                                  ALBridgePairReady, ALBridgePairPin,
                                  (__bridge void *)bridge, &result)
            : 1;

        // Copy strings out on this thread; al_pairing_result_free runs now, before
        // the main-queue block below could dereference them.
        NSString *irk = [bridge alString:result.host_alt_irk_hex];
        NSString *device = [bridge alString:result.device_name];
        NSString *error = [bridge alString:result.error];
        BOOL success = (rc == 0);

        al_pairing_result_free(&result);

        dispatch_async(dispatch_get_main_queue(), ^{
            [bridge pairingHostFinishedWithCode:success
                                         altIRK:irk
                                     deviceName:device
                                          error:error];
        });
    });
}

- (void)pairingHostFinishedWithCode:(BOOL)success
                             altIRK:(NSString *)irk
                         deviceName:(NSString *)device
                              error:(NSString *)error {
    if (_pairingFinished) {
        // A stopPairing() already superseded this run.
        return;
    }
    _pairingFinished = YES;
    self.isPairing = NO;
    self.pairingPIN = nil;

    if (success) {
        if (irk.length) {
            [NSUserDefaults.standardUserDefaults setObject:irk forKey:kAltIRKDefaultsKey];
        }
        self.pairedDeviceName = device.length ? device : @"iPhone";
        [self refreshPairingFile];
        [self appendLog:[NSString stringWithFormat:
            @"airlift: paired with %@ ✅", self.pairedDeviceName]];
    } else {
        [self appendLog:[NSString stringWithFormat:
            @"airlift: pairing failed: %@", error.length ? error : @"(rc != 0)"]];
    }
    [NSNotificationCenter.defaultCenter
        postNotificationName:ALBridgePairingStateChangeNotification object:nil];
}

- (void)stopPairing {
    [self stopAdvertising];
    if (self.isPairing) {
        _pairingFinished = YES;
        self.isPairing = NO;
        self.pairingPIN = nil;
        [self appendLog:@"airlift: pairing cancelled"];
        [NSNotificationCenter.defaultCenter
            postNotificationName:ALBridgePairingStateChangeNotification object:nil];
    }
}

- (void)startAdvertising:(NSString *)serviceID port:(uint16_t)port txt:(NSDictionary *)txt {
    [self stopAdvertising];
    NSNetService *service = [[NSNetService alloc]
        initWithDomain:@"" type:@"_remotepairing-pairable-host._tcp."
                  name:serviceID port:(int)port];
    // Build the TXT record bytes by hand: the classic setTXTRecord: API was
    // removed from the iOS 17 SDK and setTXTRecordData: is deprecated but kept.
    NSMutableData *txtData = [NSMutableData data];
    [txt enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSData *value, BOOL *stop) {
        NSMutableData *entry = [[key dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
        [entry appendBytes:"=" length:1];
        [entry appendData:value];
        uint8_t len = (uint8_t)MIN(entry.length, 255u);
        [txtData appendBytes:&len length:1];
        [txtData appendData:entry];
    }];
    [service setTXTRecordData:txtData];
    [service publish];
    self.service = service;
    [self appendLog:
        @"airlift: advertising — pair under Settings › Privacy & Security › Developer Mode"];
}

- (void)stopAdvertising {
    [self.service stop];
    self.service = nil;
}

#pragma mark - Airlift exploit

- (NSString *)_pairingGuard {
    return self.hasPairingFile ? self.pairingFilePath : nil;
}

- (NSInteger)canaryWriteAtTarget:(NSString *)target
                      completion:(void (^)(NSInteger rc, NSDictionary *_Nullable json,
                                           NSString *_Nullable error))completion {
    NSString *path = self.pairingFilePath;
    if (!self.hasPairingFile) {
        if (completion) completion(-1, nil, @"No pairing file. Pair this iPhone first.");
        return -1;
    }
    NSString *tgt = target.length ? target : kDefaultTarget;
    AirliftBridge *bridge = self;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        char *outError = NULL;
        char *outJson = NULL;
        int32_t rc = al_exploit_run(path.UTF8String, tgt.UTF8String,
                                    ALBridgeLogCallback, (__bridge void *)bridge,
                                    &outJson, &outError);
        NSString *errorText = outError ? [NSString stringWithUTF8String:outError] : nil;
        NSString *jsonText = outJson ? [NSString stringWithUTF8String:outJson] : nil;
        NSDictionary *report = [bridge reportFromJson:jsonText
                                             fallback:jsonText
                                               ? @{ @"output": jsonText }
                                               : (errorText ? @{ @"error": errorText } : @{})];
        if (outError) al_string_free(outError);
        if (outJson) al_string_free(outJson);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(rc, report, errorText);
        });
    });
    return 0;
}

- (NSInteger)writeDirectory:(NSString *)sourceDir
                   toTarget:(NSString *)targetDir
                 completion:(void (^)(NSInteger rc, NSString *_Nullable error))completion {
    NSString *path = self.pairingFilePath;
    if (!self.hasPairingFile) {
        if (completion) completion(-1, @"No pairing file. Pair this iPhone first.");
        return -1;
    }
    if (!sourceDir.length || !targetDir.length) {
        if (completion) completion(-1, @"Both source and target must be set.");
        return -1;
    }
    AirliftBridge *bridge = self;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        char *outError = NULL;
        int32_t rc = al_exploit_write_dir(path.UTF8String, sourceDir.UTF8String,
                                          targetDir.UTF8String,
                                          ALBridgeLogCallback, (__bridge void *)bridge,
                                          &outError);
        NSString *errorText = outError ? [NSString stringWithUTF8String:outError] : nil;
        if (outError) al_string_free(outError);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(rc, errorText);
        });
    });
    return 0;
}

- (NSInteger)readFileAtDir:(NSString *)dir
                      leaf:(NSString *)leaf
                    toPath:(NSString *)outPath
                completion:(void (^)(NSInteger rc, NSDictionary *_Nullable json,
                                     NSString *_Nullable error))completion {
    NSString *path = [self _pairingGuard];
    if (!path) {
        if (completion) completion(-1, nil, @"No pairing file. Pair this iPhone first.");
        return -1;
    }
    if (!dir.length || !leaf.length || !outPath.length) {
        if (completion) completion(-1, nil, @"dir, leaf and output path must all be set.");
        return -1;
    }
    AirliftBridge *bridge = self;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        char *outError = NULL;
        char *outJson = NULL;
        int32_t rc = al_exploit_read_file(path.UTF8String, dir.UTF8String, leaf.UTF8String,
                                          outPath.UTF8String,
                                          ALBridgeLogCallback, (__bridge void *)bridge,
                                          &outJson, &outError);
        NSString *errorText = outError ? [NSString stringWithUTF8String:outError] : nil;
        NSString *jsonText = outJson ? [NSString stringWithUTF8String:outJson] : nil;
        NSDictionary *report = [bridge reportFromJson:jsonText
                                             fallback:jsonText
                                               ? @{ @"output": jsonText }
                                               : (errorText ? @{ @"error": errorText } : @{})];
        if (outError) al_string_free(outError);
        if (outJson) al_string_free(outJson);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(rc, report, errorText);
        });
    });
    return 0;
}

- (NSInteger)removeFileAtDir:(NSString *)dir
                        leaf:(NSString *)leaf
                  completion:(void (^)(NSInteger rc, NSDictionary *_Nullable json,
                                       NSString *_Nullable error))completion {
    NSString *path = [self _pairingGuard];
    if (!path) {
        if (completion) completion(-1, nil, @"No pairing file. Pair this iPhone first.");
        return -1;
    }
    if (!dir.length || !leaf.length) {
        if (completion) completion(-1, nil, @"dir and leaf must be set.");
        return -1;
    }
    AirliftBridge *bridge = self;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        char *outError = NULL;
        char *outJson = NULL;
        int32_t rc = al_exploit_remove(path.UTF8String, dir.UTF8String, leaf.UTF8String,
                                       ALBridgeLogCallback, (__bridge void *)bridge,
                                       &outJson, &outError);
        NSString *errorText = outError ? [NSString stringWithUTF8String:outError] : nil;
        NSString *jsonText = outJson ? [NSString stringWithUTF8String:outJson] : nil;
        NSDictionary *report = [bridge reportFromJson:jsonText
                                             fallback:jsonText
                                               ? @{ @"output": jsonText }
                                               : (errorText ? @{ @"error": errorText } : @{})];
        if (outError) al_string_free(outError);
        if (outJson) al_string_free(outJson);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(rc, report, errorText);
        });
    });
    return 0;
}

@end

#pragma mark - C callbacks

static void ALBridgeLogCallback(void *ctx, const char *msg) {
    if (!msg) return;
    @autoreleasepool {
        AirliftBridge *bridge = (__bridge AirliftBridge *)ctx;
        NSString *line = [NSString stringWithUTF8String:msg];
        if (line.length) [bridge appendLog:line];
    }
}

static void ALBridgePairReady(void *ctx, const char *serviceID, uint16_t port,
                              const char *const *txtKeys, const char *const *txtVals,
                              size_t txtCount) {
    if (!ctx || !serviceID) return;
    @autoreleasepool {
        AirliftBridge *bridge = (__bridge AirliftBridge *)ctx;
        NSString *service = [NSString stringWithUTF8String:serviceID];
        NSMutableDictionary *txt = [NSMutableDictionary dictionary];
        if (txtKeys && txtVals) {
            for (size_t i = 0; i < txtCount; i++) {
                if (!txtKeys[i] || !txtVals[i]) continue;
                NSString *key = [NSString stringWithUTF8String:txtKeys[i]];
                NSString *val = [NSString stringWithUTF8String:txtVals[i]];
                if (key.length) txt[key] = [val dataUsingEncoding:NSUTF8StringEncoding];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [bridge startAdvertising:service port:port txt:txt];
        });
    }
}

static void ALBridgePairPin(const char *pin, void *ctx) {
    if (!ctx || !pin) return;
    @autoreleasepool {
        AirliftBridge *bridge = (__bridge AirliftBridge *)ctx;
        NSString *pinString = [NSString stringWithUTF8String:pin];
        dispatch_async(dispatch_get_main_queue(), ^{
            bridge.pairingPIN = pinString;
            [NSNotificationCenter.defaultCenter
                postNotificationName:ALBridgePairingStateChangeNotification object:nil];
        });
    }
}