#!/usr/bin/env python3
import argparse
from pathlib import Path
import subprocess
import tempfile


parser = argparse.ArgumentParser(description="Run isolated core workflows and benchmarks. These do not replace app-level E2E verification.")
parser.add_argument("--skip-build", action="store_true")
parser.add_argument("--scenario", choices=["AutomaticReadWorkflow", "ComposerPersistence", "ComposerWorkload", "LoadingInteractions", "CachedConversationLoading", "CachedLoadWorkflows", "SendDuringCachedLoad", "CachedLoadHold", "FixtureStartupConversation"])
arguments = parser.parse_args()
repository = Path(__file__).resolve().parent.parent


def run(command):
    print("+ " + " ".join(map(str, command)), flush=True)
    subprocess.run(list(map(str, command)), cwd=repository, check=True, timeout=600)


if not arguments.skip_build:
    run(["swift", "build", "--jobs", "4", "--product", "OpenTeams"])

products = Path(subprocess.check_output(["swift", "build", "--show-bin-path"], cwd=repository, text=True).strip())
module_path = products / "Modules" if (products / "Modules").is_dir() else products
objects = []
for module in ["TeamsCore", "SwiftSoup"]:
    product_object = products / (module + ".o")
    module_objects = [product_object] if product_object.is_file() else sorted((products / (module + ".build")).glob("*.o"))
    if not module_objects:
        raise SystemExit("Missing build objects for " + module)
    objects.extend(module_objects)

with tempfile.TemporaryDirectory(prefix="openteams-performance-e2e-") as directory:
    for source in sorted((repository / "Tests/E2E").glob("*.swift")):
        if arguments.scenario and source.stem != arguments.scenario:
            continue
        executable = Path(directory) / source.stem
        extra = ["-D", "DEBUG", repository / "Sources/TeamsChat/Views/PerformanceFixtureTransport.swift"] if source.stem == "CachedLoadHold" else []
        if source.stem == "FixtureStartupConversation":
            extra = ["-D", "DEBUG", repository / "Sources/TeamsChat/Views/PerformanceFixtureTransport.swift",
                     repository / "Sources/TeamsChat/Views/PerformanceFixtureStartupConversation.swift"]
        run(["swiftc", *extra, "-parse-as-library", "-swift-version", "6", "-Onone", "-I", module_path, source, *objects, "-o", executable])
        run([executable])

print("All core workflows passed. App-level E2E verification is separate; see Tests/E2E/APP.md.")
