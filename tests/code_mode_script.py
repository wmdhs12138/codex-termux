#!/usr/bin/env python3
"""Script for tests/mock_responses.py: the "model" makes nine `exec` (code mode) calls.

Together they cover what scripts rely on: text output, a nested tool call, store/load across
calls, early exit(), timers, the text of a runtime error, nested apply_patch, and the locale
APIs (Intl, toLocaleString, localeCompare) that QuickJS only has through the Intl overlay.
"""
import json
import sys

# A path outside the working directory, for the nested apply_patch that must be refused.
OUTSIDE = sys.argv[1] if len(sys.argv) > 1 else "/data/outside-guard.txt"

CALLS = [
    'text("hello " + (1 + 2));\n'
    'const r = await tools.exec_command({cmd: "echo from-nested-tool"});\n'
    'text(typeof r === "string" ? r : JSON.stringify(r));\n',
    'store("k", {a: 1, list: [1, 2, 3]});\n',
    'text(JSON.stringify(load("k")));\n',
    'text("a");\nexit();\ntext("b");\n',
    'await new Promise((resolve) => setTimeout(resolve, 20));\n'
    'text("timer ok");\nundefinedFn();\n',
    # What a real gpt-6.1-sol session wrote: parallel nested calls, a failing command that is a
    # normal result (exit code), async arrows, object spread and text() of an object.
    'const jobs = [\n'
    '  {name: "ok", args: {cmd: "echo parallel-one"}},\n'
    '  {name: "fails", args: {cmd: "exit 3"}},\n'
    '];\n'
    'const results = await Promise.allSettled(jobs.map(async (job) => {\n'
    '  const result = await tools.exec_command(job.args);\n'
    '  return {name: job.name, ...result};\n'
    '}));\n'
    'for (let i = 0; i < results.length; i++) {\n'
    '  const r = results[i];\n'
    '  text(r.status === "fulfilled" ? r.value : {name: jobs[i].name, error: String(r.reason)});\n'
    '}\n',
    # Files are written from inside Code Mode too (a real session did this for six files):
    # a patch inside the working directory goes through...
    'text(await tools.apply_patch("*** Begin Patch\\n*** Add File: nested.txt\\n+nested ok\\n*** End Patch\\n"));\n',
    # ...and one aimed outside it must still be refused, nested or not.
    'text(await tools.apply_patch("*** Begin Patch\\n*** Add File: ' + OUTSIDE + '\\n+must not be written\\n*** End Patch\\n"));\n',
    # Locale-sensitive built-ins, as a model would use them: time zones, currency, collation.
    'const when = new Date("2025-01-02T03:04:05Z");\n'
    'text(when.toLocaleString("en-US", {timeZone: "America/New_York", dateStyle: "medium", timeStyle: "short"}));\n'
    'text(new Intl.NumberFormat("en-US", {style: "currency", currency: "USD"}).format(1234.5));\n'
    'text(["b", "a", "C"].sort((x, y) => x.localeCompare(y)).join(","));\n'
    'text(new Intl.ListFormat("en").format(["a", "b", "c"]));\n'
    'text((1234567.891).toLocaleString());\n'
    'text(new Intl.DateTimeFormat("en-US", {timeZone: "Asia/Shanghai", hour: "numeric", minute: "2-digit", timeZoneName: "short"}).format(when));\n',
]

print(json.dumps([
    [{"type": "custom_tool_call", "id": f"ctc_{i}", "status": "completed",
      "call_id": f"call_exec{i}", "name": "exec", "input": source}]
    for i, source in enumerate(CALLS, 1)
]))
