// MioObjCSafe.h — 在 ObjC 里执行一段代码并接住 NSException（Swift 的 do/catch 接不住 ObjC 异常）。
// 用于启动期的非关键系统调用（如 BGTaskScheduler.register），失败时降级而不是让 App 闪退。
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface MioObjCSafe : NSObject
/// 执行 block；抛出 NSException 时返回该异常（不再向上抛），否则返回 nil。
+ (nullable NSException *)tryBlock:(NS_NOESCAPE void (^)(void))block NS_SWIFT_NAME(catching(_:));
@end

NS_ASSUME_NONNULL_END
