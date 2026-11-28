# Ragnar VPS Management Panel

**Telegram:** [@farisbazed](https://t.me/farisbazed) · **Channel:** [t.me/ragnaresim](https://t.me/ragnaresim)

A complete VPS panel in the style of the classic SSH/Xray autoscripts —
one menu that runs SSH, WebSocket, SSL, Xray, Cloudflare, UDP and SlowDNS
together **without the ports fighting each other**.

[Terminal preview](docs/look.txt) — the dashboard shows host resources,
transfer, accounts and service health above the numbered menus. On narrow
terminals, values stack and optional hints give way to action labels.
Press **T · Appearance** to select Orchid, Evergreen, Cobalt or Parchment,
or to restore the default terminal colors; press **L · Layout** (or keys 6–9
inside Appearance) to switch between **Classic**, **Boxed** (rounded card
panels), **Compact** (two-column split HUD) and **Ledger** (double-ruled
console). Preferences are saved per user in `$XDG_CONFIG_HOME/ragnar/terminal-theme`
and `$XDG_CONFIG_HOME/ragnar/terminal-layout` (normally under `~/.config/ragnar/`),
independently of the web panel.
Use `NO_COLOR=1 menu` for unstyled output without changing your preference.

## Install

Fresh **Ubuntu 22.04 / 24.04** or **Debian 11 / 12**, as root:

```bash
git clone https://github.com/faresbazed/ragnar-vps-panel.git
cd ragnar-vps-panel
sudo bash install.sh
```

The installer asks for a domain (optional — blank uses the IP with a
self-signed cert) and a SlowDNS nameserver (optional). Non-interactive:

```bash
RAGNAR_DOMAIN=vpn.example.com RAGNAR_NS=ns.example.com sudo -E bash install.sh
```

Then open the panel any time with:

```bash
menu        # or: ragnar
```

Uninstall from the menu (option **13**) or `sudo bash /etc/ragnar/uninstall.sh`.
It restores configuration and service state captured before the installer
changes them, and removes tagged firewall rules and recorded UFW allowances.
For udp-custom's untagged rules, uninstall only removes recognized rules absent
from the pre-install snapshot; older installs without this snapshot leave them alone.
Xray, sing-box, cloudflared (including a tunnel service created from the
menu) and the Go toolchain are removed when Ragnar
installed them and the sister panel is not present; components that existed
before Ragnar and required Debian/Ubuntu packages are left installed. An independently
configured cloudflared service keeps its binary. Shared SlowDNS data in
`/etc/vps-panel/slowdns` is kept for the sister panel.

The current uninstaller requires the private installer records in
`/var/lib/ragnar-panel` (or the same `RAGNAR_STATE_DIR` used at install).
It will not guess what to delete on a legacy installation without records.
If restoration fails, some services may already be stopped: correct the
reported error and rerun uninstall. The panel and its recovery records are
kept until restoration succeeds. Linux account removal requires a separate
confirmation; choosing **no** keeps those accounts but removes the panel database.
Files overwritten before snapshots existed cannot be reconstructed automatically.

To verify removal without touching live services, run `bash tests/test_uninstall.sh`
on Linux with unprivileged user namespaces enabled. It runs the uninstaller in
a temporary chroot with fake accounts, services and firewall commands.

## Updating

The panel updates itself from GitHub — no re-clone needed:

- **Terminal menu:** option **10 · UPDATE PANEL**
- **Web panel:** Settings → **Update panel now**
- **Script:** `sudo bash /etc/ragnar/core/update.sh`
  (`check` only compares versions; `--force` reinstalls even if they match)

An update downloads a specific `main` commit and backs up `/etc/ragnar` to a
unique, root-only `/root/ragnar-backup-pre-update-<date>-<suffix>.tar.gz`
before installing. Account databases, web credentials, settings and SlowDNS
keys are kept. A valid renewed Let's Encrypt certificate takes precedence over
the local pair. Damaged JSON or an incomplete key pair stops the upgrade
rather than silently resetting accounts or generating a new identity.

The updater records the new commit in `/etc/ragnar/version` only after the
installer succeeds. On failure, check `/etc/ragnar/update-status.json` and
`/etc/ragnar/update.log`, fix the reported problem and retry. A late failure
can leave new code or host configuration in place; the archive is a panel
state backup, not an automatic host rollback.

When upgrading from a release that predates these checks, run
`sudo bash core/update.sh --force` from a fresh checkout to use the new
backup and validation flow on that first upgrade as well.

## The port-sharing solution

Only **HAProxy binds 80 and 443**. Everything else is loopback-only,
health-checked, and revived by a watchdog every minute:

| Stage | What happens |
|---|---|
| 443 arrives | HAProxy peeks at the TLS **SNI**: `anytls.*` → sing-box AnyTLS (raw TLS passthrough). Everything else → stage 2 |
| Stage 2 (TLS terminated) | First bytes inspected: `GET /ragnar-vless` etc. → that Xray protocol; other `GET` → landing page; **not HTTP at all → SSH backend** (that's SSH-over-SSL) |
| 80 arrives | Same path routing without TLS; unknown paths fall through to the SSH-WS proxy so payload apps keep working |

So SSH-SSL, WSS and AnyTLS genuinely share 443, and no service can kill
another by grabbing its port. Backends: OpenSSH 22, Dropbear 109,
SSH-WS proxy 10005, Xray 10001–10004, AnyTLS 10006 (plus 8446 fallback).

**Checking TLS 1.3:** connect directly to the panel domain (not a Cloudflare
tunnel or the `anytls.` subdomain), replacing `vpn.example.com` below:

```bash
openssl s_client -connect vpn.example.com:443 -servername vpn.example.com \
  -tls1_3 -verify_hostname vpn.example.com -verify_return_error -brief
```

Leave the connection open without typing. `Protocol version: TLSv1.3`
confirms negotiation; an `SSH-2.0-…` banner confirms the SSH backend too.
For a self-signed install, supply the trusted panel certificate with `-CAfile`.

## Features

### SSH & SSL users
- Create / list / **edit** / delete / renew users (real Linux accounts)
- **Per-user GB quota** (iptables owner-match counters, checked every minute)
- **Per-user IP limit** (extra source IPs get their sessions kicked)
- Expiry in days, enable/disable, password change
- User info sheet: host, ports, WS path, SNI, SlowDNS NS + public key
- **Two SSH-WS flavours, both on 80/443** — the proxy is hybrid:
  - `/ragnar-sshws` — **payload/raw mode** for NPV Tunnel, HTTP Custom,
    HA Tunnel etc. *Any* payload works: the proxy answers 101 to any
    request head (no Sec-WebSocket-Key required, any method, LF or CRLF)
    and then pipes raw SSH bytes, exactly like the classic panel proxies.
  - `/ragnar-sshwsf` — **true WebSocket framing** for NapsternetV-style
    WS clients (proper handshake, masked binary frames).
  - Any other path auto-detects from the first bytes the client sends.

### Xray — all protocols from one user
Creating one Xray user generates **all of these at the same time**, each
with links for **direct WS 80, direct WSS 443, Cloudflare WS 80 and
Cloudflare WSS 443**:

- **VLESS** · **VMESS** · **Trojan** · **SSWS** (Shadowsocks 2022) — Xray-core, WebSocket transport
- **AnyTLS** — via a sing-box sidecar (Xray-core has no AnyTLS; anyone
  telling you otherwise is selling you a config Xray will reject).
  AnyTLS is raw TLS, so it is direct-only on 443 (SNI-routed) / 8446 —
  Cloudflare's HTTP proxy cannot carry it.

Per-user expiry, GB quota (Xray Stats API counters) and edit/renew work
the same as SSH. Xray traffic totals cover VLESS, VMess, Trojan and SSWS;
AnyTLS uses a separate sing-box service and is not included in those totals.
When creating an account in the terminal menu or web panel, an optional
canonical RFC 4122 UUID can be supplied for VLESS/VMess; leave it blank for
automatic generation. Custom UUIDs must be valid and not already assigned to
another Xray user.

In **Xray accounts**, **Browse links** groups routes by Direct, Cloudflare
and AnyTLS. **Find by protocol** starts with the client protocol instead.
Choose a route and protocol to print one complete URI on its own line.
**Reveal all links** requires confirmation: these links contain credentials.

### Cloudflared
Menu **11**: set the domain, set the hostname used in Cloudflare links,
install a named-tunnel token, or start a quick trycloudflare tunnel.
Point the tunnel at `http://127.0.0.1:80` (the HAProxy front door) —
one tunnel then carries every WS protocol.

### UDP, optimized
Applied at install: BBR + fq, 64 MB socket buffers, big backlogs,
conntrack headroom, `LimitNOFILE` everywhere.

- **UDP ZIVPN** — server on 5667, per-user passwords, whole client port
  range **6000–19999 redirected** to it, self-signed cert generated.
- **UDP Custom** (ePro binary, SHA-256 verified against the pinned
  upstream hash) — listen 36712 with the upstream-optimized 80 MB
  receive buffer, ports **20000–65535 redirected** to it, badvpn-udpgw
  on 7300, SSH users mirrored as auth entries.
- **SlowDNS** (DNSTT) — UDP 53 redirected to dnstt on 5300 → SSH.
  The sister panel's implementation
  ([Ragnar-VPS-Management-Panel](https://github.com/faresbazed/Ragnar-VPS-Management-Panel)),
  integrated by `core/slowdns-setup.sh` (their verbatim script is
  kept at `core/ragnar-slowdns-setup` for reference): turbo-patched
  dnstt-server build (KCP `SetNoDelay(1, 10, 2, 1)` +
  `SetWindowSize(1024, 1024)`, turbotunnel `QueueSize = 1024`,
  smux buffers 4 MB), their NAT cleanup/assert block, Cloudflare
  API provisioning and unit shape — with this panel's settings.json
  as the config store, keys in `/etc/ragnar/slowdns/`, and their
  `/etc/vps-panel/slowdns/` layout mirrored on every run. The
  SlowDNS menu mirrors their manager: nameserver + CF token,
  diagnostic, SSH backend switch (OpenSSH 22 ⇄ Dropbear 109),
  resolver, MTU, key regeneration, and the turbo preset (rebuild +
  Dropbear backend + MTU 1232). MTU defaults to 1232 on purpose:
  the server `-mtu` is also the minimum EDNS size demanded from
  requesters, and a measured carrier path advertising 1395 bytes
  was FORMERR-rejected at MTU 1400, dropping sessions every minute.

### Panel
- Header: VPS IP, ISP, OS, uptime, CPU/RAM/disk, server time, bandwidth,
  user stats (per protocol + total + online) and live service status
- Per-user traffic is shown in the SSH and Xray account lists and details.
  SSH totals include SSH, SSH-WS/SSL and SlowDNS traffic forwarded to the
  user's SSH backend (port 22 or 109); SlowDNS shares the SSH user's total.
- Per-user metering is not available for AnyTLS, UDP ZIVPN or UDP Custom in
  the current integration. The server-wide bandwidth total still includes
  all interface traffic, but it cannot identify those bytes by user.
- **Tools:** restart all services, user backup, run the limit checker,
  speed test, listening ports
- **Clear RAM**, **Reboot VPS**, **Uninstall** — all in the menu
- `ragnar-check.timer` enforces expiry/quota/IP limits every minute;
  `ragnar-watchdog.timer` restarts any dead service every minute
- SSH traffic accounting uses per-socket `ss -tnpi` byte counters
  (iptables owner-match cannot see daemon relay traffic — accepted
  sockets belong to the root listener); this also captures SlowDNS sessions
  after DNSTT forwards them into the SSH backend

### Web panel (3x-ui style)
- Choose a panel layout (**Classic**, **Sidebar**, **Bento**, or **Console**)
  and a color theme (**Dark**, **Light**, **Orchid**, **Evergreen**, **Cobalt**,
  or **Parchment**) independently from the sign-in card or panel header. Both
  choices are saved in this browser and do not change the terminal's appearance.
- `https://<your-domain>/panel` — username/password login (PBKDF2,
  lockout after failed attempts), served with the panel's own domain
  certificate by `ragnar-web.service`
- Dashboard (server info, measured bandwidth, user totals, online,
  service status), SSH / Xray / ZIVPN user management, Xray links with
  copy buttons, service restarts, SlowDNS info, password change
- Single file (`web/webpanel.py`), Python standard library only; all
  actions go through the same `core/ragnar.py` as the terminal menu.
  Login is created at install (`--init` prints it once) and can be
  reset from the terminal menu: **WEB PANEL → RESET ADMIN PASSWORD**

## Ports

| Port | Service |
|---|---|
| 22/tcp | SSH direct |
| 109, 143/tcp | Dropbear |
| 80/tcp | WS — all protocols + SSH-WS (HAProxy) |
| 443/tcp | WSS + SSH-SSL + AnyTLS SNI (HAProxy) |
| 8446/tcp | AnyTLS fallback |
| 443/tcp `/panel` | Web panel (HTTPS via HAProxy; app on loopback :2053) |
| 53 udp/tcp | SlowDNS |
| 5667/udp (+6000–19999) | ZIVPN |
| 36712/udp (+20000–65535) | UDP Custom |
| 7300 (loopback) | badvpn-udpgw |

## Layout

```
menu.sh            the panel (installed as `menu` / `ragnar`)
install.sh         one-shot installer        uninstall.sh
core/ragnar.py     user DBs, config + link generation (stdlib only)
core/checker.py    expiry / quota / IP-limit enforcer (1-minute timer)
core/wsproxy.py    SSH-over-WebSocket proxy (stdlib only)
core/watchdog.sh   dead-service reviver (1-minute timer)
web/webpanel.py    3x-ui style web panel at /panel (stdlib only)
configs/           HAProxy front door + sysctl tuning
tests/             local tests: python3 tests/test_ragnar.py
                   python3 tests/test_wsproxy.py
```

## Verification done locally (before any VPS)

- Core unit tests: 41 checks (users, UUID validation, edits, links, config, enforcement)
- Installer-state regression test: `bash tests/test_install_state.sh`
- TLS routing regression test: `python3 tests/test_tls_routing.py -v`
  (requires HAProxy and OpenSSL; uses only temporary loopback ports)
- Generated Xray config validated with **real Xray 25.10.15**, and all
  four WS protocols tunnelled live traffic through it
- Generated sing-box config validated with **real sing-box 1.12.9**;
  AnyTLS tunnelled live traffic, both direct and through HAProxy's
  443 SNI passthrough
- HAProxy config validated with **real HAProxy 2.8**, and a live
  front-door test passed all at once: SSH-WS on 80, SSH-WSS on 443,
  raw SSH-SSL banner on 443, HTTPS landing on 443, VLESS on 80 and 443

What still needs a real VPS: the systemd installer end-to-end, the
closed-source UDP binaries (ZIVPN / UDP Custom download at install time),
SlowDNS over a real NS delegation, and Cloudflared with a real tunnel
token — the sandbox here cannot answer UDP or run systemd.
