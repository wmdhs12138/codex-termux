#!/usr/bin/env python3
"""Run one turn through the shared background server's control socket.

    daemon_session.py <control socket> <cwd> <prompt>

The control socket speaks JSON-RPC in WebSocket text frames (the same protocol the TUI uses
when it attaches to the daemon). This is a minimal client, standard library only: handshake,
`initialize`, `thread/start`, `turn/start`, then every notification until `turn/completed`.
It answers server requests (approvals, elicitations) with an error, so a turn that needs one
fails loudly. Exit status 0 only if the turn completed.
"""
import base64
import json
import os
import socket
import struct
import sys
import time

TIMEOUT = 150


class WebSocket:
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(TIMEOUT)
        try:
            self.sock.connect(path)
        except OSError as error:
            if "too long" not in str(error):
                raise
            # sun_path holds 107 bytes; the control socket is a symlink to a short physical
            # path, so resolve it, as the Rust clients do.
            self.sock.connect(os.path.realpath(path))
        self.buf = b""
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall(
            (
                "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n"
                f"Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: {key}\r\n\r\n"
            ).encode()
        )
        head = self._read_until(b"\r\n\r\n")
        if not head.startswith(b"HTTP/1.1 101"):
            raise RuntimeError(f"websocket upgrade refused: {head[:200]!r}")

    def _read_until(self, marker):
        while marker not in self.buf:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise EOFError("control socket closed")
            self.buf += chunk
        head, _, self.buf = self.buf.partition(marker)
        return head

    def _read(self, n):
        while len(self.buf) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise EOFError("control socket closed")
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def _send_frame(self, opcode, payload):
        header = bytes([0x80 | opcode])
        if len(payload) < 126:
            header += bytes([0x80 | len(payload)])
        elif len(payload) < 65536:
            header += bytes([0x80 | 126]) + struct.pack(">H", len(payload))
        else:
            header += bytes([0x80 | 127]) + struct.pack(">Q", len(payload))
        mask = os.urandom(4)
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.sock.sendall(header + mask + masked)

    def send(self, message):
        self._send_frame(0x1, json.dumps(message).encode())

    def recv(self):
        """The next JSON message; control frames are handled on the way."""
        text = b""
        while True:
            b0, b1 = self._read(2)
            opcode, length = b0 & 0x0F, b1 & 0x7F
            if length == 126:
                (length,) = struct.unpack(">H", self._read(2))
            elif length == 127:
                (length,) = struct.unpack(">Q", self._read(8))
            payload = self._read(length)  # server frames are not masked
            if opcode == 0x8:
                raise EOFError("server closed the websocket")
            if opcode == 0x9:
                self._send_frame(0xA, payload)
            elif opcode in (0x0, 0x1, 0x2):
                text += payload
                if b0 & 0x80:
                    return json.loads(text)


class Session:
    def __init__(self, path):
        self.ws = WebSocket(path)
        self.next_id = 0
        self.notifications = []

    def _dispatch(self, message, want_id):
        if "method" in message and "id" in message:  # a request from the server
            print(f"server request refused: {message['method']}", flush=True)
            self.ws.send({"id": message["id"], "error": {"code": -32601, "message": "unsupported"}})
        elif "method" in message:
            self.notifications.append(message)
        elif message.get("id") == want_id:
            return message

    def request(self, method, params):
        self.next_id += 1
        self.ws.send({"id": self.next_id, "method": method, "params": params})
        while True:
            response = self._dispatch(self.ws.recv(), self.next_id)
            if response is None:
                continue
            if "error" in response:
                raise RuntimeError(f"{method} failed: {response['error']}")
            return response["result"]

    def next_notification(self):
        # Notifications that arrived while a request was waiting for its response come first.
        while not self.notifications:
            self._dispatch(self.ws.recv(), None)
        return self.notifications.pop(0)


def main():
    path, cwd, prompt = sys.argv[1:4]
    session = Session(path)
    init = session.request(
        "initialize",
        {"clientInfo": {"name": "codex_termux_ci", "title": "codex-termux CI", "version": "0"}},
    )
    print("server:", init.get("userAgent"), flush=True)
    session.ws.send({"method": "initialized"})
    started = session.request(
        "thread/start",
        {"cwd": cwd, "approvalPolicy": "never", "sandbox": "workspace-write", "modelProvider": "mock"},
    )
    thread_id = started["thread"]["id"]
    print("thread:", thread_id, flush=True)
    session.request(
        "turn/start",
        {"threadId": thread_id, "input": [{"type": "text", "text": prompt, "text_elements": []}]},
    )
    deadline = time.time() + TIMEOUT
    seen = {}
    while time.time() < deadline:
        note = session.next_notification()
        method = note["method"]
        seen[method] = seen.get(method, 0) + 1
        if method == "turn/completed":
            turn = note["params"]["turn"]
            print("turn:", turn.get("status"), "| notifications:", json.dumps(seen, sort_keys=True))
            if turn.get("status") != "completed":
                print(json.dumps(turn)[:2000])
                sys.exit(1)
            return
    print("timed out waiting for turn/completed; saw", json.dumps(seen, sort_keys=True))
    sys.exit(1)


if __name__ == "__main__":
    main()
