//
//  worse_query.h
//  SuperKill
//
//  worse_query 沙盒逃逸原语的可用封装（面向 iOS 26.0 - 26.7.2 / 27.2）。
//  上游 PoC: https://github.com/forcequitOS/worse_query (GPL-3.0)
//
//  原理：把 App Group 容器里的 Library/Caches 换成指向目标路径的符号链接，
//  再让 containermanagerd 为该 group 的 "Library/Caches" part 签发 sandbox token。
//  containermanagerd 在签发前会解析符号链接，于是 token 实际覆盖的是目标路径，
//  进程 consume 之后即获得该任意路径（含 SystemGroup 系统组容器）的读写权限。
//

#ifndef worse_query_h
#define worse_query_h

#import <Foundation/Foundation.h>
#include <stdint.h>
#include <stdbool.h>

/// 取得 target 路径的 sandbox extension。
///
/// @param target     目标路径（目录或文件，必须已存在，除非 create_dir 为 true）
/// @param group      自己签名里带的 App Group identifier，例如 group.cc.team.superkill
/// @param create_dir 目标不存在时是否仍然签发
/// @param flags_used 可空；返回本次成功的 container_query flags
///
/// @return >0 扩展句柄（后续用 sk_escape_release 释放）
///         -1  App Group 不存在（签名未注入 entitlements，或 group 未在门户注册）
///         -2  符号解析失败（系统版本不受支持 / dylib 不在）
///         -3  container_query_create 失败
///         -4  符号链接创建失败
///         -5  containermanagerd 拒绝 query
///         -6  内核拒绝签发 / consume 失败
///         -255 目标路径不存在
int64_t sk_escape(NSString *target, NSString *group, bool create_dir, int64_t *flags_used);

/// 释放扩展。传入 <=0 时安全无操作。
void sk_escape_release(int64_t handle);

/// 该 group 在当前进程里是否存在可用的容器（用于自检）。
BOOL sk_has_app_group(NSString *group);

#endif /* worse_query_h */
