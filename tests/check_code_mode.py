#!/usr/bin/env python3
"""Checks what the model was sent back for tests/code_mode_script.py.

usage: check_code_mode.py <last request.json>   (its history holds every exec result)
"""
import json
import sys

request = json.load(open(sys.argv[1]))
outputs = []
for item in request["input"]:
    if item.get("type") == "custom_tool_call_output":
        out = item["output"]
        outputs.append([part["text"] for part in out] if isinstance(out, list) else [out])

for number, texts in enumerate(outputs, 1):
    print(f"exec #{number}: {texts!r}"[:240])

assert len(outputs) == 6, f"expected 6 exec results, got {len(outputs)}"
one, two, three, four, five, six = outputs

assert one[0].startswith("Script completed") and "hello 3" in one, one
nested = json.loads(one[2])
assert nested["exit_code"] == 0 and nested["output"] == "from-nested-tool\n", nested

assert two[0].startswith("Script completed") and len(two) == 1, two
assert three[1:] == ['{"a":1,"list":[1,2,3]}'], three      # store() survived into a later call
assert four[0].startswith("Script completed") and four[1:] == ["a"], four   # exit() ended it
assert five[0].startswith("Script failed") and "timer ok" in five, five      # timer ran first
assert any("ReferenceError: undefinedFn is not defined" in text for text in five), five
# The orchestration pattern: both jobs settle, and a failing command is a result, not a throw.
assert six[0].startswith("Script completed"), six
ok, fails = (json.loads(text) for text in six[1:3])
assert ok["name"] == "ok" and ok["exit_code"] == 0 and ok["output"] == "parallel-one\n", ok
assert fails["name"] == "fails" and fails["exit_code"] == 3, fails
print("code mode behaves as expected")
