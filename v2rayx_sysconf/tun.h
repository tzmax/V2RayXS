//
//  tun.h
//  V2RayXS
//
//  Created by tzmax on 2023/1/20.
//  Copyright © 2023 Project V2Ray. All rights reserved.
//

#ifndef tun_h
#define tun_h

#import <Foundation/Foundation.h>

int createTUN(void);
int createTUNWithName(NSString* preferredName, NSString** actualNameOut);
BOOL ensureTUNInterfaceReady(NSString* tunName, uint32_t mtu, NSString** errorMessage);
BOOL sendFileDescriptor(int socketFD, int fileDescriptor, NSString* payload);

#endif /* tun_h */
