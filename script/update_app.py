import fcntl
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys


REPOSITORY = "https://github.com/hxutixnnn/OpenTeams.git"
DESTINATION = Path("/Applications/OpenTeams.app")


def write_status(job, state, message, commit):
    temporary = job / "status.tmp"
    temporary.write_text(json.dumps({"state": state, "message": message,
                                     "commit": commit, "pid": os.getpid()}))
    temporary.replace(job / "status.json")


def run(command, cwd, log, timeout=1800):
    subprocess.run(command, cwd=cwd, stdout=log, stderr=subprocess.STDOUT,
                   stdin=subprocess.DEVNULL, timeout=timeout, check=True)


def update(job, commit, repository=REPOSITORY, destination=DESTINATION, launch=True):
    if not re.fullmatch(r"[a-f0-9]{40}", commit):
        raise ValueError("Invalid update revision.")
    with (job.parent / "update.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError("Another OpenTeams update is already running.")
        current = job.parent / ("current." + job.name)
        current.write_text(job.name)
        current.replace(job.parent / "current")
        with (job / "update.log").open("a", buffering=1) as log:
            source = job / "source"
            write_status(job, "downloading", "Downloading the selected update…", commit)
            run(["/usr/bin/git", "init", str(source)], job, log, 30)
            run(["/usr/bin/git", "remote", "add", "origin", repository], source, log, 30)
            run(["/usr/bin/git", "-c", "credential.helper=", "fetch", "--depth=1", "origin", commit], source, log, 300)
            run(["/usr/bin/git", "checkout", "--detach", commit], source, log, 30)
            actual = subprocess.check_output(["/usr/bin/git", "rev-parse", "HEAD"], cwd=source, text=True).strip()
            if actual != commit:
                raise RuntimeError("The downloaded revision does not match the selected update.")
            write_status(job, "building", "Building and signing the update. This may take several minutes…", commit)
            run(["/bin/bash", "script/build_and_run.sh", "--build-only"], source, log)
            candidate = source / "dist/OpenTeams.app"
            with (candidate / "Contents/Info.plist").open("rb") as stream:
                metadata = plistlib.load(stream)
            if metadata.get("OpenTeamsSourceRevision") != commit:
                raise RuntimeError("The built app does not match the selected update.")
            run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(candidate)], source, log, 30)
            write_status(job, "installing", "Installing the update. OpenTeams will restart…", commit)
            run(["/bin/bash", "script/install.sh", "--no-launch"], source, log, 120)
            with (destination / "Contents/Info.plist").open("rb") as stream:
                installed = plistlib.load(stream)
            if installed.get("OpenTeamsSourceRevision") != commit:
                raise RuntimeError("The installed app does not match the selected update.")
            write_status(job, "installed", "Update installed successfully.", commit)
            if launch:
                run(["/usr/bin/open", "-n", str(destination)], job, log, 30)


def main():
    job = Path(__file__).resolve().parent
    commit = sys.argv[1] if len(sys.argv) == 2 else ""
    try:
        write_status(job, "starting", "Starting the update…", commit)
        update(job, commit)
    except Exception as error:
        try:
            was_installing = json.loads((job / "status.json").read_text())["state"] == "installing"
        except (OSError, ValueError, KeyError):
            was_installing = False
        write_status(job, "failed", "Update failed: " + str(error) + " See the update log for details.", commit)
        if was_installing and DESTINATION.is_dir():
            try:
                identity = (Path.home() / "Library/Application Support/TeamsChat/signing-identity").read_text().strip()
                if re.fullmatch(r"[A-Fa-f0-9]{40}", identity):
                    requirement = 'identifier "dev.native.teamschat" and certificate leaf = H"' + identity.lower() + '"'
                    verified = subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", "-R", requirement, str(DESTINATION)],
                                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    if verified.returncode == 0:
                        subprocess.run(["/usr/bin/open", "-n", str(DESTINATION)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            except OSError:
                pass
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
