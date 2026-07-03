#!/usr/bin/env bash
#
# setup-iam.sh — creates a dedicated IAM user for Route 53 DDNS updates
# Run once on a machine with AWS CLI and root/admin credentials.
#
# Output: IAM user "route53-ddns" with least-privilege policy,
#         AWS access key/secret key printed to stdout.
#
# Uses current AWS credentials (root or admin). Does not store them.
#
set -euo pipefail

# --- Configuration: set these to your domain ---
DOMAIN="example.com"
SUBDOMAIN="home.example.com"
IAM_USER="route53-ddns"
POLICY_NAME="route53-ddns-policy"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo ">>> Looking up hosted zone for $DOMAIN ..."
ZONE_ID=$(aws route53 list-hosted-zones \
  --query "HostedZones[?Name=='${DOMAIN}.'].Id" \
  --output text | sed 's|/hostedzone/||')

if [ -z "$ZONE_ID" ]; then
  echo "ERROR: hosted zone not found for $DOMAIN"
  echo "Check: aws route53 list-hosted-zones"
  exit 1
fi

echo "    Zone ID = $ZONE_ID"

echo ">>> Creating IAM policy (least-privilege, only $SUBDOMAIN) ..."
sed "s|YOUR_ZONE_ID|$ZONE_ID|g" "$SCRIPT_DIR/iam-policy.json" > /tmp/ddns-policy.json
aws iam create-policy \
  --policy-name "$POLICY_NAME" \
  --policy-document file:///tmp/ddns-policy.json \
  --description "DDNS update for ${SUBDOMAIN} only" \
  2>/dev/null || {
    echo "    Policy already exists — fetching ARN ..."
  }
POLICY_ARN=$(aws iam list-policies \
  --query "Policies[?PolicyName=='${POLICY_NAME}'].Arn" \
  --output text)

echo ">>> Creating IAM user '$IAM_USER' ..."
aws iam create-user --user-name "$IAM_USER" 2>/dev/null || {
  echo "    User already exists — continuing ..."
}

echo ">>> Attaching policy to user ..."
aws iam attach-user-policy \
  --user-name "$IAM_USER" \
  --policy-arn "$POLICY_ARN"

echo ">>> Creating access key ..."
ACCESS_JSON=$(aws iam create-access-key --user-name "$IAM_USER" \
  --query 'AccessKey.[AccessKeyId,SecretAccessKey]' \
  --output text)

ACCESS_KEY_ID=$(echo "$ACCESS_JSON" | awk '{print $1}')
SECRET_KEY=$(echo "$ACCESS_JSON" | awk '{print $2}')

echo ""
echo "========================================"
echo "  DONE — credentials for DDNS script:"
echo "========================================"
echo "AWS_ACCESS_KEY_ID  = $ACCESS_KEY_ID"
echo "AWS_SECRET_KEY     = $SECRET_KEY"
echo "HOSTED_ZONE_ID     = $ZONE_ID"
echo "========================================"
echo ""
echo "Copy these to your DDNS configuration."
echo "Do NOT store or commit these credentials."
echo "Root AWS credentials were not stored."
rm -f /tmp/ddns-policy.json
