#!/usr/bin/env python3
"""Resolve the public update key without exposing or replacing the signing secret."""
import base64
import binascii
import os
import sys

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey


def resolve(secret, configured=""):
    try:
        raw = base64.b64decode(secret.strip(), validate=True)
    except (ValueError, binascii.Error):
        raise ValueError("SPARKLE_KEY must be a base64 Sparkle signing key") from None
    if len(raw) == 32:
        public = Ed25519PrivateKey.from_private_bytes(raw).public_key().public_bytes(
            serialization.Encoding.Raw, serialization.PublicFormat.Raw
        )
    elif len(raw) == 96:
        # Sparkle's legacy export contains a 64-byte private key then its public key.
        public = raw[64:]
    else:
        raise ValueError("SPARKLE_KEY must decode to a 32-byte seed or 96-byte legacy key")
    encoded = base64.b64encode(public).decode("ascii")
    if configured.strip() and configured.strip() != encoded:
        raise ValueError("SPARKLE_PUBLIC_KEY does not match SPARKLE_KEY")
    return encoded


if __name__ == "__main__":
    try:
        public = resolve(os.environ.get("SPARKLE_KEY", ""), os.environ.get("SPARKLE_PUBLIC_KEY", ""))
        with open(os.environ["GITHUB_ENV"], "a") as environment:
            environment.write(f"SPARKLE_PUBLIC_KEY={public}\n")
        print("Resolved Sparkle public key for the release build")
    except ValueError as error:
        print(f"::error::{error}", file=sys.stderr)
        sys.exit(1)
