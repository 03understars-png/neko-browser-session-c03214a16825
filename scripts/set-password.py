import hashlib, os, plistlib, subprocess, sys

user = sys.argv[1]
password = sys.stdin.read().rstrip("\n").encode()
salt = os.urandom(32)
iterations = 45000
entropy = hashlib.pbkdf2_hmac("sha512", password, salt, iterations, dklen=128)
shadow = plistlib.dumps({"SALTED-SHA512-PBKDF2": {"entropy": entropy, "salt": salt, "iterations": iterations}},
                        fmt=plistlib.FMT_BINARY)
record = f"/var/db/dslocal/nodes/Default/users/{user}.plist"
with open(record, "rb") as handle:
    data = plistlib.load(handle)
data["ShadowHashData"] = [shadow]
with open(record, "wb") as handle:
    plistlib.dump(data, handle, fmt=plistlib.FMT_BINARY)
subprocess.run(["killall", "opendirectoryd"], check=False)
