#!/usr/bin/env bash
set -euo pipefail

BASE="${RAGNAR_DIR:-/etc/ragnar}"
if [ "$#" -gt 0 ]; then
    LINEAGE="$1"
else
    [ -s "$BASE/certs/letsencrypt-lineage" ] || exit 0
    IFS= read -r LINEAGE < "$BASE/certs/letsencrypt-lineage"
    [ "${RENEWED_LINEAGE:-}" = "$LINEAGE" ] || exit 0
fi

umask 077
STAGE=$(mktemp -d "$BASE/certs/.deploy.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
cp "$LINEAGE/fullchain.pem" "$STAGE/fullchain.pem"
cp "$LINEAGE/privkey.pem" "$STAGE/privkey.pem"
openssl x509 -in "$STAGE/fullchain.pem" -noout -checkend 0 >/dev/null
openssl x509 -in "$STAGE/fullchain.pem" -noout -checkhost "$(head -n1 "$BASE/domain")" | grep -Fq 'does match certificate'
openssl x509 -in "$STAGE/fullchain.pem" -pubkey -noout > "$STAGE/cert.pub"
openssl pkey -in "$STAGE/privkey.pem" -pubout > "$STAGE/key.pub"
cmp -s "$STAGE/cert.pub" "$STAGE/key.pub"
cat "$STAGE/fullchain.pem" "$STAGE/privkey.pem" > "$STAGE/haproxy.pem"
printf '%s\n' "$LINEAGE" > "$STAGE/letsencrypt-lineage"
for file in fullchain.pem privkey.pem haproxy.pem letsencrypt-lineage; do
    chmod 600 "$STAGE/$file"
    mv -f "$STAGE/$file" "$BASE/certs/$file"
done

if [ "$#" -eq 0 ]; then
    failed=0
    if systemctl is-active --quiet haproxy; then
        systemctl reload haproxy || failed=1
    fi
    for service in sing-box ragnar-web; do
        if systemctl is-active --quiet "$service"; then
            systemctl restart "$service" || failed=1
        fi
    done
    exit "$failed"
fi
