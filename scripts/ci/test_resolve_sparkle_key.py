import base64
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("resolver", Path(__file__).with_name("resolve-sparkle-key.py"))
resolver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(resolver)


class ResolveKeyTests(unittest.TestCase):
    # RFC 8032 test vector 1.
    seed = base64.b64encode(bytes.fromhex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")).decode()
    public = base64.b64encode(bytes.fromhex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")).decode()

    def test_derive_seed(self):
        self.assertEqual(resolver.resolve(self.seed), self.public)

    def test_matching_configuration(self):
        self.assertEqual(resolver.resolve(self.seed, self.public), self.public)

    def test_mismatch_rejected(self):
        with self.assertRaisesRegex(ValueError, "does not match"):
            resolver.resolve(self.seed, "wrong")

    def test_invalid_secret_rejected_without_echo(self):
        for secret in ["", "not-a-key", base64.b64encode(bytes(64)).decode()]:
            with self.subTest(secret=secret), self.assertRaises(ValueError):
                resolver.resolve(secret)

    def test_legacy_key(self):
        legacy = base64.b64encode(bytes(64) + base64.b64decode(self.public)).decode()
        self.assertEqual(resolver.resolve(legacy), self.public)


if __name__ == "__main__":
    unittest.main()
