"""Render the terminal UI against synthetic panel data, never a running VPS."""
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
ANSI = re.compile(r"\x1b\[[\d;]*m")
PAGES = {
    "dashboard": ("print_header; main_menu", "Server overview"),
    "ssh": ("ssh_menu", "SSH & SSL"),
    "xray": ("xray_menu", "Xray accounts"),
    "zivpn": ("zivpn_menu", "UDP ZIVPN"),
    "udp": ("udpcustom_menu", "UDP Custom"),
    "slowdns": ("slowdns_menu", "SlowDNS / DNSTT"),
    "cloudflare": ("cloudflared_menu", "Cloudflare"),
    "web": ("webpanel_menu", "Web panel"),
    "tools": ("tools_menu", "Tools & diagnostics"),
    "health": ("status_page", "Status & health"),
    "update": ("update_panel", "Update panel"),
}
FIXTURE = """
source "$MENU"
clear_screen() { :; }
read_host_stats() {
    ip=192.0.2.10; isp='Example Networks'; os='Debian 12'; up='4 days';
    now='12:40 UTC'; cpu=24.8%; ram='1.5 / 4 GiB (38%)'; disk='18 / 80 GiB (23%)';
}
systemctl() {
    [[ $1 == is-active ]] || return 1; shift
    [[ $1 == --quiet ]] && { [[ $2 != cloudflared && $2 != zivpn ]]; return; }
    local unit
    for unit; do
        case $unit in cloudflared|zivpn) echo inactive ;; *) echo active ;; esac
    done
}
ss() { :; }
slowdns_build() { kv Build 'Turbo patch active' "$G"; }
"""
SETTINGS = {"ns": "ns.example.test", "slowdns_target": 109, "slowdns_mtu": 1232,
            "slowdns_pubkey": "0123456789abcdef" * 4, "slowdns_resolver": "192.0.2.53"}


class MenuTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(prefix="ragnar-menu-")
        self.addCleanup(tmp.cleanup)
        self.base = Path(tmp.name)
        self.bin = self.base / "bin"
        self.bin.mkdir()
        for cmd in ("bash", "cat", "dirname", "grep", "python3", "stty", "tput"):
            (self.bin / cmd).symlink_to(shutil.which(cmd))
        self.core = self.base / "core"
        self.core.mkdir()
        (self.core / "update.sh").write_text("echo 'Test release'\n")
        (self.core / "ragnar.py").write_text("""
def dashboard_summary():
    return dict(bandwidth=dict(today=dict(total_f='1.2 GiB'), month=dict(total_f='8.4 GiB'),
                               source='vnstat'),
                stats=dict(vmess=4, vless=4, trojan=4, ssws=4, ssh=8, zivpn=2, total=14),
                online=dict(online=3))
if __name__ == '__main__':
    import json, sys
    if sys.argv[1] == 'stats':
        print(json.dumps(dashboard_summary()['stats']))
    elif sys.argv[1] == 'bandwidth-summary':
        print('Today: 1.2 GiB')
""")
        (self.base / "host").write_text("192.0.2.10\n")
        (self.base / "settings.json").write_text(json.dumps(SETTINGS))

    def render(self, page, width, tty=False, no_color=False):
        env = {"TERM": "xterm-256color", "LC_ALL": "C.UTF-8", "PATH": str(self.bin),
               "MENU": str(ROOT / "menu.sh"), "RAGNAR_DIR": str(self.base), "COLUMNS": str(width)}
        if no_color:
            env["NO_COLOR"] = "1"
        command = FIXTURE + PAGES[page][0]
        args = ["/bin/bash", "-c", command]
        if tty:
            env["SHELL"] = "/bin/bash"
            # Width comes from a real pty in this variant, not $COLUMNS.
            command = f"stty cols {width}; unset COLUMNS; " + command
            args = [shutil.which("script"), "-qec", command, "/dev/null"]
        p = subprocess.run(args, input="0\n", env=env, capture_output=True, text=True, timeout=5)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertFalse(p.stderr, p.stderr)
        return p.stdout

    def test_pages_fit_phone_and_desktop(self):
        for width in (32, 40, 80, 96):
            for page, (_, title) in PAGES.items():
                with self.subTest(page=page, width=width):
                    output = self.render(page, width)
                    self.assertIn(title, output)
                    self.assertNotIn("\x1b", output)
                    self.assertNotIn("...", output)
                    for line in output.splitlines():
                        if SETTINGS["slowdns_pubkey"] in line:
                            continue  # Keep the key intact for terminal soft wrap / copy.
                        self.assertLessEqual(len(line), width, line)

    def test_empty_fields_keep_their_positions(self):
        (self.base / "settings.json").write_text('{"slowdns_target":109,"slowdns_mtu":1400}')
        text = self.render("slowdns", 80)
        for pattern in (r"Nameserver\s+Not set", r"Public key\s+Not generated",
                        r"Resolver\s+1\.1\.1\.1:53", r"SSH\s+127\.0\.0\.1:109", r"MTU\s+1400"):
            self.assertRegex(text, pattern)
        dashboard = self.render("dashboard", 80)
        self.assertRegex(dashboard, r"Total\s+14")
        self.assertRegex(dashboard, r"Online\s+3")

    def test_terminal_width_and_color(self):
        phone = self.render("slowdns", 40, tty=True)
        wide = self.render("slowdns", 96, tty=True)
        self.assertIn("\x1b[36m", phone)
        self.assertIn(SETTINGS["slowdns_pubkey"], phone)
        for width, output in ((40, phone), (96, wide)):
            rule = next(s for s in ANSI.sub("", output).splitlines() if "TUNNEL PROFILE" in s)
            self.assertEqual(len(rule), width)
        self.assertIn("Optional Cloudflare DNS records", wide)
        self.assertNotIn("Optional Cloudflare DNS records", phone)
        self.assertNotIn("\x1b", self.render("slowdns", 40, tty=True, no_color=True))


if __name__ == "__main__":
    unittest.main()
