#!/usr/bin/env python3
"""Script for tests/mock_responses.py: the "model" makes five `exec` (code mode) calls.

Together they cover what scripts rely on: text output, a nested tool call, store/load across
calls, early exit(), timers, and the text of a runtime error.
"""
import json

CALLS = [
    'text("hello " + (1 + 2));\n'
    'const r = await tools.exec_command({cmd: "echo from-nested-tool"});\n'
    'text(typeof r === "string" ? r : JSON.stringify(r));\n',
    'store("k", {a: 1, list: [1, 2, 3]});\n',
    'text(JSON.stringify(load("k")));\n',
    'text("a");\nexit();\ntext("b");\n',
    'await new Promise((resolve) => setTimeout(resolve, 20));\n'
    'text("timer ok");\nundefinedFn();\n',
]

print(json.dumps([
    [{"type": "custom_tool_call", "id": f"ctc_{i}", "status": "completed",
      "call_id": f"call_exec{i}", "name": "exec", "input": source}]
    for i, source in enumerate(CALLS, 1)
]))
