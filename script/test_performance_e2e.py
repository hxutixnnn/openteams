#!/usr/bin/env python3
import argparse
from pathlib import Path
import subprocess
import tempfile


parser = argparse.ArgumentParser(description="Run isolated application-core E2E workflows without launching the GUI or accessing real accounts.")
parser.add_argument("--skip-build", action="store_true")
parser.add_argument("--scenario", choices=["ComposerPersistence", "ComposerWorkload", "LoadingInteractions"])
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
        run(["swiftc", "-parse-as-library", "-swift-version", "6", "-Onone", "-I", module_path, source, *objects, "-o", executable])
        run([executable])

print("All application-core E2E workflows passed.")
