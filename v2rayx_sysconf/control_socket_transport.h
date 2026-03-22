#ifndef control_socket_transport_h
#define control_socket_transport_h

#import <Foundation/Foundation.h>

typedef NSDictionary* (^ControlSocketRequestHandler)(NSDictionary* request, int* responseFDOut);

BOOL startControlSocketServer(int* serverFDOut, NSString** errorMessage);
void controlSocketAcceptLoop(int serverFD, BOOL* runLoopMark, ControlSocketRequestHandler handler);
NSDictionary* sendRequestToControlServer(NSDictionary* request, NSString** errorMessage);
NSDictionary* sendRequestToControlServerWithFD(NSDictionary* request, int* receivedFDOut, NSString** errorMessage);
BOOL isControlSocketReachable(void);

#endif /* control_socket_transport_h */
