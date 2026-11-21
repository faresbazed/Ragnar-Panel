import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class SlowDNSMenuTests(unittest.TestCase):
    def test_empty_fields_do_not_shift_start_settings(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            (base / "host").write_text("192.0.2.10\n")
            (base / "settings.json").write_text(json.dumps({"slowdns_mtu": 1484, "slowdns_target": 109}))
            (base / "core").mkdir()
            (base / "core/slowdns-setup.sh").write_text('printf "[%s]" "$@"\n')
            result = subprocess.run(
                ["bash", "-c", r'''source <(sed '/^if \[ "\${RAGNAR_PREVIEW:-}"/,$d' "$1"); slowdns_menu''',
                 "bash", str(ROOT / "menu.sh")],
                input="1\nns.example.co.uk\n\n\n0\n", text=True, capture_output=True, check=True,
                env={**os.environ, "RAGNAR_DIR": directory}, timeout=10,
            )
        self.assertIn("Nameserver : not set", result.stdout)
        self.assertIn("Public key : not generated", result.stdout)
        self.assertIn("[ns.example.co.uk][][1484][][109]", result.stdout)


class SlowDNSSetupTests(unittest.TestCase):
    def run_setup(self, nameserver, stored_nameserver="", restart=False,
                  existing=False, fail_insert=False, mtu="", resolver="", target="",
                  cloudflare=False, fail_restart=False, legacy_build=False,
                  expect_failure=None):
        with tempfile.TemporaryDirectory() as directory:
            tmp = Path(directory)
            base = tmp / "ragnar"
            slowdns = base / "slowdns"
            slowdns.mkdir(parents=True)
            (slowdns / ".turbo_kcp_patched").touch()
            patch = (ROOT / "configs/dnstt-server.patch").read_bytes()
            (base / "core").mkdir()
            (base / "core/dnstt-server.patch").write_bytes(patch)
            if not legacy_build:
                (slowdns / ".dnstt-build").write_text(f"20260501 {hashlib.sha256(patch).hexdigest()}  -\n")
            (slowdns / "server.key").write_text("private-key\n")
            (slowdns / "server.pub").write_text("public-key\n")
            (base / "settings.json").write_text(json.dumps({"ns": stored_nameserver}))
            bin_dir = tmp / "bin"
            bin_dir.mkdir()
            log = tmp / "commands.log"
            log.touch()
            for command in ("iptables", "ip6tables", "ufw", "systemctl", "sysctl", "curl", "go"):
                shim = bin_dir / command
                shim.write_text(
                    '#!/usr/bin/env bash\n'
                    'printf "%s %s\\n" "${0##*/}" "$*" >> "$COMMAND_LOG"\n'
                    'case "${0##*/}" in\n'
                    '  iptables|ip6tables) [[ " $* " != *" -C "* && " $* " != *" -D "* ]] ;;\n'
                    '  sysctl) echo 33554432 ;;\n'
                    '  systemctl) [ "$*" != "restart slowdns" ] || [ "$FAIL_RESTART" = 0 ] ;;\n'
                    '  go) echo "go version go1.22.12 linux/amd64" ;;\n'
                    '  curl) case "$*" in\n'
                    '    *dnstt-*.zip*) exit 22 ;;\n'
                    '    *icanhazip.com*) echo 192.0.2.10 ;;\n'
                    '    *zones?name=example.co.uk*) echo \'{"result":[{"id":"zone-id"}]}\' ;;\n'
                    '    *dns_records?type=A*) echo \'{"success":true,"result":[{"id":"a-record"}]}\' ;;\n'
                    '    *) echo \'{"success":true,"result":[]}\' ;;\n'
                    '  esac ;;\n'
                    'esac\n'
                )
                shim.chmod(0o755)
            binary = bin_dir / "dnstt-server"
            binary.write_text("#!/usr/bin/env bash\nexit 1\n")
            binary.chmod(0o755)
            ip = bin_dir / "ip"
            ip.write_text('#!/bin/sh\necho "default via 192.0.2.1 dev eth0"\n')
            ip.chmod(0o755)
            source = Path(os.environ.get("SLOWDNS_SETUP_SCRIPT", ROOT / "core/slowdns-setup.sh"))
            script = tmp / "slowdns-setup.sh"
            unit = tmp / "slowdns.service"
            # Isolate absolute host paths without changing the setup logic.
            script.write_text(source.read_text().replace(
                'THEIR_DIR="/etc/vps-panel/slowdns"', f'THEIR_DIR="{tmp / "sister"}"'
            ).replace('BIN=/usr/local/bin/dnstt-server', f'BIN="{binary}"').replace(
                '/etc/systemd/system/slowdns.service', str(unit)
            ).replace(
                '/tmp/ragnar-slowdns-build.log', str(tmp / "build.log")
            ))
            env = {**os.environ, "RAGNAR_DIR": str(base),
                   "PATH": f"{bin_dir}:{os.environ['PATH']}", "COMMAND_LOG": str(log),
                   "SLOWDNS_REBUILD": "0", "FAIL_RESTART": str(int(fail_restart))}
            result = subprocess.run(
                ["bash", str(script), nameserver, "mock-token" if cloudflare else "", mtu, resolver, target],
                capture_output=True, text=True, env=env, timeout=10,
            )
            commands = log.read_text().splitlines()
            if os.environ.get("SLOWDNS_TRACE"):
                print(f"nameserver={nameserver!r}, stored={stored_nameserver!r}")
                print(result.stdout, end="")
                print("\n".join(c for c in commands if c.startswith(("iptables ", "ip6tables "))) or "(no iptables/ip6tables commands)")
            if expect_failure:
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(expect_failure, result.stdout + result.stderr)
                self.assertNotIn("SlowDNS started:", result.stdout)
            else:
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(binary.read_text(), "#!/usr/bin/env bash\nexit 1\n")
            if resolver and not expect_failure:
                self.assertEqual((tmp / "sister/dns_resolver").read_text().strip(), resolver)
            if restart:
                state = tmp / "rules.json"
                rules = {}
                for command, loopback in (("iptables", "127.0.0.0/8"), ("ip6tables", "::1/128")):
                    rules[command] = [
                        f"INPUT -p udp --dport {port} -j ACCEPT" for port in (53, 5300)
                    ] + [f"-t nat PREROUTING ! -d {loopback} -p udp --dport 53 -j REDIRECT --to-ports 5300"] if existing else []
                    (bin_dir / command).write_text(
                        '#!/usr/bin/env python3\n'
                        'import json, pathlib, sys\n'
                        f'p = pathlib.Path({str(state)!r})\n'
                        'rules = json.loads(p.read_text())\n'
                        'args = sys.argv[1:]\n'
                        'op = next(a for a in args if a in ("-C", "-I"))\n'
                        'args.remove(op)\n'
                        'rule = " ".join(args)\n'
                        'items = rules[pathlib.Path(sys.argv[0]).name]\n'
                        'if op == "-C": sys.exit(0 if rule in items else 1)\n'
                        f'if {fail_insert!r}: sys.exit(1)\n'
                        'items.append(rule)\n'
                        'p.write_text(json.dumps(rules))\n'
                    )
                state.write_text(json.dumps(rules))
                lines = [line for line in unit.read_text().splitlines() if line.startswith("ExecStartPre=")]
                self.assertEqual(len(lines), 6)
                for _ in range(2):
                    for line in lines:
                        argv = shlex.split(line.removeprefix("ExecStartPre=-"))
                        self.assertEqual(argv[:2], ["/bin/sh", "-c"])
                        self.assertIn(str(bin_dir), argv[2])
                        pre = subprocess.run(argv, env=env, capture_output=True, text=True)
                        self.assertEqual(pre.returncode, 1 if fail_insert else 0, pre.stderr)
                actual = json.loads(state.read_text())
                for command in rules:
                    self.assertEqual(len(actual[command]), 0 if fail_insert else 3)
                    if existing:
                        self.assertEqual(actual[command], rules[command])
                    elif not fail_insert:
                        self.assertTrue(all("--comment ragnar-slowdns" in rule for rule in actual[command]))
            return commands, unit.read_text() if unit.exists() else None

    def test_blank_nameserver_leaves_firewall_and_services_untouched(self):
        commands, unit = self.run_setup("")
        self.assertEqual([c for c in commands if c.startswith(
            ("iptables ", "ip6tables ", "ufw ", "systemctl "))], [])
        self.assertIsNone(unit)

    def assert_service_setup(self, nameserver, stored_nameserver=""):
        commands, unit = self.run_setup(nameserver, stored_nameserver)
        for command in ("iptables", "ip6tables"):
            for spec in (
                "-p udp --dport 5300 -j REDIRECT --to-ports 53",
                "-p udp --dport 53 -j REDIRECT --to-ports 5300",
                "-i eth0 -p udp --dport 53 -j REDIRECT --to-ports 5300",
            ):
                self.assertIn(f"{command} -t nat -D PREROUTING {spec}", commands)
            self.assertFalse(any(c.startswith(command + " -t nat -D PREROUTING !") for c in commands))
            redirects = [c for c in commands if c.startswith(command + " ")
                         and " -I PREROUTING " in c and "-j REDIRECT --to-ports 5300" in c]
            self.assertEqual(len(redirects), 1)
        self.assertIn("ufw allow 53/udp", commands)
        self.assertIn("ufw allow 5300/udp", commands)
        self.assertIn("systemctl restart slowdns", commands)
        self.assertIn(f" {nameserver or stored_nameserver} 127.0.0.1:22", unit)

    def test_valid_nameserver_adds_redirects_and_creates_service(self):
        self.assert_service_setup("ns.example.com")

    def test_blank_argument_keeps_stored_nameserver(self):
        self.assert_service_setup("", "stored.example.com")

    def test_unit_restores_empty_firewall_idempotently(self):
        self.run_setup("ns.example.com", restart=True)

    def test_unit_preserves_untagged_equivalents(self):
        self.run_setup("ns.example.com", restart=True, existing=True)

    def test_unit_tolerates_unavailable_firewall(self):
        self.run_setup("ns.example.com", restart=True, fail_insert=True)

    def test_configures_high_mtu_dropbear_and_multilabel_dns_zone(self):
        commands, unit = self.run_setup("ns.example.co.uk", mtu="1484", resolver="192.0.2.53:53",
                                        target="109", cloudflare=True)
        self.assertIn("-mtu 1484 ", unit)
        self.assertIn(" ns.example.co.uk 127.0.0.1:109", unit)
        self.assertNotIn("192.0.2.53", unit)
        self.assertTrue(any("zones?name=example.co.uk" in c for c in commands), commands)
        self.assertTrue(any("dns_records/a-record -X PATCH" in c for c in commands))
        self.assertTrue(any("dns_records -X POST" in c for c in commands))
        self.assertTrue(any('"content":"dns.example.co.uk"' in c and '"type":"NS"' in c for c in commands))

    def test_legacy_build_is_rebuilt_without_removing_binary_on_error(self):
        commands, unit = self.run_setup("ns.example.com", legacy_build=True, expect_failure="build failed")
        self.assertTrue(any("dnstt-20260501.zip" in c for c in commands))
        self.assertIsNone(unit)

    def test_systemd_restart_failure_is_reported(self):
        self.run_setup("ns.example.com", fail_restart=True, expect_failure="could not start SlowDNS")

    def test_invalid_mtu_does_not_create_a_unit(self):
        commands, unit = self.run_setup("ns.example.com", mtu="511", expect_failure="must be between 512 and 4096")
        self.assertIsNone(unit)
        self.assertNotIn("systemctl restart slowdns", commands)


if __name__ == "__main__":
    unittest.main()
