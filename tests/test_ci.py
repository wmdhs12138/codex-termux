#!/usr/bin/env python3
"""Offline tests for the release logic in .github/workflows/build.yml.

The resolve and release steps run for real against a scratch git repository
and a fake gh, so the tag, re-cut, Latest and release-notes decisions are
tested without GitHub. Needs bash, git, jq and python3.

  python3 -m unittest -v tests/test_ci.py
"""

import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "build.yml"
BASH = shutil.which("bash")


def run_block(header):
    """The shell of the workflow step whose first line is `header`."""
    lines = WORKFLOW.read_text().splitlines()
    start = next(i for i, line in enumerate(lines) if line.strip() == header)
    run = next(i for i in range(start, len(lines)) if lines[i].strip() == "run: |")
    indent = len(lines[run]) - len(lines[run].lstrip()) + 2
    body = []
    for line in lines[run + 1:]:
        if line.strip() and len(line) - len(line.lstrip()) < indent:
            break
        body.append(line[indent:])
    return "\n".join(body) + "\n"


def git(repo, *args):
    return subprocess.run(
        ["git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "init.defaultBranch=main",
         *args], cwd=repo, text=True, capture_output=True, check=True,
    ).stdout.strip()


def commit(repo, path, subject):
    target = pathlib.Path(repo) / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(subject)
    git(repo, "add", "-A")
    git(repo, "commit", "-q", "-m", subject)
    return git(repo, "rev-parse", "HEAD")


def scratch_repo(tmp):
    repo = pathlib.Path(tmp) / "repo"
    repo.mkdir()
    git(repo, "init", "-q")
    shutil.copy(ROOT / "versions.json", repo / "versions.json")
    commit(repo, "patches/0001.patch", "first")
    return repo


class ResolveTests(unittest.TestCase):
    def resolve(self, tags, requested, recut):
        with tempfile.TemporaryDirectory() as tmp:
            repo = scratch_repo(tmp)
            for tag in tags:
                git(repo, "tag", tag)
            output = repo / "github-output"
            env = dict(os.environ, REQUESTED=requested, RECUT=recut, GITHUB_OUTPUT=str(output))
            proc = subprocess.run(
                [BASH, "-c", run_block("- name: Resolve upstream version and release tag")],
                cwd=repo, env=env, text=True, capture_output=True)
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
            return dict(line.split("=", 1) for line in output.read_text().split())

    def test_new_version_is_released_as_plain_tag(self):
        out = self.resolve(["v0.1.2"], "0.1.3", "false")
        self.assertEqual((out["tag"], out["unreleased"]), ("v0.1.3", "true"))

    def test_released_version_is_not_released_again(self):
        out = self.resolve(["v0.1.2-r1"], "0.1.2", "false")
        self.assertEqual(out["unreleased"], "false")

    def test_recut_takes_the_next_free_suffix(self):
        out = self.resolve(["v0.1.2", "v0.1.2-r1"], "0.1.2", "true")
        self.assertEqual((out["tag"], out["unreleased"]), ("v0.1.2-r2", "true"))


class PublishTests(unittest.TestCase):
    """Runs the release job's shell against a scratch repository and a fake gh."""

    def publish(self, tags, version, tag, fail_first=False):
        with tempfile.TemporaryDirectory() as tmp:
            repo = scratch_repo(tmp)
            for t in tags:
                git(repo, "tag", t)
            commit(repo, "patches/0002.patch", "Patch the updater")
            head = commit(repo, "docs/x.md", "Docs: explain it")
            dist = repo / "out" / "dist"
            dist.mkdir(parents=True)
            (dist / "codex-termux-aarch64.tar.gz").write_bytes(b"tarball")
            digest = hashlib.sha256(b"tarball").hexdigest()
            (dist / "codex-termux-aarch64.tar.gz.sha256").write_text(
                f"{digest}  codex-termux-aarch64.tar.gz\n")
            (dist / "build-manifest.json").write_text(json.dumps(
                {"codex": version, "upstream_commit": "u" * 40, "binary_sha256": "b" * 64}))
            calls = pathlib.Path(tmp) / "calls.jsonl"
            fake = pathlib.Path(tmp) / "bin"
            fake.mkdir()
            (fake / "gh").write_text(f"""#!{sys.executable}
import json, os, sys
calls = {str(calls)!r}
args = sys.argv[1:]
notes = open(args[args.index("--notes-file") + 1]).read()
n = sum(1 for _ in open(calls)) if os.path.exists(calls) else 0
with open(calls, "a") as f:
    f.write(json.dumps({{"args": args, "notes": notes}}) + "\\n")
if {fail_first!r} and n == 0:
    print("HTTP 422: tag_name was used by an immutable release", file=sys.stderr)
    sys.exit(1)
""")
            (fake / "gh").chmod(0o755)
            env = dict(os.environ, PATH=f"{fake}:{os.environ['PATH']}", GITHUB_SHA=head,
                       GITHUB_WORKSPACE=str(repo), GITHUB_REPOSITORY="owner/codex-termux",
                       VERSION=version, TAG=tag)
            proc = subprocess.run([BASH, "-c", run_block("- name: Publish release")],
                                  cwd=repo, env=env, text=True, capture_output=True)
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
            return head, [json.loads(line) for line in calls.read_text().splitlines()]

    def test_pins_the_built_commit_attaches_the_tarball_and_lists_changes(self):
        head, calls = self.publish(["v0.1.2"], "0.1.3", "v0.1.3")
        self.assertEqual(len(calls), 1)
        args, notes = calls[0]["args"], calls[0]["notes"]
        self.assertEqual(args[:3], ["release", "create", "v0.1.3"])
        self.assertEqual(args[args.index("--target") + 1], head)
        self.assertIn("--latest=true", args)
        for asset in ("codex-termux-aarch64.tar.gz", "codex-termux-aarch64.tar.gz.sha256",
                      "build-manifest.json"):
            self.assertIn(f"out/dist/{asset}", args)
        self.assertIn("Codex 0.1.3 · Termux", args)
        self.assertIn("main/install.sh | bash", notes)
        self.assertIn("Binary SHA-256 `" + "b" * 64 + "`", notes)
        self.assertIn("Changes since `v0.1.2`:", notes)
        self.assertIn("Patch the updater", notes)
        self.assertNotIn("Docs: explain it", notes)
        self.assertNotIn("Re-release", notes)

    def test_predecessor_is_the_highest_release_on_a_shared_commit(self):
        _, calls = self.publish(["v0.1.1", "v0.1.2"], "0.1.3", "v0.1.3")
        self.assertIn("Changes since `v0.1.2`:", calls[0]["notes"])

    def test_recut_is_titled_and_explained(self):
        _, calls = self.publish(["v0.1.2"], "0.1.2", "v0.1.2-r1")
        self.assertIn("Codex 0.1.2 · Termux (r1)", calls[0]["args"])
        self.assertIn("--latest=true", calls[0]["args"])
        self.assertIn("Re-release 1 of Codex 0.1.2", calls[0]["notes"])

    def test_recut_of_an_older_version_does_not_take_latest(self):
        _, calls = self.publish(["v0.1.2", "v0.1.5"], "0.1.2", "v0.1.2-r1")
        self.assertIn("--latest=false", calls[0]["args"])

    def test_reserved_tag_falls_back_to_next_recut(self):
        _, calls = self.publish(["v0.1.2"], "0.1.3", "v0.1.3", fail_first=True)
        self.assertEqual([c["args"][2] for c in calls], ["v0.1.3", "v0.1.3-r1"])


if __name__ == "__main__":
    unittest.main()
