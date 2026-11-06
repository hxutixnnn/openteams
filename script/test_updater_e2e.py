import fcntl
import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import uuid


repository = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("updater", repository / "script/update_app.py")
updater = importlib.util.module_from_spec(spec)
spec.loader.exec_module(updater)
support = Path.home() / "Library/Application Support/TeamsChat"
identity = (support / "signing-identity").read_text().strip()
helper = support / "CredentialHelper/v2/TeamsCredentialService.xpc"


def run(command, cwd):
    return subprocess.check_output(command, cwd=cwd, stderr=subprocess.STDOUT, text=True).strip()


def make_app(app, revision, signing_identity=identity):
    contents = app / "Contents"
    (contents / "MacOS").mkdir(parents=True)
    (contents / "XPCServices").mkdir()
    shutil.copyfile("/usr/bin/true", contents / "MacOS/OpenTeams")
    (contents / "MacOS/OpenTeams").chmod(0o755)
    shutil.copytree(helper, contents / "XPCServices/TeamsCredentialService.xpc")
    with (contents / "Info.plist").open("wb") as stream:
        plistlib.dump({"CFBundleIdentifier": "dev.native.teamschat", "CFBundleExecutable": "OpenTeams",
                      "CFBundlePackageType": "APPL", "TeamsSigningCertificate": identity,
                      "OpenTeamsSourceRevision": revision}, stream)
    run(["/usr/bin/codesign", "--force", "--sign", signing_identity, str(app)], app.parent)


with tempfile.TemporaryDirectory(prefix="openteams-updater-e2e-") as temporary:
    root = Path(temporary)
    for mode in ["success", "build-failure", "revision-mismatch", "bad-signature", "unrelated-app", "rollback", "concurrent"]:
        case = root / mode
        case.mkdir()
        origin = case / "origin"
        (origin / "script").mkdir(parents=True)
        destination = case / "Applications/OpenTeams.app"
        destination.parent.mkdir()
        make_app(destination, "0" * 40, "-" if mode == "unrelated-app" else identity)
        before = (destination / "Contents/_CodeSignature/CodeResources").read_bytes()
        builder = '''import pathlib, subprocess, sys
sys.path.insert(0, TEST_SCRIPT_DIRECTORY)
from fixture_support import make_app
root = pathlib.Path.cwd()
revision = subprocess.check_output(["/usr/bin/git", "rev-parse", "HEAD"], text=True).strip()
make_app(root / "dist/OpenTeams.app", revision)
'''.replace("TEST_SCRIPT_DIRECTORY", repr(str(root)))
        if mode == "build-failure":
            builder = "raise SystemExit(17)\n"
        elif mode == "revision-mismatch":
            builder = builder.replace('revision)\n', '"1" * 40)\n')
        elif mode == "bad-signature":
            builder += '(root / "dist/OpenTeams.app/Contents/MacOS/OpenTeams").write_bytes(b"tampered")\n'
        (root / "fixture_support.py").write_text(
            "import pathlib, shutil, plistlib, subprocess\n"
            + "identity = " + repr(identity) + "\n"
            + "helper = pathlib.Path(" + repr(str(helper)) + ")\n"
            + "def run(command, cwd):\n    subprocess.run(command, cwd=cwd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)\n"
            + __import__("inspect").getsource(make_app))
        (origin / "script/build.py").write_text(builder)
        (origin / "script/build_and_run.sh").write_text("set -eu\n/usr/bin/python3 script/build.py\n")
        installer = (repository / "script/install.sh").read_text()
        installer = installer.replace('DEST="/Applications/OpenTeams.app"', "DEST=" + __import__("shlex").quote(str(destination)))
        installer = installer.replace("mktemp -d /Applications/.OpenTeams-install.XXXXXX",
                                      "mktemp -d " + __import__("shlex").quote(str(destination.parent / ".OpenTeams-install.XXXXXX")))
        if mode == "rollback":
            installer = installer.replace('if ! validate "$DEST"; then', 'if ! false; then')
        (origin / "script/install.sh").write_text(installer)
        shutil.copy2(repository / "script/verify_credential_helper.sh", origin / "script/verify_credential_helper.sh")
        (origin / "script/app_processes.py").write_text("pass\n")
        run(["/usr/bin/git", "init", "-b", "main"], origin)
        run(["/usr/bin/git", "add", "."], origin)
        run(["/usr/bin/git", "-c", "user.name=E2E", "-c", "user.email=e2e@example.invalid", "commit", "-m", "Fixture"], origin)
        commit = run(["/usr/bin/git", "rev-parse", "HEAD"], origin)
        job = case / str(uuid.uuid4())
        job.mkdir()
        lock = (case / "update.lock").open("a")
        if mode == "concurrent":
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            updater.update(job, commit, str(origin), destination, launch=False)
            assert mode == "success", "Unsafe update succeeded: " + mode
            with (destination / "Contents/Info.plist").open("rb") as stream:
                assert plistlib.load(stream)["OpenTeamsSourceRevision"] == commit
            assert json.loads((job / "status.json").read_text())["state"] == "installed"
            backups = list(destination.parent.glob(".OpenTeams-install.*/previous.app"))
            assert len(backups) == 1
            assert (backups[0] / "Contents/_CodeSignature/CodeResources").read_bytes() == before
        except (subprocess.CalledProcessError, RuntimeError):
            assert mode != "success", (job / "update.log").read_text()
            assert (destination / "Contents/_CodeSignature/CodeResources").read_bytes() == before
        finally:
            lock.close()
        print(mode + ": PASS", flush=True)
    invalid = root / "invalid"
    invalid.mkdir()
    shutil.copy2(repository / "script/update_app.py", invalid / "update_app.py")
    result = subprocess.run([sys.executable, str(invalid / "update_app.py"), "not-a-commit"], check=False)
    assert result.returncode == 1
    assert json.loads((invalid / "status.json").read_text())["state"] == "failed"
    assert not (invalid / "source").exists()
    print("invalid-revision-status: PASS", flush=True)

print("Updater process E2E passed. GUI and live GitHub access are separate checks.")
