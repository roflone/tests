#!/usr/bin/env bash
# Сводка VPS: CPU и диск, скорость, страны по сервисам, Multination.
set -euo pipefail

export LC_ALL=C

if [[ -t 1 ]]; then
  BOLD=$'\033[1m'
  DIM=$'\033[2m'
  RESET=$'\033[0m'
  RED=$'\033[38;5;203m'
  GREEN=$'\033[38;5;114m'
  YELLOW=$'\033[38;5;221m'
  CYAN=$'\033[38;5;117m'
  GRAY=$'\033[38;5;245m'
else
  BOLD="" DIM="" RESET="" RED="" GREEN="" YELLOW="" CYAN="" GRAY=""
fi

if [[ ! -r /proc/stat ]]; then
  printf '%s\n' "Нужен Linux: не найден /proc/stat." >&2
  exit 1
fi

PIDS=()
cleanup() {
  local pid
  for pid in "${PIDS[@]:-}"; do
    kill "$pid" 2>/dev/null || true
  done
  rm -f /tmp/vps-bench-io-$$ /tmp/vps-bench-iperf-$$ /tmp/vps-bench-region-$$ /tmp/vps-bench-multi-$$
}
trap cleanup EXIT INT TERM

LABEL_WIDTH=14

cols() {
  local s="$1" i n=0 code byte
  local len=${#s}
  for ((i = 0; i < len; i++)); do
    byte="${s:i:1}"
    printf -v code '%d' "'$byte" 2>/dev/null || code=0
    if (( code < 0 )); then
      code=$((code + 256))
    fi
    if (( code < 128 || code >= 192 )); then
      n=$((n + 1))
    fi
  done
  printf '%s' "$n"
}

pad_label() {
  local text="$1" width="${2:-$LABEL_WIDTH}" n pad
  n="$(cols "$text")"
  printf '%s' "$text"
  pad=$((width - n))
  (( pad > 0 )) && printf '%*s' "$pad" ''
  return 0
}

pad_right() {
  local text="$1" width="$2" n pad
  n="$(cols "$text")"
  pad=$((width - n))
  (( pad > 0 )) && printf '%*s' "$pad" ''
  printf '%s' "$text"
  return 0
}

section() {
  printf '\n'
  printf '  %s%s%s\n' "$BOLD" "$CYAN" "$1" "$RESET"
  printf '  %s%s%s\n' "$GRAY" "────────────────────────────────────────" "$RESET"
}

note() {
  printf '  %s%s%s\n' "$DIM" "$1" "$RESET"
}

warn() {
  printf '  %s%s%s\n' "$YELLOW" "$1" "$RESET"
}

row() {
  printf '  %s' "$DIM"
  pad_label "$1"
  printf '%s%s\n' "$RESET" "$2"
}

status_line() {
  printf '\r\033[2K  %s%s%s' "$DIM" "$1" "$RESET"
}

ensure_pkg() {
  local cmd="$1" pkg="$2"
  command -v "$cmd" >/dev/null 2>&1 && return 0
  if [[ "$(id -u)" -eq 0 ]] && command -v apt-get >/dev/null 2>&1; then
    note "Ставлю ${pkg}..."
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$pkg" >/dev/null
  fi
  command -v "$cmd" >/dev/null 2>&1
}

strip_ansi() {
  sed -E 's/\x1B\[[0-9;?]*[A-Za-z]//g; s/\r//g'
}

# ── Диск ────────────────────────────────────────────────────────────────────

io_once() {
  (LANG=C dd if=/dev/zero of="/tmp/vps-bench-io-$$" bs=512k count=2048 conv=fdatasync && rm -f "/tmp/vps-bench-io-$$") 2>&1 \
    | awk -F, '{io=$NF} END {print io}' | sed 's/^[ \t]*//;s/[ \t]*$//'
}

io_to_mbs() {
  local raw="$1" num unit
  num="$(printf '%s' "$raw" | awk '{print $1}')"
  unit="$(printf '%s' "$raw" | awk '{print $2}')"
  awk -v n="$num" -v u="$unit" 'BEGIN {
    if (n == "" || n+0 != n) { print ""; exit }
    if (u == "GB/s") n = n * 1024
    else if (u == "kB/s" || u == "KB/s") n = n / 1024
    printf "%.1f", n
  }'
}

disk_line() {
  local free io1 io2 io3 a b c avg
  free="$(df -m /tmp | awk 'NR==2 {print $4}')"
  if [[ -z "$free" || "$free" -le 1024 ]]; then
    warn "Мало места в /tmp, скорость диска не мерял."
    return 0
  fi
  status_line "Диск, прогон 1 из 3"
  io1="$(io_once)"
  status_line "Диск, прогон 2 из 3"
  io2="$(io_once)"
  status_line "Диск, прогон 3 из 3"
  io3="$(io_once)"
  printf '\r\033[2K'
  a="$(io_to_mbs "$io1")"
  b="$(io_to_mbs "$io2")"
  c="$(io_to_mbs "$io3")"
  if [[ -z "$a" || -z "$b" || -z "$c" ]]; then
    warn "Скорость диска не посчиталась."
    return 0
  fi
  avg="$(awk -v a="$a" -v b="$b" -v c="$c" 'BEGIN {printf "%.1f", (a+b+c)/3}')"
  row "Диск" "${avg} MB/s"
}

# ── Скорость ────────────────────────────────────────────────────────────────

iperf_mbps() {
  local file="$1" role="$2" speed
  speed="$(grep '\[SUM\]' "$file" | grep "$role" | awk '{print $6; exit}')"
  if [[ -z "$speed" ]]; then
    speed="$(grep "$role" "$file" | grep 'MBytes' | awk '{sum+=$7} END{print sum}')"
  fi
  printf '%s' "$speed"
}

speed_one() {
  local server="$1" port="$2" name="$3" lat up dl
  ping -c 1 -W 2 "$server" >/dev/null 2>&1 || return 1
  lat="$(ping -c 3 -W 2 "$server" 2>/dev/null | awk -F/ '/avg/ {printf "%.2f", $5; exit}')"
  up=""
  dl=""
  if timeout 25 iperf3 -c "$server" -p "$port" -t 10 -O 3 -f m -P 4 >"/tmp/vps-bench-iperf-$$" 2>/dev/null; then
    up="$(iperf_mbps "/tmp/vps-bench-iperf-$$" sender)"
  fi
  sleep 1
  if timeout 25 iperf3 -c "$server" -p "$port" -t 10 -O 3 -f m -P 4 --reverse >"/tmp/vps-bench-iperf-$$" 2>/dev/null; then
    dl="$(iperf_mbps "/tmp/vps-bench-iperf-$$" receiver)"
  fi
  rm -f "/tmp/vps-bench-iperf-$$"
  [[ -z "$up" || -z "$dl" || "$up" == "0" || "$dl" == "0" ]] && return 1
  printf '\r\033[2K'
  speed_row "$name" "$up" "$dl" "${lat:-n/a}"
}

speed_row() {
  local name="$1" up="$2" dl="$3" lat="$4"
  printf '  '
  pad_label "$name" 22
  printf '%s' "$BOLD"
  pad_right "$up" 7
  printf '%s %sМбит/с%s  ' "$RESET" "$DIM" "$RESET"
  printf '%s' "$BOLD"
  pad_right "$dl" 7
  printf '%s %sМбит/с%s  ' "$RESET" "$DIM" "$RESET"
  if [[ "$lat" == "n/a" ]]; then
    pad_right "$lat" 9
    printf '\n'
  else
    printf '%s' "$BOLD"
    pad_right "$lat" 6
    printf '%s %sмс%s\n' "$RESET" "$DIM" "$RESET"
  fi
}

speed_info() {
  local -a servers=(
    'spd-rudp.hostkey.ru:5201:Moscow, Hostkey'
    'st.spb.ertelecom.ru:5203:SPB, Er-com'
    'mskst.st.mtsws.net:3333:Moscow, MTS'
    'voronezh-speedtest.corbina.net:5203:Voronezh, Beeline'
    'iperf-ams-nl.eranium.net:5201:NL Amsterdam'
    'speedtest.fra1.de.leaseweb.net:5201:DE Frankfurt'
  )
  local item server port name got=0
  section "Скорость"
  if ! ensure_pkg iperf3 iperf3 || ! command -v ping >/dev/null 2>&1; then
    warn "Нет iperf3 или ping, скорость не мерял."
    return 0
  fi
  printf '  %s' "$DIM"
  pad_label "Узел" 22
  pad_right "Отдача" 7
  printf ' Мбит/с  '
  pad_right "Приём" 7
  printf ' Мбит/с  '
  pad_right "Пинг" 6
  printf ' мс%s\n' "$RESET"
  for item in "${servers[@]}"; do
    IFS=':' read -r server port name <<<"$item"
    status_line "Скорость: ${name}"
    if speed_one "$server" "$port" "$name"; then
      got=$((got + 1))
    fi
  done
  printf '\r\033[2K'
  if (( got == 0 )); then
    warn "Скорость не измерилась: ни один узел не ответил."
  fi
}

# ── CPU ─────────────────────────────────────────────────────────────────────

read_cpu() {
  awk '/^cpu / {
    total = 0
    for (i = 2; i <= NF; i++) total += $i
    print total, ($9 + 0)
    exit
  }' /proc/stat
}

bar() {
  local percent="$1" width=22 filled color i
  filled="$(awk -v p="$percent" -v w="$width" 'BEGIN {
    if (p < 0) p = 0
    if (p > 100) p = 100
    printf "%d", p / 100 * w + 0.5
  }')"
  color="$2"
  printf '%s' "$color"
  for ((i = 0; i < filled; i++)); do printf '█'; done
  printf '%s' "$GRAY"
  for ((i = filled; i < width; i++)); do printf '░'; done
  printf '%s' "$RESET"
}

grade_color() {
  case "$1" in
    отлично) printf '%s' "$GREEN" ;;
    хорошо) printf '%s' "$CYAN" ;;
    нормально) printf '%s' "$YELLOW" ;;
    *) printf '%s' "$RED" ;;
  esac
}

spin_test() {
  local threads="$1" seconds="$2" label="$3"
  local outfile pid frames i result
  outfile="$(mktemp)"
  frames=('|' '/' '-' '\')
  i=0
  sysbench cpu --threads="$threads" --time="$seconds" --report-interval=0 run >"$outfile" 2>&1 &
  pid=$!
  PIDS+=("$pid")
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r  %s' "$DIM"
    pad_label "$label"
    printf '%s %s%s%s ' "$RESET" "$CYAN" "${frames[$((i % 4))]}" "$RESET"
    i=$((i + 1))
    sleep 0.12
  done
  wait "$pid"
  PIDS=()
  result="$(awk '/events per second:/ { print $4; exit }' "$outfile")"
  rm -f "$outfile"
  if [[ -z "$result" ]]; then
    printf '\n%s\n' "sysbench не вернул events per second." >&2
    exit 1
  fi
  printf '\r\033[2K'
  RESULT="$result"
}

cpu_info() {
  local single all eff steal eff_grade steal_grade verdict verdict_color
  local steal_a steal_b total_a total_b
  section "CPU"
  row "Процессор" "${CPU_MODEL}"
  row "vCPU" "${VCPU}"
  disk_line
  if ! ensure_pkg sysbench sysbench; then
    warn "Нет sysbench, CPU не мерял."
    return 0
  fi
  printf '\n'
  note "Прогрев ядер..."
  sysbench cpu --threads="$VCPU" --time=3 --report-interval=0 run >/dev/null
  spin_test 1 15 "1 поток"
  single="$RESULT"
  printf '  %s' "$DIM"
  pad_label "1 поток"
  printf '%s%s%10.2f%s оп/с\n' "$RESET" "$BOLD" "$single" "$RESET"
  read -r total_a steal_a < <(read_cpu)
  spin_test "$VCPU" 15 "Все потоки"
  all="$RESULT"
  read -r total_b steal_b < <(read_cpu)
  printf '  %s' "$DIM"
  pad_label "Все потоки"
  printf '%s%s%10.2f%s оп/с\n' "$RESET" "$BOLD" "$all" "$RESET"
  eff="$(awk -v all="$all" -v one="$single" -v cpu="$VCPU" 'BEGIN {
    if (one <= 0 || cpu <= 0) { print "0.0"; exit }
    printf "%.1f", (all / (one * cpu)) * 100
  }')"
  steal="$(awk -v a="$steal_a" -v b="$steal_b" -v ta="$total_a" -v tb="$total_b" 'BEGIN {
    dt = tb - ta
    ds = b - a
    if (dt <= 0 || ds < 0) { print "0.00"; exit }
    printf "%.2f", (ds / dt) * 100
  }')"
  eff_grade="$(awk -v e="$eff" 'BEGIN {
    if (e >= 90) print "отлично"
    else if (e >= 75) print "хорошо"
    else if (e >= 60) print "нормально"
    else print "слабо"
  }')"
  steal_grade="$(awk -v s="$steal" 'BEGIN {
    if (s < 1) print "отлично"
    else if (s < 5) print "нормально"
    else if (s < 10) print "высокая"
    else print "очень высокая"
  }')"
  printf '\n'
  printf '  %s' "$DIM"
  pad_label "Масштаб"
  printf '%s' "$RESET"
  bar "$eff" "$(grade_color "$eff_grade")"
  printf '  %s%6.1f%%%s  %s%s%s\n' "$BOLD" "$eff" "$RESET" "$(grade_color "$eff_grade")" "$eff_grade" "$RESET"
  printf '  %s' "$DIM"
  pad_label "CPU steal"
  printf '%s' "$RESET"
  bar "$steal" "$(grade_color "$steal_grade")"
  printf '  %s%6.2f%%%s  %s%s%s\n' "$BOLD" "$steal" "$RESET" "$(grade_color "$steal_grade")" "$steal_grade" "$RESET"
  verdict="$(awk -v e="$eff" -v s="$steal" 'BEGIN {
    if (e >= 75 && s < 5) print "CPU работает хорошо"
    else if (e >= 60 && s < 10) print "CPU работает нормально"
    else print "с CPU есть проблемы"
  }')"
  verdict_color="$(awk -v e="$eff" -v s="$steal" 'BEGIN {
    if (e >= 75 && s < 5) print "green"
    else if (e >= 60 && s < 10) print "yellow"
    else print "red"
  }')"
  case "$verdict_color" in
    green) verdict_color="$GREEN" ;;
    yellow) verdict_color="$YELLOW" ;;
    *) verdict_color="$RED" ;;
  esac
  printf '\n'
  printf '  %s%s%s%s\n' "$BOLD" "$verdict_color" "$verdict" "$RESET"
}

# ── Страны ──────────────────────────────────────────────────────────────────

col_at() {
  local hay="$1" needle="$2" prefix
  prefix="${hay%%"$needle"*}"
  if [[ "$prefix" == "$hay" ]]; then
    printf '%s' "-1"
  else
    printf '%s' "${#prefix}"
  fi
}

field_slice() {
  local s="$1" start="$2" end="$3" part len
  len="${#s}"
  (( start < 0 )) && start=0
  (( start > len )) && start=$len
  if (( end < 0 || end > len )); then
    end=$len
  fi
  (( end < start )) && end=$start
  part="${s:start:end-start}"
  part="${part#"${part%%[![:space:]]*}"}"
  part="${part%"${part##*[![:space:]]}"}"
  printf '%s' "$part"
}

region_info() {
  local raw table line header name ipv4 ipv6 width=16 n
  local country_at ipv4_at ipv6_at code
  local -a rows=()
  section "Страны по сервисам"
  if ! command -v curl >/dev/null 2>&1; then
    warn "Нет curl, таблицу стран не получил."
    return 0
  fi
  status_line "Спрашиваю сервисы, откуда виден этот IP..."
  if ! curl -fsSL --max-time 30 -A "curl/8.0" "https://ipregion.xyz" -o /tmp/vps-bench-region-$$; then
    printf '\r\033[2K'
    warn "Скрипт стран не скачался."
    return 0
  fi
  raw="$(bash /tmp/vps-bench-region-$$ 2>/dev/null | strip_ansi || true)"
  rm -f /tmp/vps-bench-region-$$
  printf '\r\033[2K'
  table="$(printf '%s\n' "$raw" | awk '
    /^Code[[:space:]]+Country/ { grab=1 }
    grab { print }
    grab && NF==0 { exit }
  ')"
  if [[ -z "$table" ]]; then
    warn "Таблица стран не получена."
    return 0
  fi
  header="$(printf '%s\n' "$table" | awk '/^Code[[:space:]]+Country/ { print; exit }')"
  country_at="$(col_at "$header" "Country")"
  ipv4_at="$(col_at "$header" "% IPv4")"
  [[ "$ipv4_at" == "-1" ]] && ipv4_at="$(col_at "$header" "IPv4")"
  ipv6_at="$(col_at "$header" "% IPv6")"
  [[ "$ipv6_at" == "-1" ]] && ipv6_at="$(col_at "$header" "IPv6")"
  if [[ "$country_at" == "-1" || "$ipv4_at" == "-1" || "$ipv6_at" == "-1" ]]; then
    warn "Таблица стран не разобралась."
    printf '%s\n' "$table" | sed 's/^/  /'
    return 0
  fi
  while IFS= read -r line; do
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "${line// /}" ]] && continue
    [[ "$line" == "$header" ]] && continue
    code="$(field_slice "$line" 0 "$country_at")"
    [[ "$code" =~ ^[A-Za-z]{2}$ ]] || continue
    name="$(field_slice "$line" "$country_at" "$ipv4_at")"
    ipv4="$(field_slice "$line" "$ipv4_at" "$ipv6_at")"
    ipv6="$(field_slice "$line" "$ipv6_at" -1)"
    [[ -z "$name" ]] && name="$code"
    [[ -z "$ipv4" ]] && ipv4="—"
    [[ -z "$ipv6" ]] && ipv6="—"
    n="$(cols "$name")"
    (( n > width )) && width=$n
    rows+=("${name}"$'\t'"${ipv4}"$'\t'"${ipv6}")
  done <<<"$table"
  if (( ${#rows[@]} == 0 )); then
    warn "Таблица стран пустая."
    return 0
  fi
  width=$((width + 2))
  printf '  %s' "$DIM"
  pad_label "Страна" "$width"
  pad_right "IPv4" 8
  printf '  '
  pad_right "IPv6" 8
  printf '%s\n' "$RESET"
  for line in "${rows[@]}"; do
    IFS=$'\t' read -r name ipv4 ipv6 <<<"$line"
    printf '  '
    pad_label "$name" "$width"
    pad_right "$ipv4" 8
    printf '  '
    pad_right "$ipv6" 8
    printf '\n'
  done
}

# ── Multination ─────────────────────────────────────────────────────────────

multi_info() {
  local raw line name rest width=28 n
  section "Multination"
  if ! command -v curl >/dev/null 2>&1; then
    warn "Нет curl, проверку сервисов не запустил."
    return 0
  fi
  status_line "Проверяю сервисы. Это несколько минут."
  if ! curl -fsSL --max-time 60 -L "https://git.io/JRw8R" -o /tmp/vps-bench-multi-$$; then
    printf '\r\033[2K'
    warn "Скрипт проверки сервисов не скачался."
    return 0
  fi
  raw="$(echo 0 | bash /tmp/vps-bench-multi-$$ -E en -M 4 2>/dev/null | strip_ansi | awk '/^=+\[ Multination \]=+$/,/^=+$/' || true)"
  rm -f /tmp/vps-bench-multi-$$
  printf '\r\033[2K'
  if [[ -z "$(printf '%s' "$raw" | tr -d '[:space:]')" ]]; then
    warn "Блок Multination пустой."
    return 0
  fi
  local block="" title
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    if [[ "$line" =~ ^---(.+)---$ ]]; then
      title="${BASH_REMATCH[1]}"
      if [[ "$title" == "Game" ]]; then
        block="game"
      else
        block=""
      fi
      continue
    fi
    [[ "$block" == "game" ]] && continue
    [[ "$line" == *:* ]] || continue
    name="${line%%:*}"
    name="${name%"${name##*[![:space:]]}"}"
    n="$(cols "$name")"
    (( n + 2 > width )) && width=$((n + 2))
  done <<<"$raw"
  block=""
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^=+\ *\[?\ *Multination ]] && continue
    [[ "$line" =~ ^=+$ ]] && continue
    if [[ "$line" =~ ^---(.+)---$ ]]; then
      title="${BASH_REMATCH[1]}"
      if [[ "$title" == "Game" ]]; then
        block="game"
      elif [[ "$title" == "Forum" ]]; then
        block=""
      else
        block=""
        printf '\n  %s%s%s\n' "$CYAN" "$title" "$RESET"
      fi
      continue
    fi
    [[ "$block" == "game" ]] && continue
    if [[ "$line" == *:* ]]; then
      name="${line%%:*}"
      name="${name%"${name##*[![:space:]]}"}"
      rest="${line#*:}"
      rest="${rest#"${rest%%[![:space:]]*}"}"
      printf '  %s' "$DIM"
      pad_label "$name" "$width"
      printf '%s' "$RESET"
      if [[ "$rest" == Yes* || "$rest" == Available* || "$rest" == Unlock* ]]; then
        printf '%s%s%s\n' "$GREEN" "$rest" "$RESET"
      elif [[ "$rest" == No* || "$rest" == Failed* || "$rest" == Banned* ]]; then
        printf '%s%s%s\n' "$RED" "$rest" "$RESET"
      else
        printf '%s\n' "$rest"
      fi
    else
      printf '  %s\n' "$line"
    fi
  done <<<"$raw"
}

want() {
  [[ "$RUN_ALL" == "1" || " ${PICKED} " == *" $1 "* ]]
}

choose() {
  local choice item
  RUN_ALL=0
  PICKED=""
  if [[ ! -r /dev/tty ]]; then
    RUN_ALL=1
    return 0
  fi
  printf '\n'
  printf '  %s%sVPS CHECK%s\n' "$BOLD" "$CYAN" "$RESET"
  printf '  %s%s%s\n' "$GRAY" "────────────────────────────────────────" "$RESET"
  printf '\n'
  printf '  %s%s1%s  всё\n' "$BOLD" "$CYAN" "$RESET"
  printf '  %s2%s  CPU и диск\n' "$DIM" "$RESET"
  printf '  %s3%s  страны\n' "$DIM" "$RESET"
  printf '  %s4%s  Multination\n' "$DIM" "$RESET"
  printf '  %s5%s  скорость\n' "$DIM" "$RESET"
  printf '\n'
  printf '  %sНомера через пробел, Enter — всё:%s ' "$DIM" "$RESET"
  IFS= read -r choice </dev/tty || choice=""
  choice="${choice//,/ }"
  if [[ -z "${choice// /}" || "$choice" == "1" || "$choice" == "0" ]]; then
    RUN_ALL=1
    return 0
  fi
  for item in $choice; do
    case "$item" in
      2) PICKED+=" cpu" ;;
      3) PICKED+=" region" ;;
      4) PICKED+=" multi" ;;
      5) PICKED+=" speed" ;;
      *)
        warn "Не понял «${item}». Запускаю всё."
        RUN_ALL=1
        return 0
        ;;
    esac
  done
}

if [[ -t 1 ]]; then
  clear
fi

choose

if [[ -t 1 ]]; then
  clear
fi

VCPU="$(nproc)"
CPU_MODEL="$(awk -F: '/model name/ { gsub(/^[ \t]+/, "", $2); print $2; exit }' /proc/cpuinfo)"
CPU_MODEL="${CPU_MODEL:-unknown}"

want cpu && cpu_info
want region && region_info
want multi && multi_info
want speed && speed_info
printf '\n'
