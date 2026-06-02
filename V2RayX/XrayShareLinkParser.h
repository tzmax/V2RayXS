//
//  XrayShareLinkParser.h
//  V2RayX
//

#import <Foundation/Foundation.h>
#import "ServerProfile.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const XrayShareLinkParserErrorDomain;

typedef NS_ENUM(NSInteger, XrayShareLinkParseMode) {
    XrayShareLinkParseModeCompatible,
    XrayShareLinkParseModeStrictStandard,
};

typedef NS_ENUM(NSInteger, XrayShareLinkCoreCompatibility) {
    XrayShareLinkCoreCompatibilityCurrent,
    XrayShareLinkCoreCompatibilityLegacy,
    XrayShareLinkCoreCompatibilityMayNotRun,
};

typedef NS_ENUM(NSInteger, XrayShareLinkParserErrorCode) {
    XrayShareLinkParserErrorInvalidURL = 1,
    XrayShareLinkParserErrorUnsupportedProtocol,
    XrayShareLinkParserErrorMissingRequiredField,
    XrayShareLinkParserErrorDuplicateQueryItem,
    XrayShareLinkParserErrorInvalidQueryValue,
    XrayShareLinkParserErrorUnsupportedTransport,
    XrayShareLinkParserErrorUnsupportedSecurity,
    XrayShareLinkParserErrorUnsupportedEncryption,
};

@interface XrayShareLinkParseResult : NSObject

@property (nonatomic, strong, readonly) ServerProfile *profile;
@property (nonatomic, copy, readonly) NSArray<NSString *> *warnings;
@property (nonatomic, copy, readonly) NSDictionary<NSString *, NSString *> *rawQuery;
@property (nonatomic, readonly) XrayShareLinkCoreCompatibility coreCompatibility;

- (instancetype)initWithProfile:(ServerProfile *)profile
                       warnings:(NSArray<NSString *> *)warnings
                       rawQuery:(NSDictionary<NSString *, NSString *> *)rawQuery
              coreCompatibility:(XrayShareLinkCoreCompatibility)coreCompatibility NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

@interface XrayShareLinkParser : NSObject

+ (BOOL)canParseLink:(NSString *)link;
+ (nullable XrayShareLinkParseResult *)parseLink:(NSString *)link error:(NSError **)error;
+ (nullable XrayShareLinkParseResult *)parseLink:(NSString *)link
                                            mode:(XrayShareLinkParseMode)mode
                                           error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
