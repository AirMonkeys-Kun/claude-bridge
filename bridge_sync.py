#!/usr/bin/env python3
"""
bridge_sync.py — 9P 缓存感知的文件写工具

通过 TCP 桥（bridge_agent:19850）将文件写入 Windows 物理文件系统，
彻底绕过 VM 侧 FUSE 9P write-back 缓存。

何时使用：
  - 写入 memory 文件（MEMORY.md, *.md）
  - 写入系统会读取的配置文件（CLAUDE.md 等）
  - 任何需要"写入后即时对 Windows 可见"的场景

何时不必使用：
  - 只从 VM 沙箱内部读取的文件（直接 bash 操作）
  - 临时文件、日志（不需要跨 VM/Windows 同步）

用法：
  # 写文件（内容从标准输入或 --content）
  python3 bridge_sync.py /path/to/target/file.md --content "文件内容"
  python3 bridge_sync.py /path/to/target/file.md < source.md

  # 读文件验证
  python3 bridge_sync.py /path/to/target/file.md --read

  # 删除文件
  python3 bridge_sync.py /path/to/target/file.md --delete

  # 列出目录
  python3 bridge_sync.py /path/to/dir/ --ls

环境变量：
  BRIDGE_HOST — bridge_agent IP (默认 172.16.10.254)
  BRIDGE_PORT — bridge_agent 端口 (默认 19850)
"""

import argparse
import base64
import json
import os
import subprocess
import sys
import textwrap

BRIDGE_HOST = os.environ.get("BRIDGE_HOST", "172.16.10.254")
BRIDGE_PORT = int(os.environ.get("BRIDGE_PORT", "19850"))


def _find_bridge_client():
    """Locate bridge_client.py relative to this script or in known locations."""
    script_dir = os.path.dirname(os.path.abspath(__file__))
    candidates = [
        os.path.join(script_dir, "bridge_client.py"),
        os.path.join(os.path.dirname(script_dir), "bridge_client.py"),
        "/sessions/practical-nice-feynman/mnt/claude-bridge/bridge_client.py",
    ]
    for c in candidates:
        if os.path.isfile(c):
            return c
    # Glob fallback
    import glob
    matches = glob.glob("/sessions/*/mnt/*/bridge_client.py")
    if matches:
        return matches[0]
    sys.stderr.write("bridge_client.py not found\n")
    sys.exit(1)


def _send_command(cmd_dict, timeout=15):
    """Send a PowerShell command via bridge_client, return parsed result."""
    bc = _find_bridge_client()
    payload = json.dumps(cmd_dict)
    try:
        r = subprocess.run(
            [sys.executable, bc, payload],
            capture_output=True, text=True, timeout=timeout + 10,
        )
        result = json.loads(r.stdout.strip())
        return result
    except Exception as e:
        return {"state": "error", "stdout": "", "stderr": str(e), "error": str(e)}


def write_file(target_path, content):
    """Write content to a Windows file via TCP bridge, bypassing 9P cache.

    Uses base64 encoding to preserve UTF-8 content, then PowerShell
    WriteAllBytes to write directly to the Windows filesystem.
    """
    content_b64 = base64.b64encode(content.encode("utf-8")).decode("ascii")

    # Escape backslashes for PowerShell
    ps_path = target_path.replace("\\", "\\\\")

    ps_cmd = (
        '$b=[Convert]::FromBase64String("' + content_b64 + '");'
        '[System.IO.File]::WriteAllBytes("' + ps_path + '",$b);'
        'Write-Output ("OK:" + ([System.IO.File]::ReadAllBytes("' + ps_path + '").Length) + " bytes")'
    )

    result = _send_command({"command": ps_cmd, "type": "powershell", "timeout": 15})

    if result.get("state") == "done":
        sys.stdout.write(result.get("stdout", "").strip() + "\n")
        return True
    else:
        sys.stderr.write(f"ERROR: {result.get('error', 'unknown')}\n")
        sys.stderr.write(result.get("stderr", "") + "\n")
        return False


def read_file(target_path):
    """Read a Windows file via TCP bridge, return content as string."""
    ps_path = target_path.replace("\\", "\\\\")
    ps_cmd = (
        '$b=[System.IO.File]::ReadAllBytes("' + ps_path + '");'
        '[Convert]::ToBase64String($b)'
    )

    result = _send_command({"command": ps_cmd, "type": "powershell", "timeout": 15})

    if result.get("state") == "done":
        b64 = result.get("stdout", "").strip()
        if b64:
            return base64.b64decode(b64).decode("utf-8")
    return None


def delete_file(target_path):
    """Delete a Windows file via TCP bridge."""
    ps_path = target_path.replace("\\", "\\\\")
    ps_cmd = (
        'Remove-Item -LiteralPath "' + ps_path + '" -Force -ErrorAction SilentlyContinue;'
        'if (Test-Path "' + ps_path + '") { Write-Output "FAIL: still exists" } '
        'else { Write-Output "DELETED" }'
    )

    result = _send_command({"command": ps_cmd, "type": "powershell", "timeout": 15})
    sys.stdout.write(result.get("stdout", "").strip() + "\n")
    return result.get("state") == "done"


def list_dir(target_path):
    """List directory contents via TCP bridge."""
    ps_path = target_path.replace("\\", "\\\\")
    ps_cmd = (
        'Get-ChildItem -LiteralPath "' + ps_path + '" | '
        'Select-Object Name,Length,LastWriteTime | '
        'ConvertTo-Json -Compress'
    )

    result = _send_command({"command": ps_cmd, "type": "powershell", "timeout": 15})

    if result.get("state") == "done":
        stdout = result.get("stdout", "").strip()
        if stdout:
            try:
                items = json.loads(stdout)
                if not isinstance(items, list):
                    items = [items]
                for item in items:
                    size = item.get("Length", "?")
                    lwt = item.get("LastWriteTime", "?")
                    name = item.get("Name", "?")
                    sys.stdout.write(f"{lwt}  {size:>8}  {name}\n")
                return True
            except json.JSONDecodeError:
                sys.stdout.write(stdout + "\n")
                return True
    return False


def main():
    parser = argparse.ArgumentParser(
        description="9P 缓存感知的文件写工具 — 通过 TCP 桥写入 Windows 文件系统",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=textwrap.dedent("""\
            示例：
              bridge_sync.py C:\\path\\to\\file.md --content "hello"
              bridge_sync.py C:\\path\\to\\file.md --read
              bridge_sync.py C:\\path\\to\\file.md --delete
              bridge_sync.py C:\\path\\to\\dir\\ --ls
        """),
    )
    parser.add_argument("target", help="Windows 目标路径")
    parser.add_argument("--content", help="文件内容（不提供则从 stdin 读取）")
    parser.add_argument("--read", action="store_true", help="读取文件内容")
    parser.add_argument("--delete", action="store_true", help="删除文件")
    parser.add_argument("--ls", action="store_true", help="列出目录")

    args = parser.parse_args()

    if args.read:
        content = read_file(args.target)
        if content is not None:
            sys.stdout.write(content)
            if not content.endswith("\n"):
                sys.stdout.write("\n")
        else:
            sys.stderr.write(f"Failed to read: {args.target}\n")
            sys.exit(1)

    elif args.delete:
        if not delete_file(args.target):
            sys.exit(1)

    elif args.ls:
        if not list_dir(args.target):
            sys.stderr.write(f"Failed to list: {args.target}\n")
            sys.exit(1)

    else:
        content = args.content
        if content is None:
            content = sys.stdin.read()

        if not content:
            sys.stderr.write("No content provided (use --content or pipe stdin)\n")
            sys.exit(1)

        if not write_file(args.target, content):
            sys.exit(1)


if __name__ == "__main__":
    main()
