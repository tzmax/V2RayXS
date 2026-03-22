#ifndef session_backup_store_h
#define session_backup_store_h

#import <Foundation/Foundation.h>

extern NSString* const ROUTE_BACKUP_VERSION_KEY;
extern NSString* const ROUTE_BACKUP_STATE_KEY;
extern NSString* const ROUTE_BACKUP_STATE_IDLE;
extern NSString* const ROUTE_BACKUP_STATE_SWITCHING;
extern NSString* const ROUTE_BACKUP_STATE_ACTIVE;
extern NSString* const ROUTE_BACKUP_TUN_NAME_KEY;
extern NSString* const ROUTE_BACKUP_WHITELIST_ROUTES_KEY;
extern NSString* const ROUTE_BACKUP_IPV4_TAKEOVER_ROUTES_KEY;
extern NSString* const ROUTE_BACKUP_LAST_ERROR_KEY;
extern NSString* const ROUTE_BACKUP_SESSION_TYPE_KEY;
extern NSString* const ROUTE_BACKUP_SESSION_OWNER_KEY;
extern NSString* const ROUTE_BACKUP_CONTROL_PLANE_KEY;

extern NSString* const SESSION_TYPE_NONE;
extern NSString* const SESSION_TYPE_INTERNAL;
extern NSString* const SESSION_TYPE_EXTERNAL_FD;
extern NSString* const SESSION_OWNER_NONE;
extern NSString* const SESSION_OWNER_HELPER;
extern NSString* const SESSION_OWNER_EXTERNAL;
extern NSString* const CONTROL_PLANE_NONE;
extern NSString* const CONTROL_PLANE_SOCKET;
extern NSString* const CONTROL_PLANE_STATELESS;

NSMutableDictionary* loadRouteBackup(void);
BOOL saveRouteBackup(NSMutableDictionary* backup);
NSMutableDictionary* sanitizeLegacyRouteBackup(NSMutableDictionary* backup);
BOOL backupRepresentsRecoverableActiveSession(NSDictionary* backup);

#endif /* session_backup_store_h */
