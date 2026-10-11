#!/usr/bin/env python3
"""TensorFold Home gateway.

A stable OpenAI/Anthropic-compatible port (default 127.0.0.1:8484) in front of the TensorFold engine, for TensorFold Home,
Hermes, Open WebUI and any other client. It
- starts the engine on the first generation request and, depending on the memory mode, stops it after IDLE_MINUTES idle;
- answers /v1/models itself with one model id (SERVED_NAME) and its context window (Hermes checks its 64K floor there);
- rewrites any requested model name to SERVED_NAME, so clients keep working when the loaded model changes;
- fills sampling fields a client leaves out from the shared defaults (TensorFold Home's "Use for other apps too");
- streams replies through unchanged while recording each request's tokens, cache reuse, prefill and decode speed, time to
  first token and drafts, which /tf/metrics and /tf/perf serve to TensorFold Home's Monitor;
- can listen on the network, where other computers must send the API key (requests from this Mac never need it).
"""
import collections
import hmac
import http.client
import json
import os
import re
import socketserver
import subprocess
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.environ.get("TF_LAUNCHER_ROOT") or os.path.expanduser("~/Library/Application Support/TensorFoldLauncher")
STATE = os.path.join(ROOT, "state")
TFCTL = os.path.join(ROOT, "bin", "tfctl")
PERF_FILE = os.path.join(STATE, "perf", "requests.jsonl")
DEFAULTS_FILE = os.path.join(STATE, "sampling_defaults.json")
KEY_FILE = os.path.join(STATE, "api_key")
ENGINE_LOG = os.path.join(ROOT, "logs", "engine.log")
ENGINE_LABEL = os.environ.get("TF_ENGINE_LABEL", "com.tensorfold.engine")  # tests use their own
IDLE_CHECK_S = float(os.environ.get("TF_IDLE_CHECK_S", 20))
START_TIMEOUT = 300
HISTORY = 120  # seconds of 1 s samples
HOP_BY_HOP = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailer", "trailers",
              "transfer-encoding", "upgrade", "host", "content-length"}
WAKE_METHODS = {"POST", "PUT", "PATCH"}
OPENAI_STREAMS = ("/v1/chat/completions", "/v1/completions", "/chat/completions", "/completions")
SAMPLING_KEYS = ("temperature", "top_p", "top_k", "max_tokens", "seed", "reasoning_effort")


# ------------------------------------------------------------------------------------------------ configuration

_cfg_cache = {"key": None, "value": None}


def _mtime(path):
    try:
        return os.stat(path).st_mtime_ns
    except OSError:
        return 0


def read_config():
    """config.env + models.conf, re-read only when either file changes."""
    paths = (os.path.join(ROOT, "config.env"), os.path.join(ROOT, "models.conf"))
    key = tuple(_mtime(p) for p in paths)
    if _cfg_cache["key"] == key:
        return _cfg_cache["value"]
    cfg = {}
    try:
        with open(paths[0]) as fh:
            for line in fh:
                line = line.split("#", 1)[0].strip()
                if "=" in line:
                    k, v = line.split("=", 1)
                    cfg[k.strip()] = v.strip().strip('"').strip("'")
    except OSError:
        pass
    models = {}
    try:
        with open(paths[1]) as fh:
            for line in fh:
                if line.strip() and not line.lstrip().startswith("#"):
                    k, label, engine, repo = (line.rstrip("\n").split("|") + ["", "", "", ""])[:4]
                    models[k] = {"key": k, "label": label, "engine": engine, "repo": repo}
    except OSError:
        pass
    name = cfg.get("MODEL", "")
    idle = float(cfg.get("IDLE_MINUTES", 30) or 0)
    mode = cfg.get("MEMORY_MODE") or ("idle" if idle > 0 else "always")
    value = {
        "model": models.get(name, {"key": name, "label": name, "engine": "", "repo": ""}),
        "models": list(models.values()),
        "context": int(cfg.get("CONTEXT", 65536) or 65536), "thinking": cfg.get("THINKING", "off"),
        "memory_mode": mode, "idle_minutes": idle, "served_name": cfg.get("SERVED_NAME", "tensorfold"),
        "gateway_port": int(cfg.get("GATEWAY_PORT", 8484)), "engine_port": int(cfg.get("ENGINE_PORT", 18484)),
        "webui_port": int(cfg.get("WEBUI_PORT", 3000)), "endpoint_at_login": cfg.get("ENDPOINT_AT_LOGIN", "1") == "1",
        "share": cfg.get("SHARE_ON_NETWORK", "0") == "1", "require_key": cfg.get("REQUIRE_KEY", "0") == "1",
        "auto_update": cfg.get("AUTO_UPDATE", "1") == "1",
    }
    _cfg_cache.update(key=key, value=value)
    return value


def api_key():
    try:
        with open(KEY_FILE) as fh:
            return fh.read().strip()
    except OSError:
        return ""


def read_json(path, default):
    try:
        with open(path) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return default


def http_get(port, path, timeout=1.5):
    """(status, body bytes) from the engine, or (0, b"") when it does not answer."""
    try:
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
        conn.request("GET", path)
        resp = conn.getresponse()
        body = resp.read()
        conn.close()
        return resp.status, body
    except OSError:
        return 0, b""


def is_loopback(addr):
    return addr in ("::1", "localhost") or addr.startswith("127.") or addr.startswith("::ffff:127.")


def client_name(user_agent):
    ua = (user_agent or "").lower()
    for needle, name in (("tensorfoldhome", "TensorFold Home"), ("aiohttp", "Open WebUI"), ("hermes", "Hermes"),
                         ("anthropic", "Anthropic SDK"), ("openai/python", "OpenAI SDK"), ("openai/js", "OpenAI SDK"),
                         ("curl", "curl"), ("python-urllib", "Python"), ("python-requests", "Python")):
        if needle in ua:
            return name
    return (user_agent or "unknown").split("/")[0][:24] or "unknown"


# ------------------------------------------------------------------------------------------------ engine facts

def engine_version(engine_type):
    try:
        if engine_type == "native":
            out = subprocess.run(["/opt/homebrew/bin/tensorfold", "--version"], capture_output=True, text=True, timeout=10).stdout
            return out.split()[-1] if out.split() else ""
        if engine_type == "tf06":
            import importlib.metadata as md
            dist = md.distribution("tensorfold")
            direct = json.loads(dist.read_text("direct_url.json") or "{}")
            commit = (direct.get("vcs_info") or {}).get("commit_id", "")[:7]
            return f"{dist.version}+{commit}" if commit else dist.version
    except Exception:
        pass
    return ""


def engine_facts():
    """What the engine printed at its last start: load time, context, drafts, weights, prompt cache, concurrency."""
    facts = {}
    try:
        with open(ENGINE_LOG, "rb") as fh:
            fh.seek(0, 2)
            size = fh.tell()
            fh.seek(max(0, size - 400_000))
            text = fh.read().decode("utf-8", "replace")
    except OSError:
        return facts
    start = text.rfind("tf-engine: ")
    if start < 0:
        return facts
    block = text[start:]
    patterns = {
        "serving": r"serving \S+ at \S+ \(sampling: ([^;]+); drafts: (\w+); context: (\d+); loaded in ([\d.]+)s\)",
        "weights_gib": r"([\d.]+) GiB of weights kept resident",
        "prompt_cache_gib": r"prompt cache(?: up to)? ([\d.]+) GiB",
        "concurrency": r"up to (\d+) requests share each round",
        "memory_budget_gib": r"memory budget ([\d.]+) GiB",
        "decoder": r"(lane decoder without tensor units|native tensor-unit kernels|lane kernels)",
    }
    for name, pat in patterns.items():
        m = re.search(pat, block)
        if not m:
            continue
        if name == "serving":
            facts.update(sampling=m.group(1), drafts=m.group(2) == "on", context=int(m.group(3)), load_seconds=float(m.group(4)))
        elif name in ("concurrency",):
            facts[name] = int(m.group(1))
        elif name == "decoder":
            facts[name] = m.group(1)
        else:
            facts[name] = float(m.group(1))
    snaps = [int(n) for n in re.findall(r"loaded system-block snapshot tokens=(\d+)", block)]
    if snaps:
        facts.update(snapshots=len(snaps), snapshot_tokens=max(snaps))
    if "no draft model" in block:
        facts["drafter"] = "none (drafts copy from the context)"
    m = re.search(r"--drafter\S* (\S+)", block)
    if m:
        facts["drafter"] = m.group(1)
    return facts


_details_cache = {}


def model_details(repo):
    """Quantization, geometry and size of a cached Hugging Face checkpoint (cached per repo once found)."""
    if not repo:
        return {}
    if repo in _details_cache:
        return _details_cache[repo]
    info = _model_details(repo)
    if info.get("cached"):
        _details_cache[repo] = info
    return info


def _model_details(repo):
    base = os.path.expanduser(f"~/.cache/huggingface/hub/models--{repo.replace('/', '--')}/snapshots")
    try:
        snap = sorted(os.listdir(base))[-1]
    except OSError:
        return {"repo": repo, "cached": False}
    path = os.path.join(base, snap)
    cfg = read_json(os.path.join(path, "config.json"), {})
    text = cfg.get("text_config", cfg)
    q = cfg.get("quantization") or cfg.get("quantization_config") or {}
    size = 0
    for name in os.listdir(path):
        try:
            size += os.stat(os.path.join(path, name)).st_size  # follows the snapshot's links into blobs
        except OSError:
            pass
    quant = f"MLX {q['bits']}-bit, group {q.get('group_size', '?')}" if q.get("bits") else "unquantized"
    return {"repo": repo, "cached": True, "revision": snap[:12], "quantization": quant, "model_type": cfg.get("model_type", ""),
            "layers": text.get("num_hidden_layers"), "hidden_size": text.get("hidden_size"),
            "max_position_embeddings": text.get("max_position_embeddings"), "size_gb": round(size / 1e9, 2)}


def launchd_engine():
    """(loaded, running, pid, last_exit) of the engine's launchd job."""
    try:
        out = subprocess.run(["/bin/launchctl", "print", f"gui/{os.getuid()}/{ENGINE_LABEL}"],
                             capture_output=True, text=True, timeout=5)
    except Exception:
        return False, False, None, None
    if out.returncode != 0:
        return False, False, None, None
    text = out.stdout
    pid = re.search(r"^\s*pid = (\d+)", text, re.M)
    state = re.search(r"^\s*state = (\w+)", text, re.M)
    last = re.search(r"last exit code = (-?\d+)", text)
    return True, bool(state and state.group(1) == "running"), int(pid.group(1)) if pid else None, \
        int(last.group(1)) if last else None


# ------------------------------------------------------------------------------------------------ live state + records

class Live:
    """One request in flight: reading (no token yet) or generating."""

    def __init__(self, path, client, stream):
        self.id = uuid.uuid4().hex[:12]
        self.path, self.client, self.stream = path, client, stream
        self.start = time.time()
        self.loading = False
        self.first_token = None
        self.generated = 0
        self.marks = collections.deque(maxlen=64)  # (t, generated)
        self.usage, self.tf, self.spec, self.finish = {}, {}, {}, None
        self.thinking = None

    def token(self, n=1):
        now = time.time()
        if self.first_token is None:
            self.first_token = now
        self.generated += n
        self.marks.append((now, self.generated))

    def rate(self):
        """Tokens per second over the last ~2 s."""
        now = time.time()
        pts = [m for m in self.marks if now - m[0] <= 2.0]
        if len(pts) >= 2 and pts[-1][0] > pts[0][0]:
            return (pts[-1][1] - pts[0][1]) / (pts[-1][0] - pts[0][0])
        if self.first_token and self.generated > 1 and now > self.first_token:
            return (self.generated - 1) / (now - self.first_token)
        return 0.0

    def state(self):
        if self.loading:
            return "loading"
        return "generating" if self.first_token else "reading"

    def snapshot(self):
        return {"id": self.id, "path": self.path, "client": self.client, "state": self.state(),
                "elapsed_s": round(time.time() - self.start, 2), "generated": self.generated, "tok_s": round(self.rate(), 2)}


def scan_event(ev, live):
    """Pull usage, TensorFold stats, drafts, finish and token deltas out of one JSON reply or SSE event."""
    if not isinstance(ev, dict):
        return
    for holder in (ev, ev.get("message"), ev.get("response")):
        if not isinstance(holder, dict):
            continue
        if isinstance(holder.get("usage"), dict):
            live.usage.update({k: v for k, v in holder["usage"].items() if v is not None})
        if isinstance(holder.get("tensorfold"), dict):
            live.tf.update(holder["tensorfold"])
        if isinstance(holder.get("speculative"), dict):
            live.spec.update(holder["speculative"])
    choices = ev.get("choices")
    if isinstance(choices, list):
        for ch in choices:
            if not isinstance(ch, dict):
                continue
            if ch.get("finish_reason"):
                live.finish = ch["finish_reason"]
            delta = ch.get("delta")
            if isinstance(delta, dict) and (delta.get("content") or delta.get("reasoning_content") or delta.get("reasoning")):
                live.token()
            elif isinstance(ch.get("text"), str) and ch["text"] and ev.get("object") == "text_completion":
                live.token()
    etype = ev.get("type", "")
    if etype == "content_block_delta":
        d = ev.get("delta") or {}
        if d.get("text") or d.get("thinking"):
            live.token()
    elif etype == "message_delta":
        if (ev.get("delta") or {}).get("stop_reason"):
            live.finish = ev["delta"]["stop_reason"]
    elif etype in ("response.output_text.delta", "response.reasoning_text.delta", "response.reasoning_summary_text.delta"):
        live.token()
    elif etype in ("response.completed", "response.incomplete"):
        live.finish = (ev.get("response") or {}).get("status") or etype.split(".")[-1]


class Recorder:
    """Live requests, the last 200 finished ones, totals, a 2-minute history and the per-version perf log."""

    def __init__(self):
        self.lock = threading.Lock()
        self.live = {}
        self.requests = collections.deque(maxlen=200)
        self.totals = {"since": time.time(), "requests": 0, "prompt_tokens": 0, "cached_tokens": 0, "output_tokens": 0,
                       "prefill_s": 0.0, "decode_s": 0.0}
        self.history = {k: collections.deque(maxlen=HISTORY) for k in ("t", "tok_s", "prefill_tok_s", "inflight")}
        self.last_prefill = None

    def begin(self, live):
        with self.lock:
            self.live[live.id] = live

    def finish(self, live, status, cfg, version, error=None, cancelled=False):
        with self.lock:
            self.live.pop(live.id, None)
        u, tf, sp = live.usage, live.tf, live.spec
        prompt = u.get("prompt_tokens", u.get("input_tokens"))
        details = u.get("prompt_tokens_details") or u.get("input_tokens_details") or {}
        cached = details.get("cached_tokens", u.get("cache_read_input_tokens", 0)) or 0
        output = u.get("completion_tokens", u.get("output_tokens"))
        if output is None and live.generated:
            output = live.generated
        end = time.time()
        ttft = tf.get("time_to_first_token") or (live.first_token - live.start if live.first_token else None)
        prefill_s = tf.get("prefill_seconds")
        decode = tf.get("tokens_per_second")
        if not decode and live.first_token and output and output > 1 and end > live.first_token:
            decode = (output - 1) / (end - live.first_token)
        read = max(0, (prompt or 0) - cached)
        prefill = read / prefill_s if prefill_s and read else (read / ttft if ttft and read else None)
        finish = "error" if error else "cancel" if cancelled else (live.finish or ("stop" if 200 <= status < 300 else "error"))
        rec = {
            "id": live.id, "time": end, "start": live.start, "path": live.path, "client": live.client, "stream": live.stream,
            "status": status, "finish": finish, "error": error,
            "prompt_tokens": prompt, "cached_tokens": cached, "output_tokens": output,
            "reasoning_tokens": (u.get("completion_tokens_details") or {}).get("reasoning_tokens"),
            "ttft_s": round(ttft, 3) if ttft else None, "prefill_s": round(prefill_s, 3) if prefill_s else None,
            "prefill_tok_s": round(prefill, 1) if prefill else None, "decode_tok_s": round(decode, 2) if decode else None,
            "duration_s": round(end - live.start, 2), "drafted": sp.get("drafted"), "accepted": sp.get("accepted"),
            "thinking": tf.get("enable_thinking"), "effort": tf.get("reasoning_effort"),
            "model": cfg["model"]["key"], "model_label": cfg["model"]["label"], "engine": cfg["model"]["engine"],
            "engine_version": version,
        }
        if prompt is None and output is None and finish != "error":
            return rec  # nothing generated (a probe, or a request without a body we understand)
        with self.lock:
            self.requests.appendleft(rec)
            t = self.totals
            t["requests"] += 1
            t["prompt_tokens"] += prompt or 0
            t["cached_tokens"] += cached or 0
            t["output_tokens"] += output or 0
            if prefill_s:
                t["prefill_s"] += prefill_s
            if decode and output:
                t["decode_s"] += output / decode
            if prefill:
                self.last_prefill = prefill
        if 200 <= status < 300 and (output or 0) > 0:
            try:
                os.makedirs(os.path.dirname(PERF_FILE), exist_ok=True)
                with open(PERF_FILE, "a") as fh:
                    fh.write(json.dumps({k: rec[k] for k in ("time", "model", "model_label", "engine", "engine_version",
                                                             "prompt_tokens", "cached_tokens", "output_tokens",
                                                             "prefill_s", "decode_tok_s", "ttft_s")}) + "\n")
            except OSError:
                pass
        return rec

    def sample(self):
        with self.lock:
            lives = list(self.live.values())
        rate = sum(l.rate() for l in lives if l.first_token)
        h = self.history
        h["t"].append(round(time.time(), 1))
        h["tok_s"].append(round(rate, 2))
        h["prefill_tok_s"].append(round(self.last_prefill or 0, 1))
        h["inflight"].append(len(lives))

    def snapshot(self, engine_metrics):
        with self.lock:
            lives = [l.snapshot() for l in self.live.values()]
            reqs = list(self.requests)
            totals = dict(self.totals)
            hist = {k: list(v) for k, v in self.history.items()}
        waiting = int(engine_metrics.get("requests_waiting", 0) or 0)
        states = [l["state"] for l in lives]
        state = ("loading" if "loading" in states else "queued" if waiting > 0 else "reading" if "reading" in states
                 else "generating" if "generating" in states else "idle")
        main = next((l for l in lives if l["state"] == "generating"), lives[0] if lives else None)
        live = {"state": state, "requests": lives, "queued": waiting, "running": len(lives),
                "generated": main["generated"] if main else 0, "tok_s": round(sum(l["tok_s"] for l in lives), 2),
                "elapsed_s": main["elapsed_s"] if main else 0}
        return {"live": live, "requests": reqs, "requests_kept": len(reqs), "totals": totals, "history": hist}


def perf_summaries():
    """Prefill and decode averages per (engine version, model), newest version first, weighted by tokens."""
    groups = {}
    try:
        with open(PERF_FILE) as fh:
            for line in fh:
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                key = (r.get("engine_version") or "", r.get("model") or "")
                g = groups.setdefault(key, {"version": key[0], "model": key[1], "model_label": r.get("model_label") or key[1],
                                            "engine": r.get("engine") or "", "requests": 0, "read": 0, "prefill_s": 0.0,
                                            "out": 0, "decode_s": 0.0, "first": r.get("time", 0), "last": r.get("time", 0)})
                g["requests"] += 1
                g["last"] = max(g["last"], r.get("time", 0))
                read = max(0, (r.get("prompt_tokens") or 0) - (r.get("cached_tokens") or 0))
                if r.get("prefill_s") and read:
                    g["read"] += read
                    g["prefill_s"] += r["prefill_s"]
                out = r.get("output_tokens") or 0
                if r.get("decode_tok_s") and out:
                    g["out"] += out
                    g["decode_s"] += out / r["decode_tok_s"]
    except OSError:
        pass
    rows = []
    for g in groups.values():
        rows.append({"version": g["version"], "model": g["model"], "model_label": g["model_label"], "engine": g["engine"],
                     "requests": g["requests"], "prefill_tok_s": round(g["read"] / g["prefill_s"], 1) if g["prefill_s"] else None,
                     "decode_tok_s": round(g["out"] / g["decode_s"], 2) if g["decode_s"] else None, "last_used": g["last"]})
    rows.sort(key=lambda r: r["last_used"], reverse=True)
    return rows


# ------------------------------------------------------------------------------------------------ the engine

class Engine:
    """Starts/stops the launchd-managed engine through tfctl, watches its health and idles it out."""

    def __init__(self, recorder):
        self.rec = recorder
        self.lock = threading.Lock()
        self.starting = False
        self.last_activity = time.time()
        self.was_up = False
        self.up_since = None
        self.metrics = {}
        self.launchd = (False, False, None, None)
        self.launchd_at = 0
        self.version = ""
        self.facts = {}
        self.model_info = {}
        self.model_key = None

    def up(self):
        return http_get(read_config()["engine_port"], "/health")[0] == 200

    def launchd_state(self, max_age=2.0):
        if time.time() - self.launchd_at > max_age:
            self.launchd = launchd_engine()
            self.launchd_at = time.time()
        return self.launchd

    def state(self):
        if self.up():
            return "running"
        loaded, running, _, last_exit = self.launchd_state()
        if self.starting or (loaded and running):
            return "loading"
        if loaded and last_exit not in (None, 0):
            return "error"
        return "stopped"

    def ensure(self):
        if self.up():
            return True
        with self.lock:
            if not self.starting and not self.up():
                self.starting = True
                subprocess.run([TFCTL, "engine", "start", "--no-wait"], capture_output=True, timeout=60)
                self.launchd_at = 0
        deadline = time.time() + START_TIMEOUT
        try:
            while time.time() < deadline:
                if self.up():
                    return True
                loaded, running, _, last_exit = self.launchd_state(max_age=1.0)
                if loaded and not running and last_exit not in (None, 0) and time.time() - deadline + START_TIMEOUT > 15:
                    return False  # it crashed on start
                time.sleep(0.5)
            return False
        finally:
            self.starting = False

    def touch(self):
        self.last_activity = time.time()

    def on_up(self):
        cfg = read_config()
        self.up_since = time.time()
        self.version = engine_version(cfg["model"]["engine"])
        self.facts = engine_facts()
        if self.model_key != cfg["model"]["key"]:
            self.model_info = model_details(cfg["model"]["repo"])
            self.model_key = cfg["model"]["key"]

    def poll_loop(self):
        """Every second: health, engine /metrics, history; every IDLE_CHECK_S (20 s): the idle check."""
        last_idle_check = 0
        while True:
            time.sleep(1)
            try:
                cfg = read_config()
                up = self.up()
                if up and not self.was_up:
                    self.touch()  # started elsewhere (TensorFold Home, tfctl): idle time counts from now
                    self.on_up()
                if not up and self.was_up:
                    self.up_since = None
                    self.metrics = {}
                self.was_up = up
                if up:
                    status, body = http_get(cfg["engine_port"], "/metrics")
                    if status == 200:
                        self.metrics = parse_prometheus(body.decode("utf-8", "replace"))
                self.rec.sample()
                if time.time() - last_idle_check >= IDLE_CHECK_S:
                    last_idle_check = time.time()
                    idle_s = cfg["idle_minutes"] * 60
                    with self.rec.lock:
                        busy = bool(self.rec.live)
                    if up and cfg["memory_mode"] != "always" and idle_s > 0 and not busy and not self.starting \
                            and time.time() - self.last_activity > idle_s:
                        subprocess.run([TFCTL, "engine", "stop"], capture_output=True, timeout=60)
                        self.was_up = False
                        self.up_since = None
                        self.launchd_at = 0
            except Exception as exc:  # keep polling whatever happens
                print(f"tf-gateway: poll failed: {exc}", flush=True)


def parse_prometheus(text):
    out = {}
    for line in text.splitlines():
        if line.startswith("#") or " " not in line:
            continue
        name, _, value = line.rpartition(" ")
        name = name.split("{", 1)[0].replace("tensorfold:", "").replace("vllm:", "")
        if name.endswith("_bucket"):
            continue
        try:
            out[name] = out.get(name, 0) + float(value) if name.endswith(("_sum", "_count", "_total")) else float(value)
        except ValueError:
            pass
    return out


RECORDER = Recorder()
ENGINE = Engine(RECORDER)


# ------------------------------------------------------------------------------------------------ status payloads

def status():
    cfg = read_config()
    state = ENGINE.state()
    idle_s = cfg["idle_minutes"] * 60
    loaded, running, pid, last_exit = ENGINE.launchd_state()
    update = read_json(os.path.join(STATE, "update.json"), None)
    defaults = read_json(DEFAULTS_FILE, None)
    return {
        "gateway": "ok", "engine": state, "engine_pid": pid if running else None, "engine_last_exit": last_exit,
        "engine_version": ENGINE.version if state == "running" else "", "engine_up_since": ENGINE.up_since,
        "engine_facts": ENGINE.facts if state == "running" else {},
        "model": cfg["model"], "models": cfg["models"], "model_info": ENGINE.model_info or model_details(cfg["model"]["repo"]),
        "served_name": cfg["served_name"], "context": cfg["context"], "thinking": cfg["thinking"],
        "memory_mode": cfg["memory_mode"], "idle_minutes": cfg["idle_minutes"],
        "idle_remaining_s": max(0, int(idle_s - (time.time() - ENGINE.last_activity)))
        if state == "running" and idle_s > 0 and cfg["memory_mode"] != "always" else None,
        "inflight": len(RECORDER.live), "endpoint": f"http://127.0.0.1:{cfg['gateway_port']}/v1",
        "gateway_port": cfg["gateway_port"], "engine_port": cfg["engine_port"], "webui_port": cfg["webui_port"],
        "chat_url": f"http://127.0.0.1:{cfg['webui_port']}",
        "dashboard_url": f"http://127.0.0.1:{cfg['gateway_port']}/dashboard" if cfg["model"]["engine"] == "native" else None,
        "webui": "running" if http_get(cfg["webui_port"], "/health", 0.8)[0] == 200 else "stopped",
        "endpoint_at_login": cfg["endpoint_at_login"], "share": cfg["share"], "require_key": cfg["require_key"],
        "key_set": bool(api_key()), "listening": LISTEN_HOST, "auto_update": cfg["auto_update"], "update": update,
        "shared_defaults": defaults.get("defaults") if isinstance(defaults, dict) else None,
    }


def metrics():
    m = RECORDER.snapshot(ENGINE.metrics)
    cfg = read_config()
    em = ENGINE.metrics
    m["engine"] = {"state": ENGINE.state(), "version": ENGINE.version, "model": cfg["model"], "max_context": cfg["context"],
                   "drafted_total": em.get("mtp_drafted_total"), "accepted_total": em.get("mtp_accepted_total"),
                   "kv_cache_usage": em.get("kv_cache_usage_ratio"), "facts": ENGINE.facts}
    return m


def model_entry(cfg):
    return {"id": cfg["served_name"], "object": "model", "created": 0, "owned_by": "tensorfold",
            "name": f"TensorFold · {cfg['model']['label']}", "context_length": cfg["context"],
            "max_model_len": cfg["context"], "context_window": cfg["context"]}


# ------------------------------------------------------------------------------------------------ HTTP

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "TensorFoldGateway/2"

    def log_message(self, fmt, *args):
        if self.path.split("?", 1)[0] in ("/health", "/tf/health", "/tf/status", "/tf/metrics", "/tf/perf", "/tf/settings"):
            return  # polled every second by TensorFold Home
        print(f"tf-gateway: {self.address_string()} {fmt % args}", flush=True)

    def send_json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def read_body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    def authorized(self, cfg):
        if is_loopback(self.client_address[0]):
            return True
        key = api_key()
        if not (cfg["require_key"] and key):
            return True
        sent = self.headers.get("x-api-key") or ""
        auth = self.headers.get("Authorization") or ""
        if auth.lower().startswith("bearer "):
            sent = sent or auth[7:].strip()
        return bool(sent) and hmac.compare_digest(sent, key)

    def handle_any(self):
        path = self.path.split("?", 1)[0].rstrip("/") or "/"
        cfg = read_config()
        if path in ("/health", "/tf/health"):
            return self.send_json(200, {"status": "ok", "engine": ENGINE.state()})
        if path.startswith("/tf/"):
            if not is_loopback(self.client_address[0]):
                return self.send_json(403, {"error": {"message": "TensorFold Home's control endpoints answer this Mac only"}})
            return self.control(path)
        if not self.authorized(cfg):
            return self.send_json(401, {"error": {"message": "Missing or wrong API key. Send it as Authorization: Bearer <key> or x-api-key.",
                                                  "type": "authentication_error"}})
        if self.command == "GET" and path in ("/v1/models", "/models"):
            return self.send_json(200, {"object": "list", "data": [model_entry(cfg)]})
        if self.command == "GET" and (path.startswith("/v1/models/") or path.startswith("/models/")):
            return self.send_json(200, model_entry(cfg))

        body = self.read_body()
        if body and os.path.exists(os.path.join(STATE, "debug")):  # touch state/debug to capture requests
            with open(os.path.join(STATE, "last_request.json"), "wb") as fh:
                fh.write(body)
        doc, strip_usage = None, False
        if body and "json" in (self.headers.get("Content-Type") or "json"):
            try:
                doc = json.loads(body)
            except ValueError:
                doc = None
        stream = False
        if isinstance(doc, dict):
            if "model" in doc:
                doc["model"] = cfg["served_name"]
            stream = bool(doc.get("stream"))
            if self.command == "POST":
                apply_defaults(doc, path)
                if stream and path in OPENAI_STREAMS and not (doc.get("stream_options") or {}).get("include_usage"):
                    doc["stream_options"] = dict(doc.get("stream_options") or {}, include_usage=True)
                    strip_usage = True  # the gateway wants the token counts; the client did not ask for them
            body = json.dumps(doc).encode()

        wake = self.command in WAKE_METHODS
        live = Live(path, client_name(self.headers.get("User-Agent")), stream) if wake else None
        if live:
            RECORDER.begin(live)
            ENGINE.touch()
        try:
            if not ENGINE.up():
                if not wake:  # never load a model for a probe (Hermes/Open WebUI GETs, /dashboard, /metrics ...)
                    return self.send_json(503 if path in ("/dashboard", "/stats", "/metrics") else 404,
                                          {"error": {"message": "TensorFold engine is idle; it starts on the next generation request"}})
                live.loading = True
                ok = ENGINE.ensure()
                live.loading = False
                live.start = time.time()  # the record's timings are the engine's, not the load
                if ok and ENGINE.up_since is None:
                    ENGINE.on_up()  # so this first request is recorded under the right engine version
                    ENGINE.was_up = True
                if not ok:
                    RECORDER.finish(live, 503, cfg, ENGINE.version, error="engine failed to start")
                    live = None
                    return self.send_json(503, {"error": {"message": f"TensorFold engine failed to start; see {ROOT}/logs/engine.log"}})
            status_code, cancelled, error = self.proxy(cfg["engine_port"], body, live, strip_usage)
            if live:
                RECORDER.finish(live, status_code, read_config(), ENGINE.version, error=error, cancelled=cancelled)
                live = None
        finally:
            if live:  # an exception escaped: forget the live entry
                with RECORDER.lock:
                    RECORDER.live.pop(live.id, None)
            if wake:
                ENGINE.touch()

    def control(self, path):
        if path == "/tf/status":
            return self.send_json(200, status())
        if path == "/tf/metrics":
            return self.send_json(200, metrics())
        if path == "/tf/perf":
            return self.send_json(200, {"rows": perf_summaries(), "current_version": ENGINE.version, "file": PERF_FILE})
        if path == "/tf/settings":
            if self.command == "POST":
                try:
                    doc = json.loads(self.read_body() or b"{}")
                except ValueError:
                    return self.send_json(400, {"error": {"message": "invalid JSON"}})
                defaults = doc.get("defaults")
                if defaults is not None:
                    defaults = {k: v for k, v in defaults.items() if k in SAMPLING_KEYS and v is not None}
                os.makedirs(STATE, exist_ok=True)
                with open(DEFAULTS_FILE, "w") as fh:
                    json.dump({"defaults": defaults or None}, fh)
            saved = read_json(DEFAULTS_FILE, {})
            d = saved.get("defaults") if isinstance(saved, dict) else None
            return self.send_json(200, {"shared": bool(d), "defaults": d})
        return self.send_json(404, {"error": {"message": f"unknown path {path}"}})

    def proxy(self, port, body, live, strip_usage):
        """Forward to the engine and stream the reply back. Returns (status, cancelled, error)."""
        headers = {k: v for k, v in self.headers.items() if k.lower() not in HOP_BY_HOP}
        headers["Content-Length"] = str(len(body))
        upstream = http.client.HTTPConnection("127.0.0.1", port, timeout=3600)
        status_code = 502
        try:
            upstream.request(self.command, self.path, body=body, headers=headers)
            resp = upstream.getresponse()
            status_code = resp.status
            streaming = resp.getheader("Content-Length") is None
            self.send_response(resp.status, resp.reason)
            for k, v in resp.getheaders():
                if k.lower() not in HOP_BY_HOP:
                    self.send_header(k, v)
            if not streaming:
                data = resp.read()
                if live:
                    try:
                        scan_event(json.loads(data), live)
                    except ValueError:
                        pass
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
                return status_code, False, None if status_code < 400 else f"HTTP {status_code}"
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            buf, skip_blank = b"", False
            while True:
                chunk = resp.read1(65536)
                if not chunk:
                    break
                buf += chunk
                out = []
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    if skip_blank and line.strip() == b"":
                        skip_blank = False
                        continue
                    skip_blank = False
                    if line.startswith(b"data: {") and live is not None:
                        try:
                            ev = json.loads(line[6:])
                        except ValueError:
                            ev = None
                        if ev is not None:
                            scan_event(ev, live)
                            if strip_usage and ev.get("choices") == [] and "usage" in ev:
                                skip_blank = True
                                continue
                    out.append(line + b"\n")
                if out:
                    payload = b"".join(out)
                    self.wfile.write(b"%x\r\n%s\r\n" % (len(payload), payload))
                    self.wfile.flush()
            if buf:
                self.wfile.write(b"%x\r\n%s\r\n" % (len(buf), buf))
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
            return status_code, False, None
        except (BrokenPipeError, ConnectionResetError):
            self.close_connection = True  # client went away; closing upstream cancels the generation
            return status_code, True, None
        except OSError as exc:
            try:
                self.send_json(502, {"error": {"message": f"TensorFold engine connection failed: {exc}"}})
            except OSError:
                pass
            return 502, False, str(exc)
        finally:
            upstream.close()

    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = do_OPTIONS = handle_any


def apply_defaults(doc, path):
    """Shared sampling defaults, for fields the client did not set itself."""
    saved = read_json(DEFAULTS_FILE, {})
    defaults = saved.get("defaults") if isinstance(saved, dict) else None
    if not defaults:
        return
    if path.endswith("/messages"):
        allowed = ("temperature", "top_p", "top_k")
    elif path.endswith(("/chat/completions", "/completions")):
        allowed = SAMPLING_KEYS
    else:
        return
    for k in allowed:
        if k not in defaults or k in doc:
            continue
        if k == "reasoning_effort" and isinstance(doc.get("chat_template_kwargs"), dict) \
                and "enable_thinking" in doc["chat_template_kwargs"]:
            continue
        doc[k] = defaults[k]


LISTEN_HOST = "127.0.0.1"


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def server_bind(self):
        # HTTPServer.server_bind looks up the host's name (socket.getfqdn), a reverse DNS query that can stall
        # startup for half a minute on a network with slow DNS; nothing here uses the name.
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]


def main():
    global LISTEN_HOST
    cfg = read_config()
    LISTEN_HOST = "0.0.0.0" if cfg["share"] else "127.0.0.1"
    if ENGINE.up():  # an engine that was already running: read its version and facts before the first request
        ENGINE.on_up()
        ENGINE.was_up = True
    threading.Thread(target=ENGINE.poll_loop, daemon=True).start()
    server = Server((LISTEN_HOST, cfg["gateway_port"]), Handler)
    print(f"tf-gateway: serving http://{LISTEN_HOST}:{cfg['gateway_port']}/v1 -> engine :{cfg['engine_port']}"
          f"{' (API key required from other computers)' if cfg['share'] and cfg['require_key'] and api_key() else ''}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
