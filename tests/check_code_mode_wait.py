#!/usr/bin/env python3
"""usage: check_code_mode_wait.py <last request.json>"""
import json
import sys

request = json.load(open(sys.argv[1]))
exec_out = wait_out = None
for item in request["input"]:
    if item.get("type") in ("custom_tool_call_output", "function_call_output"):
        texts = [part["text"] for part in item["output"]]
        if item["type"] == "custom_tool_call_output":
            exec_out = texts
        else:
            wait_out = texts
print("exec:", exec_out)
print("wait:", wait_out)
assert exec_out and exec_out[0].startswith("Script running with cell ID 1"), exec_out
assert exec_out[1:] == ["started"], exec_out            # output produced before the yield
assert wait_out and wait_out[0].startswith("Script completed"), wait_out
assert wait_out[1:] == ["finished after the delay"], wait_out
print("yield and wait behave as expected")
