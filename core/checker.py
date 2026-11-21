#!/usr/bin/env python3
"""
Ragnar limit checker - run every minute by ragnar-check.timer.

Enforces, for every panel user:
  * expiry date          (SSH: lock + kill sessions; Xray/ZIVPN: disable + regen)
  * GB quota             (same actions; counters below)
  * SSH IP limit         (extra source IPs get ONLY that user's extra sessions killed)

Traffic counters:
  * Xray: `xray api statsquery` user>>>email>>>traffic counters are added
    into used_bytes (Xray resets its counters on restart, so we accumulate
    deltas into the panel DB each run).
  * SSH: per-socket byte counters from `ss -tnpi` (tcp_info bytes_sent /
    bytes_received on the client-facing socket of each sshd/dropbear
    session - local port 22/109/143). DNSTT forwards SlowDNS sessions to
    the user's SSH backend on port 22 or 109, so those bytes are included.
    The daemon's outbound sockets to forwarded targets are excluded so
    relayed bytes count once.

Without --apply it only prints the plan (dry run).
"""
import json
import os
import pwd
import re
import signal
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ragnar  # noqa: E402


def run(cmd):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True).stdout


def counter_delta(prev, total):
    """Bytes moved since the previous reading of a cumulative counter."""
    prev, total = int(prev), int(total)
    return total if total < prev else total - prev


def _pid_user(pid):
    try:
        with open(f"/proc/{pid}/status") as fh:
            uid = int(re.search(r"^Uid:\s+(\d+)", fh.read(), re.M).group(1))
        return pwd.getpwuid(uid).pw_name
    except Exception:
        return None


DAEMON_PORTS = {"22", "109", "143"}  # sshd / dropbear listen ports
SOCKET_LINE_RE = re.compile(r'(\S+):(\d+)\s+(\S+):(\d+)\s+users:\(\((.*?)\)\)')


def _strip_brackets(host):
    if host.startswith("[") and host.endswith("]"):
        return host[1:-1]
    if host.startswith("::ffff:") and "." in host:
        return host[7:]
    return host


def _iter_daemon_sockets(ss_text):
    """Yield (user, local_ep, peer_ep, peer_ip, user_pids, next_line_info)
    for client-facing sshd/dropbear sockets on DAEMON_PORTS."""
    pid_cache = {}

    def lookup(pid):
        if pid not in pid_cache:
            pid_cache[pid] = _pid_user(pid)
        return pid_cache[pid]

    lines = ss_text.splitlines()
    i = 0
    n = len(lines)
    while i < n:
        line = lines[i]
        m = SOCKET_LINE_RE.search(line)
        if not m:
            i += 1
            continue
        local_host, local_port, peer_host, peer_port, blob = m.groups()
        info_line = ""
        if i + 1 < n and not SOCKET_LINE_RE.search(lines[i + 1]):
            info_line = lines[i + 1]
            i += 2
        else:
            i += 1
        if local_port not in DAEMON_PORTS:
            continue
        if '"sshd"' not in blob and '"dropbear"' not in blob:
            continue
        user = None
        user_pids = []
        for pid_s in re.findall(r"pid=(\d+)", blob):
            pid = int(pid_s)
            u = lookup(pid)
            if u and u != "root":
                user = user or u
                if u == user and pid not in user_pids:
                    user_pids.append(pid)
        if user and user != "root":
            yield (
                user,
                f"{local_host}:{local_port}",
                f"{peer_host}:{peer_port}",
                _strip_brackets(peer_host),
                user_pids,
                info_line,
            )


def parse_socket_bytes(ss_text):
    """{(user, local, peer): (bytes_sent, bytes_received)} for client-facing
    sshd/dropbear sessions from `ss -tnpi state established` output."""
    sockets = {}
    for user, local_ep, peer_ep, _, _, info_line in _iter_daemon_sockets(ss_text):
        if not info_line:
            continue
        sent = re.search(r"bytes_sent:(\d+)", info_line)
        recv = re.search(r"bytes_received:(\d+)", info_line)
        if sent and recv:
            sockets[(user, local_ep, peer_ep)] = (
                int(sent.group(1)), int(recv.group(1)))
    return sockets


def socket_usage_deltas(ss_text, prev_state):
    """({user: bytes}, new_state) from one ss snapshot vs the stored one."""
    current = parse_socket_bytes(ss_text)
    per_user, new_state = {}, {}
    for key, (sent, recv) in current.items():
        user = key[0]
        skey = "|".join(key)
        p_sent, p_recv = prev_state.get(skey, (0, 0))
        delta = counter_delta(p_sent, sent) + counter_delta(p_recv, recv)
        if delta:
            per_user[user] = per_user.get(user, 0) + delta
        new_state[skey] = [sent, recv]
    return per_user, new_state


def xray_deltas():
    """{email: bytes} since last run, from the Xray Stats API."""
    out = run("/usr/local/bin/xray api statsquery -server=127.0.0.1:10085 2>/dev/null")
    deltas = {}
    try:
        data = json.loads(out) if out.strip() else {}
    except ValueError:
        return deltas
    for stat in data.get("stat", []):
        parts = stat.get("name", "").split(">>>")
        if len(parts) == 4 and parts[0] == "user":
            email = parts[1]
            deltas[email] = deltas.get(email, 0) + int(stat.get("value", 0))
    return deltas


def ssh_live_ips(ss_text=None):
    """{(kind, user): [ip,...]} from client-facing sshd/dropbear sockets."""
    if ss_text is None:
        ss_text = run("ss -tnp state established 2>/dev/null")
    live = {}
    for user, _, _, peer_ip, _, _ in _iter_daemon_sockets(ss_text):
        live.setdefault(("ssh", user), []).append(peer_ip)
    return live


def pids_to_kick(ss_text, target_user, keep_ips):
    """Return non-root sshd/dropbear PIDs owned by `target_user` whose
    client peer IP is not in `keep_ips`."""
    victim_pids = []
    for user, _, _, peer_ip, user_pids, _ in _iter_daemon_sockets(ss_text):
        if user != target_user or peer_ip in keep_ips:
            continue
        for pid in user_pids:
            if pid not in victim_pids:
                victim_pids.append(pid)
    return victim_pids


def ensure_iptables_rules(ssh):
    """One counting rule per SSH user in OUTPUT (owner match)."""
    existing = run("iptables -S OUTPUT 2>/dev/null")
    for user in ssh:
        try:
            uid = pwd.getpwnam(user).pw_uid
        except KeyError:
            continue
        if f"--uid-owner {uid}" not in existing:
            run(f"iptables -A OUTPUT -m owner --uid-owner {uid} -j RETURN")


def accumulate_usage(ss_text=None):
    if ss_text is None:
        ss_text = run("ss -tnpi state established 2>/dev/null")
    ssh = ragnar.load_ssh()
    ensure_iptables_rules(ssh)
    changed = False
    counters = run("iptables -nvxL OUTPUT 2>/dev/null")
    per_user = {}
    for line in counters.splitlines():
        m = re.match(r"\s*\d+\s+(\d+)\s+.*owner UID match (\d+)", line)
        if m:
            try:
                user = pwd.getpwuid(int(m.group(2))).pw_name
            except KeyError:
                continue
            per_user[user] = per_user.get(user, 0) + int(m.group(1))
    state_f = os.path.join(ragnar.BASE, "db", "ssh_counter_state.json")
    prev = ragnar._read_json(state_f, {})
    for user, total in per_user.items():
        if user in ssh:
            delta = counter_delta(prev.get(user, 0), total)
            if delta:
                ssh[user]["used_bytes"] = int(ssh[user].get("used_bytes", 0)) + delta
                changed = True
    if per_user:
        ragnar._write_json(state_f, per_user)

    sock_f = os.path.join(ragnar.BASE, "db", "ssh_socket_state.json")
    sock_prev = {k: tuple(v) for k, v in
                 ragnar._read_json(sock_f, {}).items()}
    sock_bytes, sock_state = socket_usage_deltas(ss_text, sock_prev)
    for user, delta in sock_bytes.items():
        if user in ssh:
            ssh[user]["used_bytes"] = int(ssh[user].get("used_bytes", 0)) + delta
            changed = True
    ragnar._write_json(sock_f, sock_state)
    if changed:
        ragnar.save_ssh(ssh)

    xr = ragnar.load_xray()
    deltas = xray_deltas()
    state_f = os.path.join(ragnar.BASE, "db", "xray_counter_state.json")
    prev = ragnar._read_json(state_f, {})
    changed = False
    for email, total in deltas.items():
        if email in xr:
            delta = counter_delta(prev.get(email, 0), total)
            if delta:
                xr[email]["used_bytes"] = int(xr[email].get("used_bytes", 0)) + delta
                changed = True
    if deltas:
        ragnar._write_json(state_f, deltas)
    if changed:
        ragnar.save_xray(xr)

    seen = ragnar._read_json(ragnar.XRAY_LAST_SEEN, {})
    now = time.time()
    for email, total in deltas.items():
        if email in xr and counter_delta(prev.get(email, 0), total) > 0:
            seen[email] = now
    seen = {e: ts for e, ts in seen.items()
            if now - float(ts) <= 3600}
    ragnar._write_json(ragnar.XRAY_LAST_SEEN, seen)
    return ssh, xr


def main():
    apply_mode = "--apply" in sys.argv
    ss_text = run("ss -tnpi state established 2>/dev/null")
    ssh, xr = accumulate_usage(ss_text)
    live = ssh_live_ips(ss_text)
    zivpn = ragnar.load_zivpn()
    plan = ragnar.enforcement_plan(ssh, xr, live, zivpn)
    ssh_dirty = False
    xray_dirty = False
    zivpn_dirty = False
    for item in plan:
        print(f"{item['kind']}/{item['user']}: {item['action']} ({item['reason']})")
        if not apply_mode:
            continue
        user = item["user"]
        if item["kind"] == "ssh" and item["action"] == "lock":
            subprocess.run(["usermod", "-L", user], capture_output=True)
            subprocess.run(["pkill", "-u", user], capture_output=True)
            ssh[user]["enabled"] = False
            ssh[user]["checker_lock"] = item["reason"]
            ssh_dirty = True
        elif item["kind"] == "ssh" and item["action"] == "kick-extra":
            ips = list(dict.fromkeys(live.get(("ssh", user), [])))
            keep = set(ips[: int(ssh[user].get("ip_limit", 0))])
            for pid in pids_to_kick(ss_text, user, keep):
                try:
                    os.kill(pid, signal.SIGTERM)
                except OSError:
                    pass
        elif item["kind"] == "xray" and item["action"] == "remove":
            xr[user]["enabled"] = False
            xr[user]["checker_lock"] = item["reason"]
            xray_dirty = True
        elif item["kind"] == "zivpn" and item["action"] == "remove":
            zivpn[user]["enabled"] = False
            zivpn[user]["checker_lock"] = item["reason"]
            zivpn_dirty = True
    if ssh_dirty:
        ragnar.save_ssh(ssh)
        ragnar.sync_udp_custom()
    if xray_dirty:
        ragnar.save_xray(xr)
    if zivpn_dirty:
        ragnar._write_json(ragnar.ZIVPN_DB, {"users": zivpn})
    if xray_dirty or zivpn_dirty:
        ragnar.apply_configs()
    if not plan:
        print("all users within limits")
    return 0


if __name__ == "__main__":
    sys.exit(main())
