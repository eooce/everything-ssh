#!/usr/bin/env python3


import os
import sys
import platform
import subprocess
import urllib.request
import tarfile
import zipfile
import time
import tempfile
import shutil
import atexit
import re
from pathlib import Path

# ---------- 环境变量配置（可选） ----------
ARGO_DOMAIN = os.environ.get("ARGO_DOMAIN") or ""     # 固定隧道域名,留空使用临时隧道
ARGO_AUTH   = os.environ.get("ARGO_AUTH") or ""       # 隧道token
GOTTY_PORT  = os.environ.get("GOTTY_PORT") or "8080"  # gotty 端口

# ========== 固定配置 ==========
GOTTY_VERSION = "v1.8.0"
CLOUDFLARED_VERSION = "2025.8.0"   # 备用版本
GOTTY_COMMAND = ["bash"]           # gotty 执行的命令

# ========== 全局临时目录追踪 ==========
_temp_dirs = []   # 存储所有需要清理的临时目录路径

def register_temp_dir(path):
    """注册一个临时目录，程序退出时自动删除"""
    _temp_dirs.append(path)

def cleanup_temp_dirs():
    """清理所有已注册的临时目录"""
    for path in _temp_dirs:
        try:
            if os.path.exists(path):
                shutil.rmtree(path)
                print(f"🧹 已清理临时目录: {path}")
        except Exception as e:
            print(f"⚠️  清理 {path} 失败: {e}")

# 注册退出清理
atexit.register(cleanup_temp_dirs)

# ========== 工具函数 ==========

def get_system_info():
    system = platform.system().lower()
    machine = platform.machine().lower()
    arch_map = {
        "x86_64": "amd64", "amd64": "amd64",
        "aarch64": "arm64", "arm64": "arm64",
        "armv7l": "armv7", "armv6l": "armv6",
    }
    arch = arch_map.get(machine, machine)
    if system == "windows":
        return "windows", arch, ".exe", "windows"
    elif system == "darwin":
        return "darwin", arch, "", "darwin"
    else:
        return "linux", arch, "", "linux"


def download_file(url, dest_path, name="文件"):
    print(f"⬇️  下载 {name}...", end="", flush=True)
    urllib.request.urlretrieve(url, dest_path)
    print(" ✅ 完成")


def extract_archive(archive_path, extract_to, name="压缩包"):
    if archive_path.endswith(".tar.gz"):
        with tarfile.open(archive_path, "r:gz") as tar:
            # 兼容 Python 3.14+ 的 filter 参数
            try:
                tar.extractall(path=extract_to, filter='data')
            except TypeError:
                tar.extractall(path=extract_to)
    elif archive_path.endswith(".zip"):
        with zipfile.ZipFile(archive_path, "r") as zf:
            zf.extractall(extract_to)
    else:
        raise ValueError(f"未知格式: {archive_path}")
    print(f"📦 解压 {name} 完成")


def find_executable(extract_dir, name):
    for root, _, files in os.walk(extract_dir):
        for f in files:
            if f == name or f == name + ".exe":
                return os.path.join(root, f)
    return None


# ========== 下载和安装 ==========

def setup_gotty():
    os_name, arch, _, _ = get_system_info()
    if os_name == "windows":
        filename = f"gotty_{GOTTY_VERSION}_{os_name}_{arch}.zip"
    else:
        filename = f"gotty_{GOTTY_VERSION}_{os_name}_{arch}.tar.gz"
    url = f"https://github.com/sorenisanerd/gotty/releases/download/{GOTTY_VERSION}/{filename}"

    tmp_dir = tempfile.mkdtemp(prefix="gotty_")
    register_temp_dir(tmp_dir)   # 注册清理
    archive_path = os.path.join(tmp_dir, filename)

    try:
        download_file(url, archive_path, "gotty")
    except Exception as e:
        print(f" ❌ 下载失败: {e}")
        sys.exit(1)

    extract_archive(archive_path, tmp_dir, "gotty")
    gotty_path = find_executable(tmp_dir, "gotty")
    if not gotty_path:
        print("❌ 未找到 gotty 可执行文件")
        sys.exit(1)
    if os_name != "windows":
        os.chmod(gotty_path, 0o755)
    return gotty_path


def setup_cloudflared():
    os_name, arch, _, download_name = get_system_info()
    if os_name == "windows":
        filename = f"cloudflared-{download_name}-{arch}.exe"
    else:
        filename = f"cloudflared-{download_name}-{arch}"

    url = f"https://github.com/cloudflare/cloudflared/releases/latest/download/{filename}"
    tmp_dir = tempfile.mkdtemp(prefix="cloudflared_")
    register_temp_dir(tmp_dir)   # 注册清理
    dest_path = os.path.join(tmp_dir, filename)

    try:
        download_file(url, dest_path, "cloudflared")
    except Exception:
        print("   最新版下载失败，尝试备用版本...")
        url_v = f"https://github.com/cloudflare/cloudflared/releases/download/{CLOUDFLARED_VERSION}/{filename}"
        try:
            download_file(url_v, dest_path, "cloudflared")
        except Exception as e:
            print(f" ❌ 下载失败: {e}")
            sys.exit(1)

    if os_name != "windows":
        os.chmod(dest_path, 0o755)
    return dest_path


# ========== 启动服务 ==========

def run_gotty(gotty_path):
    cmd = [gotty_path, "-p", GOTTY_PORT] + GOTTY_COMMAND
    print(f"🚀 启动 gotty (端口 {GOTTY_PORT})")
    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        stdin=subprocess.DEVNULL,
    )
    proc._gotty_path = gotty_path
    return proc

def run_cloudflared(cloudflared_path):
    log_dir = tempfile.mkdtemp(prefix="cf_log_")
    register_temp_dir(log_dir)
    log_file = os.path.join(log_dir, "cloudflared.log")

    cmd = [
        cloudflared_path,
        "tunnel",
        "--edge-ip-version", "auto",
        "--no-autoupdate",
        "--protocol", "http2",
        "--logfile", log_file,
        "--loglevel", "info",
    ]

    if ARGO_DOMAIN and ARGO_AUTH:
        # 固定隧道：使用 run 子命令，仅提供 token
        cmd.append("run")
        cmd.extend(["--token", ARGO_AUTH])
        print(f"🚀 启动 cloudflared（固定隧道: {ARGO_DOMAIN}）")
    else:
        # 临时隧道：使用 tunnel 子命令，指定 url
        cmd.append("--url")
        cmd.append(f"http://localhost:{GOTTY_PORT}")
        print("🚀 启动 cloudflared（临时隧道）")

    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        stdin=subprocess.DEVNULL,
    )
    proc._cloudflared_path = cloudflared_path
    proc._log_file = log_file
    return proc

def get_tunnel_url(proc, is_fixed):
    if is_fixed:
        return f"https://{ARGO_DOMAIN}"

    log_file = proc._log_file
    for _ in range(10):
        if os.path.exists(log_file):
            with open(log_file, "r") as f:
                content = f.read()
                match = re.search(r'https://[a-zA-Z0-9\-]+\.trycloudflare\.com', content)
                if match:
                    return match.group(0)
        time.sleep(1)
    return None


def print_tunnel_info(proc, is_fixed):
    if is_fixed:
        print(f"🔗 固定隧道域名: https://{ARGO_DOMAIN}")
        print("   ⚠️  请确保域名已在 Cloudflare 配置并解析")
    else:
        url = get_tunnel_url(proc, is_fixed)
        if url:
            print(f"🔗 临时隧道域名: {url}")
        else:
            print("⏳ 临时隧道域名获取超时，请检查日志")


def monitor_processes(procs):
    while True:
        for name, proc in list(procs.items()):
            if proc.poll() is not None:
                print(f"⚠️  {name} 已退出 (code: {proc.returncode})，正在重启...")
                if name == "gotty":
                    new_proc = run_gotty(proc._gotty_path)
                elif name == "cloudflared":
                    new_proc = run_cloudflared(proc._cloudflared_path)
                else:
                    continue
                procs[name] = new_proc
        time.sleep(5)


# ========== 主函数 ==========

def main():
    print("=" * 50)
    print("🚀 gotty + cloudflared 自动部署工具")
    print("=" * 50)

    os_name, arch, _, _ = get_system_info()
    print(f"📋 系统: {os_name} / {arch}")

    # 下载
    gotty_path = setup_gotty()
    cloudflared_path = setup_cloudflared()

    # 启动
    gotty_proc = run_gotty(gotty_path)
    cloudflared_proc = run_cloudflared(cloudflared_path)
    is_fixed = bool(ARGO_DOMAIN and ARGO_AUTH)

    print_tunnel_info(cloudflared_proc, is_fixed)

    print("\n" + "=" * 50)
    print("✅ 所有服务已启动，监控中... (Ctrl+C 停止)")
    if is_fixed:
        print(f"   固定域名: https://{ARGO_DOMAIN}")
    else:
        print("   临时域名请见上方")
    print("=" * 50 + "\n")

    procs = {
        "gotty": gotty_proc,
        "cloudflared": cloudflared_proc,
    }

    try:
        monitor_processes(procs)
    except KeyboardInterrupt:
        print("\n🛑 终止所有进程...")
        for proc in procs.values():
            if proc and proc.poll() is None:
                proc.terminate()
                time.sleep(1)
                if proc.poll() is None:
                    proc.kill()
        print("✅ 已清理（临时目录将在退出时自动删除）")


if __name__ == "__main__":
    main()
