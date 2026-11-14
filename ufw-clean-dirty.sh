#!/bin/bash
# Чистый адрес: 80 и 443 снаружи.
# Грязный адрес: SSH отовсюду, панель 3000 только с адреса панели.
# Входящий IPv6 не открывается. Широкие правила на те же порты снимаются.
#
# Запускать по SSH на грязный адрес, от root:
#   ./ufw-clean-dirty.sh

set -euo pipefail

OUT_DENY_PORTS="25,465,587,1080,3128,8080"

valid_ip() {
  local ip=$1 o
  [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS=. read -r o o o o <<< "$ip"
  for o in ${ip//./ }; do
    [[ $o -ge 0 && $o -le 255 ]] || return 1
  done
}

valid_port() {
  local p=$1
  [[ $p =~ ^[0-9]+$ ]] || return 1
  [[ $p -ge 1 && $p -le 65535 ]]
}

ask_ip() {
  local prompt=$1 reply
  while true; do
    read -rp "$prompt" reply
    if valid_ip "$reply"; then
      printf '%s' "$reply"
      return
    fi
    echo "Некорректный адрес, введите ещё раз." >&2
  done
}

[[ $EUID -eq 0 ]] || { echo "Запускайте от root." >&2; exit 1; }
command -v ufw >/dev/null || { echo "ufw не установлен." >&2; exit 1; }

DIRTY=$(ask_ip "Грязный адрес: ")
echo
CLEAN=$(ask_ip "Чистый адрес: ")
echo
PANEL_IP=$(ask_ip "Адрес панели, с которого открыт порт 3000: ")
echo

[[ $DIRTY != "$CLEAN" ]] || { echo "Грязный и чистый адреса совпадают." >&2; exit 1; }

read -rp "Дополнительные порты на чистом адресе через пробел (можно оставить пустым): " extra
CLEAN_PORTS=(80 443)
for p in $extra; do
  valid_port "$p" || { echo "Некорректный порт: $p" >&2; exit 1; }
  CLEAN_PORTS+=("$p")
done

if [[ -n ${SSH_CONNECTION:-} ]]; then
  # client_ip client_port server_ip server_port
  read -r _ _ ssh_dst _ <<< "$SSH_CONNECTION"
  if [[ $ssh_dst != "$DIRTY" ]]; then
    echo "Сессия открыта на $ssh_dst. Зайдите на грязный $DIRTY и запустите скрипт снова." >&2
    exit 1
  fi
fi

port_re=$(IFS='|'; echo "${CLEAN_PORTS[*]}")
port_re="^(22|3000|${port_re})/tcp$"

echo
echo "Грязный $DIRTY: 22 отовсюду, 3000 только с $PANEL_IP"
echo "Чистый $CLEAN: ${CLEAN_PORTS[*]}"
read -rp "Применить эти правила? [y/N] " confirm
[[ $confirm == [yY] ]] || { echo "Отменено."; exit 0; }

ufw default deny incoming
ufw default allow outgoing

for p in "${CLEAN_PORTS[@]}"; do
  ufw allow proto tcp to "$CLEAN" port "$p"
done
ufw allow proto tcp to "$DIRTY" port 22
ufw allow proto tcp from "$PANEL_IP" to "$DIRTY" port 3000
ufw deny out proto tcp to any port "$OUT_DENY_PORTS"

mapfile -t nums < <(ufw status numbered | awk -v re="$port_re" '
  /ALLOW IN/ {
    line = $0
    sub(/^\[ */, "", line)
    num = line
    sub(/\].*/, "", num)
    gsub(/ /, "", num)
    rest = line
    sub(/^[0-9]+\][[:space:]]+/, "", rest)
    split(rest, a, /[[:space:]]+/)
    if (a[1] ~ re) print num
  }
' | sort -nr)

for n in "${nums[@]+"${nums[@]}"}"; do
  ufw --force delete "$n"
done

echo
ufw status
