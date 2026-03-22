#ifndef helper_paths_h
#define helper_paths_h

#import <Foundation/Foundation.h>

NSString* helperAppSupportPath(void);
NSURL* helperAppSupportFileURL(NSString* filename);
BOOL helperEnsureAppSupportDirectory(void);
NSURL* helperRouteBackupFileURL(void);
NSURL* helperRouteStoreFileURL(void);
NSURL* helperProxyBackupFileURL(void);
NSString* helperControlSocketPath(void);
NSString* helperTunSessionLockPath(void);

#endif /* helper_paths_h */
