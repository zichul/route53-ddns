#!/usr/bin/env python3
"""Route 53 DDNS updater using AWS SDK (boto3).
Reads config from environment variables passed by shell_command or addon options.
"""
import os
import sys
import urllib.request

import boto3

DOMAIN = os.environ.get("DOMAIN", "home.example.com")
HOSTED_ZONE_ID = os.environ.get("HOSTED_ZONE_ID", "")
TTL = int(os.environ.get("TTL", "300"))
IP_CHECK_URL = os.environ.get("IP_CHECK_URL", "https://api.ipify.org")

if not HOSTED_ZONE_ID:
    print("ERROR: HOSTED_ZONE_ID not set")
    sys.exit(1)

r53 = boto3.client(
    "route53",
    region_name=os.environ.get("AWS_REGION", "eu-central-1"),
    aws_access_key_id=os.environ.get("AWS_ACCESS_KEY_ID", ""),
    aws_secret_access_key=os.environ.get("AWS_SECRET_ACCESS_KEY", ""),
)


def get_public_ip():
    """Fetch current public IP."""
    try:
        with urllib.request.urlopen(IP_CHECK_URL, timeout=10) as resp:
            ip = resp.read().decode().strip()
        parts = ip.split(".")
        if len(parts) != 4 or not all(p.isdigit() and 0 <= int(p) <= 255 for p in parts):
            return None
        return ip
    except Exception as e:
        print(f"ERROR: failed to fetch public IP: {e}", flush=True)
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
        print(f"ERROR: failed to read DNS record: {e}", flush=True)
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
        print(f"DONE: {DOMAIN} -> {new_ip} (change={change_id})", flush=True)
        return True
    except Exception as e:
        print(f"ERROR: failed to update DNS: {e}", flush=True)
        return False


def main():
    """One-shot mode: check and update once, then exit."""
    current_ip = get_public_ip()
    if not current_ip:
        sys.exit(1)

    dns_ip = get_dns_ip()

    if current_ip == dns_ip:
        print(f"OK: {DOMAIN} -> {current_ip} (no change)", flush=True)
    else:
        print(f"CHANGE: {dns_ip or 'none'} -> {current_ip}", flush=True)
        update_dns(current_ip)


if __name__ == "__main__":
    main()
