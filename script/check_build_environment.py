import re
import subprocess
import sys


def version(command):
    result = subprocess.run(command, capture_output=True, text=True, timeout=15, check=True)
    return result.stdout.strip()


def check():
    os_version = version(['/usr/bin/sw_vers', '-productVersion'])
    if int(os_version.split('.')[0]) < 27:
        raise RuntimeError('OpenTeams requires macOS 27 or later. Update macOS before installing this version.')
    sdk = version(['/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-version'])
    if int(sdk.split('.')[0]) < 27:
        raise RuntimeError('Install Command Line Tools or Xcode with the macOS 27 SDK, then select it with xcode-select.')
    compiler = version(['/usr/bin/xcrun', 'swift', '--version'])
    match = re.search(r'Swift version (\d+)\.(\d+)', compiler)
    if not match or tuple(map(int, match.groups())) < (6, 4):
        raise RuntimeError('OpenTeams requires Swift 6.4 or later. Update the selected Command Line Tools or Xcode.')


if __name__ == '__main__':
    try:
        check()
    except (OSError, ValueError, subprocess.SubprocessError, RuntimeError) as error:
        print('Build prerequisites unavailable: ' + str(error) + '\nInstall compatible Apple developer tools and select them with xcode-select.')
        sys.exit(1)
