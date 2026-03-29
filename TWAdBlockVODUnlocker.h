#import <Foundation/Foundation.h>

@interface TWAdBlockVODUnlocker : NSObject
+ (instancetype)sharedInstance;
- (void)fetchVODMetadata:(NSString *)vodID completion:(void (^)(NSDictionary *metadata, NSError *error))completion;
- (NSString *)reconstructManifest:(NSDictionary *)metadata forVodID:(NSString *)vodID;
- (BOOL)isManifestRestricted:(NSData *)data;
@end
