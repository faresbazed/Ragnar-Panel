#!/usr/bin/env python3
"""Exercise the terminal domain setter without touching host services."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class TestDomainMenu(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="ragnar-domain-")
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.env = {k: v for k, v in os.environ.items()
                    if k not in ("RAGNAR_DOMAIN", "RAGNAR_CF_HOST")}
        self.env.update(RAGNAR_DIR=str(self.base), RAGNAR_HOST="203.0.113.10")
        (self.base / "settings.json").write_text(json.dumps({
            "domain": "old.example.com", "ns": "ns.example.com"}))
        (self.base / "domain").write_text("old.example.com\n")
        stub = self.base / "systemctl"
        stub.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$RAGNAR_DIR/restarts"\n')
        stub.chmod(0o755)
        self.env["PATH"] = str(self.base) + os.pathsep + self.env["PATH"]

    def set_domain(self, domain):
        menu = (ROOT / "menu.sh").read_text()
        function = menu[menu.index("cloudflared_menu() {"):]
        function = function[:function.index("\n# ---------------------------------------------------------------------")]
        script = '\n'.join([
            'CORE="$1"', function,
            'page_header() { :; }; section() { :; }; opt() { :; }',
            'svc_dot_cf() { :; }; pause() { :; }',
            'menu_choice() { read -r MENU_CHOICE; }',
            'cloudflared_menu',
        ])
        return subprocess.run(["bash", "-c", script, "domain-test", str(ROOT / "core/ragnar.py")],
                              input=f"1\n{domain}\n0\n", env=self.env,
                              capture_output=True, text=True, timeout=10)

    def resolved_domain(self):
        result = subprocess.run([
            "python3", "-c",
            "import ragnar; print(ragnar.load_settings()['domain'])"],
            cwd=ROOT / "core", env=self.env, capture_output=True, text=True, check=True)
        return result.stdout.strip()

    def test_set_domain_overrides_installed_settings(self):
        self.assertEqual(self.resolved_domain(), "old.example.com")
        result = self.set_domain("new.example.com")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.resolved_domain(), "new.example.com")
        settings = json.loads((self.base / "settings.json").read_text())
        self.assertEqual(settings["ns"], "ns.example.com")
        config = json.loads((self.base / "sing-box/config.json").read_text())
        self.assertEqual(config["inbounds"][0]["tls"]["server_name"], "new.example.com")
        self.assertIn("sing-box", (self.base / "restarts").read_text())

    def test_empty_domain_clears_settings_and_legacy_fallback(self):
        result = self.set_domain("")
        self.assertIn("saved", result.stdout)
        self.assertEqual(self.resolved_domain(), "")
        self.assertEqual((self.base / "domain").read_text().strip(), "")

    def test_settings_write_failure_does_not_report_saved(self):
        (self.base / "settings.json.tmp").mkdir()
        result = self.set_domain("new.example.com")
        self.assertNotIn("saved", result.stdout)
        self.assertIn("IsADirectoryError", result.stderr)
        self.assertEqual(self.resolved_domain(), "old.example.com")
        self.assertFalse((self.base / "restarts").exists())

    def test_without_settings_file(self):
        (self.base / "settings.json").unlink()
        result = self.set_domain("new.example.com")
        self.assertIn("saved", result.stdout)
        self.assertEqual(self.resolved_domain(), "new.example.com")


if __name__ == "__main__":
    unittest.main()
