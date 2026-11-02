import base64
import importlib.util
import os
import pathlib
import plistlib
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

spec = importlib.util.spec_from_file_location("validator", pathlib.Path(__file__).with_name("validate-appcast.py"))
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)


class ArchiveSignatureTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        directory = pathlib.Path(self.directory.name)
        self.archive = directory / "Lumik.dmg"
        self.archive.write_bytes(b"signed release archive")
        key = Ed25519PrivateKey.generate()
        public = key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
        signature = base64.b64encode(key.sign(self.archive.read_bytes())).decode()
        self.plist = directory / "Info.plist"
        self.plist.write_bytes(plistlib.dumps({"CFBundleVersion": "42", "CFBundleShortVersionString": "2.0.1",
            "SUPublicEDKey": base64.b64encode(public).decode(),
            "SUFeedURL": "https://update.lumik.dev/appcast.xml"}))
        self.prefix = "https://update.lumik.dev/v2.0.1/"
        self.feed = directory / "appcast.xml"
        self.feed.write_text(f'''<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
            <sparkle:version>42</sparkle:version><sparkle:shortVersionString>2.0.1</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
            <sparkle:releaseNotesLink>https://update.lumik.dev/Lumik.html</sparkle:releaseNotesLink>
            <enclosure url="{self.prefix}Lumik.dmg" length="{self.archive.stat().st_size}" sparkle:edSignature="{signature}"/>
            </item></channel></rss>''')
        environment = patch.dict(os.environ, {"VERSION": "v2.0.1", "BUILD_NUMBER": "42"})
        environment.start()
        self.addCleanup(environment.stop)

    def validate(self):
        validator.validate(self.feed, self.archive, self.plist, self.prefix)

    def test_accepts_matching_signed_archive(self):
        self.validate()

    def test_rejects_same_length_tampered_archive(self):
        self.archive.write_bytes(b"tamper" + self.archive.read_bytes()[6:])
        with self.assertRaises(InvalidSignature):
            self.validate()

    def test_rejects_signature_from_different_key(self):
        app = plistlib.loads(self.plist.read_bytes())
        key = Ed25519PrivateKey.generate().public_key()
        app["SUPublicEDKey"] = base64.b64encode(key.public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)).decode()
        self.plist.write_bytes(plistlib.dumps(app))
        with self.assertRaises(InvalidSignature):
            self.validate()

    def test_rejects_feed_pointing_to_another_archive(self):
        tree = ET.parse(self.feed)
        tree.find("./channel/item/enclosure").set("url", "https://example.com/untrusted.dmg")
        tree.write(self.feed)
        with self.assertRaisesRegex(AssertionError, "Wrong download URL"):
            self.validate()


if __name__ == "__main__":
    unittest.main()
