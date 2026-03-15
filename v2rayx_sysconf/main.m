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
#import "route.h"
#import "tun.h"

#define INFO "v2rayx_sysconf\nusage:\n  v2rayx_sysconf -v\n  v2rayx_sysconf off\n  v2rayx_sysconf auto\n  v2rayx_sysconf global <socksPort> <httpPort>\n  v2rayx_sysconf save\n  v2rayx_sysconf restore\n  v2rayx_sysconf tun start <socksPort>\n  v2rayx_sysconf tun allocate [<utunName>] <sendSocketFD>\n  v2rayx_sysconf tun activate <utunName>\n  v2rayx_sysconf tun deactivate [<utunName>] [--json]\n  v2rayx_sysconf tun stop [--json]\n  v2rayx_sysconf tun status [--json]\n  v2rayx_sysconf route add <ip...> [--json] [--require-active]\n  v2rayx_sysconf route del <ip...> [--json] [--require-active]\n  v2rayx_sysconf route list [--json]\n  v2rayx_sysconf route clear [--json] [--require-active]\n  v2rayx_sysconf route apply [--json]\n  v2rayx_sysconf route sync-file <path> [--json] [--require-active]\n"

static NSString* const V2RayXSAppSupportRelativePath = @"Library/Application Support/V2RayXS";
static NSString* const SystemRouteBackupFilename = @"system_route_backup.plist";
static NSString* const SystemProxyBackupFilename = @"system_proxy_backup.plist";
static NSString* const RouteWhitelistStoreFilename = @"route_whitelist_store.plist";
static NSString* const TunControlSocketFilename = @"tun_route.sock";
static NSString* const TunSessionLockFilename = @"tun_session.lock";

static NSString* const ROUTE_BACKUP_VERSION_KEY = @"Version";
static NSString* const ROUTE_BACKUP_STATE_KEY = @"RouteState";
static NSString* const ROUTE_BACKUP_STATE_IDLE = @"idle";
static NSString* const ROUTE_BACKUP_STATE_SWITCHING = @"switching";
static NSString* const ROUTE_BACKUP_STATE_ACTIVE = @"active";
static NSString* const ROUTE_BACKUP_TUN_NAME_KEY = @"TunName";
static NSString* const ROUTE_BACKUP_DEFAULT_GATEWAY_V4_KEY = @"DefaultRouteGatewayV4";
static NSString* const ROUTE_BACKUP_DEFAULT_GATEWAY_V6_KEY = @"DefaultRouteGatewayV6";
static NSString* const ROUTE_BACKUP_DEFAULT_INTERFACE_V4_KEY = @"DefaultRouteInterfaceV4";
static NSString* const ROUTE_BACKUP_DEFAULT_INTERFACE_V6_KEY = @"DefaultRouteInterfaceV6";
static NSString* const ROUTE_BACKUP_WHITELIST_ROUTES_KEY = @"WhitelistRoutes";
static NSString* const ROUTE_BACKUP_IPV4_TAKEOVER_ROUTES_KEY = @"IPv4TakeoverRoutes";
static NSString* const ROUTE_BACKUP_LAST_ERROR_KEY = @"LastError";
static NSString* const ROUTE_BACKUP_SESSION_TYPE_KEY = @"SessionType";
static NSString* const ROUTE_BACKUP_SESSION_OWNER_KEY = @"SessionOwner";
static NSString* const ROUTE_BACKUP_CONTROL_PLANE_KEY = @"ControlPlane";

static NSString* const SESSION_TYPE_NONE = @"none";
static NSString* const SESSION_TYPE_INTERNAL = @"internal";
static NSString* const SESSION_TYPE_EXTERNAL_FD = @"external_fd";
static NSString* const SESSION_OWNER_NONE = @"none";
static NSString* const SESSION_OWNER_HELPER = @"helper";
static NSString* const SESSION_OWNER_EXTERNAL = @"external";
static NSString* const CONTROL_PLANE_NONE = @"none";
static NSString* const CONTROL_PLANE_SOCKET = @"socket";
static NSString* const CONTROL_PLANE_STATELESS = @"stateless";
static NSArray<NSString*>* const IPv4TakeoverCIDRs = @[@"0.0.0.0/1", @"128.0.0.0/1"];

static NSString* const ROUTE_STORE_VERSION_KEY = @"Version";
static NSString* const ROUTE_STORE_ENTRIES_KEY = @"Entries";

static NSString* const ENTRY_IP_KEY = @"ip";
static NSString* const ENTRY_FAMILY_KEY = @"family";
static NSString* const ENTRY_ENABLED_KEY = @"enabled";
static NSString* const ENTRY_GATEWAY_KEY = @"gateway";
static NSString* const ENTRY_INTERFACE_KEY = @"interface";
static NSString* const ENTRY_APPLIED_KEY = @"applied";

static NSInteger const EXIT_USAGE = 1;
static NSInteger const EXIT_REQUIRE_ACTIVE = 2;
static NSInteger const EXIT_SOCKET = 3;
static NSInteger const EXIT_ROUTE = 4;
static NSInteger const EXIT_TUN_FD = 5;

static BOOL runLoopMark = YES;
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

static NSString* appSupportPath(void);
static NSURL* appSupportFileURL(NSString* filename);
static BOOL ensureAppSupportDirectory(void);
static NSURL* routeBackupFileURL(void);
static NSURL* routeStoreFileURL(void);
static NSString* controlSocketPath(void);
static NSString* tunSessionLockPath(void);
static BOOL acquireTunSessionLock(NSString** errorMessage);
static void releaseTunSessionLock(void);
static NSDictionary* makeResponse(BOOL ok, NSString* message, NSDictionary* payload);
static void printResponse(NSDictionary* response, BOOL asJSON);
static BOOL shouldOutputJSON(NSArray<NSString*>* arguments);
static NSDictionary* runTool(NSString* launchPath, NSArray<NSString*>* arguments);
static BOOL runNetworksetup(NSArray<NSString*>* arguments);
static BOOL setProxyFlag(NSMutableDictionary* proxies, NSString* key, BOOL enabled);
static void disableManualProxySettings(NSMutableDictionary* proxies);
static BOOL saveProxyBackup(NSDictionary* sets);
static NSDictionary* loadProxyBackup(void);
static BOOL isConfigurableProxyService(NSDictionary* service);
static BOOL parseProxyPorts(const char* socksArg, const char* httpArg, int* localPort, int* httpPort);
static void applyAutoProxySettings(NSMutableDictionary* proxies);
static void applyGlobalProxySettings(NSMutableDictionary* proxies, int localPort, int httpPort);
static void cleanupInactiveProxySettings(NSMutableDictionary* proxies, NSString* mode);
static NSMutableDictionary* proxiesForMode(NSString* mode, NSDictionary* service, NSString* serviceID, NSDictionary* originalSets, int localPort, int httpPort);
static BOOL applyProxyModeToServices(SCPreferencesRef prefRef, NSDictionary* sets, NSString* mode, NSDictionary* originalSets, int localPort, int httpPort);
static BOOL createAuthorizedPreferences(SCPreferencesRef* prefRefOut);
static BOOL configureNetworksetupProxyForService(NSString* serviceName, NSString* mode, int localPort, int httpPort);
static BOOL applyDynamicProxyState(NSString* mode, int localPort, int httpPort);
static BOOL runProxySaveMode(void);
static BOOL applySystemProxyMode(NSString* mode, NSDictionary* originalSets, int localPort, int httpPort);
static NSMutableDictionary* loadRouteBackup(void);
static BOOL saveRouteBackup(NSMutableDictionary* backup);
static NSMutableDictionary* sanitizeLegacyRouteBackup(NSMutableDictionary* backup);
static NSMutableDictionary* loadRouteStore(void);
static BOOL saveRouteStore(NSDictionary* store);
static NSString* familyStringForFamily(SYSRouteAddressFamily family);
static SYSRouteAddressFamily familyFromString(NSString* familyString);
static NSString* normalizedIPAddressString(NSString* ipAddress, SYSRouteAddressFamily family);
static NSArray<NSDictionary*>* normalizedEntriesFromArray(NSArray* rawEntries, NSArray<NSString*>** invalidItems);
static NSString* routeKeyForEntry(NSDictionary* entry);
static NSArray<NSDictionary*>* storeEntries(void);
static BOOL replaceStoreEntries(NSArray<NSDictionary*>* entries);
static NSDictionary* addEntriesToStore(NSArray<NSDictionary*>* entries);
static NSDictionary* removeEntriesFromStore(NSArray<NSDictionary*>* entries);
static NSDictionary* clearStoreEntries(void);
static NSArray<NSDictionary*>* activeIPv4TakeoverRouteEntries(void);
static void updateRouteBackupTakeoverRoutes(NSMutableDictionary* backup);
static NSDictionary* tunStatusPayload(void);
static NSDictionary* routeListPayload(void);
static NSDictionary* sendRequestToControlServer(NSDictionary* request, NSString** errorMessage);
static NSDictionary* requestActiveSession(NSDictionary* request);
static NSString* currentSessionState(void);
static NSString* currentSessionType(void);
static NSString* currentSessionOwner(void);
static NSString* currentControlPlane(void);
static BOOL isExternalFDSession(void);
static BOOL canTreatSessionAsActiveResponse(NSDictionary* response);
static BOOL applyWhitelistEntries(NSArray<NSDictionary*>* entries, NSMutableArray* appliedEntries, NSMutableArray* failedEntries);
static BOOL removeWhitelistEntries(NSArray<NSDictionary*>* entries, NSMutableArray* removedEntries, NSMutableArray* failedEntries);
static NSDictionary* syncActiveWhitelistWithEntries(NSArray<NSDictionary*>* entries, BOOL replaceExisting);
static NSDictionary* stopTunSession(void);
static BOOL setupTunSession(int localProxyPort, NSString** errorMessage);
static BOOL activateExternalTunSession(NSString* tunName, NSString** errorMessage);
static NSDictionary* allocateTunFDSession(NSString* tunName, int sendSocketFD);
static NSDictionary* deactivateExternalTunSession(NSString* expectedTunName);
static BOOL installIPv4TakeoverRoutes(NSString* tunName, NSMutableDictionary* backup, NSString** errorMessage);
static BOOL removeIPv4TakeoverRoutes(NSString* tunName, NSString** errorMessage);
static BOOL loadDefaultRouteBaseline(NSString** errorMessage);
static BOOL startControlSocketServer(NSString** errorMessage);
static void controlSocketAcceptLoop(void);
static NSDictionary* processServerRequest(NSDictionary* request);
static void syncRuntimeSessionFromBackup(void);
static void syncRuntimeRouteBaselineFromBackup(void);
static BOOL isTunManagedIPv4Route(NSString* gateway, NSString* interfaceName);
static BOOL hasUsableIPv4Baseline(void);
static void resetTunRuntimeState(NSMutableDictionary* routeBackup, NSString* state, NSString* lastError);
static void updateRouteBackupState(NSMutableDictionary* backup, NSString* state, NSString* lastError);
static void hydrateBaselineRuntimeFromBackup(NSMutableDictionary* backup);
static NSDictionary* preferredNonTunDefaultRoute(void);
static void updateRouteBackupRoutes(NSMutableDictionary* backup);
static NSArray<NSString*>* ipLiteralAddressesFromPath(NSString* path);
static NSDictionary* handleTunCommand(NSArray<NSString*>* arguments);
static NSDictionary* handleRouteCommand(NSArray<NSString*>* arguments);
static void cleanupHandle(int signal_ns);

static NSString* appSupportPath(void) {
    NSString* override = [[[NSProcessInfo processInfo] environment] objectForKey:@"V2RAYXS_APP_SUPPORT_PATH"];
    if (override.length > 0) {
        return override;
    }
    return [NSString stringWithFormat:@"%@/%@", NSHomeDirectory(), V2RayXSAppSupportRelativePath];
}

static NSURL* appSupportFileURL(NSString* filename) {
    if (filename.length == 0) {
        return nil;
    }
    return [NSURL fileURLWithPath:[NSString stringWithFormat:@"%@/%@", appSupportPath(), filename]];
}

static BOOL ensureAppSupportDirectory(void) {
    NSError* error = nil;
    if ([[NSFileManager defaultManager] createDirectoryAtPath:appSupportPath() withIntermediateDirectories:YES attributes:nil error:&error]) {
        return YES;
    }
    return error == nil;
}

static NSURL* routeBackupFileURL(void) {
    return appSupportFileURL(SystemRouteBackupFilename);
}

static NSURL* routeStoreFileURL(void) {
    return appSupportFileURL(RouteWhitelistStoreFilename);
}

static NSString* controlSocketPath(void) {
    return [[appSupportFileURL(TunControlSocketFilename) path] copy];
}

static NSString* tunSessionLockPath(void) {
    return [[appSupportFileURL(TunSessionLockFilename) path] copy];
}

static BOOL acquireTunSessionLock(NSString** errorMessage) {
    if (tunSessionLockFD != -1) {
        return YES;
    }
    ensureAppSupportDirectory();
    NSString* lockPath = tunSessionLockPath();
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
    NSString* lockPath = tunSessionLockPath();
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

static BOOL runNetworksetup(NSArray<NSString*>* arguments) {
    return [runTool(@"/usr/sbin/networksetup", arguments)[@"status"] intValue] == 0;
}

static BOOL setProxyFlag(NSMutableDictionary* proxies, NSString* key, BOOL enabled) {
    if (proxies == nil || key == nil) {
        return NO;
    }
    proxies[key] = @(enabled ? 1 : 0);
    return YES;
}

static void disableManualProxySettings(NSMutableDictionary* proxies) {
    setProxyFlag(proxies, (NSString *)kCFNetworkProxiesHTTPEnable, NO);
    setProxyFlag(proxies, (NSString *)kCFNetworkProxiesHTTPSEnable, NO);
    setProxyFlag(proxies, (NSString *)kCFNetworkProxiesProxyAutoConfigEnable, NO);
    setProxyFlag(proxies, (NSString *)kCFNetworkProxiesProxyAutoDiscoveryEnable, NO);
    setProxyFlag(proxies, (NSString *)kCFNetworkProxiesSOCKSEnable, NO);
    proxies[(NSString *)kCFNetworkProxiesProxyAutoConfigURLString] = @"";
}

static BOOL saveProxyBackup(NSDictionary* sets) {
    if (sets == nil) {
        return NO;
    }
    ensureAppSupportDirectory();
    return [sets writeToURL:appSupportFileURL(SystemProxyBackupFilename) atomically:NO];
}

static NSDictionary* loadProxyBackup(void) {
    return [NSDictionary dictionaryWithContentsOfURL:appSupportFileURL(SystemProxyBackupFilename)];
}

static BOOL isConfigurableProxyService(NSDictionary* service) {
    if (![service isKindOfClass:[NSDictionary class]]) {
        return NO;
    }
    NSDictionary* proxies = service[@"Proxies"];
    if (![proxies isKindOfClass:[NSDictionary class]]) {
        return NO;
    }
    NSString* serviceUserDefinedName = service[@"UserDefinedName"];
    return ![serviceUserDefinedName isEqualToString:@"V2RayXS"] && ![serviceUserDefinedName isEqualToString:@"V2RayX"];
}

static BOOL parseProxyPorts(const char* socksArg, const char* httpArg, int* localPort, int* httpPort) {
    int parsedLocalPort = 0;
    int parsedHttpPort = 0;
    if (sscanf(socksArg, "%i", &parsedLocalPort) != 1 || parsedLocalPort > 65535 || parsedLocalPort < 0) {
        return NO;
    }
    if (sscanf(httpArg, "%i", &parsedHttpPort) != 1 || parsedHttpPort > 65535 || parsedHttpPort < 0) {
        return NO;
    }
    if (localPort != NULL) {
        *localPort = parsedLocalPort;
    }
    if (httpPort != NULL) {
        *httpPort = parsedHttpPort;
    }
    return YES;
}

static void applyAutoProxySettings(NSMutableDictionary* proxies) {
    proxies[(NSString *)kCFNetworkProxiesProxyAutoConfigURLString] = @"http://127.0.0.1:8070/proxy.pac";
    setProxyFlag(proxies, (NSString *)kCFNetworkProxiesProxyAutoConfigEnable, YES);
}

static void applyGlobalProxySettings(NSMutableDictionary* proxies, int localPort, int httpPort) {
    if (localPort > 0) {
        proxies[(NSString *)kCFNetworkProxiesSOCKSProxy] = @"127.0.0.1";
        proxies[(NSString*)kCFNetworkProxiesSOCKSPort] = @(localPort);
        setProxyFlag(proxies, (NSString*)kCFNetworkProxiesSOCKSEnable, YES);
    }
    if (httpPort > 0) {
        proxies[(NSString *)kCFNetworkProxiesHTTPProxy] = @"127.0.0.1";
        proxies[(NSString *)kCFNetworkProxiesHTTPSProxy] = @"127.0.0.1";
        proxies[(NSString*)kCFNetworkProxiesHTTPPort] = @(httpPort);
        proxies[(NSString*)kCFNetworkProxiesHTTPSPort] = @(httpPort);
        setProxyFlag(proxies, (NSString*)kCFNetworkProxiesHTTPEnable, YES);
        setProxyFlag(proxies, (NSString*)kCFNetworkProxiesHTTPSEnable, YES);
    }
}

static void cleanupInactiveProxySettings(NSMutableDictionary* proxies, NSString* mode) {
    if (![mode isEqualToString:@"auto"]) {
        proxies[(NSString *)kCFNetworkProxiesProxyAutoConfigURLString] = @"";
    }
    if (![mode isEqualToString:@"global"]) {
        proxies[(NSString *)kCFNetworkProxiesSOCKSProxy] = @"";
        proxies[(NSString *)kCFNetworkProxiesSOCKSPort] = @0;
        proxies[(NSString *)kCFNetworkProxiesHTTPProxy] = @"";
        proxies[(NSString *)kCFNetworkProxiesHTTPSProxy] = @"";
        proxies[(NSString *)kCFNetworkProxiesHTTPPort] = @0;
        proxies[(NSString *)kCFNetworkProxiesHTTPSPort] = @0;
    }
}

static NSMutableDictionary* proxiesForMode(NSString* mode, NSDictionary* service, NSString* serviceID, NSDictionary* originalSets, int localPort, int httpPort) {
    NSMutableDictionary* proxies = [service[@"Proxies"] mutableCopy] ?: [[NSMutableDictionary alloc] init];
    disableManualProxySettings(proxies);
    if ([mode isEqualToString:@"restore"]) {
        NSDictionary* originalProxySettings = originalSets[serviceID][@"Proxies"];
        return originalProxySettings != nil ? [originalProxySettings mutableCopy] : proxies;
    }
    if ([mode isEqualToString:@"auto"]) {
        applyAutoProxySettings(proxies);
    } else if ([mode isEqualToString:@"global"]) {
        applyGlobalProxySettings(proxies, localPort, httpPort);
    }
    cleanupInactiveProxySettings(proxies, mode);
    return proxies;
}

static BOOL applyProxyModeToServices(SCPreferencesRef prefRef, NSDictionary* sets, NSString* mode, NSDictionary* originalSets, int localPort, int httpPort) {
    SCNetworkSetRef currentSet = SCNetworkSetCopyCurrent(prefRef);
    if (currentSet == NULL) {
        return NO;
    }
    NSArray* services = CFBridgingRelease(SCNetworkSetCopyServices(currentSet));
    CFRelease(currentSet);
    BOOL didApply = NO;
    for (id serviceObject in services) {
        SCNetworkServiceRef serviceRef = (__bridge SCNetworkServiceRef)serviceObject;
        if (serviceRef == NULL || !SCNetworkServiceGetEnabled(serviceRef)) {
            continue;
        }
        NSString* serviceID = (__bridge NSString*)SCNetworkServiceGetServiceID(serviceRef);
        NSDictionary* service = sets[serviceID];
        if (!isConfigurableProxyService(service)) {
            continue;
        }
        SCNetworkProtocolRef proxyProtocol = SCNetworkServiceCopyProtocol(serviceRef, kSCNetworkProtocolTypeProxies);
        if (proxyProtocol == NULL) {
            continue;
        }
        NSMutableDictionary* proxies = proxiesForMode(mode, service, serviceID, originalSets, localPort, httpPort);
        Boolean ok = SCNetworkProtocolSetConfiguration(proxyProtocol, (__bridge CFDictionaryRef)proxies);
        CFRelease(proxyProtocol);
        if (!ok) {
            return NO;
        }
        didApply = YES;
    }
    return didApply;
}

static BOOL createAuthorizedPreferences(SCPreferencesRef* prefRefOut) {
    if (prefRefOut == NULL) {
        return NO;
    }
    *prefRefOut = NULL;
    if (geteuid() == 0) {
        SCPreferencesRef prefRef = SCPreferencesCreate(NULL, CFSTR("V2RayXS"), NULL);
        if (prefRef == NULL) {
            return NO;
        }
        *prefRefOut = prefRef;
        return YES;
    }
    AuthorizationRef authRef = NULL;
    AuthorizationFlags authFlags = kAuthorizationFlagDefaults | kAuthorizationFlagExtendRights | kAuthorizationFlagInteractionAllowed | kAuthorizationFlagPreAuthorize;
    OSStatus authErr = AuthorizationCreate(nil, kAuthorizationEmptyEnvironment, authFlags, &authRef);
    if (authErr != noErr || authRef == NULL) {
        return NO;
    }
    SCPreferencesRef prefRef = SCPreferencesCreateWithAuthorization(nil, CFSTR("V2RayXS"), nil, authRef);
    if (prefRef == NULL) {
        return NO;
    }
    *prefRefOut = prefRef;
    return YES;
}

static BOOL configureNetworksetupProxyForService(NSString* serviceName, NSString* mode, int localPort, int httpPort) {
    if (serviceName.length == 0) {
        return NO;
    }
    BOOL ok = YES;
    ok = runNetworksetup(@[@"-setautoproxystate", serviceName, @"off"]) && ok;
    ok = runNetworksetup(@[@"-setwebproxystate", serviceName, @"off"]) && ok;
    ok = runNetworksetup(@[@"-setsecurewebproxystate", serviceName, @"off"]) && ok;
    ok = runNetworksetup(@[@"-setsocksfirewallproxystate", serviceName, @"off"]) && ok;
    if ([mode isEqualToString:@"auto"]) {
        ok = runNetworksetup(@[@"-setautoproxyurl", serviceName, @"http://127.0.0.1:8070/proxy.pac"]) && ok;
        ok = runNetworksetup(@[@"-setautoproxystate", serviceName, @"on"]) && ok;
        return ok;
    }
    if ([mode isEqualToString:@"global"]) {
        if (httpPort > 0) {
            NSString* httpPortString = [NSString stringWithFormat:@"%d", httpPort];
            ok = runNetworksetup(@[@"-setwebproxy", serviceName, @"127.0.0.1", httpPortString]) && ok;
            ok = runNetworksetup(@[@"-setsecurewebproxy", serviceName, @"127.0.0.1", httpPortString]) && ok;
            ok = runNetworksetup(@[@"-setwebproxystate", serviceName, @"on"]) && ok;
            ok = runNetworksetup(@[@"-setsecurewebproxystate", serviceName, @"on"]) && ok;
        }
        if (localPort > 0) {
            NSString* localPortString = [NSString stringWithFormat:@"%d", localPort];
            ok = runNetworksetup(@[@"-setsocksfirewallproxy", serviceName, @"127.0.0.1", localPortString]) && ok;
            ok = runNetworksetup(@[@"-setsocksfirewallproxystate", serviceName, @"on"]) && ok;
        }
    }
    return ok;
}

static BOOL applyDynamicProxyState(NSString* mode, int localPort, int httpPort) {
    SCPreferencesRef prefRef = SCPreferencesCreate(NULL, CFSTR("V2RayXS"), NULL);
    if (prefRef == NULL) {
        return NO;
    }
    SCNetworkSetRef currentSet = SCNetworkSetCopyCurrent(prefRef);
    if (currentSet == NULL) {
        CFRelease(prefRef);
        return NO;
    }
    NSArray* services = CFBridgingRelease(SCNetworkSetCopyServices(currentSet));
    CFRelease(currentSet);
    CFRelease(prefRef);
    BOOL didApply = NO;
    BOOL ok = YES;
    for (id serviceObject in services) {
        SCNetworkServiceRef serviceRef = (__bridge SCNetworkServiceRef)serviceObject;
        if (serviceRef == NULL || !SCNetworkServiceGetEnabled(serviceRef)) {
            continue;
        }
        NSString* serviceName = (__bridge NSString*)SCNetworkServiceGetName(serviceRef);
        if (serviceName.length == 0) {
            continue;
        }
        didApply = YES;
        ok = configureNetworksetupProxyForService(serviceName, mode, localPort, httpPort) && ok;
    }
    return didApply && ok;
}

static BOOL runProxySaveMode(void) {
    SCPreferencesRef prefRef = NULL;
    if (!createAuthorizedPreferences(&prefRef)) {
        return NO;
    }
    NSDictionary *sets = (__bridge NSDictionary *)SCPreferencesGetValue(prefRef, kSCPrefNetworkServices);
    BOOL ok = saveProxyBackup(sets);
    CFRelease(prefRef);
    return ok;
}

static BOOL applySystemProxyMode(NSString* mode, NSDictionary* originalSets, int localPort, int httpPort) {
    SCPreferencesRef prefRef = NULL;
    if (!createAuthorizedPreferences(&prefRef)) {
        return NO;
    }
    if (!SCPreferencesLock(prefRef, YES)) {
        CFRelease(prefRef);
        return NO;
    }
    NSDictionary* sets = (__bridge NSDictionary*)SCPreferencesGetValue(prefRef, kSCPrefNetworkServices);
    if (sets == nil || !applyProxyModeToServices(prefRef, sets, mode, originalSets, localPort, httpPort)) {
        SCPreferencesUnlock(prefRef);
        CFRelease(prefRef);
        return NO;
    }
    BOOL ok = SCPreferencesCommitChanges(prefRef) && SCPreferencesApplyChanges(prefRef);
    SCPreferencesSynchronize(prefRef);
    SCPreferencesUnlock(prefRef);
    CFRelease(prefRef);
    if (!ok) {
        return NO;
    }
    if (![mode isEqualToString:@"restore"]) {
        return applyDynamicProxyState(mode, localPort, httpPort);
    }
    return YES;
}

static NSMutableDictionary* loadRouteBackup(void) {
    NSMutableDictionary* backup = [NSMutableDictionary dictionaryWithContentsOfURL:routeBackupFileURL()] ?: [[NSMutableDictionary alloc] init];
    backup = sanitizeLegacyRouteBackup(backup);
    backup[ROUTE_BACKUP_VERSION_KEY] = @2;
    if (backup[ROUTE_BACKUP_STATE_KEY] == nil) {
        backup[ROUTE_BACKUP_STATE_KEY] = ROUTE_BACKUP_STATE_IDLE;
    }
    if (backup[ROUTE_BACKUP_TUN_NAME_KEY] == nil) {
        backup[ROUTE_BACKUP_TUN_NAME_KEY] = @"";
    }
    if (backup[ROUTE_BACKUP_DEFAULT_GATEWAY_V4_KEY] == nil) {
        backup[ROUTE_BACKUP_DEFAULT_GATEWAY_V4_KEY] = @"";
    }
    if (backup[ROUTE_BACKUP_DEFAULT_GATEWAY_V6_KEY] == nil) {
        backup[ROUTE_BACKUP_DEFAULT_GATEWAY_V6_KEY] = @"";
    }
    if (backup[ROUTE_BACKUP_DEFAULT_INTERFACE_V4_KEY] == nil) {
        backup[ROUTE_BACKUP_DEFAULT_INTERFACE_V4_KEY] = @"";
    }
    if (backup[ROUTE_BACKUP_DEFAULT_INTERFACE_V6_KEY] == nil) {
        backup[ROUTE_BACKUP_DEFAULT_INTERFACE_V6_KEY] = @"";
    }
    if (backup[ROUTE_BACKUP_WHITELIST_ROUTES_KEY] == nil) {
        backup[ROUTE_BACKUP_WHITELIST_ROUTES_KEY] = @[];
    }
    if (backup[ROUTE_BACKUP_IPV4_TAKEOVER_ROUTES_KEY] == nil) {
        backup[ROUTE_BACKUP_IPV4_TAKEOVER_ROUTES_KEY] = @[];
    }
    if (backup[ROUTE_BACKUP_LAST_ERROR_KEY] == nil) {
        backup[ROUTE_BACKUP_LAST_ERROR_KEY] = @"";
    }
    if (backup[ROUTE_BACKUP_SESSION_TYPE_KEY] == nil) {
        backup[ROUTE_BACKUP_SESSION_TYPE_KEY] = SESSION_TYPE_NONE;
    }
    if (backup[ROUTE_BACKUP_SESSION_OWNER_KEY] == nil) {
        backup[ROUTE_BACKUP_SESSION_OWNER_KEY] = SESSION_OWNER_NONE;
    }
    if (backup[ROUTE_BACKUP_CONTROL_PLANE_KEY] == nil) {
        backup[ROUTE_BACKUP_CONTROL_PLANE_KEY] = CONTROL_PLANE_NONE;
    }
    return backup;
}

static BOOL saveRouteBackup(NSMutableDictionary* backup) {
    ensureAppSupportDirectory();
    backup = sanitizeLegacyRouteBackup(backup);
    return [backup writeToURL:routeBackupFileURL() atomically:NO];
}

static NSMutableDictionary* sanitizeLegacyRouteBackup(NSMutableDictionary* backup) {
    if (backup == nil) {
        return [[NSMutableDictionary alloc] init];
    }

    id legacyDefaultGateway = backup[@"DefaultRouteGateway"];
    if (![backup[ROUTE_BACKUP_DEFAULT_GATEWAY_V4_KEY] isKindOfClass:[NSString class]] || [backup[ROUTE_BACKUP_DEFAULT_GATEWAY_V4_KEY] length] == 0) {
        if ([legacyDefaultGateway isKindOfClass:[NSString class]] && [legacyDefaultGateway length] > 0) {
            backup[ROUTE_BACKUP_DEFAULT_GATEWAY_V4_KEY] = legacyDefaultGateway;
        }
    }

    NSArray<NSString*>* legacyKeys = @[@"DefaultRouteGateway", @"DefaultRouteSwitched"];
    for (NSString* key in legacyKeys) {
        [backup removeObjectForKey:key];
    }

    return backup;
}

static NSMutableDictionary* loadRouteStore(void) {
    NSMutableDictionary* store = [NSMutableDictionary dictionaryWithContentsOfURL:routeStoreFileURL()] ?: [[NSMutableDictionary alloc] init];
    store[ROUTE_STORE_VERSION_KEY] = @1;
    if (store[ROUTE_STORE_ENTRIES_KEY] == nil) {
        store[ROUTE_STORE_ENTRIES_KEY] = @[];
    }
    return store;
}

static BOOL saveRouteStore(NSDictionary* store) {
    ensureAppSupportDirectory();
    return [store writeToURL:routeStoreFileURL() atomically:NO];
}

static NSString* familyStringForFamily(SYSRouteAddressFamily family) {
    return family == SYSRouteAddressFamilyIPv6 ? @"ipv6" : @"ipv4";
}

static SYSRouteAddressFamily familyFromString(NSString* familyString) {
    return [familyString isEqualToString:@"ipv6"] ? SYSRouteAddressFamilyIPv6 : SYSRouteAddressFamilyIPv4;
}

static NSString* normalizedIPAddressString(NSString* ipAddress, SYSRouteAddressFamily family) {
    if (ipAddress.length == 0) {
        return nil;
    }
    char buffer[INET6_ADDRSTRLEN] = {0};
    if (family == SYSRouteAddressFamilyIPv4) {
        struct in_addr ipv4Addr;
        if (inet_pton(AF_INET, [ipAddress UTF8String], &ipv4Addr) != 1) {
            return nil;
        }
        if (inet_ntop(AF_INET, &ipv4Addr, buffer, sizeof(buffer)) == NULL) {
            return nil;
        }
    } else {
        struct in6_addr ipv6Addr;
        if (inet_pton(AF_INET6, [ipAddress UTF8String], &ipv6Addr) != 1) {
            return nil;
        }
        if (inet_ntop(AF_INET6, &ipv6Addr, buffer, sizeof(buffer)) == NULL) {
            return nil;
        }
    }
    return [NSString stringWithUTF8String:buffer];
}

static NSArray<NSDictionary*>* normalizedEntriesFromArray(NSArray* rawEntries, NSArray<NSString*>** invalidItems) {
    NSMutableArray<NSDictionary*>* entries = [[NSMutableArray alloc] init];
    NSMutableArray<NSString*>* invalid = [[NSMutableArray alloc] init];
    NSMutableSet<NSString*>* seenKeys = [[NSMutableSet alloc] init];
    for (id item in rawEntries) {
        NSString* ipAddress = nil;
        NSString* familyString = nil;
        if ([item isKindOfClass:[NSString class]]) {
            ipAddress = item;
        } else if ([item isKindOfClass:[NSDictionary class]]) {
            ipAddress = item[ENTRY_IP_KEY];
            familyString = item[ENTRY_FAMILY_KEY];
        }
        SYSRouteAddressFamily family = SYSRouteAddressFamilyIPv4;
        if (familyString.length > 0) {
            family = familyFromString(familyString);
        } else {
            SYSRouteAddressFamily detectedFamily = SYSRouteAddressFamilyIPv4;
            if (![routeHelper isValidIPAddress:ipAddress family:&detectedFamily]) {
                [invalid addObject:(ipAddress ?: @"<invalid>")];
                continue;
            }
            family = detectedFamily;
        }
        NSString* normalizedIP = normalizedIPAddressString(ipAddress, family);
        if (normalizedIP.length == 0) {
            [invalid addObject:(ipAddress ?: @"<invalid>")];
            continue;
        }
        NSDictionary* entry = @{
            ENTRY_IP_KEY: normalizedIP,
            ENTRY_FAMILY_KEY: familyStringForFamily(family),
            ENTRY_ENABLED_KEY: @YES,
        };
        NSString* key = routeKeyForEntry(entry);
        if ([seenKeys containsObject:key]) {
            continue;
        }
        [seenKeys addObject:key];
        [entries addObject:entry];
    }
    if (invalidItems != NULL) {
        *invalidItems = invalid;
    }
    return entries;
}

static NSString* routeKeyForEntry(NSDictionary* entry) {
    return [NSString stringWithFormat:@"%@:%@", entry[ENTRY_FAMILY_KEY] ?: @"ipv4", entry[ENTRY_IP_KEY] ?: @""];
}

static NSArray<NSDictionary*>* storeEntries(void) {
    return [loadRouteStore()[ROUTE_STORE_ENTRIES_KEY] copy] ?: @[];
}

static BOOL replaceStoreEntries(NSArray<NSDictionary*>* entries) {
    NSMutableDictionary* store = loadRouteStore();
    store[ROUTE_STORE_ENTRIES_KEY] = entries ?: @[];
    return saveRouteStore(store);
}

static NSDictionary* addEntriesToStore(NSArray<NSDictionary*>* entries) {
    NSMutableArray<NSDictionary*>* mergedEntries = [[storeEntries() mutableCopy] ?: [NSMutableArray array] mutableCopy];
    NSMutableSet<NSString*>* existingKeys = [[NSMutableSet alloc] init];
    for (NSDictionary* entry in mergedEntries) {
        [existingKeys addObject:routeKeyForEntry(entry)];
    }
    NSMutableArray* added = [[NSMutableArray alloc] init];
    for (NSDictionary* entry in entries) {
        NSString* key = routeKeyForEntry(entry);
        if ([existingKeys containsObject:key]) {
            continue;
        }
        [existingKeys addObject:key];
        [mergedEntries addObject:entry];
        [added addObject:entry];
    }
    if (!replaceStoreEntries(mergedEntries)) {
        return makeResponse(NO, @"Failed to update route whitelist store.", nil);
    }
    return makeResponse(YES, @"Routes added to whitelist store.", @{@"persisted": added, @"entries": mergedEntries});
}

static NSDictionary* removeEntriesFromStore(NSArray<NSDictionary*>* entries) {
    NSMutableSet<NSString*>* keysToRemove = [[NSMutableSet alloc] init];
    for (NSDictionary* entry in entries) {
        [keysToRemove addObject:routeKeyForEntry(entry)];
    }
    NSMutableArray<NSDictionary*>* updatedEntries = [[NSMutableArray alloc] init];
    NSMutableArray<NSDictionary*>* removed = [[NSMutableArray alloc] init];
    for (NSDictionary* entry in storeEntries()) {
        if ([keysToRemove containsObject:routeKeyForEntry(entry)]) {
            [removed addObject:entry];
        } else {
            [updatedEntries addObject:entry];
        }
    }
    if (!replaceStoreEntries(updatedEntries)) {
        return makeResponse(NO, @"Failed to update route whitelist store.", nil);
    }
    return makeResponse(YES, @"Routes removed from whitelist store.", @{@"removed": removed, @"entries": updatedEntries});
}

static NSDictionary* clearStoreEntries(void) {
    NSArray<NSDictionary*>* previousEntries = storeEntries();
    if (!replaceStoreEntries(@[])) {
        return makeResponse(NO, @"Failed to clear route whitelist store.", nil);
    }
    return makeResponse(YES, @"Route whitelist store cleared.", @{@"removed": previousEntries});
}

static NSArray<NSDictionary*>* activeIPv4TakeoverRouteEntries(void) {
    if (activeIPv4TakeoverRoutes != nil) {
        return [activeIPv4TakeoverRoutes copy];
    }
    NSArray* storedEntries = loadRouteBackup()[ROUTE_BACKUP_IPV4_TAKEOVER_ROUTES_KEY];
    return [storedEntries isKindOfClass:[NSArray class]] ? storedEntries : @[];
}

static void updateRouteBackupTakeoverRoutes(NSMutableDictionary* backup) {
    if (backup == nil) {
        return;
    }
    backup[ROUTE_BACKUP_IPV4_TAKEOVER_ROUTES_KEY] = activeIPv4TakeoverRoutes != nil ? [activeIPv4TakeoverRoutes copy] : @[];
}

static NSDictionary* tunStatusPayload(void) {
    NSMutableDictionary* backup = loadRouteBackup();
    NSArray* persistedEntries = storeEntries();
    BOOL socketAvailable = access([controlSocketPath() fileSystemRepresentation], F_OK) == 0;
    NSUInteger appliedCount = activeWhitelistRoutes != nil ? [activeWhitelistRoutes count] : [backup[ROUTE_BACKUP_WHITELIST_ROUTES_KEY] count];
    NSString* state = currentSessionState();
    NSString* tunName = activeTunName.length > 0 ? activeTunName : (backup[ROUTE_BACKUP_TUN_NAME_KEY] ?: @"");
    BOOL tunExists = NO;
    BOOL tunUp = NO;
    if (tunName.length > 0) {
        NSDictionary* taskResult = runTool(@"/sbin/ifconfig", @[tunName]);
        NSString* ifconfigOutput = taskResult[@"stdout"] ?: @"";
        tunExists = [taskResult[@"status"] intValue] == 0;
        tunUp = tunExists && [ifconfigOutput containsString:@"<UP,"];
    }
    NSArray* activeTakeoverEntries = activeIPv4TakeoverRouteEntries();
    return @{
        @"sessionType": currentSessionType(),
        @"sessionOwner": currentSessionOwner(),
        @"controlPlane": currentControlPlane(),
        @"session": state,
        @"socket": socketAvailable ? @"available" : @"unavailable",
        @"tunName": tunName,
        @"tunExists": @(tunExists),
        @"tunUp": @(tunUp),
        @"defaultGatewayV4": defaultRouteGatewayV4.length > 0 ? defaultRouteGatewayV4 : (backup[ROUTE_BACKUP_DEFAULT_GATEWAY_V4_KEY] ?: @""),
        @"defaultGatewayV6": defaultRouteGatewayV6.length > 0 ? defaultRouteGatewayV6 : (backup[ROUTE_BACKUP_DEFAULT_GATEWAY_V6_KEY] ?: @""),
        @"defaultInterfaceV4": defaultRouteInterfaceV4.length > 0 ? defaultRouteInterfaceV4 : (backup[ROUTE_BACKUP_DEFAULT_INTERFACE_V4_KEY] ?: @""),
        @"defaultInterfaceV6": defaultRouteInterfaceV6.length > 0 ? defaultRouteInterfaceV6 : (backup[ROUTE_BACKUP_DEFAULT_INTERFACE_V6_KEY] ?: @""),
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
        @"session": currentSessionState(),
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
    hydrateBaselineRuntimeFromBackup(backup);
    backup[ROUTE_BACKUP_STATE_KEY] = state ?: ROUTE_BACKUP_STATE_IDLE;
    backup[ROUTE_BACKUP_TUN_NAME_KEY] = activeTunName ?: @"";
    backup[ROUTE_BACKUP_DEFAULT_GATEWAY_V4_KEY] = defaultRouteGatewayV4 ?: @"";
    backup[ROUTE_BACKUP_DEFAULT_GATEWAY_V6_KEY] = defaultRouteGatewayV6 ?: @"";
    backup[ROUTE_BACKUP_DEFAULT_INTERFACE_V4_KEY] = defaultRouteInterfaceV4 ?: @"";
    backup[ROUTE_BACKUP_DEFAULT_INTERFACE_V6_KEY] = defaultRouteInterfaceV6 ?: @"";
    backup[ROUTE_BACKUP_LAST_ERROR_KEY] = lastError ?: @"";
    if (activeTunName.length == 0) {
        backup[ROUTE_BACKUP_SESSION_TYPE_KEY] = SESSION_TYPE_NONE;
        backup[ROUTE_BACKUP_SESSION_OWNER_KEY] = SESSION_OWNER_NONE;
        backup[ROUTE_BACKUP_CONTROL_PLANE_KEY] = CONTROL_PLANE_NONE;
    }
    updateRouteBackupRoutes(backup);
    updateRouteBackupTakeoverRoutes(backup);
    saveRouteBackup(backup);
}

static void hydrateBaselineRuntimeFromBackup(NSMutableDictionary* backup) {
    if (backup == nil) {
        return;
    }
    NSString* storedGatewayV4 = [backup[ROUTE_BACKUP_DEFAULT_GATEWAY_V4_KEY] isKindOfClass:[NSString class]] ? backup[ROUTE_BACKUP_DEFAULT_GATEWAY_V4_KEY] : @"";
    NSString* storedInterfaceV4 = [backup[ROUTE_BACKUP_DEFAULT_INTERFACE_V4_KEY] isKindOfClass:[NSString class]] ? backup[ROUTE_BACKUP_DEFAULT_INTERFACE_V4_KEY] : @"";
    NSString* storedGatewayV6 = [backup[ROUTE_BACKUP_DEFAULT_GATEWAY_V6_KEY] isKindOfClass:[NSString class]] ? backup[ROUTE_BACKUP_DEFAULT_GATEWAY_V6_KEY] : @"";
    NSString* storedInterfaceV6 = [backup[ROUTE_BACKUP_DEFAULT_INTERFACE_V6_KEY] isKindOfClass:[NSString class]] ? backup[ROUTE_BACKUP_DEFAULT_INTERFACE_V6_KEY] : @"";

    if (defaultRouteGatewayV4.length == 0 && storedGatewayV4.length > 0) {
        defaultRouteGatewayV4 = storedGatewayV4;
    }
    if (defaultRouteInterfaceV4.length == 0 && storedInterfaceV4.length > 0) {
        defaultRouteInterfaceV4 = storedInterfaceV4;
    }
    if (defaultRouteGatewayV6.length == 0 && storedGatewayV6.length > 0) {
        defaultRouteGatewayV6 = storedGatewayV6;
    }
    if (defaultRouteInterfaceV6.length == 0 && storedInterfaceV6.length > 0) {
        defaultRouteInterfaceV6 = storedInterfaceV6;
    }
}

static BOOL applyWhitelistEntries(NSArray<NSDictionary*>* entries, NSMutableArray* appliedEntries, NSMutableArray* failedEntries) {
    if (entries.count == 0) {
        return YES;
    }
    for (NSDictionary* entry in entries) {
        SYSRouteAddressFamily family = familyFromString(entry[ENTRY_FAMILY_KEY]);
        NSString* gateway = family == SYSRouteAddressFamilyIPv6 ? defaultRouteGatewayV6 : defaultRouteGatewayV4;
        NSString* routeInterface = family == SYSRouteAddressFamilyIPv6 ? defaultRouteInterfaceV6 : defaultRouteInterfaceV4;
        if (family == SYSRouteAddressFamilyIPv6 && routeInterface.length == 0 && defaultRouteInterfaceV4.length > 0) {
            routeInterface = defaultRouteInterfaceV4;
        }
        BOOL didApply = NO;
        if (gateway.length > 0) {
            didApply = [routeHelper addHostRouteToDestination:entry[ENTRY_IP_KEY] gateway:gateway family:family];
        } else if (routeInterface.length > 0) {
            didApply = [routeHelper addHostRouteToDestination:entry[ENTRY_IP_KEY] interface:routeInterface family:family];
        } else {
            NSString* reason = family == SYSRouteAddressFamilyIPv6 ? @"missing IPv6 baseline gateway/interface" : @"missing IPv4 baseline gateway/interface";
            [failedEntries addObject:@{ENTRY_IP_KEY: entry[ENTRY_IP_KEY] ?: @"", @"reason": reason, ENTRY_FAMILY_KEY: entry[ENTRY_FAMILY_KEY] ?: @""}];
            continue;
        }
        if (!didApply) {
            [failedEntries addObject:@{ENTRY_IP_KEY: entry[ENTRY_IP_KEY] ?: @"", @"reason": @"failed to add route", ENTRY_FAMILY_KEY: entry[ENTRY_FAMILY_KEY] ?: @""}];
            continue;
        }
        NSMutableDictionary* appliedEntry = [entry mutableCopy];
        if (gateway.length > 0) {
            appliedEntry[ENTRY_GATEWAY_KEY] = gateway;
        }
        if (routeInterface.length > 0) {
            appliedEntry[ENTRY_INTERFACE_KEY] = routeInterface;
        }
        appliedEntry[ENTRY_APPLIED_KEY] = @YES;
        if (activeWhitelistRoutes == nil) {
            activeWhitelistRoutes = [[NSMutableDictionary alloc] init];
        }
        activeWhitelistRoutes[routeKeyForEntry(entry)] = appliedEntry;
        [appliedEntries addObject:appliedEntry];
    }
    return [failedEntries count] == 0;
}

static BOOL removeWhitelistEntries(NSArray<NSDictionary*>* entries, NSMutableArray* removedEntries, NSMutableArray* failedEntries) {
    for (NSDictionary* entry in entries) {
        NSDictionary* activeEntry = activeWhitelistRoutes[routeKeyForEntry(entry)];
        if (activeEntry == nil) {
            continue;
        }
        SYSRouteAddressFamily family = familyFromString(activeEntry[ENTRY_FAMILY_KEY]);
        NSString* gateway = activeEntry[ENTRY_GATEWAY_KEY];
        NSString* routeInterface = activeEntry[ENTRY_INTERFACE_KEY];
        BOOL deleted = NO;
        if ([gateway isKindOfClass:[NSString class]] && gateway.length > 0) {
            deleted = [routeHelper deleteHostRouteToDestination:activeEntry[ENTRY_IP_KEY] gateway:gateway family:family];
        } else if ([routeInterface isKindOfClass:[NSString class]] && routeInterface.length > 0) {
            deleted = [routeHelper deleteHostRouteToDestination:activeEntry[ENTRY_IP_KEY] interface:routeInterface family:family];
        }
        if (!deleted) {
            [failedEntries addObject:@{ENTRY_IP_KEY: activeEntry[ENTRY_IP_KEY] ?: @"", @"reason": @"failed to delete route"}];
            continue;
        }
        [activeWhitelistRoutes removeObjectForKey:routeKeyForEntry(entry)];
        [removedEntries addObject:activeEntry];
    }
    return [failedEntries count] == 0;
}

static NSDictionary* syncActiveWhitelistWithEntries(NSArray<NSDictionary*>* entries, BOOL replaceExisting) {
    if (activeWhitelistRoutes == nil) {
        activeWhitelistRoutes = [[NSMutableDictionary alloc] init];
    }
    NSMutableArray* removed = [[NSMutableArray alloc] init];
    NSMutableArray* applied = [[NSMutableArray alloc] init];
    NSMutableArray* failed = [[NSMutableArray alloc] init];
    if (replaceExisting) {
        NSMutableSet<NSString*>* desiredKeys = [[NSMutableSet alloc] init];
        for (NSDictionary* entry in entries) {
            [desiredKeys addObject:routeKeyForEntry(entry)];
        }
        NSMutableArray<NSDictionary*>* staleEntries = [[NSMutableArray alloc] init];
        for (NSDictionary* activeEntry in [activeWhitelistRoutes allValues]) {
            if (![desiredKeys containsObject:routeKeyForEntry(activeEntry)]) {
                [staleEntries addObject:activeEntry];
            }
        }
        removeWhitelistEntries(staleEntries, removed, failed);
    }
    NSMutableArray<NSDictionary*>* newEntries = [[NSMutableArray alloc] init];
    for (NSDictionary* entry in entries) {
        if (activeWhitelistRoutes[routeKeyForEntry(entry)] == nil) {
            [newEntries addObject:entry];
        }
    }
    applyWhitelistEntries(newEntries, applied, failed);
    NSMutableDictionary* backup = loadRouteBackup();
    updateRouteBackupState(backup, activeTunName.length > 0 ? ROUTE_BACKUP_STATE_ACTIVE : ROUTE_BACKUP_STATE_IDLE, failed.count > 0 ? @"whitelist sync failed" : @"");
    return makeResponse([failed count] == 0, [failed count] == 0 ? @"Whitelist synchronized." : @"Whitelist synchronization completed with failures.", @{@"applied": applied, @"removed": removed, @"failed": failed, @"active": [activeWhitelistRoutes allValues] ?: @[]});
}

static NSDictionary* stopTunSession(void) {
    syncRuntimeSessionFromBackup();
    NSString* lockError = nil;
    if (!acquireTunSessionLock(&lockError)) {
        return makeResponse(NO, lockError ?: @"Another tun session operation is already in progress.", nil);
    }
    NSMutableArray* removedEntries = [[NSMutableArray alloc] init];
    NSMutableArray* failedEntries = [[NSMutableArray alloc] init];
    if (activeWhitelistRoutes != nil) {
        removeWhitelistEntries([activeWhitelistRoutes allValues], removedEntries, failedEntries);
    }
    NSMutableDictionary* backup = loadRouteBackup();
    NSString* routeError = nil;
    BOOL removedTakeover = removeIPv4TakeoverRoutes(activeTunName, &routeError);
    resetTunRuntimeState(backup, ROUTE_BACKUP_STATE_IDLE, @"");
    BOOL restored = YES;
    if (controlServerSocketFD != -1) {
        close(controlServerSocketFD);
        controlServerSocketFD = -1;
    }
    unlink([controlSocketPath() fileSystemRepresentation]);
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

    NSDictionary* payload = @{
        @"tunName": actualTunName ?: @"",
    };
    NSData* payloadData = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    NSString* payloadString = [[NSString alloc] initWithData:payloadData encoding:NSUTF8StringEncoding] ?: @"{}";
    if (!sendFileDescriptor(sendSocketFD, tunFD, payloadString)) {
        close(tunFD);
        return makeResponse(NO, @"Failed to send tun fd to caller.", nil);
    }

    close(tunFD);
    return makeResponse(YES, @"Tun fd prepared.", @{@"tunName": actualTunName ?: @""});
}

static NSDictionary* deactivateExternalTunSession(NSString* expectedTunName) {
    syncRuntimeSessionFromBackup();
    if (expectedTunName.length > 0 && activeTunName.length > 0 && ![expectedTunName isEqualToString:activeTunName]) {
        return makeResponse(NO, @"Requested tun name does not match active external tun session.", nil);
    }
    return stopTunSession();
}

static BOOL startControlSocketServer(NSString** errorMessage) {
    ensureAppSupportDirectory();
    NSString* socketPath = controlSocketPath();
    unlink([socketPath fileSystemRepresentation]);
    int serverFD = socket(AF_UNIX, SOCK_STREAM, 0);
    if (serverFD == -1) {
        if (errorMessage != NULL) {
            *errorMessage = @"Failed to create control socket.";
        }
        return NO;
    }
    struct sockaddr_un address;
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    strncpy(address.sun_path, [socketPath fileSystemRepresentation], sizeof(address.sun_path) - 1);
    if (bind(serverFD, (struct sockaddr*)&address, sizeof(address)) != 0) {
        close(serverFD);
        if (errorMessage != NULL) {
            *errorMessage = @"Failed to bind control socket.";
        }
        return NO;
    }
    chmod([socketPath fileSystemRepresentation], 0600);
    if (listen(serverFD, 8) != 0) {
        close(serverFD);
        if (errorMessage != NULL) {
            *errorMessage = @"Failed to listen on control socket.";
        }
        return NO;
    }
    controlServerSocketFD = serverFD;
    return YES;
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
        return syncActiveWhitelistWithEntries(entries ?: @[], YES);
    }
    if ([command isEqualToString:@"route-add"]) {
        return syncActiveWhitelistWithEntries(entries ?: @[], NO);
    }
    if ([command isEqualToString:@"route-del"]) {
        NSMutableArray* removed = [[NSMutableArray alloc] init];
        NSMutableArray* failed = [[NSMutableArray alloc] init];
        removeWhitelistEntries(entries ?: @[], removed, failed);
        NSMutableDictionary* backup = loadRouteBackup();
        updateRouteBackupState(backup, activeTunName.length > 0 ? ROUTE_BACKUP_STATE_ACTIVE : ROUTE_BACKUP_STATE_IDLE, failed.count > 0 ? @"route delete failed" : @"");
        return makeResponse(failed.count == 0, failed.count == 0 ? @"Routes removed from active whitelist." : @"Failed to remove some active routes.", @{@"removed": removed, @"failed": failed, @"active": [activeWhitelistRoutes allValues] ?: @[]});
    }
    if ([command isEqualToString:@"route-clear"]) {
        NSMutableArray* removed = [[NSMutableArray alloc] init];
        NSMutableArray* failed = [[NSMutableArray alloc] init];
        removeWhitelistEntries([activeWhitelistRoutes allValues] ?: @[], removed, failed);
        NSMutableDictionary* backup = loadRouteBackup();
        updateRouteBackupState(backup, activeTunName.length > 0 ? ROUTE_BACKUP_STATE_ACTIVE : ROUTE_BACKUP_STATE_IDLE, failed.count > 0 ? @"route clear failed" : @"");
        return makeResponse(failed.count == 0, failed.count == 0 ? @"Active whitelist cleared." : @"Failed to clear active whitelist.", @{@"removed": removed, @"failed": failed});
    }
    if ([command isEqualToString:@"stop"]) {
        return stopTunSession();
    }
    return makeResponse(NO, @"Unknown server command.", nil);
}

static void controlSocketAcceptLoop(void) {
    while (runLoopMark && controlServerSocketFD != -1) {
        int clientFD = accept(controlServerSocketFD, NULL, NULL);
        if (clientFD == -1) {
            continue;
        }
        NSMutableData* inputData = [[NSMutableData alloc] init];
        uint8_t buffer[4096];
        ssize_t bytesRead = 0;
        while ((bytesRead = read(clientFD, buffer, sizeof(buffer))) > 0) {
            [inputData appendBytes:buffer length:(NSUInteger)bytesRead];
        }
        NSDictionary* request = nil;
        if (inputData.length > 0) {
            request = [NSJSONSerialization JSONObjectWithData:inputData options:0 error:nil];
        }
        NSDictionary* response = processServerRequest(request ?: @{});
        NSData* responseData = [NSJSONSerialization dataWithJSONObject:response options:0 error:nil];
        if (responseData != nil) {
            write(clientFD, [responseData bytes], [responseData length]);
        }
        close(clientFD);
    }
}

static NSDictionary* sendRequestToControlServer(NSDictionary* request, NSString** errorMessage) {
    int clientFD = socket(AF_UNIX, SOCK_STREAM, 0);
    if (clientFD == -1) {
        if (errorMessage != NULL) {
            *errorMessage = @"Failed to create client socket.";
        }
        return nil;
    }
    struct sockaddr_un address;
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    NSString* socketPath = controlSocketPath();
    strncpy(address.sun_path, [socketPath fileSystemRepresentation], sizeof(address.sun_path) - 1);
    if (connect(clientFD, (struct sockaddr*)&address, sizeof(address)) != 0) {
        close(clientFD);
        if (errorMessage != NULL) {
            *errorMessage = @"No active tun session.";
        }
        return nil;
    }
    NSData* requestData = [NSJSONSerialization dataWithJSONObject:request options:0 error:nil];
    if (requestData == nil || write(clientFD, [requestData bytes], [requestData length]) < 0) {
        close(clientFD);
        if (errorMessage != NULL) {
            *errorMessage = @"Failed to send request to tun session.";
        }
        return nil;
    }
    shutdown(clientFD, SHUT_WR);
    NSMutableData* responseData = [[NSMutableData alloc] init];
    uint8_t buffer[4096];
    ssize_t bytesRead = 0;
    while ((bytesRead = read(clientFD, buffer, sizeof(buffer))) > 0) {
        [responseData appendBytes:buffer length:(NSUInteger)bytesRead];
    }
    close(clientFD);
    NSDictionary* response = responseData.length > 0 ? [NSJSONSerialization JSONObjectWithData:responseData options:0 error:nil] : nil;
    if (response == nil && errorMessage != NULL) {
        *errorMessage = @"Failed to decode tun session response.";
    }
    return response;
}

static NSDictionary* requestActiveSession(NSDictionary* request) {
    NSString* errorMessage = nil;
    NSDictionary* response = sendRequestToControlServer(request, &errorMessage);
    if (response == nil) {
        if (isExternalFDSession()) {
            return makeResponse(NO, errorMessage ?: @"No active control socket for external tun session.", nil);
        }
        NSString* sessionState = currentSessionState();
        if (![sessionState isEqualToString:@"inactive"]) {
            return makeResponse(YES, @"Tun session state available from backup but control socket is unavailable.", tunStatusPayload());
        }
        return makeResponse(NO, errorMessage ?: @"Failed to contact tun session.", nil);
    }
    return response;
}

static BOOL canTreatSessionAsActiveResponse(NSDictionary* response) {
    if (![response[@"ok"] boolValue]) {
        return NO;
    }
    NSString* session = response[@"session"];
    return [session isKindOfClass:[NSString class]] && ![session isEqualToString:@"inactive"];
}

static NSString* currentSessionType(void) {
    NSMutableDictionary* backup = loadRouteBackup();
    NSString* value = backup[ROUTE_BACKUP_SESSION_TYPE_KEY];
    return [value isKindOfClass:[NSString class]] && value.length > 0 ? value : SESSION_TYPE_NONE;
}

static NSString* currentSessionOwner(void) {
    NSMutableDictionary* backup = loadRouteBackup();
    NSString* value = backup[ROUTE_BACKUP_SESSION_OWNER_KEY];
    return [value isKindOfClass:[NSString class]] && value.length > 0 ? value : SESSION_OWNER_NONE;
}

static NSString* currentControlPlane(void) {
    NSMutableDictionary* backup = loadRouteBackup();
    NSString* value = backup[ROUTE_BACKUP_CONTROL_PLANE_KEY];
    return [value isKindOfClass:[NSString class]] && value.length > 0 ? value : CONTROL_PLANE_NONE;
}

static BOOL isExternalFDSession(void) {
    return [currentSessionType() isEqualToString:SESSION_TYPE_EXTERNAL_FD];
}

static BOOL setupTunSession(int localProxyPort, NSString** errorMessage) {
    if (!acquireTunSessionLock(errorMessage)) {
        return NO;
    }
    syncRuntimeSessionFromBackup();
    if (![currentSessionState() isEqualToString:@"inactive"]) {
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
    if (!loadDefaultRouteBaseline(errorMessage)) {
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
    if (!installIPv4TakeoverRoutes(activeTunName, backup, errorMessage)) {
        resetTunRuntimeState(backup, ROUTE_BACKUP_STATE_IDLE, @"");
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
    syncRuntimeSessionFromBackup();
    if (![currentSessionState() isEqualToString:@"inactive"]) {
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
    if (!loadDefaultRouteBaseline(errorMessage)) {
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
    if (!installIPv4TakeoverRoutes(activeTunName, backup, errorMessage)) {
        resetTunRuntimeState(backup, ROUTE_BACKUP_STATE_IDLE, @"");
        activeTunName = @"";
        releaseTunSessionLock();
        return NO;
    }
    updateRouteBackupState(backup, ROUTE_BACKUP_STATE_ACTIVE, @"");
    backup[ROUTE_BACKUP_SESSION_TYPE_KEY] = SESSION_TYPE_EXTERNAL_FD;
    backup[ROUTE_BACKUP_SESSION_OWNER_KEY] = SESSION_OWNER_EXTERNAL;
    backup[ROUTE_BACKUP_CONTROL_PLANE_KEY] = CONTROL_PLANE_STATELESS;
    saveRouteBackup(backup);
    NSDictionary* syncResponse = syncActiveWhitelistWithEntries(storeEntries(), YES);
    if (![syncResponse[@"ok"] boolValue]) {
        if (errorMessage != NULL) {
            *errorMessage = syncResponse[@"message"] ?: @"Failed to synchronize whitelist routes.";
        }
        releaseTunSessionLock();
        return NO;
    }
    return YES;
}

static BOOL loadDefaultRouteBaseline(NSString** errorMessage) {
    syncRuntimeSessionFromBackup();
    NSDictionary* preferredDefaultRouteV4 = preferredNonTunDefaultRoute();
    defaultRouteGatewayV4 = preferredDefaultRouteV4[@"gateway"] ?: @"";
    defaultRouteGatewayV6 = [routeHelper getDefaultRouteGatewayForFamily:SYSRouteAddressFamilyIPv6] ?: @"";
    defaultRouteInterfaceV4 = preferredDefaultRouteV4[@"interface"] ?: @"";
    defaultRouteInterfaceV6 = [routeHelper getDefaultRouteInterfaceForFamily:SYSRouteAddressFamilyIPv6] ?: @"";

    if (isTunManagedIPv4Route(defaultRouteGatewayV4, defaultRouteInterfaceV4)) {
        defaultRouteGatewayV4 = @"";
        defaultRouteInterfaceV4 = @"";
    }

    if (![routeHelper isValidGateway:defaultRouteGatewayV4]) {
        defaultRouteGatewayV4 = @"";
    }

    if (!hasUsableIPv4Baseline()) {
        syncRuntimeRouteBaselineFromBackup();
    }

    if (!hasUsableIPv4Baseline()) {
        NSMutableDictionary* backup = loadRouteBackup();
        hydrateBaselineRuntimeFromBackup(backup);
    }

    if (!hasUsableIPv4Baseline()) {
        if (errorMessage != NULL) {
            *errorMessage = @"Unable to determine current default IPv4 route baseline.";
        }
        return NO;
    }

    return YES;
}

static BOOL installIPv4TakeoverRoutes(NSString* tunName, NSMutableDictionary* backup, NSString** errorMessage) {
    if (tunName.length == 0) {
        if (errorMessage != NULL) {
            *errorMessage = @"Missing tun interface for IPv4 takeover routes.";
        }
        return NO;
    }
    activeIPv4TakeoverRoutes = [[NSMutableArray alloc] init];
    for (NSString* cidr in IPv4TakeoverCIDRs) {
        if (![routeHelper addNetworkRouteToDestination:cidr interface:tunName family:SYSRouteAddressFamilyIPv4]) {
            if (errorMessage != NULL) {
                *errorMessage = [NSString stringWithFormat:@"Failed to install IPv4 takeover route %@.", cidr];
            }
            if (backup != nil) {
                updateRouteBackupState(backup, ROUTE_BACKUP_STATE_SWITCHING, @"ipv4 takeover install failed");
            }
            return NO;
        }
        [activeIPv4TakeoverRoutes addObject:@{@"cidr": cidr, @"interface": tunName, @"family": @"ipv4"}];
    }
    updateRouteBackupTakeoverRoutes(backup);
    return YES;
}

static BOOL removeIPv4TakeoverRoutes(NSString* tunName, NSString** errorMessage) {
    BOOL ok = YES;
    NSArray<NSDictionary*>* takeoverEntries = activeIPv4TakeoverRouteEntries();
    for (NSDictionary* entry in takeoverEntries) {
        NSString* cidr = entry[@"cidr"] ?: @"";
        NSString* entryInterface = entry[@"interface"] ?: tunName ?: @"";
        BOOL removed = NO;
        if (entryInterface.length > 0) {
            removed = [routeHelper deleteNetworkRouteToDestination:cidr interface:entryInterface family:SYSRouteAddressFamilyIPv4];
        } else {
            removed = YES;
        }
        if (!removed && defaultRouteGatewayV4.length > 0) {
            removed = [routeHelper deleteNetworkRouteToDestination:cidr gateway:defaultRouteGatewayV4 family:SYSRouteAddressFamilyIPv4];
        }
        ok = removed && ok;
        if (!removed && errorMessage != NULL) {
            *errorMessage = [NSString stringWithFormat:@"Failed to remove IPv4 takeover route %@.", cidr];
        }
    }
    if (activeIPv4TakeoverRoutes == nil) {
        activeIPv4TakeoverRoutes = [[NSMutableArray alloc] init];
    } else {
        [activeIPv4TakeoverRoutes removeAllObjects];
    }
    return ok;
}

static void syncRuntimeSessionFromBackup(void) {
    NSMutableDictionary* backup = loadRouteBackup();
    if (activeTunName.length == 0) {
        activeTunName = backup[ROUTE_BACKUP_TUN_NAME_KEY] ?: @"";
    }
    if (activeIPv4TakeoverRoutes == nil) {
        NSArray* storedRoutes = backup[ROUTE_BACKUP_IPV4_TAKEOVER_ROUTES_KEY];
        activeIPv4TakeoverRoutes = [storedRoutes isKindOfClass:[NSArray class]] ? [storedRoutes mutableCopy] : [[NSMutableArray alloc] init];
    }
}

static void syncRuntimeRouteBaselineFromBackup(void) {
    NSMutableDictionary* backup = loadRouteBackup();
    if (defaultRouteGatewayV4.length == 0 || isTunManagedIPv4Route(defaultRouteGatewayV4, defaultRouteInterfaceV4)) {
        defaultRouteGatewayV4 = backup[ROUTE_BACKUP_DEFAULT_GATEWAY_V4_KEY] ?: @"";
    }
    if (defaultRouteGatewayV6.length == 0) {
        defaultRouteGatewayV6 = backup[ROUTE_BACKUP_DEFAULT_GATEWAY_V6_KEY] ?: @"";
    }
    if (defaultRouteInterfaceV4.length == 0 || isTunManagedIPv4Route(defaultRouteGatewayV4, defaultRouteInterfaceV4)) {
        defaultRouteInterfaceV4 = backup[ROUTE_BACKUP_DEFAULT_INTERFACE_V4_KEY] ?: @"";
    }
    if (defaultRouteInterfaceV6.length == 0) {
        defaultRouteInterfaceV6 = backup[ROUTE_BACKUP_DEFAULT_INTERFACE_V6_KEY] ?: @"";
    }
    if (![routeHelper isValidGateway:defaultRouteGatewayV4]) {
        defaultRouteGatewayV4 = @"";
    }
}

static BOOL isTunManagedIPv4Route(NSString* gateway, NSString* interfaceName) {
    if ([gateway isKindOfClass:[NSString class]] && [gateway isEqualToString:tunWg]) {
        return YES;
    }
    if ([interfaceName isKindOfClass:[NSString class]] && interfaceName.length > 0 && activeTunName.length > 0 && [interfaceName isEqualToString:activeTunName]) {
        return YES;
    }
    return NO;
}

static BOOL hasUsableIPv4Baseline(void) {
    return (defaultRouteGatewayV4.length > 0 && [routeHelper isValidGateway:defaultRouteGatewayV4]) || defaultRouteInterfaceV4.length > 0;
}

static NSDictionary* preferredNonTunDefaultRoute(void) {
    NSArray<NSDictionary*>* defaults = [routeHelper defaultRoutesForFamily:SYSRouteAddressFamilyIPv4];
    for (NSDictionary* route in defaults) {
        NSString* interfaceName = route[@"interface"] ?: @"";
        NSString* gateway = route[@"gateway"] ?: @"";
        if ([interfaceName hasPrefix:@"utun"]) {
            continue;
        }
        if (interfaceName.length == 0 && gateway.length == 0) {
            continue;
        }
        return route;
    }
    return @{
        @"gateway": defaultRouteGatewayV4 ?: @"",
        @"interface": defaultRouteInterfaceV4 ?: @"",
    };
}

static void resetTunRuntimeState(NSMutableDictionary* routeBackup, NSString* state, NSString* lastError) {
    syncRuntimeRouteBaselineFromBackup();
    activeTunName = @"";
    defaultRouteGatewayV4 = @"";
    defaultRouteGatewayV6 = @"";
    defaultRouteInterfaceV4 = @"";
    defaultRouteInterfaceV6 = @"";
    [activeWhitelistRoutes removeAllObjects];
    if (activeIPv4TakeoverRoutes == nil) {
        activeIPv4TakeoverRoutes = [[NSMutableArray alloc] init];
    } else {
        [activeIPv4TakeoverRoutes removeAllObjects];
    }
    updateRouteBackupState(routeBackup, state ?: ROUTE_BACKUP_STATE_IDLE, lastError ?: @"");
}

static NSString* currentSessionState(void) {
    NSMutableDictionary* backup = loadRouteBackup();
    NSString* state = activeTunName.length > 0 ? ROUTE_BACKUP_STATE_ACTIVE : backup[ROUTE_BACKUP_STATE_KEY];
    NSString* backupTunName = backup[ROUTE_BACKUP_TUN_NAME_KEY];
    NSArray* backupTakeoverRoutes = [backup[ROUTE_BACKUP_IPV4_TAKEOVER_ROUTES_KEY] isKindOfClass:[NSArray class]] ? backup[ROUTE_BACKUP_IPV4_TAKEOVER_ROUTES_KEY] : @[];
    if ((state.length == 0 || [state isEqualToString:ROUTE_BACKUP_STATE_IDLE]) && ![currentSessionType() isEqualToString:SESSION_TYPE_NONE] && backupTakeoverRoutes.count > 0 && [backupTunName isKindOfClass:[NSString class]] && backupTunName.length > 0) {
        state = ROUTE_BACKUP_STATE_ACTIVE;
    }
    if ([state isEqualToString:ROUTE_BACKUP_STATE_SWITCHING] && [currentSessionType() isEqualToString:SESSION_TYPE_NONE] && [currentSessionOwner() isEqualToString:SESSION_OWNER_NONE] && [currentControlPlane() isEqualToString:CONTROL_PLANE_NONE] && backupTakeoverRoutes.count == 0) {
        state = ROUTE_BACKUP_STATE_IDLE;
    }
    if (state.length == 0 || [state isEqualToString:ROUTE_BACKUP_STATE_IDLE]) {
        return @"inactive";
    }
    return state;
}

static NSArray<NSString*>* ipLiteralAddressesFromPath(NSString* path) {
    NSData* data = [NSData dataWithContentsOfFile:path];
    if (data == nil) {
        return @[];
    }
    id jsonObject = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if ([jsonObject isKindOfClass:[NSArray class]]) {
        return jsonObject;
    }
    if ([jsonObject isKindOfClass:[NSDictionary class]]) {
        NSArray* entries = jsonObject[@"entries"];
        if ([entries isKindOfClass:[NSArray class]]) {
            return entries;
        }
    }
    return @[];
}

static NSDictionary* handleTunCommand(NSArray<NSString*>* arguments) {
    if (arguments.count < 2) {
        return makeResponse(NO, @"Missing tun subcommand.", nil);
    }
    NSString* subcommand = arguments[1];
    BOOL asJSON = shouldOutputJSON(arguments);
    if ([subcommand isEqualToString:@"status"]) {
        return makeResponse(YES, @"Tun session status.", tunStatusPayload());
    }
    if ([subcommand isEqualToString:@"allocate"]) {
        NSString* tunName = nil;
        NSString* socketFDString = nil;
        if (arguments.count >= 4) {
            tunName = arguments[2];
            socketFDString = arguments[3];
        } else if (arguments.count >= 3) {
            socketFDString = arguments[2];
        }
        int sendSocketFD = -1;
        if (socketFDString.length == 0 || sscanf([socketFDString UTF8String], "%d", &sendSocketFD) != 1 || sendSocketFD < 0) {
            return makeResponse(NO, @"Missing or invalid tun fd transport socket fd.", nil);
        }
        return allocateTunFDSession(tunName, sendSocketFD);
    }
    if ([subcommand isEqualToString:@"activate"]) {
        if (arguments.count < 3) {
            return makeResponse(NO, @"Missing utun interface name for tun activate.", nil);
        }
        NSString* errorMessage = nil;
        BOOL didActivate = activateExternalTunSession(arguments[2], &errorMessage);
        return makeResponse(didActivate, didActivate ? @"External tun session activated." : (errorMessage ?: @"Failed to activate external tun session."), didActivate ? tunStatusPayload() : nil);
    }
    if ([subcommand isEqualToString:@"deactivate"]) {
        NSString* tunName = arguments.count >= 3 ? arguments[2] : nil;
        return deactivateExternalTunSession(tunName);
    }
    if ([subcommand isEqualToString:@"stop"]) {
        if (isExternalFDSession()) {
            return makeResponse(NO, @"Use `tun deactivate` for external tun sessions.", nil);
        }
        NSDictionary* response = requestActiveSession(@{@"cmd": @"stop"});
        if ([response[@"ok"] boolValue]) {
            return response;
        }
        syncRuntimeSessionFromBackup();
        NSString* sessionState = currentSessionState();
        if (![sessionState isEqualToString:@"inactive"]) {
            return stopTunSession();
        }
        return makeResponse(NO, response[@"message"] ?: @"No active tun session.", nil);
    }
    if ([subcommand isEqualToString:@"start"]) {
        NSString* errorMessage = nil;
        BOOL didStart = NO;
        if (arguments.count < 3) {
            return makeResponse(NO, @"Missing socks port for tun start.", nil);
        }
        int localProxyPort = 0;
        if (sscanf([arguments[2] UTF8String], "%i", &localProxyPort) != 1 || localProxyPort <= 0 || localProxyPort > 65535) {
            return makeResponse(NO, @"Invalid socks port for tun start.", nil);
        }
        didStart = setupTunSession(localProxyPort, &errorMessage);
        if (!didStart) {
            return makeResponse(NO, errorMessage ?: @"Failed to start tun session.", nil);
        }
        if (!startControlSocketServer(&errorMessage)) {
            NSMutableDictionary* backup = loadRouteBackup();
            updateRouteBackupState(backup, ROUTE_BACKUP_STATE_ACTIVE, @"");
            resetTunRuntimeState(backup, ROUTE_BACKUP_STATE_IDLE, @"");
            releaseTunSessionLock();
            return makeResponse(NO, errorMessage ?: @"Failed to start tun control socket.", nil);
        }
        NSDictionary* syncResponse = syncActiveWhitelistWithEntries(storeEntries(), YES);
        if (![syncResponse[@"ok"] boolValue]) {
            NSMutableDictionary* backup = loadRouteBackup();
            updateRouteBackupState(backup, ROUTE_BACKUP_STATE_ACTIVE, syncResponse[@"message"] ?: @"whitelist sync failed");
        }
        if (!asJSON) {
            printf("tun session started\n");
        }
        controlSocketAcceptLoop();
        releaseTunSessionLock();
        return makeResponse(YES, @"Tun session exited.", tunStatusPayload());
    }
    return makeResponse(NO, @"Unknown tun subcommand.", nil);
}

static NSDictionary* handleRouteCommand(NSArray<NSString*>* arguments) {
    if (arguments.count < 2) {
        return makeResponse(NO, @"Missing route subcommand.", nil);
    }
    NSString* subcommand = arguments[1];
    BOOL requireActive = [arguments containsObject:@"--require-active"];
    NSMutableArray<NSString*>* filteredArguments = [[NSMutableArray alloc] init];
    for (NSString* argument in arguments) {
        if (![argument isEqualToString:@"--json"] && ![argument isEqualToString:@"--require-active"]) {
            [filteredArguments addObject:argument];
        }
    }
    if ([subcommand isEqualToString:@"list"]) {
        return makeResponse(YES, @"Route whitelist entries.", routeListPayload());
    }
    BOOL useStatelessExternalSession = isExternalFDSession();
    if ([subcommand isEqualToString:@"apply"]) {
        if (useStatelessExternalSession) {
            return syncActiveWhitelistWithEntries(storeEntries(), YES);
        }
        return requestActiveSession(@{@"cmd": @"route-sync", @"entries": storeEntries()});
    }
    NSArray* rawEntries = nil;
    if ([subcommand isEqualToString:@"sync-file"]) {
        if (filteredArguments.count < 3) {
            return makeResponse(NO, @"Missing path for route sync-file.", nil);
        }
        rawEntries = ipLiteralAddressesFromPath(filteredArguments[2]);
    } else if ([subcommand isEqualToString:@"clear"]) {
        rawEntries = @[];
    } else {
        if (filteredArguments.count < 3) {
            return makeResponse(NO, @"Missing route IP arguments.", nil);
        }
        rawEntries = [filteredArguments subarrayWithRange:NSMakeRange(2, filteredArguments.count - 2)];
    }
    NSArray<NSString*>* invalidItems = nil;
    NSArray<NSDictionary*>* entries = normalizedEntriesFromArray(rawEntries, &invalidItems);
    if (invalidItems.count > 0) {
        return makeResponse(NO, @"Some route entries are invalid.", @{@"invalid": invalidItems});
    }
    if ([subcommand isEqualToString:@"add"]) {
        if (useStatelessExternalSession) {
            NSDictionary* storeResponse = addEntriesToStore(entries);
            if (![storeResponse[@"ok"] boolValue]) {
                return storeResponse;
            }
            NSDictionary* activeResponse = syncActiveWhitelistWithEntries(storeEntries(), YES);
            return makeResponse([activeResponse[@"ok"] boolValue], [activeResponse[@"ok"] boolValue] ? @"Routes added to whitelist store and active external session." : (activeResponse[@"message"] ?: @"Failed to apply routes to active external session."), @{@"persisted": storeResponse[@"persisted"] ?: @[], @"applied": activeResponse[@"applied"] ?: @[], @"pending": [activeResponse[@"ok"] boolValue] ? @[] : entries});
        }
        if (requireActive) {
            NSDictionary* response = requestActiveSession(@{@"cmd": @"route-add", @"entries": entries});
            if (![response[@"ok"] boolValue] || !canTreatSessionAsActiveResponse(response)) {
                return response;
            }
            return addEntriesToStore(entries);
        }
        NSDictionary* storeResponse = addEntriesToStore(entries);
        NSDictionary* activeResponse = requestActiveSession(@{@"cmd": @"route-add", @"entries": entries});
        if ([activeResponse[@"ok"] boolValue]) {
            return makeResponse(YES, @"Routes added to whitelist store and active session.", @{@"persisted": storeResponse[@"persisted"] ?: @[], @"applied": activeResponse[@"applied"] ?: @[], @"pending": @[]});
        }
        return makeResponse(YES, @"Routes added to whitelist store and pending active tun session.", @{@"persisted": storeResponse[@"persisted"] ?: @[], @"applied": @[], @"pending": entries});
    }
    if ([subcommand isEqualToString:@"del"]) {
        if (useStatelessExternalSession) {
            NSDictionary* storeResponse = removeEntriesFromStore(entries);
            if (![storeResponse[@"ok"] boolValue]) {
                return storeResponse;
            }
            NSDictionary* activeResponse = syncActiveWhitelistWithEntries(storeEntries(), YES);
            return makeResponse([activeResponse[@"ok"] boolValue], [activeResponse[@"ok"] boolValue] ? @"Routes removed from whitelist store and active external session." : (activeResponse[@"message"] ?: @"Failed to reconcile active external whitelist."), @{@"removed": storeResponse[@"removed"] ?: @[], @"active": activeResponse[@"active"] ?: @[]});
        }
        if (requireActive) {
            NSDictionary* response = requestActiveSession(@{@"cmd": @"route-del", @"entries": entries});
            if (![response[@"ok"] boolValue] || !canTreatSessionAsActiveResponse(response)) {
                return response;
            }
            return removeEntriesFromStore(entries);
        }
        NSDictionary* storeResponse = removeEntriesFromStore(entries);
        NSDictionary* activeResponse = requestActiveSession(@{@"cmd": @"route-del", @"entries": entries});
        return makeResponse(YES, [activeResponse[@"ok"] boolValue] ? @"Routes removed from whitelist store and active session." : @"Routes removed from whitelist store.", @{@"removed": storeResponse[@"removed"] ?: @[], @"activeRemoved": activeResponse[@"removed"] ?: @[]});
    }
    if ([subcommand isEqualToString:@"clear"]) {
        if (useStatelessExternalSession) {
            NSDictionary* storeResponse = clearStoreEntries();
            if (![storeResponse[@"ok"] boolValue]) {
                return storeResponse;
            }
            NSDictionary* activeResponse = syncActiveWhitelistWithEntries(@[], YES);
            return makeResponse([activeResponse[@"ok"] boolValue], [activeResponse[@"ok"] boolValue] ? @"Route whitelist cleared from store and active external session." : (activeResponse[@"message"] ?: @"Failed to clear active external whitelist."), @{@"removed": storeResponse[@"removed"] ?: @[], @"active": activeResponse[@"active"] ?: @[]});
        }
        if (requireActive) {
            NSDictionary* response = requestActiveSession(@{@"cmd": @"route-clear"});
            if (![response[@"ok"] boolValue] || !canTreatSessionAsActiveResponse(response)) {
                return response;
            }
            return clearStoreEntries();
        }
        NSDictionary* storeResponse = clearStoreEntries();
        NSDictionary* activeResponse = requestActiveSession(@{@"cmd": @"route-clear"});
        return makeResponse(YES, [activeResponse[@"ok"] boolValue] ? @"Route whitelist cleared from store and active session." : @"Route whitelist store cleared.", @{@"removed": storeResponse[@"removed"] ?: @[], @"activeRemoved": activeResponse[@"removed"] ?: @[]});
    }
    if ([subcommand isEqualToString:@"sync-file"]) {
        if (useStatelessExternalSession) {
            if (!replaceStoreEntries(entries)) {
                return makeResponse(NO, @"Failed to update route whitelist store.", nil);
            }
            NSDictionary* activeResponse = syncActiveWhitelistWithEntries(entries, YES);
            return makeResponse([activeResponse[@"ok"] boolValue], [activeResponse[@"ok"] boolValue] ? @"Route whitelist synchronized to store and active external session." : (activeResponse[@"message"] ?: @"Failed to synchronize active external whitelist."), @{@"entries": entries, @"applied": activeResponse[@"applied"] ?: @[], @"failed": activeResponse[@"failed"] ?: @[]});
        }
        if (requireActive) {
            NSDictionary* response = requestActiveSession(@{@"cmd": @"route-sync", @"entries": entries});
            if (![response[@"ok"] boolValue] || !canTreatSessionAsActiveResponse(response)) {
                return response;
            }
            if (!replaceStoreEntries(entries)) {
                return makeResponse(NO, @"Failed to update route whitelist store.", nil);
            }
            return makeResponse(YES, @"Route whitelist synchronized to store and active session.", @{@"entries": entries, @"applied": response[@"applied"] ?: @[]});
        }
        if (!replaceStoreEntries(entries)) {
            return makeResponse(NO, @"Failed to update route whitelist store.", nil);
        }
        NSDictionary* activeResponse = requestActiveSession(@{@"cmd": @"route-sync", @"entries": entries});
        return makeResponse(YES, [activeResponse[@"ok"] boolValue] ? @"Route whitelist synchronized to store and active session." : @"Route whitelist stored and pending active session.", @{@"entries": entries, @"applied": activeResponse[@"applied"] ?: @[], @"pending": [activeResponse[@"ok"] boolValue] ? @[] : entries});
    }
    return makeResponse(NO, @"Unknown route subcommand.", nil);
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
