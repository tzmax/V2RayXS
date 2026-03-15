//
//  AppDelegate.h
//  V2RayX
//
//  Copyright © 2016年 Cenmrev. All rights reserved.
//


#import <Cocoa/Cocoa.h>
#import "sysconf_version.h"
#import "utilities.h"
#define kV2RayXHelper @"/Library/Application Support/V2RayXS/v2rayx_sysconf"
#define kV2RayXSettingVersion 4

#define webServerPort 8070

typedef enum ProxyMode : NSInteger{
    pacMode,
    globalMode,
    manualMode,
    tunMode
} ProxyMode;


NSDictionary* runCommandLineResult(NSString* launchPath, NSArray* arguments);
int runCommandLine(NSString* launchPath, NSArray* arguments);

@interface AppDelegate : NSObject <NSApplicationDelegate, NSUserNotificationCenterDelegate> {
    BOOL proxyState;
    ProxyMode proxyMode;
    NSInteger localPort;
    NSInteger httpPort;
    BOOL udpSupport;
    BOOL shareOverLan;
    BOOL useCusProfile;
    BOOL useMultipleServer;
    NSInteger selectedServerIndex;
    NSInteger selectedCusServerIndex;
    NSString* selectedPacFileName;
    NSString* dnsString;
    NSMutableArray *profiles;
    NSMutableArray *cusProfiles;
    NSString* logLevel;
    
    NSString* logDirPath;
}

@property NSString* logDirPath;
@property NSString* webServerUuidString;

@property BOOL proxyState;
@property ProxyMode proxyMode;
@property NSInteger localPort;
@property NSInteger httpPort;
@property BOOL udpSupport;
@property BOOL shareOverLan;
@property BOOL useCusProfile;
@property NSInteger selectedServerIndex;
@property NSInteger selectedCusServerIndex;
@property NSInteger selectedRoutingSet;
@property NSString* dnsString;
@property NSMutableArray *profiles;
@property NSMutableArray *cusProfiles;
@property (atomic) NSMutableArray *subsOutbounds;
@property NSMutableArray *routingRuleSets;
@property NSString* logLevel;
@property BOOL useMultipleServer;
@property NSString* selectedPacFileName;
@property BOOL enableRestore;
@property NSMutableArray *subscriptions;
@property BOOL enableEncryption;
@property BOOL useXrayTun;
@property NSString* encryptionKey;

- (BOOL)helperBinaryIsHealthy:(NSString**)errorMessage;
- (void)presentHelperFailureAlert:(NSString*)message;
- (BOOL)runHelperCommand:(NSArray*)arguments action:(NSString*)action;
- (BOOL)installHelperBinary:(NSString**)errorMessage;
- (NSString*)appleScriptStringLiteral:(NSString*)value;
- (BOOL)helperBinaryAtPathIsHealthy:(NSString*)helperPath error:(NSString**)errorMessage;
- (NSString*)helperVersionAtPath:(NSString*)helperPath error:(NSString**)errorMessage;
- (BOOL)helperVersionAtPathMatchesCurrentVersion:(NSString*)helperPath error:(NSString**)errorMessage;

- (IBAction)didChangeStatus:(id)sender;
- (IBAction)updateSubscriptions:(id)sender;
- (IBAction)showHelp:(id)sender;
- (IBAction)showConfigWindow:(id)sender;
- (IBAction)editPac:(id)sender;
- (IBAction)resetPac:(id)sender;
- (IBAction)viewLog:(id)sender;
- (void)saveConfigInfo;

-(NSString*)getV2rayPath;
- (BOOL)isCurrentCoreXray;
- (NSString*)currentCoreVersionString;
- (BOOL)currentCoreSupportsXrayTun;
- (NSString*)availableUtunName;
- (BOOL)shouldMaintainTunRoutingSession;
- (BOOL)hasActiveTunRoutingSession;
- (void)probeTunRoutingSessionState;
- (void)stopTunRoutingSession;
- (void)refreshTunRoutingSession;
- (void)syncTunWhitelistRoutes;
- (NSString*)logDirPath;

@property (weak) IBOutlet NSMenuItem *updateServerItem;
@property (strong, nonatomic)  NSStatusItem *statusBarItem;
@property (weak) IBOutlet NSMenuItem *upgradeMenuItem;
@property (weak, nonatomic) IBOutlet NSMenu *statusBarMenu;
@property (weak, nonatomic) IBOutlet NSMenuItem *v2rayStatusItem;
@property (weak, nonatomic) IBOutlet NSMenuItem *enableV2rayItem;
@property (weak, nonatomic) IBOutlet NSMenuItem *pacModeItem;
@property (weak, nonatomic) IBOutlet NSMenuItem *v2rayRulesItem;
@property (weak) IBOutlet NSMenu *ruleSetMenuList;
@property (weak, nonatomic) IBOutlet NSMenuItem *globalModeItem;
@property (weak) IBOutlet NSMenuItem *manualModeItem;
@property (weak) IBOutlet NSMenuItem *tunModeItem;
@property (weak, nonatomic) IBOutlet NSMenuItem *serversItem;
@property (weak, nonatomic) IBOutlet NSMenu *serverListMenu;
@property (weak, nonatomic) IBOutlet NSMenu *pacListMenu;
@property (weak) IBOutlet NSMenuItem *editPacMenuItem;
@property (weak) IBOutlet NSMenuItem *resetPacMenuItem;

@property (weak) IBOutlet NSMenu *authMenu;

@end
