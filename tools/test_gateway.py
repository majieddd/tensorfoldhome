#!/usr/bin/env python3
"""Offline tests for backend/bin/tf-gateway.py against tools/mock_engine.py.

    python3 -m unittest discover -s tools -p test_gateway.py -v

Everything runs in a temporary root on free ports: no model, no launchd, and the real TensorFold setup is not touched.
"""
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
GATEWAY = os.path.join(HERE, "..", "backend", "bin", "tf-gateway.py")
MOCK = os.path.join(HERE, "mock_engine.py")


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def lan_ip():
    for iface in ("en0", "en1"):
        out = subprocess.run(["ipconfig", "getifaddr", iface], capture_output=True, text=True).stdout.strip()
        if out:
            return out
    return None


class GatewayTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = tempfile.mkdtemp(prefix="tfgw-test-")
        cls.gw_port, cls.eng_port = free_port(), free_port()
        for d in ("bin", "state", "logs", "rec"):
            os.makedirs(os.path.join(cls.root, d))
        cls.write_config()
        with open(os.path.join(cls.root, "models.conf"), "w") as fh:
            fh.write("mock|Mock model|mock|mock/repo\n")
        tfctl = os.path.join(cls.root, "bin", "tfctl")
        with open(tfctl, "w") as fh:  # the gateway only ever calls `tfctl engine start --no-wait` and `tfctl engine stop`
            fh.write(f"""#!/bin/bash
pidf="{cls.root}/state/mock.pid"
case "$1 $2" in
  "engine start") nohup "{sys.executable}" "{MOCK}" {cls.eng_port} "{cls.root}/rec" >/dev/null 2>&1 & echo $! >"$pidf"
                  echo start >>"{cls.root}/rec/tfctl.log" ;;
  "engine stop") [[ -f $pidf ]] && kill "$(cat "$pidf")" 2>/dev/null; rm -f "$pidf"; echo stop >>"{cls.root}/rec/tfctl.log" ;;
esac
""")
        os.chmod(tfctl, 0o755)
        cls.start_gateway()

    @classmethod
    def write_config(cls, **extra):
        cfg = {"MODEL": "mock", "CONTEXT": 65536, "MEMORY_MODE": "idle", "IDLE_MINUTES": 30, "SERVED_NAME": "tensorfold",
               "GATEWAY_PORT": cls.gw_port, "ENGINE_PORT": cls.eng_port, "WEBUI_PORT": free_port(), "SHARE_ON_NETWORK": 0,
               "REQUIRE_KEY": 0}
        cfg.update(extra)
        with open(os.path.join(cls.root, "config.env"), "w") as fh:
            fh.write("".join(f"{k}={v}\n" for k, v in cfg.items()))

    @classmethod
    def start_gateway(cls):
        env = dict(os.environ, TF_LAUNCHER_ROOT=cls.root, TF_ENGINE_LABEL="com.tensorfold.test-none", TF_IDLE_CHECK_S="1")
        cls.gw_log = open(os.path.join(cls.root, "logs", "gateway.log"), "a")
        cls.gw = subprocess.Popen([sys.executable, GATEWAY], env=env, stdout=cls.gw_log, stderr=subprocess.STDOUT)
        if not cls.wait(lambda: cls.get("/health")[0] == 200, 30):
            raise RuntimeError("the gateway did not answer /health within 30 s; see " + cls.gw_log.name)

    @classmethod
    def stop_gateway(cls):
        cls.gw.terminate()
        cls.gw.wait(5)
        cls.gw_log.close()

    @classmethod
    def tearDownClass(cls):
        cls.stop_gateway()
        pidf = os.path.join(cls.root, "state", "mock.pid")
        if os.path.exists(pidf):
            with open(pidf) as fh:
                subprocess.run(["kill", fh.read().strip()])
        if os.environ.get("TFGW_KEEP"):
            print(f"\nkept test root: {cls.root}")
        else:
            shutil.rmtree(cls.root, ignore_errors=True)

    # -------------------------------------------------------------------------------------------- helpers

    @classmethod
    def wait(cls, cond, seconds):
        end = time.time() + seconds
        while time.time() < end:
            try:
                if cond():
                    return True
            except Exception:
                pass
            time.sleep(0.1)
        return False

    @classmethod
    def get(cls, path, host="127.0.0.1", headers=None):
        req = urllib.request.Request(f"http://{host}:{cls.gw_port}{path}", headers=headers or {})
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                return r.status, json.loads(r.read() or b"null")
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read() or b"null")

    def post(self, path, body, host="127.0.0.1", headers=None, raw=False):
        h = {"Content-Type": "application/json", "User-Agent": "TensorFoldHome-test"}
        h.update(headers or {})
        req = urllib.request.Request(f"http://{host}:{self.gw_port}{path}", data=json.dumps(body).encode(), headers=h)
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                data = r.read()
                return r.status, data if raw else json.loads(data)
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read() or b"null")

    def engine_saw(self, name="v1_chat_completions"):
        with open(os.path.join(self.root, "rec", f"last_{name}.json")) as fh:
            return json.load(fh)["body"]

    def metrics(self):
        return self.get("/tf/metrics")[1]

    def chat(self, **kw):
        body = {"model": "anything", "messages": [{"role": "user", "content": "hi"}]}
        body.update(kw)
        return body

    # -------------------------------------------------------------------------------------------- tests (run in name order)

    def test_01_health_and_models(self):
        self.assertEqual(self.get("/health")[0], 200)
        code, models = self.get("/v1/models")
        self.assertEqual(code, 200)
        m = models["data"][0]
        self.assertEqual(m["id"], "tensorfold")
        self.assertEqual(m["context_length"], 65536)  # Hermes reads this for its 64K floor
        self.assertEqual(m["max_model_len"], 65536)
        self.assertIn("Mock model", m["name"])

    def test_02_probe_does_not_wake(self):
        code, _ = self.get("/v1/props")
        self.assertEqual(code, 404)
        self.assertEqual(self.get("/tf/status")[1]["engine"], "stopped")

    def test_03_wake_on_demand_and_model_rewrite(self):
        code, reply = self.post("/v1/chat/completions", self.chat())
        self.assertEqual(code, 200)
        self.assertEqual(reply["choices"][0]["message"]["content"], "Hello from the mock engine.")
        self.assertEqual(self.engine_saw()["model"], "tensorfold")
        rec = self.metrics()["requests"][0]
        self.assertEqual(rec["prompt_tokens"], 40)
        self.assertEqual(rec["cached_tokens"], 10)
        self.assertEqual(rec["output_tokens"], 6)
        self.assertEqual(rec["decode_tok_s"], 50.0)
        self.assertEqual(rec["prefill_tok_s"], 150.0)  # (40 - 10 cached) / 0.2 s
        self.assertEqual(rec["accepted"], 6)
        self.assertEqual(rec["client"], "TensorFold Home")
        self.assertEqual(rec["finish"], "stop")

    def test_04_stream_without_usage_is_unchanged_but_recorded(self):
        code, data = self.post("/v1/chat/completions", self.chat(stream=True), raw=True)
        self.assertEqual(code, 200)
        events = [l for l in data.decode().split("\n") if l.startswith("data:")]
        self.assertNotIn('"usage"', data.decode(), "the usage chunk the gateway asked for must not reach a client that did not ask")
        self.assertEqual(events[-1], "data: [DONE]")
        self.assertTrue(self.engine_saw()["stream_options"]["include_usage"])
        content = "".join(json.loads(e[5:])["choices"][0]["delta"].get("content", "") for e in events[:-1] if json.loads(e[5:])["choices"])
        self.assertEqual(content, "Hello from the mock engine.")
        rec = self.metrics()["requests"][0]
        self.assertTrue(rec["stream"])
        self.assertEqual(rec["output_tokens"], 6)
        self.assertEqual(rec["prompt_tokens"], 40)

    def test_05_stream_with_usage_keeps_it(self):
        code, data = self.post("/v1/chat/completions", self.chat(stream=True, stream_options={"include_usage": True}), raw=True)
        self.assertEqual(code, 200)
        self.assertIn('"usage"', data.decode())

    def test_06_anthropic_messages(self):
        body = {"model": "claude-x", "max_tokens": 50, "stream": True, "messages": [{"role": "user", "content": "hi"}]}
        code, data = self.post("/v1/messages", body, raw=True)
        self.assertEqual(code, 200)
        self.assertIn(b"message_stop", data)
        self.assertEqual(self.engine_saw("v1_messages")["model"], "tensorfold")
        rec = self.metrics()["requests"][0]
        self.assertEqual(rec["path"], "/v1/messages")
        self.assertEqual(rec["prompt_tokens"], 40)
        self.assertEqual(rec["output_tokens"], 6)
        self.assertEqual(rec["finish"], "end_turn")

    def test_07_shared_sampling_defaults(self):
        code, r = self.post("/tf/settings", {"defaults": {"temperature": 0.3, "reasoning_effort": "low", "bogus": 1}})
        self.assertEqual(code, 200)
        self.assertTrue(r["shared"])
        self.assertNotIn("bogus", r["defaults"])
        self.post("/v1/chat/completions", self.chat())
        seen = self.engine_saw()
        self.assertEqual(seen["temperature"], 0.3)
        self.assertEqual(seen["reasoning_effort"], "low")
        self.post("/v1/chat/completions", self.chat(temperature=0.9, chat_template_kwargs={"enable_thinking": True}))
        seen = self.engine_saw()
        self.assertEqual(seen["temperature"], 0.9, "a client's own value wins")
        self.assertNotIn("reasoning_effort", seen, "explicit enable_thinking is not overridden")
        code, r = self.post("/tf/settings", {"defaults": None})
        self.assertFalse(r["shared"])
        self.post("/v1/chat/completions", self.chat())
        self.assertNotIn("temperature", self.engine_saw())

    def test_08_metrics_totals_history_perf(self):
        self.assertTrue(self.wait(lambda: len(self.metrics()["history"]["tok_s"]) >= 2, 5), "one history sample a second")
        m = self.metrics()
        self.assertGreaterEqual(m["totals"]["requests"], 5)
        self.assertEqual(m["live"]["state"], "idle")
        self.assertEqual(m["engine"]["max_context"], 65536)
        self.assertGreater(m["requests"][0]["time"], m["requests"][-1]["time"], "newest first")
        rows = self.get("/tf/perf")[1]["rows"]
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["model"], "mock")
        self.assertEqual(rows[0]["prefill_tok_s"], 150.0)
        # every OpenAI-route reply reports 50 tok/s; the Anthropic one has no stats block, so the gateway timed it itself
        self.assertGreaterEqual(rows[0]["decode_tok_s"], 50.0)
        self.assertGreaterEqual(rows[0]["requests"], m["totals"]["requests"] - 1)

    def test_09_live_state_and_disconnect(self):
        req = urllib.request.Request(f"http://127.0.0.1:{self.gw_port}/v1/chat/completions",
                                     data=json.dumps(self.chat(stream=True, messages=[{"role": "user", "content": "SLOW"}])).encode(),
                                     headers={"Content-Type": "application/json"})
        resp = urllib.request.urlopen(req, timeout=30)
        resp.readline()
        self.assertTrue(self.wait(lambda: self.metrics()["live"]["state"] == "generating", 5))
        live = self.metrics()["live"]
        self.assertEqual(live["running"], 1)
        self.assertGreaterEqual(live["generated"], 1)
        resp.close()  # the client goes away mid-answer
        self.assertTrue(self.wait(lambda: self.metrics()["live"]["running"] == 0, 10))
        self.assertTrue(self.wait(lambda: os.path.exists(os.path.join(self.root, "rec", "cancelled")), 10),
                        "closing the client must close the engine connection")
        self.assertEqual(self.metrics()["requests"][0]["finish"], "cancel")

    def test_10_concurrent_requests(self):
        results = []
        threads = [threading.Thread(target=lambda: results.append(self.post("/v1/chat/completions", self.chat())[0])) for _ in range(4)]
        [t.start() for t in threads]
        [t.join() for t in threads]
        self.assertEqual(results, [200] * 4)

    def test_11_idle_stop_and_always_mode(self):
        type(self).write_config(IDLE_MINUTES=0.03)  # ~2 s
        self.assertTrue(self.wait(lambda: self.get("/tf/status")[1]["engine"] == "stopped", 15), "idle mode unloads the model")
        self.assertEqual(self.post("/v1/chat/completions", self.chat())[0], 200, "and the next request loads it again")
        type(self).write_config(MEMORY_MODE="always", IDLE_MINUTES=0.03)
        time.sleep(4)
        self.assertEqual(self.get("/tf/status")[1]["engine"], "running", "always mode keeps it loaded")
        type(self).write_config()

    def test_12_network_key(self):
        ip = lan_ip()
        if not ip:
            self.skipTest("no LAN address on en0/en1")
        type(self).stop_gateway()
        with open(os.path.join(self.root, "state", "api_key"), "w") as fh:
            fh.write("sk-test-123\n")
        type(self).write_config(SHARE_ON_NETWORK=1, REQUIRE_KEY=1)
        type(self).start_gateway()
        try:
            self.assertEqual(self.get("/tf/status")[1]["listening"], "0.0.0.0")
            self.assertEqual(self.post("/v1/chat/completions", self.chat(), host=ip)[0], 401, "another computer without the key")
            self.assertEqual(self.post("/v1/chat/completions", self.chat(), host=ip, headers={"Authorization": "Bearer nope"})[0], 401)
            self.assertEqual(self.post("/v1/chat/completions", self.chat(), host=ip, headers={"Authorization": "Bearer sk-test-123"})[0], 200)
            self.assertEqual(self.post("/v1/chat/completions", self.chat(), host=ip, headers={"x-api-key": "sk-test-123"})[0], 200)
            self.assertEqual(self.post("/v1/chat/completions", self.chat())[0], 200, "this Mac never needs the key")
            self.assertEqual(self.get("/tf/status", host=ip)[0], 403, "control endpoints answer this Mac only")
            self.assertEqual(self.get("/health", host=ip)[0], 200)
        finally:
            type(self).stop_gateway()
            type(self).write_config()
            type(self).start_gateway()


if __name__ == "__main__":
    unittest.main(verbosity=2)
