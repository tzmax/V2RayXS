#import <Foundation/Foundation.h>
#import "helper_runtime_context.h"
#import "tun_session_controller.h"

NSDictionary* helperRuntimeUpdateBackupForActiveRoutes(HelperRuntimeContext context, NSString* state, NSString* lastError) {
    NSMutableDictionary* backup = context.loadRouteBackupBlock();
    context.updateRouteBackupStateBlock(backup, state, lastError);
    return backup;
}

void helperRuntimeSyncRuntimeSessionFromBackup(HelperRuntimeContext context) {
    syncRuntimeSessionFromBackup(context.activeTunName, context.activeIPv4TakeoverRoutes, context.loadRouteBackupBlock);
}

void helperRuntimeSyncRuntimeRouteBaselineFromBackup(HelperRuntimeContext context) {
    syncRuntimeRouteBaselineFromBackup(*context.activeTunName, context.tunWg, context.routeHelper, context.defaultRouteGatewayV4, context.defaultRouteGatewayV6, context.defaultRouteInterfaceV4, context.defaultRouteInterfaceV6, context.loadRouteBackupBlock);
}

BOOL helperRuntimeLoadDefaultRouteBaseline(HelperRuntimeContext context, NSString** errorMessage) {
    return loadDefaultRouteBaseline(context.routeHelper, *context.activeTunName, context.tunWg, context.defaultRouteGatewayV4, context.defaultRouteGatewayV6, context.defaultRouteInterfaceV4, context.defaultRouteInterfaceV6, ^{
        helperRuntimeSyncRuntimeSessionFromBackup(context);
    }, ^{
        helperRuntimeSyncRuntimeRouteBaselineFromBackup(context);
    }, ^(NSMutableDictionary* backup) {
        context.hydrateBaselineRuntimeFromBackupBlock(backup);
    }, errorMessage);
}

BOOL helperRuntimeInstallIPv4TakeoverRoutes(HelperRuntimeContext context, NSString* tunName, NSMutableDictionary* backup, NSString** errorMessage) {
    return installIPv4TakeoverRoutes(tunName, context.routeHelper, context.activeIPv4TakeoverRoutes, backup, ^(NSMutableDictionary* stateBackup, NSString* state, NSString* lastError) {
        context.updateRouteBackupStateBlock(stateBackup, state, lastError);
    }, errorMessage);
}

BOOL helperRuntimeRemoveIPv4TakeoverRoutes(HelperRuntimeContext context, NSString* tunName, NSString** errorMessage) {
    return removeIPv4TakeoverRoutes(tunName, context.routeHelper, *context.defaultRouteGatewayV4, context.activeIPv4TakeoverRoutes, context.loadRouteBackupBlock(), errorMessage);
}

void helperRuntimeResetTunRuntimeState(HelperRuntimeContext context, NSMutableDictionary* routeBackup, NSString* state, NSString* lastError) {
    resetTunRuntimeState(routeBackup, state, lastError, context.activeWhitelistRoutes, context.activeIPv4TakeoverRoutes, context.activeTunName, context.defaultRouteGatewayV4, context.defaultRouteGatewayV6, context.defaultRouteInterfaceV4, context.defaultRouteInterfaceV6, ^{
        helperRuntimeSyncRuntimeRouteBaselineFromBackup(context);
    }, ^(NSMutableDictionary* backup, NSString* nextState, NSString* nextError) {
        context.updateRouteBackupStateBlock(backup, nextState, nextError);
    });
}

NSString* helperRuntimeCurrentSessionState(HelperRuntimeContext context) {
    return tunSessionCurrentState(*context.activeTunName, context.currentSessionTypeBlock, context.currentSessionOwnerBlock, context.currentControlPlaneBlock, context.loadRouteBackupBlock);
}
