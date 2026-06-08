#!/usr/bin/env python3
"""
bridge_fsync.py — 9P write-back 缓存强制刷写工具

9P/virtiofs write-back 缓存是 Linux VM 写入文件的最大问题：
  write() → 9P client confirms immediately → data may NOT reach Windows for 5-30s (or ever)

Python 的 open() + close() 不触发 9P flush。唯一可靠的方法是 fsync()。
本工具提供统一的 fsync 入口，用于所有 FUSE 文件写入后的强制刷写。

用法：
  # 刷写单个文件
  python3 bridge_fsync.py /path/to/file.txt

  # 刷写整个目录（所有脏页）
  python3 bridge_fsync.py /path/to/dir/ --dir

  # 对整个 9P 挂载点执行 syncfs（最彻底）
  python3 bridge_fsync.py --syncfs

  # 链式写入 + fsync
  echo '{"state":"pending","cmd_id":"x"}' > queue.txt && python3 bridge_fsync.py queue.txt

原理：
  -- 单文件: open() → fsync(fd) → close()
  -- 目录: fsync(fd) on the directory (force metadata sync)
  -- syncfs: os.sync() on the entire filesystem (force all dirty pages)
"""

import argparse
import ctypes
import os
import sys


def fsync_file(path):
    """Force 9P write-back flush for a single file.

    Opens the file, calls fsync(), then closes. The fsync() system call
    forces the kernel to flush dirty pages for this file to the 9P server,
    which then writes them to the Windows filesystem.

    Returns True on success, False on failure.
    """
    try:
        fd = os.open(path, os.O_RDONLY)
        try:
            os.fsync(fd)
            return True
        finally:
            os.close(fd)
    except OSError as e:
        sys.stderr.write(f"fsync failed for {path}: {e}\n")
        return False


def fsync_dir(path):
    """Force 9P write-back flush for a directory's metadata.

    Forces kernel to flush directory entry changes to the 9P server.
    This ensures file creations/deletions/renames are visible on Windows.
    """
    try:
        fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(fd)
            return True
        finally:
            os.close(fd)
    except OSError as e:
        sys.stderr.write(f"dir fsync failed for {path}: {e}\n")
        return False


def sync_all():
    """Force sync the entire filesystem.

    Calls the sync() system call which queues all dirty pages for writeback.
    Note: sync() is asynchronous — it queues the writes but doesn't wait.
    On Linux, this is generally sufficient for 9P flush within ~1s.
    """
    try:
        # Python's os.sync() calls the sync() syscall
        os.sync()
        return True
    except OSError as e:
        sys.stderr.write(f"sync() failed: {e}\n")
        return False


def syncfs_9p(mount_point):
    """Force sync on a specific 9P mount point (Linux 5.4+).

    Uses the syncfs() syscall on an open fd of the mount point.
    This is more targeted than sync() — it only flushes pages for
    this specific filesystem, not all filesystems.

    syncfs(fd) syscall number: 306 on x86_64
    """
    try:
        fd = os.open(mount_point, os.O_RDONLY | os.O_DIRECTORY)
        try:
            # syncfs() syscall — more targeted than global sync()
            # Falls back to os.sync() if syscall not available
            libc = ctypes.CDLL("libc.so.6")
            result = libc.syncfs(fd)
            if result != 0:
                raise OSError(ctypes.get_errno(), f"syncfs() returned {result}")
            return True
        except AttributeError:
            # libc.syncfs not available — fall back to global sync
            os.sync()
            return True
        finally:
            os.close(fd)
    except OSError as e:
        sys.stderr.write(f"syncfs failed for {mount_point}: {e}\n")
        return False


def main():
    parser = argparse.ArgumentParser(
        description="9P write-back 缓存强制刷写工具",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("path", nargs="?", help="要刷写的文件路径")
    parser.add_argument("--dir", action="store_true", help="刷写目录（代替单个文件）")
    parser.add_argument("--syncfs", metavar="MOUNT_POINT", nargs="?",
                        const="/", default=None,
                        help="syncfs 挂载点 (默认: /)")
    parser.add_argument("--sync", action="store_true", help="全局 sync()")
    args = parser.parse_args()

    if args.sync:
        ok = sync_all()
        sys.stdout.write("sync() OK\n" if ok else "sync() FAILED\n")
        sys.exit(0 if ok else 1)

    if args.syncfs is not None:
        ok = syncfs_9p(args.syncfs)
        sys.stdout.write(f"syncfs({args.syncfs}) OK\n" if ok else f"syncfs({args.syncfs}) FAILED\n")
        sys.exit(0 if ok else 1)

    if not args.path:
        parser.print_help()
        sys.exit(1)

    path = args.path

    if args.dir:
        ok = fsync_dir(path)
        sys.stdout.write(f"fsync_dir({path}) OK\n" if ok else f"fsync_dir({path}) FAILED\n")
    else:
        ok = fsync_file(path)
        sys.stdout.write(f"fsync({path}) OK\n" if ok else f"fsync({path}) FAILED\n")

    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
