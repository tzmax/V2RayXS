//
//  main.m
//  v2rayx_sysconf
//
//  Copyright © 2016年 Cenmrev. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <sys/signal.h>
#import <Tun2socks/Tun2socks.h>
#import "sysconf_version.h"
#import "tun.h"
#import "route.h"


#define INFO "v2rayx_sysconf\n the helper tool for V2RayX, modified from clowwindy's shadowsocks_sysconf.\nusage: v2rayx_sysconf [options]\noff\t turn off proxy\nauto\t auto proxy change\nglobal port \t global proxy at the specified port number\n"

//@interface AppDelegate : NSObject<NSXPCListenerDelegate> {}
//@end
//
//@implementation AppDelegate
//-(BOOL) listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)newConnection {
//    if (newConnection != NULL) {
//        [newConnection resume];
//    }
//
//    return true;
//}
//
//@end

BOOL runLoopMark = YES;

NSString* defaultRouteGateway;
NSString* activeProxyServer;
BOOL didAddProxyRoute = NO;
BOOL didSwitchDefaultRouteToTun = NO;

SYSRouteHelper* routeHelper;
NSString* tunAddr = @"10.0.0.0";
NSString* tunWg = @"10.0.0.1";
NSString* tunMask = @"255.255.255.0";
NSString* tunDns = @"8.8.8.8,8.8.4.4,1.1.1.1";
NSString* proxyServer;
NSString* exampleServer = @"93.184.216.34"; // example.com ip use to identify records
NSString *runtimeMode = @"";

NSString* const ROUTE_BACKUP_DEFAULT_GATEWAY_KEY = @"DefaultRouteGateway";
NSString* const ROUTE_BACKUP_PROXY_SERVER_KEY = @"ProxyServer";
NSString* const ROUTE_BACKUP_TUN_NAME_KEY = @"TunName";
NSString* const ROUTE_BACKUP_STATE_KEY = @"RouteState";
NSString* const ROUTE_BACKUP_STATE_IDLE = @"idle";
NSString* const ROUTE_BACKUP_STATE_SWITCHING = @"switching";
NSString* const ROUTE_BACKUP_STATE_ACTIVE = @"active";
NSString* const ROUTE_BACKUP_STATE_RESTORING = @"restoring";

NSString* const V2RayXSAppSupportRelativePath = @"Library/Application Support/V2RayXS";
NSString* const SystemRouteBackupFilename = @"system_route_backup.plist";
NSString* const SystemProxyBackupFilename = @"system_proxy_backup.plist";

NSString* appSupportPath(void) {
    return [NSString stringWithFormat:@"%@/%@", NSHomeDirectory(), V2RayXSAppSupportRelativePath];
}

NSURL* appSupportFileURL(NSString* filename) {
    if (filename == NULL || [filename isEqualToString:@""]) {
        return NULL;
    }
    return [NSURL fileURLWithPath:[NSString stringWithFormat:@"%@/%@", appSupportPath(), filename]];
}

BOOL setProxyFlag(NSMutableDictionary* proxies, NSString* key, BOOL enabled) {
    if (proxies == NULL || key == NULL) {
        return NO;
    }
    [proxies setObject:@(enabled) forKey:key];
    return YES;
}

void disableManualProxySettings(NSMutableDictionary* proxies) {
    setProxyFlag(proxies, (NSString *)kCFNetworkProxiesHTTPEnable, NO);
    setProxyFlag(proxies, (NSString *)kCFNetworkProxiesHTTPSEnable, NO);
    setProxyFlag(proxies, (NSString *)kCFNetworkProxiesProxyAutoConfigEnable, NO);
    setProxyFlag(proxies, (NSString *)kCFNetworkProxiesSOCKSEnable, NO);
}

NSString* routeBackupFilePath(void) {
    return [[appSupportFileURL(SystemRouteBackupFilename) path] copy];
}

NSURL* routeBackupFileURL(void) {
    return [NSURL fileURLWithPath:routeBackupFilePath()];
}

NSURL* proxyBackupFileURL(void) {
    return appSupportFileURL(SystemProxyBackupFilename);
}

BOOL saveProxyBackup(NSDictionary* sets) {
    if (sets == NULL) {
        return NO;
    }
    return [sets writeToURL:proxyBackupFileURL() atomically:NO];
}

NSDictionary* loadProxyBackup(void) {
    return [NSDictionary dictionaryWithContentsOfURL:proxyBackupFileURL()];
}

BOOL isSupportedProxyHardware(NSString* hardware) {
    return [hardware isEqualToString:@"AirPort"] || [hardware isEqualToString:@"Wi-Fi"] || [hardware isEqualToString:@"Ethernet"];
}

NSString* proxyPreferencePath(NSString* key) {
    return [NSString stringWithFormat:@"/%@/%@/%@", kSCPrefNetworkServices, key, kSCEntNetProxies];
}

BOOL parseProxyPorts(const char* socksArg, const char* httpArg, int* localPort, int* httpPort) {
    int parsedLocalPort = 0;
    int parsedHttpPort = 0;
    if (sscanf(socksArg, "%i", &parsedLocalPort) != 1 || parsedLocalPort > 65535 || parsedLocalPort < 0) {
        printf("error - not a valid port number");
        return NO;
    }
    if (sscanf(httpArg, "%i", &parsedHttpPort) != 1 || parsedHttpPort > 65535 || parsedHttpPort < 0) {
        printf("error - not a valid port number");
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

void applyAutoProxySettings(NSMutableDictionary* proxies) {
    [proxies setObject:@"http://127.0.0.1:8070/proxy.pac" forKey:(NSString *)kCFNetworkProxiesProxyAutoConfigURLString];
    setProxyFlag(proxies, (NSString *)kCFNetworkProxiesProxyAutoConfigEnable, YES);
}

void applyGlobalProxySettings(NSMutableDictionary* proxies, int localPort, int httpPort) {
    NSLog(@"in helper %d %d", localPort, httpPort);
    if (localPort > 0) {
        [proxies setObject:@"127.0.0.1" forKey:(NSString *)kCFNetworkProxiesSOCKSProxy];
        [proxies setObject:@(localPort) forKey:(NSString*)kCFNetworkProxiesSOCKSPort];
        setProxyFlag(proxies, (NSString*)kCFNetworkProxiesSOCKSEnable, YES);
    }
    if (httpPort > 0) {
        [proxies setObject:@"127.0.0.1" forKey:(NSString *)kCFNetworkProxiesHTTPProxy];
        [proxies setObject:@"127.0.0.1" forKey:(NSString *)kCFNetworkProxiesHTTPSProxy];
        [proxies setObject:@(httpPort) forKey:(NSString*)kCFNetworkProxiesHTTPPort];
        [proxies setObject:@(httpPort) forKey:(NSString*)kCFNetworkProxiesHTTPSPort];
        setProxyFlag(proxies, (NSString*)kCFNetworkProxiesHTTPEnable, YES);
        setProxyFlag(proxies, (NSString*)kCFNetworkProxiesHTTPSEnable, YES);
    }
}

NSMutableDictionary* proxiesForMode(NSString* mode, NSString* key, NSDictionary* sets, NSDictionary* originalSets, int localPort, int httpPort) {
    NSMutableDictionary* proxies = [sets[key][@"Proxies"] mutableCopy];
    disableManualProxySettings(proxies);

    if ([mode isEqualToString:@"restore"]) {
        NSDictionary* originalProxySettings = originalSets[key][@"Proxies"];
        if (originalProxySettings != NULL) {
            return [originalProxySettings mutableCopy];
        }
        return proxies;
    }

    if ([mode isEqualToString:@"auto"]) {
        applyAutoProxySettings(proxies);
    } else if ([mode isEqualToString:@"global"]) {
        applyGlobalProxySettings(proxies, localPort, httpPort);
    }

    return proxies;
}

void applyProxyModeToServices(SCPreferencesRef prefRef, NSDictionary* sets, NSString* mode, NSDictionary* originalSets, int localPort, int httpPort) {
    for (NSString *key in [sets allKeys]) {
        NSMutableDictionary *dict = [sets objectForKey:key];
        NSString *hardware = [dict valueForKeyPath:@"Interface.Hardware"];
        if (!isSupportedProxyHardware(hardware)) {
            continue;
        }

        NSMutableDictionary* proxies = proxiesForMode(mode, key, sets, originalSets, localPort, httpPort);
        SCPreferencesPathSetValue(prefRef, (__bridge CFStringRef)proxyPreferencePath(key), (__bridge CFDictionaryRef)proxies);
    }
}

NSMutableDictionary* loadRouteBackup(void) {
    NSMutableDictionary* backup = [NSMutableDictionary dictionaryWithContentsOfURL:routeBackupFileURL()];
    if (backup == NULL) {
        backup = [[NSMutableDictionary alloc] init];
    }
    if (![backup objectForKey:ROUTE_BACKUP_DEFAULT_GATEWAY_KEY]) {
        [backup setValue:@"" forKey:ROUTE_BACKUP_DEFAULT_GATEWAY_KEY];
    }
    if (![backup objectForKey:ROUTE_BACKUP_PROXY_SERVER_KEY]) {
        [backup setValue:@"" forKey:ROUTE_BACKUP_PROXY_SERVER_KEY];
    }
    if (![backup objectForKey:ROUTE_BACKUP_TUN_NAME_KEY]) {
        [backup setValue:@"" forKey:ROUTE_BACKUP_TUN_NAME_KEY];
    }
    if (![backup objectForKey:ROUTE_BACKUP_STATE_KEY]) {
        [backup setValue:ROUTE_BACKUP_STATE_IDLE forKey:ROUTE_BACKUP_STATE_KEY];
    }
    return backup;
}

BOOL saveRouteBackup(NSMutableDictionary* backup) {
    return [backup writeToURL:routeBackupFileURL() atomically:NO];
}

void updateRouteBackupState(NSMutableDictionary* backup, NSString* state, NSString* gateway, NSString* proxy, NSString* tunName) {
    if (backup == NULL) {
        return;
    }
    [backup setValue:(state ?: ROUTE_BACKUP_STATE_IDLE) forKey:ROUTE_BACKUP_STATE_KEY];
    [backup setValue:(gateway ?: @"") forKey:ROUTE_BACKUP_DEFAULT_GATEWAY_KEY];
    [backup setValue:(proxy ?: @"") forKey:ROUTE_BACKUP_PROXY_SERVER_KEY];
    [backup setValue:(tunName ?: @"") forKey:ROUTE_BACKUP_TUN_NAME_KEY];
    saveRouteBackup(backup);
}

BOOL restoreDefaultRouting(void) {
    if (routeHelper == NULL || defaultRouteGateway == NULL || [defaultRouteGateway isEqualToString:@""]) {
        return YES;
    }

    BOOL ok = YES;
    if (didSwitchDefaultRouteToTun || [routeHelper hasRoute:@"default" gateway:tunWg]) {
        ok = [routeHelper routeDelete:@"default" gateway:tunWg] && ok;
    }
    ok = [routeHelper routeAdd:@"default" gateway:defaultRouteGateway] && ok;

    if ((didAddProxyRoute || (activeProxyServer != NULL && ![activeProxyServer isEqualToString:@""])) && activeProxyServer != NULL) {
        ok = [routeHelper routeDelete:activeProxyServer gateway:defaultRouteGateway] && ok;
    }

    if (ok) {
        didAddProxyRoute = NO;
        didSwitchDefaultRouteToTun = NO;
    }

    return ok;
}

BOOL restoreDefaultRoutingAndPersist(NSMutableDictionary* routeBackup) {
    if (routeBackup != NULL) {
        updateRouteBackupState(routeBackup, ROUTE_BACKUP_STATE_RESTORING, defaultRouteGateway, activeProxyServer, routeBackup[ROUTE_BACKUP_TUN_NAME_KEY]);
    }

    BOOL ok = restoreDefaultRouting();
    if (routeBackup != NULL) {
        if (ok) {
            updateRouteBackupState(routeBackup, ROUTE_BACKUP_STATE_IDLE, defaultRouteGateway, @"", @"");
        } else {
            saveRouteBackup(routeBackup);
        }
    }

    return ok;
}

// helper perform the cleanup task.
void cleanupHandle(int signal_ns) {
    // printf("app kill signal %d\n", signal_ns);
    
    if ([runtimeMode isEqualToString: @"tun"]) {
        // Restore the default route
        if (![defaultRouteGateway isEqualToString:@""] && routeHelper != NULL) {
            NSMutableDictionary* routeBackup = loadRouteBackup();
            if (restoreDefaultRoutingAndPersist(routeBackup)) {
                printf("reset DefaultRouteGateway %s\n", [defaultRouteGateway UTF8String]);
            } else {
                NSLog(@"Failed to fully restore default routing to %@", defaultRouteGateway);
            }
        }
    }
    
    runLoopMark = NO;
}

int main(int argc, const char * argv[])
{
    // prepare for XPC communication
//    AppDelegate* appDelegate = [AppDelegate init];
//    NSXPCListener* xpcListener = [NSXPCListener serviceListener];
//    xpcListener.delegate = appDelegate;
    
    // Initialize the routing controller
    routeHelper = [[SYSRouteHelper alloc] init];

    // app kill signal
    signal(SIGKILL, cleanupHandle);
    signal(SIGABRT, cleanupHandle);
    signal(SIGINT, cleanupHandle);
    
    if (argc < 2 || argc >4) {
        printf(INFO);
        return 1;
    }
    @autoreleasepool {
        NSString *mode = [NSString stringWithUTF8String:argv[1]];
        
        NSSet *support_args = [NSSet setWithObjects:@"off", @"auto", @"global", @"save", @"restore", @"tun", @"-v", nil];
        if (![support_args containsObject:mode]) {
            printf(INFO);
            return 1;
        }
        
        runtimeMode = mode;
        
        if ([mode isEqualToString:@"-v"]) {
            printf("%s", [VERSION UTF8String]);
            return 0;
        }
        
        if ([mode isEqualToString:@"tun"]) {
            
            proxyServer = exampleServer; // Just avoid empty abnormalities
            if (argv[2] != NULL) {
                NSString* server = [NSString stringWithUTF8String:argv[2]];
                if (server != NULL) {
                    proxyServer = server;
                }
            }
            activeProxyServer = proxyServer;
            
            int localProxyPort = 0;
            if (sscanf (argv[3], "%i", &localProxyPort) != 1 || localProxyPort > 65535 || localProxyPort < 0) {
                printf("error - not a valid port number\n");
                return 0;
            }
            NSString* socks5ProxyLink = [[NSString alloc] initWithFormat: @"socks5://127.0.0.1:%i", localProxyPort];
            
            // The native way of creating TUN is deprecated
            // int fd = createTUN();
            // printf("tun fd is %d\n", fd);
            
            NSError* err;
            Tun2socksTun2socksCtl* ctl = Tun2socksCreateTunConnect(tunAddr, tunWg, tunMask, tunDns, socks5ProxyLink, true, &err);
            if (err != NULL) {
                NSLog(@"Tun2socksConnect error:  %@\n", err);
                return 0;
            }
            
            if (ctl != NULL && ctl.tunName != NULL) {
                // NSLog(@"tun fd is %@\n", ctl.tunName);
                
                // Process route
                NSMutableDictionary* systemRouteBackup = loadRouteBackup();
                
                NSString* defGateway = [routeHelper getDefaultRouteGateway];
                NSString* fixGateway = systemRouteBackup[ROUTE_BACKUP_DEFAULT_GATEWAY_KEY];
                NSString* backupState = systemRouteBackup[ROUTE_BACKUP_STATE_KEY];
                NSString* backupProxyServer = systemRouteBackup[ROUTE_BACKUP_PROXY_SERVER_KEY];
                // NSString* fixGateway = [routeHelper getRouteGateway: exampleServer];
            
                // printf("defGateway %s\n", [defGateway UTF8String]);
                // printf("fixGateway %s\n", [fixGateway UTF8String]);
                
                if ([defGateway isEqualToString:@""] && ![fixGateway isEqualToString:@""]) {
                    defGateway = fixGateway;
                }

                if (![fixGateway isEqualToString:@""] && ([defGateway isEqualToString:tunWg] || ![backupState isEqualToString:ROUTE_BACKUP_STATE_IDLE])) {
                    NSLog(@"Detected stale route backup state %@, trying to restore %@ first", backupState, fixGateway);
                    defaultRouteGateway = fixGateway;
                    activeProxyServer = [backupProxyServer isEqualToString:@""] ? proxyServer : backupProxyServer;
                    restoreDefaultRoutingAndPersist(systemRouteBackup);
                    defGateway = [routeHelper getDefaultRouteGateway];
                }
                
                if(![defGateway isEqualToString:@""] && ([fixGateway isEqualToString:@""] || ![defGateway isEqualToString:fixGateway])) {
                    fixGateway = defGateway;
                }
                
//                if(![defGateway isEqualToString:@""] && [fixGateway isEqualToString:@""]) {
//                    printf("add fix defGateway %s\n", [defGateway UTF8String]);
//                    [routeHelper routeAdd:exampleServer gateway:defGateway];
//                }
//                if (![defGateway isEqualToString:@""] && ![defGateway isEqualToString:fixGateway]) {
//                    [routeHelper routeDelete:exampleServer gateway:defGateway];
//                    [routeHelper routeAdd:exampleServer gateway:defGateway];
//                }
                 
                 defaultRouteGateway = defGateway;
                if (![routeHelper isValidGateway:defaultRouteGateway]) {
                    NSLog(@"Invalid default route gateway: %@", defaultRouteGateway);
                    return 1;
                }

                updateRouteBackupState(systemRouteBackup, ROUTE_BACKUP_STATE_SWITCHING, defaultRouteGateway, proxyServer, ctl.tunName);
                  
                  if (![routeHelper upInterface: ctl.tunName]) {
                    updateRouteBackupState(systemRouteBackup, ROUTE_BACKUP_STATE_IDLE, defaultRouteGateway, @"", @"");
                    NSLog(@"Failed to bring up tun interface %@", ctl.tunName);
                    return 1;
                  }
                 
                 if (![defaultRouteGateway isEqualToString:@""]) {
                     didAddProxyRoute = [routeHelper routeAdd:proxyServer gateway:defaultRouteGateway];
                     if (!didAddProxyRoute) {
                         updateRouteBackupState(systemRouteBackup, ROUTE_BACKUP_STATE_IDLE, defaultRouteGateway, @"", @"");
                         NSLog(@"Failed to preserve direct route to proxy server %@ via %@", proxyServer, defaultRouteGateway);
                         return 1;
                     }

                     if (![routeHelper routeDelete:@"default" gateway:defaultRouteGateway]) {
                         [routeHelper routeDelete:proxyServer gateway:defaultRouteGateway];
                         didAddProxyRoute = NO;
                         updateRouteBackupState(systemRouteBackup, ROUTE_BACKUP_STATE_IDLE, defaultRouteGateway, @"", @"");
                         NSLog(@"Failed to remove default route via %@", defaultRouteGateway);
                         return 1;
                     }
                 }

                  didSwitchDefaultRouteToTun = [routeHelper routeAdd:@"default" gateway:tunWg];
                  if (!didSwitchDefaultRouteToTun || ![routeHelper hasRoute:@"default" gateway:tunWg]) {
                      NSLog(@"Failed to switch default route to tun gateway %@, rolling back", tunWg);
                      restoreDefaultRoutingAndPersist(systemRouteBackup);
                      return 1;
                  }

                  updateRouteBackupState(systemRouteBackup, ROUTE_BACKUP_STATE_ACTIVE, defaultRouteGateway, proxyServer, ctl.tunName);
              }

            // run loop
            CFRunLoopSourceContext context = {0};
            CFRunLoopSourceRef source = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context);
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopDefaultMode);
            CFRelease(source);
            while (runLoopMark) {
                SInt32 result = CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.0e10, true);
                if (result == kCFRunLoopRunFinished) {
                    runLoopMark = NO;
                }
            }
            
            cleanupHandle(SIGABRT);
            return 0;
        }

        static AuthorizationRef authRef;
        static AuthorizationFlags authFlags;
        authFlags = kAuthorizationFlagDefaults
        | kAuthorizationFlagExtendRights
        | kAuthorizationFlagInteractionAllowed
        | kAuthorizationFlagPreAuthorize;
        OSStatus authErr = AuthorizationCreate(nil, kAuthorizationEmptyEnvironment, authFlags, &authRef);
        if (authErr != noErr) {
            authRef = nil;
        } else {
            if (authRef == NULL) {
                NSLog(@"No authorization has been granted to modify network configuration");
                return 1;
            }
            
            SCPreferencesRef prefRef = SCPreferencesCreateWithAuthorization(nil, CFSTR("V2RayXS"), nil, authRef);
            
            NSDictionary *sets = (__bridge NSDictionary *)SCPreferencesGetValue(prefRef, kSCPrefNetworkServices);
            NSDictionary* originalSets = nil;
            int localPort = 0;
            int httpPort = 0;
            if ([mode isEqualToString:@"save"]) {
                saveProxyBackup(sets);
                return 0;
            }

            if ([mode isEqualToString:@"restore"]) {
                originalSets = loadProxyBackup();
            } else if ([mode isEqualToString:@"global"]) {
                if (!parseProxyPorts(argv[2], argv[3], &localPort, &httpPort)) {
                    return 1;
                }
            }

            applyProxyModeToServices(prefRef, sets, mode, originalSets, localPort, httpPort);
            
            SCPreferencesCommitChanges(prefRef);
            SCPreferencesApplyChanges(prefRef);
            SCPreferencesSynchronize(prefRef);
            
        }
        
        printf("proxy set to %s\n", [mode UTF8String]);
    }
    
    return 0;
}
