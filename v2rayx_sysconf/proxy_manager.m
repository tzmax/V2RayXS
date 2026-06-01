#import <Foundation/Foundation.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <Security/Authorization.h>
#import <unistd.h>
#import "helper_paths.h"
#import "proxy_manager.h"

static NSDictionary* runTool(NSString* launchPath, NSArray<NSString*>* arguments);
static NSDictionary* runNetworksetup(NSArray<NSString*>* arguments);
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
static BOOL configureNetworksetupProxyForService(NSString* serviceName, NSString* mode, int localPort, int httpPort, NSMutableDictionary* diagnostics, NSString** errorMessage);
static BOOL applyDynamicProxyState(NSString* mode, int localPort, int httpPort, NSMutableDictionary* diagnostics, NSString** errorMessage);
static void setProxyError(NSString** errorMessage, NSString* message);

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
    return applySystemProxyModeWithDiagnostics(mode, originalSets, localPort, httpPort, NULL, NULL);
}

BOOL applySystemProxyModeWithDiagnostics(NSString* mode, NSDictionary* originalSets, int localPort, int httpPort, NSString** errorMessage, NSDictionary** diagnosticsOut) {
    NSMutableDictionary* diagnostics = [@{
        @"stage": @"proxy.apply",
        @"mode": mode ?: @"",
    } mutableCopy];
    SCPreferencesRef prefRef = NULL;
    if (!createAuthorizedPreferences(&prefRef)) {
        setProxyError(errorMessage, @"Failed to create authorized system proxy preferences.");
        diagnostics[@"failure"] = @"create_authorized_preferences";
        if (diagnosticsOut != NULL) {
            *diagnosticsOut = diagnostics;
        }
        return NO;
    }
    if (!SCPreferencesLock(prefRef, YES)) {
        setProxyError(errorMessage, @"Failed to lock system proxy preferences.");
        diagnostics[@"failure"] = @"lock_preferences";
        CFRelease(prefRef);
        if (diagnosticsOut != NULL) {
            *diagnosticsOut = diagnostics;
        }
        return NO;
    }
    NSDictionary* sets = (__bridge NSDictionary*)SCPreferencesGetValue(prefRef, kSCPrefNetworkServices);
    if (sets == nil || !applyProxyModeToServices(prefRef, sets, mode, originalSets, localPort, httpPort)) {
        setProxyError(errorMessage, sets == nil ? @"Failed to read network services from system preferences." : @"Failed to update proxy settings for network services.");
        diagnostics[@"failure"] = sets == nil ? @"read_network_services" : @"apply_proxy_services";
        SCPreferencesUnlock(prefRef);
        CFRelease(prefRef);
        if (diagnosticsOut != NULL) {
            *diagnosticsOut = diagnostics;
        }
        return NO;
    }
    BOOL ok = SCPreferencesCommitChanges(prefRef) && SCPreferencesApplyChanges(prefRef);
    SCPreferencesSynchronize(prefRef);
    SCPreferencesUnlock(prefRef);
    CFRelease(prefRef);
    if (!ok) {
        setProxyError(errorMessage, @"Failed to commit or apply system proxy preferences.");
        diagnostics[@"failure"] = @"commit_or_apply_preferences";
        if (diagnosticsOut != NULL) {
            *diagnosticsOut = diagnostics;
        }
        return NO;
    }
    if (![mode isEqualToString:@"restore"]) {
        BOOL dynamicOk = applyDynamicProxyState(mode, localPort, httpPort, diagnostics, errorMessage);
        if (diagnosticsOut != NULL) {
            *diagnosticsOut = diagnostics;
        }
        return dynamicOk;
    }
    if (diagnosticsOut != NULL) {
        *diagnosticsOut = diagnostics;
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

static NSDictionary* runNetworksetup(NSArray<NSString*>* arguments) {
    NSDictionary* result = runTool(@"/usr/sbin/networksetup", arguments);
    return @{
        @"ok": @([result[@"status"] intValue] == 0),
        @"command": [@[@"/usr/sbin/networksetup"] arrayByAddingObjectsFromArray:arguments ?: @[]],
        @"arguments": arguments ?: @[],
        @"exitCode": result[@"status"] ?: @0,
        @"stdout": result[@"stdout"] ?: @"",
        @"stderr": result[@"stderr"] ?: @"",
    };
}

static void setProxyError(NSString** errorMessage, NSString* message) {
    if (errorMessage != NULL) {
        *errorMessage = message ?: @"Failed to apply system proxy settings.";
    }
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

static BOOL runNetworksetupStep(NSString* serviceName, NSString* actionName, NSArray<NSString*>* arguments, NSMutableArray* steps, NSString** errorMessage) {
    NSDictionary* result = runNetworksetup(arguments);
    NSMutableDictionary* step = [@{
        @"action": actionName ?: @"networksetup",
        @"service": serviceName ?: @"",
        @"ok": result[@"ok"] ?: @NO,
        @"command": result[@"command"] ?: @[],
        @"arguments": result[@"arguments"] ?: @[],
        @"exitCode": result[@"exitCode"] ?: @0,
        @"stdout": result[@"stdout"] ?: @"",
        @"stderr": result[@"stderr"] ?: @"",
    } mutableCopy];
    [steps addObject:step];
    if (![result[@"ok"] boolValue]) {
        NSString* stderrText = [result[@"stderr"] isKindOfClass:[NSString class]] ? result[@"stderr"] : @"";
        NSString* trimmedStderr = [stderrText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString* commandText = [result[@"command"] componentsJoinedByString:@" "] ?: @"networksetup";
        NSString* message = [NSString stringWithFormat:@"networksetup failed for service \"%@\": %@ returned %@%@%@", serviceName ?: @"", commandText, result[@"exitCode"] ?: @0, trimmedStderr.length > 0 ? @": " : @"", trimmedStderr.length > 0 ? trimmedStderr : @""];
        setProxyError(errorMessage, message);
        return NO;
    }
    return YES;
}

static BOOL configureNetworksetupProxyForService(NSString* serviceName, NSString* mode, int localPort, int httpPort, NSMutableDictionary* diagnostics, NSString** errorMessage) {
    if (serviceName.length == 0) {
        setProxyError(errorMessage, @"Missing network service name for networksetup proxy update.");
        return NO;
    }
    NSMutableArray* steps = [[NSMutableArray alloc] init];
    NSMutableDictionary* serviceDiagnostic = [@{
        @"service": serviceName,
        @"mode": mode ?: @"",
        @"steps": steps,
    } mutableCopy];
    NSMutableArray* services = diagnostics[@"networksetupServices"];
    if (![services isKindOfClass:[NSMutableArray class]]) {
        services = [[NSMutableArray alloc] init];
        diagnostics[@"networksetupServices"] = services;
    }
    [services addObject:serviceDiagnostic];
    BOOL ok = YES;
    ok = runNetworksetupStep(serviceName, @"setautoproxystate", @[@"-setautoproxystate", serviceName, @"off"], steps, errorMessage) && ok;
    ok = runNetworksetupStep(serviceName, @"setwebproxystate", @[@"-setwebproxystate", serviceName, @"off"], steps, errorMessage) && ok;
    ok = runNetworksetupStep(serviceName, @"setsecurewebproxystate", @[@"-setsecurewebproxystate", serviceName, @"off"], steps, errorMessage) && ok;
    ok = runNetworksetupStep(serviceName, @"setsocksfirewallproxystate", @[@"-setsocksfirewallproxystate", serviceName, @"off"], steps, errorMessage) && ok;
    if ([mode isEqualToString:@"auto"]) {
        ok = runNetworksetupStep(serviceName, @"setautoproxyurl", @[@"-setautoproxyurl", serviceName, @"http://127.0.0.1:8070/proxy.pac"], steps, errorMessage) && ok;
        ok = runNetworksetupStep(serviceName, @"setautoproxystate", @[@"-setautoproxystate", serviceName, @"on"], steps, errorMessage) && ok;
        serviceDiagnostic[@"ok"] = @(ok);
        return ok;
    }
    if ([mode isEqualToString:@"global"]) {
        if (httpPort > 0) {
            NSString* httpPortString = [NSString stringWithFormat:@"%d", httpPort];
            ok = runNetworksetupStep(serviceName, @"setwebproxy", @[@"-setwebproxy", serviceName, @"127.0.0.1", httpPortString], steps, errorMessage) && ok;
            ok = runNetworksetupStep(serviceName, @"setsecurewebproxy", @[@"-setsecurewebproxy", serviceName, @"127.0.0.1", httpPortString], steps, errorMessage) && ok;
            ok = runNetworksetupStep(serviceName, @"setwebproxystate", @[@"-setwebproxystate", serviceName, @"on"], steps, errorMessage) && ok;
            ok = runNetworksetupStep(serviceName, @"setsecurewebproxystate", @[@"-setsecurewebproxystate", serviceName, @"on"], steps, errorMessage) && ok;
        }
        if (localPort > 0) {
            NSString* localPortString = [NSString stringWithFormat:@"%d", localPort];
            ok = runNetworksetupStep(serviceName, @"setsocksfirewallproxy", @[@"-setsocksfirewallproxy", serviceName, @"127.0.0.1", localPortString], steps, errorMessage) && ok;
            ok = runNetworksetupStep(serviceName, @"setsocksfirewallproxystate", @[@"-setsocksfirewallproxystate", serviceName, @"on"], steps, errorMessage) && ok;
        }
    }
    serviceDiagnostic[@"ok"] = @(ok);
    return ok;
}

static BOOL applyDynamicProxyState(NSString* mode, int localPort, int httpPort, NSMutableDictionary* diagnostics, NSString** errorMessage) {
    SCPreferencesRef prefRef = SCPreferencesCreate(NULL, CFSTR("V2RayXS"), NULL);
    if (prefRef == NULL) {
        setProxyError(errorMessage, @"Failed to read network services for networksetup proxy refresh.");
        diagnostics[@"failure"] = @"dynamic_create_preferences";
        return NO;
    }
    SCNetworkSetRef currentSet = SCNetworkSetCopyCurrent(prefRef);
    if (currentSet == NULL) {
        CFRelease(prefRef);
        setProxyError(errorMessage, @"Failed to read current network set for networksetup proxy refresh.");
        diagnostics[@"failure"] = @"dynamic_current_network_set";
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
        ok = configureNetworksetupProxyForService(serviceName, mode, localPort, httpPort, diagnostics, errorMessage) && ok;
    }
    diagnostics[@"dynamicRefresh"] = @{
        @"ok": @(didApply && ok),
        @"didApply": @(didApply),
    };
    if (!didApply) {
        setProxyError(errorMessage, @"No enabled network services are available for networksetup proxy refresh.");
        diagnostics[@"failure"] = @"dynamic_no_enabled_services";
    } else if (!ok) {
        diagnostics[@"failure"] = @"dynamic_networksetup_failed";
    }
    return didApply && ok;
}
