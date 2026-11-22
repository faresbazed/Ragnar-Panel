"""Exercise the terminal picker against a disposable, synthetic account."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / "core/ragnar.py"


class TestXrayLinkMenu(unittest.TestCase):
    def setUp(self):
        state = tempfile.TemporaryDirectory()
        self.addCleanup(state.cleanup)
        base = Path(state.name)
        self.env = dict(os.environ, RAGNAR_DIR=state.name, RAGNAR_CORE=str(CORE),
                        RAGNAR_DOMAIN="vpn.example.test", RAGNAR_CF_HOST="cdn.example.test",
                        NO_COLOR="1", PATH=f"{base}:{os.environ['PATH']}")
        (base / "host").write_text("192.0.2.10\n")
        stub = base / "systemctl"
        stub.write_text("#!/bin/sh\nexit 0\n")
        stub.chmod(0o755)
        self.core("xray-add", "demo", "30", "--no-links")
        self.routes = json.loads(self.core("xray-links", "demo", "--json"))

    def core(self, *args):
        return subprocess.check_output(["python3", CORE, *args], text=True, env=self.env)

    def menu(self, action, keys):
        return subprocess.run(["bash", "-c", 'source "$1"; "$2"', "test", ROOT / "menu.sh", action],
                              input=keys, text=True, env=self.env, capture_output=True,
                              check=True, timeout=10).stdout

    def test_catalog_and_every_exact_uri(self):
        pairs = [tuple(row.split("\t")) for row in self.core("xray-links", "demo", "--catalog").splitlines()]
        self.assertEqual(pairs, [(r, p) for r, entries in self.routes.items() for p in entries])
        for route, proto in pairs:
            with self.subTest(route=route, proto=proto):
                self.assertEqual(self.core("xray-links", "demo", "--one", route, proto),
                                 self.routes[route][proto] + "\n")

    def test_browsing_cancel_and_invalid_choices_do_not_reveal_links(self):
        out = self.menu("xray_links", "demo\nbad\n\na\nn\n4\nb\n0\n")
        for label in ("DIRECT", "CLOUDFLARE", "Fallback", "Reveal all 18 links", "VMess"):
            self.assertIn(label, out)
        self.assertNotIn("://", out)
        missing = self.menu("xray_links", "missing\n\n")
        self.assertIn("not found", missing)
        self.assertNotIn("Reveal all", missing)

    def test_route_first_and_protocol_first_print_only_the_selected_uri(self):
        for action, keys, route, proto in [
                ("xray_links", "4\n3", "WSS · port 443 (Cloudflare)", "TROJAN"),
                ("xray_copy_one", "5\n2", "AnyTLS · port 8446 (direct fallback)", "ANYTLS")]:
            with self.subTest(action=action):
                out = self.menu(action, f"demo\n{keys}\n\n0\n0\n")
                self.assertEqual([line for line in out.splitlines() if "://" in line],
                                 [self.routes[route][proto]])

    def test_explicit_bulk_output_matches_cli(self):
        out = self.menu("xray_links", "demo\na\ny\n\n0\n")
        self.assertIn(self.core("xray-links", "demo"), out)

    def test_add_and_edit_do_not_dump_links(self):
        out = self.menu("xray_create", "new-user\n30\n0\n0\n\n0\n")
        self.assertIn("Account created: new-user", out)
        self.assertNotIn("://", out)
        out = self.menu("xray_edit", "new-user\n2\n50\n\n")
        self.assertIn("saved.", out)
        self.assertNotIn("://", out)


if __name__ == "__main__":
    unittest.main()
