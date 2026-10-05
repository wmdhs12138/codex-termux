#!/usr/bin/env python3
"""Tiny fake OpenAI Responses API for offline tests.

Records every POST body to <outdir>/request-N.json and answers with a minimal
completed SSE stream, so `codex exec` can be pointed at it (custom provider) and
the tool list it sends can be inspected without network or credentials.

Optionally takes a script: a JSON list whose Nth entry is the list of output
items (e.g. a tool call) to answer the Nth request with; once the script runs
out, a plain assistant message is returned.

usage: mock_responses.py <outdir> <portfile> [script.json]
"""
import http.server
import json
import os
import sys

OUT, PORTFILE = sys.argv[1], sys.argv[2]
SCRIPT = json.load(open(sys.argv[3])) if len(sys.argv) > 3 else []
os.makedirs(OUT, exist_ok=True)
COUNT = 0


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        global COUNT
        n = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(n)
        COUNT += 1
        with open(os.path.join(OUT, f"request-{COUNT}.json"), "wb") as f:
            f.write(body)
        message = {
            "type": "message",
            "id": f"msg_{COUNT}",
            "role": "assistant",
            "status": "completed",
            "content": [{"type": "output_text", "text": "ok", "annotations": []}],
        }
        items = SCRIPT[COUNT - 1] if COUNT <= len(SCRIPT) else [message]
        resp = {
            "id": f"resp_{COUNT}",
            "object": "response",
            "status": "completed",
            "output": items,
            "usage": {
                "input_tokens": 1,
                "input_tokens_details": {"cached_tokens": 0},
                "output_tokens": 1,
                "output_tokens_details": {"reasoning_tokens": 0},
                "total_tokens": 2,
            },
        }
        events = [
            ("response.created", {"type": "response.created", "response": {"id": resp["id"], "status": "in_progress"}}),
        ]
        for i, item in enumerate(items):
            events.append(("response.output_item.done", {"type": "response.output_item.done", "output_index": i, "item": item}))
        events.append(("response.completed", {"type": "response.completed", "response": resp}))
        payload = "".join(f"event: {e}\ndata: {json.dumps(d)}\n\n" for e, d in events).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(PORTFILE, "w") as f:
    f.write(str(srv.server_address[1]))
srv.serve_forever()
