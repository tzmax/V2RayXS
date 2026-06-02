//
//  XrayShareLinkParser.m
//  V2RayX
//

#import "XrayShareLinkParser.h"
#import "MutableDeepCopying.h"

NSErrorDomain const XrayShareLinkParserErrorDomain = @"XrayShareLinkParserErrorDomain";

@interface XrayShareLinkParseResult ()
@property (nonatomic, strong) ServerProfile *profile;
@property (nonatomic, copy) NSArray<NSString *> *warnings;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *rawQuery;
@property (nonatomic) XrayShareLinkCoreCompatibility coreCompatibility;
@end

@implementation XrayShareLinkParseResult

- (instancetype)initWithProfile:(ServerProfile *)profile
                       warnings:(NSArray<NSString *> *)warnings
                       rawQuery:(NSDictionary<NSString *,NSString *> *)rawQuery
              coreCompatibility:(XrayShareLinkCoreCompatibility)coreCompatibility {
    self = [super init];
    if (self) {
        _profile = profile;
        _warnings = [warnings copy];
        _rawQuery = [rawQuery copy];
        _coreCompatibility = coreCompatibility;
    }
    return self;
}

@end

@interface XrayShareLinkParserContext : NSObject
@property (nonatomic) XrayShareLinkParseMode mode;
@property (nonatomic, strong) NSMutableArray<NSString *> *warnings;
@property (nonatomic) XrayShareLinkCoreCompatibility compatibility;
@end

@implementation XrayShareLinkParserContext
- (instancetype)init {
    self = [super init];
    if (self) {
        _mode = XrayShareLinkParseModeCompatible;
        _warnings = [[NSMutableArray alloc] init];
        _compatibility = XrayShareLinkCoreCompatibilityCurrent;
    }
    return self;
}
@end

@implementation XrayShareLinkParser

+ (BOOL)canParseLink:(NSString *)link {
    NSString *trimmed = [self trimmedString:link];
    NSString *lowercase = [trimmed lowercaseString];
    return [lowercase hasPrefix:@"vmess://"] || [lowercase hasPrefix:@"vless://"];
}

+ (XrayShareLinkParseResult *)parseLink:(NSString *)link error:(NSError **)error {
    return [self parseLink:link mode:XrayShareLinkParseModeCompatible error:error];
}

+ (XrayShareLinkParseResult *)parseLink:(NSString *)link mode:(XrayShareLinkParseMode)mode error:(NSError **)error {
    NSString *trimmed = [self trimmedString:link];
    if (![self canParseLink:trimmed]) {
        [self assignError:error code:XrayShareLinkParserErrorUnsupportedProtocol reason:@"Only vmess:// and vless:// links are supported by the standard parser."];
        return nil;
    }

    NSURLComponents *components = [NSURLComponents componentsWithString:trimmed];
    if (components == nil) {
        [self assignError:error code:XrayShareLinkParserErrorInvalidURL reason:@"Invalid share link URL."];
        return nil;
    }

    NSString *scheme = [[components.scheme ?: @"" lowercaseString] copy];
    if (!([scheme isEqualToString:@"vmess"] || [scheme isEqualToString:@"vless"])) {
        [self assignError:error code:XrayShareLinkParserErrorUnsupportedProtocol reason:@"Unsupported share link protocol."];
        return nil;
    }

    XrayShareLinkParserContext *context = [[XrayShareLinkParserContext alloc] init];
    context.mode = mode;

    NSDictionary<NSString *, NSString *> *query = [self queryDictionaryFromComponents:components context:context error:error];
    if (query == nil) {
        return nil;
    }

    NSString *uuid = [components.percentEncodedUser ?: components.user stringByRemovingPercentEncoding] ?: @"";
    NSString *host = components.host ?: @"";
    NSNumber *port = components.port;
    if (![self validateRequiredString:uuid name:@"uuid" error:error] || ![self validateRequiredString:host name:@"remote-host" error:error]) {
        return nil;
    }
    if (mode == XrayShareLinkParseModeStrictStandard && [[NSUUID alloc] initWithUUIDString:uuid] == nil) {
        [self assignError:error code:XrayShareLinkParserErrorInvalidQueryValue reason:@"uuid must be a valid UUID."];
        return nil;
    }
    if (port == nil || port.integerValue < 1 || port.integerValue > 65535) {
        [self assignError:error code:XrayShareLinkParserErrorMissingRequiredField reason:@"remote-port is required and must be in 1...65535."];
        return nil;
    }

    ServerProfile *profile = [[ServerProfile alloc] init];
    profile.protocol = [scheme isEqualToString:@"vmess"] ? vmess : vless;
    profile.address = host;
    profile.port = port.unsignedIntegerValue;
    profile.userId = uuid;
    profile.outboundTag = [components.percentEncodedFragment stringByRemovingPercentEncoding] ?: components.fragment ?: [NSString stringWithFormat:@"%@:%@", host, port];
    profile.alterId = 0;

    NSMutableDictionary *streamSettings = [profile.streamSettings mutableDeepCopy];
    if (mode == XrayShareLinkParseModeStrictStandard && ![self validateStrictQuery:query scheme:scheme error:error]) {
        return nil;
    }
    [self applyProtocolFields:query toProfile:profile scheme:scheme context:context error:error];
    if (error != nil && *error != nil && mode == XrayShareLinkParseModeStrictStandard) {
        return nil;
    }
    if (![self applyTransportFields:query toProfile:profile streamSettings:streamSettings context:context error:error]) {
        return nil;
    }
    if (![self applySecurityFields:query toProfile:profile streamSettings:streamSettings context:context error:error]) {
        return nil;
    }
    [self applyFinalmaskFromQuery:query streamSettings:streamSettings context:context error:error];
    if (error != nil && *error != nil && mode == XrayShareLinkParseModeStrictStandard) {
        return nil;
    }

    profile.streamSettings = normalizedStreamSettingsForXray(streamSettings);
    return [[XrayShareLinkParseResult alloc] initWithProfile:profile
                                                   warnings:context.warnings
                                                   rawQuery:query
                                          coreCompatibility:context.compatibility];
}

+ (NSDictionary<NSString *, NSString *> *)queryDictionaryFromComponents:(NSURLComponents *)components context:(XrayShareLinkParserContext *)context error:(NSError **)error {
    NSMutableDictionary<NSString *, NSString *> *query = [[NSMutableDictionary alloc] init];
    for (NSURLQueryItem *item in components.queryItems ?: @[]) {
        NSString *name = item.name ?: @"";
        NSString *value = item.value ?: @"";
        if (name.length == 0) {
            continue;
        }
        if (query[name] != nil) {
            NSString *warning = [NSString stringWithFormat:@"Duplicate query item '%@'; using the last value.", name];
            if (context.mode == XrayShareLinkParseModeStrictStandard) {
                [self assignError:error code:XrayShareLinkParserErrorDuplicateQueryItem reason:warning];
                return nil;
            }
            [context.warnings addObject:warning];
            [self markLegacy:context];
        }
        query[name] = value;
    }
    return query;
}

+ (BOOL)validateStrictQuery:(NSDictionary<NSString *, NSString *> *)query scheme:(NSString *)scheme error:(NSError **)error {
    NSSet *knownKeys = [NSSet setWithArray:@[@"type", @"encryption", @"flow", @"security", @"path", @"host", @"mtu", @"tti", @"serviceName", @"mode", @"authority", @"extra", @"fm", @"fp", @"sni", @"alpn", @"ech", @"pcs", @"vcn", @"pbk", @"sid", @"pqv", @"spx"]];
    for (NSString *key in query) {
        if (![knownKeys containsObject:key]) {
            [self assignError:error code:XrayShareLinkParserErrorInvalidQueryValue reason:[NSString stringWithFormat:@"Unknown strict share-link field '%@'.", key]];
            return NO;
        }
    }

    NSSet *nonEmptyKeys = [NSSet setWithArray:@[@"type", @"encryption", @"security", @"path", @"serviceName", @"mode", @"fp", @"sni", @"alpn", @"pbk"]];
    for (NSString *key in nonEmptyKeys) {
        if (query[key] != nil && query[key].length == 0) {
            [self assignError:error code:XrayShareLinkParserErrorInvalidQueryValue reason:[NSString stringWithFormat:@"Field '%@' cannot be empty.", key]];
            return NO;
        }
    }

    NSString *type = query[@"type"].length > 0 ? query[@"type"] : @"tcp";
    NSSet *strictTransport = [NSSet setWithArray:@[@"tcp", @"kcp", @"ws", @"grpc", @"httpupgrade", @"xhttp"]];
    if (![strictTransport containsObject:type]) {
        [self assignError:error code:XrayShareLinkParserErrorUnsupportedTransport reason:[NSString stringWithFormat:@"Unsupported strict transport '%@'.", type]];
        return NO;
    }

    NSString *security = query[@"security"].length > 0 ? query[@"security"] : @"none";
    NSSet *strictSecurity = [NSSet setWithArray:@[@"none", @"tls", @"reality"]];
    if (![strictSecurity containsObject:security]) {
        [self assignError:error code:XrayShareLinkParserErrorUnsupportedSecurity reason:[NSString stringWithFormat:@"Unsupported strict security '%@'.", security]];
        return NO;
    }

    NSString *encryption = query[@"encryption"];
    if ([scheme isEqualToString:@"vmess"]) {
        if (encryption.length > 0 && ![VMESS_SECURITY_LIST containsObject:encryption]) {
            [self assignError:error code:XrayShareLinkParserErrorUnsupportedEncryption reason:[NSString stringWithFormat:@"Unsupported VMess encryption '%@'.", encryption]];
            return NO;
        }
    } else if (encryption.length > 0 && ![encryption isEqualToString:@"none"] && ![encryption hasPrefix:@"mlkem768x25519plus"]) {
        [self assignError:error code:XrayShareLinkParserErrorUnsupportedEncryption reason:[NSString stringWithFormat:@"Unsupported VLESS encryption '%@'.", encryption]];
        return NO;
    }

    NSString *flow = query[@"flow"];
    if (flow.length > 0 && !([flow isEqualToString:@"xtls-rprx-vision"] || [flow isEqualToString:@"xtls-rprx-vision-udp443"])) {
        [self assignError:error code:XrayShareLinkParserErrorInvalidQueryValue reason:[NSString stringWithFormat:@"Unsupported strict VLESS flow '%@'.", flow]];
        return NO;
    }

    if ([query[@"mtu"] length] > 0 && ![self strictPositiveInteger:query[@"mtu"]]) {
        [self assignError:error code:XrayShareLinkParserErrorInvalidQueryValue reason:@"mtu must be a positive integer."];
        return NO;
    }
    if ([query[@"tti"] length] > 0 && ![self strictPositiveInteger:query[@"tti"]]) {
        [self assignError:error code:XrayShareLinkParserErrorInvalidQueryValue reason:@"tti must be a positive integer."];
        return NO;
    }
    if (query[@"mode"].length > 0 && ![@[@"gun", @"multi", @"guna", @"auto", @"packet-up", @"stream-up", @"stream-one"] containsObject:query[@"mode"]]) {
        [self assignError:error code:XrayShareLinkParserErrorInvalidQueryValue reason:[NSString stringWithFormat:@"Unsupported mode '%@'.", query[@"mode"]]];
        return NO;
    }

    if ([type isEqualToString:@"tcp"] && query[@"path"] != nil) {
        [self assignError:error code:XrayShareLinkParserErrorInvalidQueryValue reason:@"TCP transport cannot use path."];
        return NO;
    }
    if ([type isEqualToString:@"ws"] && (query[@"mtu"] != nil || query[@"tti"] != nil || query[@"serviceName"] != nil)) {
        [self assignError:error code:XrayShareLinkParserErrorInvalidQueryValue reason:@"WebSocket transport cannot use kCP or gRPC fields."];
        return NO;
    }
    if ([security isEqualToString:@"none"] && (query[@"fp"] != nil || query[@"sni"] != nil || query[@"alpn"] != nil || query[@"ech"] != nil || query[@"pcs"] != nil || query[@"vcn"] != nil || query[@"pbk"] != nil || query[@"sid"] != nil || query[@"pqv"] != nil || query[@"spx"] != nil)) {
        [self assignError:error code:XrayShareLinkParserErrorInvalidQueryValue reason:@"security=none cannot use TLS or REALITY fields."];
        return NO;
    }
    if ([security isEqualToString:@"tls"] && query[@"pbk"] != nil) {
        [self assignError:error code:XrayShareLinkParserErrorInvalidQueryValue reason:@"TLS security cannot use REALITY pbk."];
        return NO;
    }
    if ([security isEqualToString:@"reality"]) {
        if (query[@"fp"].length == 0 || query[@"pbk"].length == 0) {
            [self assignError:error code:XrayShareLinkParserErrorInvalidQueryValue reason:@"REALITY requires non-empty fp and pbk."];
            return NO;
        }
    }
    if (query[@"pcs"].length > 0 && ![self strictHexSha256List:query[@"pcs"]]) {
        [self assignError:error code:XrayShareLinkParserErrorInvalidQueryValue reason:@"pcs must contain SHA-256 hex value(s)."];
        return NO;
    }
    if (query[@"extra"].length > 0 && [self JSONObjectFromString:query[@"extra"]] == nil) {
        [self assignError:error code:XrayShareLinkParserErrorInvalidQueryValue reason:@"extra must be valid JSON."];
        return NO;
    }
    if (query[@"fm"].length > 0 && [self JSONObjectFromString:query[@"fm"]] == nil) {
        [self assignError:error code:XrayShareLinkParserErrorInvalidQueryValue reason:@"fm must be valid JSON."];
        return NO;
    }
    return YES;
}

+ (void)applyProtocolFields:(NSDictionary<NSString *, NSString *> *)query toProfile:(ServerProfile *)profile scheme:(NSString *)scheme context:(XrayShareLinkParserContext *)context error:(NSError **)error {
    NSString *encryption = query[@"encryption"];
    if ([scheme isEqualToString:@"vmess"]) {
        NSString *vmessSecurity = encryption.length > 0 ? encryption : @"auto";
        if (![VMESS_SECURITY_LIST containsObject:vmessSecurity]) {
            [self handleInvalidValue:[NSString stringWithFormat:@"Unsupported VMess encryption '%@'.", vmessSecurity] code:XrayShareLinkParserErrorUnsupportedEncryption context:context error:error];
            vmessSecurity = @"auto";
        }
        profile.security = searchInArray(vmessSecurity, VMESS_SECURITY_LIST);
        return;
    }

    profile.security = searchInArray(@"none", VMESS_SECURITY_LIST);
    profile.userEncryption = encryption.length > 0 ? encryption : @"none";
    if (![profile.userEncryption isEqualToString:@"none"] && ![profile.userEncryption hasPrefix:@"mlkem768x25519plus"]) {
        [self handleInvalidValue:[NSString stringWithFormat:@"Unsupported VLESS encryption '%@'.", profile.userEncryption] code:XrayShareLinkParserErrorUnsupportedEncryption context:context error:error];
        profile.userEncryption = @"none";
    }
    NSString *flow = query[@"flow"];
    if (flow != nil) {
        if (![VLESS_FLOW_LIST containsObject:flow]) {
            [self warn:[NSString stringWithFormat:@"Unsupported or legacy VLESS flow '%@'; keeping default flow.", flow] context:context mayNotRun:NO];
        } else {
            profile.flow = searchInArray(flow, VLESS_FLOW_LIST);
        }
    }
}

+ (BOOL)applyTransportFields:(NSDictionary<NSString *, NSString *> *)query toProfile:(ServerProfile *)profile streamSettings:(NSMutableDictionary *)streamSettings context:(XrayShareLinkParserContext *)context error:(NSError **)error {
    NSString *type = query[@"type"];
    if (type.length == 0) {
        type = @"tcp";
    }
    if (context.mode != XrayShareLinkParseModeStrictStandard && [type isEqualToString:@"raw"]) {
        type = @"tcp";
    } else if (context.mode != XrayShareLinkParseModeStrictStandard && [type isEqualToString:@"mkcp"]) {
        type = @"kcp";
    } else if (context.mode != XrayShareLinkParseModeStrictStandard && [type isEqualToString:@"websocket"]) {
        type = @"ws";
    } else if (context.mode != XrayShareLinkParseModeStrictStandard && [type isEqualToString:@"splithttp"]) {
        type = @"xhttp";
    }

    NSUInteger networkIndex = searchInArray(type, NETWORK_LIST);
    if (![NETWORK_LIST containsObject:type]) {
        [self handleInvalidValue:[NSString stringWithFormat:@"Unsupported transport type '%@'.", type] code:XrayShareLinkParserErrorUnsupportedTransport context:context error:error];
        type = @"tcp";
        networkIndex = searchInArray(type, NETWORK_LIST);
    }
    profile.network = networkIndex;

    if ([type isEqualToString:@"http"] || [type isEqualToString:@"quic"]) {
        [self warn:[NSString stringWithFormat:@"Transport '%@' is removed in current Xray-core; imported for legacy compatibility.", type] context:context mayNotRun:YES];
    }

    if ([type isEqualToString:@"tcp"]) {
        [self applyTCPFields:query streamSettings:streamSettings];
    } else if ([type isEqualToString:@"kcp"]) {
        [self applyKCPFields:query streamSettings:streamSettings context:context];
    } else if ([type isEqualToString:@"ws"]) {
        [self applyWSFields:query streamSettings:streamSettings];
    } else if ([type isEqualToString:@"http"]) {
        [self applyHTTPFields:query streamSettings:streamSettings];
    } else if ([type isEqualToString:@"quic"]) {
        [self applyQUICFields:query streamSettings:streamSettings];
    } else if ([type isEqualToString:@"grpc"]) {
        [self applyGRPCFields:query streamSettings:streamSettings context:context];
    } else if ([type isEqualToString:@"httpupgrade"]) {
        [self applyHTTPUpgradeFields:query streamSettings:streamSettings];
    } else if ([type isEqualToString:@"xhttp"]) {
        [self applyXHTTPFields:query streamSettings:streamSettings context:context error:error];
    }
    return !(error != nil && *error != nil && context.mode == XrayShareLinkParseModeStrictStandard);
}

+ (void)applyTCPFields:(NSDictionary<NSString *, NSString *> *)query streamSettings:(NSMutableDictionary *)streamSettings {
    NSString *headerType = query[@"headerType"];
    if (headerType.length == 0) {
        headerType = @"none";
    }
    streamSettings[@"tcpSettings"][@"header"][@"type"] = headerType;
    if ([headerType isEqualToString:@"http"] && query[@"host"].length > 0) {
        streamSettings[@"tcpSettings"][@"header"][@"host"] = [self commaSeparatedArray:query[@"host"]];
    }
}

+ (void)applyKCPFields:(NSDictionary<NSString *, NSString *> *)query streamSettings:(NSMutableDictionary *)streamSettings context:(XrayShareLinkParserContext *)context {
    NSString *headerType = query[@"headerType"];
    if (headerType.length > 0) {
        streamSettings[@"kcpSettings"][@"header"][@"type"] = headerType;
        [self warn:@"mKCP headerType is removed in current Xray-core; imported for legacy compatibility." context:context mayNotRun:YES];
    }
    if (query[@"seed"].length > 0) {
        streamSettings[@"kcpSettings"][@"seed"] = query[@"seed"];
        [self warn:@"mKCP seed is removed in current Xray-core; imported for legacy compatibility." context:context mayNotRun:YES];
    }
    [self setUnsignedIntegerQuery:@"mtu" fromQuery:query into:streamSettings[@"kcpSettings"] key:@"mtu"];
    [self setUnsignedIntegerQuery:@"tti" fromQuery:query into:streamSettings[@"kcpSettings"] key:@"tti"];
}

+ (void)applyWSFields:(NSDictionary<NSString *, NSString *> *)query streamSettings:(NSMutableDictionary *)streamSettings {
    NSString *path = query[@"path"].length > 0 ? query[@"path"] : @"/";
    streamSettings[@"wsSettings"][@"path"] = path;
    if (query[@"host"].length > 0) {
        streamSettings[@"wsSettings"][@"host"] = query[@"host"];
        streamSettings[@"wsSettings"][@"headers"][@"Host"] = query[@"host"];
    }
}

+ (void)applyHTTPFields:(NSDictionary<NSString *, NSString *> *)query streamSettings:(NSMutableDictionary *)streamSettings {
    streamSettings[@"httpSettings"][@"path"] = query[@"path"].length > 0 ? query[@"path"] : @"/";
    if (query[@"host"].length > 0) {
        streamSettings[@"httpSettings"][@"host"] = [self commaSeparatedArray:query[@"host"]];
    }
}

+ (void)applyQUICFields:(NSDictionary<NSString *, NSString *> *)query streamSettings:(NSMutableDictionary *)streamSettings {
    NSString *headerType = query[@"headerType"].length > 0 ? query[@"headerType"] : @"none";
    NSString *security = query[@"quicSecurity"].length > 0 ? query[@"quicSecurity"] : @"none";
    streamSettings[@"quicSettings"][@"header"][@"type"] = headerType;
    streamSettings[@"quicSettings"][@"security"] = security;
    if (query[@"key"].length > 0) {
        streamSettings[@"quicSettings"][@"key"] = query[@"key"];
    }
}

+ (void)applyGRPCFields:(NSDictionary<NSString *, NSString *> *)query streamSettings:(NSMutableDictionary *)streamSettings context:(XrayShareLinkParserContext *)context {
    if (query[@"serviceName"].length > 0) {
        streamSettings[@"grpcSettings"][@"serviceName"] = query[@"serviceName"];
    }
    if (query[@"authority"].length > 0) {
        streamSettings[@"grpcSettings"][@"authority"] = query[@"authority"];
    }
    NSString *mode = query[@"mode"];
    if ([mode isEqualToString:@"multi"]) {
        streamSettings[@"grpcSettings"][@"multiMode"] = @YES;
    } else {
        streamSettings[@"grpcSettings"][@"multiMode"] = @NO;
        if ([mode isEqualToString:@"guna"]) {
            [self warn:@"gRPC mode 'guna' has no current Xray JSON field; imported as non-multi mode." context:context mayNotRun:NO];
        }
    }
}

+ (void)applyHTTPUpgradeFields:(NSDictionary<NSString *, NSString *> *)query streamSettings:(NSMutableDictionary *)streamSettings {
    NSMutableDictionary *settings = streamSettings[@"httpupgradeSettings"];
    if (settings == nil) {
        settings = [[NSMutableDictionary alloc] init];
        streamSettings[@"httpupgradeSettings"] = settings;
    }
    settings[@"path"] = query[@"path"].length > 0 ? query[@"path"] : @"/";
    if (query[@"host"].length > 0) {
        settings[@"host"] = query[@"host"];
    }
}

+ (void)applyXHTTPFields:(NSDictionary<NSString *, NSString *> *)query streamSettings:(NSMutableDictionary *)streamSettings context:(XrayShareLinkParserContext *)context error:(NSError **)error {
    NSMutableDictionary *settings = streamSettings[@"xhttpSettings"];
    if (settings == nil) {
        settings = [[NSMutableDictionary alloc] init];
        streamSettings[@"xhttpSettings"] = settings;
    }
    settings[@"path"] = query[@"path"].length > 0 ? query[@"path"] : @"/";
    if (query[@"host"].length > 0) {
        settings[@"host"] = query[@"host"];
    }
    if (query[@"mode"].length > 0) {
        settings[@"mode"] = query[@"mode"];
    }
    if (query[@"extra"].length > 0) {
        id extra = [self JSONObjectFromString:query[@"extra"]];
        if (extra != nil) {
            settings[@"extra"] = extra;
        } else {
            [self handleInvalidValue:@"XHTTP extra is not valid JSON; skipped." code:XrayShareLinkParserErrorInvalidQueryValue context:context error:error];
        }
    }
}

+ (BOOL)applySecurityFields:(NSDictionary<NSString *, NSString *> *)query toProfile:(ServerProfile *)profile streamSettings:(NSMutableDictionary *)streamSettings context:(XrayShareLinkParserContext *)context error:(NSError **)error {
    NSString *security = query[@"security"].length > 0 ? query[@"security"] : @"none";
    if (![TLS_SECURITY_LIST containsObject:security]) {
        [self handleInvalidValue:[NSString stringWithFormat:@"Unsupported transport security '%@'.", security] code:XrayShareLinkParserErrorUnsupportedSecurity context:context error:error];
        security = @"none";
    }
    if ([security isEqualToString:@"xtls"]) {
        [self warn:@"Legacy XTLS is removed in current Xray-core; imported for compatibility." context:context mayNotRun:YES];
    }
    streamSettings[@"security"] = security;

    NSString *settingsName = nil;
    if ([security isEqualToString:@"tls"]) {
        settingsName = @"tlsSettings";
    } else if ([security isEqualToString:@"xtls"]) {
        settingsName = @"xtlsSettings";
    } else if ([security isEqualToString:@"reality"]) {
        settingsName = @"realitySettings";
    }
    if (settingsName == nil) {
        return !(error != nil && *error != nil && context.mode == XrayShareLinkParseModeStrictStandard);
    }

    NSMutableDictionary *settings = streamSettings[settingsName];
    if (![settings isKindOfClass:[NSMutableDictionary class]]) {
        settings = [settings mutableDeepCopy] ?: [[NSMutableDictionary alloc] init];
        streamSettings[settingsName] = settings;
    }
    settings[@"serverName"] = query[@"sni"].length > 0 ? query[@"sni"] : profile.address;
    settings[@"fingerprint"] = query[@"fp"].length > 0 ? query[@"fp"] : @"chrome";
    if (query[@"alpn"].length > 0) {
        settings[@"alpn"] = [self commaSeparatedArray:query[@"alpn"]];
    }
    if (query[@"allowInsecure"].length > 0) {
        settings[@"allowInsecure"] = [self boolFromString:query[@"allowInsecure"]];
        [self warn:@"allowInsecure is removed by current Xray-core; imported for legacy compatibility." context:context mayNotRun:YES];
    }
    if (query[@"allowInsecureCiphers"].length > 0) {
        settings[@"allowInsecureCiphers"] = [self boolFromString:query[@"allowInsecureCiphers"]];
        [self warn:@"allowInsecureCiphers is not part of the current share-link standard." context:context mayNotRun:NO];
    }
    NSString *pcs = query[@"pcs"] ?: query[@"pinnedPeerCertSha256"];
    if (pcs.length > 0) {
        settings[@"pinnedPeerCertSha256"] = pcs;
    }
    NSString *vcn = query[@"vcn"] ?: query[@"verifyPeerCertByName"];
    if (vcn.length > 0) {
        settings[@"verifyPeerCertByName"] = vcn;
    }
    if (query[@"ech"].length > 0) {
        settings[@"echConfigList"] = query[@"ech"];
    }

    if ([security isEqualToString:@"reality"]) {
        NSString *pbk = query[@"pbk"];
        if (pbk.length > 0) {
            settings[@"password"] = pbk;
            settings[@"publicKey"] = pbk;
        }
        if (query[@"sid"] != nil) {
            settings[@"shortId"] = query[@"sid"];
        }
        if (query[@"pqv"] != nil) {
            settings[@"mldsa65Verify"] = query[@"pqv"];
        }
        if (query[@"spx"] != nil) {
            settings[@"spiderX"] = query[@"spx"];
        }
        NSString *flow = query[@"flow"];
        if ([flow isKindOfClass:[NSString class]]) {
            profile.flow = searchInArray(flow, VLESS_FLOW_LIST);
        }
    }
    return !(error != nil && *error != nil && context.mode == XrayShareLinkParseModeStrictStandard);
}

+ (void)applyFinalmaskFromQuery:(NSDictionary<NSString *, NSString *> *)query streamSettings:(NSMutableDictionary *)streamSettings context:(XrayShareLinkParserContext *)context error:(NSError **)error {
    NSString *fm = query[@"fm"];
    if (fm.length == 0) {
        return;
    }
    id finalmask = [self JSONObjectFromString:fm];
    if (finalmask != nil) {
        streamSettings[@"finalmask"] = finalmask;
    } else {
        [self handleInvalidValue:@"Finalmask fm is not valid JSON; skipped." code:XrayShareLinkParserErrorInvalidQueryValue context:context error:error];
    }
}

+ (NSArray<NSString *> *)commaSeparatedArray:(NSString *)value {
    NSMutableArray<NSString *> *parts = [[NSMutableArray alloc] init];
    for (NSString *part in [value componentsSeparatedByString:@","]) {
        NSString *trimmed = [part stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length > 0) {
            [parts addObject:trimmed];
        }
    }
    return parts;
}

+ (void)setUnsignedIntegerQuery:(NSString *)queryKey fromQuery:(NSDictionary<NSString *, NSString *> *)query into:(NSMutableDictionary *)dictionary key:(NSString *)key {
    NSString *value = query[queryKey];
    if (value.length == 0) {
        return;
    }
    NSInteger integer = value.integerValue;
    if (integer > 0) {
        dictionary[key] = @(integer);
    }
}

+ (NSNumber *)boolFromString:(NSString *)value {
    NSString *lowercase = [[value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    return @([lowercase isEqualToString:@"true"] || [lowercase isEqualToString:@"1"] || [lowercase isEqualToString:@"yes"]);
}

+ (id)JSONObjectFromString:(NSString *)string {
    NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
    if (data == nil) {
        return nil;
    }
    id object = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
    return object;
}

+ (BOOL)strictPositiveInteger:(NSString *)value {
    if (value.length == 0) {
        return NO;
    }
    NSCharacterSet *notDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    if ([value rangeOfCharacterFromSet:notDigits].location != NSNotFound) {
        return NO;
    }
    return value.integerValue > 0;
}

+ (BOOL)strictHexSha256List:(NSString *)value {
    NSCharacterSet *hexSet = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF:"];
    for (NSString *part in [value componentsSeparatedByString:@","]) {
        NSString *trimmed = [part stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *normalized = [trimmed stringByReplacingOccurrencesOfString:@":" withString:@""];
        if (normalized.length != 64 || [normalized rangeOfCharacterFromSet:[hexSet invertedSet]].location != NSNotFound) {
            return NO;
        }
    }
    return YES;
}

+ (BOOL)validateRequiredString:(NSString *)value name:(NSString *)name error:(NSError **)error {
    if (value.length > 0) {
        return YES;
    }
    [self assignError:error code:XrayShareLinkParserErrorMissingRequiredField reason:[NSString stringWithFormat:@"%@ is required.", name]];
    return NO;
}

+ (void)handleInvalidValue:(NSString *)reason code:(XrayShareLinkParserErrorCode)code context:(XrayShareLinkParserContext *)context error:(NSError **)error {
    if (context.mode == XrayShareLinkParseModeStrictStandard) {
        [self assignError:error code:code reason:reason];
        return;
    }
    [context.warnings addObject:reason];
    [self markLegacy:context];
}

+ (void)warn:(NSString *)warning context:(XrayShareLinkParserContext *)context mayNotRun:(BOOL)mayNotRun {
    [context.warnings addObject:warning];
    if (mayNotRun) {
        context.compatibility = XrayShareLinkCoreCompatibilityMayNotRun;
    } else {
        [self markLegacy:context];
    }
}

+ (void)markLegacy:(XrayShareLinkParserContext *)context {
    if (context.compatibility == XrayShareLinkCoreCompatibilityCurrent) {
        context.compatibility = XrayShareLinkCoreCompatibilityLegacy;
    }
}

+ (NSString *)trimmedString:(NSString *)string {
    if (![string isKindOfClass:[NSString class]]) {
        return @"";
    }
    return [string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

+ (void)assignError:(NSError **)error code:(XrayShareLinkParserErrorCode)code reason:(NSString *)reason {
    if (error == nil) {
        return;
    }
    *error = [NSError errorWithDomain:XrayShareLinkParserErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: reason ?: @"Invalid share link."}];
}

@end
