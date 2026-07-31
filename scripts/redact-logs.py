#!/usr/bin/env python3
"""Scrub secret values out of the step logs before they are uploaded as an artifact.

GitHub masks registered secrets in the *live* log only. Artifact bytes are uploaded exactly
as written, so anything a Maven plugin echoed to stdout — a settings.xml dump, a wagon
authentication trace — would leave the runner in the clear.

Secret names come from CODIQO_REDACT_ENV_NAMES (newline or comma separated). Values are
replaced byte-wise, longest first, so a secret that contains another is not partly revealed.
Base64 forms are covered because HTTP Basic auth traces carry the credential encoded.

Best-effort by design: the caller ignores a non-zero exit and warns instead, because losing
the log artifact would cost more than it saves.
"""

import base64
import os
import re
import sys
from pathlib import Path

ALWAYS = ("CODIQO_API_KEY", "CODIQO_SETTINGS_XML")
MIN_LENGTH = 8
PLACEHOLDER = b"***"


def secret_names() -> list[str]:
    raw = os.environ.get("CODIQO_REDACT_ENV_NAMES", "")
    names = [part.strip() for chunk in raw.split("\n") for part in chunk.split(",")]
    names = [name for name in names if name]
    for name in ALWAYS:
        if name not in names:
            names.append(name)
    return names


def basic_auth_users() -> list[bytes]:
    """Usernames that could precede a secret in a Basic-auth header.

    Taken from the <username> elements of the settings.xml we were given, rather than a
    hardcoded list: that covers whatever registry the caller actually uses, and keeps this
    script free of any one provider's conventions.
    """
    settings = os.environb.get(b"CODIQO_SETTINGS_XML", b"")
    if not settings:
        return []
    found = re.findall(rb"<username>\s*(.*?)\s*</username>", settings, re.S)
    return [name for name in dict.fromkeys(found) if name]


def variants(value: bytes, users: list[bytes]) -> list[bytes]:
    """Every encoding of the secret that could plausibly appear in a log."""
    out = [value]
    if b"\n" in value:
        out.append(value.replace(b"\n", b"\r\n"))
    out.append(base64.b64encode(value))
    # Maven and wagon log Basic auth as base64("user:secret"), so the raw value alone is not
    # enough to catch a leaked credential.
    for user in users:
        out.append(base64.b64encode(user + b":" + value))
    return out


def collect() -> list[bytes]:
    needles: list[bytes] = []
    users = basic_auth_users()
    for name in secret_names():
        raw = os.environb.get(name.encode(), b"")
        if len(raw) < MIN_LENGTH:
            continue
        for candidate in variants(raw, users):
            if len(candidate) >= MIN_LENGTH and candidate not in needles:
                needles.append(candidate)
    # Longest first: otherwise a shorter secret that is a prefix of a longer one would be
    # replaced inside it and leave the remainder exposed.
    needles.sort(key=len, reverse=True)
    return needles


def main() -> int:
    logs_dir = Path(os.environ.get("CODIQO_LOGS_DIR", ""))
    if not logs_dir.is_dir():
        print(f"no log directory at {logs_dir}; nothing to redact")
        return 0

    needles = collect()
    if not needles:
        print("no secret values available to redact")
        return 0

    scrubbed = 0
    scanned = 0
    for path in sorted(logs_dir.rglob("*")):
        # Never follow a symlink: it could point outside the log directory.
        if path.is_symlink() or not path.is_file():
            continue
        scanned += 1
        try:
            data = path.read_bytes()
        except OSError as err:
            print(f"::warning::could not read {path.name}: {err}")
            continue
        original = data
        for needle in needles:
            if needle in data:
                data = data.replace(needle, PLACEHOLDER)
        if data != original:
            try:
                path.write_bytes(data)
                scrubbed += 1
            except OSError as err:
                print(f"::warning::could not rewrite {path.name}: {err}")

    print(f"redaction scanned {scanned} file(s), rewrote {scrubbed}, using {len(needles)} pattern(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
