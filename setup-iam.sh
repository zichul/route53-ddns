#!/usr/bin/env bash
#
# setup-iam.sh — tworzy dedykowanego użytkownika IAM dla DDNS Route 53
# Uruchom raz na maszynie z dostępem do AWS CLI i root credentialami.
#
# Wynik: użytkownik IAM "route53-ddns" z polityką least-privilege,
#         klucze AWS access key/secret key wypisane na ekran.
#
# UŻYWA: bieżących credentiałów AWS (root lub admin).  Nie zapisuje ich nigdzie.
#
set -euo pipefail

DOMAIN="zichul.de"
SUBDOMAIN="home.zichul.de"
IAM_USER="route53-ddns"
POLICY_NAME="route53-ddns-policy"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo ">>> Szukam hosted zone dla $DOMAIN ..."
ZONE_ID=$(aws route53 list-hosted-zones \
  --query "HostedZones[?Name=='${DOMAIN}.'].Id" \
  --output text | sed 's|/hostedzone/||')

if [ -z "$ZONE_ID" ]; then
  echo "BŁĄD: nie znaleziono hosted zone dla $DOMAIN"
  echo "Sprawdź czy domena jest w Route 53: aws route53 list-hosted-zones"
  exit 1
fi

echo "    Zone ID = $ZONE_ID"

echo ">>> Tworzę politykę IAM (least-privilege, tylko $SUBDOMAIN) ..."
# Podstaw zone ID do polityki
sed "s|ZICHUL_ZONE_ID|$ZONE_ID|g" "$SCRIPT_DIR/iam-policy.json" > /tmp/ddns-policy.json
aws iam create-policy \
  --policy-name "$POLICY_NAME" \
  --policy-document file:///tmp/ddns-policy.json \
  --description "DDNS update for ${SUBDOMAIN} only" \
  2>/dev/null || {
    echo "    Polityka prawdopodobnie już istnieje — pobieram ARN ..."
  }
POLICY_ARN=$(aws iam list-policies \
  --query "Policies[?PolicyName=='${POLICY_NAME}'].Arn" \
  --output text)

echo ">>> Tworzę użytkownika IAM '$IAM_USER' ..."
aws iam create-user --user-name "$IAM_USER" 2>/dev/null || {
  echo "    Użytkownik już istnieje — kontynuuję ..."
}

echo ">>> Przypięcie polityki do użytkownika ..."
aws iam attach-user-policy \
  --user-name "$IAM_USER" \
  --policy-arn "$POLICY_ARN"

echo ">>> Tworzenie access key ..."
ACCESS_JSON=$(aws iam create-access-key --user-name "$IAM_USER" \
  --query 'AccessKey.[AccessKeyId,SecretAccessKey]' \
  --output text)

ACCESS_KEY_ID=$(echo "$ACCESS_JSON" | awk '{print $1}')
SECRET_KEY=$(echo "$ACCESS_JSON" | awk '{print $2}')

echo ""
echo "========================================"
echo "  GOTOWE — klucze dla skryptu DDNS:"
echo "========================================"
echo "AWS_ACCESS_KEY_ID = $ACCESS_KEY_ID"
echo "AWS_SECRET_KEY     = $SECRET_KEY"
echo "HOSTED_ZONE_ID     = $ZONE_ID"
echo "========================================"
echo ""
echo "Skopiuj te wartości do /etc/ddns/ddns.conf na urządzeniu HA."
echo "NIE zapisuj ich nigdzie publicznie."
echo "Klucz root AWS nie był nigdzie zapisany — użyty tylko do tego wywołania."
rm -f /tmp/ddns-policy.json
