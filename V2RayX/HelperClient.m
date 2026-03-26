#import "HelperClient.h"
#import <signal.h>
#import <sys/socket.h>
#import <sys/uio.h>
#import <unistd.h>

NSDictionary* runCommandLineResult(NSString* launchPath, NSArray* arguments);
NSDictionary* runCommandLineResultWithStdinFD(NSString* launchPath, NSArray* arguments, int stdinFD);
pid_t spawnDetachedProcess(NSString* launchPath, NSArray<NSString*>* arguments);

static BOOL helperClientDebugEnabled(void) {
    return [[[NSProcessInfo processInfo] arguments] containsObject:@"--debug"];
}

static NSArray<NSString*>* helperClientArgumentsWithOptionalDebug(NSArray<NSString*>* arguments) {
    if (!helperClientDebugEnabled() || [arguments containsObject:@"--debug"]) {
        return arguments;
    }
    return [arguments arrayByAddingObject:@"--debug"];
}

static NSDictionary* helperClientReceiveFileDescriptorAndPayload(int socketFD) {
    if (socketFD < 0) {
        return nil;
    }

    char payloadBuffer[4096];
    memset(payloadBuffer, 0, sizeof(payloadBuffer));
    char controlBuffer[CMSG_SPACE(sizeof(int))];
    memset(controlBuffer, 0, sizeof(controlBuffer));

    struct iovec io = {
        .iov_base = payloadBuffer,
        .iov_len = sizeof(payloadBuffer) - 1,
    };
    struct msghdr message;
    memset(&message, 0, sizeof(message));
    message.msg_iov = &io;
    message.msg_iovlen = 1;
    message.msg_control = controlBuffer;
    message.msg_controllen = sizeof(controlBuffer);

    ssize_t received = recvmsg(socketFD, &message, 0);
    if (received <= 0) {
        return nil;
    }

    int receivedFD = -1;
    for (struct cmsghdr* header = CMSG_FIRSTHDR(&message); header != NULL; header = CMSG_NXTHDR(&message, header)) {
        if (header->cmsg_level == SOL_SOCKET && header->cmsg_type == SCM_RIGHTS) {
            memcpy(&receivedFD, CMSG_DATA(header), sizeof(int));
            break;
        }
    }
    if (receivedFD < 0) {
        return nil;
    }

    NSData* payloadData = [NSData dataWithBytes:payloadBuffer length:(NSUInteger)received];
    NSDictionary* payload = [NSJSONSerialization JSONObjectWithData:payloadData options:0 error:nil];
    if (![payload isKindOfClass:[NSDictionary class]]) {
        close(receivedFD);
        return nil;
    }

    return @{
        @"fd": @(receivedFD),
        @"payload": payload,
    };
}

@interface HelperClient ()

@property (nonatomic, copy) NSString* helperPath;

@end

@implementation HelperClient

- (instancetype)initWithHelperPath:(NSString*)helperPath {
    self = [super init];
    if (self != nil) {
        _helperPath = [helperPath copy];
    }
    return self;
}

- (NSDictionary*)parsedJSONPayloadFromTaskResult:(NSDictionary*)taskResult {
    NSString* stdoutString = [taskResult[@"stdout"] isKindOfClass:[NSString class]] ? taskResult[@"stdout"] : @"";
    if (stdoutString.length == 0) {
        return nil;
    }
    NSData* stdoutData = [stdoutString dataUsingEncoding:NSUTF8StringEncoding];
    if (stdoutData == nil) {
        return nil;
    }
    NSDictionary* jsonObject = [NSJSONSerialization JSONObjectWithData:stdoutData options:0 error:nil];
    return [jsonObject isKindOfClass:[NSDictionary class]] ? jsonObject : nil;
}

- (NSString*)failureDetailsFromTaskResult:(NSDictionary*)taskResult {
    NSString* stderrString = [taskResult[@"stderr"] isKindOfClass:[NSString class]] ? taskResult[@"stderr"] : @"";
    NSString* trimmedStderr = [stderrString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmedStderr.length > 0) {
        return trimmedStderr;
    }

    NSDictionary* jsonObject = [self parsedJSONPayloadFromTaskResult:taskResult];
    NSString* jsonMessage = [jsonObject isKindOfClass:[NSDictionary class]] ? jsonObject[@"message"] : nil;
    if ([jsonMessage isKindOfClass:[NSString class]]) {
        NSString* trimmedMessage = [jsonMessage stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmedMessage.length > 0) {
            return trimmedMessage;
        }
    }

    return @"";
}

- (BOOL)isExpectedTunStartSignalExitForArguments:(NSArray<NSString*>*)arguments exitCode:(int)exitCode {
    NSString* commandName = arguments.count > 0 ? arguments[0] : @"";
    NSString* tunSubcommand = arguments.count > 1 ? arguments[1] : @"";
    return [commandName isEqualToString:@"tun"] && [tunSubcommand isEqualToString:@"start"] && (exitCode == SIGTERM || exitCode == SIGINT);
}

- (void)presentFailureMessage:(NSString*)message {
    if (self.failurePresenter != nil) {
        self.failurePresenter(message);
    }
}

- (NSString*)helperIssueMessage {
    return self.helperIssueProvider != nil ? self.helperIssueProvider() : nil;
}

- (NSString*)errorMessageForArguments:(NSArray<NSString*>*)arguments action:(NSString*)action taskResult:(NSDictionary*)taskResult {
    int exitCode = [taskResult[@"exitCode"] intValue];
    NSString* commandError = [self failureDetailsFromTaskResult:taskResult];
    NSString* helperIssue = [self helperIssueMessage];
    NSString* errorMessage = [NSString stringWithFormat:@"Helper command `%@` failed with exit code %d.", [arguments componentsJoinedByString:@" "], exitCode];
    if (commandError.length > 0) {
        errorMessage = [errorMessage stringByAppendingFormat:@"\n\nError: %@", commandError];
    }
    if (helperIssue.length > 0) {
        errorMessage = [errorMessage stringByAppendingFormat:@"\n\nDetected helper issue: %@\nPlease reinstall the helper.", helperIssue];
    }
    NSLog(@"%@ (%@)", errorMessage, action);
    return errorMessage;
}

- (NSDictionary*)taskResultForArguments:(NSArray<NSString*>*)arguments {
    return runCommandLineResult(self.helperPath, helperClientArgumentsWithOptionalDebug(arguments));
}

- (BOOL)launchDetachedCommandWithArguments:(NSArray<NSString*>*)arguments error:(NSString**)errorMessage {
    pid_t pid = spawnDetachedProcess(self.helperPath, helperClientArgumentsWithOptionalDebug(arguments));
    if (pid == 0) {
        if (errorMessage != NULL) {
            *errorMessage = @"Failed to launch detached helper command.";
        }
        return NO;
    }
    return YES;
}

- (BOOL)runCommandWithArguments:(NSArray<NSString*>*)arguments action:(NSString*)action {
    NSDictionary* taskResult = [self taskResultForArguments:arguments];
    int exitCode = [taskResult[@"exitCode"] intValue];
    if (exitCode == 0 || [self isExpectedTunStartSignalExitForArguments:arguments exitCode:exitCode]) {
        if (exitCode != 0) {
            NSLog(@"Helper command `%@` exited with signal %d during expected shutdown", [arguments componentsJoinedByString:@" "], exitCode);
        }
        return YES;
    }

    [self presentFailureMessage:[self errorMessageForArguments:arguments action:action taskResult:taskResult]];
    return NO;
}

- (NSDictionary*)runJSONCommandWithArguments:(NSArray<NSString*>*)arguments action:(NSString*)action {
    NSDictionary* taskResult = [self taskResultForArguments:arguments];
    int exitCode = [taskResult[@"exitCode"] intValue];
    NSDictionary* payload = [self parsedJSONPayloadFromTaskResult:taskResult];
    if (exitCode == 0 || [self isExpectedTunStartSignalExitForArguments:arguments exitCode:exitCode]) {
        if (exitCode != 0) {
            NSLog(@"Helper command `%@` exited with signal %d during expected shutdown", [arguments componentsJoinedByString:@" "], exitCode);
        }
        return payload;
    }

    [self presentFailureMessage:[self errorMessageForArguments:arguments action:action taskResult:taskResult]];
    return nil;
}

- (BOOL)runHelperDaemonWithAction:(NSString*)action {
    NSString* launchError = nil;
    if (![self launchDetachedCommandWithArguments:@[@"daemon", @"run"] error:&launchError]) {
        NSString* message = launchError.length > 0 ? launchError : @"Failed to launch helper daemon.";
        NSLog(@"%@ (%@)", message, action);
        [self presentFailureMessage:message];
        return NO;
    }
    return YES;
}

- (BOOL)ensureDaemonIsRunning {
    NSDictionary* daemonStatus = [self helperDaemonStatusWithAction:@"check helper daemon status"];
    NSString* daemonState = [daemonStatus[@"daemon"] isKindOfClass:[NSString class]] ? daemonStatus[@"daemon"] : @"";
    if ([daemonState isEqualToString:@"available"]) {
        return YES;
    }
    if (![self runHelperDaemonWithAction:@"start helper daemon"]) {
        return NO;
    }
    for (NSInteger attempt = 0; attempt < 10; attempt += 1) {
        [NSThread sleepForTimeInterval:0.2];
        NSDictionary* refreshedStatus = [self helperDaemonStatusWithAction:@"wait for helper daemon after startup"];
        NSString* refreshedDaemonState = [refreshedStatus[@"daemon"] isKindOfClass:[NSString class]] ? refreshedStatus[@"daemon"] : @"";
        if ([refreshedDaemonState isEqualToString:@"available"]) {
            return YES;
        }
    }
    return NO;
}

- (NSDictionary*)helperDaemonStatusWithAction:(NSString*)action {
    return [self runJSONCommandWithArguments:@[@"daemon", @"status", @"--json"] action:action];
}

- (NSDictionary*)stopHelperDaemonWithAction:(NSString*)action {
    return [self runJSONCommandWithArguments:@[@"daemon", @"stop", @"--json"] action:action];
}

- (NSDictionary*)allocateTunFDWithPreferredName:(NSString*)preferredName error:(NSString* _Nullable __autoreleasing *)errorMessage {
    if (![self ensureDaemonIsRunning]) {
        if (errorMessage != NULL) {
            *errorMessage = @"Failed to start helper daemon for tun allocation.";
        }
        return nil;
    }

    int sockets[2] = {-1, -1};
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) != 0) {
        if (errorMessage != NULL) {
            *errorMessage = @"Failed to create local tun fd transport socketpair.";
        }
        return nil;
    }

    NSString* socketFDString = @"0";
    NSArray<NSString*>* arguments = preferredName.length > 0 ? @[@"tun", @"allocate", preferredName, socketFDString] : @[@"tun", @"allocate", socketFDString];
    arguments = helperClientArgumentsWithOptionalDebug(arguments);
    int helperSocketFD = sockets[1];
    NSDictionary* helperResult = runCommandLineResultWithStdinFD(self.helperPath, arguments, helperSocketFD);
    close(sockets[1]);
    if ([helperResult[@"exitCode"] intValue] != 0) {
        close(sockets[0]);
        if (errorMessage != NULL) {
            NSString* helperError = [self failureDetailsFromTaskResult:helperResult];
            *errorMessage = helperError.length > 0 ? helperError : @"Helper failed to prepare tun fd.";
        }
        return nil;
    }

    NSDictionary* received = helperClientReceiveFileDescriptorAndPayload(sockets[0]);
    close(sockets[0]);
    if (![received isKindOfClass:[NSDictionary class]]) {
        if (errorMessage != NULL) {
            *errorMessage = @"Did not receive tun fd from helper.";
        }
        return nil;
    }

    NSDictionary* payload = received[@"payload"];
    NSString* tunName = [payload[@"tunName"] isKindOfClass:[NSString class]] ? payload[@"tunName"] : @"";
    NSString* leaseId = [payload[@"leaseId"] isKindOfClass:[NSString class]] ? payload[@"leaseId"] : @"";
    NSNumber* fdNumber = received[@"fd"];
    if (tunName.length == 0 || leaseId.length == 0 || ![fdNumber isKindOfClass:[NSNumber class]]) {
        int receivedFD = [fdNumber intValue];
        if (receivedFD >= 0) {
            close(receivedFD);
        }
        if (errorMessage != NULL) {
            *errorMessage = @"Helper returned incomplete tun fd payload.";
        }
        return nil;
    }

    return @{
        @"tunName": tunName,
        @"leaseId": leaseId,
        @"fd": fdNumber,
    };
}

- (BOOL)disableSystemProxyWithAction:(NSString*)action {
    return [self runCommandWithArguments:@[@"off"] action:action];
}

- (BOOL)restoreSystemProxyWithAction:(NSString*)action {
    return [self runCommandWithArguments:@[@"restore"] action:action];
}

- (NSDictionary*)startEmbeddedTunWithLocalPort:(NSInteger)localPort action:(NSString*)action {
    if (![self ensureDaemonIsRunning]) {
        return nil;
    }
    return [self runJSONCommandWithArguments:@[@"tun", @"start", [NSString stringWithFormat:@"%ld", (long)localPort]] action:action];
}

- (NSDictionary*)tunStatusWithAction:(NSString*)action {
    return [self runJSONCommandWithArguments:@[@"tun", @"status", @"--json"] action:action];
}

- (NSDictionary*)activateTunWithLeaseId:(NSString*)leaseId action:(NSString*)action {
    NSArray<NSString*>* arguments = leaseId.length > 0 ? @[@"tun", @"activate", leaseId, @"--json"] : @[@"tun", @"activate", @"--json"];
    return [self runJSONCommandWithArguments:arguments action:action];
}

- (NSDictionary*)activateTunLeaseSynchronouslyWithLeaseId:(NSString*)leaseId action:(NSString*)action {
    NSDictionary* response = nil;
    for (NSInteger attempt = 0; attempt < 10; attempt += 1) {
        response = [self activateTunWithLeaseId:leaseId action:action];
        NSString* session = [response[@"session"] isKindOfClass:[NSString class]] ? response[@"session"] : @"";
        NSDictionary* status = [response[@"status"] isKindOfClass:[NSDictionary class]] ? response[@"status"] : response;
        NSString* statusSession = [status[@"session"] isKindOfClass:[NSString class]] ? status[@"session"] : @"";
        if ([session isEqualToString:@"active"] || [statusSession isEqualToString:@"active"]) {
            return response;
        }
        [NSThread sleepForTimeInterval:0.3];
    }
    return response;
}

- (NSDictionary*)deactivateTunWithLeaseId:(NSString*)leaseId action:(NSString*)action {
    NSArray<NSString*>* arguments = leaseId.length > 0 ? @[@"tun", @"deactivate", leaseId, @"--json"] : @[@"tun", @"deactivate", @"--json"];
    return [self runJSONCommandWithArguments:arguments action:action];
}

- (NSDictionary*)stopTunWithAction:(NSString*)action {
    return [self runJSONCommandWithArguments:@[@"tun", @"stop", @"--json"] action:action];
}

- (NSDictionary*)syncRouteWhitelistAtPath:(NSString*)path action:(NSString*)action {
    return [self runJSONCommandWithArguments:@[@"route", @"sync-file", path] action:action];
}

- (BOOL)clearRouteWhitelistWithAction:(NSString*)action {
    return [self runCommandWithArguments:@[@"route", @"clear"] action:action];
}

@end
