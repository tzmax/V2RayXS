//
//  TLSCertSha256.m
//  V2RayX
//

#import "TLSCertSha256.h"
#import <CommonCrypto/CommonDigest.h>

static NSString* TLSCertSha256TrimmedString(id value) {
    if (![value isKindOfClass:[NSString class]]) {
        return @"";
    }
    return [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSString* TLSCertSha256HexStringForData(NSData* data) {
    if (data.length == 0) {
        return @"";
    }
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, hash);
    NSMutableString* result = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [result appendFormat:@"%02x", hash[i]];
    }
    return result;
}

static NSData* TLSCertSha256FirstCertificatePEMData(NSData* sClientOutputData) {
    NSString* sClientOutput = [[NSString alloc] initWithData:sClientOutputData encoding:NSUTF8StringEncoding];
    if (sClientOutput.length == 0) {
        return nil;
    }

    NSString* beginMarker = @"-----BEGIN CERTIFICATE-----";
    NSString* endMarker = @"-----END CERTIFICATE-----";
    NSRange beginRange = [sClientOutput rangeOfString:beginMarker];
    if (beginRange.location == NSNotFound) {
        return nil;
    }

    NSRange searchRange = NSMakeRange(NSMaxRange(beginRange), sClientOutput.length - NSMaxRange(beginRange));
    NSRange endRange = [sClientOutput rangeOfString:endMarker options:0 range:searchRange];
    if (endRange.location == NSNotFound) {
        return nil;
    }

    NSUInteger certificateEnd = NSMaxRange(endRange);
    NSString* certificatePEM = [sClientOutput substringWithRange:NSMakeRange(beginRange.location, certificateEnd - beginRange.location)];
    certificatePEM = [certificatePEM stringByAppendingString:@"\n"];
    return [certificatePEM dataUsingEncoding:NSUTF8StringEncoding];
}

static BOOL TLSCertSha256RunTask(NSString* launchPath,
                                NSArray<NSString*>* arguments,
                                NSData* stdinData,
                                NSTimeInterval timeout,
                                NSData** stdoutData,
                                NSString** stderrString,
                                int* terminationStatus,
                                NSString** errorMessage) {
    NSTask* task = [[NSTask alloc] init];
    NSPipe* stdoutPipe = [NSPipe pipe];
    NSPipe* stderrPipe = [NSPipe pipe];
    NSPipe* stdinPipe = stdinData != nil ? [NSPipe pipe] : nil;
    task.launchPath = launchPath;
    task.arguments = arguments ?: @[];
    task.standardOutput = stdoutPipe;
    task.standardError = stderrPipe;
    task.standardInput = stdinPipe != nil ? stdinPipe : [NSFileHandle fileHandleWithNullDevice];

    @try {
        [task launch];
    } @catch (NSException* exception) {
        if (errorMessage != NULL) {
            *errorMessage = exception.reason ?: @"failed to launch task";
        }
        return NO;
    }

    if (stdinPipe != nil) {
        @try {
            [[stdinPipe fileHandleForWriting] writeData:stdinData];
            [[stdinPipe fileHandleForWriting] closeFile];
        } @catch (NSException* exception) {
            ;
        }
    }

    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @try {
            [task waitUntilExit];
        } @catch (NSException* exception) {
            ;
        }
        dispatch_semaphore_signal(sema);
    });

    if (dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC))) != 0) {
        @try {
            [task terminate];
        } @catch (NSException* exception) {
            ;
        }
        if (errorMessage != NULL) {
            *errorMessage = @"task timed out";
        }
        return NO;
    }

    @try {
        if (stdoutData != NULL) {
            *stdoutData = [[stdoutPipe fileHandleForReading] readDataToEndOfFile];
        }
        NSData* stderrData = [[stderrPipe fileHandleForReading] readDataToEndOfFile];
        if (stderrString != NULL) {
            *stderrString = [[NSString alloc] initWithData:stderrData encoding:NSUTF8StringEncoding] ?: @"";
        }
        if (terminationStatus != NULL) {
            *terminationStatus = task.terminationStatus;
        }
    } @catch (NSException* exception) {
        if (errorMessage != NULL) {
            *errorMessage = exception.reason ?: @"failed to read task output";
        }
        return NO;
    }
    return YES;
}

@implementation TLSCertSha256Endpoint

- (instancetype)init {
    self = [super init];
    if (self) {
        _host = @"";
        _serverName = @"";
        _security = @"";
        _outboundTag = @"";
    }
    return self;
}

- (id)copyWithZone:(NSZone*)zone {
    TLSCertSha256Endpoint* endpoint = [[[self class] allocWithZone:zone] init];
    endpoint.host = self.host;
    endpoint.port = self.port;
    endpoint.serverName = self.serverName;
    endpoint.security = self.security;
    endpoint.outboundTag = self.outboundTag;
    return endpoint;
}

- (NSString*)cacheKey {
    NSString* host = TLSCertSha256TrimmedString(self.host);
    NSString* serverName = TLSCertSha256TrimmedString(self.serverName);
    if (serverName.length == 0) {
        serverName = host;
    }
    return [NSString stringWithFormat:@"%@|%@|%lu|%@",
            [TLSCertSha256TrimmedString(self.security) lowercaseString],
            host,
            (unsigned long)self.port,
            serverName];
}

- (NSString*)displayAddress {
    return [NSString stringWithFormat:@"%@:%lu", TLSCertSha256TrimmedString(self.host), (unsigned long)self.port];
}

@end

@implementation TLSCertSha256CacheEntry

- (instancetype)init {
    self = [super init];
    if (self) {
        _sha256 = @"";
        _errorMessage = @"";
        _endpoint = [[TLSCertSha256Endpoint alloc] init];
    }
    return self;
}

- (BOOL)hasSha256 {
    return TLSCertSha256TrimmedString(self.sha256).length > 0;
}

@end

@interface TLSCertSha256 ()
@property (nonatomic, strong) NSMutableDictionary<NSString*, TLSCertSha256CacheEntry*>* entries;
@property (nonatomic, strong) dispatch_queue_t queue;
@end

@implementation TLSCertSha256

+ (instancetype)sharedCache {
    static TLSCertSha256* sharedCache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedCache = [[TLSCertSha256 alloc] init];
    });
    return sharedCache;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _entries = [[NSMutableDictionary alloc] init];
        _queue = dispatch_queue_create("cenmrev.v2rayxs.tls-cert-sha256", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (TLSCertSha256CacheEntry*)cachedEntryForEndpoint:(TLSCertSha256Endpoint*)endpoint {
    if (endpoint == nil) {
        return nil;
    }
    __block TLSCertSha256CacheEntry* entry = nil;
    dispatch_sync(self.queue, ^{
        entry = self.entries[[endpoint cacheKey]];
    });
    return entry;
}

- (TLSCertSha256CacheEntry*)fetchForEndpoint:(TLSCertSha256Endpoint*)endpoint refresh:(BOOL)refresh {
    TLSCertSha256Endpoint* endpointCopy = [endpoint copy];
    if (endpointCopy == nil) {
        NSLog(@"TLSCertSha256 fetch skipped: missing endpoint");
        TLSCertSha256CacheEntry* entry = [[TLSCertSha256CacheEntry alloc] init];
        entry.errorMessage = @"missing TLS certificate endpoint";
        entry.fetchedAt = [NSDate date];
        return entry;
    }

    NSLog(@"TLSCertSha256 fetch requested refresh=%@ endpoint=%@ key=%@", refresh ? @"YES" : @"NO", [endpointCopy displayAddress], [endpointCopy cacheKey]);

    NSString* cacheKey = [endpointCopy cacheKey];
    if (!refresh) {
        TLSCertSha256CacheEntry* cachedEntry = [self cachedEntryForEndpoint:endpointCopy];
        if (cachedEntry != nil) {
            NSLog(@"TLSCertSha256 cache hit endpoint=%@ hasSha256=%@ error=%@", [endpointCopy displayAddress], [cachedEntry hasSha256] ? @"YES" : @"NO", cachedEntry.errorMessage ?: @"");
            return cachedEntry;
        }
    }

    TLSCertSha256CacheEntry* entry = [self fetchUncachedForEndpoint:endpointCopy];
    dispatch_sync(self.queue, ^{
        self.entries[cacheKey] = entry;
    });
    return entry;
}

- (void)fetchForEndpoint:(TLSCertSha256Endpoint*)endpoint refresh:(BOOL)refresh completion:(void (^)(TLSCertSha256CacheEntry* entry))completion {
    TLSCertSha256Endpoint* endpointCopy = [endpoint copy];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        TLSCertSha256CacheEntry* entry = [self fetchForEndpoint:endpointCopy refresh:refresh];
        if (completion != nil) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(entry);
            });
        }
    });
}

- (void)clearCacheForEndpoint:(TLSCertSha256Endpoint*)endpoint {
    if (endpoint == nil) {
        return;
    }
    NSString* cacheKey = [endpoint cacheKey];
    dispatch_sync(self.queue, ^{
        [self.entries removeObjectForKey:cacheKey];
    });
}

- (void)clearAllCache {
    dispatch_sync(self.queue, ^{
        [self.entries removeAllObjects];
    });
}

- (TLSCertSha256CacheEntry*)fetchUncachedForEndpoint:(TLSCertSha256Endpoint*)endpoint {
    TLSCertSha256CacheEntry* entry = [[TLSCertSha256CacheEntry alloc] init];
    entry.endpoint = [endpoint copy];
    entry.fetchedAt = [NSDate date];

    NSString* trimmedHost = TLSCertSha256TrimmedString(endpoint.host);
    NSString* trimmedServerName = TLSCertSha256TrimmedString(endpoint.serverName);
    if (trimmedServerName.length == 0) {
        trimmedServerName = trimmedHost;
    }
    if (trimmedHost.length == 0 || endpoint.port == 0) {
        entry.errorMessage = @"missing host or port";
        NSLog(@"TLSCertSha256 fetch failed before launch: %@", entry.errorMessage);
        return entry;
    }

    NSString* connectTarget = [NSString stringWithFormat:@"%@:%lu", trimmedHost, (unsigned long)endpoint.port];
    NSLog(@"TLSCertSha256 launching openssl connect=%@ sni=%@", connectTarget, trimmedServerName);

    NSData* certificatePEMData = nil;
    NSString* sClientStderr = @"";
    NSString* taskError = @"";
    int sClientStatus = -1;
    BOOL sClientOK = TLSCertSha256RunTask(@"/usr/bin/openssl",
                                          @[@"s_client", @"-connect", connectTarget, @"-servername", trimmedServerName, @"-showcerts"],
                                          nil,
                                          10,
                                          &certificatePEMData,
                                          &sClientStderr,
                                          &sClientStatus,
                                          &taskError);
    if (!sClientOK) {
        entry.errorMessage = taskError.length > 0 ? taskError : @"certificate fetch timed out";
        NSLog(@"TLSCertSha256 s_client failed endpoint=%@ error=%@", connectTarget, entry.errorMessage);
        return entry;
    }

    NSData* leafCertificatePEMData = TLSCertSha256FirstCertificatePEMData(certificatePEMData);
    if (leafCertificatePEMData.length == 0) {
        NSString* errorMessage = TLSCertSha256TrimmedString(sClientStderr);
        entry.errorMessage = errorMessage.length > 0 ? errorMessage : @"failed to find peer certificate in openssl output";
        NSLog(@"TLSCertSha256 no certificate found endpoint=%@ s_client_status=%d error=%@", connectTarget, sClientStatus, entry.errorMessage);
        return entry;
    }

    NSData* certificateDERData = nil;
    NSString* x509Stderr = @"";
    int x509Status = -1;
    BOOL x509OK = TLSCertSha256RunTask(@"/usr/bin/openssl",
                                       @[@"x509", @"-outform", @"DER"],
                                       leafCertificatePEMData,
                                       10,
                                       &certificateDERData,
                                       &x509Stderr,
                                       &x509Status,
                                       &taskError);
    if (!x509OK || x509Status != 0 || certificateDERData.length == 0) {
        NSString* errorMessage = TLSCertSha256TrimmedString(x509Stderr);
        entry.errorMessage = errorMessage.length > 0 ? errorMessage : (taskError.length > 0 ? taskError : @"failed to read peer certificate");
        NSLog(@"TLSCertSha256 x509 failed endpoint=%@ status=%d error=%@", connectTarget, x509Status, entry.errorMessage);
        return entry;
    }

    NSString* pin = TLSCertSha256HexStringForData(certificateDERData);
    if (pin.length == 64) {
        entry.sha256 = pin;
        NSLog(@"TLSCertSha256 fetch succeeded endpoint=%@ sha256=%@", connectTarget, entry.sha256);
        return entry;
    }

    NSString* errorMessage = TLSCertSha256TrimmedString(sClientStderr);
    entry.errorMessage = errorMessage.length > 0 ? errorMessage : @"failed to calculate peer certificate sha256";
    NSLog(@"TLSCertSha256 fetch failed endpoint=%@ s_client_status=%d error=%@", connectTarget, sClientStatus, entry.errorMessage);
    return entry;
}

+ (NSString*)shortSha256:(NSString*)sha256 {
    NSString* trimmed = TLSCertSha256TrimmedString(sha256);
    if (trimmed.length <= 24) {
        return trimmed;
    }
    return [NSString stringWithFormat:@"%@...%@", [trimmed substringToIndex:12], [trimmed substringFromIndex:trimmed.length - 12]];
}

+ (NSString*)placeholderForSha256:(NSString*)sha256 {
    NSString* shortSha256 = [self shortSha256:sha256];
    return shortSha256.length > 0 ? [NSString stringWithFormat:@"%@", shortSha256] : @"";
}

+ (NSString*)statusTextForEntry:(TLSCertSha256CacheEntry*)entry {
    if (entry == nil || ![entry hasSha256]) {
        return @"";
    }
    TLSCertSha256Endpoint* endpoint = entry.endpoint;
    NSString* serverName = TLSCertSha256TrimmedString(endpoint.serverName);
    if (serverName.length == 0) {
        serverName = TLSCertSha256TrimmedString(endpoint.host);
    }
    return [NSString stringWithFormat:@"Auto Pin fetched from %@ with SNI %@:\n%@", [endpoint displayAddress], serverName, entry.sha256];
}

@end
