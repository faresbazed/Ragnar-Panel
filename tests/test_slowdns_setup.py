import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class SlowDNSSetupTests(unittest.TestCase):
    def run_setup(self, nameserver, stored_nameserver=""):
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
                    '  iptables|ip6tables) [[ " $* " != *" -C "* ]] ;;\n'
                    '  sysctl) echo 33554432 ;;\n'
                    'esac\n'
                )
                shim.chmod(0o755)
            binary = bin_dir / "dnstt-server"
            binary.write_text("#!/usr/bin/env bash\nexit 1\n")
            binary.chmod(0o755)
            source = Path(os.environ.get("SLOWDNS_SETUP_SCRIPT", ROOT / "core/slowdns-setup.sh"))
            script = tmp / "slowdns-setup.sh"
            unit = tmp / "slowdns.service"
            # Isolate absolute host paths without changing the setup logic.
            script.write_text(source.read_text().replace(
                'THEIR_DIR="/etc/vps-panel/slowdns"', f'THEIR_DIR="{tmp / "sister"}"'
            ).replace('BIN=/usr/local/bin/dnstt-server', f'BIN="{binary}"').replace(
                '/etc/systemd/system/slowdns.service', str(unit)
            ))
            result = subprocess.run(
                ["bash", str(script), nameserver], capture_output=True, text=True,
                env={**os.environ, "RAGNAR_DIR": str(base),
                     "PATH": f"{bin_dir}:{os.environ['PATH']}", "COMMAND_LOG": str(log)},
            )
            commands = log.read_text().splitlines()
            if os.environ.get("SLOWDNS_TRACE"):
                print(f"nameserver={nameserver!r}, stored={stored_nameserver!r}")
                print(result.stdout, end="")
                print("\n".join(c for c in commands if c.startswith(("iptables ", "ip6tables "))) or "(no iptables/ip6tables commands)")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            return commands, unit.read_text() if unit.exists() else None

    def test_blank_nameserver_leaves_firewall_and_services_untouched(self):
        commands, unit = self.run_setup("")
        self.assertEqual([c for c in commands if c.startswith(
            ("iptables ", "ip6tables ", "ufw ", "systemctl "))], [])
        self.assertIsNone(unit)

    def assert_service_setup(self, nameserver, stored_nameserver=""):
        commands, unit = self.run_setup(nameserver, stored_nameserver)
        for command in ("iptables", "ip6tables"):
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


if __name__ == "__main__":
    unittest.main()
