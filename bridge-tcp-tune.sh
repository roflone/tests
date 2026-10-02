#!/usr/bin/env bash
# Тюнинг TCP на мосту. Из node-accelerator/scripts/optimize.sh взяты только:
#   BBR + очередь fq, tcp_slow_start_after_idle, tcp_mtu_probing,
#   tcp_min_snd_mss и RPS/RFS/XPS.
# Ядро, файрвол, буферы, forwarding и swap не меняются.
set -Eeuo pipefail

SELF_NAME="$(basename "$0")"
SYSCTL_PATH="/etc/sysctl.d/99-bridge-tcp-tune.conf"
STATE_PATH="/etc/bridge-tcp-tune.state"
RPS_BIN="/usr/local/sbin/bridge-tcp-rps-setup"
RPS_UNIT="/etc/systemd/system/bridge-tcp-rps.service"

log() { printf '[%s] %s\n' "$SELF_NAME" "$*"; }
die() { printf '[%s] ERROR: %s\n' "$SELF_NAME" "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage:
  sudo ./bridge-tcp-tune.sh
  sudo ./bridge-tcp-tune.sh remove

Ставит на мост BBR+fq, отключает медленный старт после паузы,
включает пробу MTU и RPS, если ядер больше одного, а очередь приёма одна.
EOF
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Запусти от root: sudo bash $0"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Не найдена команда: $1"
}

default_iface() {
  ip -o -4 route show default 2>/dev/null | awk '{print $5; exit}'
}

sysctl_get() {
  sysctl -n "$1" 2>/dev/null || true
}

rx_queue_count() {
  local iface="$1" n=0 d
  for d in "/sys/class/net/${iface}/queues"/rx-*; do
    [[ -d "$d" ]] || continue
    n=$((n + 1))
  done
  printf '%s' "$n"
}

write_rps_helper() {
  # Логика скопирована из node-accelerator scripts/optimize.sh (na-rps-setup).
  cat >"$RPS_BIN" <<'RPS'
#!/usr/bin/env bash
# Receive/Transmit Packet Steering. На virtio с одной очередью весь RX-softirq
# иначе висит на cpu0. Взято из node-accelerator scripts/optimize.sh.
set -u
want="${1:-}"
sysdir=/sys/class/net

nics=""
if [ -n "$want" ] && [ -d "$sysdir/$want" ]; then
    nics="$want"
else
    [ -n "$want" ] && echo "bridge-tcp-rps: интерфейс '$want' не найден — автодетект" >&2
    i=0
    while [ "$i" -lt 20 ]; do
        nics="$(ip -o -4 route show default 2>/dev/null | awk '{print $5; exit}')"
        if [ -n "$nics" ]; then break; fi
        i=$((i + 1))
        sleep 1
    done
    if [ -z "$nics" ]; then
        for d in "$sysdir"/*/device; do
            [ -e "$d" ] || continue
            n="${d%/device}"; n="${n##*/}"
            case "$n" in lo|veth*|docker*|br-*|wg*) continue;; esac
            nics="${nics:+$nics }$n"
        done
        [ -n "$nics" ] && echo "bridge-tcp-rps: default route не появился за 20с — беру физические: $nics" >&2
    fi
fi

ncpu="$(nproc)"
mask="$(awk -v n="$ncpu" 'BEGIN{
    s=""; while(n>0){ b=(n>=32?32:n); n-=32;
        v=(b>=32?4294967295:(2^b)-1);
        s=(s==""?sprintf("%x",v):sprintf("%x,%s",v,s)); } print (s==""?"0":s) }')"
echo 32768 > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null || true

applied=0
for NIC in $nics; do
    [ -d "$sysdir/$NIC" ] || continue
    for q in "$sysdir/$NIC"/queues/rx-*; do
        [ -e "$q/rps_cpus" ] && echo "$mask" > "$q/rps_cpus" 2>/dev/null || true
        [ -e "$q/rps_flow_cnt" ] && echo 4096 > "$q/rps_flow_cnt" 2>/dev/null || true
    done
    for q in "$sysdir/$NIC"/queues/tx-*; do
        [ -e "$q/xps_cpus" ] && echo "$mask" > "$q/xps_cpus" 2>/dev/null || true
    done
    echo "bridge-tcp-rps: NIC=$NIC mask=$mask cpus=$ncpu"
    applied=1
done

if [ "$applied" -ne 1 ]; then
    echo "bridge-tcp-rps: no usable interface — giving up" >&2
    exit 1
fi
RPS
  chmod 755 "$RPS_BIN"
}

clear_rps() {
  local iface="$1" q
  [[ -n "$iface" && -d "/sys/class/net/${iface}" ]] || return 0
  for q in "/sys/class/net/${iface}/queues"/rx-*; do
    [[ -e "$q/rps_cpus" ]] && printf '0\n' >"$q/rps_cpus" || true
    [[ -e "$q/rps_flow_cnt" ]] && printf '0\n' >"$q/rps_flow_cnt" || true
  done
  for q in "/sys/class/net/${iface}/queues"/tx-*; do
    [[ -e "$q/xps_cpus" ]] && printf '0\n' >"$q/xps_cpus" || true
  done
}

apply_sysctl_key() {
  local key="$1" value="$2"
  sysctl -w "${key}=${value}" >/dev/null
}

cmd_remove() {
  require_root
  if [[ -f "$STATE_PATH" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_PATH"
    apply_sysctl_key net.ipv4.tcp_congestion_control "${SAVED_CC:-cubic}" || true
    apply_sysctl_key net.core.default_qdisc "${SAVED_QDISC:-fq_codel}" || true
    apply_sysctl_key net.ipv4.tcp_slow_start_after_idle "${SAVED_SLOW_START:-1}" || true
    apply_sysctl_key net.ipv4.tcp_mtu_probing "${SAVED_MTU_PROBING:-0}" || true
    apply_sysctl_key net.ipv4.tcp_min_snd_mss "${SAVED_MIN_MSS:-48}" || true
    if [[ "${SAVED_FQ_APPLIED:-0}" == "1" && -n "${SAVED_IFACE:-}" ]]; then
      tc qdisc replace dev "${SAVED_IFACE}" root "${SAVED_ROOT_QDISC:-fq_codel}" >/dev/null 2>&1 || true
    fi
    clear_rps "${SAVED_IFACE:-}"
  fi
  rm -f "$SYSCTL_PATH" "$STATE_PATH" "$RPS_BIN" "$RPS_UNIT"
  systemctl disable --now bridge-tcp-rps.service >/dev/null 2>&1 || true
  systemctl daemon-reload >/dev/null 2>&1 || true
  log "Тюнинг снят. Остальные настройки сервера не трогал."
}

cmd_apply() {
  require_root
  need_cmd ip
  need_cmd sysctl
  need_cmd awk
  need_cmd nproc

  local iface ncpu rxq cc_now qdisc_now slow_now mtu_now mss_now root_qdisc fq_applied rps_applied
  iface="$(default_iface)"
  [[ -n "$iface" ]] || die "Не нашёл интерфейс маршрута по умолчанию."
  [[ -d "/sys/class/net/${iface}" ]] || die "Интерфейса ${iface} нет."

  modprobe tcp_bbr 2>/dev/null || true
  modprobe sch_fq 2>/dev/null || true
  if ! sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
    die "В этом ядре нет BBR. Переключать управление TCP не стал."
  fi

  cc_now="$(sysctl_get net.ipv4.tcp_congestion_control)"
  qdisc_now="$(sysctl_get net.core.default_qdisc)"
  slow_now="$(sysctl_get net.ipv4.tcp_slow_start_after_idle)"
  mtu_now="$(sysctl_get net.ipv4.tcp_mtu_probing)"
  mss_now="$(sysctl_get net.ipv4.tcp_min_snd_mss)"
  root_qdisc="$(tc qdisc show dev "$iface" 2>/dev/null | awk 'NR==1 { print $2; exit }')"

  umask 077
  cat >"$STATE_PATH" <<EOF
SAVED_CC=${cc_now:-cubic}
SAVED_QDISC=${qdisc_now:-fq_codel}
SAVED_SLOW_START=${slow_now:-1}
SAVED_MTU_PROBING=${mtu_now:-0}
SAVED_MIN_MSS=${mss_now:-48}
SAVED_IFACE=${iface}
SAVED_ROOT_QDISC=${root_qdisc:-fq_codel}
SAVED_FQ_APPLIED=0
EOF
  chmod 600 "$STATE_PATH"

  cat >"$SYSCTL_PATH" <<'EOF'
# bridge-tcp-tune: BBR+fq и проба MTU. Остальной sysctl не трогаем.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_min_snd_mss = 512
net.core.rps_sock_flow_entries = 32768
EOF
  chmod 644 "$SYSCTL_PATH"
  sysctl -p "$SYSCTL_PATH" >/dev/null

  fq_applied=0
  if [[ "$root_qdisc" == "mq" ]]; then
    log "На ${iface} несколько очередей (${root_qdisc}), корневую очередь fq не подменяю."
  elif command -v tc >/dev/null 2>&1; then
    if tc qdisc replace dev "$iface" root fq >/dev/null 2>&1; then
      fq_applied=1
      log "На ${iface} включена очередь fq."
    else
      log "Живую очередь на ${iface} сменить не удалось. После ребута возьмётся fq из sysctl."
    fi
  fi
  sed -i "s/^SAVED_FQ_APPLIED=.*/SAVED_FQ_APPLIED=${fq_applied}/" "$STATE_PATH"

  ncpu="$(nproc)"
  rxq="$(rx_queue_count "$iface")"
  rps_applied=0
  if [[ "$ncpu" -le 1 ]]; then
    log "Ядро одно, RPS не нужен."
  elif [[ "$rxq" -gt 1 ]]; then
    log "У ${iface} очередей приёма: ${rxq}. Карта уже раскидывает пакеты, RPS не включаю."
  else
    write_rps_helper
    cat >"$RPS_UNIT" <<EOF
[Unit]
Description=Bridge TCP tune RPS/RFS/XPS
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${RPS_BIN} ${iface}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable bridge-tcp-rps.service >/dev/null 2>&1 || true
    if systemctl restart bridge-tcp-rps.service >/dev/null 2>&1; then
      rps_applied=1
      log "RPS включён на ${iface}: ${ncpu} ядер, очередь приёма одна."
    else
      log "RPS не применился. Журнал: journalctl -u bridge-tcp-rps.service"
    fi
  fi

  echo ""
  log "Готово на ${iface}."
  log "BBR: $(sysctl_get net.ipv4.tcp_congestion_control), очередь по умолчанию: $(sysctl_get net.core.default_qdisc)"
  log "slow_start_after_idle=$(sysctl_get net.ipv4.tcp_slow_start_after_idle), mtu_probing=$(sysctl_get net.ipv4.tcp_mtu_probing), min_snd_mss=$(sysctl_get net.ipv4.tcp_min_snd_mss)"
  if [[ "$rps_applied" == "1" ]]; then
    log "RPS: $(cat "/sys/class/net/${iface}/queues/rx-0/rps_cpus" 2>/dev/null || echo не прочиталось)"
  fi
}

main() {
  case "${1:-}" in
    ""|apply) cmd_apply ;;
    remove|down) cmd_remove ;;
    -h|--help|help) usage ;;
    *) usage; die "Неизвестная команда: $1" ;;
  esac
}

main "$@"
