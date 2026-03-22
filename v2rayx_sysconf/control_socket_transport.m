#import <Foundation/Foundation.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/un.h>
#import <unistd.h>
#import "control_socket_transport.h"
#import "helper_paths.h"

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
        NSDictionary* response = handler != nil ? handler(request ?: @{}) : @{@"ok": @NO, @"message": @"Missing control socket handler."};
        NSData* responseData = [NSJSONSerialization dataWithJSONObject:response options:0 error:nil];
        if (responseData != nil) {
            write(clientFD, [responseData bytes], [responseData length]);
        }
        close(clientFD);
    }
}

NSDictionary* sendRequestToControlServer(NSDictionary* request, NSString** errorMessage) {
    int clientFD = socket(AF_UNIX, SOCK_STREAM, 0);
    if (clientFD == -1) {
        if (errorMessage != NULL) {
            *errorMessage = @"Failed to create client socket.";
        }
        return nil;
    }
    struct sockaddr_un address;
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    NSString* socketPath = helperControlSocketPath();
    strncpy(address.sun_path, [socketPath fileSystemRepresentation], sizeof(address.sun_path) - 1);
    if (connect(clientFD, (struct sockaddr*)&address, sizeof(address)) != 0) {
        close(clientFD);
        if (errorMessage != NULL) {
            *errorMessage = @"No active tun session.";
        }
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
    NSMutableData* responseData = [[NSMutableData alloc] init];
    uint8_t buffer[4096];
    ssize_t bytesRead = 0;
    while ((bytesRead = read(clientFD, buffer, sizeof(buffer))) > 0) {
        [responseData appendBytes:buffer length:(NSUInteger)bytesRead];
    }
    close(clientFD);
    NSDictionary* response = responseData.length > 0 ? [NSJSONSerialization JSONObjectWithData:responseData options:0 error:nil] : nil;
    if (response == nil && errorMessage != NULL) {
        *errorMessage = @"Failed to decode tun session response.";
    }
    return response;
}
