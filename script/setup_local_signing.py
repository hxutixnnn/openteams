#!/usr/bin/env python3
"""Create a local-only code-signing identity in the login keychain once."""
import os
import pathlib
import subprocess
import tempfile

name = "TeamsChat Local Development"
keychain = pathlib.Path.home() / "Library/Keychains/login.keychain-db"
existing = subprocess.run(["security", "find-certificate", "-c", name, str(keychain)], capture_output=True)
if existing.returncode == 0:
    raise SystemExit("A certificate with this name already exists; inspect it before creating another.")
with tempfile.TemporaryDirectory(prefix="teamschat-signing-") as directory:
    os.chmod(directory, 0o700)
    key = os.path.join(directory, "key.pem")
    cert = os.path.join(directory, "cert.pem")
    bundle = os.path.join(directory, "identity.p12")
    subprocess.run(["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:3072", "-nodes", "-days", "3650",
                    "-subj", "/CN=" + name, "-addext", "extendedKeyUsage=codeSigning",
                    "-addext", "keyUsage=digitalSignature", "-keyout", key, "-out", cert],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    os.chmod(key, 0o600)
    traditional = os.path.join(directory, "traditional.pem")
    subprocess.run(["/usr/bin/openssl", "rsa", "-in", key, "-out", traditional],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    os.chmod(traditional, 0o600)
    subprocess.run(["security", "import", traditional, "-k", str(keychain), "-t", "priv", "-f", "openssl",
                    "-T", "/usr/bin/codesign"], check=True)
    subprocess.run(["security", "import", cert, "-k", str(keychain), "-t", "cert", "-f", "pemseq"], check=True)
identities = subprocess.run(["security", "find-identity", "-p", "codesigning", str(keychain)],
                            check=True, capture_output=True, text=True).stdout
matches = [line.split('"')[0].split()[-1] for line in identities.splitlines() if '"' + name + '"' in line]
if len(matches) != 1 or len(matches[0]) != 40:
    raise SystemExit("Could not identify the new signing certificate uniquely; inspect Keychain Access.")
identity_file = pathlib.Path.home() / "Library/Application Support/TeamsChat/signing-identity"
identity_file.parent.mkdir(parents=True, exist_ok=True)
identity_file.write_text(matches[0] + "\n")
identity_file.chmod(0o600)
print("Local signing identity created in the login keychain.")
