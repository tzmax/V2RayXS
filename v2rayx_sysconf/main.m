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

NSString* routeBackupFilePath(void) {
    return [NSString stringWithFormat:@"%@/Library/Application Support/V2RayXS/system_route_backup.plist", NSHomeDirectory()];
}

NSMutableDictionary* loadRouteBackup(void) {
    NSMutableDictionary* backup = [NSMutableDictionary dictionaryWithContentsOfURL:[NSURL fileURLWithPath:routeBackupFilePath()]];
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
    return [backup writeToURL:[NSURL fileURLWithPath:routeBackupFilePath()] atomically:NO];
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
            
            NSDictionary* originalSets;
            if ([mode isEqualToString:@"save"]) {
                [sets writeToURL:[NSURL fileURLWithPath:[NSString stringWithFormat:@"%@/Library/Application Support/V2RayXS/system_proxy_backup.plist",NSHomeDirectory()]] atomically:NO];
                return 0;
            }
            
            // 遍历系统中的网络设备列表，设置 AirPort 和 Ethernet 的代理
            if([mode isEqualToString:@"restore"]) {
                originalSets = [NSDictionary dictionaryWithContentsOfURL:[NSURL fileURLWithPath:[NSString stringWithFormat:@"%@/Library/Application Support/V2RayXS/system_proxy_backup.plist",NSHomeDirectory()]]];
            }
            for (NSString *key in [sets allKeys]) {
                NSMutableDictionary *dict = [sets objectForKey:key];
                NSString *hardware = [dict valueForKeyPath:@"Interface.Hardware"];
                //        NSLog(@"%@", hardware);
                if ([hardware isEqualToString:@"AirPort"] || [hardware isEqualToString:@"Wi-Fi"] || [hardware isEqualToString:@"Ethernet"]) {
                    
                    NSMutableDictionary *proxies = [sets[key][@"Proxies"] mutableCopy];
                    [proxies setObject:[NSNumber numberWithInt:0] forKey:(NSString *)kCFNetworkProxiesHTTPEnable];
                    [proxies setObject:[NSNumber numberWithInt:0] forKey:(NSString *)kCFNetworkProxiesHTTPSEnable];
                    [proxies setObject:[NSNumber numberWithInt:0] forKey:(NSString *)kCFNetworkProxiesProxyAutoConfigEnable];
                    [proxies setObject:[NSNumber numberWithInt:0] forKey:(NSString *)kCFNetworkProxiesSOCKSEnable];
                    
                    if ([mode isEqualToString:@"restore"]) {
                        if ([originalSets objectForKey:key]){
                            proxies = originalSets[key][@"Proxies"];
                        }
                    }
                    
                    if ([mode isEqualToString:@"auto"]) {
                        
                        [proxies setObject:@"http://127.0.0.1:8070/proxy.pac" forKey:(NSString *)kCFNetworkProxiesProxyAutoConfigURLString];
                        [proxies setObject:[NSNumber numberWithInt:1] forKey:(NSString *)kCFNetworkProxiesProxyAutoConfigEnable];
                        
                    } else if ([mode isEqualToString:@"global"]) {
                        int localPort = 0;
                        int httpPort = 0;
                        if (sscanf (argv[2], "%i", &localPort)!=1 || localPort > 65535 || localPort < 0) {
                            printf ("error - not a valid port number");
                            return 1;
                        }
                        if (sscanf (argv[3], "%i", &httpPort)!=1 || httpPort > 65535 || httpPort < 0) {
                            printf ("error - not a valid port number");
                            return 1;
                        }
                        NSLog(@"in helper %d %d", localPort, httpPort);
                        if (localPort > 0) {
                            [proxies setObject:@"127.0.0.1" forKey:(NSString *)
                             kCFNetworkProxiesSOCKSProxy];
                            [proxies setObject:[NSNumber numberWithInt:localPort] forKey:(NSString*)
                             kCFNetworkProxiesSOCKSPort];
                            [proxies setObject:[NSNumber numberWithInt:1] forKey:(NSString*)
                             kCFNetworkProxiesSOCKSEnable];
                        }
                        if (httpPort > 0) {
                            [proxies setObject:@"127.0.0.1" forKey:(NSString *)
                             kCFNetworkProxiesHTTPProxy];
                            [proxies setObject:@"127.0.0.1" forKey:(NSString *)
                             kCFNetworkProxiesHTTPSProxy];
                            [proxies setObject:[NSNumber numberWithInt:httpPort] forKey:(NSString*)
                             kCFNetworkProxiesHTTPPort];
                            [proxies setObject:[NSNumber numberWithInt:httpPort] forKey:(NSString*)
                             kCFNetworkProxiesHTTPSPort];
                            [proxies setObject:[NSNumber numberWithInt:1] forKey:(NSString*)
                             kCFNetworkProxiesHTTPEnable];
                            [proxies setObject:[NSNumber numberWithInt:1] forKey:(NSString*)
                             kCFNetworkProxiesHTTPSEnable];
                        }
                    }
                    
                    SCPreferencesPathSetValue(prefRef, (__bridge CFStringRef)[NSString stringWithFormat:@"/%@/%@/%@", kSCPrefNetworkServices, key, kSCEntNetProxies], (__bridge CFDictionaryRef)proxies);
                }
            }
            
            SCPreferencesCommitChanges(prefRef);
            SCPreferencesApplyChanges(prefRef);
            SCPreferencesSynchronize(prefRef);
            
        }
        
        printf("proxy set to %s\n", [mode UTF8String]);
    }
    
    return 0;
}
