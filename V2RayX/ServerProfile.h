//
//  ServerProfile.h
//  V2RayX
//
//  Copyright © 2016年 Cenmrev. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "AppDelegate.h"
#import "utilities.h"

typedef enum ProtocolType : NSUInteger {
    vmess,
    vless
} ProtocolType;

typedef enum SecurityType : NSUInteger {
    none_security,
    auto_security,
    aes_128_gcm,
    chacha20_poly130
} SecurityType;

typedef enum FlowType : NSUInteger {
    none_flow,
    xtls_rprx_direct,
    xtls_rprx_direct_udp443,
    xtls_rprx_origin,
    xtls_rprx_origin_udp443,
    xtls_rprx_splice,
    xtls_rprx_splice_udp443
} FlowType;

typedef enum NetWorkType : NSUInteger {
    tcp,
    kcp,
    ws,
    http,
    quic
} NetWorkType;

@interface ServerProfile : NSObject
- (NSMutableDictionary* _Null_unspecified)outboundProfile;
+ (ServerProfile* _Nullable)readFromAnOutboundDic:(NSDictionary* _Null_unspecified)outDict;
+ (NSArray* _Null_unspecified)profilesFromJson:(NSDictionary* _Null_unspecified)outboundJson;
-(ServerProfile* _Null_unspecified)deepCopy;

@property (nonatomic) NSString* _Null_unspecified address;
@property (nonatomic) ProtocolType protocol;
@property (nonatomic) NSUInteger port;
@property (nonatomic) NSString* _Null_unspecified userId;
@property (nonatomic) NSUInteger alterId;
@property (nonatomic) NSUInteger level;
@property (nonatomic) NSString* _Null_unspecified outboundTag;
@property (nonatomic) FlowType flow;
@property (nonatomic) SecurityType security;
@property (nonatomic) NetWorkType network;
@property (nonatomic) NSString* _Null_unspecified sendThrough;
@property (nonatomic) NSDictionary* _Null_unspecified streamSettings; // except network type.
@property (nonatomic) NSDictionary* _Null_unspecified muxSettings;
@end
