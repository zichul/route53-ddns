#!/usr/bin/env sh
# /config/ddns.sh — Route 53 DDNS updater for HA
# Wywoływany przez shell_command z HA automation co 5 min
# Używa curl + openssl (dostępne w kontenerze HA) — nie wymaga aws-cli
set -eu

# Parametry (z secrets.yaml przez shell_command)
AWS_ACCESS_KEY_ID="${1:?AWS_ACCESS_KEY_ID required}"
AWS_SECRET_ACCESS_KEY="${2:?AWS_SECRET_ACCESS_KEY required}"
AWS_REGION="${3:-eu-central-1}"
HOSTED_ZONE_ID="${4:?HOSTED_ZONE_ID required}"
DOMAIN="${5:?DOMAIN required}"
TTL="${6:-300}"
IP_CHECK_URL="${7:-https://api.ipify.org}"

# Pobierz aktualny publiczny IP
CURRENT_IP=$(curl -s --max-time 10 "$IP_CHECK_URL" 2>/dev/null || echo "")

if ! echo "$CURRENT_IP" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "BŁĄD: nie udało się pobrać IP ($IP_CHECK_URL)"
    exit 1
fi

# AWS SigV4 signing
host="route53.amazonaws.com"
service="route53"
amz_date=$(date -u +"%Y%m%dT%H%M%SZ")
date_scope=$(date -u +"%Y%m%d")

# GET current DNS record
canonical_uri="/2013-04-01/hostedzone/${HOSTED_ZONE_ID}/rrset/"
canonical_querystring="name=${DOMAIN}.&type=A"
payload_hash=$(printf '%s' "" | openssl dgst -sha256 -hex | sed 's/.*= //')

canonical_headers="content-type:application/x-amz-json-1.1
host:${host}
x-amz-content-sha256:${payload_hash}
x-amz-date:${amz_date}
"
signed_headers="content-type;host;x-amz-content-sha256;x-amz-date"

canonical_request="GET
${canonical_uri}
${canonical_querystring}
${canonical_headers}
${signed_headers}
${payload_hash}"

credential_scope="${date_scope}/${service}/aws4_request"
canonical_request_hash=$(printf '%s' "$canonical_request" | openssl dgst -sha256 -hex | sed 's/.*= //')
string_to_sign="AWS4-HMAC-SHA256
${amz_date}
${credential_scope}
${canonical_request_hash}"

k_secret="AWS4${AWS_SECRET_ACCESS_KEY}"
k_secret_hex=$(printf '%s' "$k_secret" | xxd -p | tr -d '\n')
k_date=$(printf '%s' "$date_scope" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:${k_secret_hex}" -hex | sed 's/.*= //')
k_region=$(printf '%s' "$service" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:${k_date}" -hex | sed 's/.*= //')
k_service=$(printf '%s' "$service" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:${k_region}" -hex | sed 's/.*= //')
k_signing=$(printf '%s' "aws4_request" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:${k_service}" -hex | sed 's/.*= //')
signature=$(printf '%s' "$string_to_sign" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:${k_signing}" -hex | sed 's/.*= //')

authorization="AWS4-HMAC-SHA256 Credential=${AWS_ACCESS_KEY_ID}/${credential_scope}, SignedHeaders=${signed_headers}, Signature=${signature}"

DNS_IP=$(curl -s -X GET \
    -H "Content-Type: application/x-amz-json-1.1" \
    -H "X-Amz-Content-Sha256: ${payload_hash}" \
    -H "X-Amz-Date: ${amz_date}" \
    -H "Authorization: ${authorization}" \
    "https://${host}${canonical_uri}?${canonical_querystring}" \
  | jq -r '.ResourceRecordSets[0].ResourceRecords[0].Value // empty' 2>/dev/null || echo "")

if [ "$CURRENT_IP" = "$DNS_IP" ]; then
    echo "OK: ${DOMAIN} -> ${CURRENT_IP} (bez zmian)"
    exit 0
fi

echo "ZMIANA: ${DNS_IP:-none} -> ${CURRENT_IP} — aktualizuję ${DOMAIN}"

# POST update (UPSERT)
request_body=$(cat <<EOF
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

# Re-sign for POST
payload_hash_post=$(printf '%s' "$request_body" | openssl dgst -sha256 -hex | sed 's/.*= //')
amz_date_post=$(date -u +"%Y%m%dT%H%M%SZ")

canonical_headers_post="content-type:application/x-amz-json-1.1
host:${host}
x-amz-content-sha256:${payload_hash_post}
x-amz-date:${amz_date_post}
"

canonical_request_post="POST
${canonical_uri}
${canonical_querystring}
${canonical_headers_post}
${signed_headers}
${payload_hash_post}"

canonical_request_hash_post=$(printf '%s' "$canonical_request_post" | openssl dgst -sha256 -hex | sed 's/.*= //')
string_to_sign_post="AWS4-HMAC-SHA256
${amz_date_post}
${credential_scope}
${canonical_request_hash_post}"

signature_post=$(printf '%s' "$string_to_sign_post" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:${k_signing}" -hex | sed 's/.*= //')
authorization_post="AWS4-HMAC-SHA256 Credential=${AWS_ACCESS_KEY_ID}/${credential_scope}, SignedHeaders=${signed_headers}, Signature=${signature_post}"

RESPONSE=$(curl -s -X POST \
    -H "Content-Type: application/x-amz-json-1.1" \
    -H "X-Amz-Content-Sha256: ${payload_hash_post}" \
    -H "X-Amz-Date: ${amz_date_post}" \
    -H "Authorization: ${authorization_post}" \
    -d "$request_body" \
    "https://${host}${canonical_uri}?${canonical_querystring}")

CHANGE_ID=$(echo "$RESPONSE" | jq -r '.ChangeInfo.Id // empty' 2>/dev/null)

if [ -n "$CHANGE_ID" ]; then
    echo "GOTOWE: ${DOMAIN} -> ${CURRENT_IP} (change=${CHANGE_ID})"
else
    echo "BŁĄD: $(echo "$RESPONSE" | jq -r '.Error.Message // "unknown"' 2>/dev/null)"
    exit 1
fi
