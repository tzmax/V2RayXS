//
//  utilities.m
//  V2RayX
//
//

#import "utilities.h"

static NSString* trimmedStringValue(id value) {
    if (![value isKindOfClass:[NSString class]]) {
        return @"";
    }
    return [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

NSUInteger searchInArray(NSString* str, NSArray* array) {
    if ([str isKindOfClass:[NSString class]]) {
        NSUInteger index = 0;
        for (NSString* s in array) {
            if ([s isKindOfClass:[NSString class]] && [s isEqualToString:str]) {
                return index;
            }
            index += 1;
        }
    }
    return 0;
}

NSMutableDictionary* normalizedStreamSettingsForXray(NSDictionary* streamSettings) {
    NSMutableDictionary* normalized = [streamSettings isKindOfClass:[NSDictionary class]] ? [streamSettings mutableDeepCopy] : [[NSMutableDictionary alloc] init];

    NSMutableDictionary* kcpSettings = [normalized[@"kcpSettings"] isKindOfClass:[NSDictionary class]] ? [normalized[@"kcpSettings"] mutableDeepCopy] : nil;
    if (kcpSettings != nil) {
        [kcpSettings removeObjectForKey:@"seed"];
        NSMutableDictionary* kcpHeader = [kcpSettings[@"header"] isKindOfClass:[NSDictionary class]] ? [kcpSettings[@"header"] mutableDeepCopy] : nil;
        NSString* headerType = [kcpHeader[@"type"] isKindOfClass:[NSString class]] ? kcpHeader[@"type"] : @"none";
        [kcpSettings removeObjectForKey:@"header"];
        kcpSettings[@"headerConfig"] = @{@"type": headerType.length > 0 ? headerType : @"none"};
        normalized[@"kcpSettings"] = kcpSettings;
    }

    return normalized;
}

NSMutableDictionary* normalizedStreamSettingsForXrayForCore(NSDictionary* streamSettings, BOOL rejectsTLSAllowInsecure) {
    NSMutableDictionary* normalized = normalizedStreamSettingsForXray(streamSettings);

    NSArray* tlsSettingNames = @[@"tlsSettings", @"xtlsSettings"];
    for (NSString* settingName in tlsSettingNames) {
        NSMutableDictionary* tlsSettings = [normalized[settingName] isKindOfClass:[NSDictionary class]] ? [normalized[settingName] mutableDeepCopy] : nil;
        if (tlsSettings != nil) {
            NSString* manualPin = trimmedStringValue(tlsSettings[@"pinnedPeerCertSha256"]);
            if (manualPin.length > 0) {
                tlsSettings[@"pinnedPeerCertSha256"] = manualPin;
            } else {
                [tlsSettings removeObjectForKey:@"pinnedPeerCertSha256"];
            }
            [tlsSettings removeObjectForKey:@"autoPinnedPeerCertSha256"];
            [tlsSettings removeObjectForKey:@"pinnedPeerCertSha256Source"];
            NSString* verifyPeerCertByName = trimmedStringValue(tlsSettings[@"verifyPeerCertByName"]);
            if (verifyPeerCertByName.length > 0) {
                tlsSettings[@"verifyPeerCertByName"] = verifyPeerCertByName;
            } else {
                [tlsSettings removeObjectForKey:@"verifyPeerCertByName"];
            }
            normalized[settingName] = tlsSettings;
        }
    }

    return normalized;
}
