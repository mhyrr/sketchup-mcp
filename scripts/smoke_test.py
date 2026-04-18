"""
SketchUp MCP smoke test.

Runs a series of direct TCP calls against the in-SketchUp plugin (port
9876 by default) to verify the failure modes fixed in 2.0.0 stay fixed.

Prereq: SketchUp open, Extensions → MCP Server → Start Server.

Usage:
    python scripts/smoke_test.py            # run all tests
    python scripts/smoke_test.py -k eval    # filter by substring
    python scripts/smoke_test.py --verbose  # print raw traffic

Exit code is the number of failed tests (0 = all pass).
"""

from __future__ import annotations

import argparse
import json
import os
import socket
import sys
import time
from typing import Any, Dict, List, Optional, Tuple


HOST = os.environ.get("SKETCHUP_MCP_HOST", "127.0.0.1")
PORT = int(os.environ.get("SKETCHUP_MCP_PORT", "9876"))


class Client:
    def __init__(self, host: str = HOST, port: int = PORT, verbose: bool = False):
        self.host = host
        self.port = port
        self.verbose = verbose
        self.sock: Optional[socket.socket] = None
        self.buf = b""
        self._id = 0

    def connect(self) -> None:
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.settimeout(5.0)
        self.sock.connect((self.host, self.port))
        self.sock.settimeout(None)
        self.buf = b""

    def close(self) -> None:
        if self.sock:
            try:
                self.sock.close()
            except Exception:
                pass
        self.sock = None
        self.buf = b""

    def send(self, method: str, args: Optional[Dict[str, Any]] = None,
             timeout: float = 30.0) -> Dict[str, Any]:
        if self.sock is None:
            self.connect()
        self._id += 1
        req = {
            "jsonrpc": "2.0",
            "method": "tools/call",
            "params": {"name": method, "arguments": args or {}},
            "id": self._id,
        }
        wire = json.dumps(req).encode("utf-8") + b"\n"
        if self.verbose:
            print(f"→ {wire!r}")
        assert self.sock is not None
        self.sock.sendall(wire)
        self.sock.settimeout(timeout)
        return self._read_json(timeout)

    def _read_json(self, timeout: float) -> Dict[str, Any]:
        assert self.sock is not None
        deadline = time.time() + timeout
        while True:
            parsed, consumed = self._try_parse(self.buf)
            if parsed is not None:
                self.buf = self.buf[consumed:]
                if self.verbose:
                    print(f"← {json.dumps(parsed)[:200]}")
                return parsed
            remaining = deadline - time.time()
            if remaining <= 0:
                raise TimeoutError("read timeout")
            self.sock.settimeout(max(0.1, remaining))
            chunk = self.sock.recv(32768)
            if not chunk:
                raise ConnectionError("server closed")
            self.buf += chunk

    @staticmethod
    def _try_parse(buf: bytes) -> Tuple[Optional[Dict[str, Any]], int]:
        if not buf:
            return None, 0
        i = 0
        while i < len(buf) and buf[i:i+1] in (b" ", b"\t", b"\r", b"\n"):
            i += 1
        if i == len(buf):
            return None, 0
        nl = buf.find(b"\n", i)
        if nl != -1:
            candidate = buf[i:nl].strip()
            if candidate:
                try:
                    return json.loads(candidate.decode("utf-8")), nl + 1
                except json.JSONDecodeError:
                    pass
        # Depth scan fallback
        depth = 0
        in_str = False
        esc = False
        for j in range(i, len(buf)):
            c = buf[j:j+1]
            if in_str:
                if esc:
                    esc = False
                elif c == b"\\":
                    esc = True
                elif c == b'"':
                    in_str = False
            else:
                if c == b'"':
                    in_str = True
                elif c == b"{":
                    depth += 1
                elif c == b"}":
                    depth -= 1
                    if depth == 0:
                        try:
                            return json.loads(buf[i:j+1].decode("utf-8")), j + 1
                        except json.JSONDecodeError:
                            return None, 0
        return None, 0


# ───── Individual tests ──────────────────────────────────────────────────

def t_ping(c: Client) -> None:
    r = c.send("ping")
    assert r["result"]["structured"]["pong"] is True


def t_units_info(c: Client) -> None:
    r = c.send("units_info")
    st = r["result"]["structured"]
    assert "length_unit_name" in st
    assert "cm_per_inch" in st


def t_eval_simple_scalar(c: Client) -> None:
    r = c.send("eval_ruby", {"code": "1 + 2"})
    st = r["result"]["structured"]
    assert st["class"] == "Integer"
    assert json.loads(st["value"]) == 3


def t_eval_hash_result(c: Client) -> None:
    r = c.send("eval_ruby", {"code": '{a: 1, b: "two"}'})
    st = r["result"]["structured"]
    assert st["class"] == "Hash"
    # value is JSON-encoded
    v = json.loads(st["value"])
    assert v == {"a": 1, "b": "two"}


def t_eval_large_payload(c: Client) -> None:
    # 50 KB of Ruby — verifies buffered read and big response framing.
    body = 'x = 0\n' + ('x += 1\n' * 10000) + 'x'
    r = c.send("eval_ruby", {"code": body}, timeout=60.0)
    assert json.loads(r["result"]["structured"]["value"]) == 10000


def t_eval_multiline_string(c: Client) -> None:
    code = 'puts "hello\nworld"; "multi\nline"'
    r = c.send("eval_ruby", {"code": code})
    assert "multi" in r["result"]["structured"]["inspect"]


def t_eval_error_has_backtrace(c: Client) -> None:
    r = c.send("eval_ruby", {"code": "undefined_method_call"})
    assert "error" in r, f"expected error in response, got: {r}"
    assert r["error"]["code"] == -32002, f"expected -32002, got {r['error'].get('code')}"
    msg = r["error"]["message"].lower()
    assert "undefined" in msg or "namerror" in msg, f"unexpected message: {msg}"
    bt = (r["error"].get("data") or {}).get("backtrace")
    assert isinstance(bt, list) and len(bt) >= 1, "expected backtrace in data"


def t_eval_timeout(c: Client) -> None:
    r = c.send("eval_ruby",
               {"code": "sleep 10", "timeout": 2}, timeout=15.0)
    assert "error" in r, f"expected error (timeout), got: {r}"
    msg = r["error"]["message"].lower()
    assert "timed out" in msg or "timeout" in msg, f"unexpected message: {msg}"


def t_list_definitions(c: Client) -> None:
    r = c.send("list_definitions", {"include_bounds": False})
    st = r["result"]["structured"]
    assert "definitions" in st
    assert st["count"] == len(st["definitions"])


def t_list_instances_limit(c: Client) -> None:
    r = c.send("list_instances", {"limit": 5})
    st = r["result"]["structured"]
    assert len(st["instances"]) <= 5


def t_batch_three_evals(c: Client) -> None:
    r = c.send("batch", {
        "calls": [
            {"tool": "eval_ruby", "args": {"code": "1"}},
            {"tool": "eval_ruby", "args": {"code": "2"}},
            {"tool": "eval_ruby", "args": {"code": "3"}},
        ],
        "wrap_undo": False,
    })
    st = r["result"]["structured"]
    assert st["count"] == 3
    assert all(e["success"] for e in st["results"])


def t_snapshot_tempfile(c: Client) -> None:
    r = c.send("snapshot", {"width": 400, "height": 300})
    st = r["result"]["structured"]
    assert os.path.exists(st["path"])


def t_persistent_reuse(c: Client) -> None:
    # 20 rapid-fire calls on the SAME connection should all succeed
    # (tests the persistent-connection fix).
    for i in range(20):
        r = c.send("eval_ruby", {"code": str(i)})
        assert json.loads(r["result"]["structured"]["value"]) == i


def t_reconnect_after_close(c: Client) -> None:
    # Close and reopen mid-session.
    c.close()
    r = c.send("ping")
    assert r["result"]["structured"]["pong"] is True


def t_concat_frame(c: Client) -> None:
    # Send two requests concatenated (no newline between) — server must
    # parse both via the depth scan.
    if c.sock is None:
        c.connect()
    a = {"jsonrpc": "2.0", "method": "tools/call",
         "params": {"name": "ping", "arguments": {}}, "id": 9001}
    b = {"jsonrpc": "2.0", "method": "tools/call",
         "params": {"name": "ping", "arguments": {}}, "id": 9002}
    wire = (json.dumps(a) + json.dumps(b)).encode("utf-8")
    assert c.sock is not None
    c.sock.sendall(wire)
    r1 = c._read_json(10.0)
    r2 = c._read_json(10.0)
    assert r1["id"] == 9001 and r2["id"] == 9002


# ───── Runner ────────────────────────────────────────────────────────────

TESTS = [
    ("ping",                     t_ping),
    ("units_info",               t_units_info),
    ("eval_simple_scalar",       t_eval_simple_scalar),
    ("eval_hash_result",         t_eval_hash_result),
    ("eval_large_payload",       t_eval_large_payload),
    ("eval_multiline_string",    t_eval_multiline_string),
    ("eval_error_has_backtrace", t_eval_error_has_backtrace),
    ("eval_timeout",             t_eval_timeout),
    ("list_definitions",         t_list_definitions),
    ("list_instances_limit",     t_list_instances_limit),
    ("batch_three_evals",        t_batch_three_evals),
    ("snapshot_tempfile",        t_snapshot_tempfile),
    ("persistent_reuse",         t_persistent_reuse),
    ("reconnect_after_close",    t_reconnect_after_close),
    ("concat_frame",             t_concat_frame),
]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("-k", default="", help="substring filter")
    ap.add_argument("--verbose", action="store_true")
    ap.add_argument("--host", default=HOST)
    ap.add_argument("--port", type=int, default=PORT)
    args = ap.parse_args()

    c = Client(args.host, args.port, verbose=args.verbose)
    failed: List[str] = []
    started = time.time()

    selected = [(n, f) for n, f in TESTS if args.k in n]
    for name, fn in selected:
        t0 = time.time()
        try:
            fn(c)
            ms = int((time.time() - t0) * 1000)
            print(f"  PASS  {name}  ({ms} ms)")
        except Exception as e:
            ms = int((time.time() - t0) * 1000)
            failed.append(name)
            print(f"  FAIL  {name}  ({ms} ms)  — {e}")
            if args.verbose:
                import traceback
                traceback.print_exc()

    c.close()
    total_ms = int((time.time() - started) * 1000)
    print(f"\n{len(selected) - len(failed)}/{len(selected)} passed in {total_ms} ms")
    return len(failed)


if __name__ == "__main__":
    sys.exit(main())
