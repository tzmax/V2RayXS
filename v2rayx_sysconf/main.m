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

SYSRouteHelper* routeHelper;
NSString* tunAddr = @"10.0.0.0";
NSString* tunWg = @"10.0.0.1";
NSString* tunMask = @"255.255.255.0";
NSString* tunDns = @"8.8.8.8,8.8.4.4,1.1.1.1";
NSString* proxyServer;
NSString* exampleServer = @"93.184.216.34"; // example.com ip use to identify records
NSString *runtimeMode = @"";

// helper perform the cleanup task.
void cleanupHandle(int signal_ns) {
    // printf("app kill signal %d\n", signal_ns);
    
    if ([runtimeMode isEqualToString: @"tun"]) {
        // Restore the default route
        if (![defaultRouteGateway isEqualToString:@""] && routeHelper != NULL) {
            [routeHelper routeDelete:@"default" gateway:tunWg];
            [routeHelper routeAdd:@"default" gateway:defaultRouteGateway];
            [routeHelper routeDelete:proxyServer gateway:defaultRouteGateway];
            printf("reset DefaultRouteGateway %s\n", [defaultRouteGateway UTF8String]);
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
                NSString* systemRouteBackupFilePath = [NSString stringWithFormat:@"%@/Library/Application Support/V2RayXS/system_route_backup.plist", NSHomeDirectory()];
                NSMutableDictionary* systemRouteBackup = [NSMutableDictionary dictionaryWithContentsOfURL:[NSURL fileURLWithPath: systemRouteBackupFilePath]];
                NSString* DEFAULT_ROUTE_GATEWAY = @"DefaultRouteGateway";
                if (systemRouteBackup == NULL) {
                    systemRouteBackup = [[NSMutableDictionary alloc] init];
                }
                if (![systemRouteBackup objectForKey:DEFAULT_ROUTE_GATEWAY]) {
                    [systemRouteBackup setValue:@"" forKey:DEFAULT_ROUTE_GATEWAY];
                }
                
                NSString* defGateway = [routeHelper getDefaultRouteGateway];
                NSString* fixGateway = systemRouteBackup[DEFAULT_ROUTE_GATEWAY];
                // NSString* fixGateway = [routeHelper getRouteGateway: exampleServer];
            
                // printf("defGateway %s\n", [defGateway UTF8String]);
                // printf("fixGateway %s\n", [fixGateway UTF8String]);
                
                if ([defGateway isEqualToString:@""] && ![fixGateway isEqualToString:@""]) {
                    defGateway = fixGateway;
                }
                
                if(![defGateway isEqualToString:@""] && ([fixGateway isEqualToString:@""] || ![defGateway isEqualToString:fixGateway])) {
                    fixGateway = defGateway;
                    [systemRouteBackup setValue:fixGateway forKey:DEFAULT_ROUTE_GATEWAY];
                    [systemRouteBackup writeToURL:[NSURL fileURLWithPath: systemRouteBackupFilePath] atomically:NO];
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
                
                [routeHelper upInterface: ctl.tunName]; // up tun Interface
                
                if (![defaultRouteGateway isEqualToString:@""]) {
                    [routeHelper routeDelete:@"default" gateway:defaultRouteGateway];
                    [routeHelper routeAdd:proxyServer gateway:defaultRouteGateway];
                }
                
                [routeHelper routeAdd:@"default" gateway:tunWg];
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
