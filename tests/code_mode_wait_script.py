#!/usr/bin/env python3
"""Script for tests/mock_responses.py: a script that outlives its yield time, then `wait`.

The first `exec` yields after 100 ms with the output so far; the model then calls `wait` on
cell 1 and receives the rest. Cell ids start at 1 in a fresh session.
"""
import json

SOURCE = (
    '// @exec: {"yield_time_ms": 100}\n'
    "const t0 = Date.now();\n"
    'text("started");\n'
    "await new Promise((resolve) => setTimeout(resolve, 800));\n"
    'text("finished after " + (Date.now() - t0 >= 700 ? "the delay" : "too early"));\n'
)

print(json.dumps([
    [{"type": "custom_tool_call", "id": "ctc_1", "status": "completed",
      "call_id": "call_exec1", "name": "exec", "input": SOURCE}],
    [{"type": "function_call", "id": "fc_1", "status": "completed", "call_id": "call_wait1",
      "name": "wait", "arguments": json.dumps({"cell_id": "1", "yield_time_ms": 3000})}],
]))
