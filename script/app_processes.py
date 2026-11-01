#!/usr/bin/env python3
"""Find and stop only this project's staged apps and its installed app."""
import ctypes
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

libproc = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
libproc.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
libproc.proc_pidpath.restype = ctypes.c_int


def executable(pid):
    buffer = ctypes.create_string_buffer(4096)
    if libproc.proc_pidpath(pid, buffer, len(buffer)) <= 0:
        return None
    return os.path.realpath(os.fsdecode(buffer.value))


def matching(paths):
    paths = {os.path.realpath(str(path)) for path in paths}
    result = subprocess.run(['/bin/ps', '-axo', 'pid=,uid='], check=True, capture_output=True, text=True)
    found = []
    for line in result.stdout.splitlines():
        fields = line.split()
        if len(fields) != 2 or int(fields[1]) != os.getuid():
            continue
        pid = int(fields[0])
        if pid != os.getpid() and executable(pid) in paths:
            found.append(pid)
    return found


def stop(paths):
    paths = {os.path.realpath(str(path)) for path in paths}
    for pid in matching(paths):
        if executable(pid) in paths:
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
    deadline = time.monotonic() + 10
    while matching(paths):
        if time.monotonic() >= deadline:
            raise SystemExit('An OpenTeams app did not stop; refusing to replace its bundle.')
        time.sleep(0.1)


def main():
    root = Path(__file__).resolve().parent.parent
    staged = root / 'dist/OpenTeams.app/Contents/MacOS/OpenTeams'
    paths = [staged, root / 'dist/TeamsChat.app/Contents/MacOS/TeamsChat',
             Path('/Applications/OpenTeams.app/Contents/MacOS/OpenTeams')]
    if sys.argv[1:] == ['stop']:
        stop(paths)
    elif sys.argv[1:] == ['verify-staged']:
        if not matching([staged]):
            raise SystemExit('The staged OpenTeams executable is not running.')
    else:
        raise SystemExit('usage: app_processes.py stop|verify-staged')


if __name__ == '__main__':
    main()
