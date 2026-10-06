#!/usr/bin/env python3
"""Time from exec to the first ready screen of the Codex TUI, on a pty.

    CODEX_HOME=... BENCH_CWD=/some/trusted/dir scripts/bench-startup.py <marker> <runs> -- codex [args]

<marker> is a byte string that shows up once the TUI knows its configuration, for example the
model name in the status line. `codex --no-daemon` measures the embedded server, a plain `codex`
the shared daemon (needs features.daemon_auto_start, the default). BENCH_PRE, if set, is a shell
command run before every (untimed) run, e.g. "codex app-server daemon stop" for cold starts.

The usual terminal queries are answered, so the TUI does not wait for a terminal that is not
there. Prints, per run, the seconds until the first output, the alternate screen and the marker.
"""
import fcntl
import os
import pty
import re
import select
import signal
import statistics
import struct
import subprocess
import sys
import termios
import time

REPLIES = {
    b"\x1b[6n": b"\x1b[1;1R",
    b"\x1b[c": b"\x1b[?1;2c",
    b"\x1b[?u": b"\x1b[?0u",
    b"\x1b]10;?\x1b\\": b"\x1b]10;rgb:ffff/ffff/ffff\x1b\\",
    b"\x1b]11;?\x1b\\": b"\x1b]11;rgb:0000/0000/0000\x1b\\",
    b"\x1b]10;?\x07": b"\x1b]10;rgb:ffff/ffff/ffff\x07",
    b"\x1b]11;?\x07": b"\x1b]11;rgb:0000/0000/0000\x07",
}
ANSI = re.compile(rb"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(\x07|\x1b\\)")


def answer_queries(fd, buf, answered):
    for query, reply in REPLIES.items():
        count = buf.count(query)
        for _ in range(count - answered.get(query, 0)):
            os.write(fd, reply)
        answered[query] = count


def run_once(argv, marker, timeout=45):
    pid, fd = pty.fork()
    if pid == 0:
        if os.environ.get("BENCH_CWD"):
            os.chdir(os.environ["BENCH_CWD"])
        fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
        os.environ["TERM"] = "xterm-256color"
        os.execvp(argv[0], argv)
    start = time.monotonic()
    first = alt = seen = None
    buf, answered = b"", {}
    while time.monotonic() - start < timeout:
        if not select.select([fd], [], [], 0.02)[0]:
            continue
        try:
            data = os.read(fd, 65536)
        except OSError:
            break
        if not data:
            break
        now = time.monotonic() - start
        first = now if first is None else first
        buf += data
        answer_queries(fd, buf, answered)
        alt = now if alt is None and b"\x1b[?1049h" in buf else alt
        if marker in buf:
            seen = now
            break
    try:
        os.killpg(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    os.waitpid(pid, 0)
    return first, alt, seen, buf


def main():
    marker, runs, argv = sys.argv[1].encode(), int(sys.argv[2]), sys.argv[4:]
    pre = os.environ.get("BENCH_PRE")
    rows = []
    fmt = lambda value: "  -  " if value is None else f"{value:5.2f}"
    for number in range(1, runs + 1):
        if pre:
            subprocess.run(pre, shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        first, alt, seen, buf = run_once(argv, marker)
        rows.append((first, alt, seen))
        print(f"run {number}: first output {fmt(first)}  alt screen {fmt(alt)}  marker {fmt(seen)}", flush=True)
        if seen is None and number == 1:
            text = ANSI.sub(b"", buf).decode("utf-8", "replace")
            print("   marker not seen; screen text:", " ".join(text.split())[:300])
    median = lambda i: statistics.median([r[i] for r in rows if r[i] is not None] or [float("nan")])
    print(f"median: first output {median(0):.2f}  alt screen {median(1):.2f}  marker {median(2):.2f}")


if __name__ == "__main__":
    main()
