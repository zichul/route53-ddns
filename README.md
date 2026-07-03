# Route 53 Dynamic DNS — home.zichul.de

DDNS skrypt który sprawdza publiczny IP co 5 minut i aktualizuje A record
w AWS Route 53 tylko gdy IP się zmienił.

## Pliki

| Plik | Funkcja |
|------|---------|
| `iam-policy.json` | Polityka IAM least-privilege (tylko update tego 1 rekordu) |
| `setup-iam.sh` | Tworzy osobny IAM user + access key (uruchom z root creds) |
| `route53-ddns.sh` | Główny skrypt DDNS |
| `route53-ddns.service` | systemd service (oneshot) |
| `route53-ddns.timer` | systemd timer (co 5 min) |

## Setup — krok 1: stwórz osobny IAM user (na maszynie z AWS CLI + root creds)

```bash
# skonfiguruj root creds (tymczasowo, nie zapisuje ich nigdzie)
export AWS_ACCESS_KEY_ID=<root-key>
export AWS_SECRET_ACCESS_KEY=<root-secret>
export AWS_DEFAULT_REGION=eu-central-1

cd ~/code/ddns
chmod +x setup-iam.sh
./setup-iam.sh
```

Skrypt wypisze:
```
AWS_ACCESS_KEY_ID = AKIA...
AWS_SECRET_KEY     = abcd...
HOSTED_ZONE_ID     = Z123ABC...
```

## Setup — krok 2: instalacja na urządzeniu Home Assistant

Założenie: HA na Debian/Ubuntu (Supervised lub Container), nie HAOS.
Na HAOS (read-only) patrz sekcja "HAOS" poniżej.

```bash
# 1. katalog konfiguracyjny
sudo mkdir -p /etc/ddns
sudo tee /etc/ddns/ddns.conf <<EOF
AWS_ACCESS_KEY_ID=AKIA...tu_od_setup
AWS_SECRET_ACCESS_KEY=abcd...tu_od_setup
AWS_REGION=eu-central-1
HOSTED_ZONE_ID=Z123...tu_od_setup
DOMAIN=home.zichul.de
TTL=300
IP_CHECK_URL=https://api.ipify.org
EOF
sudo chmod 600 /etc/ddns/ddns.conf
sudo chown root:root /etc/ddns/ddns.conf

# 2. zainstaluj aws-cli (jeśli nie ma)
sudo apt-get install -y awscli

# 3. instaluj skrypt
sudo cp route53-ddns.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/route53-ddns.sh

# 4. instaluj systemd unit + timer
sudo cp route53-ddns.service /etc/systemd/system/
sudo cp route53-ddns.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now route53-ddns.timer

# 5. test ręczny
sudo /usr/local/bin/route53-ddns.sh
```

## Weryfikacja

```bash
# sprawdź timer
systemctl status route53-ddns.timer

# sprawdź logi
journalctl -u route53-ddns -n 20

# sprawdź DNS z zewnątrz
dig home.zichul.de +short
```

## HAOS (Home Assistant OS — read-only)

HAOS nie pozwala instalować pakietów. Dwie opcje:

### Opcja A: HA automation z shell_command
W `configuration.yaml`:
```yaml
shell_command:
  route53_ddns: >
    AWS_ACCESS_KEY_ID={{ secrets.aws_key }}
    AWS_SECRET_ACCESS_KEY={{ secrets.aws_secret }}
    /config/route53-ddns.sh
```
Potem automation `trigger` co 5 min wywołuje `shell_command.route53_ddns`.
Wymaga aws-cli w kontenerze HA (może wymagać dodania przez addon).

### Opcja B: osobny kontener Docker (najprostsze)
```bash
docker run -d --name ddns --restart=always \
  -v /etc/ddns:/etc/ddns:ro \
  amazon/aws-cli route53 ...  # ale to nie działa jako daemon
```
Lepiej: kontener z cron + aws-cli:
```dockerfile
FROM amazon/aws-cli:latest
RUN apk add --no-cache curl
COPY route53-ddns.sh /route53-ddns.sh
# cron co 5 min
```

## Bezpieczeństwo

- `ddns.conf` ma chmod 600, właściciel root
- IAM polityka pozwala TYLKO na update `home.zichul.de` — nic innego
- Root creds użyte tylko w `setup-iam.sh` (jeden raz, nie zapisane)
- Skrypt nie wysyła IP gdy bez zmian (minimalne API calls = minimalny koszt)
- Route 53 billing: $0.40/milion zapytań — przy zmianie IP max kilka razy/dzień = ~$0.01/m-c

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `brak pliku konfiguracyjnego` | Stwórz `/etc/ddns/ddns.conf` lub `$DDNS_CONF` |
| `AccessDenied` | Błędne klucze w `ddns.conf` lub źle wpięta polityka IAM |
| `InvalidChangeBatch` | Rekord nie w tej zone — sprawdź HOSTED_ZONE_ID |
| `nie udało się pobrać IP` | Sprawdź `IP_CHECK_URL` lub DNS provider — fallback: `https://ifconfig.me` |
