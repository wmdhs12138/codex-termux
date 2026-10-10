#!/usr/bin/env python3
"""Run the Codex TUI on a pty and save what it drew, as text you can grep.

  tests/tui_capture.py <timeout> <out.txt> [--until TEXT] [--linger SECONDS] -- codex [args]

Answers the terminal queries the TUI waits for (as scripts/bench-startup.py does), so it gets
past startup on a pty no terminal is attached to. out.txt is the output with escape sequences
and all whitespace removed: ratatui moves the cursor over cells that are already blank instead
of writing spaces, so "Update now" can only be matched as "Updatenow". --until stops once that
text (whitespace removed) shows up, after --linger more seconds; the raw bytes go to out.raw.
"""
import fcntl
import os
import pty
import re
import select
import signal
import struct
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
ANSI = re.compile(rb"\x1b\[[0-9;?<>=]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(\x07|\x1b\\)|\x1b[78=>]")


def text(buf):
    return re.sub(rb"\s+", b"", ANSI.sub(b"", buf)).decode("utf-8", "replace")


def main():
    args = sys.argv[1:]
    split = args.index("--")
    opts, argv = args[:split], args[split + 1:]
    timeout, out = float(opts[0]), opts[1]
    until = opts[opts.index("--until") + 1] if "--until" in opts else None
    linger = float(opts[opts.index("--linger") + 1]) if "--linger" in opts else 0.0
    until = re.sub(r"\s+", "", until) if until else None

    pid, fd = pty.fork()
    if pid == 0:
        fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
        os.environ["TERM"] = "xterm-256color"
        os.execvp(argv[0], argv)
    start, stop = time.monotonic(), None
    buf, answered = b"", {}
    while time.monotonic() - start < timeout and (stop is None or time.monotonic() < stop):
        if not select.select([fd], [], [], 0.05)[0]:
            continue
        try:
            data = os.read(fd, 65536)
        except OSError:
            break
        if not data:
            break
        buf += data
        for query, reply in REPLIES.items():
            for _ in range(buf.count(query) - answered.get(query, 0)):
                os.write(fd, reply)
            answered[query] = buf.count(query)
        if until and stop is None and until in text(buf):
            stop = time.monotonic() + linger
    try:
        os.killpg(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    os.waitpid(pid, 0)
    with open(out, "w") as f:
        f.write(text(buf) + "\n")
    with open(re.sub(r"\.txt$", "", out) + ".raw", "wb") as f:
        f.write(buf)


if __name__ == "__main__":
    main()
