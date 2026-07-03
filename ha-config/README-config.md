# Dodaj do configuration.yaml (na końcu):
#
# shell_command:
#   ddns_update: sh /config/ddns.sh "{{ secrets.aws_access_key_id }}" "{{ secrets.aws_secret_access_key }}" "eu-central-1" "{{ secrets.aws_zone_id }}" "home.zichul.de" "300" "https://api.ipify.org"
#
# secrets.yaml entries:
# aws_access_key_id: AKIA2CA7O54YEK44XWDWN
# aws_secret_access_key: UrBJ6TPuXlZqu+ld6vLvYVb9Cb7M+lMPCElGJ70U
# aws_zone_id: Z03910021BEMNBANA8R7K
#
# Automations.yaml entry:
#
# - alias: "DDNS Route 53 Update"
#   trigger:
#     - platform: time_pattern
#       minutes: "/5"
#   action:
#     - service: shell_command.ddns_update
#       data: {}
#   mode: single
