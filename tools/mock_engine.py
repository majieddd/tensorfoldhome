#!/usr/bin/env python3
"""A stand-in for the TensorFold engine, for the gateway tests: the same routes and reply shapes, no model.

    python3 mock_engine.py PORT RECORD_DIR

Every request body is written to RECORD_DIR/last_<path>.json. A prompt containing "SLOW" streams one token every 0.2 s.
"""
import json
import os
import socketserver
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT, RECORD = int(sys.argv[1]), sys.argv[2]
TOTALS = {"prompt": 0, "gen": 0, "drafted": 0, "accepted": 0}
WORDS = ["Hello", " from", " the", " mock", " engine", "."]


def stats(n_out):
    return {"enable_thinking": False, "reasoning_effort": "none", "engine": "mock", "tokens_per_second": 50.0,
            "seconds": 0.5, "prefill_seconds": 0.2, "time_to_first_token": 0.21, "drafts": True}


def spec():
    return {"rounds": 4, "drafted": 8, "accepted": 6, "acceptance_rate": 0.75}


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def send_json(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        if self.path == "/health":
            return self.send_json(200, {"status": "ok"})
        if self.path == "/metrics":
            text = (f"tensorfold:requests_running 0\ntensorfold:requests_waiting 0\n"
                    f"tensorfold:prompt_tokens_total {TOTALS['prompt']}\ntensorfold:generation_tokens_total {TOTALS['gen']}\n"
                    f"tensorfold:mtp_drafted_total {TOTALS['drafted']}\ntensorfold:mtp_accepted_total {TOTALS['accepted']}\n"
                    f'tensorfold:kv_cache_usage_ratio{{pool="0"}} 0\n').encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(text)))
            self.end_headers()
            return self.wfile.write(text)
        return self.send_json(404, {"error": {"message": "unknown path"}})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        name = self.path.strip("/").replace("/", "_")
        with open(os.path.join(RECORD, f"last_{name}.json"), "w") as fh:
            json.dump({"body": body, "headers": dict(self.headers)}, fh)
        prompt_text = json.dumps(body.get("messages", ""))
        slow = "SLOW" in prompt_text
        n_prompt = 40
        TOTALS["prompt"] += n_prompt
        TOTALS["gen"] += len(WORDS)
        TOTALS["drafted"] += 8
        TOTALS["accepted"] += 6
        usage = {"prompt_tokens": n_prompt, "completion_tokens": len(WORDS), "total_tokens": n_prompt + len(WORDS),
                 "prompt_tokens_details": {"cached_tokens": 10}, "completion_tokens_details": {"reasoning_tokens": 0}}
        if self.path == "/v1/messages":
            return self.anthropic(body, n_prompt, slow)
        if not body.get("stream"):
            return self.send_json(200, {"id": "cmpl-1", "object": "chat.completion", "model": body.get("model"),
                                        "choices": [{"index": 0, "message": {"role": "assistant", "content": "".join(WORDS)},
                                                     "finish_reason": "stop"}],
                                        "usage": usage, "tensorfold": stats(len(WORDS)), "speculative": spec()})
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()

        def emit(obj):
            data = b"data: " + (obj if isinstance(obj, bytes) else json.dumps(obj).encode()) + b"\n\n"
            self.wfile.write(b"%x\r\n%s\r\n" % (len(data), data))
            self.wfile.flush()

        words = WORDS * (25 if slow else 1)
        try:
            for i, w in enumerate(words):
                emit({"id": "c1", "object": "chat.completion.chunk", "model": body.get("model"),
                      "choices": [{"index": 0, "delta": {"content": w}, "finish_reason": None}]})
                if slow:
                    time.sleep(0.2)
            emit({"id": "c1", "object": "chat.completion.chunk", "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
                  "tensorfold": stats(len(words)), "speculative": spec()})
            if (body.get("stream_options") or {}).get("include_usage"):
                emit({"id": "c1", "object": "chat.completion.chunk", "choices": [], "usage": usage})
            emit(b"[DONE]")
            self.wfile.write(b"0\r\n\r\n")
        except (BrokenPipeError, ConnectionResetError):
            with open(os.path.join(RECORD, "cancelled"), "w") as fh:
                fh.write("1")

    def anthropic(self, body, n_prompt, slow):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()

        def emit(event, obj):
            data = f"event: {event}\ndata: {json.dumps(obj)}\n\n".encode()
            self.wfile.write(b"%x\r\n%s\r\n" % (len(data), data))
            self.wfile.flush()

        emit("message_start", {"type": "message_start", "message": {"id": "m1", "usage": {"input_tokens": n_prompt, "output_tokens": 1}}})
        for w in WORDS:
            emit("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": w}})
        emit("message_delta", {"type": "message_delta", "delta": {"stop_reason": "end_turn"}, "usage": {"output_tokens": len(WORDS)}})
        emit("message_stop", {"type": "message_stop"})
        self.wfile.write(b"0\r\n\r\n")


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def server_bind(self):  # skip HTTPServer's reverse DNS lookup of the host name (slow on some networks)
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]


Server(("127.0.0.1", PORT), H).serve_forever()
