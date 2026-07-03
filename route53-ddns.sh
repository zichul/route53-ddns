#!/usr/bin/env bash
#
# route53-ddns.sh — standalone DDNS script using AWS CLI
# Works on any Linux with curl + aws-cli. No Python required.
#
# Configuration: /etc/ddns/ddns.conf or ~/.ddns.conf
#
#   AWS_ACCESS_KEY_ID=AKIA...
#   AWS_SECRET_ACCESS_KEY=abcd...
#   AWS_REGION=eu-central-1
#   HOSTED_ZONE_ID=Z123ABC...
#   DOMAIN=home.example.com
#   TTL=300
#   IP_CHECK_URL=https://api.ipify.org
#
set -euo pipefail

CONF_FILE="${DDNS_CONF:-/etc/ddns/ddns.conf}"
LOG_TAG="route53-ddns"

log() { logger -t "$LOG_TAG" "$1" 2>/dev/null || echo "[$(date '+%F %T')] $1"; }

if [ ! -f "$CONF_FILE" ]; then
    CONF_FILE="$HOME/.ddns.conf"
fi

if [ ! -f "$CONF_FILE" ]; then
    log "ERROR: config file not found ($CONF_FILE)"
    exit 1
fi

source "$CONF_FILE"

: "${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID required}"
: "${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY required}"
: "${AWS_REGION:=eu-central-1}"
: "${HOSTED_ZONE_ID:?HOSTED_ZONE_ID required}"
: "${DOMAIN:?DOMAIN required}"
: "${TTL:=300}"
: "${IP_CHECK_URL:=https://api.ipify.org}"

export AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY
export AWS_DEFAULT_REGION="$AWS_REGION"

CURRENT_IP=$(curl -s --max-time 10 "$IP_CHECK_URL")

if ! echo "$CURRENT_IP" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
    log "ERROR: failed to fetch public IP (got: '$CURRENT_IP')"
    exit 1
fi

DNS_IP=$(aws route53 list-resource-record-sets \
    --hosted-zone-id "$HOSTED_ZONE_ID" \
    --query "ResourceRecordSets[?Name=='${DOMAIN}.'].[ResourceRecords[0].Value]" \
    --output text 2>/dev/null || echo "none")

if [ "$DNS_IP" = "none" ] || [ -z "$DNS_IP" ]; then
    log "INFO: record does not exist — creating"
    DNS_IP=""
fi

if [ "$CURRENT_IP" = "$DNS_IP" ]; then
    [ "${VERBOSE:-0}" = "1" ] && log "OK: IP unchanged ($CURRENT_IP)"
    exit 0
fi

log "CHANGE: $DNS_IP -> $CURRENT_IP — updating Route 53 ..."

CHANGE_BATCH=$(cat <<EOF
{
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "${DOMAIN}.",
        "Type": "A",
        "TTL": ${TTL},
        "ResourceRecords": [{"Value": "${CURRENT_IP}"}]
      }
    }
  ]
}
EOF
)

CHANGE_ID=$(aws route53 change-resource-record-sets \
    --hosted-zone-id "$HOSTED_ZONE_ID" \
    --change-batch "$CHANGE_BATCH" \
    --query 'ChangeInfo.Id' \
    --output text)

timeout 30 aws route53 wait resource-record-sets-changed --id "$CHANGE_ID" 2>/dev/null || true

log "DONE: $DOMAIN -> $CURRENT_IP (TTL=${TTL}s, change=$CHANGE_ID)"
