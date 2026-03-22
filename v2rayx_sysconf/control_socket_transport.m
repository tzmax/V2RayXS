#import <Foundation/Foundation.h>
#import <errno.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/un.h>
#import <unistd.h>
#import "control_socket_transport.h"
#import "helper_paths.h"

static int connectToControlSocket(NSString** errorMessage);
static NSDictionary* receiveJSONResponseWithOptionalFD(int clientFD, int* receivedFDOut, NSString** errorMessage);
static BOOL sendJSONResponseWithOptionalFD(int clientFD, NSDictionary* response, int responseFD);

BOOL startControlSocketServer(int* serverFDOut, NSString** errorMessage) {
    helperEnsureAppSupportDirectory();
    NSString* socketPath = helperControlSocketPath();
    unlink([socketPath fileSystemRepresentation]);
    int serverFD = socket(AF_UNIX, SOCK_STREAM, 0);
    if (serverFD == -1) {
        if (errorMessage != NULL) {
            *errorMessage = @"Failed to create control socket.";
        }
        return NO;
    }
    struct sockaddr_un address;
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    strncpy(address.sun_path, [socketPath fileSystemRepresentation], sizeof(address.sun_path) - 1);
    if (bind(serverFD, (struct sockaddr*)&address, sizeof(address)) != 0) {
        close(serverFD);
        if (errorMessage != NULL) {
            *errorMessage = @"Failed to bind control socket.";
        }
        return NO;
    }
    chmod([socketPath fileSystemRepresentation], 0600);
    if (listen(serverFD, 8) != 0) {
        close(serverFD);
        if (errorMessage != NULL) {
            *errorMessage = @"Failed to listen on control socket.";
        }
        return NO;
    }
    if (serverFDOut != NULL) {
        *serverFDOut = serverFD;
    }
    return YES;
}

void controlSocketAcceptLoop(int serverFD, BOOL* runLoopMark, ControlSocketRequestHandler handler) {
    while ((runLoopMark == NULL || *runLoopMark) && serverFD != -1) {
        int clientFD = accept(serverFD, NULL, NULL);
        if (clientFD == -1) {
            continue;
        }
        NSMutableData* inputData = [[NSMutableData alloc] init];
        uint8_t buffer[4096];
        ssize_t bytesRead = 0;
        while ((bytesRead = read(clientFD, buffer, sizeof(buffer))) > 0) {
            [inputData appendBytes:buffer length:(NSUInteger)bytesRead];
        }
        NSDictionary* request = nil;
        if (inputData.length > 0) {
            request = [NSJSONSerialization JSONObjectWithData:inputData options:0 error:nil];
        }
        int responseFD = -1;
        NSDictionary* response = handler != nil ? handler(request ?: @{}, &responseFD) : @{@"ok": @NO, @"message": @"Missing control socket handler."};
        sendJSONResponseWithOptionalFD(clientFD, response, responseFD);
        if (responseFD >= 0) {
            close(responseFD);
        }
        close(clientFD);
    }
}

NSDictionary* sendRequestToControlServer(NSDictionary* request, NSString** errorMessage) {
    return sendRequestToControlServerWithFD(request, NULL, errorMessage);
}

NSDictionary* sendRequestToControlServerWithFD(NSDictionary* request, int* receivedFDOut, NSString** errorMessage) {
    int clientFD = connectToControlSocket(errorMessage);
    if (clientFD == -1) {
        return nil;
    }
    NSData* requestData = [NSJSONSerialization dataWithJSONObject:request options:0 error:nil];
    if (requestData == nil || write(clientFD, [requestData bytes], [requestData length]) < 0) {
        close(clientFD);
        if (errorMessage != NULL) {
            *errorMessage = @"Failed to send request to tun session.";
        }
        return nil;
    }
    shutdown(clientFD, SHUT_WR);
    NSDictionary* response = receiveJSONResponseWithOptionalFD(clientFD, receivedFDOut, errorMessage);
    close(clientFD);
    return response;
}

BOOL isControlSocketReachable(void) {
    int clientFD = connectToControlSocket(NULL);
    BOOL reachable = clientFD != -1;
    close(clientFD);
    return reachable;
}

static int connectToControlSocket(NSString** errorMessage) {
    int clientFD = socket(AF_UNIX, SOCK_STREAM, 0);
    if (clientFD == -1) {
        if (errorMessage != NULL) {
            *errorMessage = @"Failed to create client socket.";
        }
        return -1;
    }
    struct sockaddr_un address;
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    NSString* socketPath = helperControlSocketPath();
    strncpy(address.sun_path, [socketPath fileSystemRepresentation], sizeof(address.sun_path) - 1);
    if (connect(clientFD, (struct sockaddr*)&address, sizeof(address)) != 0) {
        close(clientFD);
        if (errorMessage != NULL) {
            *errorMessage = @"No active daemon session.";
        }
        return -1;
    }
    return clientFD;
}

static NSDictionary* receiveJSONResponseWithOptionalFD(int clientFD, int* receivedFDOut, NSString** errorMessage) {
    if (receivedFDOut != NULL) {
        *receivedFDOut = -1;
    }
    NSMutableData* responseData = [[NSMutableData alloc] init];
    BOOL receivedAnyPayload = NO;
    while (YES) {
        uint8_t buffer[4096];
        char control[CMSG_SPACE(sizeof(int))];
        struct iovec iov = {.iov_base = buffer, .iov_len = sizeof(buffer)};
        struct msghdr msg;
        memset(&msg, 0, sizeof(msg));
        msg.msg_iov = &iov;
        msg.msg_iovlen = 1;
        msg.msg_control = control;
        msg.msg_controllen = sizeof(control);
        ssize_t bytesRead = recvmsg(clientFD, &msg, 0);
        if (bytesRead < 0) {
            if (errno == EINTR) {
                continue;
            }
            if (errorMessage != NULL) {
                *errorMessage = @"Failed to read daemon response.";
            }
            return nil;
        }
        if (bytesRead == 0) {
            break;
        }
        receivedAnyPayload = YES;
        [responseData appendBytes:buffer length:(NSUInteger)bytesRead];
        if (receivedFDOut != NULL) {
            for (struct cmsghdr* cmsg = CMSG_FIRSTHDR(&msg); cmsg != NULL; cmsg = CMSG_NXTHDR(&msg, cmsg)) {
                if (cmsg->cmsg_level == SOL_SOCKET && cmsg->cmsg_type == SCM_RIGHTS) {
                    memcpy(receivedFDOut, CMSG_DATA(cmsg), sizeof(int));
                    break;
                }
            }
        }
    }
    NSDictionary* response = receivedAnyPayload ? [NSJSONSerialization JSONObjectWithData:responseData options:0 error:nil] : nil;
    if (response == nil && errorMessage != NULL) {
        *errorMessage = @"Failed to decode tun session response.";
    }
    return response;
}

static BOOL sendJSONResponseWithOptionalFD(int clientFD, NSDictionary* response, int responseFD) {
    NSData* responseData = [NSJSONSerialization dataWithJSONObject:response options:0 error:nil];
    if (responseData == nil) {
        return NO;
    }
    if (responseFD < 0) {
        return write(clientFD, [responseData bytes], [responseData length]) == (ssize_t)[responseData length];
    }
    struct iovec iov = {.iov_base = (void*)[responseData bytes], .iov_len = [responseData length]};
    char control[CMSG_SPACE(sizeof(int))];
    memset(control, 0, sizeof(control));
    struct msghdr msg;
    memset(&msg, 0, sizeof(msg));
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_control = control;
    msg.msg_controllen = sizeof(control);
    struct cmsghdr* cmsg = CMSG_FIRSTHDR(&msg);
    cmsg->cmsg_level = SOL_SOCKET;
    cmsg->cmsg_type = SCM_RIGHTS;
    cmsg->cmsg_len = CMSG_LEN(sizeof(int));
    memcpy(CMSG_DATA(cmsg), &responseFD, sizeof(int));
    msg.msg_controllen = cmsg->cmsg_len;
    return sendmsg(clientFD, &msg, 0) != -1;
}
