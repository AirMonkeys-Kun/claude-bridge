"""
Claude Desktop <-> Multi-Provider Proxy v13
============================================

Features
--------
- **Smart model routing** — route haiku to cheap provider, sonnet/opus to premium
- **Real-time metrics** — GET /metrics with provider health, latency, circuit states, token tracking
- **Structured audit log** — every request/response logged to proxy_audit.log
- **Multi-provider failover** — circuit breaker per provider, automatic fallback
- **Request deduplication** — identical concurrent requests share a single backend call
- **Gzip compression** — FastAPI GzipMiddleware for smaller responses
- **Concurrency semaphore** — limits concurrent backend requests (CONCURRENT_MAX)
- **Token tracking** — per-provider input/output/cache token counters with zero-usage fix
- **Config hot-reload** — live config.yaml changes via polling watcher (no restart needed)
- **Dual API format** — native Anthropic passthrough (xiaomi) OR OpenAI conversion (zhipu)
- **Thinking blocks** — preserved natively in anthropic mode; reasoning_content
  properly handled in openai mode (never forwarded as text_delta)
- **Pooled HTTPS connections** — shared httpx.AsyncClient reduces per-request TLS overhead
- **Role-based model mapping** — exact match first, then role fallback (sonnet/opus/haiku)
- **Zero-usage fix** — message_delta always includes a usage block (even zero)
- **Canonicalized JSON** — sorts dict keys for byte-identical prefix-cache reuse
- **Local trivial query interception** — title gen, suggestions answered without backend roundtrip
- **Tool result truncation** — prevents context explosion (configurable char limit)
- **Tool choice mapping** — correct Anthropic<->OpenAI tool_choice conversion
- **Thinking normalization** — handles adaptive thinking for backends that don't support it
- **Tool-call thinking injection** — DeepSeek compatibility: injects reasoning blocks
  on tool_call multi-turn history
- **Retry on transient failures** — one retry for 5xx / connection errors
- **Rate limiting** — in-memory token bucket, configurable RPM
- **API key rotation** — multiple keys via comma-separated list, round-robin
- **Error passthrough** — backend error details forwarded to client
- **Stream heartbeat** — periodic ping keeps long streams alive
- **CORS headers** — cross-origin support for web-based clients
- **Wildcard model matching** -- ``claude-*`` style patterns in model_map

Config sources (priority high->low): env vars -> config.yaml -> code defaults
"""

import json
import time
import uuid
import logging
import os
import asyncio
import re
import itertools
import hashlib
from pathlib import Path
from typing import AsyncGenerator, Optional, List
from collections import deque
from dataclasses import dataclass, field

from fastapi import FastAPI, Request, HTTPException
from fastapi.responses import StreamingResponse, JSONResponse
from fastapi.middleware.cors import CORSMiddleware
from starlette.middleware.gzip import GZipMiddleware
import httpx
import uvicorn
import yaml


# ---------------------------------------------------------------------------
# Load .env file (next to proxy_server.py) if present
# ---------------------------------------------------------------------------

_env_file = Path(__file__).parent / ".env"
if _env_file.exists():
    with open(_env_file, encoding="utf-8") as _f:
        for _line in _f:
            _line = _line.strip()
            if _line and not _line.startswith("#") and "=" in _line:
                _k, _v = _line.split("=", 1)
                _k = _k.strip()
                _v = _v.strip()
                # strip optional quotes around value
                if len(_v) >= 2 and _v[0] == _v[-1] and _v[0] in ('"', "'"):
                    _v = _v[1:-1]
                os.environ.setdefault(_k, _v)


# ---------------------------------------------------------------------------
# Exception for provider failover signalling
# ---------------------------------------------------------------------------

class ProviderFailover(Exception):
    """Raised when a provider fails and the next provider should be tried.

    Only raised for 5xx / network errors — NOT for 4xx client errors.
    """
    def __init__(self, message: str, status_code: int = 502):
        self.status_code = status_code
        super().__init__(message)


# ---------------------------------------------------------------------------
# Paths & Config
# ---------------------------------------------------------------------------

BASE_DIR = Path(__file__).parent
CONFIG_PATH = BASE_DIR / "config.yaml"

_config = {}
if CONFIG_PATH.exists():
    with open(CONFIG_PATH, encoding="utf-8") as f:
        _config = yaml.safe_load(f) or {}

ACTIVE_PROVIDER = os.environ.get("PROVIDER") or _config.get("provider", "xiaomi")

# --- Failover config ---
_failover_cfg = _config.get("failover", {})
FAILOVER_ENABLED = _failover_cfg.get("enabled", False)
FAILOVER_THRESHOLD = _failover_cfg.get("failure_threshold", 3)
FAILOVER_COOLDOWN = _failover_cfg.get("cooldown_seconds", 30)
FAILOVER_PROVIDERS: List[str] = _failover_cfg.get("providers", [])

# --- Smart routing config ---
_routing_cfg = _config.get("routing", {})
ROUTING_ENABLED = _routing_cfg.get("enabled", False)
ROUTING_RULES: List[dict] = _routing_cfg.get("rules", [])

# --- Server ---
SERVER_HOST = os.environ.get("PROXY_HOST") or _config.get("server", {}).get("host", "127.0.0.1")
SERVER_PORT = int(os.environ.get("PROXY_PORT") or _config.get("server", {}).get("port", 4000))

# --- Rate limit ---
RATE_LIMIT_RPM = int(os.environ.get("RATE_LIMIT_RPM", "60"))

# --- Tunables (shared across providers) ---
TOOL_RESULT_MAX_CHARS = int(os.environ.get("TOOL_RESULT_MAX_CHARS", "12000"))
OUTPUT_MAX_TOKENS = int(os.environ.get("OUTPUT_MAX_TOKENS", "16384"))
RETRY_MAX = int(os.environ.get("RETRY_MAX", "1"))
MAX_TOKENS_DEFAULT = int(os.environ.get("MAX_TOKENS_DEFAULT", "8192"))
STREAM_PING_INTERVAL = float(os.environ.get("STREAM_PING_INTERVAL", "10.0"))
CONCURRENT_MAX = int(os.environ.get("CONCURRENT_MAX", "10"))    # max concurrent backend requests
_concurrent_semaphore = asyncio.Semaphore(CONCURRENT_MAX)


# ---------------------------------------------------------------------------
# Dataclass: per-provider configuration
# ---------------------------------------------------------------------------

@dataclass
class ProviderConfig:
    """All config for a single backend provider, loaded from config.yaml."""
    name: str
    api_format: str                    # "anthropic" or "openai"
    api_base_anthropic: str = ""       # for anthropic-native passthrough
    api_base: str = ""                 # for OpenAI-format conversion
    api_key: str = ""
    api_keys: List[str] = field(default_factory=list)
    model_map: dict = field(default_factory=dict)
    default_model: str = field(default="")

    def __post_init__(self):
        self._key_cycle = itertools.cycle(self.api_keys) if len(self.api_keys) > 1 else None

    def get_current_key(self) -> str:
        if self._key_cycle:
            return next(self._key_cycle)
        return self.api_keys[0] if self.api_keys else ""

    def build_auth_header(self) -> dict:
        return {"Authorization": f"Bearer {self.get_current_key()}", "Content-Type": "application/json"}

    @property
    def role_defaults(self) -> dict:
        roles = {}
        for role_key in ("sonnet", "opus", "haiku"):
            mapped = self.model_map.get(f"claude-{role_key}", "")
            roles[role_key] = mapped or self.default_model
        return roles


def _load_provider_configs() -> dict[str, ProviderConfig]:
    """Load all provider configs referenced in config.yaml."""
    providers: dict[str, ProviderConfig] = {}

    # Collect all provider names we might need
    names = set()
    if FAILOVER_ENABLED:
        names.update(FAILOVER_PROVIDERS)
    names.add(ACTIVE_PROVIDER)

    for name in names:
        cfg = _config.get(name, {})
        api_format = (os.environ.get(f"{name.upper()}_API_FORMAT") or cfg.get("api_format", "openai")).lower()
        api_base_anthropic = (
            os.environ.get(f"{name.upper()}_API_BASE_ANTHROPIC")
            or cfg.get("api_base_anthropic")
            or cfg.get("api_base", "")
        )
        api_base = os.environ.get(f"{name.upper()}_API_BASE") or cfg.get("api_base", "")
        api_key = os.environ.get(f"{name.upper()}_API_KEY") or cfg.get("api_key", "")
        model_map = cfg.get("model_map", {})

        # Parse multiple comma-separated keys
        api_keys = [k.strip() for k in api_key.split(",") if k.strip()]

        # Default model: first model_map value, or sensible default
        all_values = list(model_map.values())
        default_model = all_values[0] if all_values else ("mimo-v2.5" if name == "xiaomi" else "glm-5.1")

        providers[name] = ProviderConfig(
            name=name,
            api_format=api_format,
            api_base_anthropic=api_base_anthropic,
            api_base=api_base,
            api_key=api_key,
            api_keys=api_keys,
            model_map=model_map,
            default_model=default_model,
        )

    return providers


_providers: dict[str, ProviderConfig] = _load_provider_configs()

# Quick validation
for pname, p in _providers.items():
    if not p.api_keys:
        raise SystemExit(f"FATAL: Provider '{pname}' API key is empty.")
    if p.api_format == "openai" and not p.api_base:
        raise SystemExit(f"FATAL: Provider '{pname}' api_base is empty (openai mode).")
    if p.api_format == "anthropic" and not p.api_base_anthropic:
        raise SystemExit(f"FATAL: Provider '{pname}' anthropic base is empty (anthropic mode).")


# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    handlers=[
        logging.StreamHandler(),
        logging.FileHandler(BASE_DIR / "proxy_debug.log", encoding="utf-8"),
    ],
)
logger = logging.getLogger("claude-bridge")

# ---------------------------------------------------------------------------
# Metrics & audit logging
# ---------------------------------------------------------------------------

_metrics = {
    "requests_total": 0,
    "trivial_intercepted": 0,
    "health_probes": 0,
    "errors_total": 0,
    "dedup_hits": 0,
    "dedup_total": 0,
    "rate_limit_exceeded": 0,
    "started_at": time.time(),
}

_provider_stats: dict[str, dict] = {}
for pname in _providers:
    _provider_stats[pname] = {"requests": 0, "success": 0, "failure": 0, "latencies": []}

_provider_tokens: dict[str, dict] = {}
for pname in _providers:
    _provider_tokens[pname] = {"input": 0, "output": 0, "cache_read": 0}

_models_cache: Optional[dict] = None
_models_cache_ts: float = 0
_MODELS_CACHE_TTL = 60  # seconds

_audit_logger = logging.getLogger("claude-bridge-audit")
_audit_logger.setLevel(logging.INFO)
_audit_logger.propagate = False
_audit_handler = logging.FileHandler(BASE_DIR / "proxy_audit.log", encoding="utf-8")
_audit_handler.setFormatter(logging.Formatter('%(message)s'))
_audit_logger.addHandler(_audit_handler)

app = FastAPI()

# --- CORS ---
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# --- Gzip compression (Starlette, compresses JSON responses > 1 KB) ---
app.add_middleware(GZipMiddleware, minimum_size=1000)


# ---------------------------------------------------------------------------
# Circuit Breaker (per-provider)
# ---------------------------------------------------------------------------

class CircuitState:
    CLOSED = "closed"
    OPEN = "open"
    HALF_OPEN = "half_open"


class CircuitBreaker:
    """Simple circuit breaker: Closed -> Open -> HalfOpen -> Closed.

    Closed:   normal operation, requests pass through
    Open:     failures exceeded threshold, requests fail fast (skip provider)
    HalfOpen: after cooldown, one probe request is allowed
    """

    def __init__(self, name: str, threshold: int = 3, cooldown: float = 30.0):
        self.name = name
        self.state = CircuitState.CLOSED
        self.failure_count = 0
        self.threshold = threshold
        self.cooldown = cooldown
        self.last_failure_time = 0.0
        self.total_success = 0
        self.total_failure = 0

    def is_available(self) -> bool:
        now = time.monotonic()
        if self.state == CircuitState.CLOSED:
            return True
        if self.state == CircuitState.OPEN:
            elapsed = now - self.last_failure_time
            if elapsed >= self.cooldown:
                logger.info("Circuit breaker '%s': open -> half-open (cooldown %.1fs elapsed)",
                            self.name, elapsed)
                self.state = CircuitState.HALF_OPEN
                return True
            return False
        # HALF_OPEN — allow the probe
        return True

    def record_success(self):
        self.total_success += 1
        if self.state == CircuitState.HALF_OPEN:
            logger.info("Circuit breaker '%s': half-open probe succeeded -> closed", self.name)
            self.state = CircuitState.CLOSED
            self.failure_count = 0

    def record_failure(self):
        self.total_failure += 1
        self.failure_count += 1
        self.last_failure_time = time.monotonic()
        if self.state == CircuitState.HALF_OPEN or self.failure_count >= self.threshold:
            logger.warning("Circuit breaker '%s': %s after %d failures (threshold=%d)",
                           self.name,
                           "half-open -> open" if self.state == CircuitState.HALF_OPEN else "closed -> open",
                           self.failure_count, self.threshold)
            self.state = CircuitState.OPEN


# Build circuit breakers for all providers (and any that might be added dynamically)
_circuit_breakers: dict[str, CircuitBreaker] = {}
for pname in _providers:
    _circuit_breakers[pname] = CircuitBreaker(pname, FAILOVER_THRESHOLD, FAILOVER_COOLDOWN)


def _get_cb(provider_name: str) -> CircuitBreaker:
    """Return (or create) a circuit breaker for the given provider."""
    cb = _circuit_breakers.get(provider_name)
    if cb is None:
        cb = CircuitBreaker(provider_name, FAILOVER_THRESHOLD, FAILOVER_COOLDOWN)
        _circuit_breakers[provider_name] = cb
    return cb


# ---------------------------------------------------------------------------
# Rate limiter (token bucket) — global, not per-provider
# ---------------------------------------------------------------------------

class RateLimiter:
    """Simple in-memory token bucket rate limiter."""

    def __init__(self, rpm: int):
        self.capacity = rpm
        self.tokens = rpm
        self.refill_rate = rpm / 60.0
        self.last_refill = time.monotonic()

    def allow(self) -> bool:
        now = time.monotonic()
        elapsed = now - self.last_refill
        self.tokens = min(self.capacity, self.tokens + elapsed * self.refill_rate)
        self.last_refill = now
        if self.tokens >= 1:
            self.tokens -= 1
            return True
        return False


_rate_limiter = RateLimiter(RATE_LIMIT_RPM)


# ---------------------------------------------------------------------------
# Config hot-reload
# ---------------------------------------------------------------------------

_config_last_mtime: float = 0.0


def _reload_config():
    """Reload config.yaml and update global state in-place.
    Called by the background watcher when the file changes."""
    global _config, ACTIVE_PROVIDER
    global FAILOVER_ENABLED, FAILOVER_THRESHOLD, FAILOVER_COOLDOWN, FAILOVER_PROVIDERS
    global ROUTING_ENABLED, ROUTING_RULES

    try:
        with open(CONFIG_PATH, encoding="utf-8") as f:
            new_config = yaml.safe_load(f) or {}
    except Exception as e:
        logger.error("Config reload failed: %s", e)
        return

    _config = new_config

    # --- Reload failover settings ---
    _failover_cfg = _config.get("failover", {})
    FAILOVER_ENABLED = _failover_cfg.get("enabled", False)
    FAILOVER_THRESHOLD = _failover_cfg.get("failure_threshold", 3)
    FAILOVER_COOLDOWN = _failover_cfg.get("cooldown_seconds", 30)
    FAILOVER_PROVIDERS = _failover_cfg.get("providers", [])

    # --- Reload routing ---
    _routing_cfg = _config.get("routing", {})
    ROUTING_ENABLED = _routing_cfg.get("enabled", False)
    ROUTING_RULES = _routing_cfg.get("rules", [])

    # --- Reload provider configs ---
    ACTIVE_PROVIDER = os.environ.get("PROVIDER") or _config.get("provider", "xiaomi")
    new_providers = _load_provider_configs()
    for pname, pcfg in new_providers.items():
        if pname in _providers:
            # Update in-place to preserve circuit breakers and stats
            old_p = _providers[pname]
            old_p.api_format = pcfg.api_format
            old_p.api_base_anthropic = pcfg.api_base_anthropic
            old_p.api_base = pcfg.api_base
            old_p.api_key = pcfg.api_key
            old_p.api_keys = pcfg.api_keys
            old_p.model_map = pcfg.model_map
            old_p.default_model = pcfg.default_model
            old_p._key_cycle = pcfg._key_cycle
        else:
            _providers[pname] = pcfg
            _circuit_breakers[pname] = CircuitBreaker(pname, FAILOVER_THRESHOLD, FAILOVER_COOLDOWN)
            _provider_stats[pname] = {"requests": 0, "success": 0, "failure": 0, "latencies": []}
            _provider_tokens[pname] = {"input": 0, "output": 0, "cache_read": 0}

    # --- Remove providers that no longer exist ---
    for pname in list(_providers.keys()):
        if pname not in new_providers:
            del _providers[pname]
            _circuit_breakers.pop(pname, None)
            _provider_stats.pop(pname, None)
            _provider_tokens.pop(pname, None)

    # --- Update rate limiter if capacity changed ---
    new_rpm = int(os.environ.get("RATE_LIMIT_RPM", "60"))
    if new_rpm != _rate_limiter.capacity:
        _rate_limiter.capacity = new_rpm
        _rate_limiter.refill_rate = new_rpm / 60.0

    logger.info("Config hot-reloaded (%d providers, failover=%s routing=%s)",
                len(_providers), FAILOVER_ENABLED, ROUTING_ENABLED)


async def _watch_config():
    """Background task: poll config.yaml mtime every 5 seconds."""
    global _config_last_mtime
    # Set initial mtime so we don't trigger on first check
    try:
        _config_last_mtime = CONFIG_PATH.stat().st_mtime
    except OSError:
        _config_last_mtime = 0.0
    while True:
        await asyncio.sleep(5)
        try:
            current_mtime = CONFIG_PATH.stat().st_mtime
        except OSError:
            continue
        if current_mtime > _config_last_mtime:
            _config_last_mtime = current_mtime
            logger.info("Config file changed, reloading...")
            _reload_config()


# ---------------------------------------------------------------------------
# Shared HTTP client
# ---------------------------------------------------------------------------

_client: Optional[httpx.AsyncClient] = None


def get_client() -> httpx.AsyncClient:
    global _client
    if _client is None:
        _client = httpx.AsyncClient(
            timeout=httpx.Timeout(300.0, connect=30.0),
            limits=httpx.Limits(max_keepalive_connections=8, max_connections=32),
        )
    return _client


# ---------------------------------------------------------------------------
# Model name resolution (provider-aware)
# ---------------------------------------------------------------------------

def get_backend_model(claude_model: str, model_map: Optional[dict] = None) -> str:
    """Resolve a claude-* model name to the backend model ID.

    Priority: exact map -> wildcard pattern -> role fallback -> default_model_str
    """
    mm = model_map or {}
    if not mm:
        # Fallback if no model map is available
        return claude_model

    # 1. Exact match
    exact = mm.get(claude_model)
    if exact:
        return exact

    # 2. Wildcard match (e.g. ``claude-*`` -> backend default)
    for pattern, mapped in mm.items():
        if "*" in pattern:
            regex = "^" + re.escape(pattern).replace("\\*", ".*") + "$"
            if re.match(regex, claude_model):
                return mapped

    # 3. Role-based fallback
    claude_lower = claude_model.lower()
    for role_key in ("sonnet", "opus", "haiku"):
        if role_key in claude_lower:
            fallback_model = mm.get(f"claude-{role_key}")
            if fallback_model:
                return fallback_model

    # 4. Fallback to first value in model_map
    first_val = next(iter(mm.values()), None)
    return first_val or claude_model


# ---------------------------------------------------------------------------
# Smart model routing
# ---------------------------------------------------------------------------

def _apply_routing(model: str) -> Optional[str]:
    """Check routing rules against model name.
    Returns provider name if a rule matches, else None.
    """
    if not ROUTING_ENABLED:
        return None
    for rule in ROUTING_RULES:
        pattern = rule.get("pattern", "")
        provider = rule.get("provider", "")
        if not pattern or not provider:
            continue
        if "*" in pattern:
            regex = "^" + re.escape(pattern).replace("\\*", ".*") + "$"
            if re.match(regex, model):
                return provider
        elif pattern == model:
            return provider
    return None


# ---------------------------------------------------------------------------
# Local trivial query interception (free-claude-code inspired)
# ---------------------------------------------------------------------------

TRIVIAL_PATTERNS = [
    lambda b: b.get("max_tokens", 100) <= 5 and len(b.get("messages", [])) == 1,
    lambda b: b.get("max_tokens", 100) <= 10 and len(b.get("messages", [])) == 1,
]


def is_trivial_query(body: dict) -> bool:
    return any(fn(body) for fn in TRIVIAL_PATTERNS)


def trivial_response(claude_model: str) -> dict:
    return {
        "id": f"msg_{uuid.uuid4().hex[:24]}",
        "type": "message",
        "role": "assistant",
        "content": [{"type": "text", "text": "ok"}],
        "model": claude_model,
        "stop_reason": "end_turn",
        "stop_sequence": None,
        "usage": {"input_tokens": 1, "output_tokens": 1},
    }


# ---------------------------------------------------------------------------
# Health probe detection
# ---------------------------------------------------------------------------

def is_health_probe(body: dict) -> bool:
    return body.get("max_tokens") == 1 and not body.get("tools") and len(body.get("messages", [])) <= 1


# ---------------------------------------------------------------------------
# Retry helper (provider-aware)
# ---------------------------------------------------------------------------

async def _request_with_retry(method: str, url: str, provider_name: str = "xiaomi", **kwargs) -> httpx.Response:
    """Make a request with retry on 5xx or connection errors.
    Picks a fresh API key per attempt (key rotation per provider)."""
    p = _providers.get(provider_name)
    if not p:
        raise ProviderFailover(f"Unknown provider: {provider_name}")

    last_exc = None
    for attempt in range(1 + RETRY_MAX):
        hdr = p.build_auth_header()
        merged_headers = kwargs.pop("headers", {})
        merged_headers.update(hdr)
        try:
            resp = await get_client().request(method, url, headers=merged_headers, **kwargs)
            if resp.status_code < 500 or attempt == RETRY_MAX:
                return resp
            logger.warning("[%s] Retry %d/%d due to %d on %s",
                           provider_name, attempt + 1, RETRY_MAX, resp.status_code, url)
            await _backoff(attempt)
        except (httpx.ConnectError, httpx.TimeoutException, httpx.RemoteProtocolError) as e:
            last_exc = e
            if attempt == RETRY_MAX:
                raise ProviderFailover(f"{provider_name}: {type(e).__name__}: {e}") from e
            logger.warning("[%s] Retry %d/%d due to %s: %s",
                           provider_name, attempt + 1, RETRY_MAX, type(e).__name__, e)
            await _backoff(attempt)
    raise ProviderFailover(f"{provider_name}: retries exhausted: {last_exc}") if last_exc else \
        ProviderFailover(f"{provider_name}: retries exhausted")


async def _backoff(attempt: int):
    await asyncio.sleep(0.5 * (attempt + 1))


# ---------------------------------------------------------------------------
# Tool result truncation (DeepSeek-inspired)
# ---------------------------------------------------------------------------

def _truncate_tool_content(text: str, max_chars: int = TOOL_RESULT_MAX_CHARS) -> str:
    if len(text) > max_chars:
        half = max_chars // 2
        return text[:half] + f"\n... [truncated {len(text) - max_chars} chars] ...\n" + text[-half:]
    return text


# ---------------------------------------------------------------------------
# Thinking normalization (DeepSeek compatibility)
# ---------------------------------------------------------------------------

def _normalize_thinking(body: dict) -> dict:
    body = dict(body)
    thinking = body.get("thinking")
    if isinstance(thinking, dict):
        ttype = thinking.get("type", "")
        if ttype == "adaptive":
            logger.info("Normalizing thinking: adaptive -> enabled budget=4096")
            body["thinking"] = {"type": "enabled", "budget_tokens": 4096}
        elif ttype == "disabled":
            body.pop("thinking", None)
    return body


# ---------------------------------------------------------------------------
# tool_choice mapping
# ---------------------------------------------------------------------------

def _map_tool_choice(anthropic_tc) -> any:
    if not isinstance(anthropic_tc, dict):
        return anthropic_tc
    tc_type = anthropic_tc.get("type", "auto")
    if tc_type == "auto":
        return "auto"
    elif tc_type == "any":
        return "required"
    elif tc_type == "tool":
        name = anthropic_tc.get("name", "")
        if name:
            return {"type": "function", "function": {"name": name}}
        return "auto"
    return "auto"


# ---------------------------------------------------------------------------
# Error passthrough helper
# ---------------------------------------------------------------------------

def _error_response(status_code: int, body: str, proxy_detail: str = "") -> JSONResponse:
    logger.error("Error %d: %s", status_code, body[:500])
    msg = proxy_detail if proxy_detail else f"Backend returned {status_code}"
    return JSONResponse(
        status_code=status_code,
        content={
            "type": "error",
            "error": {"type": "api_error", "message": msg},
            "proxy": True,
        },
    )


# ---------------------------------------------------------------------------
# Request deduplication (non-streaming only)
# ---------------------------------------------------------------------------

_request_dedup: dict[str, asyncio.Future] = {}
_DEDUP_TTL = 30  # seconds — safety cleanup for abandoned futures


def _dedup_key(body: dict) -> str:
    """Canonical hash of a request body for dedup."""
    raw = json.dumps(body, sort_keys=True, ensure_ascii=False)
    return hashlib.sha256(raw.encode()).hexdigest()


async def _dedup_wait_or_claim(hkey: str, factory):
    """If a request with this hash is in-flight, wait for its result.
    Otherwise, claim it: call factory(), store the result, and return.
    """
    existing = _request_dedup.get(hkey)
    if existing is not None:
        logger.info("Dedup hit for %s, waiting on in-flight request", hkey[:12])
        _metrics["dedup_hits"] += 1
        return await existing

    future = asyncio.get_event_loop().create_future()
    _request_dedup[hkey] = future

    # Safety cleanup — if the future is never resolved, remove after TTL
    async def _cleanup():
        await asyncio.sleep(_DEDUP_TTL)
        _request_dedup.pop(hkey, None)
    cleanup_task = asyncio.ensure_future(_cleanup())

    try:
        result = await factory()
        future.set_result(result)
        cleanup_task.cancel()
        return result
    except Exception as e:
        future.set_exception(e)
        cleanup_task.cancel()
        raise
    finally:
        _request_dedup.pop(hkey, None)


# ===================================================================
# /v1/messages endpoint with failover loop
# ===================================================================

@app.post("/v1/messages")
async def messages(request: Request):
    body = await request.json()
    claude_model = body.get("model", "claude-sonnet-4-6")

    # --- Rate limit check ---
    if not _rate_limiter.allow():
        _metrics["rate_limit_exceeded"] += 1
        logger.warning("Rate limit exceeded")
        return JSONResponse(
            status_code=429,
            content={
                "type": "error",
                "error": {"type": "rate_limit_error", "message": "Rate limit exceeded. Try again later."},
            },
        )

    # --- Health probe ---
    if is_health_probe(body):
        _metrics["health_probes"] += 1
        logger.info("Health check probe -> responding locally")
        return JSONResponse(trivial_response(claude_model))

    # --- Trivial query interception ---
    if is_trivial_query(body):
        _metrics["trivial_intercepted"] += 1
        logger.info("Trivial query -> responding locally (max_tokens=%d, msgs=%d)",
                     body.get("max_tokens"), len(body.get("messages", [])))
        return JSONResponse(trivial_response(claude_model))

    # --- Determine provider order (with smart routing) ---
    is_stream = body.get("stream", False)
    routed_provider = _apply_routing(claude_model) if FAILOVER_ENABLED and ROUTING_ENABLED else None

    if routed_provider:
        # Routing matched: put routed provider first in failover chain
        provider_order = list(FAILOVER_PROVIDERS)
        if routed_provider in provider_order:
            provider_order.remove(routed_provider)
        provider_order.insert(0, routed_provider)
        logger.info("Route model %s -> provider '%s' (first in chain)", claude_model, routed_provider)
    elif not FAILOVER_ENABLED:
        provider_order = [ACTIVE_PROVIDER]
    else:
        provider_order = list(FAILOVER_PROVIDERS)
        if ACTIVE_PROVIDER not in provider_order:
            provider_order.insert(0, ACTIVE_PROVIDER)

    last_error: Optional[str] = None

    for provider_name in provider_order:
        cb = _get_cb(provider_name)
        if not cb.is_available():
            logger.info("Provider '%s': circuit open, skip", provider_name)
            continue

        p = _providers.get(provider_name)
        if not p:
            logger.warning("Provider '%s': no config, skip", provider_name)
            continue

        backend_model = get_backend_model(claude_model, p.model_map)
        logger.info(
            "[%s] %s %s -> %s  msgs=%d stream=%s tools=%d",
            provider_name, p.api_format, claude_model, backend_model,
            len(body.get("messages", [])),
            body.get("stream"),
            len(body.get("tools", [])),
        )

        _metrics["requests_total"] += 1
        _provider_stats[provider_name]["requests"] += 1
        t0 = time.monotonic()

        try:
            if is_stream:
                result = await _call_provider_stream(p, body, backend_model, claude_model)
            else:
                _metrics["dedup_total"] += 1
                hkey = _dedup_key(body)
                result = await _dedup_wait_or_claim(
                    hkey,
                    lambda: _call_provider_normal(p, body, backend_model, claude_model),
                )

            elapsed = time.monotonic() - t0
            _provider_stats[provider_name]["success"] += 1
            _provider_stats[provider_name]["latencies"].append(elapsed)
            cb.record_success()

            # Audit log
            _audit_logger.info(json.dumps({
                "ts": time.time(),
                "method": "POST",
                "path": "/v1/messages",
                "provider": provider_name,
                "model": claude_model,
                "backend_model": backend_model,
                "stream": is_stream,
                "latency_ms": round(elapsed * 1000),
                "status": "success",
                "failover": provider_name != provider_order[0],
            }))

            if provider_name != provider_order[0]:
                logger.info("Failover: primary='%s' succeeded on fallback='%s'",
                            provider_order[0], provider_name)
            return result

        except ProviderFailover as e:
            _metrics["errors_total"] += 1
            _provider_stats[provider_name]["failure"] += 1
            cb.record_failure()
            last_error = str(e)
            logger.warning("Provider '%s' failed (%s), trying next", provider_name, last_error)
            continue

        except httpx.HTTPStatusError as e:
            elapsed = time.monotonic() - t0
            # 4xx client errors — return to client, don't failover
            if e.response.status_code < 500:
                return _error_response(e.response.status_code,
                                       e.response.text[:500] if e.response else str(e))
            # 5xx — failover eligible
            _metrics["errors_total"] += 1
            _provider_stats[provider_name]["failure"] += 1
            cb.record_failure()
            last_error = f"{provider_name}: HTTP {e.response.status_code}"
            logger.warning("Provider '%s' HTTP %d, trying next", provider_name, e.response.status_code)
            continue

        except Exception as e:
            _metrics["errors_total"] += 1
            _provider_stats[provider_name]["failure"] += 1
            cb.record_failure()
            last_error = f"{provider_name}: {type(e).__name__}: {e}"
            logger.warning("Provider '%s' unexpected error (%s), trying next", provider_name, last_error)
            continue

    return _error_response(
        502,
        last_error or "All providers unavailable",
        proxy_detail=f"All providers failed. Last: {last_error or 'unknown'}",
    )


# ===================================================================
# Provider call wrappers
# ===================================================================

async def _call_provider_normal(p: ProviderConfig, body: dict, backend_model: str, claude_model: str):
    """Call a single provider non-streaming. Raises ProviderFailover on 5xx/network errors."""
    if p.api_format == "anthropic":
        return await _anthropic_passthrough(p, body, backend_model, claude_model)
    else:
        return await _openai_conversion_normal(p, body, backend_model, claude_model)


async def _call_provider_stream(p: ProviderConfig, body: dict, backend_model: str, claude_model: str):
    """Call a single provider streaming. Raises ProviderFailover on initial connection failure."""
    if p.api_format == "anthropic":
        return await _anthropic_passthrough(p, body, backend_model, claude_model)
    else:
        return await _openai_conversion_stream(p, body, backend_model, claude_model)


# ===================================================================
# Eager stream connection (for streaming failover)
# ===================================================================

async def _connect_anthropic_stream(p: ProviderConfig, backend_payload: dict) -> httpx.Response:
    """Eagerly establish an Anthropic streaming connection.
    Returns connected httpx.Response on success (2xx).
    Raises ProviderFailover on connection error or 5xx."""
    url = f"{p.api_base_anthropic.rstrip('/')}/messages"
    hdr = p.build_auth_header()
    request = get_client().build_request("POST", url, json=backend_payload, headers=hdr)
    try:
        response = await get_client().send(request, stream=True)
    except (httpx.ConnectError, httpx.TimeoutException, httpx.RemoteProtocolError) as e:
        raise ProviderFailover(f"{p.name}: {type(e).__name__}: {e}")
    if response.status_code >= 500:
        error_body = await response.aread()
        err_text = error_body.decode()[:300]
        await response.aclose()
        raise ProviderFailover(f"{p.name}: HTTP {response.status_code}: {err_text}")
    return response


async def _connect_openai_stream(p: ProviderConfig, oai_payload: dict) -> httpx.Response:
    """Eagerly establish an OpenAI streaming connection.
    Returns connected httpx.Response on success (2xx).
    Raises ProviderFailover on connection error or 5xx."""
    url = f"{p.api_base.rstrip('/')}/chat/completions"
    hdr = p.build_auth_header()
    request = get_client().build_request("POST", url, json=oai_payload, headers=hdr)
    try:
        response = await get_client().send(request, stream=True)
    except (httpx.ConnectError, httpx.TimeoutException, httpx.RemoteProtocolError) as e:
        raise ProviderFailover(f"{p.name}: {type(e).__name__}: {e}")
    if response.status_code >= 500:
        error_body = await response.aread()
        err_text = error_body.decode()[:300]
        await response.aclose()
        raise ProviderFailover(f"{p.name}: HTTP {response.status_code}: {err_text}")
    return response


# ===================================================================
# Anthropic Native Passthrough
# ===================================================================

def _build_anthropic_payload(body: dict, backend_model: str) -> dict:
    """Build and canonicalize the Anthropic-native request payload."""
    payload = dict(body)
    payload["model"] = backend_model
    payload = _normalize_thinking(payload)
    sort_keys(payload)
    return payload


async def _anthropic_passthrough(p: ProviderConfig, body: dict, backend_model: str, claude_model: str):
    payload = _build_anthropic_payload(body, backend_model)

    is_stream = body.get("stream", False)
    if is_stream:
        # Eagerly connect for streaming failover support
        async with _concurrent_semaphore:
            resp = await _connect_anthropic_stream(p, payload)
        return await _passthrough_stream(p, resp, claude_model)
    else:
        return await _passthrough_normal(p, payload, claude_model)


async def _passthrough_normal(p: ProviderConfig, payload: dict, claude_model: str):
    url = f"{p.api_base_anthropic.rstrip('/')}/messages"
    try:
        async with _concurrent_semaphore:
            resp = await _request_with_retry("POST", url, provider_name=p.name, json=payload)
            resp.raise_for_status()
            data = resp.json()
    except ProviderFailover:
        raise
    except httpx.HTTPStatusError as e:
        if e.response.status_code >= 500:
            raise ProviderFailover(f"{p.name}: HTTP {e.response.status_code}") from e
        detail = e.response.text[:500] if e.response else str(e)
        return _error_response(e.response.status_code if e.response else 502, detail)
    except Exception as e:
        logger.error("[%s] API error: %s", p.name, e)
        raise ProviderFailover(f"{p.name}: {type(e).__name__}: {e}") from e

    if "model" in data:
        data["model"] = claude_model

    # Token tracking
    usage = data.get("usage", {})
    if isinstance(usage, dict):
        _provider_tokens[p.name]["input"] += usage.get("input_tokens", 0)
        _provider_tokens[p.name]["output"] += usage.get("output_tokens", 0)
        _provider_tokens[p.name]["cache_read"] += usage.get("cache_read_input_tokens", 0)

    logger.info("[%s] Passthrough response: model=%s stop=%s usage=%s",
                p.name, data.get("model"), data.get("stop_reason"), usage)
    return JSONResponse(data)


async def _passthrough_stream(p: ProviderConfig, resp: httpx.Response, claude_model: str):
    """Stream an already-connected Anthropic response.
    `resp` must be a 2xx response from _connect_anthropic_stream()."""

    async def generate():
        msg_id = f"msg_{uuid.uuid4().hex[:24]}"
        yielded_start = False
        finish_reason = "end_turn"
        has_content = has_thinking = False
        output_tokens = 0
        input_tokens = 0
        cache_read = 0
        chunk_log = []
        last_ping_time = time.monotonic()

        try:
            async with resp:
                async for raw in resp.aiter_lines():
                    if not raw.startswith("data: "):
                        continue
                    data_str = raw[6:].strip()
                    if data_str == "[DONE]":
                        break
                    try:
                        event = json.loads(data_str)
                    except json.JSONDecodeError:
                        continue

                    etype = event.get("type", "")
                    chunk_log.append(etype)

                    if etype == "message_start":
                        msg = event.get("message", {})
                        msg["model"] = claude_model
                        event["message"] = msg
                        yield _sse("message_start", event)
                        yielded_start = True
                        yield _sse("ping", {"type": "ping"})
                        u = msg.get("usage", {}) or {}
                        input_tokens += u.get("input_tokens", 0)
                        cache_read += u.get("cache_read_input_tokens", 0)

                    elif etype == "content_block_start":
                        cb = event.get("content_block", {})
                        if cb.get("type") == "thinking":
                            has_thinking = True
                        yield _sse("content_block_start", event)

                    elif etype == "content_block_delta":
                        delta = event.get("delta", {})
                        dt = delta.get("type", "")
                        if dt == "text_delta":
                            has_content = True
                            output_tokens += len(delta.get("text", "")) // 4
                        elif dt == "thinking_delta":
                            has_thinking = True
                            output_tokens += len(delta.get("thinking", "")) // 4
                        yield _sse("content_block_delta", event)

                    elif etype == "content_block_stop":
                        yield _sse("content_block_stop", event)

                    elif etype == "message_delta":
                        d = event.get("delta", {})
                        if d.get("stop_reason"):
                            finish_reason = d["stop_reason"]
                        usage = event.get("usage", {}) or {}
                        usage.setdefault("output_tokens", max(output_tokens, 0))
                        event["usage"] = usage
                        yield _sse("message_delta", event)

                    elif etype == "message_stop":
                        yield _sse("message_stop", event)

                    # Stream heartbeat
                    now = time.monotonic()
                    if now - last_ping_time >= STREAM_PING_INTERVAL:
                        yield _sse("ping", {"type": "ping"})
                        last_ping_time = now

        except Exception as e:
            logger.error("[%s] Passthrough stream error: %s", p.name, e)
            if not yielded_start:
                yield _sse("message_start", {
                    "type": "message_start",
                    "message": {
                        "id": msg_id, "type": "message", "role": "assistant",
                        "content": [], "model": claude_model,
                        "stop_reason": None, "stop_sequence": None,
                        "usage": {"input_tokens": 0, "output_tokens": 0},
                    },
                })

        # Token tracking for streaming
        _provider_tokens[p.name]["input"] += input_tokens
        _provider_tokens[p.name]["output"] += output_tokens
        _provider_tokens[p.name]["cache_read"] += cache_read

        logger.info("[%s] Passthrough stream done: stop=%s content=%s thinking=%s (tok in=%d out=%d)",
                    p.name, finish_reason, has_content, has_thinking, input_tokens, output_tokens)

    return StreamingResponse(
        generate(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
        },
    )


# ===================================================================
# OpenAI Conversion Mode
# ===================================================================

async def _openai_conversion_normal(p: ProviderConfig, body: dict, backend_model: str, claude_model: str):
    oai_payload = _anthropic_to_openai(body, backend_model)
    url = f"{p.api_base.rstrip('/')}/chat/completions"
    try:
        async with _concurrent_semaphore:
            resp = await _request_with_retry("POST", url, provider_name=p.name, json=oai_payload)
            resp.raise_for_status()
            data = resp.json()
    except ProviderFailover:
        raise
    except httpx.HTTPStatusError as e:
        if e.response.status_code >= 500:
            raise ProviderFailover(f"{p.name}: HTTP {e.response.status_code}") from e
        return _error_response(e.response.status_code if e.response else 502,
                               e.response.text[:500] if e.response else str(e))
    except Exception as e:
        logger.error("[%s] API error: %s", p.name, e)
        raise ProviderFailover(f"{p.name}: {type(e).__name__}: {e}") from e

    logger.info("[%s] OpenAI response: %s", p.name, json.dumps(data, ensure_ascii=False)[:300])

    choice = data.get("choices", [{}])[0]
    msg = choice.get("message", {})
    content_text = msg.get("content", "") or ""
    reasoning_text = msg.get("reasoning_content", "") or ""

    anthropic_content = []
    if not content_text and reasoning_text:
        anthropic_content.append({"type": "text", "text": f"[thinking]{reasoning_text}[/thinking]"})
    elif content_text:
        anthropic_content.append({"type": "text", "text": content_text})
    else:
        anthropic_content.append({"type": "text", "text": ""})

    stop_reason = "end_turn"
    if msg.get("tool_calls"):
        for tc in msg["tool_calls"]:
            fn = tc.get("function", {})
            try:
                inp = json.loads(fn.get("arguments", "{}"))
            except json.JSONDecodeError:
                inp = {}
            anthropic_content.append({
                "type": "tool_use",
                "id": tc.get("id", f"toolu_{uuid.uuid4().hex[:22]}"),
                "name": fn.get("name", ""),
                "input": inp,
            })
        stop_reason = "tool_use"

    usage = data.get("usage", {})
    # Token tracking
    _provider_tokens[p.name]["input"] += usage.get("prompt_tokens", 0)
    _provider_tokens[p.name]["output"] += usage.get("completion_tokens", 0)
    # OpenAI non-streaming doesn't expose cache_read

    return JSONResponse({
        "id": f"msg_{uuid.uuid4().hex[:24]}",
        "type": "message",
        "role": "assistant",
        "content": anthropic_content,
        "model": claude_model,
        "stop_reason": stop_reason,
        "stop_sequence": None,
        "usage": {
            "input_tokens": usage.get("prompt_tokens", 0),
            "output_tokens": usage.get("completion_tokens", 0),
        },
    })


async def _openai_conversion_stream(p: ProviderConfig, body: dict, backend_model: str, claude_model: str):
    oai_payload = _anthropic_to_openai(body, backend_model)
    # Eagerly connect for streaming failover support
    async with _concurrent_semaphore:
        resp = await _connect_openai_stream(p, oai_payload)
    return StreamingResponse(
        _generate_openai_stream(p, resp, oai_payload, claude_model),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "Connection": "keep-alive", "X-Accel-Buffering": "no"},
    )


async def _generate_openai_stream(p: ProviderConfig, resp: httpx.Response, oai_payload: dict, claude_model: str):
    """Stream an already-connected OpenAI response.
    `resp` must be a 2xx response from _connect_openai_stream()."""
    msg_id = f"msg_{uuid.uuid4().hex[:24]}"
    input_tokens = sum(len(m.get("content", "") or "") // 4 for m in oai_payload.get("messages", []))
    output_tokens = 0
    finish_reason = "end_turn"
    tool_calls_buffer = {}
    text_emitted = False
    reasoning_buf = []
    last_ping_time = time.monotonic()

    yield _sse("message_start", {
        "type": "message_start",
        "message": {
            "id": msg_id, "type": "message", "role": "assistant",
            "content": [], "model": claude_model,
            "stop_reason": None, "stop_sequence": None,
            "usage": {"input_tokens": input_tokens, "output_tokens": 0},
        },
    })
    yield _sse("ping", {"type": "ping"})
    yield _sse("content_block_start", {
        "type": "content_block_start", "index": 0,
        "content_block": {"type": "text", "text": ""},
    })

    try:
        async with resp:
            if resp.status_code != 200:
                error_body = await resp.aread()
                err_text = error_body.decode()[:500]
                logger.error("[%s] OpenAI HTTP %d: %s", p.name, resp.status_code, err_text)
                yield _sse("content_block_delta", {
                    "type": "content_block_delta", "index": 0,
                    "delta": {"type": "text_delta", "text": f"[API Error {resp.status_code}]"},
                })
            else:
                async for line in resp.aiter_lines():
                    if not line.startswith("data: "):
                        continue
                    data_str = line[6:].strip()
                    if data_str == "[DONE]":
                        break
                    try:
                        chunk = json.loads(data_str)
                    except json.JSONDecodeError:
                        continue

                    choices = chunk.get("choices", [])
                    if not choices:
                        continue

                    choice = choices[0]
                    delta = choice.get("delta", {})
                    fr = choice.get("finish_reason")

                    content = delta.get("content", "")
                    if content:
                        text_emitted = True
                        output_tokens += 1
                        yield _sse("content_block_delta", {
                            "type": "content_block_delta", "index": 0,
                            "delta": {"type": "text_delta", "text": content},
                        })

                    reasoning = delta.get("reasoning_content", "")
                    if reasoning:
                        reasoning_buf.append(reasoning)
                        output_tokens += 1

                    if delta.get("tool_calls"):
                        for tc_delta in delta["tool_calls"]:
                            tc_idx = tc_delta.get("index", 0)
                            if tc_idx not in tool_calls_buffer:
                                tool_calls_buffer[tc_idx] = {
                                    "id": tc_delta.get("id", f"toolu_{uuid.uuid4().hex[:22]}"),
                                    "name": "",
                                    "arguments_str": "",
                                }
                            fn_delta = tc_delta.get("function", {})
                            if fn_delta.get("name"):
                                tool_calls_buffer[tc_idx]["name"] = fn_delta["name"]
                            if fn_delta.get("arguments"):
                                tool_calls_buffer[tc_idx]["arguments_str"] += fn_delta["arguments"]

                    if fr == "tool_calls":
                        finish_reason = "tool_use"

                    # Stream heartbeat
                    now = time.monotonic()
                    if now - last_ping_time >= STREAM_PING_INTERVAL:
                        yield _sse("ping", {"type": "ping"})
                        last_ping_time = now

    except Exception as e:
        logger.error("[%s] OpenAI stream error: %s", p.name, e)
        yield _sse("content_block_delta", {
            "type": "content_block_delta", "index": 0,
            "delta": {"type": "text_delta", "text": f"[Proxy Error: {e}]"},
        })

    # Token tracking for streaming
    _provider_tokens[p.name]["input"] += input_tokens
    _provider_tokens[p.name]["output"] += output_tokens
    # OpenAI doesn't expose cache_read in stream, approximate as 0

    if not text_emitted and reasoning_buf:
        yield _sse("content_block_delta", {
            "type": "content_block_delta", "index": 0,
            "delta": {"type": "text_delta", "text": f"[thinking]{''.join(reasoning_buf)}[/thinking]"},
        })

    yield _sse("content_block_stop", {"type": "content_block_stop", "index": 0})

    if tool_calls_buffer:
        for tc_idx in sorted(tool_calls_buffer.keys()):
            tc = tool_calls_buffer[tc_idx]
            block_index = 1 + tc_idx
            try:
                inp = json.loads(tc["arguments_str"])
            except json.JSONDecodeError:
                inp = {}
            yield _sse("content_block_start", {
                "type": "content_block_start", "index": block_index,
                "content_block": {"type": "tool_use", "id": tc["id"], "name": tc["name"], "input": {}},
            })
            yield _sse("content_block_delta", {
                "type": "content_block_delta", "index": block_index,
                "delta": {"type": "input_json_delta",
                          "partial_json": json.dumps(inp, ensure_ascii=False)},
            })
            yield _sse("content_block_stop", {"type": "content_block_stop", "index": block_index})
        finish_reason = "tool_use"

    yield _sse("message_delta", {
        "type": "message_delta",
        "delta": {"stop_reason": finish_reason, "stop_sequence": None},
        "usage": {"output_tokens": max(output_tokens, 1)},
    })
    yield _sse("message_stop", {"type": "message_stop"})

    logger.info("[%s] OpenAI stream done: stop=%s text=%s reasoning=%d tools=%d in=%d out=%d",
                p.name, finish_reason, text_emitted, len(reasoning_buf),
                len(tool_calls_buffer), input_tokens, output_tokens)


# ===================================================================
# Format conversion helpers (shared, stateless)
# ===================================================================

def _anthropic_to_openai(body: dict, backend_model: str) -> dict:
    oai_messages = []
    body = _normalize_thinking(body)

    system_text = body.get("system", "")
    if isinstance(system_text, list):
        system_text = "\n".join(
            p.get("text", "") for p in system_text
            if isinstance(p, dict) and p.get("type") == "text"
        )
    if system_text:
        oai_messages.append({"role": "system", "content": system_text})

    for msg in body.get("messages", []):
        role = msg["role"]
        content = msg["content"]

        if role == "assistant":
            if isinstance(content, list):
                text_parts, tool_calls = [], []
                for part in content:
                    if isinstance(part, dict):
                        pt = part.get("type", "")
                        if pt == "text":
                            text_parts.append(part.get("text", ""))
                        elif pt == "tool_use":
                            tool_calls.append({
                                "id": part.get("id", str(uuid.uuid4())),
                                "type": "function",
                                "function": {
                                    "name": part.get("name", ""),
                                    "arguments": json.dumps(part.get("input", {}), ensure_ascii=False),
                                },
                            })
                        elif pt == "thinking":
                            text_parts.append(f"[thinking]{part.get('thinking', '')}[/thinking]")
                oai_msg = {"role": "assistant"}
                oai_msg["content"] = "\n".join(text_parts) if text_parts else ""
                if tool_calls:
                    oai_msg["tool_calls"] = tool_calls
                oai_messages.append(oai_msg)
            else:
                oai_messages.append({"role": "assistant", "content": str(content) if content else ""})

        elif role == "user":
            if isinstance(content, list):
                text_parts = []
                for part in content:
                    if isinstance(part, dict):
                        pt = part.get("type", "")
                        if pt == "text":
                            text_parts.append(part.get("text", ""))
                        elif pt == "tool_result":
                            oai_messages.append(_tool_result_to_openai(part))
                    else:
                        text_parts.append(str(part))
                if text_parts:
                    oai_messages.append({"role": "user", "content": "\n".join(text_parts)})
            else:
                oai_messages.append({"role": "user", "content": str(content)})

        elif role in ("tool_use", "tool"):
            text = _extract_text(content)
            tool_id = msg.get("id") or msg.get("tool_use_id", "")
            oai_messages.append({"role": "tool", "tool_call_id": tool_id, "content": text})
        else:
            text = _extract_text(content)
            oai_messages.append({"role": role, "content": text})

    oai_payload = {
        "model": backend_model,
        "messages": oai_messages,
        "max_tokens": min(body.get("max_tokens", MAX_TOKENS_DEFAULT), OUTPUT_MAX_TOKENS),
        "stream": body.get("stream", False),
    }
    if body.get("temperature") is not None:
        oai_payload["temperature"] = body["temperature"]
    if body.get("top_p") is not None:
        oai_payload["top_p"] = body["top_p"]
    if body.get("tool_choice"):
        oai_payload["tool_choice"] = _map_tool_choice(body["tool_choice"])
    if body.get("tools"):
        oai_payload["tools"] = [
            {"type": "function", "function": {
                "name": t.get("name", ""),
                "description": t.get("description", ""),
                "parameters": t.get("input_schema", {}),
            }}
            for t in body["tools"]
        ]

    sort_keys(oai_payload)
    return oai_payload


def _tool_result_to_openai(part: dict) -> dict:
    tool_id = part.get("tool_use_id", "")
    rc = part.get("content", "")
    if isinstance(rc, list):
        rc = "\n".join(p.get("text", "") for p in rc if isinstance(p, dict) and p.get("type") == "text")
    elif not isinstance(rc, str):
        rc = str(rc)
    rc = _truncate_tool_content(rc)
    return {"role": "tool", "tool_call_id": tool_id, "content": rc}


def _extract_text(content) -> str:
    if isinstance(content, list):
        return "\n".join(p.get("text", str(p)) if isinstance(p, dict) else str(p) for p in content)
    return str(content)


# ===================================================================
# Endpoints
# ===================================================================

@app.get("/v1/models")
async def list_models():
    """Health check — models list that Claude Desktop recognises."""
    global _models_cache, _models_cache_ts
    now = time.time()
    if _models_cache is not None and (now - _models_cache_ts) < _MODELS_CACHE_TTL:
        return JSONResponse(_models_cache)

    logger.info("GET /v1/models (health check)")
    model_ids = [
        "claude-opus-4-7", "claude-sonnet-4-6", "claude-haiku-4-6",
        "claude-opus-4-20250514", "claude-sonnet-4-20250514", "claude-haiku-4-20250514",
    ]
    ts = int(now)
    models = [{"id": m, "object": "model", "created": ts, "owned_by": "anthropic"} for m in model_ids]
    _models_cache = {"object": "list", "data": models}
    _models_cache_ts = now
    return JSONResponse(_models_cache)


@app.get("/health")
async def health():
    """Health check endpoint for load balancers."""
    return JSONResponse({"status": "ok", "provider": ACTIVE_PROVIDER, "format": "multi"})


@app.get("/metrics")
async def metrics():
    """Real-time proxy metrics and provider health overview."""
    now = time.time()
    uptime = now - _metrics["started_at"]

    # Build per-provider summary from circuit breakers
    providers_summary = {}
    for pname, pcfg in _providers.items():
        cb = _get_cb(pname)
        stats = _provider_stats.get(pname, {"requests": 0, "success": 0, "failure": 0, "latencies": []})
        latencies = stats["latencies"]
        avg_latency = (sum(latencies) / len(latencies)) * 1000 if latencies else 0
        providers_summary[pname] = {
            "state": cb.state,
            "format": pcfg.api_format,
            "requests": stats["requests"],
            "success": stats["success"],
            "failure": stats["failure"],
            "cb_success": cb.total_success,
            "cb_failure": cb.total_failure,
            "avg_latency_ms": round(avg_latency, 1),
        }

    # Token tracking summary
    tokens_summary = {}
    for pname in _providers:
        t = _provider_tokens.get(pname, {"input": 0, "output": 0, "cache_read": 0})
        tokens_summary[pname] = {
            "input": t["input"],
            "output": t["output"],
            "cache_read": t["cache_read"],
            "total": t["input"] + t["output"] + t["cache_read"],
        }

    return JSONResponse({
        "version": "v13",
        "uptime_sec": round(uptime),
        "provider": ACTIVE_PROVIDER,
        "failover": FAILOVER_ENABLED,
        "routing": ROUTING_ENABLED,
        "providers": providers_summary,
        "rate_limiter": {
            "capacity": _rate_limiter.capacity,
            "tokens": round(_rate_limiter.tokens, 1),
            "refill_rate": round(_rate_limiter.refill_rate, 2),
        },
        "dedup": {
            "total": _metrics["dedup_total"],
            "hits": _metrics["dedup_hits"],
            "in_flight": len(_request_dedup),
        },
        "requests": {
            "total": _metrics["requests_total"],
            "trivial_intercepted": _metrics["trivial_intercepted"],
            "health_probes": _metrics["health_probes"],
            "errors": _metrics["errors_total"],
            "rate_limit_exceeded": _metrics["rate_limit_exceeded"],
        },
        "tokens": tokens_summary,
        "circuit_breakers": {
            pname: {"state": cb.state, "failures": cb.failure_count,
                    "total_ok": cb.total_success, "total_err": cb.total_failure}
            for pname, cb in _circuit_breakers.items()
        },
    })


# ---------------------------------------------------------------------------
# JSON key sorter (in-place)
# ---------------------------------------------------------------------------

def sort_keys(obj):
    """Recursively sort all dict keys in-place for canonical cache keys."""
    if isinstance(obj, dict):
        keys = sorted(obj.keys())
        new_obj = {k: obj[k] for k in keys}
        obj.clear()
        obj.update(new_obj)
        for v in obj.values():
            sort_keys(v)
    elif isinstance(obj, list):
        for item in obj:
            sort_keys(item)


# ---------------------------------------------------------------------------
# SSE helper
# ---------------------------------------------------------------------------

def _sse(event: str, data: dict) -> str:
    return f"event: {event}\ndata: {json.dumps(data, ensure_ascii=False)}\n\n"


# ---------------------------------------------------------------------------
# Startup event: launch config watcher
# ---------------------------------------------------------------------------

@app.on_event("startup")
async def _on_startup():
    """Launch background config watcher on startup."""
    asyncio.create_task(_watch_config())
    logger.info("Config hot-reload watcher started (poll interval=5s)")


# ---------------------------------------------------------------------------
# Catch-all
# ---------------------------------------------------------------------------

@app.api_route("/{path:path}", methods=["GET", "POST", "PUT", "DELETE", "OPTIONS"])
async def catch_all(path: str, request: Request):
    logger.info("Catch-all: %s /%s", request.method, path)
    return JSONResponse({"status": "ok"}, status_code=200)


# ---------------------------------------------------------------------------
# Model list helper (for catch-all or future use)
# ---------------------------------------------------------------------------

@app.get("/")
async def root():
    return JSONResponse({
        "service": "Claude Bridge Proxy",
        "version": "v13",
        "provider": ACTIVE_PROVIDER,
        "format": "multi",
        "failover": FAILOVER_ENABLED,
        "routing": ROUTING_ENABLED,
        "endpoints": ["GET /health", "GET /v1/models", "GET /metrics", "POST /v1/messages"],
    })


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    logger.info("Starting Claude Bridge proxy v13 on http://%s:%s", SERVER_HOST, SERVER_PORT)
    logger.info("Provider: %s | Failover: %s | Routing: %s", ACTIVE_PROVIDER, FAILOVER_ENABLED, ROUTING_ENABLED)
    if FAILOVER_ENABLED:
        logger.info("Failover providers: %s (threshold=%d, cooldown=%ds)",
                    FAILOVER_PROVIDERS, FAILOVER_THRESHOLD, FAILOVER_COOLDOWN)
        for pname, p in _providers.items():
            logger.info("  %s: format=%s anthropic=%s base=%s keys=%d models=%d",
                        pname, p.api_format, p.api_base_anthropic or "-",
                        p.api_base or "-", len(p.api_keys), len(p.model_map))
    else:
        p = _providers.get(ACTIVE_PROVIDER)
        if p:
            logger.info("Anthropic base: %s", p.api_base_anthropic)
            logger.info("OpenAI base: %s", p.api_base)
            logger.info("Model map: %s", json.dumps(p.model_map, ensure_ascii=False))
            logger.info("Keys: %d key(s) | RPM: %d | Retry: %d | Tool trunc: %d | Output cap: %d | Ping: %.1fs",
                        len(p.api_keys), RATE_LIMIT_RPM, RETRY_MAX,
                        TOOL_RESULT_MAX_CHARS, OUTPUT_MAX_TOKENS, STREAM_PING_INTERVAL)
    uvicorn.run(app, host=SERVER_HOST, port=SERVER_PORT)
