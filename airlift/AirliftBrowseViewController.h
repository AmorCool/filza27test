#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Browse tab: the AirliftIndex catalog (known on-device paths), pulled Imports,
/// and push-able Staging folders. No directory enumeration is possible via the
/// AirTraffic bug, so the catalog + probing is how the device side is explored.
@interface AirliftBrowseViewController : UITableViewController
@end

NS_ASSUME_NONNULL_END