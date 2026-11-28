#!/usr/bin/env bash
# Slipstream (QUIC-over-DNS) setup for the Ragnar panel.
# Uses dnstm (https://github.com/net2share/dnstm) in multi-tunnel mode:
# its DNS router owns UDP/TCP 53 and routes queries by subdomain.
# Cannot run together with the SlowDNS module (both need port 53).
set -uo pipefail

ACTION="${1:-setup}"
DOMAIN="${2:-}"

log() { echo "[slipstream] $*"; }

install_dnstm() {
    if ! command -v dnstm >/dev/null 2>&1; then
        log "installing dnstm..."
        curl -fsSL https://raw.githubusercontent.com/net2share/dnstm/main/install.sh -o /tmp/dnstm-install.sh
        bash /tmp/dnstm-install.sh --force
    fi
}

check_port53_conflict() {
    if systemctl is-active --quiet slowdns 2>/dev/null; then
        log "ERROR: the SlowDNS service is active and owns port 53."
        log "Stop it first (SlowDNS menu, option 9), then re-run."
        return 1
    fi
    return 0
}

slip_domain() {
    dnstm tunnel list 2>/dev/null | awk '$1=="slip1"{print $5}'
}

show_cert() {
    local CERT=/etc/dnstm/tunnels/slip1/cert.pem
    if [ -f "$CERT" ]; then
        openssl x509 -in "$CERT" -outform DER 2>/dev/null | base64 -w0
        echo
    else
        echo "no certificate yet - run setup first"
    fi
}

case "$ACTION" in
    setup)
        install_dnstm || { log "dnstm install failed"; exit 1; }
        check_port53_conflict || exit 1
        dnstm router mode multi >/dev/null 2>&1 || dnstm install --mode multi
        if [ -z "$DOMAIN" ]; then
            DOMAIN="$(slip_domain)"
        fi
        if [ -z "$DOMAIN" ]; then
            log "no domain given and none configured yet"
            exit 1
        fi
        cur="$(slip_domain)"
        if [ -n "$cur" ] && [ "$cur" != "$DOMAIN" ]; then
            log "domain change: $cur -> $DOMAIN (recreating slip1)"
            yes 2>/dev/null | dnstm tunnel remove -t slip1 || true
        fi
        if [ -z "$(slip_domain)" ]; then
            dnstm tunnel add -t slip1 --transport slipstream --backend socks --domain "$DOMAIN"
        fi
        dnstm router start >/dev/null 2>&1 || true
        dnstm tunnel start -t slip1 >/dev/null 2>&1 || true
        log "slip1 running on domain: $(slip_domain)"
        log "DNS records needed (DNS only, no proxy):"
        ip=$(curl -fsS -m 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')
        base="${DOMAIN#*.}"
        echo "    A   ns   -> $ip"
        echo "    NS  ${DOMAIN%%.*}   -> ns.$base"
        log "client certificate (base64):"
        show_cert
        ;;
    diagnose)
        echo "1. dnstm router on port 53:"
        if ss -ulnp 2>/dev/null | grep -q ":53 "; then
            echo "   OK - listening"
        else
            echo "   NOT listening - starting"
            dnstm router start 2>/dev/null || true
        fi
        echo "2. slip1 tunnel:"
        dnstm tunnel status -t slip1 2>/dev/null || echo "   not installed - run setup"
        echo "3. NS delegation for $(slip_domain || echo '<unset>') (via Google DNS):"
        d="$(slip_domain)"
        if [ -n "$d" ]; then
            curl -fsSL "https://dns.google/resolve?name=${d}&type=NS" 2>/dev/null | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    ans=[a['data'] for a in d.get('Answer',[]) if a.get('type')==2]
    print('   NS ->', ans[0] if ans else 'NOT FOUND - create the NS record in Cloudflare (DNS only)')
except Exception:
    print('   could not check (no network?)')
" || echo "   could not check"
        fi
        ;;
    config)
        echo "Domain : $(slip_domain || echo '<unset>')"
        echo "Cert   : $(show_cert)"
        echo "Share link:"
        dnstm tunnel share -t slip1 2>/dev/null || echo "   not installed - run setup"
        ;;
    *)
        echo "usage: $0 [setup <domain>|diagnose|config]" >&2
        exit 1
        ;;
esac
