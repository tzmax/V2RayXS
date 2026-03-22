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
#import "helper_runtime_context.h"
#import "route_command_service.h"
#import "route_entry_normalizer.h"
#import "session_backup_store.h"
#import "session_state.h"
#import "tun_command_service.h"
#import "tun_session_controller.h"
#import "route_whitelist_store.h"
#import "control_socket_transport.h"
#import <stdarg.h>

#define INFO "v2rayx_sysconf\nusage:\n  v2rayx_sysconf -v\n  v2rayx_sysconf off [--debug]\n  v2rayx_sysconf auto [--debug]\n  v2rayx_sysconf global <socksPort> <httpPort> [--debug]\n  v2rayx_sysconf save [--debug]\n  v2rayx_sysconf restore [--debug]\n  v2rayx_sysconf tun start <socksPort> [--debug]\n  v2rayx_sysconf tun allocate [<utunName>] <sendSocketFD> [--debug]\n  v2rayx_sysconf tun activate <utunName> [--debug]\n  v2rayx_sysconf tun deactivate [<utunName>] [--json] [--debug]\n  v2rayx_sysconf tun stop [--json] [--debug]\n  v2rayx_sysconf tun status [--json] [--debug]\n  v2rayx_sysconf route add <ip...> [--json] [--require-active] [--debug]\n  v2rayx_sysconf route del <ip...> [--json] [--require-active] [--debug]\n  v2rayx_sysconf route list [--json] [--debug]\n  v2rayx_sysconf route clear [--json] [--require-active] [--debug]\n  v2rayx_sysconf route apply [--json] [--debug]\n  v2rayx_sysconf route sync-file <path> [--json] [--require-active] [--debug]\n"

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
static void debugLog(NSString* format, ...);
static NSDictionary* runTool(NSString* launchPath, NSArray<NSString*>* arguments);
static NSDictionary* tunStatusPayload(void);
static NSDictionary* routeListPayload(void);
static NSDictionary* requestActiveSession(NSDictionary* request);
static BOOL isExternalFDSession(void);
static NSDictionary* stopTunSession(void);
static BOOL setupTunSession(int localProxyPort, NSString** errorMessage);
static BOOL activateExternalTunSession(NSString* tunName, NSString** errorMessage);
static NSDictionary* allocateTunFDSession(NSString* tunName, int sendSocketFD);
static NSDictionary* deactivateExternalTunSession(NSString* expectedTunName);
static NSDictionary* processServerRequest(NSDictionary* request);
static void updateRouteBackupState(NSMutableDictionary* backup, NSString* state, NSString* lastError);
static void updateRouteBackupRoutes(NSMutableDictionary* backup);
static NSDictionary* handleTunCommand(NSArray<NSString*>* arguments);
static NSDictionary* handleRouteCommand(NSArray<NSString*>* arguments);
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

static void debugLog(NSString* format, ...) {
    if (!debugLoggingEnabled) {
        return;
    }
    va_list args;
    va_start(args, format);
    NSString* message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    fprintf(stderr, "[debug] %s\n", [message UTF8String]);
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

static void syncRuntimeSessionFromBackupBridge(void) {
    helperRuntimeSyncRuntimeSessionFromBackup(runtimeContext);
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

static NSString* currentSessionStateBridge(void) {
    return helperRuntimeCurrentSessionState(runtimeContext);
}

static NSDictionary* tunStatusPayload(void) {
    NSMutableDictionary* backup = loadRouteBackup();
    NSArray* persistedEntries = storeEntries();
    BOOL socketAvailable = access([helperControlSocketPath() fileSystemRepresentation], F_OK) == 0;
    NSUInteger appliedCount = activeWhitelistRoutes != nil ? [activeWhitelistRoutes count] : [backup[ROUTE_BACKUP_WHITELIST_ROUTES_KEY] count];
    NSString* state = currentSessionStateBridge();
    NSString* tunName = activeTunName.length > 0 ? activeTunName : (backup[ROUTE_BACKUP_TUN_NAME_KEY] ?: @"");
    BOOL tunExists = NO;
    BOOL tunUp = NO;
    if (tunName.length > 0) {
        NSDictionary* taskResult = runTool(@"/sbin/ifconfig", @[tunName]);
        NSString* ifconfigOutput = taskResult[@"stdout"] ?: @"";
        tunExists = [taskResult[@"status"] intValue] == 0;
        tunUp = tunExists && [ifconfigOutput containsString:@"<UP,"];
    }
    NSArray* activeTakeoverEntries = activeIPv4TakeoverRouteEntries(activeIPv4TakeoverRoutes, backup);
    return @{
        @"sessionType": currentSessionType(),
        @"sessionOwner": currentSessionOwner(),
        @"controlPlane": currentControlPlane(),
        @"session": state,
        @"socket": socketAvailable ? @"available" : @"unavailable",
        @"tunName": tunName,
        @"tunExists": @(tunExists),
        @"tunUp": @(tunUp),
        @"defaultGatewayV4": defaultRouteGatewayV4 ?: @"",
        @"defaultGatewayV6": defaultRouteGatewayV6 ?: @"",
        @"defaultInterfaceV4": defaultRouteInterfaceV4 ?: @"",
        @"defaultInterfaceV6": defaultRouteInterfaceV6 ?: @"",
        @"ipv4TakeoverRoutes": activeTakeoverEntries ?: @[],
        @"whitelistPersistedCount": @([persistedEntries count]),
        @"whitelistAppliedCount": @(appliedCount),
        @"lastError": backup[ROUTE_BACKUP_LAST_ERROR_KEY] ?: @"",
    };
}

static NSDictionary* routeListPayload(void) {
    NSArray* persistedEntries = storeEntries();
    NSArray* appliedEntries = activeWhitelistRoutes != nil ? [activeWhitelistRoutes allValues] : loadRouteBackup()[ROUTE_BACKUP_WHITELIST_ROUTES_KEY];
    return @{
        @"session": currentSessionStateBridge(),
        @"persisted": persistedEntries ?: @[],
        @"applied": appliedEntries ?: @[],
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
    syncRuntimeSessionFromBackupBridge();
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
    BOOL restored = YES;
    if (controlServerSocketFD != -1) {
        close(controlServerSocketFD);
        controlServerSocketFD = -1;
    }
    unlink([helperControlSocketPath() fileSystemRepresentation]);
    activeTunName = @"";
    runLoopMark = NO;
    releaseTunSessionLock();
    if (!removedTakeover && routeError.length > 0) {
        backup[ROUTE_BACKUP_LAST_ERROR_KEY] = routeError;
        saveRouteBackup(backup);
    }
    return makeResponse(restored && removedTakeover && failedEntries.count == 0, (restored && removedTakeover) ? @"Tun session stopped." : @"Failed to fully restore tun session.", @{@"removed": removedEntries, @"failed": failedEntries, @"takeoverRemoved": @(removedTakeover)});
}

static NSDictionary* allocateTunFDSession(NSString* tunName, int sendSocketFD) {
    if (tunName != nil && tunName.length > 0) {
        if (![tunName hasPrefix:@"utun"]) {
            return makeResponse(NO, @"Tun interface name must be utunN.", nil);
        }
    }
    if (sendSocketFD < 0) {
        return makeResponse(NO, @"Missing tun fd transport socket fd.", nil);
    }

    debugLog(@"allocating tun fd preferredName=%@ sendSocketFD=%d", tunName ?: @"", sendSocketFD);
    NSString* actualTunName = nil;
    int tunFD = createTUNWithName(tunName, &actualTunName);
    if (tunFD < 0) {
        debugLog(@"createTUNWithName failed errno=%d", -tunFD);
        return makeResponse(NO, [NSString stringWithFormat:@"Failed to create tun interface (errno=%d).", -tunFD], nil);
    }
    if (actualTunName.length == 0 && tunName.length > 0) {
        actualTunName = tunName;
    }

    NSString* setupError = nil;
    if (!ensureTUNInterfaceReady(actualTunName, 1500, &setupError)) {
        debugLog(@"ensureTUNInterfaceReady failed tunName=%@ error=%@", actualTunName ?: @"", setupError ?: @"");
        close(tunFD);
        return makeResponse(NO, setupError ?: @"Failed to configure tun interface.", nil);
    }

    NSDictionary* payload = @{
        @"tunName": actualTunName ?: @"",
    };
    NSData* payloadData = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    NSString* payloadString = [[NSString alloc] initWithData:payloadData encoding:NSUTF8StringEncoding] ?: @"{}";
    if (!sendFileDescriptor(sendSocketFD, tunFD, payloadString)) {
        debugLog(@"sendFileDescriptor failed sendSocketFD=%d tunFD=%d payload=%@ errno=%d", sendSocketFD, tunFD, payloadString, errno);
        close(tunFD);
        return makeResponse(NO, @"Failed to send tun fd to caller.", nil);
    }

    debugLog(@"allocated tun fd actualName=%@ tunFD=%d", actualTunName ?: @"", tunFD);

    close(tunFD);
    return makeResponse(YES, @"Tun fd prepared.", @{@"tunName": actualTunName ?: @""});
}

static NSDictionary* deactivateExternalTunSession(NSString* expectedTunName) {
    syncRuntimeSessionFromBackupBridge();
    if (expectedTunName.length > 0 && activeTunName.length > 0 && ![expectedTunName isEqualToString:activeTunName]) {
        return makeResponse(NO, @"Requested tun name does not match active external tun session.", nil);
    }
    return stopTunSession();
}

static NSDictionary* processServerRequest(NSDictionary* request) {
    NSString* command = request[@"cmd"];
    NSArray* entries = request[@"entries"];
    if ([command isEqualToString:@"status"]) {
        return makeResponse(YES, @"Tun session status.", tunStatusPayload());
    }
    if ([command isEqualToString:@"route-list"]) {
        return makeResponse(YES, @"Route whitelist entries.", routeListPayload());
    }
    if ([command isEqualToString:@"route-sync"]) {
        return syncActiveWhitelistWithEntries(entries ?: @[], YES, routeHelper, defaultRouteGatewayV4, defaultRouteGatewayV6, defaultRouteInterfaceV4, defaultRouteInterfaceV6, &activeWhitelistRoutes, activeTunName, ^NSDictionary* (NSString* state, NSString* lastError) {
            return updateBackupForActiveRoutes(state, lastError);
        });
    }
    if ([command isEqualToString:@"route-add"]) {
        return syncActiveWhitelistWithEntries(entries ?: @[], NO, routeHelper, defaultRouteGatewayV4, defaultRouteGatewayV6, defaultRouteInterfaceV4, defaultRouteInterfaceV6, &activeWhitelistRoutes, activeTunName, ^NSDictionary* (NSString* state, NSString* lastError) {
            return updateBackupForActiveRoutes(state, lastError);
        });
    }
    if ([command isEqualToString:@"route-del"]) {
        NSMutableArray* removed = [[NSMutableArray alloc] init];
        NSMutableArray* failed = [[NSMutableArray alloc] init];
        removeWhitelistEntries(entries ?: @[], routeHelper, &activeWhitelistRoutes, removed, failed);
        NSMutableDictionary* backup = loadRouteBackup();
        updateRouteBackupState(backup, activeTunName.length > 0 ? ROUTE_BACKUP_STATE_ACTIVE : ROUTE_BACKUP_STATE_IDLE, failed.count > 0 ? @"route delete failed" : @"");
        return makeResponse(failed.count == 0, failed.count == 0 ? @"Routes removed from active whitelist." : @"Failed to remove some active routes.", @{@"removed": removed, @"failed": failed, @"active": [activeWhitelistRoutes allValues] ?: @[]});
    }
    if ([command isEqualToString:@"route-clear"]) {
        NSMutableArray* removed = [[NSMutableArray alloc] init];
        NSMutableArray* failed = [[NSMutableArray alloc] init];
        removeWhitelistEntries([activeWhitelistRoutes allValues] ?: @[], routeHelper, &activeWhitelistRoutes, removed, failed);
        NSMutableDictionary* backup = loadRouteBackup();
        updateRouteBackupState(backup, activeTunName.length > 0 ? ROUTE_BACKUP_STATE_ACTIVE : ROUTE_BACKUP_STATE_IDLE, failed.count > 0 ? @"route clear failed" : @"");
        return makeResponse(failed.count == 0, failed.count == 0 ? @"Active whitelist cleared." : @"Failed to clear active whitelist.", @{@"removed": removed, @"failed": failed});
    }
    if ([command isEqualToString:@"stop"]) {
        return stopTunSession();
    }
    return makeResponse(NO, @"Unknown server command.", nil);
}

static NSDictionary* requestActiveSession(NSDictionary* request) {
    NSString* errorMessage = nil;
    NSDictionary* response = sendRequestToControlServer(request, &errorMessage);
    if (response == nil) {
        if (isExternalFDSession()) {
            return makeResponse(NO, errorMessage ?: @"No active control socket for external tun session.", nil);
        }
        NSString* sessionState = currentSessionStateBridge();
        if (![sessionState isEqualToString:@"inactive"]) {
            return makeResponse(YES, @"Tun session state available from backup but control socket is unavailable.", tunStatusPayload());
        }
        return makeResponse(NO, errorMessage ?: @"Failed to contact tun session.", nil);
    }
    return response;
}

static NSDictionary* handleRouteCommand(NSArray<NSString*>* arguments) {
    return routeCommandServiceHandle(arguments, routeHelper, defaultRouteGatewayV4, defaultRouteGatewayV6, defaultRouteInterfaceV4, defaultRouteInterfaceV6, &activeWhitelistRoutes, activeTunName, isExternalFDSession(), ^NSDictionary* (NSDictionary* request) {
        return requestActiveSession(request);
    }, ^NSString* {
        return currentSessionStateBridge();
    }, ^NSDictionary* {
        return routeListPayload();
    }, ^NSDictionary* (BOOL ok, NSString* message, NSDictionary* payload) {
        return makeResponse(ok, message, payload);
    }, ^NSDictionary* (NSString* state, NSString* lastError) {
        return updateBackupForActiveRoutes(state, lastError);
    });
}

static NSDictionary* handleTunCommand(NSArray<NSString*>* arguments) {
    return tunCommandServiceHandle(arguments, ^BOOL {
        return isExternalFDSession();
    }, ^NSDictionary* (BOOL ok, NSString* message, NSDictionary* payload) {
        return makeResponse(ok, message, payload);
    }, ^NSDictionary* {
        return tunStatusPayload();
    }, ^NSDictionary* (NSString* tunName, int sendSocketFD) {
        return allocateTunFDSession(tunName, sendSocketFD);
    }, ^BOOL (NSString* tunName, NSString** errorMessage) {
        return activateExternalTunSession(tunName, errorMessage);
    }, ^NSDictionary* (NSString* tunName) {
        return deactivateExternalTunSession(tunName);
    }, ^NSDictionary* (NSDictionary* request) {
        return requestActiveSession(request);
    }, ^{
        syncRuntimeSessionFromBackupBridge();
    }, ^NSString* {
        return currentSessionStateBridge();
    }, ^NSDictionary* {
        return stopTunSession();
    }, ^BOOL (int localProxyPort, NSString** errorMessage) {
        return setupTunSession(localProxyPort, errorMessage);
    }, ^BOOL (NSString** errorMessage) {
        return startControlSocketServer(&controlServerSocketFD, errorMessage);
    }, ^NSDictionary* (NSString* errorMessage) {
        NSMutableDictionary* backup = loadRouteBackup();
        updateRouteBackupState(backup, ROUTE_BACKUP_STATE_ACTIVE, @"");
        resetTunRuntimeStateBridge(backup, ROUTE_BACKUP_STATE_IDLE, @"");
        releaseTunSessionLock();
        return makeResponse(NO, errorMessage ?: @"Failed to start tun control socket.", nil);
    }, ^NSDictionary* {
        NSDictionary* syncResponse = syncActiveWhitelistWithEntries(storeEntries(), YES, routeHelper, defaultRouteGatewayV4, defaultRouteGatewayV6, defaultRouteInterfaceV4, defaultRouteInterfaceV6, &activeWhitelistRoutes, activeTunName, ^NSDictionary* (NSString* state, NSString* lastError) {
            return updateBackupForActiveRoutes(state, lastError);
        });
        if (![syncResponse[@"ok"] boolValue]) {
            NSMutableDictionary* backup = loadRouteBackup();
            updateRouteBackupState(backup, ROUTE_BACKUP_STATE_ACTIVE, syncResponse[@"message"] ?: @"whitelist sync failed");
        }
        return syncResponse;
    }, ^{
        controlSocketAcceptLoop(controlServerSocketFD, &runLoopMark, ^NSDictionary* (NSDictionary* request) {
            return processServerRequest(request);
        });
    }, ^{
        releaseTunSessionLock();
    });
}

static BOOL isExternalFDSession(void) {
    return [currentSessionType() isEqualToString:SESSION_TYPE_EXTERNAL_FD];
}

static BOOL setupTunSession(int localProxyPort, NSString** errorMessage) {
    if (!acquireTunSessionLock(errorMessage)) {
        return NO;
    }
    syncRuntimeSessionFromBackupBridge();
    if (![currentSessionStateBridge() isEqualToString:@"inactive"]) {
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

static BOOL activateExternalTunSession(NSString* tunName, NSString** errorMessage) {
    if (!acquireTunSessionLock(errorMessage)) {
        return NO;
    }
    syncRuntimeSessionFromBackupBridge();
    if (![currentSessionStateBridge() isEqualToString:@"inactive"]) {
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
