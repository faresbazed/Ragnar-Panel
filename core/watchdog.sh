#!/bin/bash
# Ragnar watchdog - run every minute by ragnar-watchdog.timer.
# Revives any dead panel service so a crashed backend never takes a
# shared port down with it (HAProxy also health-checks and skips dead
# backends in the meantime).
SERVICES="haproxy xray sing-box ragnar-wsproxy ragnar-landing dropbear zivpn udp-custom badvpn-udpgw slowdns ragnar-web"
for svc in $SERVICES; do
    if ! systemctl is-active --quiet "$svc" 2>/dev/null \
       && systemctl is-enabled --quiet "$svc" 2>/dev/null; then
        if systemctl restart "$svc"; then
            logger -t ragnar-watchdog "restarted $svc"
        else
            logger -t ragnar-watchdog "FAILED to restart $svc"
        fi
    fi
done
# HAProxy must own 80/443 - if something else grabbed them, bounce HAProxy.
if ! ss -tlnp 2>/dev/null | grep -qE ':(80|443)\s.*haproxy'; then
    if systemctl is-enabled --quiet haproxy 2>/dev/null; then
        systemctl restart haproxy 2>/dev/null || true
    fi
fi
exit 0
