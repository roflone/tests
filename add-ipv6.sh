#!/usr/bin/env bash
# Показывает, как на сервере настроена сеть, затем добавляет выданный хостером IPv6.
# IPv4, netplan, cloud-init и /etc/network/interfaces не переписываются:
# адрес поднимается командой ip и сохраняется отдельной службой systemd.
set -Eeuo pipefail

SELF_NAME="$(basename "$0")"
STATE_FILE="/etc/add-ipv6.env"
UNIT_NAME="add-ipv6.service"
UNIT_PATH="/etc/systemd/system/${UNIT_NAME}"
SYSCTL_PATH="/etc/sysctl.d/99-add-ipv6.conf"

log() {
  printf '[%s] %s\n' "$SELF_NAME" "$*"
}

die() {
  printf '[%s] ERROR: %s\n' "$SELF_NAME" "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  sudo ./add-ipv6.sh
  sudo ./add-ipv6.sh <ipv6-адрес>
  sudo ./add-ipv6.sh <ipv6-адрес>/<префикс> [интерфейс]
  sudo ./add-ipv6.sh remove

Скрипт сначала показывает, кто хранит сеть на сервере, затем спрашивает
выданный хостером IPv6 и добавляет его. Строки IPv4 не меняются.
EOF
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Запусти от root: sudo bash $0"
  fi
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Не найдена команда: $1"
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

require_tty() {
  [[ -t 0 ]] || die "Интерактивный режим требует терминала."
}

prompt_value() {
  local prompt="$1"
  local default="${2:-}"
  local reply=""
  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " reply || true
    printf '%s' "${reply:-$default}"
  else
    read -r -p "$prompt: " reply || true
    printf '%s' "$reply"
  fi
}

confirm() {
  local prompt="$1"
  local default="${2:-y}"
  local reply=""
  local hint="[Y/n]"
  [[ "$default" == "n" ]] && hint="[y/N]"
  read -r -p "$prompt $hint: " reply || true
  reply="${reply:-$default}"
  case "$reply" in
    y|Y|yes|YES|да|ДА) return 0 ;;
    *) return 1 ;;
  esac
}

detect_ifaces() {
  ip -4 route show default 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") print $(i + 1)}' | awk '!seen[$0]++'
}

current_default_gateway() {
  ip -6 route show default 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "via") { print $(i + 1); exit }}'
}

ipv6_gateway() {
  local ip="$1"
  local left="" right="" zeros=0 i=0 g
  local -a left_g=() right_g=() all=()
  ip="$(printf '%s' "$ip" | tr '[:upper:]' '[:lower:]')"
  [[ "$ip" != *::*::* ]] || return 1

  if [[ "$ip" == *::* ]]; then
    left="${ip%%::*}"
    right="${ip#*::}"
  else
    left="$ip"
  fi

  if [[ -n "$left" ]]; then
    IFS=':' read -r -a left_g <<< "$left"
  fi
  if [[ -n "$right" ]]; then
    IFS=':' read -r -a right_g <<< "$right"
  fi

  if [[ "$ip" != *::* ]]; then
    [[ ${#left_g[@]} -eq 8 ]] || return 1
    all=("${left_g[@]}")
  else
    zeros=$((8 - ${#left_g[@]} - ${#right_g[@]}))
    [[ "$zeros" -ge 1 ]] || return 1
    if [[ ${#left_g[@]} -gt 0 ]]; then
      all=("${left_g[@]}")
    fi
    for ((i = 0; i < zeros; i++)); do
      all+=("0")
    done
    if [[ ${#right_g[@]} -gt 0 ]]; then
      all+=("${right_g[@]}")
    fi
  fi
  [[ ${#all[@]} -eq 8 ]] || return 1

  for g in "${all[0]}" "${all[1]}" "${all[2]}" "${all[3]}"; do
    [[ "$g" =~ ^[0-9a-f]{1,4}$ ]] || return 1
  done

  local a b c d
  a="$(printf '%x' "0x${all[0]}")"
  b="$(printf '%x' "0x${all[1]}")"
  c="$(printf '%x' "0x${all[2]}")"
  d="$(printf '%x' "0x${all[3]}")"
  if [[ "$d" == "0" ]]; then
    printf '%s:%s:%s::1' "$a" "$b" "$c"
  else
    printf '%s:%s:%s:%s::1' "$a" "$b" "$c" "$d"
  fi
}

split_address() {
  local raw="$1"
  raw="$(trim "$raw")"
  raw="${raw#[}"
  raw="${raw%]}"
  ADDR_PREFIX="64"
  if [[ "$raw" == */* ]]; then
    ADDR_PREFIX="${raw##*/}"
    raw="${raw%/*}"
  fi
  ADDR_VALUE="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
  [[ "$ADDR_PREFIX" =~ ^[0-9]+$ ]] || die "Некорректный префикс: ${ADDR_PREFIX}"
  (( ADDR_PREFIX >= 48 && ADDR_PREFIX <= 128 )) || die "Префикс должен быть от /48 до /128."
  ipv6_gateway "$ADDR_VALUE" >/dev/null || die "Некорректный IPv6: ${ADDR_VALUE}"
  [[ "$ADDR_VALUE" != fe80:* && "$ADDR_VALUE" != ff* ]] || die "Нужен публичный IPv6 из панели хостера."
}

print_block() {
  local title="$1"
  echo ""
  echo "— ${title}"
}

show_matching_lines() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  echo ""
  echo "Файл ${file}:"
  grep -nE 'dhcp4|dhcp6|addresses:|address |gateway|via:|renderer:|inet |iface |Address=|Gateway=|^\s*[A-Za-z0-9_.:-]+:' "$file" | head -n 60 || true
}

show_network_report() {
  local iface="$1"
  local backend="отдельной службой, файлы IPv4 не трогаю"
  local f

  echo "=== Как сейчас настроена сеть ==="
  echo ""
  echo "Кратко по всем интерфейсам:"
  ip -br addr || true
  echo ""
  echo "Маршруты по умолчанию:"
  ip -4 route show default 2>/dev/null || true
  ip -6 route show default 2>/dev/null || true

  print_block "Интерфейс, куда добавлю IPv6: ${iface}"
  ip -4 addr show dev "$iface" scope global || true
  echo ""
  ip -6 addr show dev "$iface" || true

  print_block "Где лежат настройки"
  local found="no"
  if compgen -G "/etc/netplan/*.yaml" >/dev/null; then
    found="yes"
    echo "Сеть описывает netplan:"
    for f in /etc/netplan/*.yaml; do
      echo "  ${f}"
      if grep -q "cloud-init" "$f" 2>/dev/null || [[ "$f" == *cloud-init* ]]; then
        echo "  этот файл собирает cloud-init, скрипт его не редактирует"
      fi
      show_matching_lines "$f"
    done
    backend="netplan уже держит IPv4; IPv6 добавлю отдельно и не буду править эти yaml"
  fi

  if [[ -f /etc/network/interfaces ]] && grep -qE '^[[:space:]]*iface[[:space:]]+' /etc/network/interfaces; then
    found="yes"
    echo ""
    echo "Сеть также описана в /etc/network/interfaces. Этот файл скрипт не меняет."
    show_matching_lines /etc/network/interfaces
    if [[ "$backend" == "отдельной службой, файлы IPv4 не трогаю" ]]; then
      backend="/etc/network/interfaces уже держит IPv4; IPv6 добавлю отдельно"
    fi
  fi

  if command -v nmcli >/dev/null 2>&1; then
    local nm_state
    nm_state="$(nmcli -t -f DEVICE,STATE device status 2>/dev/null | grep "^${iface}:" || true)" || true
    if [[ -n "$nm_state" && "$nm_state" != *unmanaged* ]]; then
      found="yes"
      echo ""
      echo "Интерфейсом управляет NetworkManager: ${nm_state}"
      nmcli -f ipv4.method,ipv4.addresses,ipv6.method,ipv6.addresses,ipv6.gateway device show "$iface" 2>/dev/null || true
      backend="NetworkManager уже держит IPv4; IPv6 добавлю отдельно и не буду менять его профиль"
    fi
  fi

  if command -v networkctl >/dev/null 2>&1; then
    local netfile
    netfile="$(networkctl status "$iface" 2>/dev/null | awk -F: '/Network File/ { gsub(/^ +/, "", $2); print $2; exit }' || true)"
    if [[ -n "$netfile" ]]; then
      found="yes"
      echo ""
      echo "systemd-networkd ведёт интерфейс файлом ${netfile}. Скрипт его не меняет."
      show_matching_lines "$netfile"
      if [[ "$backend" == "отдельной службой, файлы IPv4 не трогаю" ]]; then
        backend="systemd-networkd уже держит IPv4; IPv6 добавлю отдельно"
      fi
    fi
  fi

  if [[ -f /etc/timeweb-ipv6.env ]]; then
    echo ""
    echo "На сервере уже есть /etc/timeweb-ipv6.env от прежнего скрипта Timeweb."
  fi

  if [[ "$found" == "no" ]]; then
    echo "Готового файла с адресами не нашёл. Для IPv6 этого достаточно: адрес поднимет служба systemd."
  fi

  echo ""
  echo "Что сделает скрипт: ${backend}."
  echo "После ввода адреса он пропишет его на ${iface} и сохранит на перезагрузку."
  echo "Шлюз из панели хостера важнее подсказки скрипта."
}

write_state() {
  umask 077
  cat >"$STATE_FILE" <<EOF
IPV6_ADDR=${ADDR_VALUE}
IPV6_PREFIX=${ADDR_PREFIX}
IPV6_GATEWAY=${ADDR_GATEWAY}
IPV6_IFACE=${ADDR_IFACE}
EOF
  chmod 600 "$STATE_FILE"
}

install_sysctl() {
  cat >"$SYSCTL_PATH" <<'EOF'
net.ipv6.ip_nonlocal_bind = 1
EOF
  sysctl --system >/dev/null
}

install_unit() {
  local ip_bin
  ip_bin="$(command -v ip)"
  cat >"$UNIT_PATH" <<'EOF'
[Unit]
Description=Additional IPv6 from the hosting panel
After=network-online.target
Wants=network-online.target
Before=wg-quick@wg0.service

[Service]
Type=oneshot
EnvironmentFile=@STATE@
ExecStartPre=/bin/sh -c 'for n in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do @IP@ link show "$IPV6_IFACE" >/dev/null 2>&1 && exit 0; sleep 1; done; exit 0'
ExecStart=@IP@ -6 addr replace ${IPV6_ADDR}/${IPV6_PREFIX} dev ${IPV6_IFACE}
ExecStart=/bin/sh -c 'if [ -n "$IPV6_GATEWAY" ]; then @IP@ -6 route replace default via "$IPV6_GATEWAY" dev "$IPV6_IFACE" onlink; fi'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  sed -i.bak \
    -e "s|@STATE@|${STATE_FILE}|g" \
    -e "s|@IP@|${ip_bin}|g" \
    "$UNIT_PATH"
  rm -f "${UNIT_PATH}.bak"
  systemctl daemon-reload
  systemctl enable "$UNIT_NAME" >/dev/null
}

apply_now() {
  ip -6 addr replace "${ADDR_VALUE}/${ADDR_PREFIX}" dev "${ADDR_IFACE}"
  if [[ -n "$ADDR_GATEWAY" ]]; then
    ip -6 route replace default via "${ADDR_GATEWAY}" dev "${ADDR_IFACE}" onlink
  fi
}

disable_ipv6_dhcp_client() {
  local unit
  for unit in dhclient6.service dhcpcd6.service; do
    if systemctl cat "$unit" >/dev/null 2>&1; then
      systemctl disable --now "$unit" >/dev/null 2>&1 || true
      log "Отключил ${unit}, чтобы он не снимал статический IPv6."
    fi
  done
}

wait_for_dad() {
  local i=0 line
  while [[ "$i" -lt 8 ]]; do
    line="$(ip -6 addr show dev "${ADDR_IFACE}" scope global 2>/dev/null || true)"
    if [[ "$line" == *dadfailed* ]]; then
      return 1
    fi
    if [[ "$line" != *tentative* ]]; then
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  return 2
}

show_result() {
  local dad_rc=0
  wait_for_dad || dad_rc=$?
  echo ""
  ip -6 addr show dev "${ADDR_IFACE}" scope global || true
  echo ""
  ip -6 route show default || true
  echo ""
  if [[ "$dad_rc" -eq 1 ]]; then
    log "Сеть отвергла адрес: на интерфейсе он помечен dadfailed."
    return
  fi
  if [[ "$dad_rc" -eq 2 ]]; then
    log "Адрес завис в tentative. Ядро ещё не разрешило с него отправлять пакеты."
  fi
  if ping -6 -c 2 -W 3 2606:4700:4700::1111 >/dev/null 2>&1; then
    log "IPv6 наружу отвечает."
  else
    log "Адрес на интерфейсе есть, ping до 2606:4700:4700::1111 не прошёл."
    if [[ -n "${ADDR_GATEWAY}" ]]; then
      log "Проверь шлюз: ping -6 -c 3 ${ADDR_GATEWAY}"
    fi
  fi
}

cmd_remove() {
  require_root
  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
    if [[ -n "${IPV6_ADDR:-}" && -n "${IPV6_IFACE:-}" ]]; then
      ip -6 addr del "${IPV6_ADDR}/${IPV6_PREFIX:-64}" dev "${IPV6_IFACE}" >/dev/null 2>&1 || true
    fi
    if [[ -n "${IPV6_GATEWAY:-}" && -n "${IPV6_IFACE:-}" ]]; then
      ip -6 route del default via "${IPV6_GATEWAY}" dev "${IPV6_IFACE}" onlink >/dev/null 2>&1 || true
    fi
  fi
  systemctl disable --now "$UNIT_NAME" >/dev/null 2>&1 || true
  rm -f "$UNIT_PATH" "$STATE_FILE" "$SYSCTL_PATH"
  systemctl daemon-reload
  log "Добавленный IPv6 снят. IPv4 не менялся."
}

choose_iface() {
  local iface_arg="$1"
  local detected iface_count
  detected="$(detect_ifaces)"
  iface_count="$(printf '%s\n' "$detected" | awk 'NF { n++ } END { print n + 0 }')"
  if [[ -n "$iface_arg" ]]; then
    ADDR_IFACE="$iface_arg"
  elif [[ "$iface_count" -eq 1 ]]; then
    ADDR_IFACE="$detected"
  elif [[ -t 0 && "$iface_count" -gt 1 ]]; then
    echo "Несколько интерфейсов с маршрутом по умолчанию:"
    printf '%s\n' "$detected"
    ADDR_IFACE="$(prompt_value "Куда добавлять IPv6" "$(printf '%s\n' "$detected" | awk 'NF { print; exit }')")"
  else
    ADDR_IFACE="$(printf '%s\n' "$detected" | awk 'NF { print; exit }')"
  fi
  [[ -n "$ADDR_IFACE" ]] || die "Не смог определить интерфейс. Укажи его вторым аргументом."
  ip link show "$ADDR_IFACE" >/dev/null 2>&1 || die "Интерфейса ${ADDR_IFACE} нет."
}

cmd_apply() {
  require_root
  need_cmd ip
  need_cmd awk
  need_cmd systemctl

  local raw="${1:-}"
  local iface_arg="${2:-}"
  local suggested existing gateway_input

  choose_iface "$iface_arg"
  show_network_report "$ADDR_IFACE"

  echo ""
  if [[ -z "$raw" ]]; then
    require_tty
    raw="$(prompt_value "IPv6 из панели, как в колонке адреса, без /64" "")"
  fi
  [[ -n "$raw" ]] || die "Адрес IPv6 обязателен."
  split_address "$raw"

  if [[ -t 0 ]]; then
    ADDR_PREFIX="$(prompt_value "Префикс. /64 если хостер выдал сеть, /128 если один адрес" "$ADDR_PREFIX")"
    [[ "$ADDR_PREFIX" =~ ^[0-9]+$ ]] || die "Некорректный префикс: ${ADDR_PREFIX}"
    (( ADDR_PREFIX >= 48 && ADDR_PREFIX <= 128 )) || die "Префикс должен быть от /48 до /128."
  fi

  suggested="$(ipv6_gateway "$ADDR_VALUE")"
  [[ "$suggested" != "$ADDR_VALUE" ]] || die "Адрес совпал со шлюзом ${suggested}. Возьми в панели адрес сервера, не адрес шлюза."
  existing="$(current_default_gateway)"
  ADDR_GATEWAY=""
  if [[ -n "$existing" ]]; then
    echo "IPv6-шлюз уже есть: ${existing}"
    if [[ -t 0 ]]; then
      gateway_input="$(prompt_value "Новый шлюз. Enter оставляет ${existing}" "")"
      gateway_input="$(trim "$gateway_input")"
      if [[ -n "$gateway_input" ]]; then
        ADDR_GATEWAY="$gateway_input"
      fi
    fi
  else
    if [[ -t 0 ]]; then
      ADDR_GATEWAY="$(prompt_value "Шлюз IPv6 из панели" "$suggested")"
    else
      ADDR_GATEWAY="$suggested"
    fi
    ADDR_GATEWAY="$(trim "$ADDR_GATEWAY")"
    [[ -n "$ADDR_GATEWAY" ]] || die "Шлюз IPv6 обязателен: своего маршрута на сервере ещё нет."
  fi
  if [[ -n "$ADDR_GATEWAY" ]]; then
    ipv6_gateway "$ADDR_GATEWAY" >/dev/null || die "Некорректный шлюз: ${ADDR_GATEWAY}"
    [[ "$ADDR_GATEWAY" != "$ADDR_VALUE" ]] || die "Шлюз совпал с адресом сервера."
  fi

  echo ""
  echo "Будет настроено:"
  echo "  адрес:     ${ADDR_VALUE}/${ADDR_PREFIX}"
  if [[ -n "$ADDR_GATEWAY" ]]; then
    echo "  шлюз:      ${ADDR_GATEWAY}"
  else
    echo "  шлюз:      оставить ${existing}"
  fi
  echo "  интерфейс: ${ADDR_IFACE}"
  echo "  IPv4:      без изменений"
  if [[ -t 0 ]]; then
    confirm "Применить?" "y" || {
      log "Ничего не менял."
      return
    }
  fi

  apply_now
  write_state
  install_sysctl
  install_unit
  disable_ipv6_dhcp_client
  show_result
  log "После перезагрузки адрес поднимет служба ${UNIT_NAME}."
  log "Проверка: ip -6 addr show dev ${ADDR_IFACE} scope global"
}

main() {
  case "${1:-}" in
    ""|apply)
      cmd_apply ""
      ;;
    remove|down)
      cmd_remove
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      cmd_apply "$@"
      ;;
  esac
}

main "$@"
