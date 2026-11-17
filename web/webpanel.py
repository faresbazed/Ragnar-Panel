#!/usr/bin/env python3
"""
Ragnar Web Panel - modern web control plane for the Ragnar VPS panel.

Single file, Python standard library only (Python 3.8+). Two serving modes:
  * fronted (what install.sh sets up): plain HTTP on 127.0.0.1:2053
    under the /panel prefix, reached as https://<domain>/panel through
    HAProxy on 443 - providers like IONOS firewall inbound 2053 before
    it ever reaches the box, but 443 is always open.
  * direct: HTTPS on port 2053 (3x-ui's port) with the panel's own
    domain certificate (<RAGNAR_DIR>/certs/fullchain.pem + privkey.pem).
Env switches: RAGNAR_WEB_BASE, RAGNAR_WEB_BIND, RAGNAR_WEB_NO_TLS,
RAGNAR_WEB_PORT.

All user management goes through core/ragnar.py - the same functions
the terminal menu uses - so the two UIs can never drift apart.

Login credentials live in <RAGNAR_DIR>/web.json (PBKDF2-HMAC-SHA256,
never plaintext). Manage them with:
    python3 webpanel.py --init             # create admin + random password
    python3 webpanel.py --reset-password   # new random password, printed once
    python3 webpanel.py --set-password USER PASS
"""
import base64
import gzip
import hashlib
import hmac
import html
import json
import os
import secrets
import shutil
import ssl
import subprocess
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "core"))
import ragnar  # noqa: E402

BASE = ragnar.BASE
WEB_JSON = os.path.join(BASE, "web.json")
DEFAULT_PORT = 2053
BASE_PATH = os.environ.get("RAGNAR_WEB_BASE", "").rstrip("/")
SESSION_TTL = 12 * 3600
SERVICES = [
    "haproxy", "xray", "sing-box", "ragnar-wsproxy", "dropbear",
    "ssh", "zivpn", "udp-custom", "badvpn-udpgw", "slowdns",
    "cloudflared", "ragnar-web",
]

_failures = {}  # ip -> (count, locked_until)
_cfg_cache = {"path": None, "mtime": None, "cfg": None}
_cpu_lock = threading.Lock()
_cpu_prev = None  # (total_jiffies, idle_jiffies)


def U(path):
    """Public URL for an app path, honouring the HAProxy prefix."""
    return BASE_PATH + path


# ---------------------------------------------------------------------
# Credentials / sessions (mtime-cached config reads)
# ---------------------------------------------------------------------
def _hash_password(password, salt=None):
    salt = salt or secrets.token_bytes(16)
    dk = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, 200_000)
    return salt.hex(), dk.hex()


def load_web_cfg():
    mtime = None
    try:
        mtime = os.stat(WEB_JSON).st_mtime_ns
    except OSError:
        pass
    if (_cfg_cache["cfg"] is not None
            and _cfg_cache["path"] == WEB_JSON
            and _cfg_cache["mtime"] == mtime):
        return dict(_cfg_cache["cfg"])
    cfg = ragnar._read_json(WEB_JSON, {})
    cfg.setdefault("username", "admin")
    cfg.setdefault("port", DEFAULT_PORT)
    if "secret" not in cfg:
        cfg["secret"] = secrets.token_hex(32)
    _cfg_cache.update({"path": WEB_JSON, "mtime": mtime, "cfg": dict(cfg)})
    return cfg


def save_web_cfg(cfg):
    os.makedirs(BASE, exist_ok=True)
    tmp = WEB_JSON + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(cfg, fh, indent=2)
    os.chmod(tmp, 0o600)
    os.replace(tmp, WEB_JSON)
    try:
        mtime = os.stat(WEB_JSON).st_mtime_ns
    except OSError:
        mtime = None
    _cfg_cache.update({"path": WEB_JSON, "mtime": mtime, "cfg": dict(cfg)})


def set_password(username, password):
    cfg = load_web_cfg()
    salt, dk = _hash_password(password)
    cfg.update({"username": username, "salt": salt, "hash": dk})
    save_web_cfg(cfg)
    return cfg


def check_password(username, password):
    cfg = load_web_cfg()
    if username != cfg.get("username") or "hash" not in cfg:
        return False
    _, dk = _hash_password(password, bytes.fromhex(cfg["salt"]))
    return hmac.compare_digest(dk, cfg["hash"])


def make_session(username):
    cfg = load_web_cfg()
    payload = base64.urlsafe_b64encode(json.dumps(
        {"u": username, "exp": int(time.time()) + SESSION_TTL}
    ).encode()).decode()
    sig = hmac.new(cfg["secret"].encode(), payload.encode(),
                   hashlib.sha256).hexdigest()
    return f"{payload}.{sig}"


def check_session(token):
    try:
        cfg = load_web_cfg()
        payload, sig = token.rsplit(".", 1)
        good = hmac.new(cfg["secret"].encode(), payload.encode(),
                        hashlib.sha256).hexdigest()
        if not hmac.compare_digest(sig, good):
            return None
        data = json.loads(base64.urlsafe_b64decode(payload.encode()))
        if data.get("exp", 0) < time.time() or data.get("u") != cfg["username"]:
            return None
        return data["u"]
    except Exception:
        return None


def csrf_token(session_token):
    cfg = load_web_cfg()
    return hmac.new(cfg["secret"].encode(),
                    ("csrf:" + session_token).encode(),
                    hashlib.sha256).hexdigest()[:32]


def login_locked(ip):
    _, until = _failures.get(ip, (0, 0))
    return time.time() < until


def note_login_failure(ip):
    count, _ = _failures.get(ip, (0, 0))
    count += 1
    if count >= 8:
        _failures[ip] = (0, time.time() + 300)
    else:
        _failures[ip] = (count, 0)


# ---------------------------------------------------------------------
# System telemetry & batched service health
# ---------------------------------------------------------------------
def esc(x):
    return html.escape(str(x), quote=True)


def fmt_used(u):
    return ragnar.fmt_gb(int(u.get("used_bytes", 0)))


def fmt_quota(u):
    q = u.get("quota_gb") or 0
    return "Unlimited" if not q else ragnar.fmt_gb(int(q * 1024 ** 3))


def svc_states(units=SERVICES):
    """Check all systemd units in ONE subprocess / D-Bus round-trip."""
    if not units:
        return []
    try:
        out = subprocess.run(
            ["systemctl", "is-active", *units],
            capture_output=True, text=True
        ).stdout.splitlines()
    except OSError:
        out = []
    return [
        (unit, (out[i].strip() == "active") if i < len(out) else False)
        for i, unit in enumerate(units)
    ]


def svc_active(unit):
    res = svc_states([unit])
    return res[0][1] if res else False


def _read_proc_stat():
    try:
        with open("/proc/stat", encoding="utf-8") as fh:
            parts = [int(x) for x in fh.readline().split()[1:9]]
        if len(parts) >= 4:
            idle = parts[3] + (parts[4] if len(parts) > 4 else 0)
            return sum(parts), idle
    except (OSError, ValueError):
        pass
    return None


def _cpu_percent():
    global _cpu_prev
    with _cpu_lock:
        cur = _read_proc_stat()
        if cur is None:
            return None
        if _cpu_prev is None:
            _cpu_prev = cur
            time.sleep(0.02)
            cur2 = _read_proc_stat()
            if cur2 is None:
                return 0.0
            dt = cur2[0] - cur[0]
            di = cur2[1] - cur[1]
            _cpu_prev = cur2
            return round(max(0.0, min(100.0, (dt - di) * 100.0 / dt)), 1) if dt > 0 else 0.0
        dt = cur[0] - _cpu_prev[0]
        di = cur[1] - _cpu_prev[1]
        if dt > 0:
            _cpu_prev = cur
            return round(max(0.0, min(100.0, (dt - di) * 100.0 / dt)), 1)
        return 0.0


def server_info():
    info = {
        "ip": "-", "os": "Linux", "uptime": "-",
        "cpu": "n/a", "cpu_pct": 0,
        "ram": "-", "ram_pct": 0,
        "disk": "-", "disk_pct": 0,
    }
    try:
        with open(os.path.join(BASE, "host"), encoding="utf-8") as fh:
            info["ip"] = fh.read().strip() or "-"
    except OSError:
        pass
    try:
        with open("/etc/os-release", encoding="utf-8") as fh:
            for line in fh:
                if line.startswith("PRETTY_NAME="):
                    info["os"] = line.split("=", 1)[1].strip().strip('"')
                    break
    except OSError:
        pass
    try:
        with open("/proc/uptime", encoding="utf-8") as fh:
            secs = int(float(fh.read().split()[0]))
        days, rem = divmod(secs, 86400)
        hours, rem = divmod(rem, 3600)
        mins = rem // 60
        info["uptime"] = f"{days}d {hours}h" if days else f"{hours}h {mins}m"
    except OSError:
        pass
    cpu_p = _cpu_percent()
    if cpu_p is not None:
        info["cpu_pct"] = cpu_p
        info["cpu"] = f"{cpu_p:.1f}%"
    try:
        total = avail = 0
        with open("/proc/meminfo", encoding="utf-8") as fh:
            for line in fh:
                if line.startswith("MemTotal:"):
                    total = int(line.split()[1])
                elif line.startswith("MemAvailable:"):
                    avail = int(line.split()[1])
        if total > 0:
            used = max(0, total - avail)
            info["ram"] = f"{used // 1024} MB / {total // 1024} MB"
            info["ram_pct"] = round(used * 100.0 / total, 1)
    except OSError:
        pass
    try:
        d = shutil.disk_usage("/")
        if d.total > 0:
            info["disk"] = f"{d.used / 2**30:.1f}G / {d.total / 2**30:.1f}G"
            info["disk_pct"] = round(d.used * 100.0 / d.total, 1)
    except OSError:
        pass
    return info


def api_status_payload():
    info = server_info()
    st = ragnar.stats()
    on = ragnar.online_users()
    bw = ragnar.bandwidth()
    today = bw.get("today") or {}
    month = bw.get("month") or {}
    states = svc_states()
    return {
        "info": info,
        "stats": st,
        "online": on,
        "bw_today": today.get("total_f", "n/a"),
        "bw_month": month.get("total_f", "n/a"),
        "services": dict(states),
        "online_services": sum(1 for _, up in states if up),
        "total_services": len(states),
    }


# ---------------------------------------------------------------------
# Icons & Token-Driven Vanilla CSS Design System
# ---------------------------------------------------------------------
ICONS = {
    "dashboard": '<rect x="3" y="3" width="8" height="8" rx="1.5"/><rect x="13" y="3" width="8" height="5" rx="1.5"/><rect x="13" y="10" width="8" height="11" rx="1.5"/><rect x="3" y="13" width="8" height="8" rx="1.5"/>',
    "ssh": '<path d="M8 15a5 5 0 1 1 3.9-1.9L21 22"/><path d="m18 19 2-2M15 16l2-2"/><circle cx="8" cy="10" r="1"/>',
    "xray": '<path d="M13 2 3 14h8l-1 8 10-12h-8l1-8Z"/>',
    "zivpn": '<path d="M12 22s8-4 8-11V5l-8-3-8 3v6c0 7 8 11 8 11Z"/><path d="m9 12 2 2 4-4"/>',
    "services": '<rect x="3" y="4" width="18" height="6" rx="2"/><rect x="3" y="14" width="18" height="6" rx="2"/><path d="M7 7h.01M7 17h.01M11 7h6M11 17h6"/>',
    "settings": '<path d="M4 21v-7M4 10V3M12 21v-9M12 8V3M20 21v-5M20 12V3"/><path d="M2 14h4M10 8h4M18 16h4"/>',
    "logout": '<path d="M10 17l5-5-5-5M15 12H3"/><path d="M12 3h6a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2h-6"/>',
    "server": '<rect x="3" y="4" width="18" height="7" rx="2"/><rect x="3" y="13" width="18" height="7" rx="2"/><path d="M7 7.5h.01M7 16.5h.01M11 8h6M11 17h6"/>',
    "ip": '<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3a15 15 0 0 1 0 18M12 3a15 15 0 0 0 0 18"/>',
    "uptime": '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
    "cpu": '<rect x="6" y="6" width="12" height="12" rx="2"/><path d="M9 1v3M15 1v3M9 20v3M15 20v3M1 9h3M1 15h3M20 9h3M20 15h3"/>',
    "disk": '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M3 14h18M7 17h.01M11 17h.01M15 8h2"/>',
    "users": '<path d="M16 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2"/><circle cx="10" cy="7" r="4"/><path d="M20 21v-2a4 4 0 0 0-3-3.9M16 3.1a4 4 0 0 1 0 7.8"/>',
    "online": '<path d="M3 12h4l3-8 4 16 3-8h4"/>',
    "bandwidth": '<path d="M3 3v18h18"/><path d="m7 14 4-4 4 3 6-7"/><path d="M17 6h4v4"/>',
    "plus": '<path d="M12 5v14M5 12h14"/>',
    "copy": '<rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/>',
    "search": '<circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/>',
    "refresh": '<path d="M21 12a9 9 0 1 1-2.64-6.36"/><path d="M21 3v6h-6"/>',
    "check": '<path d="m5 12 5 5L20 7"/>',
    "alert": '<circle cx="12" cy="12" r="9"/><path d="M12 8v4M12 16h.01"/>',
}


def icon(name, cls="icon"):
    paths = ICONS.get(name, ICONS["server"])
    return (
        f'<svg class="{cls}" viewBox="0 0 24 24" fill="none" '
        f'stroke="currentColor" stroke-width="1.8" stroke-linecap="round" '
        f'stroke-linejoin="round" aria-hidden="true" focusable="false">'
        f'{paths}</svg>'
    )


CSS = """
:root {
  color-scheme: dark;
  --bg: #090d16;
  --bg-elev: #0f1624;
  --surface: #121b2c;
  --surface-2: #172237;
  --surface-hover: #1b2840;
  --border: #233149;
  --border-strong: #314463;
  --text: #eef2f8;
  --text-muted: #93a3bc;
  --text-dim: #667691;
  --accent: #0ea5e9;
  --accent-hover: #38bdf8;
  --accent-soft: rgba(14, 165, 233, 0.14);
  --ok: #10b981;
  --ok-bg: rgba(16, 185, 129, 0.14);
  --ok-text: #6ee7b7;
  --warn: #f59e0b;
  --warn-bg: rgba(245, 158, 11, 0.15);
  --warn-text: #fcd34d;
  --danger: #ef4444;
  --danger-bg: rgba(239, 68, 68, 0.15);
  --danger-text: #fca5a5;
  --info-bg: rgba(14, 165, 233, 0.14);
  --info-text: #7dd3fc;
  --radius-sm: 8px;
  --radius: 12px;
  --radius-lg: 16px;
  --shadow: 0 12px 32px rgba(2, 6, 16, 0.42);
}
* { box-sizing: border-box; margin: 0; padding: 0; }
html, body { min-height: 100%; }
body {
  font-family: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif;
  background: radial-gradient(ellipse 90% 50% at 65% -10%, #132238 0%, var(--bg) 62%);
  color: var(--text);
  display: flex;
  min-height: 100vh;
  line-height: 1.5;
  -webkit-font-smoothing: antialiased;
}
.tabular, .v, td, .health-summary, .pill { font-variant-numeric: tabular-nums; }

/* Sidebar */
.sidebar {
  width: 252px;
  min-height: 100vh;
  position: sticky;
  top: 0;
  display: flex;
  flex-direction: column;
  padding: 22px 14px;
  flex-shrink: 0;
  background: rgba(11, 17, 29, 0.96);
  border-right: 1px solid var(--border);
  backdrop-filter: blur(12px);
}
.logo {
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 2px 10px 24px;
  font-size: 18px;
  font-weight: 700;
  color: var(--text);
  letter-spacing: 0.05em;
}
.logo small {
  display: block;
  font-size: 11.5px;
  color: var(--text-dim);
  font-weight: 400;
  letter-spacing: 0;
  line-height: 1.35;
  margin-top: 2px;
}
.logo-badge {
  display: grid;
  place-items: center;
  width: 40px;
  height: 40px;
  flex: 0 0 40px;
  color: var(--accent-hover);
  border: 1px solid var(--border-strong);
  border-radius: 11px;
  background: linear-gradient(150deg, #162944, #0f1829);
  box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.07);
}
.logo-icon { width: 20px; height: 20px; }
.nav { display: grid; gap: 4px; }
.nav a {
  display: flex;
  align-items: center;
  gap: 11px;
  padding: 10px 12px;
  color: var(--text-muted);
  text-decoration: none;
  font-size: 13.5px;
  font-weight: 500;
  border-radius: 9px;
  transition: background 0.14s ease, color 0.14s ease;
}
.nav a:hover { color: var(--text); background: var(--surface); }
.nav a.on {
  color: #fff;
  background: var(--surface-2);
  box-shadow: inset 3px 0 0 var(--accent-hover);
}
.nav-icon { width: 18px; height: 18px; flex: 0 0 18px; opacity: 0.9; }
.nav a.on .nav-icon { color: var(--accent-hover); opacity: 1; }
.sidebar-footer {
  display: flex;
  align-items: center;
  gap: 9px;
  margin: auto 10px 2px;
  padding-top: 20px;
  border-top: 1px solid rgba(35, 49, 73, 0.55);
  color: var(--text-dim);
  font-size: 12px;
}
.sidebar-dot {
  width: 8px;
  height: 8px;
  border-radius: 50%;
  background: var(--ok);
  box-shadow: 0 0 10px rgba(16, 185, 129, 0.55);
}

/* Main Content */
.main {
  flex: 1;
  width: calc(100% - 252px);
  max-width: 1460px;
  padding: 32px clamp(20px, 3.8vw, 52px);
}
.page-heading {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 16px;
  margin-bottom: 24px;
}
.page-heading h1 {
  margin: 3px 0 0;
  font-size: clamp(21px, 2.1vw, 27px);
  font-weight: 700;
  letter-spacing: -0.025em;
}
.eyebrow {
  color: var(--text-dim);
  font-size: 11px;
  font-weight: 700;
  letter-spacing: 0.12em;
  text-transform: uppercase;
}
.heading-actions { display: flex; align-items: center; gap: 10px; }
.live-chip {
  display: inline-flex;
  align-items: center;
  gap: 7px;
  padding: 6px 11px;
  border-radius: 99px;
  border: 1px solid var(--border);
  background: var(--bg-elev);
  color: var(--text-muted);
  font-size: 12px;
}
.page-mark {
  display: grid;
  place-items: center;
  width: 40px;
  height: 40px;
  border: 1px solid var(--border);
  border-radius: 11px;
  color: var(--accent-hover);
  background: var(--bg-elev);
}
.page-mark svg { width: 19px; height: 19px; }

/* Metric Cards */
.cards {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(210px, 1fr));
  gap: 14px;
  margin-bottom: 28px;
}
.card {
  background: linear-gradient(160deg, rgba(21, 31, 50, 0.95), rgba(14, 21, 35, 0.96));
  border: 1px solid var(--border);
  border-radius: var(--radius);
  padding: 16px 18px;
  box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.03), var(--shadow);
}
.metric-card {
  min-width: 0;
  display: flex;
  flex-direction: column;
  transition: transform 0.15s ease, border-color 0.15s ease;
}
.metric-card:hover {
  transform: translateY(-2px);
  border-color: var(--border-strong);
}
.metric-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
}
.card .k {
  font-size: 11.5px;
  font-weight: 600;
  color: var(--text-muted);
  text-transform: uppercase;
  letter-spacing: 0.07em;
}
.metric-icon-wrap {
  display: grid;
  place-items: center;
  width: 32px;
  height: 32px;
  flex: 0 0 32px;
  color: var(--accent-hover);
  border: 1px solid rgba(56, 189, 248, 0.22);
  border-radius: 9px;
  background: var(--accent-soft);
}
.metric-icon { width: 16px; height: 16px; }
.card .v {
  font-size: clamp(18px, 1.85vw, 23px);
  font-weight: 700;
  letter-spacing: -0.02em;
  margin-top: 11px;
  overflow-wrap: anywhere;
}
.card .s {
  font-size: 12px;
  color: var(--text-dim);
  margin-top: 4px;
  min-height: 18px;
}
.meter {
  height: 5px;
  width: 100%;
  background: rgba(255, 255, 255, 0.07);
  border-radius: 99px;
  overflow: hidden;
  margin-top: 10px;
}
.meter > span {
  display: block;
  height: 100%;
  border-radius: 99px;
  background: var(--accent-hover);
  transition: width 0.35s ease;
}
.meter.warn > span { background: var(--warn); }
.meter.crit > span { background: var(--danger); }

/* Section Headings & Health */
.section-heading {
  display: flex;
  align-items: center;
  justify-content: space-between;
  flex-wrap: wrap;
  gap: 12px;
  margin: 6px 0 12px;
}
.section-heading h2, h3 {
  color: var(--text);
  font-size: 16px;
  font-weight: 600;
  letter-spacing: -0.01em;
}
h3 { margin: 22px 0 10px; }
.health-summary {
  padding: 5px 11px;
  border: 1px solid rgba(16, 185, 129, 0.32);
  border-radius: 99px;
  color: var(--ok-text);
  background: var(--ok-bg);
  font-size: 12px;
  font-weight: 600;
}

/* Tables */
.tblwrap {
  overflow-x: auto;
  -webkit-overflow-scrolling: touch;
  border: 1px solid var(--border);
  border-radius: var(--radius);
  background: rgba(15, 22, 36, 0.92);
  box-shadow: var(--shadow);
}
table {
  width: 100%;
  border-collapse: collapse;
  min-width: 600px;
}
th, td {
  padding: 12px 15px;
  text-align: left;
  font-size: 13.5px;
  border-bottom: 1px solid rgba(35, 49, 73, 0.72);
  white-space: nowrap;
}
th {
  background: #10192a;
  color: var(--text-muted);
  font-size: 11.5px;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.055em;
}
tr:last-child td { border-bottom: none; }
tbody tr { transition: background 0.12s ease; }
tbody tr:hover { background: rgba(255, 255, 255, 0.025); }
.empty-cell {
  text-align: center;
  color: var(--text-dim);
  padding: 28px 16px;
}
.row-actions {
  display: inline-flex;
  align-items: center;
  gap: 6px;
}

/* Status Dots, Pills & Quota Mini-Bars */
.dot {
  display: inline-block;
  width: 8px;
  height: 8px;
  border-radius: 50%;
  margin-right: 7px;
  vertical-align: middle;
}
.on-dot { background: var(--ok); box-shadow: 0 0 8px rgba(16, 185, 129, 0.5); }
.off-dot { background: var(--danger); }
.pill {
  display: inline-flex;
  align-items: center;
  padding: 2.5px 9px;
  border-radius: 99px;
  font-size: 11.5px;
  font-weight: 600;
  line-height: 1.35;
}
.pill.g { background: var(--ok-bg); color: var(--ok-text); }
.pill.r { background: var(--danger-bg); color: var(--danger-text); }
.pill.b { background: var(--info-bg); color: var(--info-text); }
.pill.w { background: var(--warn-bg); color: var(--warn-text); }
.quota-cell { min-width: 110px; }
.quota-bar {
  height: 4px;
  width: 86px;
  background: rgba(255, 255, 255, 0.08);
  border-radius: 99px;
  overflow: hidden;
  margin-top: 4px;
}
.quota-bar > span {
  display: block;
  height: 100%;
  background: var(--accent-hover);
  border-radius: 99px;
}
.quota-bar.warn > span { background: var(--warn); }
.quota-bar.crit > span { background: var(--danger); }

/* Buttons & Controls */
.btn {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  gap: 6px;
  min-height: 35px;
  padding: 7px 14px;
  border: 1px solid transparent;
  border-radius: var(--radius-sm);
  cursor: pointer;
  font-family: inherit;
  font-size: 13px;
  font-weight: 600;
  color: #fff;
  background: var(--accent);
  text-decoration: none;
  transition: background 0.14s ease, transform 0.12s ease, border-color 0.14s ease;
}
.btn:hover { background: #0284c7; transform: translateY(-1px); }
.btn:active { transform: translateY(0); }
.btn.sm { min-height: 28px; padding: 4px 10px; font-size: 12px; border-radius: 7px; }
.btn.grey {
  background: var(--surface-2);
  color: var(--text);
  border-color: var(--border);
}
.btn.grey:hover { background: var(--surface-hover); border-color: var(--border-strong); }
.btn.red {
  background: rgba(185, 28, 28, 0.85);
  color: #fee2e2;
  border-color: rgba(239, 68, 68, 0.35);
}
.btn.red:hover { background: #dc2626; }
.btn.copied {
  background: var(--ok-bg) !important;
  color: var(--ok-text) !important;
  border-color: rgba(16, 185, 129, 0.4) !important;
}
.button-icon { width: 15px; height: 15px; }
form.inline { display: inline-flex; gap: 6px; align-items: center; }

/* Inputs & Forms */
input, select {
  font-family: inherit;
  background: var(--bg);
  border: 1px solid var(--border-strong);
  color: var(--text);
  padding: 8px 11px;
  border-radius: var(--radius-sm);
  font-size: 13.5px;
  min-height: 36px;
  transition: border-color 0.14s ease, box-shadow 0.14s ease;
}
input::placeholder { color: var(--text-dim); }
input:focus, select:focus {
  outline: none;
  border-color: var(--accent-hover);
  box-shadow: 0 0 0 3px rgba(56, 189, 248, 0.16);
}
.nav a:focus-visible, .btn:focus-visible, .filter-chip:focus-visible {
  outline: 2px solid var(--accent-hover);
  outline-offset: 2px;
}
.addform {
  background: linear-gradient(160deg, rgba(21, 31, 50, 0.95), rgba(14, 21, 35, 0.96));
  border: 1px solid var(--border);
  border-radius: var(--radius);
  padding: 16px 18px;
  margin-bottom: 16px;
  display: flex;
  gap: 12px;
  flex-wrap: wrap;
  align-items: flex-end;
  box-shadow: var(--shadow);
}
.addform > div { display: flex; flex-direction: column; min-width: 135px; flex: 1 1 145px; }
.addform label, .field-label {
  font-size: 12px;
  font-weight: 500;
  color: var(--text-muted);
  display: block;
  margin-bottom: 5px;
}
.pw-group { display: flex; gap: 6px; }
.pw-group input { flex: 1; min-width: 0; }

/* Table Toolbar (Search + Filter Chips) */
.toolbar {
  display: flex;
  align-items: center;
  justify-content: space-between;
  flex-wrap: wrap;
  gap: 10px;
  margin-bottom: 12px;
}
.search-box {
  position: relative;
  flex: 1 1 240px;
  max-width: 340px;
}
.search-box svg {
  position: absolute;
  left: 11px;
  top: 50%;
  transform: translateY(-50%);
  width: 15px;
  height: 15px;
  color: var(--text-dim);
  pointer-events: none;
}
.search-box input { width: 100%; padding-left: 34px; }
.filter-group { display: flex; flex-wrap: wrap; gap: 6px; align-items: center; }
.filter-chip {
  background: var(--bg-elev);
  border: 1px solid var(--border);
  color: var(--text-muted);
  padding: 5px 11px;
  border-radius: 99px;
  font-size: 12px;
  font-weight: 500;
  cursor: pointer;
  transition: 0.14s ease;
}
.filter-chip:hover { color: var(--text); border-color: var(--border-strong); }
.filter-chip.on {
  background: var(--accent-soft);
  color: var(--accent-hover);
  border-color: rgba(56, 189, 248, 0.38);
}

/* Flash Messages */
.msg {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  background: var(--ok-bg);
  border: 1px solid rgba(16, 185, 129, 0.35);
  color: var(--ok-text);
  padding: 11px 15px;
  border-radius: 10px;
  margin-bottom: 18px;
  font-size: 13.5px;
}
.msg.err {
  background: var(--danger-bg);
  border-color: rgba(239, 68, 68, 0.4);
  color: var(--danger-text);
}
.msg-inner { display: flex; align-items: center; gap: 9px; }
.msg-inner svg { width: 17px; height: 17px; flex: 0 0 17px; }
.msg-close {
  background: none;
  border: 0;
  color: inherit;
  opacity: 0.7;
  cursor: pointer;
  font-size: 18px;
  line-height: 1;
  padding: 0 4px;
}
.msg-close:hover { opacity: 1; }

/* Edit, Settings & Link Cards */
.editform { max-width: 540px; }
.editform label {
  font-size: 12.5px;
  color: var(--text-muted);
  display: block;
  margin: 14px 0 5px;
}
.editform input, .editform select { width: 100%; padding: 9px 11px; }
.form-actions { display: flex; gap: 10px; margin-top: 20px; }
.settings-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(320px, 1fr));
  gap: 18px;
  align-items: start;
}
.meta-line { margin: 10px 0; font-size: 13.5px; color: var(--text-muted); }
.meta-line b { color: var(--text); }
.log-viewer {
  white-space: pre-wrap;
  word-break: break-all;
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 11.5px;
  color: var(--text-muted);
  background: var(--bg);
  border: 1px solid var(--border);
  border-radius: var(--radius-sm);
  padding: 10px 12px;
  max-height: 220px;
  overflow: auto;
  margin-top: 14px;
}
.link-group { margin-bottom: 18px; }
.link-item {
  background: var(--bg-elev);
  border: 1px solid var(--border);
  border-radius: 10px;
  padding: 12px 14px;
  margin-bottom: 10px;
}
.link-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
  margin-bottom: 8px;
}
.link-box {
  background: var(--bg);
  border: 1px solid var(--border);
  border-radius: 8px;
  padding: 9px 11px;
  word-break: break-all;
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 12px;
  color: #cbd5e1;
  line-height: 1.45;
}
.kv-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(230px, 1fr));
  gap: 10px;
  margin: 14px 0 20px;
}
.kv-item {
  background: var(--bg-elev);
  border: 1px solid var(--border);
  border-radius: 10px;
  padding: 11px 13px;
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
}
.kv-item .k { font-size: 11px; color: var(--text-dim); text-transform: uppercase; letter-spacing: 0.06em; }
.kv-item .val {
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 13px;
  color: var(--text);
  word-break: break-all;
  margin-top: 2px;
}

/* Login Screen */
.login-wrap { margin: auto; width: 400px; max-width: 92vw; padding: 24px 0; }
.login-card {
  background: linear-gradient(160deg, #141e33, #0e1524);
  border: 1px solid var(--border);
  border-radius: var(--radius-lg);
  padding: 34px 30px;
  box-shadow: 0 24px 64px rgba(2, 6, 16, 0.65);
}
.login-brand {
  display: flex;
  justify-content: center;
  align-items: center;
  gap: 11px;
  margin-bottom: 6px;
}
.login-card h1 { font-size: 22px; color: var(--text); letter-spacing: 0.05em; }
.login-card p { text-align: center; color: var(--text-dim); font-size: 13px; margin-bottom: 22px; }
.login-card label { font-size: 12.5px; color: var(--text-muted); display: block; margin: 14px 0 5px; }
.login-card input { width: 100%; padding: 10px 12px; }
.login-card .btn { width: 100%; padding: 11px; margin-top: 22px; font-size: 14px; }

.skip-link {
  position: fixed;
  z-index: 20;
  top: 10px;
  left: 10px;
  padding: 8px 12px;
  transform: translateY(-160%);
  border-radius: 8px;
  color: #fff;
  background: var(--accent);
  text-decoration: none;
}
.skip-link:focus { transform: translateY(0); }

/* Responsive */
@media (max-width: 880px) {
  body { flex-direction: column; }
  .sidebar {
    position: relative;
    min-height: auto;
    width: 100%;
    padding: 12px 12px 0;
    border-right: 0;
    border-bottom: 1px solid var(--border);
  }
  .logo { padding: 0 4px 12px; }
  .logo small br { display: none; }
  .nav {
    display: flex;
    gap: 4px;
    overflow-x: auto;
    padding: 0 0 10px;
    scrollbar-width: thin;
  }
  .nav a { flex: 0 0 auto; gap: 7px; padding: 8px 11px; white-space: nowrap; }
  .nav a.on { box-shadow: inset 0 -2px 0 var(--accent-hover); }
  .sidebar-footer { display: none; }
  .main { width: 100%; max-width: none; padding: 22px 16px; }
  .addform { flex-direction: column; align-items: stretch; }
  .addform > div { width: 100%; flex: 1 1 auto; }
}
@media (max-width: 560px) {
  .main { padding: 18px 12px; }
  .cards { grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 10px; }
  .metric-card { padding: 13px; }
  .card .v { font-size: 18px; }
  .live-chip span { display: none; }
}
"""

CLIENT_JS = """
function copyText(text, btn) {
  function done() {
    if (!btn) return;
    var orig = btn.getAttribute('data-orig') || btn.textContent;
    btn.setAttribute('data-orig', orig);
    btn.textContent = 'Copied!';
    btn.classList.add('copied');
    setTimeout(function() {
      btn.textContent = orig;
      btn.classList.remove('copied');
    }, 1500);
  }
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(text).then(done).catch(function() { fallbackCopy(text, done); });
  } else {
    fallbackCopy(text, done);
  }
}
function fallbackCopy(text, cb) {
  var ta = document.createElement('textarea');
  ta.value = text;
  ta.style.position = 'fixed';
  ta.style.opacity = '0';
  document.body.appendChild(ta);
  ta.focus();
  ta.select();
  try { document.execCommand('copy'); if (cb) cb(); } catch (e) {}
  document.body.removeChild(ta);
}
function copyById(id, btn) {
  var el = document.getElementById(id);
  if (el) copyText(el.innerText || el.textContent, btn);
}
function copyAllLinks(btn) {
  var boxes = document.querySelectorAll('.link-item:not([ hidden ]) .link-box');
  var out = [];
  boxes.forEach(function(b) { out.push((b.innerText || b.textContent).trim()); });
  if (out.length) copyText(out.join('\\n'), btn);
}
function genPass(btn) {
  var chars = 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  var arr = new Uint32Array(12);
  if (window.crypto && window.crypto.getRandomValues) window.crypto.getRandomValues(arr);
  var out = '';
  for (var i = 0; i < 12; i++) out += chars[(arr[i] || Math.floor(Math.random() * 999)) % chars.length];
  var inp = btn.parentElement.querySelector('input');
  if (inp) { inp.type = 'text'; inp.value = out; inp.focus(); }
}
function filterUsers() {
  var q = (document.getElementById('user-search') || {}).value || '';
  q = q.toLowerCase().trim();
  var activeChip = document.querySelector('.filter-chip.on');
  var st = activeChip ? activeChip.getAttribute('data-filter') : 'all';
  var rows = document.querySelectorAll('tr[data-user]');
  var shown = 0;
  rows.forEach(function(r) {
    var name = r.getAttribute('data-user') || '';
    var rstate = r.getAttribute('data-state') || '';
    var exp = r.getAttribute('data-expiring') === '1';
    var okQ = !q || name.indexOf(q) !== -1;
    var okS = (st === 'all') || (st === rstate) || (st === 'expiring' && exp);
    var vis = okQ && okS;
    r.hidden = !vis;
    if (vis) shown++;
  });
  var cnt = document.getElementById('visible-count');
  if (cnt) cnt.textContent = shown + ' shown';
}
function setUserFilter(chip) {
  document.querySelectorAll('.filter-chip').forEach(function(c) { c.classList.remove('on'); });
  chip.classList.add('on');
  filterUsers();
}
function filterProto(chip, proto) {
  document.querySelectorAll('.filter-chip').forEach(function(c) { c.classList.remove('on'); });
  chip.classList.add('on');
  document.querySelectorAll('.link-item').forEach(function(item) {
    item.hidden = (proto !== 'ALL' && item.getAttribute('data-proto') !== proto);
  });
}
"""


def _is_error_flash(text):
    low = text.lower()
    return any(k in low for k in ("error:", "wrong", "missing", "unknown", "bad ", "failed"))


def _meter_cls(pct):
    if pct >= 88:
        return "meter crit"
    if pct >= 72:
        return "meter warn"
    return "meter"


def layout(title, active, body, flash="", page_icon="server", extra_js=""):
    nav = [
        (U("/"), "dashboard", "Dashboard", "dashboard"),
        (U("/ssh"), "ssh", "SSH & SSL", "ssh"),
        (U("/xray"), "xray", "Xray", "xray"),
        (U("/zivpn"), "zivpn", "ZIVPN", "zivpn"),
        (U("/services"), "services", "Services", "services"),
        (U("/settings"), "settings", "Settings", "settings"),
        (U("/logout"), "", "Logout", "logout"),
    ]
    nav_items = []
    for href, key, label, icon_name in nav:
        on_cls = " on" if key == active else ""
        aria = ' aria-current="page"' if key == active else ""
        nav_items.append(
            f'<a href="{href}" class="nav-link{on_cls}"{aria}>'
            f'{icon(icon_name, "nav-icon")}<span>{label}</span></a>'
        )
    links = "".join(nav_items)

    msg = ""
    if flash:
        is_err = _is_error_flash(flash)
        m_cls = "msg err" if is_err else "msg"
        m_ico = icon("alert" if is_err else "check")
        msg = (
            f'<div class="{m_cls}" role="status">'
            f'<div class="msg-inner">{m_ico}<span>{esc(flash)}</span></div>'
            f'<button class="msg-close" type="button" aria-label="Dismiss" '
            f'onclick="this.parentElement.remove()">&times;</button></div>'
        )

    return f"""<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="description" content="Ragnar VPS Management Panel - {esc(title)}">
<title>{esc(title)} - Ragnar Panel</title><style>{CSS}</style></head>
<body><a class="skip-link" href="#main">Skip to content</a>
<aside class="sidebar"><div class="logo"><span class="logo-badge">{icon("server", "logo-icon")}</span>
<span>RAGNAR<small>VPS Management Panel<br>by @farisbazed</small></span></div>
<nav class="nav" aria-label="Primary navigation">{links}</nav>
<div class="sidebar-footer"><span class="sidebar-dot"></span><span>Panel ready</span></div></aside>
<main class="main" id="main"><header class="page-heading"><div>
<div class="eyebrow">Ragnar VPS Panel</div><h1>{esc(title)}</h1></div>
<div class="heading-actions"><div class="page-mark">{icon(page_icon)}</div></div></header>{msg}{body}</main>
<script>{CLIENT_JS}{extra_js}</script></body></html>"""


def login_page(error=""):
    err = ""
    if error:
        err = (f'<div class="msg err" role="alert"><div class="msg-inner">'
               f'{icon("alert")}<span>{esc(error)}</span></div></div>')
    return f"""<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="description" content="Sign in to Ragnar VPS Management Panel">
<title>Login - Ragnar Panel</title><style>{CSS}</style></head>
<body><div class="login-wrap"><div class="login-card">
<div class="login-brand"><span class="logo-badge">{icon("server", "logo-icon")}</span>
<h1>RAGNAR</h1></div><p>VPS Management Panel</p>{err}
<form method="post" action="{U('/login')}">
<label for="login-user">Username</label><input id="login-user" name="username" autocomplete="username" required>
<label for="login-pass">Password</label><input id="login-pass" name="password" type="password"
autocomplete="current-password" required>
<button class="btn" id="login-submit" type="submit">Sign in</button></form>
</div></div></body></html>"""


def _filter_toolbar(total_count, include_online=True):
    online_btn = (
        '<button type="button" class="filter-chip" data-filter="online" '
        'onclick="setUserFilter(this)">Online</button>'
        if include_online else ""
    )
    return (
        f'<div class="toolbar">'
        f'<div class="search-box">{icon("search")}'
        f'<input id="user-search" type="search" placeholder="Search username..." '
        f'oninput="filterUsers()" autocomplete="off"></div>'
        f'<div class="filter-group">'
        f'<button type="button" class="filter-chip on" data-filter="all" '
        f'onclick="setUserFilter(this)">All ({total_count})</button>'
        f'{online_btn}'
        f'<button type="button" class="filter-chip" data-filter="expiring" '
        f'onclick="setUserFilter(this)">Expiring &le;3d</button>'
        f'<button type="button" class="filter-chip" data-filter="disabled" '
        f'onclick="setUserFilter(this)">Disabled</button>'
        f'<span id="visible-count" class="eyebrow" style="margin-left:6px">'
        f'{total_count} shown</span></div></div>'
    )


def _days_badge(days):
    if days < 0:
        return f'<span class="pill r">expired ({days}d)</span>'
    if days <= 3:
        return f'<span class="pill w">{days}d</span>'
    return f"{days}d"


def _quota_cell(u):
    used_b = int(u.get("used_bytes", 0))
    quota_gb = float(u.get("quota_gb") or 0)
    used_s = esc(fmt_used(u))
    if quota_gb <= 0:
        return f"<td>{used_s}</td><td>Unlimited</td>"
    limit_b = quota_gb * (1024 ** 3)
    pct = min(100.0, round(used_b * 100.0 / limit_b, 1)) if limit_b > 0 else 0.0
    q_cls = "quota-bar crit" if pct >= 90 else ("quota-bar warn" if pct >= 75 else "quota-bar")
    return (
        f'<td class="quota-cell">{used_s}'
        f'<div class="{q_cls}"><span style="width:{pct}%"></span></div></td>'
        f"<td>{esc(fmt_quota(u))}</td>"
    )


def user_table(rows, kind, csrf):
    """Shared SSH/Xray user table with search/filter attributes and row actions."""
    head = ("<thead><tr><th>User</th><th>Expires</th><th>Left</th><th>Used</th>"
            "<th>Quota</th><th>IP limit</th><th>Status</th><th>Actions</th></tr></thead>")
    out = []
    for name, u in rows.items():
        live = u.get("live")
        enabled = u.get("enabled", True)
        d_left = int(u.get("days_left", 0))
        if not enabled:
            status = '<span class="pill r">disabled</span>'
            rstate = "disabled"
        elif live not in (None, "-", 0):
            status = f'<span class="pill g">online: {esc(live)}</span>'
            rstate = "online"
        else:
            status = '<span class="pill b">active</span>'
            rstate = "active"
        exp_attr = "1" if enabled and d_left <= 3 else "0"
        toggle = "enable" if not enabled else "disable"
        extra_link = ""
        if kind == "xray":
            extra_link = f'<a class="btn sm grey" href="{U("/xray/links")}?u={esc(name)}">Links</a> '
        elif kind == "ssh":
            extra_link = f'<a class="btn sm grey" href="{U("/ssh/info")}?u={esc(name)}">Info</a> '
        out.append(
            f'<tr data-user="{esc(name.lower())}" data-state="{rstate}" data-expiring="{exp_attr}">'
            f"<td><b>{esc(name)}</b></td>"
            f"<td>{esc(u['expiry'])}</td>"
            f"<td>{_days_badge(d_left)}</td>"
            f"{_quota_cell(u)}"
            f"<td>{esc(u.get('ip_limit') or '∞')}</td>"
            f"<td>{status}</td>"
            f'<td><div class="row-actions">{extra_link}'
            f'<a class="btn sm" href="{U("/" + kind + "/edit")}?u={esc(name)}">Edit</a>'
            f'<form class="inline" method="post" action="{U("/" + kind + "/action")}">'
            f'<input type="hidden" name="csrf" value="{csrf}">'
            f'<input type="hidden" name="user" value="{esc(name)}">'
            f'<button class="btn sm grey" name="op" value="renew30" title="Extend 30 days">+30d</button>'
            f'<button class="btn sm grey" name="op" value="{toggle}">{toggle}</button>'
            f'<button class="btn sm red" name="op" value="delete" '
            f'onclick="return confirm(\'Delete {esc(name)}?\')">delete</button>'
            f"</form></div></td></tr>"
        )
    empty_row = '<tr><td colspan="8" class="empty-cell">No users yet. Create one above to get started.</td></tr>'
    return (
        _filter_toolbar(len(rows), include_online=True)
        + f'<div class="tblwrap"><table>{head}<tbody>'
        + ("".join(out) or empty_row)
        + "</tbody></table></div>"
    )


def add_user_form(kind, csrf):
    pw = ""
    if kind in ("ssh", "zivpn"):
        pw = (
            '<div><label>Password</label><div class="pw-group">'
            '<input name="password" required placeholder="Password">'
            '<button class="btn sm grey" type="button" onclick="genPass(this)">Generate</button>'
            "</div></div>"
        )
    uuid_field = ""
    if kind == "xray":
        uuid_field = (
            '<div><label>Custom UUID (VLESS/VMess, optional)</label>'
            '<input name="uuid" placeholder="Auto-generated if blank" autocomplete="off"></div>'
        )
    quota = ""
    if kind in ("ssh", "xray"):
        quota = (
            '<div><label>Quota GB (0 = unlimited)</label>'
            '<input name="quota" type="number" step="any" value="0" min="0"></div>'
            '<div><label>IP limit (0 = unlimited)</label>'
            '<input name="iplimit" type="number" value="0" min="0"></div>'
        )
    return f"""<form class="addform" method="post" action="{U('/' + kind + '/action')}">
<input type="hidden" name="csrf" value="{csrf}">
<div><label>Username</label><input name="user" placeholder="e.g. client01" required></div>{pw}{uuid_field}
<div><label>Days</label><input name="days" type="number" value="30" min="1"></div>
{quota}<button class="btn" name="op" value="create" type="submit">{icon("plus", "button-icon")}Create user</button>
</form>"""


def page_dashboard(csrf, flash=""):
    info = server_info()
    stats = ragnar.stats()
    online = ragnar.online_users()
    bw = ragnar.bandwidth()
    today = bw.get("today") or {}
    month = bw.get("month") or {}

    cards = [
        ("Server IP", info["ip"], info["os"], "ip", None, "stat-ip"),
        ("CPU load", info["cpu"], f"Uptime {info['uptime']}", "cpu", info["cpu_pct"], "stat-cpu"),
        ("Memory", info["ram"], f"{info['ram_pct']}% utilized", "uptime", info["ram_pct"], "stat-ram"),
        ("Disk", info["disk"], f"{info['disk_pct']}% used", "disk", info["disk_pct"], "stat-disk"),
        ("Users", str(stats.get("total", 0)),
         f"SSH {stats.get('ssh', 0)} · Xray {stats.get('vless', 0)} · ZIVPN {stats.get('zivpn', 0)}",
         "users", None, "stat-users"),
        ("Online now", str(online.get("online", 0)),
         "SSH sessions + active Xray", "online", None, "stat-online"),
        ("Bandwidth today", today.get("total_f", "n/a"),
         "Combined WAN traffic", "bandwidth", None, "stat-bwtoday"),
        ("Bandwidth month", month.get("total_f", "n/a"),
         "Combined monthly total", "bandwidth", None, "stat-bwmonth"),
    ]
    card_parts = []
    for k, v, s, icon_name, pct, cid in cards:
        meter_html = ""
        if pct is not None:
            meter_html = f'<div class="{_meter_cls(pct)}"><span data-meter="{cid}" style="width:{pct}%"></span></div>'
        card_parts.append(
            f'<section class="card metric-card"><div class="metric-head">'
            f'<div class="k">{esc(k)}</div><span class="metric-icon-wrap">'
            f'{icon(icon_name, "metric-icon")}</span></div>'
            f'<div class="v" id="{cid}">{esc(v)}</div>'
            f'<div class="s">{esc(s)}</div>{meter_html}</section>'
        )
    card_html = "".join(card_parts)

    service_states = svc_states()
    online_services = sum(1 for _, is_up in service_states if is_up)
    svc_rows = []
    for s, is_up in service_states:
        dot_cls = "on-dot" if is_up else "off-dot"
        st_lbl = "ONLINE" if is_up else "OFFLINE"
        svc_rows.append(
            f'<tr data-svc="{esc(s)}"><td><b>{esc(s)}</b></td>'
            f'<td><span class="dot {dot_cls}"></span><span class="svc-txt">{st_lbl}</span></td>'
            f'<td style="text-align:right">'
            f'<form class="inline" method="post" action="{U("/services/restart")}">'
            f'<input type="hidden" name="csrf" value="{csrf}">'
            f'<input type="hidden" name="unit" value="{esc(s)}">'
            f'<input type="hidden" name="from" value="dashboard">'
            f'<button class="btn sm grey" type="submit">{icon("refresh", "button-icon")}Restart</button>'
            f"</form></td></tr>"
        )
    svc_html = "".join(svc_rows)

    dash_js = f"""
(function() {{
  var apiUrl = "{U('/api/status')}";
  function refreshDash() {{
    if (document.hidden) return;
    fetch(apiUrl, {{ credentials: 'same-origin' }}).then(function(r) {{
      return r.ok ? r.json() : null;
    }}).then(function(d) {{
      if (!d) return;
      var set = function(id, v) {{ var e = document.getElementById(id); if (e && v !== undefined) e.textContent = v; }};
      set('stat-cpu', d.info.cpu);
      set('stat-ram', d.info.ram);
      set('stat-disk', d.info.disk);
      set('stat-users', String(d.stats.total || 0));
      set('stat-online', String(d.online.online || 0));
      set('stat-bwtoday', d.bw_today);
      set('stat-bwmonth', d.bw_month);
      var hs = document.getElementById('health-badge');
      if (hs) hs.textContent = d.online_services + ' of ' + d.total_services + ' online';
      [['stat-cpu', d.info.cpu_pct], ['stat-ram', d.info.ram_pct], ['stat-disk', d.info.disk_pct]].forEach(function(p) {{
        var m = document.querySelector('[data-meter="' + p[0] + '"]');
        if (m) m.style.width = (p[1] || 0) + '%';
      }});
      if (d.services) {{
        Object.keys(d.services).forEach(function(u) {{
          var row = document.querySelector('tr[data-svc="' + u + '"]');
          if (!row) return;
          var up = d.services[u];
          var dot = row.querySelector('.dot');
          var txt = row.querySelector('.svc-txt');
          if (dot) dot.className = 'dot ' + (up ? 'on-dot' : 'off-dot');
          if (txt) txt.textContent = up ? 'ONLINE' : 'OFFLINE';
        }});
      }}
    }}).catch(function() {{}});
  }}
  setInterval(refreshDash, 15000);
}})();
"""
    return layout(
        "Dashboard", "dashboard",
        f'<div class="cards">{card_html}</div>'
        f'<div class="section-heading"><div><div class="eyebrow">Health</div>'
        f'<h2>Service status</h2></div>'
        f'<span class="health-summary" id="health-badge">{online_services} of '
        f'{len(service_states)} online</span></div><div class="tblwrap">'
        f"<table><thead><tr><th>Service</th><th>State</th>"
        f'<th style="text-align:right">Action</th></tr></thead>'
        f"<tbody>{svc_html}</tbody></table></div>",
        flash, page_icon="dashboard", extra_js=dash_js,
    )


def page_users(kind, csrf, flash=""):
    titles = {"ssh": "SSH & SSL users", "xray": "Xray users",
              "zivpn": "ZIVPN users"}
    rows = ragnar._list_rows(kind)
    if kind == "zivpn":
        head = ("<thead><tr><th>User</th><th>Expires</th><th>Left</th>"
                "<th>Status</th><th>Actions</th></tr></thead>")
        body_rows = []
        for n, u in rows.items():
            enabled = u.get("enabled", True)
            d_left = int(u.get("days_left", 0))
            st_pill = ('<span class="pill b">active</span>' if enabled
                       else '<span class="pill r">disabled</span>')
            rstate = "active" if enabled else "disabled"
            exp_attr = "1" if enabled and d_left <= 3 else "0"
            toggle = "enable" if not enabled else "disable"
            body_rows.append(
                f'<tr data-user="{esc(n.lower())}" data-state="{rstate}" data-expiring="{exp_attr}">'
                f"<td><b>{esc(n)}</b></td><td>{esc(u['expiry'])}</td>"
                f"<td>{_days_badge(d_left)}</td><td>{st_pill}</td>"
                f'<td><div class="row-actions">'
                f'<a class="btn sm" href="{U("/zivpn/edit")}?u={esc(n)}">Edit</a>'
                f'<form class="inline" method="post" action="{U("/zivpn/action")}">'
                f'<input type="hidden" name="csrf" value="{csrf}">'
                f'<input type="hidden" name="user" value="{esc(n)}">'
                f'<button class="btn sm grey" name="op" value="renew30" title="Extend 30 days">+30d</button>'
                f'<button class="btn sm grey" name="op" value="{toggle}">{toggle}</button>'
                f'<button class="btn sm red" name="op" value="delete" '
                f'onclick="return confirm(\'Delete {esc(n)}?\')">delete</button>'
                f"</form></div></td></tr>"
            )
        empty_row = '<tr><td colspan="5" class="empty-cell">No users yet. Create one above to get started.</td></tr>'
        table = (
            _filter_toolbar(len(rows), include_online=False)
            + f'<div class="tblwrap"><table>{head}<tbody>'
            + ("".join(body_rows) or empty_row)
            + "</tbody></table></div>"
        )
    else:
        table = user_table(rows, kind, csrf)
    return layout(titles[kind], kind, add_user_form(kind, csrf) + table,
                  flash, page_icon=kind)


def page_edit(kind, user, csrf, flash=""):
    loaders = {"ssh": ragnar.load_ssh, "xray": ragnar.load_xray,
               "zivpn": ragnar.load_zivpn}
    users = loaders[kind]()
    if user not in users:
        return layout("Edit user", kind,
                      f'<div class="card"><p>User \'{esc(user)}\' not found.</p></div>',
                      page_icon=kind)
    u = users[user]
    left = ragnar.days_left(u["expiry"])
    used = (f'<p class="meta-line">Used so far: <b>{esc(fmt_used(u))}</b></p>'
            if kind != "zivpn" else "")
    quota = ""
    if kind in ("ssh", "xray"):
        quota = f"""
<label>Quota GB (0 = unlimited)</label>
<input name="quota" type="number" step="any" min="0" value="{esc(u.get('quota_gb', 0))}">
<label>IP limit (0 = unlimited)</label>
<input name="iplimit" type="number" min="0" value="{esc(u.get('ip_limit', 0))}">"""
    password = ""
    if kind in ("ssh", "zivpn"):
        password = """
<label>New password (leave empty to keep the current one)</label>
<div class="pw-group"><input name="password" type="text" autocomplete="off">
<button class="btn sm grey" type="button" onclick="genPass(this)">Generate</button></div>"""
    enabled = "yes" if u.get("enabled", True) else "no"
    sel_yes = "selected" if enabled == "yes" else ""
    sel_no = "selected" if enabled == "no" else ""
    body = f"""<div class="card editform">
<div class="k">{esc(kind.upper())} user</div>
<div class="v">{esc(user)}</div>
<p class="meta-line">Expires: <b>{esc(u['expiry'])}</b> ({esc(left)} days left)</p>{used}
<form method="post" action="{U('/' + kind + '/edit')}">
<input type="hidden" name="csrf" value="{csrf}">
<input type="hidden" name="user" value="{esc(user)}">
<label>Add days (extends the current expiry)</label>
<input name="days" type="number" min="0" value="0">
{quota}{password}
<label>Enabled</label>
<select name="enabled">
<option value="yes" {sel_yes}>Yes</option>
<option value="no" {sel_no}>No</option>
</select>
<div class="form-actions">
<button class="btn" type="submit">Save changes</button>
<a class="btn grey" href="{U('/' + kind)}">Back</a>
</div></form></div>"""
    return layout(f"Edit {user}", kind, body, flash, page_icon=kind)


def page_ssh_info(user, csrf, flash=""):
    try:
        info = ragnar.ssh_info(user)
    except ValueError:
        return layout("SSH info", "ssh",
                      f'<div class="card"><p>SSH user \'{esc(user)}\' not found.</p></div>',
                      page_icon="ssh")
    pairs = [
        ("Host / Domain", info["host"]),
        ("Username", info["username"]),
        ("Password", info["password"]),
        ("Direct SSH", f"{info['host']}:{info['ssh_port']}"),
        ("Dropbear", f"{info['host']}:{info['dropbear_port']}"),
        ("SSH-WS (Payload)", f"{info['host']}:{info['ws_port']}  ({info['ws_path']})"),
        ("SSH-WS (Framed)", f"{info['host']}:{info['ws_port']}  ({info['ws_path_framed']})"),
        ("SSH-WSS / SSL", f"{info['host']}:{info['wss_port']}  (SNI: {info['sni']})"),
        ("SlowDNS NS", info["slowdns_ns"] or "not configured"),
        ("SlowDNS Public Key", info["slowdns_pubkey"] or "not generated"),
    ]
    kv_cards = []
    for idx, (label, val) in enumerate(pairs):
        vid = f"sshv{idx}"
        kv_cards.append(
            f'<div class="kv-item"><div><div class="k">{esc(label)}</div>'
            f'<div class="val" id="{vid}">{esc(val)}</div></div>'
            f'<button class="btn sm grey" type="button" '
            f'onclick="copyById(\'{vid}\', this)">Copy</button></div>'
        )
    ws_payload = (
        f"GET {info['ws_path']} HTTP/1.1[crlf]"
        f"Host: {info['host']}[crlf]"
        f"Upgrade: websocket[crlf]"
        f"Connection: Upgrade[crlf][crlf]"
    )
    body = (
        f'<div class="section-heading"><div><div class="eyebrow">Account Sheet</div>'
        f'<h2>Connection details for {esc(user)}</h2></div>'
        f'<a class="btn sm grey" href="{U("/ssh")}">Back to SSH users</a></div>'
        f'<div class="kv-grid">{"".join(kv_cards)}</div>'
        f'<div class="link-item"><div class="link-head">'
        f'<span class="pill b">HTTP Custom / NPV Payload</span>'
        f'<button class="btn sm grey" type="button" onclick="copyById(\'ssh-pl\', this)">Copy</button>'
        f'</div><div class="link-box" id="ssh-pl">{esc(ws_payload)}</div></div>'
    )
    return layout(f"SSH info · {user}", "ssh", body, flash, page_icon="ssh")


def page_xray_links(user, csrf, flash=""):
    try:
        groups = ragnar.links_for(user)
    except ValueError:
        return layout("Xray links", "xray",
                      f'<div class="card"><p>Xray user \'{esc(user)}\' not found.</p></div>',
                      page_icon="xray")
    protos = ["ALL", "VLESS", "VMESS", "TROJAN", "SSWS", "ANYTLS"]
    chips = "".join(
        f'<button type="button" class="filter-chip{" on" if p == "ALL" else ""}" '
        f'onclick="filterProto(this, \'{p}\')">{p}</button>'
        for p in protos
    )
    parts = [
        f'<div class="toolbar"><div class="filter-group">{chips}</div>'
        f'<div class="filter-group">'
        f'<button class="btn sm" type="button" onclick="copyAllLinks(this)">'
        f'{icon("copy", "button-icon")}Copy visible links</button>'
        f'<a class="btn sm grey" href="{U("/xray")}">Back</a></div></div>'
    ]
    idx = 0
    for group, items in groups.items():
        parts.append(f'<div class="link-group"><h3>{esc(group)}</h3>')
        for proto, uri in items.items():
            idx += 1
            lid = f"l{idx}"
            parts.append(
                f'<div class="link-item" data-proto="{esc(proto)}">'
                f'<div class="link-head"><span class="pill b">{esc(proto)}</span>'
                f'<button class="btn sm grey" type="button" '
                f'onclick="copyById(\'{lid}\', this)">Copy</button></div>'
                f'<div class="link-box" id="{lid}">{esc(uri)}</div></div>'
            )
        parts.append("</div>")
    return layout(f"Xray links · {user}", "xray", "".join(parts), flash, page_icon="xray")


def page_services(csrf, flash=""):
    states = svc_states()
    online_cnt = sum(1 for _, on in states if on)
    rows = []
    for s, on in states:
        dot_cls = "on-dot" if on else "off-dot"
        st_lbl = "ONLINE" if on else "OFFLINE"
        rows.append(
            f'<tr><td><b>{esc(s)}</b></td>'
            f'<td><span class="dot {dot_cls}"></span>{st_lbl}</td>'
            f'<td style="text-align:right">'
            f'<form class="inline" method="post" action="{U("/services/restart")}">'
            f'<input type="hidden" name="csrf" value="{csrf}">'
            f'<input type="hidden" name="unit" value="{esc(s)}">'
            f'<button class="btn sm grey" type="submit">{icon("refresh", "button-icon")}Restart</button>'
            f"</form></td></tr>"
        )
    st = ragnar.load_settings()

    def sd_file(name, default="-"):
        try:
            with open(os.path.join("/etc/vps-panel/slowdns", name), encoding="utf-8") as fh:
                return fh.read().strip() or default
        except OSError:
            return default

    ns_val = sd_file("nameserver", st.get("ns") or "-")
    pub_val = sd_file("server.pub", st.get("slowdns_pubkey") or "-")
    slow = (
        f'<h3>SlowDNS / DNSTT Configuration</h3>'
        f'<div class="tblwrap"><table><tbody>'
        f'<tr><td>Nameserver</td><td id="sd-ns">{esc(ns_val)}</td>'
        f'<td style="text-align:right"><button class="btn sm grey" type="button" '
        f'onclick="copyById(\'sd-ns\', this)">Copy</button></td></tr>'
        f'<tr><td>Public key</td><td id="sd-pub" style="word-break:break-all;white-space:normal">'
        f'{esc(pub_val)}</td>'
        f'<td style="text-align:right"><button class="btn sm grey" type="button" '
        f'onclick="copyById(\'sd-pub\', this)">Copy</button></td></tr>'
        f'<tr><td>Build</td><td colspan="2">dnstt-server turbo (KCP 10ms, window 1024, smux 4MB)</td></tr>'
        f'<tr><td>MTU</td><td colspan="2">{esc(sd_file("mtu", "1232"))}</td></tr>'
        f'<tr><td>Backend</td><td colspan="2">127.0.0.1:{esc(sd_file("target_port", "22"))}</td></tr>'
        f'<tr><td>Resolver</td><td colspan="2">{esc(sd_file("dns_resolver", "1.1.1.1"))}</td></tr>'
        f"</tbody></table></div>"
    )
    return layout(
        "Services", "services",
        f'<div class="section-heading"><div><div class="eyebrow">Systemd Units</div>'
        f'<h2>Managed daemons</h2></div>'
        f'<span class="health-summary">{online_cnt} of {len(states)} online</span></div>'
        f'<div class="tblwrap"><table><thead><tr><th>Unit</th><th>State</th>'
        f'<th style="text-align:right">Action</th></tr></thead>'
        f'<tbody>{"".join(rows)}</tbody></table></div>{slow}',
        flash, page_icon="services",
    )


def panel_version():
    try:
        with open(os.path.join(BASE, "version"), encoding="utf-8") as f:
            return f.read().split()[0][:7] or "unknown"
    except Exception:
        return "unknown"


def panel_update_state():
    """Last self-update status dict (or None) + tail of the update log."""
    status = None
    try:
        with open(os.path.join(BASE, "update-status.json"), encoding="utf-8") as f:
            status = json.load(f)
    except Exception:
        pass
    tail = ""
    try:
        with open(os.path.join(BASE, "update.log"), encoding="utf-8") as f:
            tail = "".join(f.readlines()[-25:])
    except Exception:
        pass
    return status, tail


def page_settings(csrf, flash=""):
    cfg = load_web_cfg()
    status, tail = panel_update_state()
    last = ""
    if status:
        last = (
            f'<p class="meta-line">Last update run: '
            f'<b>{esc(status.get("state", "-"))}</b> — '
            f'{esc(status.get("message", ""))}<br>'
            f'<span>{esc(status.get("time", ""))}</span></p>'
        )
    log_html = f'<div class="log-viewer">{esc(tail)}</div>' if tail else ""
    body = f"""<div class="settings-grid">
<div class="card editform">
<form method="post" action="{U('/settings/password')}">
<input type="hidden" name="csrf" value="{csrf}">
<div class="k">Administrator Credentials</div>
<p class="meta-line">Username: <b>{esc(cfg['username'])}</b> · Port: <b>{esc(cfg.get('port', DEFAULT_PORT))}</b></p>
<label for="cur-pw">Current password</label>
<input id="cur-pw" name="current" type="password" required>
<label for="new-pw">New password</label>
<input id="new-pw" name="new" type="password" required>
<label for="new-user">New username (optional)</label>
<input id="new-user" name="newuser" value="{esc(cfg['username'])}">
<div class="form-actions"><button class="btn" type="submit">Save credentials</button></div>
</form></div>

<div class="card editform">
<form method="post" action="{U('/settings/update')}">
<input type="hidden" name="csrf" value="{csrf}">
<div class="k">Panel Self-Update</div>
<p class="meta-line">Installed version: <b>{esc(panel_version())}</b></p>
{last}
<p class="meta-line">Downloads the latest main branch from GitHub, backs up current state to <code>/root</code>, and updates panel code in place while preserving users, certificates, and SlowDNS keys.</p>
<div class="form-actions"><button class="btn" type="submit">{icon("refresh", "button-icon")}Update panel now</button></div>
</form>{log_html}</div></div>"""
    return layout("Settings", "settings", body, flash, page_icon="settings")


# ---------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------
def do_user_action(kind, form):
    op, user = form.get("op", ""), form.get("user", "").strip()
    if not user:
        return "Error: Missing username."
    try:
        if op == "create":
            days = int(form.get("days", 30))
            if kind == "ssh":
                u = ragnar.ssh_add(user, form.get("password", ""), days,
                                   float(form.get("quota", 0)),
                                   int(form.get("iplimit", 0)))
                ragnar.sync_linux_user(user, u["password"], u["expiry"], True)
            elif kind == "xray":
                ragnar.xray_add(user, days, float(form.get("quota", 0)),
                                int(form.get("iplimit", 0)),
                                form.get("uuid", ""))
                ragnar.apply_configs()
            elif kind == "zivpn":
                ragnar.zivpn_add(user, form.get("password", ""), days)
                ragnar.apply_configs()
            return f"User '{user}' created."
        if op == "delete":
            if kind == "ssh":
                ragnar.ssh_del(user)
                ragnar.delete_linux_user(user)
            elif kind == "xray":
                ragnar.xray_del(user)
                ragnar.apply_configs()
            elif kind == "zivpn":
                ragnar.zivpn_del(user)
                ragnar.apply_configs()
            return f"User '{user}' deleted."
        if op in ("enable", "disable"):
            enable = op == "enable"
            if kind == "ssh":
                u = ragnar.ssh_edit(user, enable=enable)
                ragnar.sync_linux_user(user, u["password"], u["expiry"], enable)
            elif kind == "xray":
                ragnar.xray_edit(user, enable=enable)
                ragnar.apply_configs()
            elif kind == "zivpn":
                ragnar.zivpn_edit(user, enable=enable)
                ragnar.apply_configs()
            return f"User '{user}' {'enabled' if enable else 'disabled'}."
        if op == "renew30":
            if kind == "ssh":
                u = ragnar.ssh_edit(user, days=30, extend=True)
                ragnar.sync_linux_user(user, u["password"], u["expiry"],
                                       u.get("enabled", True))
            elif kind == "xray":
                ragnar.xray_edit(user, days=30, extend=True)
                ragnar.apply_configs()
            elif kind == "zivpn":
                ragnar.zivpn_edit(user, days=30, extend=True)
                ragnar.apply_configs()
            return f"User '{user}' extended by 30 days."
    except Exception as exc:
        return f"Error: {exc}"
    return "Error: Unknown action."


def do_edit(kind, form):
    user = form.get("user", "").strip()
    if not user:
        return "Error: Missing username."
    try:
        days = int(form.get("days", 0))
        enable = form.get("enabled", "yes") == "yes"
        password = form.get("password", "")
        if kind == "ssh":
            kw = {"enable": enable}
            if days > 0:
                kw.update(days=days, extend=True)
            if "quota" in form:
                kw["quota_gb"] = float(form["quota"])
            if "iplimit" in form:
                kw["ip_limit"] = int(form["iplimit"])
            if password:
                kw["password"] = password
            u = ragnar.ssh_edit(user, **kw)
            ragnar.sync_linux_user(user, u["password"], u["expiry"],
                                   u.get("enabled", True))
        elif kind == "xray":
            kw = {"enable": enable}
            if days > 0:
                kw.update(days=days, extend=True)
            if "quota" in form:
                kw["quota_gb"] = float(form["quota"])
            if "iplimit" in form:
                kw["ip_limit"] = int(form["iplimit"])
            ragnar.xray_edit(user, **kw)
            ragnar.apply_configs()
        elif kind == "zivpn":
            kw = {"enable": enable}
            if days > 0:
                kw.update(days=days, extend=True)
            if password:
                kw["password"] = password
            ragnar.zivpn_edit(user, **kw)
            ragnar.apply_configs()
        return f"User '{user}' saved."
    except Exception as exc:
        return f"Error: {exc}"


# ---------------------------------------------------------------------
# HTTP handler
# ---------------------------------------------------------------------
class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _send(self, code, body, ctype="text/html; charset=utf-8", extra=None):
        data = body.encode("utf-8") if isinstance(body, str) else body
        headers = {
            "Cache-Control": "no-store",
            "X-Content-Type-Options": "nosniff",
            "X-Frame-Options": "DENY",
        }
        if extra:
            headers.update(extra)
        accept_enc = self.headers.get("Accept-Encoding", "")
        if len(data) > 1024 and "gzip" in accept_enc:
            data = gzip.compress(data, compresslevel=5)
            headers["Content-Encoding"] = "gzip"
            headers["Vary"] = "Accept-Encoding"
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        for k, v in headers.items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def _redirect(self, to, cookie=None):
        extra = {"Location": to}
        if cookie is not None:
            extra["Set-Cookie"] = cookie
        self._send(303, "", extra=extra)

    def _session_token(self):
        for part in self.headers.get("Cookie", "").split(";"):
            part = part.strip()
            if part.startswith("ragnar_session="):
                return part.split("=", 1)[1]
        return ""

    def _session(self):
        tok = self._session_token()
        return check_session(tok) if tok else None

    def _form(self):
        n = min(65536, max(0, int(self.headers.get("Content-Length", 0))))
        raw = self.rfile.read(n).decode("utf-8", errors="replace")
        return {k: v[0] for k, v in urllib.parse.parse_qs(raw).items()}

    def _authed(self):
        if not self._session():
            self._redirect(U("/login"))
            return False
        return True

    def _route_path(self):
        p = urllib.parse.urlparse(self.path).path
        if BASE_PATH and (p == BASE_PATH or p.startswith(BASE_PATH + "/")):
            p = p[len(BASE_PATH):] or "/"
        return p

    def _csrf_ok(self, form):
        return hmac.compare_digest(form.get("csrf", ""),
                                   csrf_token(self._session_token()))

    def do_GET(self):
        path = self._route_path()
        qs = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        flash = qs.get("msg", [""])[0]
        if path == "/login":
            if self._session():
                return self._redirect(U("/"))
            return self._send(200, login_page())
        if path == "/logout":
            return self._redirect(
                U("/login"), "ragnar_session=; Max-Age=0; Path=/; HttpOnly")
        if not self._authed():
            return
        if path == "/api/status":
            return self._send(
                200, json.dumps(api_status_payload()),
                ctype="application/json; charset=utf-8")
        csrf = csrf_token(self._session_token())
        try:
            if path == "/":
                self._send(200, page_dashboard(csrf, flash))
            elif path in ("/ssh", "/xray", "/zivpn"):
                self._send(200, page_users(path[1:], csrf, flash))
            elif path in ("/ssh/edit", "/xray/edit", "/zivpn/edit"):
                self._send(200, page_edit(path.split("/")[1],
                                          qs.get("u", [""])[0], csrf, flash))
            elif path == "/ssh/info":
                self._send(200, page_ssh_info(qs.get("u", [""])[0], csrf, flash))
            elif path == "/xray/links":
                self._send(200, page_xray_links(qs.get("u", [""])[0], csrf, flash))
            elif path == "/services":
                self._send(200, page_services(csrf, flash))
            elif path == "/settings":
                self._send(200, page_settings(csrf, flash))
            else:
                self._send(404, "Not found")
        except Exception as exc:
            self._send(500, f"Error: {esc(exc)}")

    def do_POST(self):
        path = self._route_path()
        form = self._form()
        if path == "/login":
            ip = self.client_address[0]
            if login_locked(ip):
                return self._send(429, login_page("Too many attempts - wait 5 minutes."))
            if check_password(form.get("username", ""), form.get("password", "")):
                _failures.pop(ip, None)
                token = make_session(form["username"])
                secure = "; Secure" if self.server.tls else ""
                return self._redirect(
                    U("/"),
                    f"ragnar_session={token}; Path=/; HttpOnly; "
                    f"SameSite=Lax; Max-Age={SESSION_TTL}{secure}",
                )
            note_login_failure(ip)
            time.sleep(0.7)
            return self._send(401, login_page("Wrong username or password."))
        if not self._authed():
            return
        if not self._csrf_ok(form):
            return self._send(403, "Bad CSRF token - reload the page.")
        if path in ("/ssh/action", "/xray/action", "/zivpn/action"):
            kind = path.split("/")[1]
            msg = do_user_action(kind, form)
            return self._redirect(U(f"/{kind}") + "?msg=" + urllib.parse.quote(msg))
        if path in ("/ssh/edit", "/xray/edit", "/zivpn/edit"):
            kind = path.split("/")[1]
            msg = do_edit(kind, form)
            return self._redirect(U(f"/{kind}") + "?msg=" + urllib.parse.quote(msg))
        if path == "/services/restart":
            unit = form.get("unit", "")
            if unit in SERVICES:
                subprocess.run(["systemctl", "restart", unit],
                               capture_output=True)
                dest = "/" if form.get("from") == "dashboard" else "/services"
                return self._redirect(
                    U(dest) + "?msg=" + urllib.parse.quote(unit + " restarted"))
            return self._send(400, "Unknown service")
        if path == "/settings/password":
            if not check_password(load_web_cfg()["username"],
                                  form.get("current", "")):
                return self._redirect(U("/settings") + "?msg=" + urllib.parse.quote("Current password is wrong"))
            newuser = form.get("newuser", "").strip() or load_web_cfg()["username"]
            set_password(newuser, form["new"])
            return self._redirect(
                U("/login"), "ragnar_session=; Max-Age=0; Path=/; HttpOnly")
        if path == "/settings/update":
            script = os.path.join(BASE, "core", "update.sh")
            started = False
            if shutil.which("systemd-run"):
                r = subprocess.run(["systemd-run", "--unit=ragnar-update",
                                    "--collect", "/bin/bash", script],
                                   capture_output=True)
                started = r.returncode == 0
            if not started:
                logf = open(os.path.join(BASE, "update.log"), "ab")
                subprocess.Popen(["/bin/bash", script], stdout=logf,
                                 stderr=logf, start_new_session=True)
            return self._redirect(
                U("/settings") + "?msg=" + urllib.parse.quote(
                    "Update started - it runs in the background and the "
                    "panel restarts during it. Refresh in a minute."))
        self._send(404, "Not found")


def serve():
    cfg = load_web_cfg()
    port = int(os.environ.get("RAGNAR_WEB_PORT", cfg.get("port", DEFAULT_PORT)))
    bind = os.environ.get("RAGNAR_WEB_BIND", "0.0.0.0")
    ThreadingHTTPServer.allow_reuse_address = True
    httpd = ThreadingHTTPServer((bind, port), Handler)
    httpd.tls = False
    ctx = None
    if not os.environ.get("RAGNAR_WEB_NO_TLS"):
        cert = os.path.join(BASE, "certs", "fullchain.pem")
        key = os.path.join(BASE, "certs", "privkey.pem")
        combo = os.path.join(BASE, "certs", "haproxy.pem")
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        try:
            if os.path.exists(cert) and os.path.exists(key):
                ctx.load_cert_chain(cert, key)
            elif os.path.exists(combo):
                ctx.load_cert_chain(combo, combo)
            else:
                ctx = None
        except ssl.SSLError:
            ctx = None
    if ctx is not None:
        httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
        httpd.tls = True
    print(f"Ragnar web panel on {bind}:{port}{BASE_PATH} "
          f"({'HTTPS' if httpd.tls else 'HTTP'})", flush=True)
    httpd.serve_forever()


def _random_password():
    return secrets.token_urlsafe(12)


if __name__ == "__main__":
    args = sys.argv[1:]
    if args[:1] == ["--init"]:
        cfg = load_web_cfg()
        if "hash" in cfg:
            print(f"Web login already set for user '{cfg['username']}'. "
                  "Use --reset-password to change it.")
        else:
            pw = _random_password()
            set_password(cfg["username"], pw)
            print(f"Web panel login created - user: {cfg['username']}  "
                  f"password: {pw}")
            print("Save it now; change it later in Settings or with "
                  "--reset-password.")
    elif args[:1] == ["--reset-password"]:
        cfg = load_web_cfg()
        pw = _random_password()
        set_password(cfg["username"], pw)
        print(f"Web panel password reset - user: {cfg['username']}  "
              f"new password: {pw}")
    elif args[:1] == ["--set-password"] and len(args) == 3:
        set_password(args[1], args[2])
        print(f"Web panel login set for user '{args[1]}'.")
    else:
        serve()
