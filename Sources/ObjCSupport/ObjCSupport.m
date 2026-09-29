#import "ObjCSupport.h"

BOOL kmk_tryCatch(void (NS_NOESCAPE ^block)(void)) {
    @try {
        block();
        return YES;
    } @catch (NSException *e) {
        NSLog(@"[KMK] nuốt NSException khi vẽ: %@ — %@", e.name, e.reason ?: @"(no reason)");
        return NO;
    }
}
