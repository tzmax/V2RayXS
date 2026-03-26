//
//  AppDelegate.m
//  V2RayX
//
//  Copyright © 2016年 Cenmrev. All rights reserved.
//

#import "AppDelegate.h"
#import "GCDWebServer.h"
#import "GCDWebServerDataResponse.h"
#import "ConfigWindowController.h"
#import <SystemConfiguration/SystemConfiguration.h>
#import "ServerProfile.h"
#import "MutableDeepCopying.h"
#import "ConfigImporter.h"
#import "NSData+AES256Encryption.h"
#import <sys/stat.h>
#import <sys/wait.h>
#import <sys/socket.h>
#import <sys/uio.h>
#import <spawn.h>
#import <fcntl.h>
#import <netdb.h>
#import <stdarg.h>

#define kUseAllServer -10

@class HelperClient;

typedef NS_ENUM(NSInteger, RuntimeCoreKind) {
    RuntimeCoreKindStopped = 0,
    RuntimeCoreKindPlain,
    RuntimeCoreKindTun,
};

typedef struct {
    BOOL enabled;
    ProxyMode mode;
    RuntimeCoreKind coreKind;
} RuntimeState;

typedef struct {
    BOOL previousModeIsTun;
    BOOL nextModeIsTun;
    BOOL shouldStopCore;
    BOOL shouldStopTunSession;
    BOOL shouldStartCore;
    BOOL shouldApplyNetworkMode;
    BOOL shouldRefreshTunSession;
    BOOL shouldBackupSystemProxy;
    BOOL shouldRestoreSystemProxy;
    BOOL shouldDisableSystemProxy;
} RuntimeTransitionPlan;

@interface AppDelegate () {
    GCDWebServer *webServer;
    ConfigWindowController *configWindowController;

    dispatch_queue_t taskQueue;
    dispatch_queue_t coreLoopQueue;
    dispatch_semaphore_t coreLoopSemaphore;
    pid_t coreProcessPID;
    int coreProcessStatus;
    int coreTunFD;
    NSString* coreConfigPath;
    dispatch_source_t dispatchPacSource;
    dispatch_source_t terminationSignalSource;
    dispatch_source_t interruptSignalSource;
    FSEventStreamRef fsEventStream;
    BOOL suppressAutomaticTunRefreshDuringCoreConfigChange;
    HelperClient* helperClient;
    NSString* lastPresentedHelperFailureKey;
    NSDate* lastPresentedHelperFailureAt;
    BOOL helperFailureAlertVisible;
    
    NSData* v2rayJSONconfig;
}

- (NSString*)helperInstallSourcePath;
- (BOOL)waitForTunInterfaceNamed:(NSString*)tunName timeout:(NSTimeInterval)timeout;
- (NSString*)shellEscapedArgument:(NSString*)argument;
- (NSString*)appleScriptStringLiteral:(NSString*)value;
- (BOOL)installHelperBinary:(NSString**)errorMessage;
- (BOOL)helperBinaryAtPathIsHealthy:(NSString*)helperPath error:(NSString**)errorMessage;
- (NSString*)helperVersionAtPath:(NSString*)helperPath error:(NSString**)errorMessage;
- (BOOL)helperVersionAtPathMatchesCurrentVersion:(NSString*)helperPath error:(NSString**)errorMessage;
- (void)restoreStartupRuntimeState;
- (RuntimeState)currentRuntimeState;
- (RuntimeState)runtimeStateWithEnabled:(BOOL)enabled mode:(ProxyMode)mode;
- (RuntimeTransitionPlan)transitionPlanFromState:(RuntimeState)previousState toState:(RuntimeState)nextState userInitiated:(BOOL)isUserInitiated startupRestore:(BOOL)isStartupRestore;
- (void)normalizeCurrentRuntimeSelections;
- (void)applyStatusChangeFromSender:(id)sender startupRestore:(BOOL)isStartupRestore;
- (void)applyStatusTransitionFromEnabled:(BOOL)previousEnabled toEnabled:(BOOL)nextEnabled startupRestore:(BOOL)isStartupRestore;
- (void)applyModeChangeFromSender:(id)sender userInitiated:(BOOL)isUserInitiated;
- (void)applyModeTransitionFrom:(ProxyMode)previousMode to:(ProxyMode)nextMode userInitiated:(BOOL)isUserInitiated sender:(id)sender;
- (void)applyRuntimeTargetEnabled:(BOOL)targetEnabled mode:(ProxyMode)targetMode startupRestore:(BOOL)isStartupRestore;
- (void)applyNonTunModeTransitionFrom:(ProxyMode)previousMode to:(ProxyMode)nextMode userInitiated:(BOOL)isUserInitiated sender:(id)sender applyNetworkMode:(BOOL)applyNetworkMode;
- (void)applyAutomationTargetIfNeeded;
- (NSMenuItem*)menuItemForAutomationMode:(NSString*)modeName;
- (void)ensureCoreLogDirectoryExists;
- (NSString*)currentTunSessionState;
- (NSString*)currentTunInterfaceName;
- (BOOL)shouldTreatTunSessionAsActive;
- (NSString*)tunStatusDisplayText;
- (void)reconcileTunSessionForCurrentRuntime;
- (void)handleWorkspaceDidWake:(NSNotification*)notification;
- (void)activateXrayTunLeaseAfterCoreSpawn:(NSDictionary*)xrayTunFDContext;
- (void)reportHelperFailureMessage:(NSString*)message;
- (BOOL)isUsingXrayTunMode;
- (void)applyNonXrayNetworkMode;
- (void)stopEmbeddedTunSessionIfNeeded;

@end

@implementation AppDelegate

static AppDelegate *appDelegate;
static BOOL helperTunSessionActive = NO;
static NSDictionary* helperTunSessionStatus = nil;
static NSString* const kMinimumSupportedXrayTunVersion = @"26.1.23";
static int const kXrayTunFDTarget = 3;

static NSString* const kStoredTunLeaseIdKey = @"xrayTunLeaseId";

static HelperClient* activeHelperClient(void) {
    return appDelegate != nil ? appDelegate->helperClient : nil;
}

extern char **environ;

static BOOL appDebugEnabled(void) {
    return [[[NSProcessInfo processInfo] arguments] containsObject:@"--debug"];
}

static void appDebugLog(NSString* format, ...) {
    if (!appDebugEnabled()) {
        return;
    }
    va_list args;
    va_start(args, format);
    NSString* message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[debug] %@", message);
}

static NSFileHandle* nullInputHandle(void) {
    return [NSFileHandle fileHandleWithNullDevice];
}

static BOOL shouldEnableHelperDebugLogging(void) {
    return [[[NSProcessInfo processInfo] arguments] containsObject:@"--debug"];
}

static NSArray* helperArgumentsWithOptionalDebug(NSArray* arguments) {
    if (!shouldEnableHelperDebugLogging() || [arguments containsObject:@"--debug"]) {
        return arguments;
    }
    return [arguments arrayByAddingObject:@"--debug"];
}

static BOOL helperArgumentsManageTunSession(NSArray* arguments) {
    if (arguments.count == 0 || ![arguments[0] isEqual:@"tun"]) {
        return NO;
    }
    if (arguments.count < 2) {
        return NO;
    }
    NSString* subcommand = arguments[1];
    return [subcommand isEqual:@"start"] || [subcommand isEqual:@"activate"] || [subcommand isEqual:@"stop"] || [subcommand isEqual:@"status"] || [subcommand isEqual:@"deactivate"];
}

static char** buildSpawnCStringArray(NSArray<NSString*>* components) {
    NSUInteger count = components.count;
    char** array = calloc(count + 1, sizeof(char*));
    if (array == NULL) {
        return NULL;
    }
    for (NSUInteger index = 0; index < count; index++) {
        array[index] = strdup([components[index] UTF8String]);
        if (array[index] == NULL) {
            for (NSUInteger cleanupIndex = 0; cleanupIndex < index; cleanupIndex++) {
                free(array[cleanupIndex]);
            }
            free(array);
            return NULL;
        }
    }
    array[count] = NULL;
    return array;
}

static void freeSpawnCStringArray(char** array) {
    if (array == NULL) {
        return;
    }
    for (NSUInteger index = 0; array[index] != NULL; index++) {
        free(array[index]);
    }
    free(array);
}

static NSArray<NSString*>* buildSpawnEnvironmentComponents(NSDictionary<NSString*, NSString*>* overrides) {
    NSMutableDictionary<NSString*, NSString*>* mergedEnvironment = [[[NSProcessInfo processInfo] environment] mutableCopy];
    [mergedEnvironment addEntriesFromDictionary:overrides ?: @{}];
    NSMutableArray<NSString*>* components = [[NSMutableArray alloc] initWithCapacity:mergedEnvironment.count];
    [mergedEnvironment enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *obj, BOOL *stop) {
        [components addObject:[NSString stringWithFormat:@"%@=%@", key, obj]];
    }];
    return components;
}

static int spawnProcess(NSString* launchPath, NSArray<NSString*>* arguments, NSDictionary<NSString*, NSString*>* environmentOverrides, int mappedFDSource, int mappedFDTarget, pid_t* pidOut) {
    if (launchPath.length == 0 || pidOut == NULL) {
        return EINVAL;
    }

    NSMutableArray<NSString*>* argvComponents = [[NSMutableArray alloc] init];
    [argvComponents addObject:launchPath];
    if (arguments.count > 0) {
        [argvComponents addObjectsFromArray:arguments];
    }
    NSArray<NSString*>* environmentComponents = buildSpawnEnvironmentComponents(environmentOverrides);
    char** argv = buildSpawnCStringArray(argvComponents);
    char** envp = buildSpawnCStringArray(environmentComponents);
    if (argv == NULL || envp == NULL) {
        freeSpawnCStringArray(argv);
        freeSpawnCStringArray(envp);
        return ENOMEM;
    }

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    if (mappedFDSource >= 0 && mappedFDTarget >= 0) {
        posix_spawn_file_actions_adddup2(&actions, mappedFDSource, mappedFDTarget);
        if (mappedFDSource != mappedFDTarget) {
            posix_spawn_file_actions_addclose(&actions, mappedFDSource);
        }
    }

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_CLOEXEC_DEFAULT);

    int spawnError = posix_spawn(pidOut, [launchPath fileSystemRepresentation], &actions, &attr, argv, envp);
    posix_spawnattr_destroy(&attr);
    posix_spawn_file_actions_destroy(&actions);
    freeSpawnCStringArray(argv);
    freeSpawnCStringArray(envp);
    return spawnError;
}

static int waitForSpawnedProcess(pid_t pid, int* statusOut) {
    int status = 0;
    pid_t waitResult = waitpid(pid, &status, 0);
    if (waitResult < 0) {
        return errno;
    }
    if (statusOut != NULL) {
        *statusOut = status;
    }
    return 0;
}

static int terminateSpawnedProcess(pid_t pid, NSTimeInterval timeout, int* statusOut) {
    if (pid <= 0) {
        return 0;
    }
    kill(pid, SIGTERM);
    NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:MAX(timeout, 0)];
    int status = 0;
    while ([[NSDate date] compare:deadline] != NSOrderedDescending) {
        pid_t waitResult = waitpid(pid, &status, WNOHANG);
        if (waitResult == pid) {
            if (statusOut != NULL) {
                *statusOut = status;
            }
            return 0;
        }
        if (waitResult < 0 && errno == ECHILD) {
            if (statusOut != NULL) {
                *statusOut = 0;
            }
            return 0;
        }
        [NSThread sleepForTimeInterval:0.1];
    }
    kill(pid, SIGKILL);
    return waitForSpawnedProcess(pid, statusOut);
}

static int normalizedExitCodeFromWaitStatus(int status) {
    if (WIFEXITED(status)) {
        return WEXITSTATUS(status);
    }
    if (WIFSIGNALED(status)) {
        return WTERMSIG(status);
    }
    return status;
}

- (NSData*)v2rayJSONconfig {
    return v2rayJSONconfig;
}

// a good reference: https://blog.gaelfoppolo.com/user-notifications-in-macos-66c25ed5c692

- (BOOL)userNotificationCenter:(NSUserNotificationCenter *)center
     shouldPresentNotification:(NSUserNotification *)notification {
    return YES;
}

- (void)userNotificationCenter:(NSUserNotificationCenter *)center didActivateNotification:(NSUserNotification *)notification {
    switch (notification.activationType) {
        case NSUserNotificationActivationTypeActionButtonClicked:
            [self inputPassword:self];
            break;
        default:
            break;
    }
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    [[NSUserNotificationCenter defaultUserNotificationCenter] setDelegate:self];
    
    // check helper
    if (![self installHelper:false]) {
        [[NSApplication sharedApplication] terminate:nil];// installation failed or stopped by user,
    };
    
    // prepare directory
    NSFileManager* fileManager = [NSFileManager defaultManager];
    NSString *pacDir = [NSString stringWithFormat:@"%@/Library/Application Support/V2RayXS/pac", NSHomeDirectory()];
    //create application support directory and pac directory
    if (![fileManager fileExistsAtPath:pacDir]) {
        [fileManager createDirectoryAtPath:pacDir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    // Create Log Dir
    NSString* logDirName = @"cenmrev.v2rayx.log";
    logDirPath = [NSString stringWithFormat:@"%@%@", NSTemporaryDirectory(), logDirName];
    [fileManager createDirectoryAtPath:logDirPath withIntermediateDirectories:YES attributes:nil error:nil];
    [fileManager createFileAtPath:[NSString stringWithFormat:@"%@/access.log", logDirPath] contents:nil attributes:nil];
    [fileManager createFileAtPath:[NSString stringWithFormat:@"%@/error.log", logDirPath] contents:nil attributes:nil];
    
    // initialize variables
    NSNumber* setingVersion = [[NSUserDefaults standardUserDefaults] objectForKey:@"setingVersion"];
    if(setingVersion == nil || [setingVersion integerValue] != kV2RayXSettingVersion) {
        NSAlert *noServerAlert = [[NSAlert alloc] init];
        [noServerAlert setMessageText:@"If you are running V2RayXS for the first time, ignore this message. \nSorry, unknown settings!\nAll V2RayXS settings will be reset."];
        [noServerAlert runModal];
        [self writeDefaultSettings]; //explicitly write default settings to user defaults file
    }
    
    v2rayJSONconfig = [[NSData alloc] init];
    helperClient = [[HelperClient alloc] initWithHelperPath:kV2RayXHelper];
    __weak typeof(self) weakSelf = self;
    helperClient.helperIssueProvider = ^NSString* {
        return [weakSelf currentHelperIssueMessage];
    };
    helperClient.failurePresenter = ^(NSString* message) {
        [weakSelf presentHelperFailureAlert:message];
    };
    [self addObserver:self forKeyPath:@"selectedPacFileName" options:NSKeyValueObservingOptionNew context:nil];
    
    // create a serial queue used for NSTask operations
    taskQueue = dispatch_queue_create("cenmrev.v2rayxs.nstask", DISPATCH_QUEUE_CONCURRENT);
    // create a loop to run core
    coreLoopSemaphore = dispatch_semaphore_create(0);
    coreLoopQueue = dispatch_queue_create("cenmrev.v2rayxs.coreloop", DISPATCH_QUEUE_SERIAL);
    signal(SIGTERM, SIG_IGN);
    signal(SIGINT, SIG_IGN);
    terminationSignalSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, dispatch_get_main_queue());
    interruptSignalSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGINT, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(terminationSignalSource, ^{
        [self unloadV2ray];
        [self stopTunRoutingSession];
        [[NSApplication sharedApplication] terminate:nil];
    });
    dispatch_source_set_event_handler(interruptSignalSource, ^{
        [self unloadV2ray];
        [self stopTunRoutingSession];
        [[NSApplication sharedApplication] terminate:nil];
    });
    dispatch_resume(terminationSignalSource);
    dispatch_resume(interruptSignalSource);
    
    
    dispatch_async(coreLoopQueue, ^{
        while (true) {
            dispatch_semaphore_wait(self->coreLoopSemaphore, DISPATCH_TIME_FOREVER);
            self->coreProcessPID = 0;
            self->coreProcessStatus = 0;
            self->coreTunFD = -1;
            self->coreConfigPath = nil;
            NSDictionary* xrayTunFDContext = nil;
            if (self->proxyState && self->proxyMode == tunMode && self.useXrayTun && [self currentCoreSupportsXrayTun]) {
                NSString* preferredTunName = [[NSUserDefaults standardUserDefaults] objectForKey:@"xrayTunInterfaceName"];
                NSString* tunFDError = nil;
                appDebugLog(@"coreLoop preparing tun fd preferred=%@", preferredTunName ?: @"");
                xrayTunFDContext = [self->helperClient allocateTunFDWithPreferredName:preferredTunName error:&tunFDError];
                if (xrayTunFDContext == nil) {
                    NSLog(@"%@", tunFDError ?: @"Failed to prepare tun fd for Xray.");
                    helperTunSessionActive = NO;
                    [self reportHelperFailureMessage:tunFDError ?: @"Failed to prepare tun fd for Xray."];
                    continue;
                }
                NSString* actualTunName = xrayTunFDContext[@"tunName"];
                if ([actualTunName isKindOfClass:[NSString class]] && actualTunName.length > 0) {
                    appDebugLog(@"coreLoop prepared tun fd actual=%@ fd=%@", actualTunName, xrayTunFDContext[@"fd"]);
                    [[NSUserDefaults standardUserDefaults] setObject:actualTunName forKey:@"xrayTunInterfaceName"];
                }
                NSString* leaseId = xrayTunFDContext[@"leaseId"];
                if ([leaseId isKindOfClass:[NSString class]] && leaseId.length > 0) {
                    [self setCurrentTunLeaseIdentifier:leaseId];
                }
            }
            [self ensureCoreLogDirectoryExists];
            NSString* temporaryConfigPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"v2rayxs-xray-%@.json", [[NSUUID UUID] UUIDString]]];
            NSData* configData = [NSJSONSerialization dataWithJSONObject:[self generateConfigFile] options:0 error:nil];
            [configData writeToFile:temporaryConfigPath atomically:YES];
            self->coreConfigPath = temporaryConfigPath;
            NSArray* coreArguments = @[@"-config", temporaryConfigPath];
            NSMutableDictionary* environmentOverrides = [[NSMutableDictionary alloc] init];
            if (xrayTunFDContext != nil) {
                int tunFD = [xrayTunFDContext[@"fd"] intValue];
                int fdFlags = fcntl(tunFD, F_GETFD);
                if (fdFlags >= 0) {
                    fcntl(tunFD, F_SETFD, fdFlags & ~FD_CLOEXEC);
                }
                self->coreTunFD = tunFD;
                environmentOverrides[@"xray.tun.fd"] = [NSString stringWithFormat:@"%d", kXrayTunFDTarget];
                environmentOverrides[@"XRAY_TUN_FD"] = [NSString stringWithFormat:@"%d", kXrayTunFDTarget];
            }
            int spawnError = spawnProcess([self getV2rayPath], coreArguments, environmentOverrides, self->coreTunFD, xrayTunFDContext != nil ? kXrayTunFDTarget : -1, &self->coreProcessPID);
            if (spawnError != 0) {
                if (self->coreTunFD >= 0) {
                    close(self->coreTunFD);
                    self->coreTunFD = -1;
                }
                if (self->coreConfigPath.length > 0) {
                    [[NSFileManager defaultManager] removeItemAtPath:self->coreConfigPath error:nil];
                    self->coreConfigPath = nil;
                }
                NSString* message = [NSString stringWithFormat:@"Failed to start Xray (spawn error %d).", spawnError];
                NSLog(@"%@", message);
                [self reportHelperFailureMessage:message];
                continue;
            }
            appDebugLog(@"coreLoop spawned pid=%d mode=%ld tunFD=%d tunName=%@", self->coreProcessPID, (long)self->proxyMode, self->coreTunFD, xrayTunFDContext[@"tunName"] ?: @"");
            if (xrayTunFDContext != nil && self->proxyState && self->proxyMode == tunMode && self.useXrayTun && [self currentCoreSupportsXrayTun]) {
                [self activateXrayTunLeaseAfterCoreSpawn:xrayTunFDContext];
            }
            waitForSpawnedProcess(self->coreProcessPID, &self->coreProcessStatus);
            if (self->coreTunFD >= 0) {
                close(self->coreTunFD);
                self->coreTunFD = -1;
            }
            if (self->coreConfigPath.length > 0) {
                [[NSFileManager defaultManager] removeItemAtPath:self->coreConfigPath error:nil];
                self->coreConfigPath = nil;
            }
            NSLog(@"core exit with code %d", normalizedExitCodeFromWaitStatus(self->coreProcessStatus));
            self->coreProcessPID = 0;
        }
    });
    
    // set up pac server
    //http://stackoverflow.com/questions/14556605/capturing-self-strongly-in-this-block-is-likely-to-lead-to-a-retain-cycle
    webServer = [[GCDWebServer alloc] init];
    [webServer addHandlerForMethod:@"GET" path:@"/proxy.pac" requestClass:[GCDWebServerRequest class] processBlock:^GCDWebServerResponse *(GCDWebServerRequest* request) {
        return [GCDWebServerDataResponse responseWithData:[weakSelf pacData] contentType:@"application/x-ns-proxy-autoconfig"];
    }];
    [webServer addHandlerForMethod:@"GET" path:@"/config.json" requestClass:[GCDWebServerRequest class] processBlock:^GCDWebServerResponse * _Nullable(__kindof GCDWebServerRequest * _Nonnull request) {
        // check uuid
        NSString *uuid = request.query[@"u"];
        if(uuid != NULL) {
            uuid = [uuid uppercaseString];
            if([uuid isEqualToString:weakSelf.webServerUuidString]) {
                return [GCDWebServerDataResponse responseWithData:[weakSelf v2rayJSONconfig] contentType:@"application/json"];
            }
        }
        return [GCDWebServerResponse responseWithStatusCode:404];
    }];

    // only bind localhost
    NSDictionary *options = @{ @"Port": @webServerPort, @"BindToLocalhost": @YES };
    [webServer startWithOptions:options  error:nil];
    
    
    [self checkUpgrade:self];
    
    appDelegate = self;
    
    // resume the service when mac wakes up
    [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self selector:@selector(handleWorkspaceDidWake:) name:NSWorkspaceDidWakeNotification object:NULL];
    
    // initialize UI
    _statusBarItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    [_statusBarItem setHighlightMode:YES];
    _pacModeItem.tag = pacMode;
    _globalModeItem.tag = globalMode;
    _manualModeItem.tag = manualMode;
    _tunModeItem.tag = tunMode;
    
    // read defaults
    [self readDefaults];
    self.encryptionKey = @"";
    if (_enableEncryption && ([profiles count] > 0 || [_subscriptions count] > 0)) {
        NSUserNotification* notification = [[NSUserNotification alloc] init];
        notification.identifier = [NSString stringWithFormat:@"cenmrev.v2rayxs.passwork.%@", [NSUUID UUID]];
        notification.title = @"Input Password";
        notification.informativeText = @"input your password to continue";
        notification.soundName = NSUserNotificationDefaultSoundName;
        notification.actionButtonTitle = @"Continue";
        notification.hasActionButton = true;
        [[NSUserNotificationCenter defaultUserNotificationCenter] deliverNotification:notification];
        [_statusBarItem setMenu:_authMenu];
        [_statusBarItem setImage:[NSImage imageNamed:@"statusBarIcon_disabled"]];
    } else {
        [self continueInitialization];
    }
}

- (IBAction)inputPassword:(id)sender {
    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = @"input password to decrypt configurations";
    [alert addButtonWithTitle:@"Decrypt"];
    [alert addButtonWithTitle:@"Cancel"];
    NSTextField *input = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 0, 200, 24)];
    [input setStringValue:@""];
    [alert setAccessoryView:input];
    [input becomeFirstResponder];
    [alert layout]; //important https://openmcl-devel.clozure.narkive.com/76HRbj5O/how-to-make-an-alert-accessory-view-be-first-responder
    [alert.window makeFirstResponder:input];
    while (true) {
        NSModalResponse response = [alert runModal];
        if (response == NSAlertSecondButtonReturn) {
            return;
        } else {
            BOOL result = [self decryptConfigurationsWithKey:[[input stringValue] stringByPaddingToLength:32 withString:@"-" startingAtIndex:0]];
            if (result) {
                break;
            }
        }
    }
    [self continueInitialization];
}

-(BOOL)decryptConfigurationsWithKey:(NSString*)key {
    NSMutableArray* decryptedLinks = [[NSMutableArray alloc] init];
    for (NSString* encryptedLink in _subscriptions) {
        NSData* encryptedData = [[NSData alloc] initWithBase64EncodedString:encryptedLink options:NSDataBase64DecodingIgnoreUnknownCharacters];
        NSData* decryptedData = [encryptedData decryptedDataWithKey:key];
        if (decryptedData) {
            NSString* decryptedLink = [[NSString alloc] initWithData:decryptedData encoding:NSUTF8StringEncoding];
            if (decryptedLink) {
                [decryptedLinks addObject:decryptedLink];
            } else {
                return false;
            }
        } else {
            return false;
        }
    }
    
    NSMutableArray* decryptedProfiles = [[NSMutableArray alloc] init];
    for (NSString* encryptedJSON in profiles) {
        NSData* encryptedData = [[NSData alloc] initWithBase64EncodedString:encryptedJSON options:NSDataBase64DecodingIgnoreUnknownCharacters];
        NSData* decryptedData = [encryptedData decryptedDataWithKey:key];
        if (decryptedData) {
            NSDictionary* decryptedProfile = [NSJSONSerialization JSONObjectWithData:decryptedData options:0 error:nil];
            if (decryptedProfile) {
                [decryptedProfiles addObject:decryptedProfile];
            } else {
                return false;
            }
        } else {
            return false;
        }
    }
    _subscriptions = decryptedLinks;
    profiles = decryptedProfiles;
    return true;
}

- (void)continueInitialization {
    [_statusBarItem setMenu:_statusBarMenu];
    [self probeTunRoutingSessionState];
    // start proxy
    [self updateSubscriptions:self]; // startup restore is handled after subscriptions are loaded
}

- (void)ensureCoreLogDirectoryExists {
    NSFileManager* fileManager = [NSFileManager defaultManager];
    if (logDirPath.length == 0) {
        NSString* logDirName = @"cenmrev.v2rayx.log";
        logDirPath = [NSString stringWithFormat:@"%@%@", NSTemporaryDirectory(), logDirName];
    }
    [fileManager createDirectoryAtPath:logDirPath withIntermediateDirectories:YES attributes:nil error:nil];
    [fileManager createFileAtPath:[NSString stringWithFormat:@"%@/access.log", logDirPath] contents:nil attributes:nil];
    [fileManager createFileAtPath:[NSString stringWithFormat:@"%@/error.log", logDirPath] contents:nil attributes:nil];
}

- (BOOL)installHelper:(BOOL)force {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString* helperError = nil;
    if (!force && [fileManager fileExistsAtPath:kV2RayXHelper] && [self helperBinaryIsHealthy:&helperError] && [self isSysconfVersionOK]) {
        // helper already installed
        return YES;
    }
    NSAlert *installAlert = [[NSAlert alloc] init];
    [installAlert addButtonWithTitle:@"Install"];
    [installAlert addButtonWithTitle:@"Quit"];
    NSString* installMessage = @"V2RayXS needs to install a small tool to /Library/Application Support/V2RayXS/ with administrator privileges to set system proxy quickly.\nOtherwise you need to type in the administrator password every time you change system proxy through V2RayXS.";
    if (helperError.length > 0) {
        installMessage = [installMessage stringByAppendingFormat:@"\n\nCurrent helper issue: %@", helperError];
    }
    [installAlert setMessageText:installMessage];
    if ([installAlert runModal] == NSAlertFirstButtonReturn) {
        NSLog(@"start install");
        if ([self installHelperBinary:&helperError]) {
            NSLog(@"installation success");
            return YES;
        } else {
            NSLog(@"installation failure: %@", helperError);
            if (helperError.length > 0) {
                NSAlert *failureAlert = [[NSAlert alloc] init];
                failureAlert.messageText = @"Failed to install V2RayXS helper";
                failureAlert.informativeText = helperError;
                [failureAlert runModal];
            }
            return NO;
        }
    } else {
        // stopped by user
        return NO;
    }
}

- (NSString*)helperInstallSourcePath {
    return [NSString stringWithFormat:@"%@/%@", [[NSBundle mainBundle] resourcePath], @"v2rayx_sysconf"];
}

- (NSString*)shellEscapedArgument:(NSString*)argument {
    NSString* escaped = [argument stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];
    return [NSString stringWithFormat:@"'%@'", escaped];
}

- (NSString*)appleScriptStringLiteral:(NSString*)value {
    NSString* escaped = [value stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    return [NSString stringWithFormat:@"\"%@\"", escaped];
}

- (BOOL)installHelperBinary:(NSString**)errorMessage {
    NSString* sourcePath = [self helperInstallSourcePath];
    NSFileManager* fileManager = [NSFileManager defaultManager];
    NSString* sourceError = nil;
    if (![fileManager fileExistsAtPath:sourcePath]) {
        if (errorMessage != NULL) {
            *errorMessage = [NSString stringWithFormat:@"Bundled helper is missing at %@", sourcePath];
        }
        return NO;
    }
    if (![self helperVersionAtPathMatchesCurrentVersion:sourcePath error:&sourceError]) {
        if (errorMessage != NULL) {
            *errorMessage = sourceError ?: @"Bundled helper version does not match the application";
        }
        return NO;
    }

    NSString* helperDirectory = [kV2RayXHelper stringByDeletingLastPathComponent];
    NSString* tempHelperPath = [helperDirectory stringByAppendingPathComponent:[NSString stringWithFormat:@".%@.tmp", [kV2RayXHelper lastPathComponent]]];
    NSString* escapedSource = [self shellEscapedArgument:sourcePath];
    NSString* escapedDirectory = [self shellEscapedArgument:helperDirectory];
    NSString* escapedDestination = [self shellEscapedArgument:kV2RayXHelper];
    NSString* escapedTempPath = [self shellEscapedArgument:tempHelperPath];
    NSString* installCommand = [NSString stringWithFormat:@"/bin/rm -f %@ && /bin/mkdir -p %@ && /usr/bin/install -o root -g admin -m 4755 %@ %@ && /bin/mv -f %@ %@", escapedTempPath, escapedDirectory, escapedSource, escapedTempPath, escapedTempPath, escapedDestination];
    NSString* script = [NSString stringWithFormat:@"do shell script %@ with administrator privileges", [self appleScriptStringLiteral:installCommand]];

    NSDictionary* appleScriptError = nil;
    NSAppleScript* appleScript = [[NSAppleScript new] initWithSource:script];
    if (![appleScript executeAndReturnError:&appleScriptError]) {
        if (errorMessage != NULL) {
            NSString* message = appleScriptError[NSAppleScriptErrorMessage] ?: @"Unknown installation error";
            *errorMessage = message;
        }
        return NO;
    }

    NSString* helperError = nil;
    if (![self helperBinaryIsHealthy:&helperError]) {
        if (errorMessage != NULL) {
            *errorMessage = helperError ?: @"Installed helper did not pass validation";
        }
        return NO;
    }

    if (![self helperVersionAtPathMatchesCurrentVersion:kV2RayXHelper error:&helperError]) {
        if (errorMessage != NULL) {
            *errorMessage = helperError ?: @"Installed helper version does not match the application bundle";
        }
        return NO;
    }

    return YES;
}

- (BOOL)helperBinaryIsHealthy:(NSString**)errorMessage {
    return [self helperBinaryAtPathIsHealthy:kV2RayXHelper error:errorMessage];
}

- (BOOL)helperBinaryAtPathIsHealthy:(NSString*)helperPath error:(NSString**)errorMessage {
    struct stat helperStat;
    if (lstat([helperPath fileSystemRepresentation], &helperStat) != 0) {
        if (errorMessage != NULL) {
            *errorMessage = [NSString stringWithFormat:@"helper binary is missing at %@", helperPath];
        }
        return NO;
    }

    if (!S_ISREG(helperStat.st_mode)) {
        if (errorMessage != NULL) {
            *errorMessage = @"helper path is not a regular file";
        }
        return NO;
    }

    if (helperStat.st_uid != 0) {
        if (errorMessage != NULL) {
            *errorMessage = [NSString stringWithFormat:@"helper owner is %u instead of root", helperStat.st_uid];
        }
        return NO;
    }

    if ((helperStat.st_mode & S_ISUID) == 0) {
        if (errorMessage != NULL) {
            *errorMessage = @"helper is missing the setuid bit";
        }
        return NO;
    }

    if ((helperStat.st_mode & S_IXUSR) == 0) {
        if (errorMessage != NULL) {
            *errorMessage = @"helper is not executable";
        }
        return NO;
    }

    return YES;
}

- (NSString*)helperVersionAtPath:(NSString*)helperPath error:(NSString**)errorMessage {
    NSTask* task = [[NSTask alloc] init];
    if (@available(macOS 10.13, *)) {
        [task setExecutableURL:[NSURL fileURLWithPath:helperPath]];
    } else {
        [task setLaunchPath:helperPath];
    }
    [task setArguments:@[@"-v"]];

    NSPipe* stdoutPipe = [NSPipe pipe];
    NSPipe* stderrPipe = [NSPipe pipe];
    [task setStandardOutput:stdoutPipe];
    [task setStandardError:stderrPipe];

    @try {
        [task launch];
    } @catch (NSException *exception) {
        if (errorMessage != NULL) {
            *errorMessage = exception.reason ?: @"Failed to launch helper for version check";
        }
        return nil;
    }

    NSData* stdoutData = [[stdoutPipe fileHandleForReading] readDataToEndOfFile];
    NSData* stderrData = [[stderrPipe fileHandleForReading] readDataToEndOfFile];
    [task waitUntilExit];

    NSString* stdoutString = [[NSString alloc] initWithData:stdoutData encoding:NSUTF8StringEncoding] ?: @"";
    NSString* stderrString = [[NSString alloc] initWithData:stderrData encoding:NSUTF8StringEncoding] ?: @"";
    if ([task terminationStatus] != 0) {
        if (errorMessage != NULL) {
            NSString* trimmedStderr = [stderrString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if ([trimmedStderr isEqualToString:@""]) {
                trimmedStderr = [NSString stringWithFormat:@"helper exited with code %d", [task terminationStatus]];
            }
            *errorMessage = trimmedStderr;
        }
        return nil;
    }

    return stdoutString;
}

- (BOOL)helperVersionAtPathMatchesCurrentVersion:(NSString*)helperPath error:(NSString**)errorMessage {
    NSString* helperVersion = [self helperVersionAtPath:helperPath error:errorMessage];
    if (helperVersion == nil) {
        return NO;
    }
    if (![helperVersion isEqualToString:VERSION]) {
        if (errorMessage != NULL) {
            NSString* trimmedVersion = [helperVersion stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            *errorMessage = [NSString stringWithFormat:@"helper version mismatch at %@: expected `%@`, got `%@`", helperPath, VERSION, trimmedVersion];
        }
        return NO;
    }
    return YES;
}

- (void)presentHelperFailureAlert:(NSString*)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString* rawMessage = [message isKindOfClass:[NSString class]] ? message : @"Unknown helper failure.";
        NSString* normalizedMessage = [rawMessage stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (normalizedMessage.length == 0) {
            normalizedMessage = @"Unknown helper failure.";
        }
        NSString* alertKey = [NSString stringWithFormat:@"helper:%@", normalizedMessage];
        NSDate* now = [NSDate date];
        if (self->helperFailureAlertVisible) {
            appDebugLog(@"suppress helper failure alert while modal visible: %@", normalizedMessage);
            return;
        }
        if ([self->lastPresentedHelperFailureKey isEqualToString:alertKey] && self->lastPresentedHelperFailureAt != nil && [now timeIntervalSinceDate:self->lastPresentedHelperFailureAt] < 15.0) {
            appDebugLog(@"suppress duplicate helper failure alert: %@", normalizedMessage);
            return;
        }
        self->helperFailureAlertVisible = YES;
        self->lastPresentedHelperFailureKey = alertKey;
        self->lastPresentedHelperFailureAt = now;
        NSAlert* alert = [[NSAlert alloc] init];
        alert.messageText = @"V2RayXS helper failed";
        alert.informativeText = normalizedMessage;
        [alert addButtonWithTitle:@"OK"];
        [alert runModal];
        self->helperFailureAlertVisible = NO;
    });
}

- (void)reportHelperFailureMessage:(NSString*)message {
    [self presentHelperFailureAlert:message];
}

- (NSString*)currentHelperIssueMessage {
    NSString* helperError = nil;
    [self helperBinaryIsHealthy:&helperError];
    return helperError;
}

- (void)collectServerAddressesFromOutbound:(NSDictionary*)outbound into:(NSMutableArray<NSString*>*)serverAddresses {
    NSArray* vnextList = outbound[@"settings"][@"vnext"];
    if ([vnextList isKindOfClass:[NSArray class]]) {
        for (NSDictionary* vnextItem in vnextList) {
            NSString* address = vnextItem[@"address"];
            if ([address isKindOfClass:[NSString class]] && address.length > 0 && ![serverAddresses containsObject:address]) {
                [serverAddresses addObject:address];
            }
        }
    }
    NSArray* serversList = outbound[@"settings"][@"servers"];
    if ([serversList isKindOfClass:[NSArray class]]) {
        for (NSDictionary* serverItem in serversList) {
            NSString* address = serverItem[@"address"] ?: serverItem[@"server"];
            if ([address isKindOfClass:[NSString class]] && address.length > 0 && ![serverAddresses containsObject:address]) {
                [serverAddresses addObject:address];
            }
        }
    }
}

- (void)collectServerAddressesFromConfigObject:(id)jsonObject into:(NSMutableArray<NSString*>*)serverAddresses {
    if (![jsonObject isKindOfClass:[NSDictionary class]]) {
        return;
    }
    NSDictionary* configObject = (NSDictionary*)jsonObject;
    NSDictionary* outbound = configObject[@"outbound"];
    if ([outbound isKindOfClass:[NSDictionary class]]) {
        [self collectServerAddressesFromOutbound:outbound into:serverAddresses];
    }
    NSArray* outbounds = configObject[@"outbounds"];
    if ([outbounds isKindOfClass:[NSArray class]]) {
        for (NSDictionary* candidate in outbounds) {
            if ([candidate isKindOfClass:[NSDictionary class]]) {
                [self collectServerAddressesFromOutbound:candidate into:serverAddresses];
            }
        }
    }
    NSArray* outboundDetour = configObject[@"outboundDetour"];
    if ([outboundDetour isKindOfClass:[NSArray class]]) {
        for (NSDictionary* candidate in outboundDetour) {
            if ([candidate isKindOfClass:[NSDictionary class]]) {
                [self collectServerAddressesFromOutbound:candidate into:serverAddresses];
            }
        }
    }
}

- (NSArray<NSString*>*)resolvedIPAddressesFromHosts:(NSArray<NSString*>*)hosts {
    NSMutableOrderedSet<NSString*>* resolvedIPs = [[NSMutableOrderedSet alloc] init];
    for (NSString* host in hosts) {
        if (![host isKindOfClass:[NSString class]] || host.length == 0) {
            continue;
        }
        struct addrinfo hints;
        memset(&hints, 0, sizeof(hints));
        hints.ai_family = AF_UNSPEC;
        hints.ai_socktype = SOCK_STREAM;
        hints.ai_flags = AI_ADDRCONFIG;

        struct addrinfo* results = NULL;
        if (getaddrinfo([host UTF8String], NULL, &hints, &results) != 0) {
            continue;
        }

        for (struct addrinfo* cursor = results; cursor != NULL; cursor = cursor->ai_next) {
            char addressBuffer[INET6_ADDRSTRLEN] = {0};
            const void* addrPtr = NULL;
            if (cursor->ai_family == AF_INET) {
                addrPtr = &((struct sockaddr_in*)cursor->ai_addr)->sin_addr;
                inet_ntop(AF_INET, addrPtr, addressBuffer, sizeof(addressBuffer));
            } else if (cursor->ai_family == AF_INET6) {
                addrPtr = &((struct sockaddr_in6*)cursor->ai_addr)->sin6_addr;
                inet_ntop(AF_INET6, addrPtr, addressBuffer, sizeof(addressBuffer));
            }
            if (addressBuffer[0] != '\0') {
                [resolvedIPs addObject:[NSString stringWithUTF8String:addressBuffer]];
            }
        }
        freeaddrinfo(results);
    }
    return [resolvedIPs array];
}

- (NSArray<NSString*>*)tunWhitelistIPAddresses {
    NSMutableArray<NSString*>* serverAddresses = [[NSMutableArray alloc] init];
    if (!useCusProfile) {
        NSDictionary* fullConfig = [self generateConfigFile];
        NSArray* generatedOutbounds = fullConfig[@"outbounds"];
        if ([generatedOutbounds isKindOfClass:[NSArray class]]) {
            for (NSDictionary* outbound in generatedOutbounds) {
                if ([outbound isKindOfClass:[NSDictionary class]]) {
                    [self collectServerAddressesFromOutbound:outbound into:serverAddresses];
                }
            }
        }
    } else if (selectedCusServerIndex >= 0 && selectedCusServerIndex < cusProfiles.count) {
        NSData* customProfileData = [NSData dataWithContentsOfFile:cusProfiles[selectedCusServerIndex]];
        NSDictionary* customJSON = customProfileData != nil ? [NSJSONSerialization JSONObjectWithData:customProfileData options:0 error:nil] : nil;
        [self collectServerAddressesFromConfigObject:customJSON into:serverAddresses];
    }
    return [self resolvedIPAddressesFromHosts:serverAddresses];
}

- (NSString*)currentTunLeaseIdentifier {
    NSString* leaseId = [[NSUserDefaults standardUserDefaults] objectForKey:kStoredTunLeaseIdKey];
    return [leaseId isKindOfClass:[NSString class]] ? leaseId : nil;
}

- (void)setCurrentTunLeaseIdentifier:(NSString*)leaseId {
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    if ([leaseId isKindOfClass:[NSString class]] && leaseId.length > 0) {
        [defaults setObject:leaseId forKey:kStoredTunLeaseIdKey];
    } else {
        [defaults removeObjectForKey:kStoredTunLeaseIdKey];
    }
}

- (void)updateTunRoutingSessionStatusFromPayload:(NSDictionary*)payload {
    NSDictionary* normalizedPayload = [payload isKindOfClass:[NSDictionary class]] ? payload : nil;
    helperTunSessionStatus = normalizedPayload;
    NSString* sessionState = [normalizedPayload[@"session"] isKindOfClass:[NSString class]] ? normalizedPayload[@"session"] : nil;
    helperTunSessionActive = [sessionState isKindOfClass:[NSString class]] && ![sessionState isEqualToString:@"inactive"];

    NSString* tunName = [normalizedPayload[@"tunName"] isKindOfClass:[NSString class]] ? normalizedPayload[@"tunName"] : nil;
    if (tunName.length > 0) {
        [[NSUserDefaults standardUserDefaults] setObject:tunName forKey:@"xrayTunInterfaceName"];
    }

    NSString* leaseId = [normalizedPayload[@"leaseId"] isKindOfClass:[NSString class]] ? normalizedPayload[@"leaseId"] : nil;
    [self setCurrentTunLeaseIdentifier:leaseId];
}

- (NSString*)currentTunSessionState {
    NSDictionary* status = [self currentTunRoutingSessionStatus];
    NSString* sessionState = [status[@"session"] isKindOfClass:[NSString class]] ? status[@"session"] : nil;
    return sessionState.length > 0 ? sessionState : @"inactive";
}

- (NSString*)currentTunInterfaceName {
    NSDictionary* status = [self currentTunRoutingSessionStatus];
    NSString* tunName = [status[@"tunName"] isKindOfClass:[NSString class]] ? status[@"tunName"] : nil;
    if (tunName.length > 0) {
        return tunName;
    }
    NSString* storedTunName = [[NSUserDefaults standardUserDefaults] objectForKey:@"xrayTunInterfaceName"];
    return [storedTunName isKindOfClass:[NSString class]] ? storedTunName : nil;
}

- (BOOL)shouldTreatTunSessionAsActive {
    return ![[self currentTunSessionState] isEqualToString:@"inactive"];
}

- (NSString*)tunStatusDisplayText {
    NSDictionary* status = [self currentTunRoutingSessionStatus];
    NSString* sessionState = [self currentTunSessionState];
    NSString* tunName = [self currentTunInterfaceName];
    NSString* leaseId = [self currentTunLeaseIdentifier];
    NSString* lastError = [status[@"lastError"] isKindOfClass:[NSString class]] ? status[@"lastError"] : nil;
    if (lastError.length == 0) {
        NSDictionary* history = [status[@"history"] isKindOfClass:[NSDictionary class]] ? status[@"history"] : nil;
        lastError = [history[@"lastError"] isKindOfClass:[NSString class]] ? history[@"lastError"] : nil;
    }
    NSDictionary* diagnostics = [status[@"diagnostics"] isKindOfClass:[NSDictionary class]] ? status[@"diagnostics"] : nil;

    NSMutableArray<NSString*>* parts = [[NSMutableArray alloc] init];
    [parts addObject:[NSString stringWithFormat:@"tun: %@", sessionState]];
    if (tunName.length > 0) {
        [parts addObject:[NSString stringWithFormat:@"if=%@", tunName]];
    }
    if (leaseId.length > 0) {
        [parts addObject:[NSString stringWithFormat:@"lease=%@", leaseId]];
    }
    if (lastError.length > 0) {
        [parts addObject:[NSString stringWithFormat:@"error=%@", lastError]];
    }
    if ([diagnostics isKindOfClass:[NSDictionary class]] && diagnostics.count > 0) {
        NSMutableArray<NSString*>* diagnosticParts = [[NSMutableArray alloc] init];
        if ([diagnostics[@"staleSocket"] boolValue]) {
            [diagnosticParts addObject:@"stale socket"];
        }
        if ([diagnostics[@"staleLock"] boolValue]) {
            [diagnosticParts addObject:@"stale lock"];
        }
        NSNumber* historicalBackup = [diagnostics[@"historicalBackup"] isKindOfClass:[NSNumber class]] ? diagnostics[@"historicalBackup"] : nil;
        if (historicalBackup != nil && historicalBackup.integerValue > 0) {
            [diagnosticParts addObject:[NSString stringWithFormat:@"historical backup=%ld", (long)historicalBackup.integerValue]];
        }
        if (diagnosticParts.count > 0) {
            [parts addObject:[NSString stringWithFormat:@"diag=%@", [diagnosticParts componentsJoinedByString:@", "]]];
        }
    }
    return [parts componentsJoinedByString:@" | "];
}

- (void)reconcileTunSessionForCurrentRuntime {
    [self probeTunRoutingSessionState];
    if (self.proxyMode != tunMode) {
        if ([self shouldTreatTunSessionAsActive]) {
            appDebugLog(@"reconcileTunSessionForCurrentRuntime stopping stray session %@", [self tunStatusDisplayText]);
            [self stopTunRoutingSession];
            [self probeTunRoutingSessionState];
        }
        return;
    }

    if (!self.proxyState) {
        if ([self shouldTreatTunSessionAsActive]) {
            appDebugLog(@"reconcileTunSessionForCurrentRuntime cleaning inactive-proxy session %@", [self tunStatusDisplayText]);
            [self stopTunRoutingSession];
            [self probeTunRoutingSessionState];
        }
        return;
    }

    if (self.useXrayTun && [self currentCoreSupportsXrayTun]) {
        if (coreProcessPID <= 0 && [self shouldTreatTunSessionAsActive]) {
            appDebugLog(@"reconcileTunSessionForCurrentRuntime found helper-active/core-stopped session %@", [self tunStatusDisplayText]);
            [self stopTunRoutingSession];
            [self probeTunRoutingSessionState];
        }
    }
}

- (void)handleWorkspaceDidWake:(NSNotification*)notification {
    [self reconcileTunSessionForCurrentRuntime];
    [self didChangeStatus:notification.object ?: self];
}

- (void)activateXrayTunLeaseAfterCoreSpawn:(NSDictionary*)xrayTunFDContext {
    if (![xrayTunFDContext isKindOfClass:[NSDictionary class]]) {
        return;
    }
    NSString* leaseId = [xrayTunFDContext[@"leaseId"] isKindOfClass:[NSString class]] ? xrayTunFDContext[@"leaseId"] : nil;
    if (leaseId.length == 0) {
        appDebugLog(@"activateXrayTunLeaseAfterCoreSpawn missing lease id");
        return;
    }
    dispatch_async(taskQueue, ^{
        NSString* tunName = [xrayTunFDContext[@"tunName"] isKindOfClass:[NSString class]] ? xrayTunFDContext[@"tunName"] : nil;
        if (tunName.length > 0) {
            appDebugLog(@"activateXrayTunLeaseAfterCoreSpawn waiting for tun=%@ lease=%@", tunName, leaseId);
            (void)[self waitForTunInterfaceNamed:tunName timeout:5.0];
        }
        NSDictionary* helperResponse = [self->helperClient activateTunLeaseSynchronouslyWithLeaseId:leaseId action:@"activate Xray tun lease after core spawn"];
        if ([helperResponse isKindOfClass:[NSDictionary class]]) {
            NSDictionary* statusPayload = [helperResponse[@"status"] isKindOfClass:[NSDictionary class]] ? helperResponse[@"status"] : helperResponse;
            [self updateTunRoutingSessionStatusFromPayload:statusPayload];
            [self syncTunWhitelistRoutes];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self updateMenus];
            });
            appDebugLog(@"activateXrayTunLeaseAfterCoreSpawn session=%@ lease=%@", statusPayload[@"session"] ?: @"", leaseId);
        }
    });
}

- (void)syncTunWhitelistRoutes {
    if (self.proxyMode != tunMode || !self.proxyState) {
        return;
    }
    NSArray<NSString*>* tunWhitelistIPs = [self tunWhitelistIPAddresses];
    if (tunWhitelistIPs.count > 0) {
        NSMutableArray* syncArguments = [NSMutableArray arrayWithObject:@"route"];
        [syncArguments addObject:@"sync-file"];
        NSString* tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"v2rayxs_tun_whitelist.json"];
        NSData* whitelistData = [NSJSONSerialization dataWithJSONObject:tunWhitelistIPs options:0 error:nil];
        if (whitelistData != nil) {
            [whitelistData writeToFile:tempPath atomically:YES];
            [syncArguments addObject:tempPath];
            [helperClient syncRouteWhitelistAtPath:tempPath action:@"sync tun whitelist routes"];
        }
    } else {
        [helperClient clearRouteWhitelistWithAction:@"clear tun whitelist routes"];
    }
}

- (BOOL)isUsingXrayTunMode {
    return self.proxyMode == tunMode && self.useXrayTun && [self currentCoreSupportsXrayTun];
}

- (void)stopEmbeddedTunSessionIfNeeded {
    if (helperApplicationTask != NULL && [helperApplicationTask isRunning]) {
        [self stopTunRoutingSession];
    }
}

- (void)applyNonXrayNetworkMode {
    NSArray* arguments = nil;
    if (proxyMode == manualMode) {
        arguments = @[@"-v"];
    } else if (proxyMode == pacMode) {
        arguments = @[@"auto"];
    } else {
        NSInteger cusHttpPort = 0;
        NSInteger cusSocksPort = 0;
        if(useMultipleServer || !useCusProfile) {
            arguments = @[@"global", [NSString stringWithFormat:@"%ld", localPort], [NSString stringWithFormat:@"%ld", httpPort]];
        } else {
            NSDictionary* cusJson = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:cusProfiles[selectedCusServerIndex]] options:0 error:nil];
            if (cusJson[@"inboundDetour"] != nil && [cusJson[@"inboundDetour"] isKindOfClass:[NSArray class]]) {
                for (NSDictionary *inboundDetour in cusJson[@"inboundDetour"]) {
                    if ([inboundDetour[@"protocol"] isEqualToString:@"http"]) {
                        cusHttpPort = [inboundDetour[@"port"] integerValue];
                    }
                    if ([inboundDetour[@"protocol"] isEqualToString:@"socks"]) {
                        cusSocksPort = [inboundDetour[@"port"] integerValue];
                    }
                }
            }
            if ([cusJson[@"inbound"][@"protocol"] isEqualToString:@"http"]) {
                cusHttpPort = [cusJson[@"inbound"][@"port"] integerValue];
            }
            if ([cusJson[@"inbound"][@"protocol"] isEqualToString:@"socks"]) {
                cusSocksPort = [cusJson[@"inbound"][@"port"] integerValue];
            }
            NSLog(@"socks: %ld, http: %ld", cusSocksPort, cusHttpPort);
            arguments = @[@"global", [NSString stringWithFormat:@"%ld", cusSocksPort], [NSString stringWithFormat:@"%ld", cusHttpPort]];
        }
    }

    dispatch_async(taskQueue, ^{
        HelperClient* client = self->helperClient;
        BOOL shouldPreDisableProxy = (self.proxyMode == pacMode) || (self.proxyMode == tunMode && ![self isUsingXrayTunMode]);
        if (shouldPreDisableProxy) {
            NSString* action = self.proxyMode == pacMode ? @"disable system proxy before PAC refresh" : @"disable system proxy before enabling tun mode";
            [client disableSystemProxyWithAction:action];
        }
        if (self.proxyMode == tunMode) {
            [self syncTunWhitelistRoutes];
        }
        appDebugLog(@"applyNonXrayNetworkMode running helper args=%@", [arguments componentsJoinedByString:@" "]);
        NSDictionary* helperResponse = self.proxyMode == tunMode ? [client startEmbeddedTunWithLocalPort:self->localPort action:@"apply helper network settings"] : [client runJSONCommandWithArguments:arguments action:@"apply helper network settings"];
        if ([helperResponse isKindOfClass:[NSDictionary class]]) {
            NSDictionary* statusPayload = [helperResponse[@"status"] isKindOfClass:[NSDictionary class]] ? helperResponse[@"status"] : helperResponse;
            [self updateTunRoutingSessionStatusFromPayload:statusPayload];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self updateMenus];
            });
        }
    });
}

- (BOOL)shouldMaintainTunRoutingSession {
    return self.proxyState && self.proxyMode == tunMode;
}

- (BOOL)hasActiveTunRoutingSession {
    return [self shouldTreatTunSessionAsActive];
}

- (NSDictionary*)currentTunRoutingSessionStatus {
    return helperTunSessionStatus;
}

- (void)probeTunRoutingSessionState {
    NSDictionary* payload = [helperClient tunStatusWithAction:@"probe tun routing session state"];
    if (![payload isKindOfClass:[NSDictionary class]]) {
        helperTunSessionStatus = nil;
        helperTunSessionActive = NO;
        [self setCurrentTunLeaseIdentifier:nil];
        return;
    }
    [self updateTunRoutingSessionStatusFromPayload:payload];
}

- (void)stopTunRoutingSession {
    if (![self shouldTreatTunSessionAsActive] && proxyMode != tunMode) {
        return;
    }
    dispatch_sync(taskQueue, ^{
        closeHelperApplicationTask();
    });
    [self stopHelperDaemonIfRunning];
}

- (void)stopHelperDaemonIfRunning {
    NSDictionary* status = [helperClient helperDaemonStatusWithAction:@"check daemon before stop"];
    if ([[status objectForKey:@"daemon"] isEqualToString:@"available"]) {
        [helperClient stopHelperDaemonWithAction:@"stop helper daemon"];
    }
}

- (void)refreshTunRoutingSession {
    if (![self shouldMaintainTunRoutingSession]) {
        [self stopTunRoutingSession];
        return;
    }
    appDebugLog(@"refreshTunRoutingSession entering proxyMode=%ld corePID=%d helperActive=%d session=%@ lease=%@", (long)proxyMode, coreProcessPID, [self shouldTreatTunSessionAsActive], [self currentTunSessionState], [self currentTunLeaseIdentifier] ?: @"");
    [self updateSystemProxy];
}

- (NSString*)availableUtunName {
    NSSet<NSString*>* existing = [NSSet setWithArray:[self existingUtunInterfaces]];
    for (NSInteger index = 10; index < 256; index++) {
        NSString* candidate = [NSString stringWithFormat:@"utun%ld", (long)index];
        if (![existing containsObject:candidate]) {
            return candidate;
        }
    }
    return @"utun233";
}

- (NSArray<NSString*>*)existingUtunInterfaces {
    NSTask* task = [[NSTask alloc] init];
    if (@available(macOS 10.13, *)) {
        [task setExecutableURL:[NSURL fileURLWithPath:@"/sbin/ifconfig"]];
    } else {
        [task setLaunchPath:@"/sbin/ifconfig"];
    }
    NSPipe* stdoutPipe = [NSPipe pipe];
    [task setStandardOutput:stdoutPipe];
    [task setStandardInput:nullInputHandle()];
    @try {
        [task launch];
        [task waitUntilExit];
    } @catch (NSException *exception) {
        return @[];
    }
    NSData* data = [[stdoutPipe fileHandleForReading] readDataToEndOfFile];
    NSString* output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    NSMutableArray<NSString*>* interfaces = [[NSMutableArray alloc] init];
    [output enumerateLinesUsingBlock:^(NSString * _Nonnull line, BOOL * _Nonnull stop) {
        NSRange colonRange = [line rangeOfString:@":"];
        if (colonRange.location == NSNotFound) {
            return;
        }
        NSString* name = [line substringToIndex:colonRange.location];
        if ([name hasPrefix:@"utun"]) {
            [interfaces addObject:name];
        }
    }];
    return interfaces;
}

- (BOOL)waitForTunInterfaceNamed:(NSString*)tunName timeout:(NSTimeInterval)timeout {
    if (![tunName isKindOfClass:[NSString class]] || tunName.length == 0) {
        return NO;
    }
    NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:MAX(timeout, 0)];
    while ([[NSDate date] compare:deadline] != NSOrderedDescending) {
        if ([[self existingUtunInterfaces] containsObject:tunName]) {
            return YES;
        }
        [NSThread sleepForTimeInterval:0.1];
    }
    return [[self existingUtunInterfaces] containsObject:tunName];
}

- (BOOL)isSysconfVersionOK {
    return [self helperVersionAtPathMatchesCurrentVersion:kV2RayXHelper error:nil];
}

- (IBAction)openReleasePage:(id)sender {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"https://github.com/tzmax/V2RayXS/releases/latest"]];
}

- (IBAction)checkUpgrade:(id)sender {
    NSURL* url =[NSURL URLWithString:@"https://api.github.com/repos/tzmax/v2rayxs/releases/latest"];
    NSURLSessionDataTask* task = [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        __block BOOL shouldShowUpgrade = NO;
        @try {
            if (error == nil && data != nil) {
                NSDictionary* d = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                NSString* tagName = [d[@"tag_name"] isKindOfClass:[NSString class]] ? d[@"tag_name"] : nil;
                NSString* currentVersionString = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleShortVersionString"];
                if ([d[@"prerelease"] isEqualToNumber:@NO] && tagName.length > 1 && currentVersionString.length > 0) {
                NSNumberFormatter* f = [[NSNumberFormatter alloc] init];
                f.numberStyle = NSNumberFormatterDecimalStyle;
                    NSArray* newVersion = [[tagName substringFromIndex:1] componentsSeparatedByString:@"."];
                    NSArray* currentVersion = [currentVersionString componentsSeparatedByString:@"."];
                    NSInteger compareCount = MIN((NSInteger)newVersion.count, (NSInteger)currentVersion.count);
                    for (NSInteger i = 0; i < compareCount; i += 1) {
                    NSInteger newv = [[f numberFromString:newVersion[i]] integerValue];
                    NSInteger currentv = [[f numberFromString:currentVersion[i]] integerValue];
                    if (newv > currentv) {
                            shouldShowUpgrade = YES;
                            break;
                        }
                        if (newv < currentv) {
                            break;
                        }
                    }
                }
            }
        } @catch (NSException *exception) {
        } @finally {
            ;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            BOOL shouldHideUpgrade = !shouldShowUpgrade;
            if (self.upgradeMenuItem.hidden != shouldHideUpgrade) {
                self.upgradeMenuItem.hidden = shouldHideUpgrade;
            }
        });
    }];
    [task resume];
}

- (void)readDefaults {
    // just read defaults, didChangeStatus will handle invalid parameters.
    // return encrypted or not
    
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSDictionary* appStatus = nilCoalescing([defaults objectForKey:@"appStatus"], @{});
    
    proxyState = [nilCoalescing(appStatus[@"proxyState"], @(NO)) boolValue]; //turn off proxy as default
    proxyMode = [nilCoalescing(appStatus[@"proxyMode"], @(manualMode)) integerValue];
    selectedServerIndex = [nilCoalescing(appStatus[@"selectedServerIndex"], @0) integerValue];
    selectedCusServerIndex = [nilCoalescing(appStatus[@"selectedCusServerIndex"], @0) integerValue];
    _selectedRoutingSet = [nilCoalescing(appStatus[@"selectedRoutingSet"], @0) integerValue];
    useMultipleServer = [nilCoalescing(appStatus[@"useMultipleServer"], @(NO)) boolValue];
    useCusProfile = [nilCoalescing(appStatus[@"useCusProfile"], @(NO)) boolValue];
    self.selectedPacFileName = nilCoalescing(appStatus[@"selectedPacFileName"], @"pac.js");
    
    _enableEncryption = [nilCoalescing([defaults objectForKey:@"enableEncryption"], @(NO)) boolValue];
    _useXrayTun = [nilCoalescing([defaults objectForKey:@"useXrayTun"], @(NO)) boolValue];
    logLevel = nilCoalescing([defaults objectForKey:@"logLevel"], @"none");
    localPort = [nilCoalescing([defaults objectForKey:@"localPort"], @1081) integerValue]; //use 1081 as default local port
    httpPort = [nilCoalescing([defaults objectForKey:@"httpPort"], @8001) integerValue]; //use 8001 as default local http port
    udpSupport = [nilCoalescing([defaults objectForKey:@"udpSupport"], @(NO)) boolValue];// do not support udp as default
    shareOverLan = [nilCoalescing([defaults objectForKey:@"shareOverLan"],@(NO)) boolValue];
    dnsString = nilCoalescing([defaults objectForKey:@"dnsString"], @"localhost");
    _enableRestore = [nilCoalescing([defaults objectForKey:@"enableRestore"],@(NO)) boolValue];
    
    profiles = [[NSMutableArray alloc] init];
    if ([defaults objectForKey:@"profiles"] && [[defaults objectForKey:@"profiles"] isKindOfClass:[NSArray class]]) {
        if (!_enableEncryption) {
            for (NSDictionary* aProfile in [defaults objectForKey:@"profiles"]) {
                if ([aProfile isKindOfClass:[NSDictionary class]] && aProfile[@"tag"] && [aProfile[@"tag"] length] && [RESERVED_TAGS indexOfObject:aProfile[@"tag"]] == NSNotFound) {
                    [profiles addObject:aProfile];
                }
            }
        } else {
            for (NSString* encrypted in [defaults objectForKey:@"profiles"]) {
                if ([encrypted isKindOfClass:[NSString class]]) {
                    [profiles addObject:encrypted];
                }
            }
        }
    }
    
    cusProfiles = [[NSMutableArray alloc] init];
    if ([[defaults objectForKey:@"cusProfiles"] isKindOfClass:[NSArray class]] && [[defaults objectForKey:@"cusProfiles"] count] > 0) {
        for (id cusPorfile in [defaults objectForKey:@"cusProfiles"]) {
            if ([cusPorfile isKindOfClass:[NSString class]]) {
                [cusProfiles addObject:cusPorfile];
            }
        }
    }
    
    _subscriptions = [[NSMutableArray alloc] init];
    if ([defaults objectForKey:@"subscriptions"] && [[defaults objectForKey:@"subscriptions"] isKindOfClass:[NSArray class]]) {
        for (NSString* link in [defaults objectForKey:@"subscriptions"]) {
            if ([link isKindOfClass:[NSString class]]) {
                [_subscriptions addObject:link];
            }
        }
    }
    
    _routingRuleSets = [@[ROUTING_GLOBAL, ROUTING_BYPASSCN_PRIVATE_APPLE, ROUTING_DIRECT] mutableDeepCopy];
    if ([[defaults objectForKey:@"routingRuleSets"] isKindOfClass:[NSArray class]] && [[defaults objectForKey:@"routingRuleSets"] count] > 0) {
        _routingRuleSets = [[defaults objectForKey:@"routingRuleSets"] mutableDeepCopy];
    }
}

- (void) writeDefaultSettings {
    NSDictionary *defaultSettings =
    @{
      @"setingVersion": [NSNumber numberWithInteger:kV2RayXSettingVersion],
      @"appStatus": @{
              @"proxyState": [NSNumber numberWithBool:NO],
              @"proxyMode": @(manualMode),
              @"selectedServerIndex": [NSNumber numberWithInteger:0],
              @"selectedCusServerIndex": [NSNumber numberWithInteger:-1],
              @"useCusProfile": @NO,
              @"selectedRoutingSet":@0,
              @"useMultipleServer": @NO,
              @"selectedPacFileName": @"pac.js"
              },
      @"enableEncryption":@(NO),
      @"useXrayTun":@(NO),
      @"logLevel": @"none",
      @"localPort": [NSNumber numberWithInteger:1081],
      @"httpPort": [NSNumber numberWithInteger:8001],
      @"udpSupport": [NSNumber numberWithBool:NO],
      @"shareOverLan": [NSNumber numberWithBool:NO],
      @"dnsString": @"localhost",
      @"profiles":@[
              [[[ServerProfile alloc] init] outboundProfile]
              ],
      @"cusProfiles": @[],
      @"enableRestore": @NO,
      @"routingRuleSets": @[ROUTING_GLOBAL, ROUTING_BYPASSCN_PRIVATE_APPLE, ROUTING_DIRECT],
      };
    for (NSString* key in [defaultSettings allKeys]) {
        [[NSUserDefaults standardUserDefaults] setObject:defaultSettings[key] forKey:key];
    }
}

- (NSData*) pacData {
    return [NSData dataWithContentsOfFile:[NSString stringWithFormat:@"%@/Library/Application Support/V2RayXS/pac/%@",NSHomeDirectory(), selectedPacFileName]];
}

- (void)saveAppStatus {
    NSDictionary* status = @{
                             @"proxyState": @(proxyState),
                             @"proxyMode": @(proxyMode),
                             @"selectedServerIndex": @(selectedServerIndex),
                             @"selectedCusServerIndex": @(selectedCusServerIndex),
                             @"useCusProfile": @(useCusProfile),
                             @"selectedRoutingSet":@(_selectedRoutingSet),
                             @"useMultipleServer": @(useMultipleServer),
                             @"selectedPacFileName": selectedPacFileName
                             };
    [[NSUserDefaults standardUserDefaults] setObject:status forKey:@"appStatus"];
}

- (void)saveConfigInfo {
    dispatch_async(taskQueue, ^{
        NSMutableArray* subscriptionToSave;
        NSMutableArray* profilesToSave;
        if (self->_enableEncryption) {
            subscriptionToSave = [[NSMutableArray alloc] init];
            for (NSString* link in self->_subscriptions) {
                [subscriptionToSave addObject:[[[link dataUsingEncoding:NSUTF8StringEncoding] encryptedDataWithKey:self->_encryptionKey] base64EncodedStringWithOptions:0]];
            }
            profilesToSave = [[NSMutableArray alloc] init];
            for (NSDictionary* profile in self->profiles) {
                NSData* jsonData = [NSJSONSerialization dataWithJSONObject:profile options:0 error:nil];
                [profilesToSave addObject:[[jsonData encryptedDataWithKey:self->_encryptionKey] base64EncodedStringWithOptions:0]];
            }
        } else {
            subscriptionToSave = self->_subscriptions;
            profilesToSave = self->profiles;
        }
        NSDictionary *settings =
        @{
          @"enableEncryption":@(self->_enableEncryption),
          @"useXrayTun":@(self->_useXrayTun),
          @"setingVersion": [NSNumber numberWithInteger:kV2RayXSettingVersion],
          @"logLevel": self.logLevel,
          @"localPort": @(self.localPort),
          @"httpPort": @(self.httpPort),
          @"udpSupport": @(self.udpSupport),
          @"shareOverLan": @(self.shareOverLan),
          @"dnsString": self.dnsString,
          @"profiles":profilesToSave,
          @"cusProfiles": self.cusProfiles,
          @"subscriptions": subscriptionToSave,
          @"routingRuleSets": self.routingRuleSets,
          @"enableRestore": @(self.enableRestore)
          };
        for (NSString* key in [settings allKeys]) {
            [[NSUserDefaults standardUserDefaults] setObject:settings[key] forKey:key];
        }
        NSLog(@"Settings saved.");
    });
}

- (void)applicationWillTerminate:(NSNotification *)aNotification {
    [self unloadV2ray];
    [self stopTunRoutingSession];
    [self stopHelperDaemonIfRunning];
    //stop monitor pac
    if (dispatchPacSource) {
        dispatch_source_cancel(dispatchPacSource);
    }
    if (terminationSignalSource) {
        dispatch_source_cancel(terminationSignalSource);
    }
    if (interruptSignalSource) {
        dispatch_source_cancel(interruptSignalSource);
    }
    //unload v2ray
    //runCommandLine(@"/bin/launchctl", @[@"unload", plistPath]);
    [self unloadV2ray];
    NSLog(@"V2RayXS quiting, Xray core unloaded.");
    //remove log file
    [[NSFileManager defaultManager] removeItemAtPath:logDirPath error:nil];
    //save application status
    [self saveAppStatus];
    //turn off proxy
    if (proxyState && proxyMode != manualMode) {
        if (_enableRestore) {
            [helperClient restoreSystemProxyWithAction:@"restore system proxy during termination"];
        } else {
            [helperClient disableSystemProxyWithAction:@"disable system proxy during termination"];
        }
    }
}

- (IBAction)showHelp:(id)sender {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"https://xtls.github.io"]];
}

// v2rayx status part

// back up system proxy state when V2RayX starts to take control of
// macOS's proxy settings, which means:
// 1. proxy status is On and not changed, but proxy mode changes from manual to non-manual => happens when didChangeMode
// or 2. proxy status was off and now is turned on, and the proxy mode is non-manual => happens when didChangeStatus
// restore system proxy state when V2RayX stops taking control of macOS's proxy settings, which means:
// 1. proxy state is On and not changed, but proxy mode changes from non-manual mode to manual mode => happens when didChangeMode
// or 2. proxy state was on and now is turned off, and the proxy mode is non-manual => happens when didChangeStatus

-(void)backupSystemProxy {
    SCPreferencesRef prefRef = SCPreferencesCreate(nil, CFSTR("V2RayXS"), nil);
    NSDictionary* sets = (__bridge NSDictionary *)SCPreferencesGetValue(prefRef, kSCPrefNetworkServices);
    [sets writeToURL:[NSURL fileURLWithPath:[NSString stringWithFormat:@"%@/Library/Application Support/V2RayXS/system_proxy_backup.plist",NSHomeDirectory()]] atomically:NO];
}

-(void)restoreSystemProxy {
    dispatch_async(taskQueue, ^{
        [self->helperClient restoreSystemProxyWithAction:@"restore system proxy"];
    });
}

-(void)cancelSystemProxy {
    dispatch_async(taskQueue, ^{
        [self->helperClient disableSystemProxyWithAction:@"disable system proxy"];
    });
}

- (void)restoreStartupRuntimeState {
    [self reconcileTunSessionForCurrentRuntime];
    [self normalizeCurrentRuntimeSelections];
    RuntimeState previousState = [self runtimeStateWithEnabled:NO mode:proxyMode];
    RuntimeState nextState = [self currentRuntimeState];
    RuntimeTransitionPlan plan = [self transitionPlanFromState:previousState toState:nextState userInitiated:NO startupRestore:YES];

    if (plan.shouldBackupSystemProxy) {
        [self backupSystemProxy];
    }

    suppressAutomaticTunRefreshDuringCoreConfigChange = plan.shouldRefreshTunSession;
    [self coreConfigDidChange:self];
    suppressAutomaticTunRefreshDuringCoreConfigChange = NO;

    if (plan.shouldApplyNetworkMode) {
        [self updateSystemProxy];
    } else if (plan.shouldRefreshTunSession) {
        [self refreshTunRoutingSession];
    }

    [self updateMenus];
    [self updatePacMenuList];
    [self applyAutomationTargetIfNeeded];
}

- (RuntimeState)currentRuntimeState {
    return [self runtimeStateWithEnabled:proxyState mode:proxyMode];
}

- (RuntimeState)runtimeStateWithEnabled:(BOOL)enabled mode:(ProxyMode)mode {
    RuntimeState state;
    state.enabled = enabled;
    state.mode = mode;
    if (!enabled) {
        state.coreKind = RuntimeCoreKindStopped;
    } else if (mode == tunMode) {
        state.coreKind = RuntimeCoreKindTun;
    } else {
        state.coreKind = RuntimeCoreKindPlain;
    }
    return state;
}

- (RuntimeTransitionPlan)transitionPlanFromState:(RuntimeState)previousState toState:(RuntimeState)nextState userInitiated:(BOOL)isUserInitiated startupRestore:(BOOL)isStartupRestore {
    RuntimeTransitionPlan plan = {0};
    plan.previousModeIsTun = (previousState.mode == tunMode);
    plan.nextModeIsTun = (nextState.mode == tunMode);

    if (isUserInitiated && previousState.enabled && previousState.mode == manualMode && nextState.mode != manualMode) {
        plan.shouldBackupSystemProxy = YES;
    }
    if (isUserInitiated && previousState.enabled && previousState.mode != manualMode && nextState.mode == manualMode) {
        plan.shouldRestoreSystemProxy = _enableRestore;
        plan.shouldDisableSystemProxy = !_enableRestore;
    }
    if (!isUserInitiated && !isStartupRestore && previousState.mode != manualMode) {
        if (!previousState.enabled && nextState.enabled) {
            plan.shouldBackupSystemProxy = YES;
        } else if (previousState.enabled && !nextState.enabled) {
            plan.shouldRestoreSystemProxy = _enableRestore;
            plan.shouldDisableSystemProxy = !_enableRestore;
        }
    }

    plan.shouldStopCore = previousState.coreKind != RuntimeCoreKindStopped &&
        ((nextState.coreKind == RuntimeCoreKindStopped) || (previousState.coreKind != nextState.coreKind));
    plan.shouldStopTunSession = plan.previousModeIsTun && (!plan.nextModeIsTun || nextState.coreKind == RuntimeCoreKindStopped);
    plan.shouldStartCore = nextState.coreKind != RuntimeCoreKindStopped &&
        (previousState.coreKind == RuntimeCoreKindStopped || previousState.coreKind != nextState.coreKind);
    plan.shouldApplyNetworkMode = nextState.enabled && !plan.nextModeIsTun;
    plan.shouldRefreshTunSession = nextState.enabled && plan.nextModeIsTun && (isStartupRestore || !plan.previousModeIsTun || previousState.coreKind != nextState.coreKind);
    return plan;
}

- (void)normalizeCurrentRuntimeSelections {
    selectedServerIndex = MIN((NSInteger)profiles.count + (NSInteger)_subsOutbounds.count - 1, selectedServerIndex);
    if (profiles.count + _subsOutbounds.count > 0) {
        selectedServerIndex = MAX(selectedServerIndex, 0);
    }
    selectedCusServerIndex = MIN((NSInteger)cusProfiles.count - 1, selectedCusServerIndex);
    _selectedRoutingSet = MIN((NSInteger)_routingRuleSets.count - 1, _selectedRoutingSet);

    if ((!useMultipleServer && selectedServerIndex == -1 && selectedCusServerIndex == -1) || (useMultipleServer && profiles.count + _subsOutbounds.count < 1)) {
        proxyState = false;
    } else if (!useMultipleServer && selectedCusServerIndex == -1) {
        useCusProfile = false;
    } else if (!useMultipleServer && selectedServerIndex == -1) {
        useCusProfile = true;
    }
}

- (void)applyAutomationTargetIfNeeded {
    NSArray<NSString*>* arguments = [[NSProcessInfo processInfo] arguments];
    NSUInteger statusIndex = [arguments indexOfObject:@"--automation-status"];
    NSUInteger modeIndex = [arguments indexOfObject:@"--automation-mode"];
    BOOL hasTargetStatus = statusIndex != NSNotFound && statusIndex + 1 < arguments.count;
    BOOL hasTargetMode = modeIndex != NSNotFound && modeIndex + 1 < arguments.count;
    if (!hasTargetStatus && !hasTargetMode) {
        return;
    }

    BOOL targetEnabled = proxyState;
    if (hasTargetStatus) {
        NSString* statusValue = arguments[statusIndex + 1];
        targetEnabled = ![statusValue isEqualToString:@"off"];
    }

    ProxyMode targetMode = proxyMode;
    if (hasTargetMode) {
        NSMenuItem* targetModeItem = [self menuItemForAutomationMode:arguments[modeIndex + 1]];
        if (targetModeItem != nil) {
            targetMode = (ProxyMode)targetModeItem.tag;
        }
    }

    if (proxyState == targetEnabled && proxyMode == targetMode) {
        return;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self applyRuntimeTargetEnabled:targetEnabled mode:targetMode startupRestore:NO];
    });
}

- (void)applyRuntimeTargetEnabled:(BOOL)targetEnabled mode:(ProxyMode)targetMode startupRestore:(BOOL)isStartupRestore {
    [self reconcileTunSessionForCurrentRuntime];
    BOOL previousEnabled = proxyState;
    ProxyMode previousMode = proxyMode;
    if (previousEnabled == targetEnabled && previousMode == targetMode) {
        [self updateMenus];
        [self updatePacMenuList];
        return;
    }

    if (previousEnabled && !targetEnabled) {
        proxyState = NO;
        [self applyStatusTransitionFromEnabled:previousEnabled toEnabled:NO startupRestore:isStartupRestore];
        proxyMode = targetMode;
        [self updateMenus];
        [self updatePacMenuList];
        return;
    }

    if (!previousEnabled && targetEnabled) {
        proxyMode = targetMode;
        proxyState = YES;
        [self applyStatusTransitionFromEnabled:NO toEnabled:YES startupRestore:isStartupRestore];
        [self updateMenus];
        [self updatePacMenuList];
        return;
    }

    if (previousMode != targetMode) {
        [self applyModeTransitionFrom:previousMode to:targetMode userInitiated:NO sender:self];
    }
    [self updateMenus];
    [self updatePacMenuList];
}

- (NSMenuItem*)menuItemForAutomationMode:(NSString*)modeName {
    if ([modeName isEqualToString:@"pac"]) {
        return _pacModeItem;
    }
    if ([modeName isEqualToString:@"global"]) {
        return _globalModeItem;
    }
    if ([modeName isEqualToString:@"manual"]) {
        return _manualModeItem;
    }
    if ([modeName isEqualToString:@"tun"]) {
        return _tunModeItem;
    }
    return nil;
}

- (void)applyStatusChangeFromSender:(id)sender startupRestore:(BOOL)isStartupRestore {
    [self reconcileTunSessionForCurrentRuntime];
    BOOL previousStatus = proxyState;
    // sender can be
    // 1. self, when app is launched
    // 2. menuitem, when a user click on a server or a routing or updateSeverMenuItem
    // 3. configwindow controller
    if (sender == _enableV2rayItem) {
        proxyState = !proxyState;
    }
    // make sure current status parameter is valid
    [self normalizeCurrentRuntimeSelections];
    [self applyStatusTransitionFromEnabled:isStartupRestore ? NO : previousStatus toEnabled:proxyState startupRestore:isStartupRestore];
    [self updateMenus];
    [self updatePacMenuList];
}

- (void)applyStatusTransitionFromEnabled:(BOOL)previousEnabled toEnabled:(BOOL)nextEnabled startupRestore:(BOOL)isStartupRestore {
    RuntimeState previousState = [self runtimeStateWithEnabled:previousEnabled mode:proxyMode];
    RuntimeState nextState = [self runtimeStateWithEnabled:nextEnabled mode:proxyMode];
    RuntimeTransitionPlan plan = [self transitionPlanFromState:previousState toState:nextState userInitiated:NO startupRestore:isStartupRestore];

    if (plan.shouldBackupSystemProxy) {
        [self backupSystemProxy];
    } else if (plan.shouldRestoreSystemProxy) {
        [self restoreSystemProxy];
    } else if (plan.shouldDisableSystemProxy) {
        [self cancelSystemProxy];
    }

    suppressAutomaticTunRefreshDuringCoreConfigChange = plan.shouldRefreshTunSession;
    [self coreConfigDidChange:self];
    suppressAutomaticTunRefreshDuringCoreConfigChange = NO;

    if (plan.shouldStopCore) {
        [self unloadV2ray];
    }
    if (plan.shouldStopTunSession) {
        [self stopTunRoutingSession];
    }
    if (plan.shouldApplyNetworkMode) {
        [self updateSystemProxy];
    } else if (plan.shouldRefreshTunSession) {
        [self refreshTunRoutingSession];
    }
}

- (void)applyNonTunModeTransitionFrom:(ProxyMode)previousMode to:(ProxyMode)nextMode userInitiated:(BOOL)isUserInitiated sender:(id)sender applyNetworkMode:(BOOL)applyNetworkMode {
    if (isUserInitiated && proxyState == true && previousMode == manualMode && nextMode != manualMode) {
        [self backupSystemProxy];
    }
    if (isUserInitiated && proxyState == true && previousMode != manualMode && nextMode == manualMode) {
        _enableRestore ? [self restoreSystemProxy] : [self cancelSystemProxy];
    }

    proxyMode = nextMode;
    [self updateMenus];
    if (sender == _pacModeItem) {
        [self updatePacMenuList];
    }

    if (proxyState == true && applyNetworkMode) {
        [self updateSystemProxy];
    }
}

- (void)applyModeTransitionFrom:(ProxyMode)previousMode to:(ProxyMode)nextMode userInitiated:(BOOL)isUserInitiated sender:(id)sender {
    RuntimeState previousState = [self runtimeStateWithEnabled:proxyState mode:previousMode];
    RuntimeState nextState = [self runtimeStateWithEnabled:proxyState mode:nextMode];
    RuntimeTransitionPlan plan = [self transitionPlanFromState:previousState toState:nextState userInitiated:isUserInitiated startupRestore:NO];

    if (!plan.previousModeIsTun && !plan.nextModeIsTun) {
        [self applyNonTunModeTransitionFrom:previousMode to:nextMode userInitiated:isUserInitiated sender:sender applyNetworkMode:YES];
        return;
    }

    if (proxyState == true && !plan.previousModeIsTun && plan.nextModeIsTun) {
        appDebugLog(@"modeTransition nonTun->tun begin previous=%ld next=%ld", (long)previousMode, (long)nextMode);
        if (isUserInitiated && previousMode == manualMode) {
            [self backupSystemProxy];
        }
        proxyMode = nextMode;
        [self setCurrentTunLeaseIdentifier:nil];
        [self updateMenus];
        if (sender == _pacModeItem) {
            [self updatePacMenuList];
        }
        suppressAutomaticTunRefreshDuringCoreConfigChange = YES;
        [self coreConfigDidChange:self];
        suppressAutomaticTunRefreshDuringCoreConfigChange = NO;
        BOOL shouldUseXrayTun = self.useXrayTun && [self currentCoreSupportsXrayTun];
        NSString* tunName = [self currentTunInterfaceName];
        BOOL sawTunAfterCoreConfig = [self waitForTunInterfaceNamed:tunName timeout:1.0];
        appDebugLog(@"modeTransition nonTun->tun after coreConfig tunName=%@ exists=%d corePID=%d useXrayTun=%d", tunName ?: @"", sawTunAfterCoreConfig, coreProcessPID, shouldUseXrayTun);
        if (!shouldUseXrayTun) {
            [self refreshTunRoutingSession];
        } else {
            appDebugLog(@"modeTransition nonTun->tun defer refresh until post-spawn activation");
        }
        return;
    }

    if (proxyState == true && plan.previousModeIsTun && !plan.nextModeIsTun) {
        [self unloadV2ray];
        [self stopTunRoutingSession];
        [self applyNonTunModeTransitionFrom:previousMode to:nextMode userInitiated:isUserInitiated sender:sender applyNetworkMode:NO];
        [self coreConfigDidChange:self];
        [self updateSystemProxy];
        return;
    }

    if (plan.previousModeIsTun && !plan.nextModeIsTun) {
        [self unloadV2ray];
        [self stopTunRoutingSession];
    }

    proxyMode = nextMode;
    [self updateMenus];
    if (sender == _pacModeItem) {
        [self updatePacMenuList];
    }
    if (proxyState == true) {
        if (proxyMode == tunMode) {
            BOOL shouldUseXrayTun = self.useXrayTun && [self currentCoreSupportsXrayTun];
            if (!shouldUseXrayTun) {
                [self refreshTunRoutingSession];
            } else {
                appDebugLog(@"applyModeTransition fallback skip refresh for Xray tun");
            }
        } else {
            [self updateSystemProxy];
        }
    } else if (previousMode == tunMode) {
        [self unloadV2ray];
        [self stopTunRoutingSession];
    }
}

- (void)applyModeChangeFromSender:(id)sender userInitiated:(BOOL)isUserInitiated {
    [self reconcileTunSessionForCurrentRuntime];
    ProxyMode previousMode = proxyMode;
    ProxyMode nextMode = [sender tag];
    [self applyModeTransitionFrom:previousMode to:nextMode userInitiated:isUserInitiated sender:sender];
}

- (IBAction)didChangeStatus:(id)sender {
    [self applyStatusChangeFromSender:sender startupRestore:NO];
}

- (IBAction)didChangeMode:(id)sender {
    [self applyModeChangeFromSender:sender userInitiated:YES];
}

- (void)updateMenus {
    if (proxyState) {
        [_v2rayStatusItem setTitle:@"xray-core: loaded"];
        [_enableV2rayItem setTitle:@"Unload core"];
        NSImage *icon = [NSImage imageNamed:@"statusBarIcon"];
        [icon setTemplate:YES];
        [_statusBarItem setImage:icon];
    } else {
        [_v2rayStatusItem setTitle:@"xray-core: unloaded"];
        [_enableV2rayItem setTitle:@"Load core"];
        [_statusBarItem setImage:[NSImage imageNamed:@"statusBarIcon_disabled"]];
    }
    [_pacModeItem setState:proxyMode == pacMode];
    [_manualModeItem setState:proxyMode == manualMode];
    [_globalModeItem setState:proxyMode == globalMode];
    [_tunModeItem setState:proxyMode == tunMode];
}

- (void)updatePacMenuList {
    NSLog(@"updatePacMenuList");
    [_pacListMenu removeAllItems];
    NSString *pacDir = [NSString stringWithFormat:@"%@/Library/Application Support/V2RayXS/pac", NSHomeDirectory()];
    
    NSFileManager *manager = [NSFileManager defaultManager];
    NSArray *allPath =[manager subpathsAtPath:pacDir];
    int i = 0;
    for (NSString *subPath in allPath) {
        NSString *extString = [subPath pathExtension];
        if (![extString  isEqual: @"js"]){
            continue;
        }
        NSString *itemTitle = subPath;
        NSMenuItem *newItem = [[NSMenuItem alloc] initWithTitle:itemTitle action:@selector(switchPac:) keyEquivalent:@""];
        newItem.state = [itemTitle isEqualToString:selectedPacFileName];
        [newItem setTag:i];
        [_pacListMenu addItem:newItem];
        i++;
    }
    [_pacListMenu addItem:[NSMenuItem separatorItem]];
    [_pacListMenu addItem:_editPacMenuItem];
    [_pacListMenu addItem:_resetPacMenuItem];
}

- (IBAction)editPac:(id)sender {
    [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:[NSString stringWithFormat:@"%@/Library/Application Support/V2RayXS/pac/%@",NSHomeDirectory(), selectedPacFileName]]]];
}

- (IBAction)resetPac:(id)sender {
    NSAlert *resetAlert = [[NSAlert alloc] init];
    [resetAlert setMessageText:@"The pac file will be reset to the original one coming with V2RayX. Are you sure to proceed?"];
    [resetAlert addButtonWithTitle:@"Yes"];
    [resetAlert addButtonWithTitle:@"Cancel"];
    NSModalResponse response = [resetAlert runModal];
    if(response == NSAlertFirstButtonReturn) {
        NSString* simplePac = [[NSBundle mainBundle] pathForResource:@"simple" ofType:@"pac"];
        NSString* pacPath = [NSString stringWithFormat:@"%@/Library/Application Support/V2RayXS/pac/%@",NSHomeDirectory(), selectedPacFileName];
        if ([[NSFileManager defaultManager] isWritableFileAtPath:pacPath]) {
            [[NSData dataWithContentsOfFile:simplePac] writeToFile:pacPath atomically:YES];
        } else {
            NSAlert* writePacAlert = [[NSAlert alloc] init];
            [writePacAlert setMessageText:[NSString stringWithFormat:@"%@ is not writable!", pacPath]];
            [writePacAlert runModal];
        }
    }
}

- (void)switchPac:(id)sender {
    [self setSelectedPacFileName:[sender title]];
    [self didChangeMode:_pacModeItem];
}

-(void)updateSystemProxy {
    BOOL shouldUseXrayTun = [self isUsingXrayTunMode];
    BOOL shouldRestartTunRoutingSession = [self shouldMaintainTunRoutingSession];
    NSString* currentLeaseId = [self currentTunLeaseIdentifier];
    NSString* currentSessionState = [self currentTunSessionState];
    BOOL hasHelperSession = [self shouldTreatTunSessionAsActive];
    if (shouldRestartTunRoutingSession) {
        if (shouldUseXrayTun) {
            [self stopEmbeddedTunSessionIfNeeded];
        } else {
            [self stopTunRoutingSession];
        }
    }
    if (!proxyState) {
        dispatch_async(taskQueue, ^{
            [self->helperClient disableSystemProxyWithAction:@"disable system proxy"];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self updateMenus];
            });
        });
        NSLog(@"system proxy state:%@,%ld",proxyState?@"on":@"off", (long)proxyMode);
        return;
    }
    
    if (shouldUseXrayTun) {
        dispatch_async(taskQueue, ^{
            [self syncTunWhitelistRoutes];
            appDebugLog(@"updateSystemProxy defer Xray tun activation to post-spawn path session=%@ lease=%@ helperActive=%d", currentSessionState, currentLeaseId ?: @"", hasHelperSession);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self updateMenus];
            });
        });
    } else {
        [self applyNonXrayNetworkMode];
    }
    NSLog(@"system proxy state:%@,%ld",proxyState?@"on":@"off", (long)proxyMode);
}


// core part

- (IBAction)updateSubscriptions:(id)sender {
    // sender can be self -> called when app is started
    // or menuItem -> called by user
    _subsOutbounds = [[NSMutableArray alloc] init];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        for (NSString* link in self.subscriptions) {
            NSDictionary* r = [ConfigImporter importFromHTTPSubscription:link];
            if (r) {
                for (ServerProfile* p in r[@"vmess"]) {
                    [self.subsOutbounds addObject:[p outboundProfile]];
                }
                for (ServerProfile* p in r[@"vless"]) {
                    [self.subsOutbounds addObject:[p outboundProfile]];
                }
                [self.subsOutbounds addObjectsFromArray:r[@"other"]];
            }
        }
        // not safe, need to make sure every tag is unique
        dispatch_async(dispatch_get_main_queue(), ^{
            if (sender == self) {
                [self restoreStartupRuntimeState];
            } else {
                [self didChangeStatus:sender];
            }
        });
    });
}

- (void)updateRuleSetMenuList {
    [_ruleSetMenuList removeAllItems];
    NSInteger i = 0;
    for (NSDictionary* rule in _routingRuleSets) {
        NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:rule[@"name"] action:@selector(switchRoutingSet:) keyEquivalent:@""];
        item.tag = i;
        item.state = i == _selectedRoutingSet;
        [_ruleSetMenuList addItem:item];
        i += 1;
    }
}

- (void)updateServerMenuList {
    [_serverListMenu removeAllItems];
    if ([profiles count] == 0 && [cusProfiles count] == 0 && [_subsOutbounds count] == 0) {
        [_serverListMenu addItem:[[NSMenuItem alloc] initWithTitle:@"no available servers, please add server profiles through config window." action:nil keyEquivalent:@""]];
        if (_subscriptions.count > 0) {
            [_serverListMenu addItem:[NSMenuItem separatorItem]];
            [_serverListMenu addItem:_updateServerItem];
        }
    } else {
        int i = 0;
        for (NSDictionary *p in profiles) {
            NSString *itemTitle = nilCoalescing(p[@"tag"], @"");
            NSMenuItem *newItem = [[NSMenuItem alloc] initWithTitle:itemTitle action:@selector(switchServer:) keyEquivalent:@""];
            [newItem setTag:i];
            if (useMultipleServer){
                newItem.state = 0;
            } else {
                newItem.state = (!useCusProfile && i == selectedServerIndex);
            }
            [_serverListMenu addItem:newItem];
            i += 1;
        }
        for (NSDictionary* p in _subsOutbounds) {
            NSString *itemTitle = nilCoalescing(p[@"tag"], @"from subscription");
            NSMenuItem *newItem = [[NSMenuItem alloc] initWithTitle:itemTitle action:@selector(switchServer:) keyEquivalent:@""];
            [newItem setTag:i];
            if (useMultipleServer){
                newItem.state = 0;
            } else {
                newItem.state = (!useCusProfile && i == selectedServerIndex);
            }
            [_serverListMenu addItem:newItem];
            i += 1;
        }
        if([profiles count] + [_subsOutbounds count]> 0) {
            NSMenuItem *newItem = [[NSMenuItem alloc] initWithTitle:@"Use All" action:@selector(switchServer:) keyEquivalent:@""];
            [newItem setTag:kUseAllServer];
            newItem.state = useMultipleServer & !useCusProfile;
            [_serverListMenu addItem:newItem];
        }
        if (_subscriptions.count > 0) {
            [_serverListMenu addItem:[NSMenuItem separatorItem]];
            [_serverListMenu addItem:_updateServerItem];
        }
        if (cusProfiles.count > 0) {
            [_serverListMenu addItem:[NSMenuItem separatorItem]];
        }
        for (NSString* cusProfilePath in cusProfiles) {
            NSString *itemTitle = [[cusProfilePath componentsSeparatedByString:@"/"] lastObject];
            NSMenuItem *newItem = [[NSMenuItem alloc] initWithTitle:itemTitle action:@selector(switchServer:) keyEquivalent:@""];
            [newItem setTag:i];
            if (useMultipleServer){
                newItem.state = 0;
            } else {
                newItem.state = (useCusProfile && i - [profiles count] - [_subsOutbounds count] == selectedCusServerIndex)? 1 : 0;
            }
            [_serverListMenu addItem:newItem];
            i += 1;
        }
    }
}


- (IBAction)coreConfigDidChange:(id)sender {
    [self reconcileTunSessionForCurrentRuntime];
    BOOL shouldRefreshTunSession = [self shouldMaintainTunRoutingSession];
    if (proxyState == true) {
        if (!useMultipleServer && useCusProfile) {
            v2rayJSONconfig = [NSData dataWithContentsOfFile:cusProfiles[selectedCusServerIndex]];
        } else {
            NSDictionary *fullConfig = [self generateConfigFile];
            v2rayJSONconfig = [NSJSONSerialization dataWithJSONObject:fullConfig options:NSJSONWritingPrettyPrinted error:nil];
        }
        //[self generateLaunchdPlist:plistPath];
        [self toggleCore];
        if (shouldRefreshTunSession && !suppressAutomaticTunRefreshDuringCoreConfigChange) {
            [self refreshTunRoutingSession];
        }
    }
    [self updateServerMenuList];
    [self updateRuleSetMenuList];
}

-(void)toggleCore {
    [self unloadV2ray];
    dispatch_semaphore_signal(coreLoopSemaphore);
//    dispatch_async(taskQueue, ^{
//        runCommandLine(@"/bin/launchctl",  @[@"unload", self->plistPath]);
//        runCommandLine(@"/bin/cp", @[@"/dev/null", [NSString stringWithFormat:@"%@/access.log", self->logDirPath]]);
//        runCommandLine(@"/bin/cp", @[@"/dev/null", [NSString stringWithFormat:@"%@/error.log", self->logDirPath]]);
//        runCommandLine(@"/bin/launchctl",  @[@"load", self->plistPath]);
//    });
}

- (IBAction)showConfigWindow:(id)sender {
    if (configWindowController) {
        [configWindowController close];
    }
    configWindowController =[[ConfigWindowController alloc] initWithWindowNibName:@"ConfigWindow"];
    configWindowController.appDelegate = self;
    [configWindowController showWindow:self];
    [NSApp activateIgnoringOtherApps:YES];
    [configWindowController.window makeKeyAndOrderFront:nil];
}

- (IBAction)backupConfigs:(id)sender {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setDateFormat:@"dd-MM-yyyy HH:mm"];
    NSDate *currentDate = [NSDate date];
    NSString *dateString = [formatter stringFromDate:currentDate];
    
    NSMutableDictionary *backup = [[NSMutableDictionary alloc] init];
    backup[@"outbounds"] = self.profiles;
    backup[@"routings"] = self.routingRuleSets;
    NSData* backupData = [NSJSONSerialization dataWithJSONObject:backup options:NSJSONWritingPrettyPrinted error:nil];
    NSString* backupPath = [NSString stringWithFormat:@"%@/v2rayxs_backup_%@.json", NSHomeDirectory(), dateString];
    
    [backupData writeToFile:backupPath atomically:YES];
    [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:backupPath]]];
}

-(IBAction)switchRoutingSet:(id)sender {
    _selectedRoutingSet = [sender tag];
    [self coreConfigDidChange:self];
}

- (void)switchServer:(id)sender {
    NSInteger outboundCount = [profiles count] + [_subsOutbounds count];
    if ([sender tag] >= 0 && [sender tag] < outboundCount) {
        [self setUseMultipleServer:NO];
        [self setUseCusProfile:NO];
        [self setSelectedServerIndex:[sender tag]];
    } else if ([sender tag] >= outboundCount && [sender tag] < outboundCount + [cusProfiles count]) {
        [self setUseMultipleServer:NO];
        [self setUseCusProfile:YES];
        [self setSelectedCusServerIndex:[sender tag] - outboundCount];
    } else if ([sender tag] == kUseAllServer) {
        [self setUseMultipleServer:YES];
        [self setUseCusProfile:NO];
    }
    NSLog(@"use cus pro:%hhd, select %ld, select cus %ld", useCusProfile, (long)selectedServerIndex, selectedCusServerIndex);
    [self coreConfigDidChange:self];
}

-(void)unloadV2ray {
    if (coreProcessPID > 0) {
        terminateSpawnedProcess(coreProcessPID, 5.0, &coreProcessStatus);
        coreProcessPID = 0;
    }
    if (coreTunFD >= 0) {
        close(coreTunFD);
        coreTunFD = -1;
    }
    if (coreConfigPath.length > 0) {
        [[NSFileManager defaultManager] removeItemAtPath:coreConfigPath error:nil];
        coreConfigPath = nil;
    }
//    dispatch_async(taskQueue, ^{
//        runCommandLine(@"/bin/launchctl", @[@"unload", self->plistPath]);
//        NSLog(@"V2Ray core unloaded.");
//    });
}

- (NSDictionary*)generateConfigFile {
    NSMutableDictionary* fullConfig = [NSMutableDictionary dictionaryWithContentsOfFile:[[NSBundle mainBundle] pathForResource:@"config-sample_new" ofType:@"plist"]];
    fullConfig[@"log"] = @{
                           @"access": [NSString stringWithFormat:@"%@/access.log", logDirPath],
                           @"error": [NSString stringWithFormat:@"%@/error.log", logDirPath],
                           @"loglevel": logLevel
                           };
    fullConfig[@"inbounds"][0][@"port"] = @(localPort);
    fullConfig[@"inbounds"][0][@"listen"] = shareOverLan ? @"0.0.0.0" : @"127.0.0.1";
    fullConfig[@"inbounds"][0][@"settings"][@"udp"] = [NSNumber numberWithBool:udpSupport];
    fullConfig[@"inbounds"][1][@"port"] = @(httpPort);
    fullConfig[@"inbounds"][1][@"listen"] = shareOverLan ? @"0.0.0.0" : @"127.0.0.1";
    BOOL shouldAppendTunInbound = proxyMode == tunMode && self.useXrayTun && [self currentCoreSupportsXrayTun];
    if (shouldAppendTunInbound) {
        NSMutableArray* inbounds = [fullConfig[@"inbounds"] mutableCopy];
        if (inbounds == nil) {
            inbounds = [[NSMutableArray alloc] init];
        }
        NSString* tunName = [self currentTunInterfaceName];
        if (![tunName isKindOfClass:[NSString class]] || tunName.length == 0) {
            tunName = [self availableUtunName];
        }
        [inbounds addObject:[@{
            @"port": @0,
            @"protocol": @"tun",
            @"settings": @{
                @"name": tunName,
                @"MTU": @1500
            }
        } mutableCopy]];
        fullConfig[@"inbounds"] = inbounds;
    }
    
    NSArray* dnsArray = [dnsString componentsSeparatedByString:@","];
    if ([dnsArray count] > 0) {
        fullConfig[@"dns"][@"servers"] = dnsArray;
    } else {
        fullConfig[@"dns"][@"servers"] = @[@"localhost"];
    }
    
    // deal with outbound
    NSMutableDictionary* configOutboundDict = [[NSMutableDictionary alloc] init];
    NSMutableDictionary* allUniqueTagOutboundDict = [[NSMutableDictionary alloc] init]; // make sure tag is unique
    NSMutableArray* allOutbounds = [profiles mutableCopy];
    [allOutbounds addObjectsFromArray:_subsOutbounds];
    for (NSDictionary* outbound in profiles) {
        allUniqueTagOutboundDict[outbound[@"tag"]] = [outbound mutableDeepCopy];
    }
    for (NSDictionary* outbound in _subsOutbounds) {
        allUniqueTagOutboundDict[outbound[@"tag"]] = [outbound mutableDeepCopy];
    }
    NSArray* allProxyTags = allUniqueTagOutboundDict.allKeys;
    allUniqueTagOutboundDict[@"direct"] = OUTBOUND_DIRECT;
    allUniqueTagOutboundDict[@"decline"] = OUTBOUND_DECLINE;
    
    fullConfig[@"routing"] = [_routingRuleSets[_selectedRoutingSet] mutableDeepCopy];
    if (!useMultipleServer) {
        // replace tag main with current selected outbound tag
        NSString* currentMainTag = allOutbounds[selectedServerIndex][@"tag"];
        for (NSMutableDictionary* aRule in fullConfig[@"routing"][@"rules"]) {
            if ([@"main" isEqualToString:aRule[@"outboundTag"]]) {
                aRule[@"outboundTag"] = currentMainTag;
            }
        }
    } else {
        // replace outbound tag main with balancetag
        for (NSMutableDictionary* aRule in fullConfig[@"routing"][@"rules"]) {
            if ([@"main" isEqualToString:aRule[@"outboundTag"]]) {
                [aRule removeObjectForKey:@"outboundTag"];
                [aRule setObject:@"balance" forKey:@"balancerTag"];
            }
        }
        
    }

    // NSLog(@"%@", allOutbounds);
    BOOL usebalance = false;
    for (NSDictionary* rule in fullConfig[@"routing"][@"rules"]) {
        if (rule[@"balancerTag"] && !rule[@"outboundTag"]) {
            // if any rule uses balancer, stop the loop and add a balancer to the routing part
            usebalance = true;
            break;
        } else {
            // pick up all mentioned outbounds in the routing rule set
            if (allUniqueTagOutboundDict[rule[@"outboundTag"]]) {
                configOutboundDict[rule[@"outboundTag"]] = allUniqueTagOutboundDict[rule[@"outboundTag"]];
            }
        }
    }
    if (usebalance) {
        // if balancer is used, add all outbounds into config file, and add all tags to the balancer selector
        fullConfig[@"routing"][@"balancers"] = @[@{
                                                     @"tag":@"balance",
                                                     @"selector": allProxyTags
                                                     }];
        NSMutableArray* normalizedOutbounds = [[NSMutableArray alloc] init];
        for (NSDictionary* outbound in allUniqueTagOutboundDict.allValues) {
            NSMutableDictionary* normalizedOutbound = [outbound mutableDeepCopy];
            normalizedOutbound[@"streamSettings"] = normalizedStreamSettingsForXray(outbound[@"streamSettings"]);
            [normalizedOutbounds addObject:normalizedOutbound];
        }
        fullConfig[@"outbounds"] = normalizedOutbounds;
    } else {
        // otherwise, we convert all collected outbounds into an array
        NSMutableArray* normalizedOutbounds = [[NSMutableArray alloc] init];
        for (NSDictionary* outbound in configOutboundDict.allValues) {
            NSMutableDictionary* normalizedOutbound = [outbound mutableDeepCopy];
            normalizedOutbound[@"streamSettings"] = normalizedStreamSettingsForXray(outbound[@"streamSettings"]);
            [normalizedOutbounds addObject:normalizedOutbound];
        }
        fullConfig[@"outbounds"] = normalizedOutbounds;
    }
    return fullConfig;
}

//-(void)generateLaunchdPlist:(NSString*)path {
//    NSString* v2rayPath = [self getV2rayPath];
//    NSLog(@"use core: %@", v2rayPath);
//    NSString *configPath = [NSString stringWithFormat:@"http://127.0.0.1:%d/config.json", webServerPort];
//    NSDictionary *runPlistDic = [[NSDictionary alloc] initWithObjects:@[@"v2rayproject.v2rayx.v2ray-core", @[v2rayPath, @"-config", configPath], [NSNumber numberWithBool:YES]] forKeys:@[@"Label", @"ProgramArguments", @"RunAtLoad"]];
//    [runPlistDic writeToFile:path atomically:NO];
//}

-(NSString*)getV2rayPath {
    NSString* defaultV2ray = [NSString stringWithFormat:@"%@/xray", [[NSBundle mainBundle] resourcePath]];
    NSFileManager* fileManager = [NSFileManager defaultManager];
    NSString* cusV2ray = [NSString stringWithFormat:@"%@/Library/Application Support/V2RayXS/xray-core/xray",NSHomeDirectory()];
    for (NSString* binary in @[@"xray"]) {
        NSString* fullpath = [NSString stringWithFormat:@"%@/Library/Application Support/V2RayXS/xray-core/%@",NSHomeDirectory(), binary];
        BOOL isDir = YES;
        if (![fileManager fileExistsAtPath:fullpath isDirectory:&isDir] || isDir || ![fileManager setAttributes:@{NSFilePosixPermissions: [NSNumber numberWithShort:0777]} ofItemAtPath:fullpath error:nil]) {
            return defaultV2ray;
        }
    }
    for (NSString* data in @[@"geoip.dat", @"geosite.dat"]) {
        NSString* fullpath = [NSString stringWithFormat:@"%@/Library/Application Support/V2RayXS/xray-core/%@",NSHomeDirectory(), data];
        BOOL isDir = YES;
        if (![fileManager fileExistsAtPath:fullpath isDirectory:&isDir] || isDir ) {
            return defaultV2ray;
        }
    }
    return cusV2ray;
    
}

- (BOOL)isCurrentCoreXray {
    NSString* firstLine = [self currentCoreVersionString];
    if (firstLine.length == 0) {
        return NO;
    }
    return [firstLine rangeOfString:@"xray" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

- (NSString*)currentCoreVersionString {
    NSString* v2rayPath = [self getV2rayPath];
    if (v2rayPath.length == 0) {
        return @"";
    }
    NSTask *task = [[NSTask alloc] init];
    if (@available(macOS 10.13, *)) {
        [task setExecutableURL:[NSURL fileURLWithPath:v2rayPath]];
    } else {
        [task setLaunchPath:v2rayPath];
    }
    [task setArguments:@[@"-version"]];
    NSPipe *stdoutpipe = [NSPipe pipe];
    [task setStandardOutput:stdoutpipe];
    [task setStandardInput:nullInputHandle()];
    @try {
        [task launch];
        [task waitUntilExit];
    } @catch (NSException *exception) {
        return @"";
    }
    NSData *data = [[stdoutpipe fileHandleForReading] readDataToEndOfFile];
    NSString *string = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (string.length == 0) {
        return @"";
    }
    return [string componentsSeparatedByString:@"\n"].firstObject ?: @"";
}

- (BOOL)currentCoreSupportsXrayTun {
    if (![self isCurrentCoreXray]) {
        return NO;
    }

    NSString* versionLine = [self currentCoreVersionString];
    if (versionLine.length == 0) {
        return NO;
    }
    NSRegularExpression* versionRegex = [NSRegularExpression regularExpressionWithPattern:@"([0-9]+(?:\\.[0-9]+)+)" options:0 error:nil];
    NSTextCheckingResult* match = [versionRegex firstMatchInString:versionLine options:0 range:NSMakeRange(0, versionLine.length)];
    if (match == nil || match.numberOfRanges < 2) {
        return NO;
    }

    NSString* detectedVersion = [versionLine substringWithRange:[match rangeAtIndex:1]];
    return [detectedVersion compare:kMinimumSupportedXrayTunVersion options:NSNumericSearch] != NSOrderedAscending;
}

- (IBAction)authorizeV2sys:(id)sender {
    [self installHelper:true];
}

- (IBAction)viewLog:(id)sender {
    if (!useCusProfile) {
        [[NSWorkspace sharedWorkspace] openFile:logDirPath];
    } else {
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:[NSString stringWithFormat:@"Check %@.", cusProfiles[selectedCusServerIndex]]];
        [alert runModal];
    }
}

- (IBAction)copyExportCmd:(id)sender {
    if (!useCusProfile) {
        [[NSPasteboard generalPasteboard] clearContents];
        NSString* command = [NSString stringWithFormat:@"export http_proxy=\"http://127.0.0.1:%ld\"; export HTTP_PROXY=\"http://127.0.0.1:%ld\"; export https_proxy=\"http://127.0.0.1:%ld\"; export HTTPS_PROXY=\"http://127.0.0.1:%ld\"", httpPort, httpPort, httpPort, httpPort];
        [[NSPasteboard generalPasteboard] setString:command forType:NSStringPboardType];
    } else {
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:[NSString stringWithFormat:@"Check %@.", cusProfiles[selectedCusServerIndex]]];
        [alert runModal];
    }
}

- (IBAction)viewConfigJson:(NSMenuItem *)sender {
    if(_webServerUuidString == nil) {
        NSUUID *uuid = [NSUUID UUID];
        _webServerUuidString = [uuid UUIDString];
    }
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%d/config.json?u=%@", webServerPort, _webServerUuidString]]];
}


NSTask *helperApplicationTask;

void closeHelperApplicationTask(void) {
    HelperClient* client = activeHelperClient();
    if(helperApplicationTask != NULL && [helperApplicationTask isRunning]) {
        NSDictionary* stopResponse = [client stopTunWithAction:@"stop helper tun session"];
        if (stopResponse == nil) {
            [helperApplicationTask interrupt];
            sleep(1);
            [helperApplicationTask terminate];
        } else {
            helperTunSessionActive = NO;
            helperTunSessionStatus = nil;
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:kStoredTunLeaseIdKey];
        }
        helperApplicationTask = NULL;
        return;
    }
    if (appDelegate != nil && ![appDelegate shouldTreatTunSessionAsActive]) {
        return;
    }
    NSString* leaseId = [[NSUserDefaults standardUserDefaults] objectForKey:kStoredTunLeaseIdKey];
    NSDictionary* deactivateResponse = [client deactivateTunWithLeaseId:leaseId action:@"deactivate helper tun session"];
    if (deactivateResponse != nil) {
        helperTunSessionActive = NO;
        helperTunSessionStatus = nil;
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:kStoredTunLeaseIdKey];
        return;
    }
    NSLog(@"Failed to deactivate helper tun session.");
}

NSDictionary* runCommandLineResult(NSString* launchPath, NSArray* arguments) {
    NSTask *task = [[NSTask alloc] init];
    if ([launchPath isEqualToString:kV2RayXHelper]) {
        arguments = helperArgumentsWithOptionalDebug(arguments);
    }
    
    // take notes helperApplicationTask
    BOOL startsTunSession = helperArgumentsManageTunSession(arguments) && arguments.count > 1 && [arguments[1] isEqual:@"start"];
    BOOL activatesExternalTunSession = helperArgumentsManageTunSession(arguments) && arguments.count > 1 && [arguments[1] isEqual:@"activate"];
    if(helperApplicationTask == NULL && startsTunSession) {
        helperApplicationTask = task;
    }
    [task setLaunchPath:launchPath];
    [task setArguments:arguments];
    NSPipe *stdoutpipe = [NSPipe pipe];
    [task setStandardOutput:stdoutpipe];
    NSPipe *stderrpipe = [NSPipe pipe];
    [task setStandardError:stderrpipe];
    [task setStandardInput:nullInputHandle()];
    NSFileHandle *file;
    NSString *stdoutString = @"";
    NSString *stderrString = @"";
    file = [stdoutpipe fileHandleForReading];
    [task launch];
    NSData *data;
    data = [file readDataToEndOfFile];
    NSString *string;
    string = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    stdoutString = string ?: @"";
    if (string.length > 0) {
        NSLog(@"%@", string);
    }
    file = [stderrpipe fileHandleForReading];
    data = [file readDataToEndOfFile];
    string = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    stderrString = string ?: @"";
    if (string.length > 0) {
        NSLog(@"%@", string);
    }
    [task waitUntilExit];
    if (startsTunSession || activatesExternalTunSession) {
        BOOL taskSucceeded = (task.terminationStatus == 0 || task.terminationStatus == SIGTERM || task.terminationStatus == SIGINT);
        if (!taskSucceeded) {
            helperTunSessionActive = NO;
            helperTunSessionStatus = nil;
        }
    }
    return @{
        @"exitCode": @(task.terminationStatus),
        @"stdout": stdoutString,
        @"stderr": stderrString,
    };
}

NSDictionary* runCommandLineResultWithSetup(NSString* launchPath, NSArray* arguments, void (^setupTask)(NSTask* task)) {
    NSTask *task = [[NSTask alloc] init];
    if ([launchPath isEqualToString:kV2RayXHelper]) {
        arguments = helperArgumentsWithOptionalDebug(arguments);
    }
    [task setLaunchPath:launchPath];
    [task setArguments:arguments];
    NSPipe *stdoutpipe = [NSPipe pipe];
    [task setStandardOutput:stdoutpipe];
    NSPipe *stderrpipe = [NSPipe pipe];
    [task setStandardError:stderrpipe];
    [task setStandardInput:nullInputHandle()];
    if (setupTask != nil) {
        setupTask(task);
    }
    [task launch];
    NSData *stdoutData = [[stdoutpipe fileHandleForReading] readDataToEndOfFile];
    NSData *stderrData = [[stderrpipe fileHandleForReading] readDataToEndOfFile];
    [task waitUntilExit];
    NSString *stdoutString = [[NSString alloc] initWithData:stdoutData encoding:NSUTF8StringEncoding] ?: @"";
    NSString *stderrString = [[NSString alloc] initWithData:stderrData encoding:NSUTF8StringEncoding] ?: @"";
    return @{
        @"exitCode": @(task.terminationStatus),
        @"stdout": stdoutString,
        @"stderr": stderrString,
    };
}

int runCommandLine(NSString* launchPath, NSArray* arguments) {
    return [runCommandLineResult(launchPath, arguments)[@"exitCode"] intValue];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context {
    if ([@"selectedPacFileName" isEqualToString:keyPath]) {
        NSLog(@"pac file is switched to %@", selectedPacFileName);
        if (dispatchPacSource) { //stop monitor previous pac
            dispatch_source_cancel(dispatchPacSource);
        }
        if (selectedPacFileName == nil || selectedPacFileName.length == 0) {
            return;
        }
        NSString* pacFullPath = [NSString stringWithFormat:@"%@/Library/Application Support/V2RayXS/pac/%@",NSHomeDirectory(), selectedPacFileName];
        if (![[NSFileManager defaultManager] fileExistsAtPath:pacFullPath]) {
            NSString* simplePac = [[NSBundle mainBundle] pathForResource:@"simple" ofType:@"pac"];
            [[NSFileManager defaultManager] copyItemAtPath:simplePac toPath:pacFullPath error:nil];
        }
        //https://randexdev.com/2012/03/how-to-detect-directory-changes-using-gcd/
        int fildes = open([pacFullPath cStringUsingEncoding:NSUTF8StringEncoding], O_RDONLY);
        dispatchPacSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, fildes, DISPATCH_VNODE_WRITE | DISPATCH_VNODE_EXTEND, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));
        dispatch_source_set_event_handler(dispatchPacSource, ^{
            NSLog(@"pac file changed");
            if (self.proxyMode == pacMode && self.proxyState == true) {
                [appDelegate updateSystemProxy];
                NSLog(@"refreshed system pacfile.");
            }
        });
        dispatch_resume(dispatchPacSource);
    }
}

@synthesize logDirPath;

@synthesize proxyState;
@synthesize proxyMode;
@synthesize localPort;
@synthesize httpPort;
@synthesize udpSupport;
@synthesize shareOverLan;
@synthesize selectedServerIndex;
@synthesize selectedPacFileName;
@synthesize dnsString;
@synthesize profiles;
@synthesize logLevel;
@synthesize cusProfiles;
@synthesize useCusProfile;
@synthesize selectedCusServerIndex;
@synthesize useMultipleServer;
@end
