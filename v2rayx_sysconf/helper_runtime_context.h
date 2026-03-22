#ifndef helper_runtime_context_h
#define helper_runtime_context_h

#import <Foundation/Foundation.h>
#import "route_helper.h"

typedef struct {
    SYSRouteHelper* routeHelper;
    NSString* tunWg;
    NSString* __strong *activeTunName;
    NSString* __strong *defaultRouteGatewayV4;
    NSString* __strong *defaultRouteGatewayV6;
    NSString* __strong *defaultRouteInterfaceV4;
    NSString* __strong *defaultRouteInterfaceV6;
    NSMutableDictionary<NSString*, NSDictionary*>* activeWhitelistRoutes;
    NSMutableArray<NSDictionary*>* __strong *activeIPv4TakeoverRoutes;
    NSMutableDictionary* (^loadRouteBackupBlock)(void);
    void (^hydrateBaselineRuntimeFromBackupBlock)(NSMutableDictionary* backup);
    void (^updateRouteBackupStateBlock)(NSMutableDictionary* backup, NSString* state, NSString* lastError);
    NSString* (^currentSessionTypeBlock)(void);
    NSString* (^currentSessionOwnerBlock)(void);
    NSString* (^currentControlPlaneBlock)(void);
} HelperRuntimeContext;

NSDictionary* helperRuntimeUpdateBackupForActiveRoutes(HelperRuntimeContext context, NSString* state, NSString* lastError);
void helperRuntimeSyncRuntimeSessionFromBackup(HelperRuntimeContext context);
void helperRuntimeSyncRuntimeRouteBaselineFromBackup(HelperRuntimeContext context);
BOOL helperRuntimeLoadDefaultRouteBaseline(HelperRuntimeContext context, NSString** errorMessage);
BOOL helperRuntimeInstallIPv4TakeoverRoutes(HelperRuntimeContext context, NSString* tunName, NSMutableDictionary* backup, NSString** errorMessage);
BOOL helperRuntimeRemoveIPv4TakeoverRoutes(HelperRuntimeContext context, NSString* tunName, NSString** errorMessage);
void helperRuntimeResetTunRuntimeState(HelperRuntimeContext context, NSMutableDictionary* routeBackup, NSString* state, NSString* lastError);
NSString* helperRuntimeCurrentSessionState(HelperRuntimeContext context);

#endif /* helper_runtime_context_h */
