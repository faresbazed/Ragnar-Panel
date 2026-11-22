#!/usr/bin/env python3
"""Installer-only operations on persistent panel data."""
import json
import os
from pathlib import Path
import sys

import ragnar


BASE = Path(ragnar.BASE)
SETTINGS = BASE / "settings.json"
SLOWDNS = (("ns", "nameserver"), ("slowdns_mtu", "mtu"),
           ("slowdns_resolver", "dns_resolver"), ("slowdns_target", "target_port"))


def read_object(path):
    if not os.path.lexists(path):
        return {}
    if not path.is_file():
        raise ValueError(f"not a regular file: {path}")
    try:
        value = json.loads(path.read_text())
    except ValueError as exc:
        raise ValueError(f"invalid JSON in {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise ValueError(f"expected an object in {path}")
    return value


def check_pair(directory, first, second):
    paths = [directory / name for name in (first, second)]
    if any(os.path.lexists(p) for p in paths):
        if not all(p.is_file() and p.stat().st_size for p in paths):
            raise ValueError(f"incomplete key pair in {directory}: restore {first} and {second}")
        return True
    return False


def validate(legacy):
    settings = read_object(SETTINGS)
    for key in ("domain", "ns"):
        if settings.get(key) is not None and not isinstance(settings[key], str):
            raise ValueError(f"expected a string for {key} in {SETTINGS}")
    for name in ("ssh", "xray", "zivpn"):
        path = BASE / "db" / (name + ".json")
        if os.path.lexists(path) and not isinstance(read_object(path).get("users"), dict):
            raise ValueError(f"expected a users object in {path}")
    web = BASE / "web.json"
    if os.path.lexists(web):
        cfg = read_object(web)
        if not cfg.get("hash") or not cfg.get("salt"):
            raise ValueError(f"incomplete credentials in {web}; refusing to reset the login")
    check_pair(BASE / "certs", "privkey.pem", "fullchain.pem")
    check_pair(BASE / "certs", "zivpn.key", "zivpn.crt")
    local = BASE / "slowdns"
    have_local = check_pair(local, "server.key", "server.pub")
    have_legacy = check_pair(legacy, "server.key", "server.pub")
    if have_local and have_legacy:
        if any((local / f).read_bytes().strip() != (legacy / f).read_bytes().strip()
               for f in ("server.key", "server.pub")):
            raise ValueError("conflicting SlowDNS key pairs; reconcile them before upgrading")
    saved = settings.get("slowdns_pubkey")
    if saved:
        if not (have_local or have_legacy):
            raise ValueError("saved SlowDNS identity has no key pair; restore it before upgrading")
        if ((local if have_local else legacy) / "server.pub").read_text().strip() != saved:
            raise ValueError("saved SlowDNS public key does not match the installed identity")


def save_settings(command, args):
    with ragnar.account_lock():
        old = read_object(SETTINGS)
        new = dict(old)
        if command == "configure":
            domain, ns, legacy = args
            if domain:
                new["domain"] = domain
            if ns:
                new["ns"] = ns
            for key, filename in SLOWDNS:
                path = Path(legacy) / filename
                if not new.get(key) and path.is_file():
                    value = path.read_text().strip()
                    if value:
                        new[key] = int(value) if key in ("slowdns_mtu", "slowdns_target") else value
        elif command == "slowdns-settings":
            for (key, _), value in zip(SLOWDNS, args):
                if value:
                    new[key] = int(value) if key in ("slowdns_mtu", "slowdns_target") else value
        elif command == "slowdns-key":
            new["slowdns_pubkey"] = Path(args[0]).read_text().strip()
            new.pop("slowdns_kcp", None)
        else:
            raise ValueError(f"unknown operation: {command}")
        if old != new or not SETTINGS.exists():
            ragnar._atomic_json(str(SETTINGS), json.dumps(new, indent=2), mode=0o600)


if __name__ == "__main__":
    try:
        if sys.argv[1] == "validate":
            validate(Path(sys.argv[2]))
        else:
            save_settings(sys.argv[1], sys.argv[2:])
    except (OSError, ValueError) as exc:
        sys.exit(f"Panel state error: {exc}")
