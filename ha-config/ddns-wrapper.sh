#!/bin/sh
# ddns-wrapper.sh — wrapper for HA shell_command approach
# Installs boto3 if missing, sets env vars, runs ddns.py

# Install boto3 if not present
python3 -c "import boto3" 2>/dev/null || pip3 install boto3 -q 2>/dev/null

# --- Set your credentials here ---
export AWS_ACCESS_KEY_ID="YOUR_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="YOUR_SECRET_ACCESS_KEY"
export AWS_REGION="eu-central-1"
export HOSTED_ZONE_ID="YOUR_HOSTED_ZONE_ID"
export DOMAIN="home.example.com"
export TTL="300"
export IP_CHECK_URL="https://api.ipify.org"

python3 /config/ddns.py 2>&1
