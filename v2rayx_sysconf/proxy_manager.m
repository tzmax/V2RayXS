#import <Foundation/Foundation.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <Security/Authorization.h>
#import <unistd.h>
#import "helper_paths.h"
#import "proxy_manager.h"

static NSDictionary* runTool(NSString* launchPath, NSArray<NSString*>* arguments);
static BOOL runNetworksetup(NSArray<NSString*>* arguments);
static BOOL setProxyFlag(NSMutableDictionary* proxies, NSString* key, BOOL enabled);
static void disableManualProxySettings(NSMutableDictionary* proxies);
static BOOL saveProxyBackup(NSDictionary* sets);
static BOOL isConfigurableProxyService(NSDictionary* service);
static void applyAutoProxySettings(NSMutableDictionary* proxies);
static void applyGlobalProxySettings(NSMutableDictionary* proxies, int localPort, int httpPort);
static void cleanupInactiveProxySettings(NSMutableDictionary* proxies, NSString* mode);
static NSMutableDictionary* proxiesForMode(NSString* mode, NSDictionary* service, NSString* serviceID, NSDictionary* originalSets, int localPort, int httpPort);
static BOOL applyProxyModeToServices(SCPreferencesRef prefRef, NSDictionary* sets, NSString* mode, NSDictionary* originalSets, int localPort, int httpPort);
static BOOL createAuthorizedPreferences(SCPreferencesRef* prefRefOut);
static BOOL configureNetworksetupProxyForService(NSString* serviceName, NSString* mode, int localPort, int httpPort);
static BOOL applyDynamicProxyState(NSString* mode, int localPort, int httpPort);

BOOL parseProxyPorts(const char* socksArg, const char* httpArg, int* localPort, int* httpPort) {
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

NSDictionary* loadProxyBackup(void) {
    return [NSDictionary dictionaryWithContentsOfURL:helperProxyBackupFileURL()];
}

BOOL runProxySaveMode(void) {
    SCPreferencesRef prefRef = NULL;
    if (!createAuthorizedPreferences(&prefRef)) {
        return NO;
    }
    NSDictionary *sets = (__bridge NSDictionary *)SCPreferencesGetValue(prefRef, kSCPrefNetworkServices);
    BOOL ok = saveProxyBackup(sets);
    CFRelease(prefRef);
    return ok;
}

BOOL applySystemProxyMode(NSString* mode, NSDictionary* originalSets, int localPort, int httpPort) {
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
    helperEnsureAppSupportDirectory();
    return [sets writeToURL:helperProxyBackupFileURL() atomically:NO];
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
