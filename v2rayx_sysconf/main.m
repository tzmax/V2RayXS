//
//  main.m
//  v2rayx_sysconf
//
//  Copyright © 2016年 Cenmrev. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <arpa/inet.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/un.h>
#import <sys/signal.h>
#import <unistd.h>
#import <netdb.h>
#import <Tun2socks/Tun2socks.h>
#import "sysconf_version.h"
#import "route_helper.h"
#import "tun_device.h"
#import "helper_paths.h"
#import "proxy_manager.h"
#import "active_route_reconciler.h"
#import "daemon_service.h"
#import "daemon_rpc.h"
#import "daemon_state.h"
#import "helper_runtime_context.h"
#import "route_command_service.h"
#import "route_entry_normalizer.h"
#import "session_backup_store.h"
#import "session_state.h"
#import "tun_command_service.h"
#import "tun_session_controller.h"
#import "route_whitelist_store.h"
#import "control_socket_transport.h"
#import "tun_device.h"
#import <stdarg.h>

#define INFO "v2rayx_sysconf\nusage:\n  v2rayx_sysconf -v\n  v2rayx_sysconf off [--debug]\n  v2rayx_sysconf auto [--debug]\n  v2rayx_sysconf global <socksPort> <httpPort> [--debug]\n  v2rayx_sysconf save [--debug]\n  v2rayx_sysconf restore [--debug]\n  v2rayx_sysconf daemon run [--debug]\n  v2rayx_sysconf daemon status [--json] [--debug]\n  v2rayx_sysconf daemon stop [--json] [--debug]\n  v2rayx_sysconf tun start <socksPort> [--json] [--debug]\n  v2rayx_sysconf tun allocate [<utunName>] [--json] [--debug]\n  v2rayx_sysconf tun activate [<leaseId>] [--json] [--debug]\n  v2rayx_sysconf tun deactivate [--json] [--debug]\n  v2rayx_sysconf tun stop [--json] [--debug]\n  v2rayx_sysconf tun status [--json] [--debug]\n  v2rayx_sysconf tun cleanup [--json] [--debug]\n  v2rayx_sysconf route add <ip...> [--json] [--require-active] [--debug]\n  v2rayx_sysconf route del <ip...> [--json] [--require-active] [--debug]\n  v2rayx_sysconf route list [--json] [--debug]\n  v2rayx_sysconf route clear [--json] [--require-active] [--debug]\n  v2rayx_sysconf route apply [--json] [--debug]\n  v2rayx_sysconf route sync-file <path> [--json] [--require-active] [--debug]\n"

static NSArray<NSString*>* const IPv4TakeoverCIDRs = @[@"0.0.0.0/1", @"128.0.0.0/1"];

static NSInteger const EXIT_USAGE = 1;
static NSInteger const EXIT_REQUIRE_ACTIVE = 2;
static NSInteger const EXIT_SOCKET = 3;
static NSInteger const EXIT_ROUTE = 4;
static NSInteger const EXIT_TUN_FD = 5;

static BOOL runLoopMark = YES;
static BOOL debugLoggingEnabled = NO;
static NSString* runtimeMode = @"";
static SYSRouteHelper* routeHelper;
static NSString* tunAddr = @"10.0.0.0";
static NSString* tunWg = @"10.0.0.1";
static NSString* tunMask = @"255.255.255.0";
static NSString* tunDns = @"8.8.8.8,8.8.4.4,1.1.1.1";
static NSString* defaultRouteGatewayV4 = @"";
static NSString* defaultRouteGatewayV6 = @"";
static NSString* defaultRouteInterfaceV4 = @"";
static NSString* defaultRouteInterfaceV6 = @"";
static int controlServerSocketFD = -1;
static int tunSessionLockFD = -1;
static NSString* activeTunName = @"";
static NSMutableDictionary<NSString*, NSDictionary*>* activeWhitelistRoutes;
static NSMutableArray<NSDictionary*>* activeIPv4TakeoverRoutes;
static Tun2socksTun2socksCtl* tunControl = nil;
static HelperRuntimeContext runtimeContext;

static BOOL acquireTunSessionLock(NSString** errorMessage);
static void releaseTunSessionLock(void);
static NSDictionary* makeResponse(BOOL ok, NSString* message, NSDictionary* payload);
static void printResponse(NSDictionary* response, BOOL asJSON);
static BOOL shouldOutputJSON(NSArray<NSString*>* arguments);
static BOOL shouldEnableDebugLogging(NSArray<NSString*>* arguments);
static NSDictionary* runTool(NSString* launchPath, NSArray<NSString*>* arguments);
static NSDictionary* runtimeSessionStatusPayload(void);
static NSDictionary* routeListPayload(void);
static NSDictionary* requestActiveSession(NSDictionary* request);
static NSDictionary* stopTunSession(void);
static BOOL setupTunSession(int localProxyPort, NSString** errorMessage);
static BOOL activateAllocatedTunLease(NSString* tunName, NSString** errorMessage);
static NSDictionary* processServerRequest(NSDictionary* request, int* responseFDOut);
static void updateRouteBackupState(NSMutableDictionary* backup, NSString* state, NSString* lastError);
static void updateRouteBackupRoutes(NSMutableDictionary* backup);
static NSDictionary* handleTunCommand(NSArray<NSString*>* arguments);
static NSDictionary* handleRouteCommand(NSArray<NSString*>* arguments);
static NSDictionary* handleDaemonCommand(NSArray<NSString*>* arguments);
static void cleanupHandle(int signal_ns);

static BOOL acquireTunSessionLock(NSString** errorMessage) {
    if (tunSessionLockFD != -1) {
        return YES;
    }
    helperEnsureAppSupportDirectory();
    NSString* lockPath = helperTunSessionLockPath();
    const char* lockPathFS = [lockPath fileSystemRepresentation];
    for (NSInteger attempt = 0; attempt < 2; attempt++) {
        int fd = open(lockPathFS, O_CREAT | O_EXCL | O_RDWR, 0600);
        if (fd != -1) {
            NSString* pidString = [NSString stringWithFormat:@"%d\n", getpid()];
            write(fd, [pidString UTF8String], (unsigned int)[pidString lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
            tunSessionLockFD = fd;
            return YES;
        }
        if (errno != EEXIST) {
            if (errorMessage != NULL) {
                *errorMessage = @"Failed to create tun session lock file.";
            }
            return NO;
        }

        NSData* existingData = [NSData dataWithContentsOfFile:lockPath];
        NSString* existingText = existingData != nil ? [[NSString alloc] initWithData:existingData encoding:NSUTF8StringEncoding] : nil;
        pid_t existingPID = (pid_t)[existingText integerValue];
        if (existingPID > 0 && kill(existingPID, 0) == 0) {
            if (errorMessage != NULL) {
                *errorMessage = [NSString stringWithFormat:@"Another tun session is already running (pid %d).", existingPID];
            }
            return NO;
        }

        unlink(lockPathFS);
    }
    if (errorMessage != NULL) {
        *errorMessage = @"Another tun session operation is already in progress.";
    }
    return NO;
}

static void releaseTunSessionLock(void) {
    if (tunSessionLockFD == -1) {
        return;
    }
    NSString* lockPath = helperTunSessionLockPath();
    unlink([lockPath fileSystemRepresentation]);
    close(tunSessionLockFD);
    tunSessionLockFD = -1;
}

static NSDictionary* makeResponse(BOOL ok, NSString* message, NSDictionary* payload) {
    NSMutableDictionary* response = [[NSMutableDictionary alloc] init];
    response[@"ok"] = @(ok);
    response[@"message"] = message ?: @"";
    if (payload != nil) {
        [response addEntriesFromDictionary:payload];
    }
    return response;
}

static void printResponse(NSDictionary* response, BOOL asJSON) {
    if (asJSON) {
        NSData* data = [NSJSONSerialization dataWithJSONObject:response options:NSJSONWritingPrettyPrinted error:nil];
        NSString* text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"{}";
        printf("%s\n", [text UTF8String]);
        return;
    }
    NSString* message = response[@"message"] ?: @"";
    if (message.length > 0) {
        printf("%s\n", [message UTF8String]);
    }
}

static BOOL shouldOutputJSON(NSArray<NSString*>* arguments) {
    return [arguments containsObject:@"--json"];
}

static BOOL shouldEnableDebugLogging(NSArray<NSString*>* arguments) {
    return [arguments containsObject:@"--debug"];
}

static NSDictionary* runTool(NSString* launchPath, NSArray<NSString*>* arguments) {
    NSTask* task = [[NSTask alloc] init];
    task.launchPath = launchPath;
    task.arguments = arguments;
    NSPipe* stdoutPipe = [NSPipe pipe];
    NSPipe* stderrPipe = [NSPipe pipe];
    task.standardOutput = stdoutPipe;
    task.standardError = stderrPipe;
    [task launch];
    [task waitUntilExit];
    NSData* stdoutData = [[stdoutPipe fileHandleForReading] readDataToEndOfFile];
    NSData* stderrData = [[stderrPipe fileHandleForReading] readDataToEndOfFile];
    return @{
        @"status": @(task.terminationStatus),
        @"stdout": [[NSString alloc] initWithData:stdoutData encoding:NSUTF8StringEncoding] ?: @"",
        @"stderr": [[NSString alloc] initWithData:stderrData encoding:NSUTF8StringEncoding] ?: @"",
    };
}

static NSDictionary* updateBackupForActiveRoutes(NSString* state, NSString* lastError) {
    return helperRuntimeUpdateBackupForActiveRoutes(runtimeContext, state, lastError);
}

static BOOL loadDefaultRouteBaselineBridge(NSString** errorMessage) {
    return helperRuntimeLoadDefaultRouteBaseline(runtimeContext, errorMessage);
}

static BOOL installIPv4TakeoverRoutesBridge(NSString* tunName, NSMutableDictionary* backup, NSString** errorMessage) {
    return helperRuntimeInstallIPv4TakeoverRoutes(runtimeContext, tunName, backup, errorMessage);
}

static BOOL removeIPv4TakeoverRoutesBridge(NSString* tunName, NSString** errorMessage) {
    return helperRuntimeRemoveIPv4TakeoverRoutes(runtimeContext, tunName, errorMessage);
}

static void resetTunRuntimeStateBridge(NSMutableDictionary* routeBackup, NSString* state, NSString* lastError) {
    helperRuntimeResetTunRuntimeState(runtimeContext, routeBackup, state, lastError);
}

static NSDictionary* cliDiagnosticStatusPayload(void);

static NSDictionary* buildDaemonStatusResponsePayload(NSDictionary* runtimeStatus) {
    NSDictionary* status = [runtimeStatus isKindOfClass:[NSDictionary class]] ? runtimeStatus : runtimeSessionStatusPayload();
    return @{
        @"daemon": isControlSocketReachable() ? @"available" : @"unavailable",
        @"session": status[@"session"] ?: daemonStateSessionStatus(),
        @"dataPlaneKind": status[@"sessionType"] ?: daemonStateDataPlaneKind(),
        @"tunName": status[@"tunName"] ?: daemonStateTunName(),
        @"leaseId": status[@"leaseId"] ?: daemonStateLeaseIdentifier(),
        @"socksPort": daemonStateSocksPort(),
        @"status": status,
    };
}

static NSDictionary* buildTunStatusResponsePayload(NSDictionary* runtimeStatus) {
    NSDictionary* status = [runtimeStatus isKindOfClass:[NSDictionary class]] ? runtimeStatus : runtimeSessionStatusPayload();
    return makeResponse(YES, @"Tun session status.", status);
}

static NSDictionary* buildTunDiagnosticStatusResponse(void) {
    return makeResponse(YES, @"Tun session status.", cliDiagnosticStatusPayload());
}

static NSDictionary* daemonEnvelopeStatusPayload(void) {
    return buildDaemonStatusResponsePayload(runtimeSessionStatusPayload());
}

static void resetDaemonRuntimeState(void) {
    daemonServiceResetRuntimeState();
    activeTunName = @"";
    defaultRouteGatewayV4 = @"";
    defaultRouteGatewayV6 = @"";
    defaultRouteInterfaceV4 = @"";
    defaultRouteInterfaceV6 = @"";
    [activeWhitelistRoutes removeAllObjects];
    [activeIPv4TakeoverRoutes removeAllObjects];
    tunControl = nil;
}

static NSDictionary* runtimeSessionStatusPayload(void) {
    NSMutableDictionary* backup = loadRouteBackup();
    NSArray* persistedEntries = storeEntries();
    BOOL socketAvailable = isControlSocketReachable();
    NSString* tunName = daemonStateTunName();
    BOOL tunExists = NO;
    BOOL tunUp = NO;
    if (tunName.length > 0) {
        NSDictionary* taskResult = runTool(@"/sbin/ifconfig", @[tunName]);
        NSString* ifconfigOutput = taskResult[@"stdout"] ?: @"";
        tunExists = [taskResult[@"status"] intValue] == 0;
        tunUp = tunExists && [ifconfigOutput containsString:@"<UP,"];
    }
    return @{
        @"sessionType": daemonStateDataPlaneKind(),
        @"sessionOwner": daemonStateIsActive() ? @"daemon" : @"none",
        @"controlPlane": socketAvailable ? @"socket" : @"none",
        @"session": daemonStateSessionStatus(),
        @"socket": socketAvailable ? @"available" : @"unavailable",
        @"tunName": tunName ?: @"",
        @"tunExists": @(tunExists),
        @"tunUp": @(tunUp),
        @"defaultGatewayV4": defaultRouteGatewayV4 ?: @"",
        @"defaultGatewayV6": defaultRouteGatewayV6 ?: @"",
        @"defaultInterfaceV4": defaultRouteInterfaceV4 ?: @"",
        @"defaultInterfaceV6": defaultRouteInterfaceV6 ?: @"",
        @"ipv4TakeoverRoutes": activeIPv4TakeoverRoutes ?: @[],
        @"whitelistPersistedCount": @([persistedEntries count]),
        @"whitelistAppliedCount": @([activeWhitelistRoutes count]),
        @"lastError": backup[ROUTE_BACKUP_LAST_ERROR_KEY] ?: @"",
        @"leaseId": daemonStateLeaseIdentifier(),
    };
}

static NSDictionary* routeListPayload(void) {
    NSArray* persistedEntries = storeEntries();
    NSArray* appliedEntries = activeWhitelistRoutes != nil ? [activeWhitelistRoutes allValues] : @[];
    return @{
        @"session": daemonStateSessionStatus(),
        @"persisted": persistedEntries ?: @[],
        @"applied": appliedEntries ?: @[],
    };
}

static NSDictionary* cliDiagnosticStatusPayload(void) {
    NSMutableDictionary* backup = loadRouteBackup();
    BOOL daemonReachable = isControlSocketReachable();
    BOOL staleSocket = access([helperControlSocketPath() fileSystemRepresentation], F_OK) == 0 && !daemonReachable;
    BOOL staleLock = access([helperTunSessionLockPath() fileSystemRepresentation], F_OK) == 0;
    return @{
        @"daemon": daemonReachable ? @"available" : @"unavailable",
        @"session": daemonReachable ? @"unknown" : @"inactive",
        @"diagnostics": @{
            @"staleSocket": @(staleSocket),
            @"staleLock": @(staleLock),
            @"historicalBackup": @([backup count] > 0),
        },
        @"history": @{
            @"lastError": backup[ROUTE_BACKUP_LAST_ERROR_KEY] ?: @"",
            @"lastTunName": backup[ROUTE_BACKUP_TUN_NAME_KEY] ?: @"",
            @"lastSessionType": backup[ROUTE_BACKUP_SESSION_TYPE_KEY] ?: SESSION_TYPE_NONE,
        },
    };
}

static void updateRouteBackupRoutes(NSMutableDictionary* backup) {
    if (backup == nil) {
        return;
    }
    NSArray* appliedRoutes = activeWhitelistRoutes != nil ? [activeWhitelistRoutes allValues] : @[];
    backup[ROUTE_BACKUP_WHITELIST_ROUTES_KEY] = appliedRoutes;
}

static void updateRouteBackupState(NSMutableDictionary* backup, NSString* state, NSString* lastError) {
    if (backup == nil) {
        return;
    }
    backup[ROUTE_BACKUP_STATE_KEY] = state ?: ROUTE_BACKUP_STATE_IDLE;
    backup[ROUTE_BACKUP_TUN_NAME_KEY] = activeTunName ?: @"";
    backup[ROUTE_BACKUP_LAST_ERROR_KEY] = lastError ?: @"";
    if (activeTunName.length == 0) {
        backup[ROUTE_BACKUP_SESSION_TYPE_KEY] = SESSION_TYPE_NONE;
        backup[ROUTE_BACKUP_SESSION_OWNER_KEY] = SESSION_OWNER_NONE;
        backup[ROUTE_BACKUP_CONTROL_PLANE_KEY] = CONTROL_PLANE_NONE;
    }
    updateRouteBackupRoutes(backup);
    updateRouteBackupTakeoverRoutes(backup, activeIPv4TakeoverRoutes);
    saveRouteBackup(backup);
}

static NSDictionary* stopTunSession(void) {
    NSString* lockError = nil;
    if (!acquireTunSessionLock(&lockError)) {
        return makeResponse(NO, lockError ?: @"Another tun session operation is already in progress.", nil);
    }
    NSMutableArray* removedEntries = [[NSMutableArray alloc] init];
    NSMutableArray* failedEntries = [[NSMutableArray alloc] init];
    if (activeWhitelistRoutes != nil) {
        removeWhitelistEntries([activeWhitelistRoutes allValues], routeHelper, &activeWhitelistRoutes, removedEntries, failedEntries);
    }
    NSMutableDictionary* backup = loadRouteBackup();
    NSString* routeError = nil;
    BOOL removedTakeover = removeIPv4TakeoverRoutesBridge(activeTunName, &routeError);
    resetTunRuntimeStateBridge(backup, ROUTE_BACKUP_STATE_IDLE, @"");
    daemonStateReset();
    BOOL restored = YES;
    activeTunName = @"";
    releaseTunSessionLock();
    if (!removedTakeover && routeError.length > 0) {
        backup[ROUTE_BACKUP_LAST_ERROR_KEY] = routeError;
        saveRouteBackup(backup);
    }
    return makeResponse(restored && removedTakeover && failedEntries.count == 0, (restored && removedTakeover) ? @"Tun session stopped." : @"Failed to fully restore tun session.", @{@"removed": removedEntries, @"failed": failedEntries, @"takeoverRemoved": @(removedTakeover)});
}

static NSDictionary* stopDaemon(void) {
    if (controlServerSocketFD != -1) {
        close(controlServerSocketFD);
        controlServerSocketFD = -1;
    }
    unlink([helperControlSocketPath() fileSystemRepresentation]);
    runLoopMark = NO;
    return makeResponse(YES, @"Daemon stopped.", buildDaemonStatusResponsePayload(nil));
}

static NSDictionary* allocateTunLease(NSString* tunName, int* responseFDOut) {
    if (tunName != nil && tunName.length > 0 && ![tunName hasPrefix:@"utun"]) {
        return makeResponse(NO, @"Tun interface name must be utunN.", nil);
    }
    if (daemonStateIsActive()) {
        return makeResponse(NO, @"A tun session is already active.", nil);
    }
    NSString* actualTunName = nil;
    int tunFD = createTUNWithName(tunName, &actualTunName);
    if (tunFD < 0) {
        return makeResponse(NO, [NSString stringWithFormat:@"Failed to create tun interface (errno=%d).", -tunFD], nil);
    }
    if (actualTunName.length == 0 && tunName.length > 0) {
        actualTunName = tunName;
    }
    NSString* setupError = nil;
    if (!ensureTUNInterfaceReady(actualTunName, 1500, &setupError)) {
        close(tunFD);
        return makeResponse(NO, setupError ?: @"Failed to configure tun interface.", nil);
    }
    NSString* leaseId = [[NSUUID UUID] UUIDString];
    NSString* leaseError = nil;
    if (!daemonStateStoreFDLease(leaseId, actualTunName, tunFD, &leaseError)) {
        close(tunFD);
        return makeResponse(NO, leaseError ?: @"Failed to store tun lease.", nil);
    }
    if (responseFDOut != NULL) {
        *responseFDOut = dup(tunFD);
    }
    return makeResponse(YES, @"Tun lease prepared.", @{@"tunName": actualTunName ?: @"", @"leaseId": leaseId});
}

static NSDictionary* processServerRequest(NSDictionary* request, int* responseFDOut) {
    if (responseFDOut != NULL) {
        *responseFDOut = -1;
    }
    NSString* command = daemonRPCCommand(request);
    NSDictionary* payload = daemonRPCPayload(request);
    NSArray* entries = payload[@"entries"];
    if ([command isEqualToString:@"session.status"] || [command isEqualToString:@"status"]) {
        return makeResponse(YES, @"Tun session status.", runtimeSessionStatusPayload());
    }
    if ([command isEqualToString:@"session.start_embedded"]) {
        NSInteger socksPort = [payload[@"socksPort"] integerValue];
        NSString* errorMessage = nil;
        if (!setupTunSession((int)socksPort, &errorMessage)) {
            return makeResponse(NO, errorMessage ?: @"Failed to start tun session.", nil);
        }
        daemonStateActivateEmbeddedSession(activeTunName, socksPort);
        NSDictionary* syncResponse = syncActiveWhitelistWithEntries(storeEntries(), YES, routeHelper, defaultRouteGatewayV4, defaultRouteGatewayV6, defaultRouteInterfaceV4, defaultRouteInterfaceV6, &activeWhitelistRoutes, activeTunName, ^NSDictionary* (NSString* state, NSString* lastError) {
            return updateBackupForActiveRoutes(state, lastError);
        });
        if (![syncResponse[@"ok"] boolValue]) {
            NSMutableDictionary* backup = loadRouteBackup();
            updateRouteBackupState(backup, ROUTE_BACKUP_STATE_ACTIVE, syncResponse[@"message"] ?: @"whitelist sync failed");
        }
        return makeResponse(YES, @"Embedded tun session started.", runtimeSessionStatusPayload());
    }
    if ([command isEqualToString:@"session.allocate_fd"]) {
        return allocateTunLease(payload[@"preferredTunName"], responseFDOut);
    }
    if ([command isEqualToString:@"session.activate"]) {
        NSString* errorMessage = nil;
        NSString* activatedTunName = nil;
        NSString* leaseId = nil;
        if (!daemonStateResolvePendingLease(payload[@"leaseId"], &activatedTunName, &leaseId, &errorMessage)) {
            return makeResponse(NO, errorMessage ?: @"Failed to activate pending tun lease.", nil);
        }
        if (!activateAllocatedTunLease(activatedTunName, &errorMessage)) {
            daemonStateClearLease();
            return makeResponse(NO, errorMessage ?: @"Failed to activate tun lease.", nil);
        }
        daemonStateActivatePendingLease();
        return makeResponse(YES, @"Tun lease activated.", @{@"leaseId": leaseId ?: @"", @"tunName": activatedTunName ?: @"", @"status": runtimeSessionStatusPayload()});
    }
    if ([command isEqualToString:@"route-list"]) {
        return makeResponse(YES, @"Route whitelist entries.", routeListPayload());
    }
    if ([command isEqualToString:@"session.route.sync"] || [command isEqualToString:@"route-sync"]) {
        return syncActiveWhitelistWithEntries(entries ?: @[], YES, routeHelper, defaultRouteGatewayV4, defaultRouteGatewayV6, defaultRouteInterfaceV4, defaultRouteInterfaceV6, &activeWhitelistRoutes, activeTunName, ^NSDictionary* (NSString* state, NSString* lastError) {
            return updateBackupForActiveRoutes(state, lastError);
        });
    }
    if ([command isEqualToString:@"session.route.add"] || [command isEqualToString:@"route-add"]) {
        return syncActiveWhitelistWithEntries(entries ?: @[], NO, routeHelper, defaultRouteGatewayV4, defaultRouteGatewayV6, defaultRouteInterfaceV4, defaultRouteInterfaceV6, &activeWhitelistRoutes, activeTunName, ^NSDictionary* (NSString* state, NSString* lastError) {
            return updateBackupForActiveRoutes(state, lastError);
        });
    }
    if ([command isEqualToString:@"session.route.del"] || [command isEqualToString:@"route-del"]) {
        NSMutableArray* removed = [[NSMutableArray alloc] init];
        NSMutableArray* failed = [[NSMutableArray alloc] init];
        removeWhitelistEntries(entries ?: @[], routeHelper, &activeWhitelistRoutes, removed, failed);
        NSMutableDictionary* backup = loadRouteBackup();
        updateRouteBackupState(backup, activeTunName.length > 0 ? ROUTE_BACKUP_STATE_ACTIVE : ROUTE_BACKUP_STATE_IDLE, failed.count > 0 ? @"route delete failed" : @"");
        return makeResponse(failed.count == 0, failed.count == 0 ? @"Routes removed from active whitelist." : @"Failed to remove some active routes.", @{@"removed": removed, @"failed": failed, @"active": [activeWhitelistRoutes allValues] ?: @[]});
    }
    if ([command isEqualToString:@"session.route.clear"] || [command isEqualToString:@"route-clear"]) {
        NSMutableArray* removed = [[NSMutableArray alloc] init];
        NSMutableArray* failed = [[NSMutableArray alloc] init];
        removeWhitelistEntries([activeWhitelistRoutes allValues] ?: @[], routeHelper, &activeWhitelistRoutes, removed, failed);
        NSMutableDictionary* backup = loadRouteBackup();
        updateRouteBackupState(backup, activeTunName.length > 0 ? ROUTE_BACKUP_STATE_ACTIVE : ROUTE_BACKUP_STATE_IDLE, failed.count > 0 ? @"route clear failed" : @"");
        return makeResponse(failed.count == 0, failed.count == 0 ? @"Active whitelist cleared." : @"Failed to clear active whitelist.", @{@"removed": removed, @"failed": failed});
    }
    if ([command isEqualToString:@"session.stop"] || [command isEqualToString:@"stop"]) {
        return stopTunSession();
    }
    if ([command isEqualToString:@"daemon.stop"]) {
        return stopDaemon();
    }
    return makeResponse(NO, @"Unknown server command.", nil);
}

static NSDictionary* requestActiveSession(NSDictionary* request) {
    NSString* errorMessage = nil;
    NSDictionary* response = sendRequestToControlServer(request, &errorMessage);
    if (response == nil) {
        return makeResponse(NO, errorMessage ?: @"Failed to contact tun session.", nil);
    }
    return response;
}

static NSDictionary* requestDaemonSession(NSDictionary* request, int* receivedFDOut) {
    NSString* errorMessage = nil;
    NSDictionary* response = sendRequestToControlServerWithFD(request, receivedFDOut, &errorMessage);
    if (response == nil) {
        return makeResponse(NO, errorMessage ?: @"Failed to contact daemon.", nil);
    }
    return response;
}

static NSDictionary* handleRouteCommand(NSArray<NSString*>* arguments) {
    return routeCommandServiceHandle(arguments, routeHelper, defaultRouteGatewayV4, defaultRouteGatewayV6, defaultRouteInterfaceV4, defaultRouteInterfaceV6, &activeWhitelistRoutes, activeTunName, NO, ^NSDictionary* (NSDictionary* request) {
        NSMutableDictionary* rpcPayload = [NSMutableDictionary dictionaryWithDictionary:request];
        NSString* legacyCommand = request[@"cmd"];
        if ([legacyCommand isEqualToString:@"route-sync"]) {
            return requestActiveSession(daemonRPCMakeRequest(@"session.route.sync", @{@"entries": request[@"entries"] ?: @[]}));
        }
        if ([legacyCommand isEqualToString:@"route-add"]) {
            return requestActiveSession(daemonRPCMakeRequest(@"session.route.add", @{@"entries": request[@"entries"] ?: @[]}));
        }
        if ([legacyCommand isEqualToString:@"route-del"]) {
            return requestActiveSession(daemonRPCMakeRequest(@"session.route.del", @{@"entries": request[@"entries"] ?: @[]}));
        }
        if ([legacyCommand isEqualToString:@"route-clear"]) {
            return requestActiveSession(daemonRPCMakeRequest(@"session.route.clear", @{}));
        }
        return requestActiveSession(daemonRPCMakeRequest(@"session.route.sync", rpcPayload));
    }, ^NSString* {
        return daemonStateSessionStatus();
    }, ^NSDictionary* {
        return routeListPayload();
    }, ^NSDictionary* (BOOL ok, NSString* message, NSDictionary* payload) {
        return makeResponse(ok, message, payload);
    }, ^NSDictionary* (NSString* state, NSString* lastError) {
        return updateBackupForActiveRoutes(state, lastError);
    });
}

static NSDictionary* handleDaemonCommand(NSArray<NSString*>* arguments) {
    if (arguments.count >= 2 && [arguments[1] isEqualToString:@"stop"]) {
        NSDictionary* response = requestDaemonSession(daemonRPCMakeRequest(@"daemon.stop", @{}), NULL);
        if ([response[@"ok"] boolValue]) {
            return makeResponse(YES, @"Daemon stopped.", buildDaemonStatusResponsePayload(nil));
        }
        return response;
    }
    if (arguments.count >= 2 && [arguments[1] isEqualToString:@"status"]) {
        NSDictionary* response = requestDaemonSession(daemonRPCMakeRequest(@"session.status", @{}), NULL);
        if ([response[@"ok"] boolValue]) {
            return makeResponse(YES, @"Daemon status.", buildDaemonStatusResponsePayload(response));
        }
        return makeResponse(YES, @"Daemon status.", buildDaemonStatusResponsePayload(nil));
    }
    return daemonServiceHandleCommand(arguments, ^NSDictionary* (BOOL ok, NSString* message, NSDictionary* payload) {
        return makeResponse(ok, message, payload);
    }, ^BOOL (NSString** errorMessage) {
        return startControlSocketServer(&controlServerSocketFD, errorMessage);
    }, ^{
        controlSocketAcceptLoop(controlServerSocketFD, &runLoopMark, ^NSDictionary* (NSDictionary* request, int* responseFDOut) {
            return processServerRequest(request, responseFDOut);
        });
    }, ^NSDictionary* {
        return daemonEnvelopeStatusPayload();
    }, ^{
        resetDaemonRuntimeState();
    });
}

static NSDictionary* handleTunCleanupCommand(void) {
    NSMutableArray<NSString*>* removed = [[NSMutableArray alloc] init];
    NSString* socketPath = helperControlSocketPath();
    NSString* lockPath = helperTunSessionLockPath();
    if (access([socketPath fileSystemRepresentation], F_OK) == 0) {
        unlink([socketPath fileSystemRepresentation]);
        [removed addObject:socketPath];
    }
    if (access([lockPath fileSystemRepresentation], F_OK) == 0) {
        unlink([lockPath fileSystemRepresentation]);
        [removed addObject:lockPath];
    }
    NSURL* backupURL = helperRouteBackupFileURL();
    if (backupURL != nil && access([[backupURL path] fileSystemRepresentation], F_OK) == 0) {
        unlink([[backupURL path] fileSystemRepresentation]);
        [removed addObject:[backupURL path]];
    }
    return makeResponse(YES, @"Tun cleanup completed.", @{@"removed": removed});
}

static NSDictionary* handleTunCommand(NSArray<NSString*>* arguments) {
    if (arguments.count >= 2 && [arguments[1] isEqualToString:@"cleanup"]) {
        return handleTunCleanupCommand();
    }
    if (arguments.count >= 2 && [arguments[1] isEqualToString:@"status"]) {
        NSDictionary* daemonResponse = requestDaemonSession(daemonRPCMakeRequest(@"session.status", @{}), NULL);
        if ([daemonResponse[@"ok"] boolValue]) {
            return buildTunStatusResponsePayload(daemonResponse);
        }
        return buildTunDiagnosticStatusResponse();
    }
    return tunCommandServiceHandle(arguments, ^NSDictionary* (BOOL ok, NSString* message, NSDictionary* payload) {
        return makeResponse(ok, message, payload);
    }, ^NSDictionary* {
        return buildTunDiagnosticStatusResponse();
    }, ^NSDictionary* (int localProxyPort) {
        return requestDaemonSession(daemonRPCMakeRequest(@"session.start_embedded", @{@"socksPort": @(localProxyPort)}), NULL);
    }, ^NSDictionary* (NSString* preferredTunName, int* receivedFDOut) {
        NSMutableDictionary* payload = [[NSMutableDictionary alloc] init];
        if (preferredTunName.length > 0) {
            payload[@"preferredTunName"] = preferredTunName;
        }
        return requestDaemonSession(daemonRPCMakeRequest(@"session.allocate_fd", payload), receivedFDOut);
    }, ^NSDictionary* (NSString* leaseId) {
        NSMutableDictionary* payload = [[NSMutableDictionary alloc] init];
        if (leaseId.length > 0) {
            payload[@"leaseId"] = leaseId;
        }
        return requestDaemonSession(daemonRPCMakeRequest(@"session.activate", payload), NULL);
    }, ^NSDictionary* {
        return requestDaemonSession(daemonRPCMakeRequest(@"session.stop", @{}), NULL);
    });
}

static BOOL setupTunSession(int localProxyPort, NSString** errorMessage) {
    if (!acquireTunSessionLock(errorMessage)) {
        return NO;
    }
    if (![daemonStateSessionStatus() isEqualToString:@"inactive"]) {
        if (errorMessage != NULL) {
            *errorMessage = @"A tun session is already active.";
        }
        releaseTunSessionLock();
        return NO;
    }
    if (!applySystemProxyMode(@"off", nil, 0, 0)) {
        if (errorMessage != NULL) {
            *errorMessage = @"Failed to disable existing system proxy before enabling tun mode.";
        }
        releaseTunSessionLock();
        return NO;
    }
    NSString* socks5ProxyLink = [NSString stringWithFormat:@"socks5://127.0.0.1:%d", localProxyPort];
    NSError* err = nil;
    tunControl = Tun2socksCreateTunConnect(tunAddr, tunWg, tunMask, tunDns, socks5ProxyLink, true, &err);
    if (err != nil || tunControl == nil || tunControl.tunName == nil) {
        if (errorMessage != NULL) {
            *errorMessage = err.localizedDescription ?: @"Failed to create tun2socks session.";
        }
        releaseTunSessionLock();
        return NO;
    }
    activeTunName = tunControl.tunName;
    if (!loadDefaultRouteBaselineBridge(errorMessage)) {
        releaseTunSessionLock();
        return NO;
    }
    NSMutableDictionary* backup = loadRouteBackup();
    updateRouteBackupState(backup, ROUTE_BACKUP_STATE_SWITCHING, @"");
    if (![routeHelper upInterface:activeTunName]) {
        if (errorMessage != NULL) {
            *errorMessage = @"Failed to bring up tun interface.";
        }
        releaseTunSessionLock();
        return NO;
    }
    if (!installIPv4TakeoverRoutesBridge(activeTunName, backup, errorMessage)) {
        resetTunRuntimeStateBridge(backup, ROUTE_BACKUP_STATE_IDLE, @"");
        releaseTunSessionLock();
        return NO;
    }
    updateRouteBackupState(backup, ROUTE_BACKUP_STATE_ACTIVE, @"");
    backup[ROUTE_BACKUP_SESSION_TYPE_KEY] = SESSION_TYPE_INTERNAL;
    backup[ROUTE_BACKUP_SESSION_OWNER_KEY] = SESSION_OWNER_HELPER;
    backup[ROUTE_BACKUP_CONTROL_PLANE_KEY] = CONTROL_PLANE_SOCKET;
    saveRouteBackup(backup);
    return YES;
}

static BOOL activateAllocatedTunLease(NSString* tunName, NSString** errorMessage) {
    if (!acquireTunSessionLock(errorMessage)) {
        return NO;
    }
    if (![daemonStateSessionStatus() isEqualToString:@"inactive"]) {
        if (errorMessage != NULL) {
            *errorMessage = @"A tun session is already active.";
        }
        releaseTunSessionLock();
        return NO;
    }
    if (tunName == nil || tunName.length == 0) {
        if (errorMessage != NULL) {
            *errorMessage = @"Missing utun interface name.";
        }
        releaseTunSessionLock();
        return NO;
    }
    if (!applySystemProxyMode(@"off", nil, 0, 0)) {
        if (errorMessage != NULL) {
            *errorMessage = @"Failed to disable existing system proxy before enabling tun mode.";
        }
        releaseTunSessionLock();
        return NO;
    }
    activeTunName = tunName;
    if (!loadDefaultRouteBaselineBridge(errorMessage)) {
        releaseTunSessionLock();
        return NO;
    }
    NSMutableDictionary* backup = loadRouteBackup();
    updateRouteBackupState(backup, ROUTE_BACKUP_STATE_SWITCHING, @"");
    if (![routeHelper upInterface:activeTunName]) {
        if (errorMessage != NULL) {
            *errorMessage = @"Failed to bring up tun interface.";
        }
        activeTunName = @"";
        releaseTunSessionLock();
        return NO;
    }
    if (!installIPv4TakeoverRoutesBridge(activeTunName, backup, errorMessage)) {
        resetTunRuntimeStateBridge(backup, ROUTE_BACKUP_STATE_IDLE, @"");
        activeTunName = @"";
        releaseTunSessionLock();
        return NO;
    }
    updateRouteBackupState(backup, ROUTE_BACKUP_STATE_ACTIVE, @"");
    backup[ROUTE_BACKUP_SESSION_TYPE_KEY] = SESSION_TYPE_EXTERNAL_FD;
    backup[ROUTE_BACKUP_SESSION_OWNER_KEY] = SESSION_OWNER_EXTERNAL;
    backup[ROUTE_BACKUP_CONTROL_PLANE_KEY] = CONTROL_PLANE_STATELESS;
    saveRouteBackup(backup);
    NSDictionary* syncResponse = syncActiveWhitelistWithEntries(storeEntries(), YES, routeHelper, defaultRouteGatewayV4, defaultRouteGatewayV6, defaultRouteInterfaceV4, defaultRouteInterfaceV6, &activeWhitelistRoutes, activeTunName, ^NSDictionary* (NSString* state, NSString* lastError) {
        return updateBackupForActiveRoutes(state, lastError);
    });
    if (![syncResponse[@"ok"] boolValue]) {
        if (errorMessage != NULL) {
            *errorMessage = syncResponse[@"message"] ?: @"Failed to synchronize whitelist routes.";
        }
        releaseTunSessionLock();
        return NO;
    }
    return YES;
}

static void cleanupHandle(int signal_ns) {
    (void)signal_ns;
    if ([runtimeMode isEqualToString:@"tun"]) {
        stopTunSession();
    }
    if (controlServerSocketFD != -1) {
        close(controlServerSocketFD);
        controlServerSocketFD = -1;
        unlink([helperControlSocketPath() fileSystemRepresentation]);
    }
    releaseTunSessionLock();
    runLoopMark = NO;
}

int main(int argc, const char * argv[])
{
    routeHelper = [[SYSRouteHelper alloc] init];
    activeWhitelistRoutes = [[NSMutableDictionary alloc] init];
    activeIPv4TakeoverRoutes = [[NSMutableArray alloc] init];
    runtimeContext = (HelperRuntimeContext){
        .routeHelper = routeHelper,
        .tunWg = tunWg,
        .activeTunName = &activeTunName,
        .defaultRouteGatewayV4 = &defaultRouteGatewayV4,
        .defaultRouteGatewayV6 = &defaultRouteGatewayV6,
        .defaultRouteInterfaceV4 = &defaultRouteInterfaceV4,
        .defaultRouteInterfaceV6 = &defaultRouteInterfaceV6,
        .activeWhitelistRoutes = activeWhitelistRoutes,
        .activeIPv4TakeoverRoutes = &activeIPv4TakeoverRoutes,
        .loadRouteBackupBlock = ^NSMutableDictionary* {
            return loadRouteBackup();
        },
        .updateRouteBackupStateBlock = ^(NSMutableDictionary* backup, NSString* state, NSString* lastError) {
            updateRouteBackupState(backup, state, lastError);
        },
        .currentSessionTypeBlock = ^NSString* {
            return currentSessionType();
        },
        .currentSessionOwnerBlock = ^NSString* {
            return currentSessionOwner();
        },
        .currentControlPlaneBlock = ^NSString* {
            return currentControlPlane();
        },
    };
    signal(SIGABRT, cleanupHandle);
    signal(SIGINT, cleanupHandle);
    signal(SIGTERM, cleanupHandle);

    @autoreleasepool {
        if (argc < 2) {
            printf(INFO);
            return EXIT_USAGE;
        }
        NSMutableArray<NSString*>* arguments = [[NSMutableArray alloc] init];
        for (int index = 1; index < argc; index++) {
            [arguments addObject:[NSString stringWithUTF8String:argv[index]]];
        }
        debugLoggingEnabled = shouldEnableDebugLogging(arguments);
        NSString* command = arguments[0];
        BOOL asJSON = shouldOutputJSON(arguments);
        NSDictionary* response = nil;
        NSInteger exitCode = 0;

        if ([command isEqualToString:@"-v"]) {
            printf("%s", [VERSION UTF8String]);
            return 0;
        }
        if ([command isEqualToString:@"off"] || [command isEqualToString:@"auto"] || [command isEqualToString:@"global"] || [command isEqualToString:@"save"] || [command isEqualToString:@"restore"]) {
            NSDictionary* originalSets = nil;
            int localPort = 0;
            int httpPort = 0;
            if ([command isEqualToString:@"save"]) {
                response = makeResponse(runProxySaveMode(), runProxySaveMode() ? @"System proxy settings saved." : @"Failed to save system proxy settings.", nil);
            } else {
                if ([command isEqualToString:@"restore"]) {
                    originalSets = loadProxyBackup();
                } else if ([command isEqualToString:@"global"]) {
                    if (arguments.count < 3 || !parseProxyPorts([arguments[1] UTF8String], [arguments[2] UTF8String], &localPort, &httpPort)) {
                        response = makeResponse(NO, @"Invalid proxy port arguments.", nil);
                        exitCode = EXIT_USAGE;
                    }
                }
                if (response == nil) {
                    BOOL ok = applySystemProxyMode(command, originalSets, localPort, httpPort);
                    response = makeResponse(ok, ok ? [NSString stringWithFormat:@"proxy set to %@", command] : [NSString stringWithFormat:@"failed to set proxy to %@", command], nil);
                }
            }
        } else if ([command isEqualToString:@"daemon"]) {
            runtimeMode = @"daemon";
            response = handleDaemonCommand(arguments);
            if (![response[@"ok"] boolValue]) {
                exitCode = EXIT_SOCKET;
            }
        } else if ([command isEqualToString:@"tun"]) {
            runtimeMode = @"tun";
            response = handleTunCommand(arguments);
            if (![response[@"ok"] boolValue]) {
                if ([arguments count] > 1 && [arguments[1] isEqualToString:@"allocate"]) {
                    exitCode = EXIT_TUN_FD;
                } else {
                    exitCode = ([response[@"message"] containsString:@"No active tun session"] || [response[@"message"] containsString:@"active tun session"]) ? EXIT_REQUIRE_ACTIVE : EXIT_ROUTE;
                }
            }
        } else if ([command isEqualToString:@"route"]) {
            response = handleRouteCommand(arguments);
            if (![response[@"ok"] boolValue]) {
                if ([response[@"message"] containsString:@"No active tun session"] || [response[@"message"] containsString:@"active tun session"]) {
                    exitCode = EXIT_REQUIRE_ACTIVE;
                } else if (response[@"invalid"] != nil) {
                    exitCode = EXIT_USAGE;
                } else if ([response[@"message"] containsString:@"socket"]) {
                    exitCode = EXIT_SOCKET;
                } else {
                    exitCode = EXIT_ROUTE;
                }
            }
        } else {
            response = makeResponse(NO, @"Unknown command.", nil);
            exitCode = EXIT_USAGE;
        }

        printResponse(response, asJSON);
        return (int)exitCode;
    }
}
