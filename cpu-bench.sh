#!/usr/bin/env bash
# Короткий замер CPU на VPS: один поток, все потоки, масштабирование и steal.
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

if ! command -v sysbench >/dev/null 2>&1; then
  if [[ "$(id -u)" -eq 0 ]] && command -v apt-get >/dev/null 2>&1; then
    printf '%s\n' "Ставлю sysbench..."
    apt-get update -qq
    apt-get install -y -qq sysbench >/dev/null
  else
    printf '%s\n' "Не найден sysbench. Установи: apt install sysbench" >&2
    exit 1
  fi
fi

VCPU="$(nproc)"
CPU_MODEL="$(awk -F: '/model name/ { gsub(/^[ \t]+/, "", $2); print $2; exit }' /proc/cpuinfo)"
CPU_MODEL="${CPU_MODEL:-unknown}"

PIDS=()
cleanup() {
  local pid
  for pid in "${PIDS[@]:-}"; do
    kill "$pid" 2>/dev/null || true
  done
}
trap cleanup EXIT INT TERM

read_cpu() {
  awk '/^cpu / {
    total = 0
    for (i = 2; i <= NF; i++) total += $i
    print total, ($9 + 0)
    exit
  }' /proc/stat
}

bar() {
  local percent="$1"
  local width=22
  local filled color i

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
  local threads="$1"
  local seconds="$2"
  local label="$3"
  local outfile pid frames i result

  outfile="$(mktemp)"
  frames=('|' '/' '-' '\')
  i=0

  sysbench cpu --threads="$threads" --time="$seconds" --report-interval=0 run >"$outfile" 2>&1 &
  pid=$!
  PIDS+=("$pid")

  while kill -0 "$pid" 2>/dev/null; do
    printf '\r  %s%-16s%s %s%s%s ' "$DIM" "$label" "$RESET" "$CYAN" "${frames[$((i % 4))]}" "$RESET"
    i=$((i + 1))
    sleep 0.12
  done
  wait "$pid"
  PIDS=()

  result="$(awk '/events per second:/ { print $4; exit }' "$outfile")"
  rm -f "$outfile"
  if [[ -z "$result" ]]; then
    printf '\r%s\n' "sysbench не вернул events per second." >&2
    exit 1
  fi
  printf '\r\033[2K'
  RESULT="$result"
}

line() {
  printf '  %s%-16s%s' "$DIM" "$1" "$RESET"
  shift
  printf '%s\n' "$*"
}

printf '\n'
printf '  %s%sCPU BENCHMARK%s\n' "$BOLD" "$CYAN" "$RESET"
printf '  %s%s%s\n' "$GRAY" "────────────────────────────────────────" "$RESET"
printf '\n'
line "Процессор" "$CPU_MODEL"
line "vCPU" "$VCPU"
printf '\n'
printf '  %sПрогрев ядер...%s\n' "$DIM" "$RESET"
sysbench cpu --threads="$VCPU" --time=3 --report-interval=0 run >/dev/null

spin_test 1 15 "1 поток"
SINGLE="$RESULT"
printf '  %s%-16s%s%s%.2f%s оп/с\n' "$DIM" "1 поток" "$RESET" "$BOLD" "$SINGLE" "$RESET"

read -r STEAL_TOTAL_A STEAL_A < <(read_cpu)
spin_test "$VCPU" 15 "Все потоки"
ALL="$RESULT"
read -r STEAL_TOTAL_B STEAL_B < <(read_cpu)
printf '  %s%-16s%s%s%.2f%s оп/с\n' "$DIM" "Все потоки" "$RESET" "$BOLD" "$ALL" "$RESET"

EFFICIENCY="$(awk -v all="$ALL" -v one="$SINGLE" -v cpu="$VCPU" 'BEGIN {
  if (one <= 0 || cpu <= 0) { print "0.0"; exit }
  printf "%.1f", (all / (one * cpu)) * 100
}')"
STEAL="$(awk -v a="$STEAL_A" -v b="$STEAL_B" -v ta="$STEAL_TOTAL_A" -v tb="$STEAL_TOTAL_B" 'BEGIN {
  dt = tb - ta
  ds = b - a
  if (dt <= 0 || ds < 0) { print "0.00"; exit }
  printf "%.2f", (ds / dt) * 100
}')"

EFF_GRADE="$(awk -v e="$EFFICIENCY" 'BEGIN {
  if (e >= 90) print "отлично"
  else if (e >= 75) print "хорошо"
  else if (e >= 60) print "нормально"
  else print "слабо"
}')"
STEAL_GRADE="$(awk -v s="$STEAL" 'BEGIN {
  if (s < 1) print "отлично"
  else if (s < 5) print "нормально"
  else if (s < 10) print "высокая"
  else print "очень высокая"
}')"

printf '\n'
printf '  %s%-16s%s' "$DIM" "Масштаб" "$RESET"
bar "$EFFICIENCY" "$(grade_color "$EFF_GRADE")"
printf '  %s%s%%%s  %s%s%s\n' "$BOLD" "$EFFICIENCY" "$RESET" "$(grade_color "$EFF_GRADE")" "$EFF_GRADE" "$RESET"

printf '  %s%-16s%s' "$DIM" "CPU steal" "$RESET"
bar "$STEAL" "$(grade_color "$STEAL_GRADE")"
printf '  %s%s%%%s  %s%s%s\n' "$BOLD" "$STEAL" "$RESET" "$(grade_color "$STEAL_GRADE")" "$STEAL_GRADE" "$RESET"

VERDICT="$(awk -v e="$EFFICIENCY" -v s="$STEAL" 'BEGIN {
  if (e >= 75 && s < 5) print "CPU работает хорошо"
  else if (e >= 60 && s < 10) print "CPU работает нормально"
  else print "с CPU есть проблемы"
}')"
VERDICT_COLOR="$(awk -v e="$EFFICIENCY" -v s="$STEAL" 'BEGIN {
  if (e >= 75 && s < 5) print "green"
  else if (e >= 60 && s < 10) print "yellow"
  else print "red"
}')"
case "$VERDICT_COLOR" in
  green) VERDICT_COLOR="$GREEN" ;;
  yellow) VERDICT_COLOR="$YELLOW" ;;
  *) VERDICT_COLOR="$RED" ;;
esac

printf '\n'
printf '  %s%s%s\n' "$GRAY" "────────────────────────────────────────" "$RESET"
printf '  %s%s%s%s\n' "$BOLD" "$VERDICT_COLOR" "$VERDICT" "$RESET"
printf '\n'
printf '  %sМасштаб — насколько все ядра вместе близки к одному, умноженному на число vCPU.%s\n' "$DIM" "$RESET"
printf '  %sSteal — доля времени, которую гипервизор отдал другим виртуалкам во время замера всех потоков.%s\n' "$DIM" "$RESET"
printf '\n'
