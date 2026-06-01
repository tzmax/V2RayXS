//
//  TLSCertSha256.h
//  V2RayX
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TLSCertSha256Endpoint : NSObject <NSCopying>

@property (nonatomic, copy) NSString* host;
@property (nonatomic) NSUInteger port;
@property (nonatomic, copy) NSString* serverName;
@property (nonatomic, copy) NSString* security;
@property (nonatomic, copy) NSString* outboundTag;

- (NSString*)cacheKey;
- (NSString*)displayAddress;

@end

@interface TLSCertSha256CacheEntry : NSObject

@property (nonatomic, copy) NSString* sha256;
@property (nonatomic, copy) NSString* errorMessage;
@property (nonatomic, strong, nullable) NSDate* fetchedAt;
@property (nonatomic, strong) TLSCertSha256Endpoint* endpoint;

- (BOOL)hasSha256;

@end

@interface TLSCertSha256 : NSObject

+ (instancetype)sharedCache;

- (TLSCertSha256CacheEntry* _Nullable)cachedEntryForEndpoint:(TLSCertSha256Endpoint*)endpoint;
- (TLSCertSha256CacheEntry*)fetchForEndpoint:(TLSCertSha256Endpoint*)endpoint refresh:(BOOL)refresh;
- (void)fetchForEndpoint:(TLSCertSha256Endpoint*)endpoint refresh:(BOOL)refresh completion:(void (^)(TLSCertSha256CacheEntry* entry))completion;
- (void)clearCacheForEndpoint:(TLSCertSha256Endpoint*)endpoint;
- (void)clearAllCache;

+ (NSString*)shortSha256:(NSString*)sha256;
+ (NSString*)placeholderForSha256:(NSString*)sha256;
+ (NSString*)statusTextForEntry:(TLSCertSha256CacheEntry*)entry;

@end

NS_ASSUME_NONNULL_END
