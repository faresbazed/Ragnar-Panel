"""Run the real updater and downloaded installer against an unprivileged fake host."""
import fcntl
import json
import os
import re
import shutil
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SHA = "ab" * 20


class UpgradeTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(prefix="ragnar-upgrade-")
        self.addCleanup(tmp.cleanup)
        self.host = Path(tmp.name)
        self.base = self.host / "etc/ragnar"
        self.bin = self.host / "bin"
        self.bin.mkdir()
        # No inherited PATH: systemd, apt, network and firewall commands can
        # never reach the host. Prefix absolute host paths in the fixture copy.
        for cmd in ("awk bash basename cat chmod cmp cp date dirname flock grep gzip "
                    "head install ln mkdir mktemp mv python3 rm rmdir sed tar tee "
                    "touch tr uname").split():
            (self.bin / cmd).symlink_to(shutil.which(cmd))
        for cmd in ("cloudflared dropbear ip jq netfilter-persistent openssl "
                    "sing-box socat systemctl vnstat wget xray").split():
            self.shim(cmd, "exit 0")
        self.shim("id", "echo 0")
        self.shim("git", f'[ "$1" = ls-remote ] && echo "{SHA} refs/heads/main"')
        self.shim("haproxy", '[ -z "$FAIL_HAPROXY" ]')
        self.shim("sysctl", "echo 33554432")
        for fw in ("iptables", "ip6tables"):
            self.shim(fw, 'case " $* " in *" -D "*) exit 1;; esac')
        self.shim("curl", '''
case "$*" in
    *codeload.github.com*) while [ "$1" != -o ]; do shift; done; cp "$ARCHIVE" "$2";;
    *api.ipify.org*) echo 192.0.2.1;;
    *) exit 1;;
esac''')
        for path in ("tmp", "root", "etc/sysctl.d", "etc/default", "etc/iptables",
                     "etc/systemd/system", "usr/local/bin", "var/lock"):
            (self.host / path).mkdir(parents=True, exist_ok=True)
        self.write(self.host / "etc/os-release", "ID=debian\n")
        self.write(self.host / "etc/security/limits.conf", "")
        self.write(self.host / "etc/shells", "/bin/false\n/usr/bin/false\n")
        self.shim("hostname", "echo test-host")
        self.write(self.host / "etc/hosts", "127.0.1.1 test-host\n")
        for name in ("zivpn", "udp-custom", "badvpn-udpgw", "dnstt-server"):
            self.write(self.host / "usr/local/bin" / name, "#!/bin/sh\nexit 1\n", 0o755)
        self.write(self.host / "usr/local/bin/menu", "pre-panel menu\n")

        self.src = self.host / ("release-" + SHA)
        self.src.mkdir()
        for name in ("core", "web", "configs"):
            shutil.copytree(ROOT / name, self.src / name, ignore=shutil.ignore_patterns("__pycache__"))
        for name in ("install.sh", "uninstall.sh", "menu.sh"):
            shutil.copyfile(ROOT / name, self.src / name)
        for script in self.src.rglob("*.sh"):
            source = re.sub(r"/(?:usr/local|etc|tmp|root|run|var/(?:lib|lock|log|tmp))\b",
                            lambda m: str(self.host) + m[0], script.read_text())
            script.write_text(source)
        self.archive = self.host / "download.tgz"
        with tarfile.open(self.archive, "w:gz") as tar:
            tar.add(self.src, arcname=self.src.name)
        self.env = {"PATH": str(self.bin), "RAGNAR_DIR": str(self.base),
                    "ARCHIVE": str(self.archive), "LC_ALL": "C"}
        settings = {"domain": "example.test", "ns": "ns.example.test",
                    "slowdns_pubkey": "public", "slowdns_mtu": 1200,
                    "slowdns_resolver": "192.0.2.53", "slowdns_target": 109,
                    "ss_server_key": "existing", "custom": {"extra": [1, 2]}}
        users = {"live": {"password": "test", "expiry": "2099-01-01"},
                 "locked": {"password": "off", "expiry": "2099-01-01", "enabled": False}}
        self.saved = {
            "settings.json": json.dumps(settings), "host": "operator-host\n",
            "domain": "example.test\n", "isp": "operator-isp\n",
            "db/ssh.json": json.dumps({"users": users}),
            "db/xray.json": json.dumps({"users": {"client": dict(users["live"], uuid="id", ss_password="ss")}}),
            "db/zivpn.json": json.dumps({"users": users}),
            "web.json": '{"username":"owner","hash":"saved","salt":"test","secret":"session-key"}',
            "certs/fullchain.pem": "local-cert\n", "certs/privkey.pem": "local-key\n",
            "certs/zivpn.crt": "udp-cert\n", "certs/zivpn.key": "udp-key\n",
            "slowdns/server.key": "private\n", "slowdns/server.pub": "public\n",
        }
        for name, data in self.saved.items():
            self.write(self.base / name, data, 0o600)
        self.write(self.base / "slowdns/.turbo_kcp_patched", "")
        self.write(self.base / "version", "previous yesterday\n")
        self.updater = self.base / "core/update.sh"
        self.write(self.updater, (self.src / "core/update.sh").read_text())
        self.write(self.base / "menu.sh", "old code\n")
        # First install registered an absent rules file; there was no package
        # baseline. Never adopt the panel's own saved rules as the original.
        self.rules = self.host / "etc/iptables/rules.v6"
        self.state = self.host / "var/lib/ragnar-panel"
        self.write(Path(str(self.state / "registered") + str(self.rules)), "")
        self.write(self.rules, "panel rules\n")

    @staticmethod
    def write(path, content, mode=0o644):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        path.chmod(mode)

    def shim(self, name, body):
        self.write(self.bin / name, "#!/bin/sh\n" + body + "\n", 0o755)

    def update(self, *args, ok=True, **env):
        run = subprocess.run(["bash", str(self.updater), *args], env={**self.env, **env},
                             capture_output=True, text=True, timeout=30)
        self.assertEqual(run.returncode == 0, ok, run.stdout + run.stderr)
        return run

    def status(self):
        return json.loads((self.base / "update-status.json").read_text())

    def backups(self):
        return list((self.host / "root").glob("*.tar.gz"))

    def test_repeated_updates_preserve_identity_and_first_install_baselines(self):
        self.update(RAGNAR_DOMAIN="unrelated.test", RAGNAR_NS="other.test")
        self.update("--force")
        self.assertEqual(self.status()["state"], "done")
        self.assertEqual((self.base / "version").read_text().split()[0], SHA)
        for code in ("menu.sh", "core/terminal-theme.sh"):
            self.assertEqual((self.base / code).read_bytes(), (self.src / code).read_bytes())
        for name, data in self.saved.items():
            self.assertEqual((self.base / name).read_text(), data, name)
        self.assertEqual((self.base / "web.json").stat().st_mode & 0o777, 0o600)
        udp = json.loads((self.base / "udp/config.json").read_text())
        self.assertEqual((self.base / "udp/config.json").stat().st_mode & 0o777, 0o600)
        self.assertEqual(udp["auth"]["config"], ["live:test"])
        xray = json.loads((self.base / "xray/config.json").read_text())
        self.assertEqual(xray["inbounds"][1]["settings"]["clients"], [{"id": "id", "email": "client"}])
        menu = self.host / "usr/local/bin/menu"
        self.assertEqual(menu.readlink(), self.base / "menu.sh")
        self.assertEqual(Path(str(self.state / "original") + str(menu)).read_text(), "pre-panel menu\n")
        self.assertFalse(Path(str(self.state / "original") + str(self.rules)).exists())
        self.assertEqual(len(self.backups()), 2)
        for path in self.backups():
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            with tarfile.open(path) as tar:
                for name, data in self.saved.items():
                    self.assertEqual(tar.extractfile("ragnar/" + name).read(), data.encode())
        self.update()
        self.assertEqual(self.status()["state"], "uptodate")
        self.assertEqual(len(self.backups()), 2)

    def test_failed_install_stays_retryable(self):
        self.update(ok=False, FAIL_HAPROXY="1")
        self.assertEqual(self.status()["state"], "failed")
        self.assertIn(str(self.backups()[0]), self.status()["message"])
        self.assertEqual((self.base / "version").read_text(), "previous yesterday\n")
        for name, data in self.saved.items():
            self.assertEqual((self.base / name).read_text(), data, name)
        self.update()
        self.assertEqual(self.status()["version"], SHA)

    def test_direct_reinstall_with_missing_code_keeps_state_and_version_on_failure(self):
        # A damaged/legacy install may have state but no core/ragnar.py.
        installer = ["bash", str(self.src / "install.sh")]
        result = subprocess.run(installer, env={**self.env, "FAIL_HAPROXY": "1"},
                                capture_output=True, text=True, timeout=30)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.base / "version").read_text(), "previous yesterday\n")
        subprocess.run(installer, env=self.env, check=True, capture_output=True, timeout=30)
        self.assertEqual((self.base / "version").read_text().split()[0], SHA)
        for name, data in self.saved.items():
            self.assertEqual((self.base / name).read_text(), data, name)

    def test_legacy_slowdns_pair_is_adopted_but_never_mixed(self):
        legacy = self.host / "etc/vps-panel/slowdns"
        for f in ("server.key", "server.pub"):
            self.write(legacy / f, "different " + f)
        self.update(ok=False)
        self.assertEqual((legacy / "server.key").read_text(), "different server.key")
        self.assertEqual((self.base / "slowdns/server.key").read_text(), "private\n")
        for f in ("server.key", "server.pub"):
            (self.base / "slowdns" / f).replace(legacy / f)
        settings = json.loads(self.saved["settings.json"])
        del settings["slowdns_target"]
        (self.base / "settings.json").write_text(json.dumps(settings))
        self.write(legacy / "target_port", "2222")
        self.write(legacy / "nameserver", "obsolete.test")
        self.update()
        self.assertEqual(json.loads((self.base / "settings.json").read_text()),
                         {**settings, "slowdns_target": 2222})
        for f in ("server.key", "server.pub"):
            self.assertEqual((self.base / "slowdns" / f).read_bytes(), (legacy / f).read_bytes())

    def test_damaged_state_aborts_before_code_or_link_replacement(self):
        for name, data in (("db/xray.json", "{"), ("db/ssh.json", '{"users":[]}'),
                           ("settings.json", "null"), ("web.json", "{}"),
                           ("certs/privkey.pem", ""), ("slowdns/server.key", "")):
            with self.subTest(name=name):
                path = self.base / name
                path.write_text(data)
                self.update(ok=False)
                self.assertEqual(path.read_text(), data)
                self.assertEqual((self.base / "version").read_text(), "previous yesterday\n")
                self.assertEqual((self.base / "menu.sh").read_text(), "old code\n")
                self.assertEqual((self.host / "usr/local/bin/menu").read_text(), "pre-panel menu\n")
                self.assertEqual(self.status()["state"], "failed")
                path.write_text(self.saved[name])

    def test_bad_download_does_not_install_or_back_up(self):
        self.archive.write_bytes(b"not a tarball")
        self.update(ok=False)
        self.assertEqual(self.backups(), [])
        self.assertEqual(self.status()["state"], "failed")
        self.assertEqual((self.base / "menu.sh").read_text(), "old code\n")

    def test_backup_contains_state_when_panel_directory_is_a_symlink(self):
        target = self.host / "separate-volume"
        self.base.rename(target)
        self.base.symlink_to(target, target_is_directory=True)
        (self.base / "settings-link").symlink_to("settings.json")
        self.update()
        with tarfile.open(self.backups()[0]) as tar:
            self.assertEqual(tar.extractfile("ragnar/settings.json").read(),
                             self.saved["settings.json"].encode())
            self.assertEqual(tar.getmember("ragnar/settings-link").linkname, "settings.json")

    def test_backup_failure_discards_partial_archive_and_never_installs(self):
        real_tar = (self.bin / "tar").readlink()
        (self.bin / "tar").unlink()
        self.shim("tar", f'if [ "$1" = -czf ]; then echo partial > "$2"; exit 1; fi\nexec "{real_tar}" "$@"')
        self.update(ok=False)
        self.assertEqual(self.backups(), [])
        self.assertEqual(self.status()["state"], "failed")
        self.assertEqual((self.base / "version").read_text(), "previous yesterday\n")
        self.assertEqual((self.base / "menu.sh").read_text(), "old code\n")

    def test_config_generation_failure_keeps_previous_auth_and_version(self):
        (self.base / "db/xray.json").write_text('{"users":{"broken":{"enabled":true}}}')
        self.write(self.base / "udp/config.json", "previous auth list")
        self.update(ok=False)
        self.assertEqual((self.base / "udp/config.json").read_text(), "previous auth list")
        self.assertEqual((self.base / "version").read_text(), "previous yesterday\n")
        self.assertEqual(self.status()["state"], "failed")

    def test_check_and_lock_contention_do_not_overwrite_status(self):
        status = self.base / "update-status.json"
        status.write_text('{"state":"running","message":"Installing pinned release"}')
        before = status.read_bytes()
        self.update("check")
        with (self.host / "var/lock/ragnar-update.lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            self.update(ok=False)
        self.assertEqual(status.read_bytes(), before)
        self.assertEqual(self.backups(), [])


if __name__ == "__main__":
    unittest.main()
