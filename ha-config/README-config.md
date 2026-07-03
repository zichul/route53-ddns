# shell_command setup for HAOS

Use this approach if the HA Supervisor addon build fails.

## Files to upload to /config/

- `ddns.py` -> `/config/ddns.py`
- `ddns-wrapper.sh` -> `/config/ddns-wrapper.sh`

## Setup

1. Edit `ddns-wrapper.sh` — set your AWS credentials and domain
2. Upload both files to HA via SSH or Samba
3. Add to `/config/configuration.yaml`:

```yaml
shell_command:
  ddns_update: sh /config/ddns-wrapper.sh
```

4. Add to `/config/automations.yaml`:

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

5. Restart Home Assistant (required for shell_command to load)
6. Test: call `shell_command.ddns_update` service manually
