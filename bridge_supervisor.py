# -*- coding: utf-8 -*-
"""
bridge_supervisor.py — Claude Bridge 健康守护层 (V1.0)
================================================================
让桥永远健康——除非用户显式手动关闭。

职责（每 15s 一轮巡检）:
  1. 功能健康检查（不止 PID 存活）:
       agent   → GET 127.0.0.1:19851/health 可达 + 19850 在监听
       watcher → .watcher_heartbeat 新鲜（< 30s）
       worker  → named pipe 真实 ping 可达
  2. 死了自动接管（拉起缺失/不健康的组件）
  3. 孤儿/多余实例自动回收（同类型超配额杀多余；parent 已死的 watchdog 杀）
  4. 手动关闭开关: watcher/.manual_stop 存在 → supervisor 退出托管（用户主动关桥）
  5. 崩溃退避防重启风暴（60s 内拉起 >3 次 → 该组件 backoff 5 分钟）
  6. worker 池按内存护栏自适应重建（复用 worker_factory.ps1 -DeployAll）

手动关闭:  touch watcher/.manual_stop   → supervisor 退出，桥不再被拉起
恢复托管:  rm watcher/.manual_stop && 重启 supervisor
"""
import json
import os
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

BASE = Path(r"D:\zebbingo\tools\claude-bridge")
CLUSTER = BASE / "cluster"
WATCHER = BASE / "watcher"
POOL_FILE = CLUSTER / ".worker_pool.json"
MANUAL_STOP = WATCHER / ".manual_stop"
LOG_FILE = BASE / "bridge_supervisor.log"
HEARTBEAT = WATCHER / ".supervisor_heartbeat"
POLL_SEC = 15
BACKOFF_SEC = 300          # 组件反复崩溃后的冷却
MAX_STARTS_IN_WINDOW = 3   # 60s 窗口内最多拉起次数

START_TIMES = {}           # component -> [recent start timestamps]
BACKOFF_UNTIL = {}         # component -> epoch (backoff until)


def log(msg):
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{ts}] [SUPERVISOR] {msg}\n"
    try:
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(line)
    except OSError:
        pass
    print(line, end="", flush=True)


def touch(path):
    try:
        Path(path).write_text(time.strftime("%Y-%m-%d %H:%M:%S"), encoding="utf-8")
    except OSError:
        pass


def free_mem_gb():
    try:
        return psutil_virtual_memory()
    except Exception:
        return 99.0


def psutil_virtual_memory():
    import psutil
    return round(psutil.virtual_memory().available / (1024 ** 3), 1)


# ── Process discovery (psutil) ────────────────────────────────────────

def find_procs(kw, exe_names=None):
    """Return psutil.Process list whose cmdline contains all kw tokens.

    exe_names: optional process-name prefixes (e.g. ["python"], ["powershell"])
    to avoid matching unrelated processes (and ourselves) whose cmdline
    happens to contain the keywords.
    """
    import psutil
    me = os.getpid()
    out = []
    for p in psutil.process_iter(["pid", "cmdline", "name", "create_time"]):
        try:
            if p.info["pid"] == me:
                continue
            if exe_names:
                nm = (p.info.get("name") or "").lower()
                if not any(nm.startswith(x) for x in exe_names):
                    continue
            cl = " ".join(p.info["cmdline"] or [])
        except Exception:
            continue
        if all(k.lower() in cl.lower() for k in kw):
            out.append(p)
    return out


def proc_age(p):
    try:
        return time.time() - p.info.get("create_time", 0)
    except Exception:
        return 0


def newest(procs):
    """Return the most recently started process (smallest age)."""
    return min(procs, key=proc_age) if procs else None


# ── Functional health ─────────────────────────────────────────────────

def agent_healthy():
    try:
        with urllib.request.urlopen("http://127.0.0.1:19851/health", timeout=4) as r:
            if r.status != 200:
                return False
            d = json.loads(r.read().decode())
            return d.get("status") == "ok"
    except Exception:
        return False


def agent_needs_restart():
    """True if agent must be (re)started.

    60s grace period after spawn — a freshly started agent takes a moment
    for its health server to come up; killing it in that window causes a
    restart-loop (supervisor keeps spawning, watchdog keeps reviving).
    """
    global _agent_unhealthy_streak
    agents = find_procs(["bridge_agent.py"], ["python"])
    if not agents:
        return True
    keep = newest(agents)
    if proc_age(keep) < 60:
        return False
    bad = not (agent_ping_ok() and port_listening(19850))
    if bad:
        _agent_unhealthy_streak += 1
        return _agent_unhealthy_streak >= 2
    _agent_unhealthy_streak = 0
    return False


def agent_ping_ok():
    """Functional probe: TCP 19850 ping (agent's handle_ping → pong).

    More reliable than the 19851 /health HTTP check: when leftover agents
    share 19851 (SO_REUSEADDR), the HTTP request can land on a dead one and
    time out → supervisor restarts a perfectly healthy agent every 30s.
    TCP ping on 19850 exercises the real command path.
    """
    try:
        import socket
        s = socket.create_connection(("127.0.0.1", 19850), timeout=3)
        try:
            s.sendall(json.dumps({"type": "ping"}).encode("utf-8") + b"\n")
            line = s.makefile("r").readline()
            return "pong" in (line or "")
        finally:
            s.close()
    except Exception:
        return False


def port_listening(port):
    try:
        import psutil
        for c in psutil.net_connections(kind="tcp"):
            if c.laddr.port == port and c.status == "LISTEN":
                return True
    except Exception:
        pass
    return False


def watcher_healthy():
    hb = WATCHER / ".watcher_heartbeat"
    try:
        return (time.time() - hb.stat().st_mtime) < 30
    except OSError:
        return False


def worker_pipe_ok(name):
    try:
        import win32pipe
        data = json.dumps({"type": "ping"}).encode()
        resp = win32pipe.CallNamedPipe(rf"\\.\pipe\{name}", data, 4096, 800)
        txt = resp.decode("utf-8", errors="replace")
        return "pong" in txt or "ok" in txt
    except Exception:
        return False


def load_pool():
    try:
        d = json.loads(POOL_FILE.read_text(encoding="utf-8-sig"))
        return d.get("workers", []) or []
    except Exception:
        return []


# ── Start / kill ──────────────────────────────────────────────────────

def allowed_to_start(comp):
    """Anti-storm: limit starts per window; backoff if too many."""
    now = time.time()
    if now < BACKOFF_UNTIL.get(comp, 0):
        return False
    recent = [t for t in START_TIMES.get(comp, []) if now - t < 60]
    if len(recent) >= MAX_STARTS_IN_WINDOW:
        BACKOFF_UNTIL[comp] = now + BACKOFF_SEC
        log(f"STORM-GUARD: {comp} 60s 内拉起 {len(recent)} 次，backoff {BACKOFF_SEC}s")
        START_TIMES[comp] = []
        return False
    return True


def note_start(comp):
    START_TIMES.setdefault(comp, []).append(time.time())
    START_TIMES[comp] = [t for t in START_TIMES[comp] if time.time() - t < 300]


def start_agent():
    if not allowed_to_start("agent"):
        return False
    try:
        subprocess.Popen(
            [sys.executable, str(BASE / "bridge_agent.py")],
            cwd=str(BASE),
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
        note_start("agent")
        log("接管: 启动 bridge_agent.py")
        return True
    except Exception as e:
        log(f"启动 agent 失败: {e}")
        return False


def start_watcher():
    if not allowed_to_start("watcher"):
        return False
    try:
        subprocess.Popen(
            ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass",
             "-File", str(WATCHER / "watcher.ps1")],
            cwd=str(WATCHER),
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
        note_start("watcher")
        log("接管: 启动 watcher.ps1")
        return True
    except Exception as e:
        log(f"启动 watcher 失败: {e}")
        return False


_pool_build_pending = False  # async pool rebuild in flight
_pool_fail_count = 0         # consecutive failed rebuilds
_pool_backoff_until = 0.0    # epoch: don't rebuild pool until then
_agent_unhealthy_streak = 0  # consecutive patrols judging agent unhealthy (debounce)


def rebuild_pool():
    """Async pool rebuild via worker_factory -DeployAll (non-blocking).

    worker_factory takes 10-90s; blocking the patrol loop would freeze
    watcher/agent supervision. So we Popen and let later rounds verify.
    """
    global _pool_build_pending
    if _pool_build_pending or not allowed_to_start("pool"):
        return False
    try:
        subprocess.Popen(
            ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass",
             "-File", str(CLUSTER / "worker_factory.ps1"), "-DeployAll"],
            cwd=str(CLUSTER),
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
        _pool_build_pending = True
        note_start("pool")
        log("接管: 异步重建 worker 池 (worker_factory -DeployAll)")
        return True
    except Exception as e:
        log(f"启动 worker_factory 失败: {e}")
        return False


def pool_rebuild_running():
    return bool(find_procs(["worker_factory.ps1"], ["power" + "shell"]))


def kill_proc(p, why):
    try:
        p.terminate()
        time.sleep(1)
        if p.is_running():
            p.kill()
        log(f"回收: {why} (PID={p.pid})")
    except Exception:
        try:
            p.kill()
        except Exception:
            pass


# ── Reaper: orphan / duplicate cleanup ───────────────────────────────

def reap_agents():
    """Keep newest 1 bridge_agent.py; kill extras TOGETHER WITH their
    watchdogs — otherwise a killed agent's watchdog sees parent dead and
    respawns it (fight between watchdog auto-revival and supervisor).
    """
    agents = find_procs(["bridge_agent.py"], ["python"])
    watchdogs = find_procs(["bridge_agent_watchdog.py"], ["python"])
    keep = newest(agents)
    kill_list = []
    for p in agents:
        if keep and p.pid == keep.pid:
            continue
        # kill this agent's own watchdog first (break revival source)
        for w in watchdogs:
            if w_ppid(w) == p.pid:
                kill_list.append(("watchdog", w))
        kill_list.append(("agent", p))
    for kind, p in kill_list:
        kill_proc(p, f"多余 {kind} 实例")

    # orphan watchdogs (parent gone / not an agent)
    live_agent_pids = {p.pid for p in agents}
    for w in watchdogs:
        if w_ppid(w) not in live_agent_pids:
            kill_proc(w, f"孤儿 watchdog (parent={w_ppid(w)} 不存在)")

    # keep-agent missing its watchdog for >60s → restart it fresh
    if keep:
        my_wd = [w for w in watchdogs if w_ppid(w) == keep.pid]
        if not my_wd and proc_age(keep) > 60:
            log("watchdog 缺失: 重启 agent 以重建 watchdog")
            kill_proc(keep, "agent 缺 watchdog")


def w_ppid(w):
    try:
        return w.ppid()
    except Exception:
        return -1


def reap_watchers():
    ws = find_procs(["watcher.ps1"], ["power" + "shell"])
    keep = newest(ws)
    for p in ws:
        if keep and p.pid == keep.pid:
            continue
        kill_proc(p, "多余 watcher 实例")


def reap_workers():
    """Kill worker_generic processes beyond the adaptive plan quota."""
    import psutil
    pool = load_pool()
    plan_total = 0
    try:
        # rough quota: reuse factory's adaptive plan
        free_gb = free_mem_gb()
        if free_gb < 1.0:
            plan_total = 0
        elif free_gb < 2.0:
            plan_total = 2
        elif free_gb < 3.0:
            plan_total = 3
        elif free_gb < 5.0:
            plan_total = 7
        else:
            plan_total = 15
    except Exception:
        plan_total = 7
    workers = find_procs(["worker_generic.ps1"], ["power" + "shell"])
    if len(workers) > plan_total:
        # keep newest plan_total, kill rest
        workers_sorted = sorted(workers, key=proc_age, reverse=True)
        for p in workers_sorted[plan_total:]:
            kill_proc(p, f"worker 超配额 (内存护栏允许 {plan_total})")
    # pool entries pointing at dead PIDs → stale; leave pool rebuild to handle


# ── Main loop ─────────────────────────────────────────────────────────

def ensure_component(label, healthy, start_fn, reap_fn=None):
    if not healthy():
        log(f"巡检: {label} 不健康 → 接管")
        start_fn()
    if reap_fn:
        reap_fn()


def _acquire_single_instance():
    """Windows named mutex — kernel-level single-instance guard.

    Reliable where PID-file locking is not: a second supervisor gets
    ERROR_ALREADY_EXISTS and exits; the mutex auto-releases when the
    owning process dies (no stale-lock problem, no orphan instances).
    """
    try:
        import ctypes
        kernel32 = ctypes.windll.kernel32
        ERROR_ALREADY_EXISTS = 183
        kernel32.CreateMutexW.restype = ctypes.c_void_p
        mutex = kernel32.CreateMutexW(None, False, "Global\\ClaudeBridgeSupervisor_V1")
        if not mutex:
            return False
        if ctypes.get_last_error() == ERROR_ALREADY_EXISTS:
            kernel32.CloseHandle(ctypes.c_void_p(mutex))
            return False
        return True
    except Exception:
        return True  # non-Windows / ctypes failure: allow (best effort)


def main():
    if not _acquire_single_instance():
        print("[SUPERVISOR] 另一 supervisor 持有互斥锁 Global\\ClaudeBridgeSupervisor_V1 — 退出避免双实例冲突", flush=True)
        return
    try:
        (WATCHER / ".supervisor_pid").write_text(str(os.getpid()), encoding="utf-8")
    except OSError:
        pass

    log("=" * 60)
    log("bridge_supervisor 启动 (巡检间隔 %ss)" % POLL_SEC)
    log("手动关闭开关: %s (存在则退出托管)" % MANUAL_STOP)
    while True:
        try:
            if MANUAL_STOP.exists():
                log("检测到 .manual_stop — 用户手动关闭，supervisor 退出（不再托管）")
                break

            touch(HEARTBEAT)

            # 1. watcher
            ensure_component("watcher", watcher_healthy, start_watcher, reap_watchers)

            # 2. agent (functional: health HTTP + port, with 60s grace)
            ensure_component(
                "agent",
                agent_needs_restart,
                start_agent,
                reap_agents,
            )

            # 3. worker pool (async rebuild — never blocks patrol)
            global _pool_build_pending, _pool_fail_count, _pool_backoff_until
            if not pool_rebuild_running():
                _pool_build_pending = False
            pool = load_pool()
            if _pool_build_pending:
                log("巡检: worker 池重建中（worker_factory 运行中，跳过）")
            elif time.time() < _pool_backoff_until:
                log(f"巡检: worker 池在 backoff 中（至 {time.strftime('%H:%M:%S', time.localtime(_pool_backoff_until))}）")
            elif free_mem_gb() < 1.0:
                log("巡检: 内存 <1GB，跳过 worker 池（护栏）")
            elif not pool:
                log("巡检: worker 池为空 → 重建")
                rebuild_pool()
            else:
                healthy_workers = sum(1 for w in pool if worker_pipe_ok(w.get("pipe", "")))
                if healthy_workers == 0:
                    _pool_fail_count += 1
                    if _pool_fail_count >= 3:
                        _pool_backoff_until = time.time() + 900
                        log(f"巡检: worker 池连续 {_pool_fail_count} 次重建仍全不健康 → 进入 15min backoff（内存不足/pipe 问题，暂停无谓重建）")
                        _pool_fail_count = 0
                    else:
                        log(f"巡检: worker 池 {len(pool)} 个全不健康(pipe 全挂) 第 {_pool_fail_count} 次 → 重建")
                        rebuild_pool()
                else:
                    _pool_fail_count = 0
            reap_workers()

            log(f"巡检完成 (mem={free_mem_gb()}GB, pool={len(load_pool())}, "
                f"agent_ok={agent_healthy()}, watcher_ok={watcher_healthy()})")
        except Exception as e:
            log(f"巡检异常(已保护): {e}")
        time.sleep(POLL_SEC)


if __name__ == "__main__":
    main()
