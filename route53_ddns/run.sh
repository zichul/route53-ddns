#!/usr/bin/env sh
# run.sh — HA addon entrypoint
# Pętla: co N sekund sprawdza IP i aktualizuje Route 53
# Options wstrzykiwane przez Supervisor w /data/options.json
# Używa curl z AWS SigV4 zamiast aws-cli (lżejszy obraz)
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

echo "[route53-ddns] Start: ${DOMAIN} zone=${HOSTED_ZONE_ID} interval=${CHECK_INTERVAL}s"

# --- AWS SigV4 signing (POSIX sh, no external deps) ---
# Based on AWS docs: https://docs.aws.amazon.com/general/latest/gr/sigv4-signed-request-examples.html
sign_and_call_route53() {
    method="$1"
    request_body="$2"
    content_type="application/x-amz-json-1.1"

    # Timestamps
    now=$(date -u +"%Y%m%dT%H%M%SZ")
    date_short=$(date -u +"%Y%m%d")

    # Canonical request
    host="route53.amazonaws.com"
    amz_date="$now"
    date_scope="$date_short"

    payload_hash=$(printf '%s' "$request_body" | openssl dgst -sha256 -hex | sed 's/.*= //')

    canonical_uri="/2013-04-01/hostedzone/${HOSTED_ZONE_ID}/rrset/"
    canonical_querystring=""

    canonical_headers="content-type:${content_type}
host:${host}
x-amz-content-sha256:${payload_hash}
x-amz-date:${amz_date}
"
    signed_headers="content-type;host;x-amz-content-sha256;x-amz-date"

    canonical_request="${method}
${canonical_uri}
${canonical_querystring}
${canonical_headers}
${signed_headers}
${payload_hash}"

    # String to sign
    credential_scope="${date_scope}/route53/aws4_request"
    canonical_request_hash=$(printf '%s' "$canonical_request" | openssl dgst -sha256 -hex | sed 's/.*= //')
    string_to_sign="AWS4-HMAC-SHA256
${amz_date}
${credential_scope}
${canonical_request_hash}"

    # Signing key
    k_secret="AWS4${AWS_SECRET_ACCESS_KEY}"
    k_date=$(printf '%s' "$date_short" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$(printf '%s' "$k_secret" | xxd -p | tr -d '\n')" -hex | sed 's/.*= //')
    k_region=$(printf '%s' "route53" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:${k_date}" -hex | sed 's/.*= //')
    k_service=$(printf '%s' "route53" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:${k_region}" -hex | sed 's/.*= //')
    k_signing=$(printf '%s' "aws4_request" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:${k_service}" -hex | sed 's/.*= //')

    signature=$(printf '%s' "$string_to_sign" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:${k_signing}" -hex | sed 's/.*= //')

    authorization_header="AWS4-HMAC-SHA256 Credential=${AWS_ACCESS_KEY_ID}/${credential_scope}, SignedHeaders=${signed_headers}, Signature=${signature}"

    # Execute request
    curl -s -X "$method" \
        -H "Content-Type: ${content_type}" \
        -H "X-Amz-Content-Sha256: ${payload_hash}" \
        -H "X-Amz-Date: ${amz_date}" \
        -H "Authorization: ${authorization_header}" \
        -d "$request_body" \
        "https://${host}${canonical_uri}"
}

get_current_dns_ip() {
    method="GET"
    request_body=""
    content_type="application/x-amz-json-1.1"

    now=$(date -u +"%Y%m%dT%H%M%SZ")
    date_short=$(date -u +"%Y%m%d")

    host="route53.amazonaws.com"
    amz_date="$now"
    date_scope="$date_short"

    payload_hash=$(printf '%s' "" | openssl dgst -sha256 -hex | sed 's/.*= //')

    canonical_uri="/2013-04-01/hostedzone/${HOSTED_ZONE_ID}/rrset/"
    canonical_querystring="name=${DOMAIN}.&type=A"

    canonical_headers="content-type:${content_type}
host:${host}
x-amz-content-sha256:${payload_hash}
x-amz-date:${amz_date}
"
    signed_headers="content-type;host;x-amz-content-sha256;x-amz-date"

    canonical_request="${method}
${canonical_uri}
${canonical_querystring}
${canonical_headers}
${signed_headers}
${payload_hash}"

    credential_scope="${date_scope}/route53/aws4_request"
    canonical_request_hash=$(printf '%s' "$canonical_request" | openssl dgst -sha256 -hex | sed 's/.*= //')
    string_to_sign="AWS4-HMAC-SHA256
${amz_date}
${credential_scope}
${canonical_request_hash}"

    k_secret="AWS4${AWS_SECRET_ACCESS_KEY}"
    k_date=$(printf '%s' "$date_short" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$(printf '%s' "$k_secret" | xxd -p | tr -d '\n')" -hex | sed 's/.*= //')
    k_region=$(printf '%s' "route53" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:${k_date}" -hex | sed 's/.*= //')
    k_service=$(printf '%s' "route53" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:${k_region}" -hex | sed 's/.*= //')
    k_signing=$(printf '%s' "aws4_request" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:${k_service}" -hex | sed 's/.*= //')

    signature=$(printf '%s' "$string_to_sign" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:${k_signing}" -hex | sed 's/.*= //')

    authorization_header="AWS4-HMAC-SHA256 Credential=${AWS_ACCESS_KEY_ID}/${credential_scope}, SignedHeaders=${signed_headers}, Signature=${signature}"

    curl -s -X GET \
        -H "Content-Type: ${content_type}" \
        -H "X-Amz-Content-Sha256: ${payload_hash}" \
        -H "X-Amz-Date: ${amz_date}" \
        -H "Authorization: ${authorization_header}" \
        "https://${host}${canonical_uri}?${canonical_querystring}" \
    | jq -r '.ResourceRecordSets[0].ResourceRecords[0].Value // empty' 2>/dev/null
}

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
    DNS_IP=$(get_current_dns_ip)

    if [ "$CURRENT_IP" = "$DNS_IP" ]; then
        : # bez zmian — cicho
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
        RESPONSE=$(sign_and_call_route53 "POST" "$CHANGE_BATCH")
        CHANGE_ID=$(echo "$RESPONSE" | jq -r '.ChangeInfo.Id // empty' 2>/dev/null)

        if [ -n "$CHANGE_ID" ]; then
            echo "[route53-ddns] $(date '+%F %T') GOTOWE: ${DOMAIN} → ${CURRENT_IP} (change=${CHANGE_ID})"
        else
            echo "[route53-ddns] $(date '+%F %T') BŁĄD: $(echo "$RESPONSE" | jq -r '.Error.Message // "unknown"' 2>/dev/null)"
        fi
    fi

    sleep "$CHECK_INTERVAL"
done
