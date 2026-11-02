#!/usr/bin/env python3
"""Fail publication if the feed, archive signature or embedded app configuration disagree."""
import base64
import os
import pathlib
import plistlib
import sys
import xml.etree.ElementTree as ET

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey


def validate(feed_path, archive_path, plist_path, download_prefix):
    app = plistlib.loads(pathlib.Path(plist_path).read_bytes())
    items = ET.parse(feed_path).findall("./channel/item")
    assert len(items) == 1, "Expected exactly one release in the appcast"
    item = items[0]
    ns = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
    enclosure = item.find("enclosure")
    assert enclosure is not None, "Missing update archive"
    archive = pathlib.Path(archive_path)
    assert enclosure.get("url") == download_prefix + "Lumik.dmg", "Wrong download URL"
    assert int(enclosure.get("length", "0")) == archive.stat().st_size, "Wrong archive length"
    assert item.findtext(ns + "version") == app["CFBundleVersion"] == os.environ["BUILD_NUMBER"], "Wrong build number"
    assert item.findtext(ns + "shortVersionString") == app["CFBundleShortVersionString"] == os.environ["VERSION"].removeprefix("v"), "Wrong marketing version"
    assert item.findtext(ns + "minimumSystemVersion") == "26.0", "Wrong minimum macOS version"
    assert app["SUFeedURL"] == "https://update.lumik.dev/appcast.xml", "Wrong feed URL"
    assert item.findtext(ns + "releaseNotesLink") == "https://update.lumik.dev/Lumik.html", "Wrong release notes URL"
    key = Ed25519PublicKey.from_public_bytes(base64.b64decode(app["SUPublicEDKey"], validate=True))
    key.verify(base64.b64decode(enclosure.get(ns + "edSignature", ""), validate=True), archive.read_bytes())
    print("Verified appcast URLs, versions, minimum OS, length and EdDSA signature against the app's public key")


if __name__ == "__main__":
    validate(*sys.argv[1:])
