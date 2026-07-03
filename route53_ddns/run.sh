#!/usr/bin/env sh
# run.sh — HA addon entrypoint
# Pętla: co N sekund sprawdza IP i aktualizuje Route 53
# Options wstrzykiwane przez Supervisor w /data/options.json
set -eu

# --- wczytaj options z Supervisor ---
OPT_FILE="/data/options.json"
if [ ! -f "$OPT_FILE" ]; then
    echo "BŁĄD: brak /data/options.json — addon nie skonfigurowany w Supervisor"
    exit 1
fi

AWS_ACCESS_KEY_ID=$(jq -r '.aws_access_key_id' "$OPT_FILE")
AWS_SECRET_ACCESS_KEY=$(jq -r '.aws_secret_access_key' "$OPT_FILE")
AWS_REGION=$(jq -r '.aws_region' "$OPT_FILE")
HOSTED_ZONE_ID=$(jq -r '.hosted_zone_id' "$OPT_FILE")
DOMAIN=$(jq -r '.domain' "$OPT_FILE")
TTL=$(jq -r '.ttl' "$OPT_FILE")
CHECK_INTERVAL=$(jq -r '.check_interval' "$OPT_FILE")
IP_CHECK_URL=$(jq -r '.ip_check_url' "$OPT_FILE")

export AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY
export AWS_DEFAULT_REGION="$AWS_REGION"

echo "[route53-ddns] Start: ${DOMAIN} zone=${HOSTED_ZONE_ID} interval=${CHECK_INTERVAL}s"

# --- pętla główna ---
while true; do
    # pobierz aktualny publiczny IP
    CURRENT_IP=$(curl -s --max-time 10 "$IP_CHECK_URL" 2>/dev/null || echo "")

    if ! echo "$CURRENT_IP" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        echo "[route53-ddns] $(date '+%F %T') BŁĄD: nie udało się pobrać IP ($IP_CHECK_URL)"
        sleep "$CHECK_INTERVAL"
        continue
    fi

    # pobierz obecny rekord z Route 53
    DNS_IP=$(aws route53 list-resource-record-sets \
        --hosted-zone-id "$HOSTED_ZONE_ID" \
        --query "ResourceRecordSets[?Name=='${DOMAIN}.'].[ResourceRecords[0].Value]" \
        --output text 2>/dev/null || echo "")

    if [ -z "$DNS_IP" ]; then
        echo "[route53-ddns] $(date '+%F %T') INFO: rekord nie istnieje — tworzę"
        DNS_IP=""
    fi

    if [ "$CURRENT_IP" = "$DNS_IP" ]; then
        # bez zmian — cicho
        :
    else
        echo "[route53-ddns] $(date '+%F %T') ZMIANA: ${DNS_IP:-none} → ${CURRENT_IP} — aktualizuję"

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
            --output text 2>/dev/null || echo "")

        if [ -n "$CHANGE_ID" ]; then
            echo "[route53-ddns] $(date '+%F %T') GOTOWE: ${DOMAIN} → ${CURRENT_IP} (change=${CHANGE_ID})"
        else
            echo "[route53-ddns] $(date '+%F %T') BŁĄD: change-resource-record-sets nieudane"
        fi
    fi

    sleep "$CHECK_INTERVAL"
done
