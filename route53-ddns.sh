#!/usr/bin/env bash
#
# route53-ddns.sh — sprawdza publiczny IP i aktualizuje A record w Route 53
# Działa wszędzie gdzie jest curl + aws-cli. Zero innych zależności.
#
# Konfiguracja: /etc/ddns/ddns.conf (lub ~/.ddns.conf)
#
#   AWS_ACCESS_KEY_ID=AKIA...
#   AWS_SECRET_ACCESS_KEY=abcd...
#   AWS_REGION=eu-central-1
#   HOSTED_ZONE_ID=Z123ABC...
#   DOMAIN=home.zichul.de
#   TTL=300
#   IP_CHECK_URL=https://api.ipify.org
#
set -euo pipefail

CONF_FILE="${DDNS_CONF:-/etc/ddns/ddns.conf}"
LOG_TAG="route53-ddns"

log() { logger -t "$LOG_TAG" "$1" 2>/dev/null || echo "[$(date '+%F %T')] $1"; }

# --- wczytaj konfigurację ---
if [ ! -f "$CONF_FILE" ]; then
    # fallback do katalogu domowego (tryb testowy)
    CONF_FILE="$HOME/.ddns.conf"
fi

if [ ! -f "$CONF_FILE" ]; then
    log "BŁĄD: brak pliku konfiguracyjnego ($CONF_FILE)"
    exit 1
fi

# shellcheck source=/dev/null
source "$CONF_FILE"

# --- walidacja zmiennych ---
: "${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID wymagane w $CONF_FILE}"
: "${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY wymagane w $CONF_FILE}"
: "${AWS_REGION:=eu-central-1}"
: "${HOSTED_ZONE_ID:?HOSTED_ZONE_ID wymagane w $CONF_FILE}"
: "${DOMAIN:?DOMAIN wymagane w $CONF_FILE}"
: "${TTL:=300}"
: "${IP_CHECK_URL:=https://api.ipify.org}"

export AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY
export AWS_DEFAULT_REGION="$AWS_REGION"

# --- pobierz aktualny publiczny IP ---
CURRENT_IP=$(curl -s --max-time 10 "$IP_CHECK_URL")

if ! echo "$CURRENT_IP" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
    log "BŁĄD: nie udało się pobrać publicznego IP (otrzymano: '$CURRENT_IP')"
    exit 1
fi

# --- pobierz obecny rekord z Route 53 ---
DNS_IP=$(aws route53 list-resource-record-sets \
    --hosted-zone-id "$HOSTED_ZONE_ID" \
    --query "ResourceRecordSets[?Name=='${DOMAIN}.'].[ResourceRecords[0].Value]" \
    --output text 2>/dev/null || echo "none")

if [ "$DNS_IP" = "none" ] || [ -z "$DNS_IP" ]; then
    log "INFO: rekord nie istnieje lub pusty — tworzę nowy"
    DNS_IP=""
fi

# --- porównaj i aktualizuj jeśli trzeba ---
if [ "$CURRENT_IP" = "$DNS_IP" ]; then
    # bez zmian — cicho (log tylko przy VERBOSE)
    [ "${VERBOSE:-0}" = "1" ] && log "OK: IP niezmieniony ($CURRENT_IP)"
    exit 0
fi

log "ZMIANA: $DNS_IP → $CURRENT_IP — aktualizuję Route 53 ..."

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

log "Wysłano change $CHANGE_ID — czekam na PINSUFFICIENT_DATA propagation ..."

# Poczekaj na insync (opcjonalne — max ~30s)
timeout 30 aws route53 wait resource-record-sets-changed --id "$CHANGE_ID" 2>/dev/null || true

log "GOTOWE: $DOMAIN → $CURRENT_IP (TTL=${TTL}s, change=$CHANGE_ID)"
