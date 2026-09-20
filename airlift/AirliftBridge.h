#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const ALBridgeLogEntryNotification;            // object = (NSString *)
extern NSString *const ALBridgePairingStateChangeNotification;  // none

/// Objective-C bridge over the Airlift (airlift_ffi) Rust core: RPPairing host,
/// LocalDevVPN loopback detection, and the AirTraffic filesystem escape with
/// full parity — write (inject), read (extract + restore), and delete.
///
/// Filza Airlift default layout (created on first launch):
///   Documents/Airlift/Staging   — local folder(s) pushed onto the device
///   Documents/Airlift/Imports   — files pulled off the device
///   Documents/Airlift/Index     — scratch space used by the transport
@interface AirliftBridge : NSObject

+ (instancetype)shared;

/// Idempotent startup: installs the Rust log subscriber, refreshes status, and
/// creates the default Airlift folder layout. Called from the tweak constructor.
- (void)warmup;

/// Documents/Airlift default layout helpers.
@property (nonatomic, readonly) NSString *airliftRootPath;
@property (nonatomic, readonly) NSString *airliftStagingPath;
@property (nonatomic, readonly) NSString *airliftImportsPath;
@property (nonatomic, readonly) NSString *airliftIndexPath;

/// LocalDevVPN / loopback status.
@property (nonatomic, readonly) BOOL vpnUp;
@property (copy, nonatomic, readonly) NSString *networkDetail;
- (BOOL)refreshVPNStatus;

/// Pairing.
@property (nonatomic, readonly) BOOL isPairing;
@property (nonatomic, readonly) BOOL hasPairingFile;
@property (copy, nonatomic, readonly, nullable) NSString *pairingPIN;
@property (copy, nonatomic, readonly, nullable) NSString *pairedDeviceName;
@property (copy, nonatomic, readonly) NSString *pairingFilePath;
- (BOOL)refreshPairingFile;
/// Present the iOS Local Network prompt so the pairing host can actually
/// advertise over Bonjour (iOS 14+ blocks advertising without this access).
- (void)requestLocalNetworkAccess;
/// Copy a pairing file from an arbitrary path into the canonical Documents
/// location so the Airlift core can use it.
- (BOOL)importPairingFileAtPath:(NSString *)sourcePath errorOut:(NSError **)errorOut;
- (void)startPairing;
- (void)stopPairing;

/// Airlift exploit (all async; completions on the main queue).
- (NSInteger)canaryWriteAtTarget:(NSString *)target
                      completion:(void (^)(NSInteger rc, NSDictionary *_Nullable json,
                                           NSString *_Nullable error))completion;
- (NSInteger)writeDirectory:(NSString *)sourceDir
                   toTarget:(NSString *)targetDir
                 completion:(void (^)(NSInteger rc, NSString *_Nullable error))completion;
- (NSInteger)readFileAtDir:(NSString *)dir
                      leaf:(NSString *)leaf
                    toPath:(NSString *)outPath
                completion:(void (^)(NSInteger rc, NSDictionary *_Nullable json,
                                     NSString *_Nullable error))completion;
- (NSInteger)removeFileAtDir:(NSString *)dir
                        leaf:(NSString *)leaf
                  completion:(void (^)(NSInteger rc, NSDictionary *_Nullable json,
                                       NSString *_Nullable error))completion;

/// Log sink used by the Rust core.
@property (copy, nonatomic, readonly) NSArray<NSString *> *logLines;
- (void)clearLog;
- (void)appendLog:(NSString *)line;

@end

NS_ASSUME_NONNULL_END