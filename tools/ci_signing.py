"""Creates a short-lived App Store distribution certificate and provisioning profile through the
App Store Connect FXI, for the manual release workflow, and removes them again afterwards.

Why: exporting an unsigned archive with cloud signing left the embedded Google frameworks unsigned,
and the upload was rejected. Signing everything with one real distribution certificate avoids that.

Usage (needs PyJWT + cryptography, and openssl on the path):
  python3 tools/ci_signing.py create  <workdir>   -> writes cert.p12, profile.mobileprovision, state.json
  python3 tools/ci_signing.py cleanup <workdir>   -> deletes the certificate and profile named in state.json
Environment: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH, BUNDLE_ID, P12_PASSWORD
"""
import base64
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

import jwt

FXI = "https://api.appstoreconnect.apple.com"


def token() -> str:
    key = Path(os.environ["ASC_KEY_PATH"]).read_text()
    now = int(time.time())
    return jwt.encode(
        {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"},
        key,
        algorithm="ES256",
        headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"},
    )


def call(method: str, path: str, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(FXI + path, data=data, method=method)
    req.add_header("Authorization", "Bearer " + token())
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as err:
        print(f"{method} {path} failed: {err.code} {err.read().decode()[:800]}", file=sys.stderr)
        raise


def run(*cmd):
    subprocess.run(cmd, check=True)


def create(work: Path) -> None:
    work.mkdir(parents=True, exist_ok=True)
    key, csr = work / "key.pem", work / "csr.pem"
    run("openssl", "genrsa", "-out", str(key), "2048")
    run("openssl", "req", "-new", "-key", str(key), "-out", str(csr),
        "-subj", "/CN=Fluxa CI/O=Ecom Swift LLC/C=US")

    cert = call("POST", "/v1/certificates", {"data": {"type": "certificates", "attributes": {
        "certificateType": "DISTRIBUTION", "csrContent": csr.read_text()}}})["data"]
    cert_id = cert["id"]
    (work / "cert.der").write_bytes(base64.b64decode(cert["attributes"]["certificateContent"]))
    run("openssl", "x509", "-inform", "DER", "-in", str(work / "cert.der"), "-out", str(work / "cert.pem"))
    run("openssl", "pkcs12", "-export", "-inkey", str(key), "-in", str(work / "cert.pem"),
        "-out", str(work / "cert.p12"), "-passout", "pass:" + os.environ["P12_PASSWORD"],
        # macOS `security import` cannot read the AES-based default of OpenSSL 3.
        "-certpbe", "PBE-SHA1-3DES", "-keypbe", "PBE-SHA1-3DES", "-macalg", "sha1")

    ident = os.environ["BUNDLE_ID"]
    bundles = call("GET", "/v1/bundleIds?filter%5Bidentifier%5D=" + ident + "&limit=200")["data"]
    bundle_id = next(b["id"] for b in bundles if b["attributes"]["identifier"] == ident)

    name = f"Fluxa CI {int(time.time())}"
    profile = call("POST", "/v1/profiles", {"data": {
        "type": "profiles",
        "attributes": {"name": name, "profileType": "IOS_APP_STORE"},
        "relationships": {
            "bundleId": {"data": {"type": "bundleIds", "id": bundle_id}},
            "certificates": {"data": [{"type": "certificates", "id": cert_id}]},
        }}})["data"]
    (work / "profile.mobileprovision").write_bytes(base64.b64decode(profile["attributes"]["profileContent"]))
    state = {"certificate_id": cert_id, "profile_id": profile["id"], "profile_name": name,
             "profile_uuid": profile["attributes"]["uuid"]}
    (work / "state.json").write_text(json.dumps(state))
    print("created", {k: v for k, v in state.items() if k != "profile_uuid"})


def cleanup(work: Path) -> None:
    state_file = work / "state.json"
    if not state_file.exists():
        return
    state = json.loads(state_file.read_text())
    for kind, key in (("profiles", "profile_id"), ("certificates", "certificate_id")):
        try:
            call("DELETE", f"/v1/{kind}/{state[key]}")
            print("deleted", kind, state[key])
        except urllib.error.HTTPError:
            pass


if __name__ == "__main__":
    action, folder = sys.argv[1], Path(sys.argv[2])
    {"create": create, "cleanup": cleanup}[action](folder)
