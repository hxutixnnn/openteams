#!/usr/bin/env python3
"""Run the isolated scroll-frame benchmark against a fictional 2000-message history."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

parser = argparse.ArgumentParser(description="Measure chat timeline frame cadence in the isolated fixture app.")
parser.add_argument("--label", default="unlabelled")
parser.add_argument("--output", default=None)
parser.add_argument("--skip-build", action="store_true")
parser.add_argument("--runner", choices=["exec", "open"], default="exec")
parser.add_argument("--mode", choices=["jump", "wheel", "bounds"], default="jump")
parser.add_argument("--timeout", type=float, default=180.0)
arguments = parser.parse_args()

repository = Path(__file__).resolve().parent.parent

if not arguments.skip_build:
    subprocess.run(["swift", "build", "--jobs", "4", "--product", "OpenTeams"], cwd=repository, check=True, timeout=900)

prepared = subprocess.run(
    [sys.executable, str(repository / "script/prepare_app_e2e.py"), "--skip-build", "--cached-history-count", "2000"],
    cwd=repository, check=True, capture_output=True, text=True)
manifest = json.loads(prepared.stdout)
root = Path(manifest["root"])
bundle = Path(manifest["bundle"])
report = root / "scroll-benchmark.json"
arguments_flag = ["--scroll-benchmark", "--scroll-benchmark-label=" + arguments.label,
                     "--scroll-benchmark-mode=" + arguments.mode]

log = root / "scroll-benchmark-run.log"
with log.open("w") as stream:
    stream.write(json.dumps(manifest["source_sha256"], sort_keys=True) + "\n")
    stream.flush()
    if arguments.runner == "exec":
        process = subprocess.Popen([str(bundle / "Contents/MacOS" / "OpenTeamsFixture")] + arguments_flag,
                                   cwd=str(bundle), stdout=stream, stderr=subprocess.STDOUT,
                                   env={**os.environ, "NSUnbufferedIO": "YES"})
    else:
        subprocess.run(["open", "-n", str(bundle), "--args"] + arguments_flag, check=True)
        process = None

deadline = time.monotonic() + arguments.timeout
while time.monotonic() < deadline:
    if report.exists():
        try:
            result = json.loads(report.read_text())
            break
        except json.JSONDecodeError:
            pass
    if process is not None and process.poll() is not None and not report.exists():
        result = {"error": "fixture exited without a report", "log": str(log)}
        break
    time.sleep(0.5)
else:
    result = {"error": "timed out waiting for a report", "log": str(log)}

if process is not None and process.poll() is None:
    process.terminate()
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        process.kill()

result["commit"] = manifest["commit"]
result["cached_history_count"] = manifest["cached_history_count"]
result["runner"] = arguments.runner
if arguments.output:
    Path(arguments.output).parent.mkdir(parents=True, exist_ok=True)
    Path(arguments.output).write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
print(json.dumps(result, indent=2, sort_keys=True))
shutil.rmtree(root, ignore_errors=True)
