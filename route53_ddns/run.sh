#!/usr/bin/env sh
# run.sh — HA addon entrypoint using AWS SDK (boto3)
set -eu

OPT_FILE="/data/options.json"
if [ ! -f "$OPT_FILE" ]; then
    echo "BŁĄD: brak /data/options.json"
    exit 1
fi

# Extract options and pass to Python script via env
export AWS_ACCESS_KEY_ID=$(jq -r '.aws_access_key_id' "$OPT_FILE")
export AWS_SECRET_ACCESS_KEY=$(jq -r '.aws_secret_access_key' "$OPT_FILE")
export AWS_REGION=$(jq -r '.aws_region' "$OPT_FILE")
export HOSTED_ZONE_ID=$(jq -r '.hosted_zone_id' "$OPT_FILE")
export DOMAIN=$(jq -r '.domain' "$OPT_FILE")
export TTL=$(jq -r '.ttl' "$OPT_FILE")
export CHECK_INTERVAL=$(jq -r '.check_interval' "$OPT_FILE")
export IP_CHECK_URL=$(jq -r '.ip_check_url' "$OPT_FILE")

exec python3 /ddns.py
