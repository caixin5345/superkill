//
//  SKEngine.h
//  SuperKill
//
//  监管（Supervision）状态读取与清除引擎。
//  通过 worse_query 取得 systemgroup.com.apple.configurationprofiles 的读写权限，
//  然后删除监管与 MDM 的落盘状态。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^SKLogBlock)(NSString *line);

/// 监管与 MDM 状态的系统级落盘位置
extern NSString *const SKConfigurationProfilesRoot;
extern NSString *const SKDeviceManagementRoot;
extern NSString *const SKUserProfilesRoot;

@interface SKEngine : NSObject

/// 日志回调，可能在任意线程被调用，UI 层自行切主线程
@property (nonatomic, copy, nullable) SKLogBlock logger;

/// 当前使用的 App Group（默认从签名 entitlements 自动读取）
@property (nonatomic, readwrite, copy) NSString *appGroup;

+ (NSString *)configuredAppGroup;
+ (void)setConfiguredAppGroup:(NSString *)group;

/// 自检：系统版本、App Group、扩展可用性、当前监管状态
- (NSString *)environmentReport;

/// 彻底清除监管 + MDM 落盘状态
- (BOOL)wipeSupervision:(BOOL)aggressive error:(NSError **)error;

/// 释放所有已 consume 的扩展
- (void)releaseAllExtensions;

@end

NS_ASSUME_NONNULL_END
