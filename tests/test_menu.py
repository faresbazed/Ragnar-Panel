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
    "appearance": ("theme_menu", "Appearance"),
    "layout": ("layout_menu", "Panel layout"),
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
        for cmd in ("bash", "cat", "dirname", "grep", "mkdir", "mktemp", "mv",
                    "python3", "readlink", "rm", "stty", "tput"):
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
        self.config = self.base / "config"
        self.preference = self.config / "ragnar/terminal-theme"
        self.layout_preference = self.config / "ragnar/terminal-layout"

    def render(self, page, width, tty=False, no_color=False, keys="0\n", **overrides):
        env = {"TERM": "xterm-256color", "LC_ALL": "C.UTF-8", "PATH": str(self.bin),
               "MENU": str(ROOT / "menu.sh"), "RAGNAR_DIR": str(self.base), "COLUMNS": str(width),
               "XDG_CONFIG_HOME": str(self.config), **overrides}
        if no_color:
            env["NO_COLOR"] = "1"
        command = FIXTURE + PAGES[page][0]
        args = ["/bin/bash", "-c", command]
        if tty:
            env["SHELL"] = "/bin/bash"
            # Width comes from a real pty in this variant, not $COLUMNS.
            command = f"stty cols {width}; unset COLUMNS; " + command
            args = [shutil.which("script"), "-qec", command, "/dev/null"]
        p = subprocess.run(args, input=keys, env=env, capture_output=True, text=True, timeout=5)
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

    def test_select_persist_and_restore_theme(self):
        self.assertIn("Default [current]", self.render("appearance", 40))
        self.assertFalse(self.preference.exists())
        for key, theme, background in [(2, "orchid", "27;16;34"), (3, "evergreen", "13;28;23"),
                                       (4, "cobalt", "11;23;48"), (5, "parchment", "232;220;195")]:
            with self.subTest(theme=theme):
                picker = self.render("appearance", 40, tty=True, keys=f"{key}\nb\n", COLORTERM="truecolor")
                self.assertIn(f"{theme.title()} [current]", ANSI.sub("", picker))
                self.assertEqual(self.preference.read_text(), theme + "\n")
                page = self.render("slowdns", 40, tty=True, COLORTERM="truecolor")
                self.assertIn(f"\x1b[48;2;{background}m", page)
                self.assertIn("PACKET PATH", page)
        self.assertIn("Default [current]", self.render("appearance", 40, keys="1\n0\n"))
        restored = self.render("dashboard", 80, tty=True)
        self.assertIn("\x1b[36m", restored)
        self.assertNotIn("\x1b[48;", restored)

    def test_theme_capabilities_and_plain_output(self):
        self.render("appearance", 80, keys="4\n0\n")
        self.assertIn("\x1b[48;5;", self.render("slowdns", 40, tty=True))
        basic = self.render("slowdns", 40, tty=True, TERM="xterm")
        self.assertIn("\x1b[40m", basic)
        self.assertNotIn("\x1b[48;", basic)
        self.assertNotIn("\x1b", self.render("slowdns", 40))
        self.assertNotIn("\x1b", self.render("slowdns", 40, tty=True, no_color=True))
        self.assertNotIn("\x1b", self.render("slowdns", 40, tty=True, TERM="dumb"))
        self.preference.write_text("not a theme\n")
        self.assertIn("Default [current]", self.render("appearance", 40))

    def test_unwritable_preference_is_session_only(self):
        self.config.touch()
        picker = self.render("appearance", 80, keys="5\n0\n")
        self.assertIn("Parchment [current]", picker)
        self.assertIn("Applied for this session only", picker)
        self.assertIn("Default [current]", self.render("appearance", 80))

    def test_symlink_finds_theme_code_next_to_menu(self):
        link = self.bin / "menu"
        link.symlink_to(ROOT / "menu.sh")
        self.assertIn("Orchid [current]", self.render("appearance", 40, keys="2\n0\n", MENU=str(link)))

    def test_select_persist_and_fit_all_layouts(self):
        self.assertIn("Classic [current]", self.render("layout", 40))
        self.assertIn("Classic [current]", self.render("appearance", 40))
        self.assertFalse(self.layout_preference.exists())
        markers = [
            (2, 7, "boxed", "╭─ HOST"),
            (3, 8, "compact", "▸ HOST & RESOURCES"),
            (4, 9, "ledger", "══╡ HOST ╞"),
        ]
        for layout_key, appearance_key, slug, marker in markers:
            with self.subTest(layout=slug):
                picked = self.render("layout", 40, keys=f"{layout_key}\n0\n")
                self.assertIn(f"{slug.title()} [current]", picked)
                self.assertEqual(self.layout_preference.read_text(), slug + "\n")
                dash80 = self.render("dashboard", 80)
                self.assertIn(marker, dash80)
                for width in (32, 40, 80, 96):
                    for page, (_, title) in PAGES.items():
                        out = self.render(page, width)
                        self.assertIn(title, out)
                        self.assertNotIn("\x1b", out)
                        self.assertNotIn("...", out)
                        for line in out.splitlines():
                            if SETTINGS["slowdns_pubkey"] in line:
                                continue
                            self.assertLessEqual(len(line), width, f"{slug}/{width}/{page}: {line!r}")
                # Selecting from Appearance menu (keys 6-9) also persists cleanly.
                via_app = self.render("appearance", 40, keys=f"{appearance_key}\nb\n")
                self.assertIn(f"{slug.title()} [current]", via_app)
                self.assertEqual(self.layout_preference.read_text(), slug + "\n")
        # Restore classic via Appearance key 6 and verify invalid saved value falls back.
        self.assertIn("Classic [current]", self.render("appearance", 40, keys="6\n0\n"))
        self.assertEqual(self.layout_preference.read_text(), "classic\n")
        self.layout_preference.write_text("not a layout\n")
        self.assertIn("Classic [current]", self.render("layout", 40))


if __name__ == "__main__":
    unittest.main()
