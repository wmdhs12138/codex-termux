#!/usr/bin/env python3
"""Print the names of every tool a recorded Responses request offered to the model.

Models in "responses lite" mode declare tools inside an `additional_tools` input
item instead of the top-level `tools` array, and tools may sit inside
`namespace` entries; collect from both places, recursively.

usage: tool_names.py <request.json>
"""
import json
import sys


def collect(tools, out):
    for t in tools or []:
        if t.get("type") == "namespace":
            collect(t.get("tools"), out)
        else:
            name = t.get("name") or t.get("function", {}).get("name") or t.get("type")
            out.append(name)


def tool_names(request):
    out = []
    collect(request.get("tools"), out)
    for item in request.get("input", []):
        if isinstance(item, dict) and item.get("type") == "additional_tools":
            collect(item.get("tools"), out)
    return out


if __name__ == "__main__":
    print(json.dumps(tool_names(json.load(open(sys.argv[1])))))
