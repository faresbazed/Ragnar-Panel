import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class SlowDNSSetupTests(unittest.TestCase):
    def run_setup(self, nameserver, stored_nameserver="", restart=False,
                  existing=False, fail_insert=False):
        with tempfile.TemporaryDirectory() as directory:
            tmp = Path(directory)
            base = tmp / "ragnar"
            slowdns = base / "slowdns"
            slowdns.mkdir(parents=True)
            (slowdns / ".turbo_kcp_patched").touch()
            (slowdns / "server.key").write_text("private-key\n")
            (slowdns / "server.pub").write_text("public-key\n")
            (base / "settings.json").write_text(json.dumps({"ns": stored_nameserver}))
            bin_dir = tmp / "bin"
            bin_dir.mkdir()
            log = tmp / "commands.log"
            log.touch()
            for command in ("iptables", "ip6tables", "ufw", "systemctl", "sysctl"):
                shim = bin_dir / command
                shim.write_text(
                    '#!/usr/bin/env bash\n'
                    'printf "%s %s\\n" "${0##*/}" "$*" >> "$COMMAND_LOG"\n'
                    'case "${0##*/}" in\n'
                    '  iptables|ip6tables) [[ " $* " != *" -C "* && " $* " != *" -D "* ]] ;;\n'
                    '  sysctl) echo 33554432 ;;\n'
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
            for helper in ("panel-state.py", "ragnar.py"):
                (tmp / helper).symlink_to(ROOT / "core" / helper)
            unit = tmp / "slowdns.service"
            # Isolate absolute host paths without changing the setup logic.
            script.write_text(source.read_text().replace(
                'THEIR_DIR="/etc/vps-panel/slowdns"', f'THEIR_DIR="{tmp / "sister"}"'
            ).replace('BIN=/usr/local/bin/dnstt-server', f'BIN="{binary}"').replace(
                '/etc/systemd/system/slowdns.service', str(unit)
            ))
            env = {**os.environ, "RAGNAR_DIR": str(base),
                   "PATH": f"{bin_dir}:{os.environ['PATH']}", "COMMAND_LOG": str(log)}
            result = subprocess.run(
                ["bash", str(script), nameserver], capture_output=True, text=True,
                env=env,
            )
            commands = log.read_text().splitlines()
            if os.environ.get("SLOWDNS_TRACE"):
                print(f"nameserver={nameserver!r}, stored={stored_nameserver!r}")
                print(result.stdout, end="")
                print("\n".join(c for c in commands if c.startswith(("iptables ", "ip6tables "))) or "(no iptables/ip6tables commands)")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
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


if __name__ == "__main__":
    unittest.main()
