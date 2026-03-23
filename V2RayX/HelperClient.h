#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface HelperClient : NSObject

@property (nonatomic, copy, nullable) NSString* (^helperIssueProvider)(void);
@property (nonatomic, copy, nullable) void (^failurePresenter)(NSString* message);

- (instancetype)initWithHelperPath:(NSString*)helperPath;
- (BOOL)runCommandWithArguments:(NSArray<NSString*>*)arguments action:(NSString*)action;
- (nullable NSDictionary*)runJSONCommandWithArguments:(NSArray<NSString*>*)arguments action:(NSString*)action;
- (BOOL)runHelperDaemonWithAction:(NSString*)action;
- (nullable NSDictionary*)helperDaemonStatusWithAction:(NSString*)action;
- (nullable NSDictionary*)stopHelperDaemonWithAction:(NSString*)action;
- (nullable NSDictionary*)allocateTunFDWithPreferredName:(nullable NSString*)preferredName error:(NSString* _Nullable * _Nullable)errorMessage;
- (BOOL)disableSystemProxyWithAction:(NSString*)action;
- (BOOL)restoreSystemProxyWithAction:(NSString*)action;
- (nullable NSDictionary*)startEmbeddedTunWithLocalPort:(NSInteger)localPort action:(NSString*)action;
- (nullable NSDictionary*)tunStatusWithAction:(NSString*)action;
- (nullable NSDictionary*)activateTunLeaseSynchronouslyWithLeaseId:(nullable NSString*)leaseId action:(NSString*)action;
- (nullable NSDictionary*)activateTunWithLeaseId:(nullable NSString*)leaseId action:(NSString*)action;
- (nullable NSDictionary*)deactivateTunWithLeaseId:(nullable NSString*)leaseId action:(NSString*)action;
- (nullable NSDictionary*)stopTunWithAction:(NSString*)action;
- (nullable NSDictionary*)syncRouteWhitelistAtPath:(NSString*)path action:(NSString*)action;
- (BOOL)clearRouteWhitelistWithAction:(NSString*)action;

@end

NS_ASSUME_NONNULL_END
