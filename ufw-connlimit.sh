#!/bin/bash
# Лимит одновременных TCP-соединений с одного адреса на порт.
# Пишется в /etc/ufw/before.rules и переживает перезагрузку.
#
# Запускать на самом сервере, от root:
#   ./ufw-connlimit.sh

set -euo pipefail

RULES_FILE="/etc/ufw/before.rules"
ANCHOR='-A ufw-before-input -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT'

[[ $EUID -eq 0 ]] || { echo "Запускайте от root." >&2; exit 1; }
[[ -f $RULES_FILE ]] || { echo "Нет файла $RULES_FILE. Сначала включите ufw." >&2; exit 1; }
command -v ufw >/dev/null || { echo "ufw не установлен." >&2; exit 1; }

valid_ip() {
  local ip=$1 o
  [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
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

ask_port() {
  local reply
  while true; do
    read -rp "Порт [443]: " reply
    reply=${reply:-443}
    if valid_port "$reply"; then
      printf '%s' "$reply"
      return
    fi
    echo "Некорректный порт, введите ещё раз." >&2
  done
}

ask_limit() {
  local reply
  while true; do
    read -rp "Сколько соединений с одного адреса оставить: " reply
    if [[ $reply =~ ^[0-9]+$ ]] && [[ $reply -ge 1 ]]; then
      printf '%s' "$reply"
      return
    fi
    echo "Нужно целое число больше нуля." >&2
  done
}

# Из сырых строк правил печатает: адрес порт число
parse_limits() {
  awk '
    /connlimit/ {
      ip = ""; port = ""; n = ""
      for (i = 1; i <= NF; i++) {
        if ($i == "-d" && i < NF) { ip = $(i + 1); sub(/\/32$/, "", ip) }
        if ($i == "--dport" && i < NF) port = $(i + 1)
        if ($i == "--connlimit-above" && i < NF) n = $(i + 1)
      }
      if (ip != "" && port != "" && n != "") print ip, port, n
    }
  '
}

print_limits() {
  local rows=$1 ip port n
  if [[ -z $rows ]]; then
    echo "  лимита нет"
    return
  fi
  while read -r ip port n; do
    [[ -n $ip ]] || continue
    echo "  ${ip}, порт ${port}: с одного адреса не больше ${n} соединений"
  done <<< "$rows"
}

show_limits() {
  local saved live
  saved=$(grep "connlimit" "$RULES_FILE" | parse_limits || true)
  live=$(iptables -S ufw-before-input 2>/dev/null | grep "connlimit" | parse_limits || true)

  if [[ -z $saved && -z $live ]]; then
    echo "Лимита нет. С одного адреса можно открывать сколько угодно соединений."
    return
  fi

  if [[ $saved == "$live" ]]; then
    echo "Сейчас:"
    print_limits "$saved"
    echo "После перезагрузки останется так же."
    return
  fi

  echo "Сейчас работает:"
  print_limits "$live"
  echo
  echo "После перезагрузки будет:"
  print_limits "$saved"
}

rule_line() {
  local ip=$1 port=$2 limit=$3
  printf '%s\n' "-A ufw-before-input -p tcp -d ${ip} --dport ${port} -m connlimit --connlimit-above ${limit} --connlimit-mask 32 -j REJECT --reject-with tcp-reset"
}

backup_rules() {
  cp "$RULES_FILE" "${RULES_FILE}.bak.$(date +%Y%m%d%H%M%S)"
}

# Удаляет из файла правила connlimit для адреса и порта.
# Печатает, сколько строк удалено.
drop_rules() {
  local ip=$1 port=$2 tmp count
  tmp=$(mktemp)
  count=$(awk -v ip="$ip" -v port="$port" '
    /connlimit/ && $0 ~ ("-d " ip " ") && $0 ~ ("--dport " port "( |$)") { c++; next }
    { print }
    END { printf "%d", c+0 > "/dev/stderr" }
  ' "$RULES_FILE" 2>"$tmp" >"${tmp}.body")
  cat "${tmp}.body" >"$RULES_FILE"
  rm -f "${tmp}.body"
  cat "$tmp"
  rm -f "$tmp"
}

insert_rule() {
  local line=$1 tmp
  grep -qxF "$ANCHOR" "$RULES_FILE" || {
    echo "В $RULES_FILE нет стандартной строки ESTABLISHED. Файл не изменён." >&2
    return 1
  }
  tmp=$(mktemp)
  awk -v anchor="$ANCHOR" -v rule="$line" '
    !done && $0 == anchor { print; print rule; done=1; next }
    { print }
  ' "$RULES_FILE" >"$tmp"
  cat "$tmp" >"$RULES_FILE"
  rm -f "$tmp"
}

apply_reload() {
  ufw reload
  echo
  show_limits
}

set_limit() {
  local ip port limit line removed
  echo
  ip=$(ask_ip "Адрес, на который действует лимит: ")
  echo
  port=$(ask_port)
  echo
  limit=$(ask_limit)
  echo
  echo "С одного адреса к ${ip}:${port} останется ${limit} соединений."
  read -rp "Записать навсегда? [y/N] " confirm
  [[ $confirm == [yY] ]] || { echo "Отменено."; return; }

  backup_rules
  removed=$(drop_rules "$ip" "$port")
  line=$(rule_line "$ip" "$port" "$limit")
  insert_rule "$line"
  echo "Записано. Прежних правил для этого адреса и порта снято: ${removed}."
  apply_reload
}

remove_limit() {
  local ip port removed
  echo
  ip=$(ask_ip "Адрес, с которого снять лимит: ")
  echo
  port=$(ask_port)
  echo
  echo "Лимит на ${ip}:${port} будет удалён из UFW."
  read -rp "Удалить навсегда? [y/N] " confirm
  [[ $confirm == [yY] ]] || { echo "Отменено."; return; }

  backup_rules
  removed=$(drop_rules "$ip" "$port")
  if [[ $removed == 0 ]]; then
    echo "Такого лимита в файле не было. Перезагрузка ufw не нужна."
    show_limits
    return
  fi
  echo "Удалено правил: ${removed}."
  apply_reload
}

while true; do
  echo
  echo "1) Показать текущий лимит"
  echo "2) Установить лимит"
  echo "3) Снять лимит"
  echo "0) Выход"
  read -rp "Выбор: " choice
  case $choice in
    1) echo; show_limits ;;
    2) set_limit ;;
    3) remove_limit ;;
    0) exit 0 ;;
    *) echo "Нет такого пункта." ;;
  esac
done
