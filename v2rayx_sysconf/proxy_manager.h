#ifndef proxy_manager_h
#define proxy_manager_h

#import <Foundation/Foundation.h>

BOOL parseProxyPorts(const char* socksArg, const char* httpArg, int* localPort, int* httpPort);
NSDictionary* loadProxyBackup(void);
BOOL runProxySaveMode(void);
BOOL applySystemProxyMode(NSString* mode, NSDictionary* originalSets, int localPort, int httpPort);

#endif /* proxy_manager_h */
