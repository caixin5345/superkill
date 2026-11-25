#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把本地工程推到 GitHub、触发 Actions 构建，并把 ipa 拉回来。

只需要一个 GitHub token（classic: repo + workflow；fine-grained:
Administration / Contents / Actions / Workflows 全部 Read & Write）。

用法：
    python scripts/push_and_build.py --token ghp_xxx --repo superkill
    GITHUB_TOKEN=ghp_xxx python scripts/push_and_build.py --repo superkill --no-build

成功后：build/ipa/SuperKill-unsigned.ipa
"""

import argparse
import base64
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile

API = "https://api.github.com"
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))

SKIP_DIRS = {".git", "build", "__pycache__", "node_modules", ".idea", ".vscode"}
SKIP_EXT = {".ipa", ".zip", ".p12", ".mobileprovision", ".cer", ".pem", ".dSYM"}
SKIP_NAMES = {".DS_Store", "Thumbs.db"}


class AuthStrippingRedirect(urllib.request.HTTPRedirectHandler):
    """下载 artifact 时会 302 到 S3，跨域必须去掉 Authorization，否则签名冲突。"""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        new = super().redirect_request(req, fp, code, msg, headers, newurl)
        if new is not None:
            old_host = urllib.parse.urlsplit(req.full_url).netloc
            new_host = urllib.parse.urlsplit(newurl).netloc
            if old_host != new_host:
                new.remove_header("Authorization")
        return new


OPENER = urllib.request.build_opener(AuthStrippingRedirect)


def api(token, method, path, body=None, raw=False, timeout=60):
    url = path if path.startswith("http") else API + path
    data = None if body is None else json.dumps(body).encode("utf-8")
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", "Bearer " + token)
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("X-GitHub-Api-Version", "2022-11-28")
    req.add_header("User-Agent", "superkill-pusher")
    if data:
        req.add_header("Content-Type", "application/json")
    try:
        with OPENER.open(req, timeout=timeout) as resp:
            payload = resp.read()
            return resp.status, payload if raw else json.loads(payload or b"{}")
    except urllib.error.HTTPError as err:
        text = err.read().decode("utf-8", "replace")
        return err.code, text


def collect_files():
    out = []
    for dirpath, dirnames, filenames in os.walk(ROOT):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in filenames:
            if name in SKIP_NAMES:
                continue
            if os.path.splitext(name)[1] in SKIP_EXT:
                continue
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, ROOT).replace(os.sep, "/")
            out.append((rel, full))
    return sorted(out)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--token", default=os.environ.get("GITHUB_TOKEN", ""))
    parser.add_argument("--repo", default="superkill")
    parser.add_argument("--branch", default="main")
    parser.add_argument("--private", action="store_true", default=True)
    parser.add_argument("--public", dest="private", action="store_false")
    parser.add_argument("--no-build", action="store_true", help="只推送，不等待构建")
    args = parser.parse_args()

    if not args.token:
        print("[!] 需要 token：--token 或环境变量 GITHUB_TOKEN")
        return 1

    status, me = api(args.token, "GET", "/user")
    if status != 200:
        print("[!] token 无效：", status, me)
        return 1
    owner = me["login"]
    print("[*] 认证用户:", owner)

    status, repo = api(args.token, "GET", "/repos/%s/%s" % (owner, args.repo))
    if status == 200:
        print("[*] 仓库已存在:", repo["html_url"])
    else:
        status, repo = api(args.token, "POST", "/user/repos", {
            "name": args.repo,
            "private": args.private,
            "auto_init": False,
            "description": "SuperKill - supervision on/off via worse_query sandbox escape",
        })
        if status not in (200, 201):
            print("[!] 建仓失败：", status, repo)
            return 1
        print("[+] 仓库已创建:", repo["html_url"])

    files = collect_files()
    print("[*] 待上传 %d 个文件" % len(files))

    tree = []
    for rel, full in files:
        with open(full, "rb") as handle:
            blob = base64.b64encode(handle.read()).decode("ascii")
        status, res = api(args.token, "POST", "/repos/%s/%s/git/blobs" % (owner, args.repo), {
            "content": blob,
            "encoding": "base64",
        })
        if status not in (200, 201):
            print("[!] 上传失败 %s: %s %s" % (rel, status, res))
            return 1
        tree.append({"path": rel, "mode": "100644", "type": "blob", "sha": res["sha"]})
    print("[+] blobs 完成")

    status, res = api(args.token, "POST", "/repos/%s/%s/git/trees" % (owner, args.repo), {"tree": tree})
    if status not in (200, 201):
        print("[!] 创建 tree 失败：", status, res)
        return 1
    tree_sha = res["sha"]

    status, res = api(args.token, "POST", "/repos/%s/%s/git/commits" % (owner, args.repo), {
        "message": "SuperKill: supervision on/off + snapshot diff",
        "tree": tree_sha,
        "parents": [],
    })
    if status not in (200, 201):
        print("[!] 创建 commit 失败：", status, res)
        return 1
    commit_sha = res["sha"]
    print("[+] commit:", commit_sha[:10])

    status, res = api(args.token, "POST", "/repos/%s/%s/git/refs" % (owner, args.repo), {
        "ref": "refs/heads/" + args.branch,
        "sha": commit_sha,
    })
    if status not in (200, 201):
        status, res = api(args.token, "PATCH", "/repos/%s/%s/git/refs/heads/%s" % (owner, args.repo, args.branch), {
            "sha": commit_sha,
            "force": True,
        })
        if status not in (200, 201):
            print("[!] 更新分支失败：", status, res)
            return 1
    api(args.token, "PATCH", "/repos/%s/%s" % (owner, args.repo), {"default_branch": args.branch})
    print("[+] 已推送分支:", args.branch)

    if args.no_build:
        print("[*] 已跳过构建。到 %s/actions 手动 Run workflow 即可。" % repo["html_url"])
        return 0

    # workflow 注册有延迟，dispatch 重试
    dispatched = False
    for attempt in range(20):
        status, res = api(args.token, "POST",
                          "/repos/%s/%s/actions/workflows/build.yml/dispatches" % (owner, args.repo),
                          {"ref": args.branch})
        if status == 204:
            dispatched = True
            break
        if status in (403, 404, 422):
            time.sleep(3)
            continue
        print("[!] dispatch 失败：", status, res)
        break
    print("[*] 已触发 workflow" if dispatched else "[!] 未触发（push 事件可能已自动触发）")

    run = None
    deadline = time.time() + 600
    while time.time() < deadline:
        status, res = api(args.token, "GET",
                          "/repos/%s/%s/actions/runs?per_page=10" % (owner, args.repo))
        if status == 200:
            for item in res.get("workflow_runs", []):
                if item.get("head_sha") == commit_sha:
                    run = item
                    break
        if run:
            break
        time.sleep(5)

    if not run:
        print("[!] 没等到 run，去 %s/actions 看看" % repo["html_url"])
        return 1

    run_id = run["id"]
    print("[*] run: %s" % run["html_url"])
    while True:
        status, res = api(args.token, "GET", "/repos/%s/%s/actions/runs/%d" % (owner, args.repo, run_id))
        if status != 200:
            print("[!] 查询 run 失败：", status, res)
            return 1
        if res.get("status") == "completed":
            conclusion = res.get("conclusion")
            print("[*] 结果:", conclusion)
            if conclusion != "success":
                print("[!] 构建失败，日志：%s" % run["html_url"])
                return 1
            break
        time.sleep(10)

    status, res = api(args.token, "GET",
                      "/repos/%s/%s/actions/runs/%d/artifacts" % (owner, args.repo, run_id))
    artifacts = res.get("artifacts", []) if isinstance(res, dict) else []
    if not artifacts:
        print("[!] 没有 artifact")
        return 1

    artifact = artifacts[0]
    print("[*] artifact:", artifact["name"], artifact["size_in_bytes"], "bytes")
    status, blob = api(args.token, "GET", artifact["archive_download_url"], raw=True)
    if status != 200:
        print("[!] 下载失败：", status)
        return 1

    out_dir = os.path.join(ROOT, "build", "ipa")
    os.makedirs(out_dir, exist_ok=True)
    zip_path = os.path.join(ROOT, "build", "artifact.zip")
    with open(zip_path, "wb") as handle:
        handle.write(blob)
    with zipfile.ZipFile(zip_path) as archive:
        archive.extractall(out_dir)

    print("[+] 已解压到:", out_dir)
    for name in os.listdir(out_dir):
        if name.endswith(".ipa"):
            print("[+] IPA:", os.path.join(out_dir, name))
    return 0


if __name__ == "__main__":
    sys.exit(main())
