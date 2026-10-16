#import "MioObjCSafe.h"

@implementation MioObjCSafe
+ (nullable NSException *)tryBlock:(NS_NOESCAPE void (^)(void))block {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        return exception;
    }
}
@end
