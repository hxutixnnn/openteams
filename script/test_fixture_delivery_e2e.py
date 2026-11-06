import argparse
from pathlib import Path
import subprocess
import tempfile


parser = argparse.ArgumentParser(description="Verify fictional delivery through the production transport/store/cache workflow, without native UI.")
parser.add_argument("--skip-build", action="store_true")
arguments = parser.parse_args()
repository = Path(__file__).resolve().parent.parent
if not arguments.skip_build:
    subprocess.run(["swift", "build", "--jobs", "4", "--product", "OpenTeams"], cwd=repository, check=True, timeout=600)
products = Path(subprocess.check_output(["swift", "build", "--show-bin-path"], cwd=repository, text=True).strip())
modules = products / "Modules" if (products / "Modules").is_dir() else products
objects = []
for module in ["TeamsCore", "SwiftSoup"]:
    product_object = products / (module + ".o")
    module_objects = [product_object] if product_object.is_file() else sorted((products / (module + ".build")).glob("*.o"))
    if not module_objects:
        raise SystemExit("Missing build objects for " + module)
    objects.extend(module_objects)
transport = repository / "Sources/TeamsChat/Views/PerformanceFixtureTransport.swift"
workflow = (repository / "Tests/E2E/FixtureDelivery/Workflow.swift").read_text()
with tempfile.TemporaryDirectory(prefix="openteams-delivery-e2e-") as directory:
    generated = Path(directory) / "FixtureDelivery.swift"
    generated.write_text("import Foundation\nimport TeamsCore\n" + workflow)
    executable = Path(directory) / "FixtureDelivery"
    subprocess.run(["swiftc", "-D", "DEBUG", str(transport), "-parse-as-library", "-swift-version", "6", "-Onone", "-I", str(modules), str(generated), *map(str, objects), "-o", str(executable)], cwd=repository, check=True, timeout=120)
    subprocess.run([str(executable)], cwd=repository, check=True, timeout=30)
