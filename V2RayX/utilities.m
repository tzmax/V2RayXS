//
//  utilities.m
//  V2RayX
//
//

#import "utilities.h"

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
