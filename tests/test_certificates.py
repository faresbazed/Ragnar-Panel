#!/usr/bin/env python3
"""Exercise installer certificate handling without touching host services."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class TestCertificates(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="ragnar-certs-")
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.certs = self.base / "certs"
        self.certs.mkdir()
        self.live = self.base / "live/example.com"
        self.live.mkdir(parents=True)
        self.env = dict(os.environ, RAGNAR_DIR=str(self.base))
        (self.base / "domain").write_text("example.com\n")
        stub = self.base / "systemctl"
        stub.write_text('#!/bin/sh\n[ "$1" = is-active ] && exit 0\nprintf "%s\\n" "$*" >> "$RAGNAR_DIR/restarts"\n')
        stub.chmod(0o755)
        self.env["PATH"] = str(self.base) + os.pathsep + self.env["PATH"]
        for target, serial in ((self.certs, 1), (self.live, 2)):
            subprocess.run([
                "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                "-keyout", str(target / "privkey.pem"), "-out", str(target / "fullchain.pem"),
                "-days", "1", "-set_serial", str(serial), "-subj", "/CN=example.com",
                "-addext", "subjectAltName=DNS:example.com"],
                check=True, capture_output=True)
        (self.certs / "haproxy.pem").write_bytes(
            (self.certs / "fullchain.pem").read_bytes() + (self.certs / "privkey.pem").read_bytes())

    def install_certificates(self, update=1):
        source = (ROOT / "install.sh").read_text()
        block = source[source.index('# Certificates ('):source.index('# ZIVPN certificate')]
        block = block.replace('/etc/letsencrypt/live/$DOMAIN', str(self.live))
        block = block.replace('/etc/letsencrypt/renewal-hooks/deploy', str(self.base / 'hooks'))
        script = '\n'.join([
            'set -eu', 'BASE="$RAGNAR_DIR"', 'SRC="$1"', f'IS_UPDATE={update}',
            'DOMAIN=example.com; PUBIP=203.0.113.1; HOST_FOR_LINKS=example.com',
            'log() { :; }; warn() { :; }; die() { echo "$*" >&2; exit 1; }',
            'ragnar_backup_file() { :; }', block])
        return subprocess.run(["bash", "-c", script, "cert-test", str(ROOT)],
                              env=self.env, capture_output=True, text=True)

    def assert_consumers(self, serial):
        for name in ("fullchain.pem", "haproxy.pem"):
            with self.subTest(consumer=name):
                result = subprocess.check_output([
                    "openssl", "x509", "-in", str(self.certs / name), "-noout", "-serial"], text=True)
                self.assertEqual(result.strip(), f"serial={serial}")
                self.assertEqual((self.certs / name).stat().st_mode & 0o777, 0o600)
        self.assertEqual((self.certs / "privkey.pem").read_bytes(),
                         (self.live / "privkey.pem").read_bytes())
        # sing-box and the HTTPS panel read this same pair; Xray uses HAProxy TLS.
        self.assertIn('"certificate_path": cert', (ROOT / "core/ragnar.py").read_text())
        self.assertIn('ctx.load_cert_chain(cert, key)', (ROOT / "web/webpanel.py").read_text())

    def test_same_domain_update_and_reinstall_use_renewed_certificate(self):
        for update in (1, 0):
            with self.subTest(update=update):
                result = self.install_certificates(update)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assert_consumers("02")

    def test_deploy_hook_updates_consumers_and_running_services(self):
        old = {p.name: p.read_bytes() for p in self.certs.iterdir()}
        self.assertEqual(self.install_certificates().returncode, 0)
        for name, data in old.items():
            (self.certs / name).write_bytes(data)
        result = subprocess.run(["bash", str(ROOT / "core/cert-deploy.sh")],
                                env=dict(self.env, RENEWED_LINEAGE=str(self.live)),
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_consumers("02")
        self.assertEqual((self.base / "restarts").read_text().splitlines(),
                         ["reload haproxy", "restart sing-box", "restart ragnar-web"])

    def test_missing_lineage_preserves_existing_certificate(self):
        (self.live / "fullchain.pem").unlink()
        result = self.install_certificates()
        self.assertEqual(result.returncode, 0, result.stderr)
        serial = subprocess.check_output(["openssl", "x509", "-in", str(self.certs / "haproxy.pem"),
                                          "-noout", "-serial"], text=True)
        self.assertEqual(serial.strip(), "serial=01")

    def test_invalid_key_does_not_replace_files_or_reload(self):
        (self.live / "privkey.pem").write_bytes((self.certs / "privkey.pem").read_bytes())
        before = {p.name: p.read_bytes() for p in self.certs.iterdir()}
        result = self.install_certificates()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual({p.name: p.read_bytes() for p in self.certs.iterdir()}, before)
        self.assertFalse((self.base / "restarts").exists())

    def test_wrong_domain_does_not_replace_files(self):
        (self.base / "domain").write_text("other.example.com\n")
        before = {p.name: p.read_bytes() for p in self.certs.iterdir()}
        result = self.install_certificates()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual({p.name: p.read_bytes() for p in self.certs.iterdir()}, before)

    def test_hook_ignores_empty_and_unrelated_lineages(self):
        for lineage in ("", str(self.base / "unrelated")):
            with self.subTest(lineage=lineage):
                result = subprocess.run(["bash", str(ROOT / "core/cert-deploy.sh")],
                                        env=dict(self.env, RENEWED_LINEAGE=lineage),
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertFalse((self.base / "restarts").exists())
        self.assertEqual(self.install_certificates().returncode, 0)
        for lineage in ("", str(self.base / "unrelated")):
            result = subprocess.run(["bash", str(ROOT / "core/cert-deploy.sh")],
                                    env=dict(self.env, RENEWED_LINEAGE=lineage),
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse((self.base / "restarts").exists())


if __name__ == "__main__":
    unittest.main()
