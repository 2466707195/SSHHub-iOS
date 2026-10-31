#!/usr/bin/env python3
"""SSHHub 发布器：推代码 -> 触发 GitHub Actions -> 轮询 -> 下载 ipa"""
import base64, json, os, subprocess, sys, time, zipfile, io
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # 仓库根 = scripts/ 的上一级
EXCLUDE_DIRS = {"build", "DerivedData", ".git", "SSHHub.xcodeproj"}
EXCLUDE_FILES = {"Info.plist"}

def gh_token():
    t = os.environ.get("GITHUB_TOKEN")
    if t and t.strip():
        return t.strip()
    return subprocess.check_output(["gh", "auth", "token"], text=True).strip()

TOKEN = gh_token()
API = "https://api.github.com"
OWNER = "2466707195"
REPO = "SSHHub-iOS"
BASE = f"{API}/repos/{OWNER}/{REPO}"

def req(method, url, payload=None, raw=False):
    data = None
    headers = {
        "Authorization": f"Bearer {TOKEN}",
        "Accept": "application/vnd.github+json",
        "User-Agent": "sshhub-publisher",
    }
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
    r = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(r) as resp:
            body = resp.read()
            return json.loads(body) if body and not raw else (body, resp.status)
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")
        raise RuntimeError(f"{method} {url} -> {e.code}: {detail[:400]}")

def collect_files():
    out = []
    for dirpath, dirnames, filenames in os.walk(ROOT):
        rel_dir = os.path.relpath(dirpath, ROOT)
        parts = set(rel_dir.replace("\\", "/").split("/"))
        if parts & EXCLUDE_DIRS:
            dirnames[:] = []
            continue
        for fn in filenames:
            if fn in EXCLUDE_FILES or fn.endswith((".ipa", ".zip")):
                continue
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, ROOT).replace("\\", "/")
            out.append((rel, full))
    return sorted(out)

def push():
    files = collect_files()
    print(f"[1/4] 收集到 {len(files)} 个文件")

    tree_entries = []
    for i, (rel, full) in enumerate(files):
        with open(full, "rb") as f:
            content = f.read()
        # 工作流文件用 utf-8 文本，其他全部 base64
        blob = req("POST", f"{BASE}/git/blobs",
                   {"content": base64.b64encode(content).decode(), "encoding": "base64"})
        tree_entries.append({"path": rel, "mode": "100644", "type": "blob", "sha": blob["sha"]})
        print(f"  blob [{i+1}/{len(files)}] {rel}")
        time.sleep(0.15)

    ref = req("GET", f"{BASE}/git/ref/heads/main")
    head = ref["object"]["sha"]
    print(f"[2/4] HEAD = {head}")

    tree = req("POST", f"{BASE}/git/trees", {"tree": tree_entries})
    print(f"[3/4] tree = {tree['sha']}")

    commit = req("POST", f"{BASE}/git/commits", {
        "message": "chore: sync SSHHub project",
        "tree": tree["sha"],
        "parents": [head],
    })
    print(f"      commit = {commit['sha'][:10]}")

    req("PATCH", f"{BASE}/git/refs/heads/main", {"sha": commit["sha"], "force": False})
    print(f"[4/4] 已推送到 main")

def dispatch():
    # workflow 刚推上去时 GitHub 索引需要几秒，做重试
    last = None
    for i in range(12):
        try:
            req("POST", f"{BASE}/actions/workflows/ios-build.yml/dispatches", {"ref": "main"})
            print("已触发 workflow_dispatch")
            return
        except RuntimeError as e:
            last = e
            print(f"  dispatch 第 {i+1} 次失败，等 10s 重试...")
            time.sleep(10)
    print(f"\n!!! dispatch 一直 404。请到仓库 Actions 页手动 Run workflow: {BASE.rsplit('/',1)[-1]}")
    print(f"    详细错误: {last}")
    sys.exit(3)

def wait_build():
    print("等待构建启动（macOS runner 排队可能需要几分钟）...")
    run_id = None
    for _ in range(40):
        time.sleep(5)
        runs = req("GET", f"{BASE}/actions/runs?branch=main&per_page=5")
        for r in runs.get("workflow_runs", []):
            if "ios-build" in r.get("path", ""):
                run_id = r["id"]
                break
        if run_id:
            break
    if not run_id:
        raise RuntimeError("找不到 workflow run")
    print(f"run id = {run_id}")
    for i in range(120):
        time.sleep(10)
        run = req("GET", f"{BASE}/actions/runs/{run_id}")
        print(f"  [{i}] {run['status']} / {run['conclusion']}")
        if run["status"] == "completed":
            if run["conclusion"] == "success":
                return run_id
            raise RuntimeError(f"构建失败: {run['conclusion']}  日志: {run['html_url']}")
    raise RuntimeError("轮询超时")

def download_artifact(run_id):
    arts = req("GET", f"{BASE}/actions/runs/{run_id}/artifacts")
    if arts["total_count"] < 1:
        raise RuntimeError("没有 artifact")
    art = arts["artifacts"][0]
    print(f"artifact: {art['name']} ({art['size_in_bytes']//1024} KB)")
    url = f"{BASE}/actions/artifacts/{art['id']}/zip"
    r = urllib.request.Request(url, headers={"Authorization": f"Bearer {TOKEN}", "User-Agent": "sshhub-publisher"})
    with urllib.request.urlopen(r) as resp:
        data = resp.read()
    out_dir = os.path.join(ROOT, "build")
    os.makedirs(out_dir, exist_ok=True)
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        z.extractall(out_dir)
    for f in os.listdir(out_dir):
        print("  产物:", f)

if __name__ == "__main__":
    try:
        push()
    except RuntimeError as e:
        msg = str(e)
        print(f"\n!!! 推送失败: {msg[:300]}")
        if "workflow" in msg.lower() and ("422" in msg or "403" in msg):
            print(">>> 原因：GitHub token 缺少 workflow 权限。请在终端运行: gh auth refresh -s workflow")
        sys.exit(1)
    dispatch()
    run_id = wait_build()
    download_artifact(run_id)
    print("\n全部完成。")
