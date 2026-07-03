#!/usr/bin/env python3
"""Route 53 DDNS updater using AWS SDK (boto3)."""
import os
import sys
import time
import urllib.request
import json

import boto3

DOMAIN = os.environ["DOMAIN"]
HOSTED_ZONE_ID = os.environ["HOSTED_ZONE_ID"]
TTL = int(os.environ.get("TTL", "300"))
CHECK_INTERVAL = int(os.environ.get("CHECK_INTERVAL", "300"))
IP_CHECK_URL = os.environ.get("IP_CHECK_URL", "https://api.ipify.org")

r53 = boto3.client("route53", region_name=os.environ.get("AWS_REGION", "eu-central-1"))


def get_public_ip():
    """Fetch current public IP."""
    try:
        with urllib.request.urlopen(IP_CHECK_URL, timeout=10) as resp:
            ip = resp.read().decode().strip()
        # Validate IPv4
        parts = ip.split(".")
        if len(parts) != 4 or not all(p.isdigit() and 0 <= int(p) <= 255 for p in parts):
            return None
        return ip
    except Exception as e:
        print(f"BŁĄD: nie udało się pobrać IP: {e}", flush=True)
        return None


def get_dns_ip():
    """Get current A record from Route 53."""
    try:
        resp = r53.list_resource_record_sets(
            HostedZoneId=HOSTED_ZONE_ID,
            StartRecordName=f"{DOMAIN}.",
            StartRecordType="A",
            MaxItems="1",
        )
        for record in resp.get("ResourceRecordSets", []):
            if record["Name"] == f"{DOMAIN}." and record["Type"] == "A":
                values = record.get("ResourceRecords", [])
                if values:
                    return values[0]["Value"]
        return None
    except Exception as e:
        print(f"BŁĄD: nie udało się odczytać rekordu DNS: {e}", flush=True)
        return None


def update_dns(new_ip):
    """Upsert A record in Route 53."""
    try:
        resp = r53.change_resource_record_sets(
            HostedZoneId=HOSTED_ZONE_ID,
            ChangeBatch={
                "Changes": [
                    {
                        "Action": "UPSERT",
                        "ResourceRecordSet": {
                            "Name": f"{DOMAIN}.",
                            "Type": "A",
                            "TTL": TTL,
                            "ResourceRecords": [{"Value": new_ip}],
                        },
                    }
                ]
            },
        )
        change_id = resp["ChangeInfo"]["Id"]
        print(f"GOTOWE: {DOMAIN} -> {new_ip} (change={change_id})", flush=True)
        return True
    except Exception as e:
        print(f"BŁĄD: nie udało się zaktualizować DNS: {e}", flush=True)
        return False


def main():
    print(f"[route53-ddns] Start: {DOMAIN} zone={HOSTED_ZONE_ID} interval={CHECK_INTERVAL}s", flush=True)

    while True:
        current_ip = get_public_ip()
        if not current_ip:
            time.sleep(CHECK_INTERVAL)
            continue

        dns_ip = get_dns_ip()

        if current_ip == dns_ip:
            # No change — silent
            pass
        else:
            print(f"ZMIANA: {dns_ip or 'none'} -> {current_ip} — aktualizuję {DOMAIN}", flush=True)
            update_dns(current_ip)

        time.sleep(CHECK_INTERVAL)


if __name__ == "__main__":
    main()
