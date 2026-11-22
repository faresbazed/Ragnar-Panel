#!/usr/bin/env python3
"""Exercise the terminal domain setter without touching host services."""
import json
import os
import signal
from pathlib import Path
import subprocess
import tempfile
import time
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

    def set_domain(self, domain, fail_writes=False):
        menu = (ROOT / "menu.sh").read_text()
        function = menu[menu.index("cloudflared_menu() {"):]
        function = function[:function.index("\n# ---------------------------------------------------------------------")]
        script = '\n'.join([
            'CORE="$1"', function,
            'page_header() { :; }; section() { :; }; opt() { :; }',
            'svc_dot_cf() { :; }; pause() { :; }',
            'menu_choice() { read -r MENU_CHOICE; }',
            'ulimit -f 0' if fail_writes else ':',
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
        result = self.set_domain("new.example.com", fail_writes=True)
        self.assertNotIn("saved", result.stdout)
        self.assertIn("File too large", result.stderr)
        self.assertEqual(self.resolved_domain(), "old.example.com")
        self.assertFalse((self.base / "restarts").exists())

    def test_without_settings_file(self):
        (self.base / "settings.json").unlink()
        result = self.set_domain("new.example.com")
        self.assertIn("saved", result.stdout)
        self.assertEqual(self.resolved_domain(), "new.example.com")

    def test_quick_tunnel_exit_returns_to_menu(self):
        menu = (ROOT / "menu.sh").read_text()
        function = menu[menu.index("cloudflared_menu() {"):]
        function = function[:function.index("\n# ---------------------------------------------------------------------")]
        script = '\n'.join([
            function,
            'page_header() { :; }; section() { :; }; opt() { :; }',
            'svc_dot_cf() { :; }; pause() { :; }',
            'menu_choice() { read -r MENU_CHOICE; }',
            'cloudflared_menu',
            'echo MENU_RETURNED',
            'test -z "$(trap -p INT)"',
        ])
        for status in (0, 7):
            with self.subTest(status=status):
                stub = self.base / "cloudflared"
                stub.write_text(f'#!/bin/sh\nexit {status}\n')
                stub.chmod(0o755)
                result = subprocess.run(["bash", "-c", script], input="4\n0\n",
                                        env=self.env, capture_output=True,
                                        text=True, timeout=5)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("MENU_RETURNED", result.stdout)

    def test_quick_tunnel_lives_until_interrupted(self):
        stub = self.base / "cloudflared"
        stub.write_text('''#!/usr/bin/env python3
import os, signal, time
from pathlib import Path
base = Path(os.environ["RAGNAR_DIR"])
def stop(signum, frame):
    (base / "stopped").write_text(signal.Signals(signum).name)
    raise SystemExit(0)
signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)
(base / "pid").write_text(str(os.getpid()))
print("https://xxx.trycloudflare.com", flush=True)
print("\\n".join("log line %d" % i for i in range(40)), flush=True)
while True:
    time.sleep(0.1)
''')
        stub.chmod(0o755)
        menu = (ROOT / "menu.sh").read_text()
        function = menu[menu.index("cloudflared_menu() {"):]
        function = function[:function.index("\n# ---------------------------------------------------------------------")]
        script = '\n'.join([
            function,
            'page_header() { echo MENU; }; section() { :; }; opt() { :; }',
            'svc_dot_cf() { :; }; pause() { :; }',
            'menu_choice() { read -r MENU_CHOICE; }',
            'cloudflared_menu',
            'echo MENU_RETURNED',
            'test -z "$(trap -p INT)"',
        ])
        proc = subprocess.Popen(["bash", "-c", script], env=self.env,
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True,
                                start_new_session=True)
        try:
            proc.stdin.write("4\n")
            proc.stdin.flush()
            deadline = time.monotonic() + 5
            while not (self.base / "pid").exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue((self.base / "pid").exists(), "cloudflared did not start")
            pid = int((self.base / "pid").read_text())
            time.sleep(12)
            stopped = self.base / "stopped"
            self.assertFalse(stopped.exists(),
                             f"quick tunnel stopped before admin interrupt: {stopped.read_text() if stopped.exists() else ''}")
            os.kill(pid, 0)
            os.killpg(proc.pid, signal.SIGINT)
            output, _ = proc.communicate("0\n", timeout=5)
            self.assertEqual(proc.returncode, 0, output)
            self.assertEqual(stopped.read_text(), "SIGINT")
            self.assertIn("https://xxx.trycloudflare.com", output)
            self.assertIn("log line 39", output)
            self.assertEqual(output.count("MENU\n"), 2, output)
            self.assertIn("MENU_RETURNED", output)
            self.assertIn("Ctrl+C", output)
            with self.assertRaises(ProcessLookupError):
                os.kill(pid, 0)
        finally:
            if proc.poll() is None:
                os.killpg(proc.pid, signal.SIGKILL)
            proc.communicate()


if __name__ == "__main__":
    unittest.main()
