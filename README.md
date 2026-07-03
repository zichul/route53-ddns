# Route 53 DDNS for Home Assistant

Dynamic DNS updater that synchronizes an AWS Route 53 A record with your current public IP.
Designed for Home Assistant OS (HAOS) but works on any system with Python 3 + boto3.

## How it works

1. Checks current public IP via `api.ipify.org`
2. Queries Route 53 for the existing A record
3. If different, updates the record via AWS SDK (boto3)
4. Runs automatically every 5 minutes via HA automation

## Files

| File | Purpose |
|------|---------|
| `route53_ddns/ddns.py` | Main DDNS script (Python + boto3) |
| `route53_ddns/run.sh` | HA addon entrypoint (reads Supervisor options) |
| `route53_ddns/Dockerfile` | HA addon Docker image |
| `route53_ddns/config.yaml` | HA addon configuration schema |
| `setup-iam.sh` | Creates dedicated IAM user with least-privilege policy |
| `iam-policy.json` | IAM policy (only allows updating one A record) |
| `ha-config/ddns-wrapper.sh` | Wrapper for shell_command approach (no addon) |
| `ha-config/README-config.md` | Instructions for shell_command setup |

## Setup

### Step 1: Create IAM user (on any machine with AWS CLI + root credentials)

```bash
export AWS_ACCESS_KEY_ID=<root-key>
export AWS_SECRET_ACCESS_KEY=<root-secret>
export AWS_DEFAULT_REGION=eu-central-1

cd route53-ddns
chmod +x setup-iam.sh
./setup-iam.sh
```

This creates an IAM user with a policy that ONLY allows updating the specified A record.
Root credentials are used once and never stored.

### Step 2a: HA Addon installation (if Supervisor build works)

1. Add this repo to HA Add-on Store (Settings > Apps > Store > Menu > Repositories)
2. Install "Route 53 DDNS"
3. Configure with AWS credentials in addon settings
4. Start the addon

### Step 2b: shell_command approach (recommended for HAOS with Supervisor build issues)

Some HAOS Supervisor versions have a bug preventing addon builds (`/store/repos 404`).
Use this approach instead:

1. Install "Terminal & SSH" addon from HA Add-on Store
2. Configure SSH access (set password, map port 22 to 22222)
3. Upload scripts to `/config/`:

```bash
scp -P 22222 route53_ddns/ddns.py root@homeassistant:/config/ddns.py
scp -P 22222 ha-config/ddns-wrapper.sh root@homeassistant:/config/ddns-wrapper.sh
```

4. Edit `/config/ddns-wrapper.sh` — set your AWS credentials
5. Add to `/config/configuration.yaml`:

```yaml
shell_command:
  ddns_update: sh /config/ddns-wrapper.sh
```

6. Add to `/config/automations.yaml`:

```yaml
- alias: "DDNS Route 53 Update"
  description: "Updates Route 53 A record every 5 minutes"
  trigger:
    - platform: time_pattern
      minutes: "/5"
  action:
    - service: shell_command.ddns_update
      data: {}
  mode: single
```

7. Restart Home Assistant (required for shell_command to load)
8. Verify: call `shell_command.ddns_update` service manually

## Security

- IAM policy allows ONLY `route53:ChangeResourceRecordSets` on one zone
- IAM policy allows ONLY `route53:ListResourceRecordSets` on one zone
- Root AWS credentials used once in `setup-iam.sh`, never stored
- Script makes zero API calls when IP hasn't changed (minimal cost)
- AWS credentials stored in `/config/secrets.yaml` (or wrapper script)

## Cost

- Route 53 hosted zone: $0.50/month (if you already have one, no extra cost)
- API calls: ~$0.40 per million — at a few updates per day = ~$0.01/month

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `ModuleNotFoundError: boto3` | Wrapper script runs `pip3 install boto3` automatically |
| `InvalidClientTokenId` | Wrong AWS credentials — verify access key ID and secret |
| `Service shell_command.ddns_update not found` | Restart HA Core (shell_command needs full restart, not just reload) |
| Supervisor addon build fails | Use shell_command approach (Step 2b) |
| IP not updating | Check `api.ipify.org` connectivity, verify HA automation is enabled |

## License

MIT
