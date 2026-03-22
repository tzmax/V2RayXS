#ifndef control_socket_transport_h
#define control_socket_transport_h

#import <Foundation/Foundation.h>

typedef NSDictionary* (^ControlSocketRequestHandler)(NSDictionary* request);

BOOL startControlSocketServer(int* serverFDOut, NSString** errorMessage);
void controlSocketAcceptLoop(int serverFD, BOOL* runLoopMark, ControlSocketRequestHandler handler);
NSDictionary* sendRequestToControlServer(NSDictionary* request, NSString** errorMessage);

#endif /* control_socket_transport_h */
