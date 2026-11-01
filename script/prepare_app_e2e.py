import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import uuid


parser = argparse.ArgumentParser()
parser.add_argument("--name", default="OpenTeams Performance Fixture")
arguments = parser.parse_args()
if not arguments.name.strip() or Path(arguments.name).name != arguments.name:
    parser.error("Fixture name must be a nonempty file name")

repository = Path(__file__).resolve().parent.parent
subprocess.run(["swift", "build", "--jobs", "4", "--product", "OpenTeams"], cwd=repository, check=True, timeout=600)
products = Path(subprocess.check_output(["swift", "build", "--show-bin-path"], cwd=repository, text=True).strip())
root = Path(tempfile.mkdtemp(prefix="openteams-app-e2e-"))
identity = "dev.native.openteams.e2e." + uuid.uuid4().hex
bundle = root / (arguments.name + ".app")
contents = bundle / "Contents"
binary = contents / "MacOS" / "OpenTeamsFixture"
binary.parent.mkdir(parents=True)
shutil.copy2(products / "OpenTeams", binary)
with (contents / "Info.plist").open("wb") as stream:
    plistlib.dump({
        "CFBundleExecutable": binary.name,
        "CFBundleIdentifier": identity,
        "CFBundleName": arguments.name,
        "CFBundlePackageType": "APPL",
        "CFBundleVersion": "1",
        "LSMinimumSystemVersion": "14.0",
        "NSPrincipalClass": "NSApplication",
        "NSHighResolutionCapable": True,
        "LSUIElement": True,
        "OpenTeamsPerformanceFixtureRoot": str(root),
    }, stream)
manifest = {
    "bundle": str(bundle), "root": str(root), "bundle_id": identity,
    "commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repository, text=True).strip(),
    "working_tree": subprocess.check_output(["git", "status", "--porcelain"], cwd=repository, text=True),
    "source_sha256": {
        str(path.relative_to(repository)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in sorted((repository / "Sources").rglob("*.swift"))
    },
}
subprocess.run(["codesign", "--force", "--sign", "-", str(bundle)], check=True)
subprocess.run(["codesign", "--verify", "--strict", str(bundle)], check=True)
manifest["binary_sha256"] = hashlib.sha256(binary.read_bytes()).hexdigest()
(root / "fixture.json").write_text(json.dumps(manifest, indent=2) + "\n")
print(json.dumps(manifest, indent=2))
