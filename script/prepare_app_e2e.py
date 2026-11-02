import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import uuid


parser = argparse.ArgumentParser(description="Prepare an isolated native fixture without launching it.")
parser.add_argument("--name", default="OpenTeams Performance Fixture")
parser.add_argument("--cached-history-count", type=int, choices=[0, 200, 2000], default=0)
parser.add_argument("--allow-fictional-send", action="store_true")
parser.add_argument("--enable-cached-load-hold", action="store_true")
parser.add_argument("--skip-build", action="store_true")
parser.add_argument("--startup-conversation", choices=["project", "planning"], default="project")
arguments = parser.parse_args()
if not arguments.name.strip() or Path(arguments.name).name != arguments.name:
    parser.error("Fixture name must be a nonempty file name")
if arguments.allow_fictional_send and not arguments.cached_history_count:
    parser.error("--allow-fictional-send requires --cached-history-count")

if arguments.enable_cached_load_hold and not arguments.cached_history_count:
    parser.error("--enable-cached-load-hold requires --cached-history-count")

repository = Path(__file__).resolve().parent.parent
if not arguments.skip_build:
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
        "OpenTeamsCachedHistoryCount": arguments.cached_history_count,
        "OpenTeamsFictionalSendEnabled": arguments.allow_fictional_send,
        "OpenTeamsCachedLoadHoldEnabled": arguments.enable_cached_load_hold,
        "OpenTeamsFixtureStartupConversation": arguments.startup_conversation,
    }, stream)
manifest = {
    "bundle": str(bundle), "root": str(root), "bundle_id": identity,
    "commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repository, text=True).strip(),
    "working_tree": subprocess.check_output(["git", "status", "--porcelain"], cwd=repository, text=True),
    "cached_history_count": arguments.cached_history_count,
    "fictional_send_enabled": arguments.allow_fictional_send,
    "cached_load_hold_enabled": arguments.enable_cached_load_hold,
    "startup_conversation": arguments.startup_conversation,
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
