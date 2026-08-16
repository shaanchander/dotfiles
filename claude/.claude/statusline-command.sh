#!/usr/bin/env bash
set -uo pipefail

CACHE_FILE="$HOME/.claude/anthropic-status.txt"
LOCK_FILE="$HOME/.claude/anthropic-status.lock"
STATUS_URL='https://status.claude.com/api/v2/summary.json'
CACHE_MAX_AGE_SEC=180          # refresh the health dot at most every 3 min
IGNORE_INCIDENT='Fable|Mythos' # known-noise incidents to ignore (regex)

mtime_of() { stat -f %m "$1" 2>/dev/null || echo 0; }

# --- Refresh mode: fetch status, classify, write ASCII "level|label" cache ---
if [ "${1:-}" = "--refresh" ]; then
  body=$(curl -fsS --max-time 6 "$STATUS_URL" 2>/dev/null)
  if [ -n "$body" ]; then
    # Walk incidents then components, keeping the highest severity seen. jq
    # mirrors the PowerShell switch: a level only ever ratchets upward.
    out=$(jq -r --arg ignore "$IGNORE_INCIDENT" '
      def bump($lvl; $name):
        if $lvl > .level then {level: $lvl, label: $name} else . end;
      . as $in
      | reduce ($in.incidents[]? | select((.name // "") | test($ignore) | not)) as $i
        ({level: 0, label: ""};
          if   $i.impact == "critical" then bump(2; $i.name)
          elif $i.impact == "major"    then bump(2; $i.name)
          elif $i.impact == "minor"    then bump(1; $i.name)
          else . end)
      | reduce ($in.components[]?) as $c (.;
          if   $c.status == "major_outage"         then bump(2; "\($c.name) outage")
          elif $c.status == "partial_outage"       then bump(2; "\($c.name) partial outage")
          elif $c.status == "degraded_performance" then bump(1; "\($c.name) degraded")
          else . end)
      | "\(.level)|\(.label)"' <<<"$body" 2>/dev/null)
  fi
  printf '%s' "${out:-3|status unavailable}" >"$CACHE_FILE.tmp" \
    && mv "$CACHE_FILE.tmp" "$CACHE_FILE"
  rm -f "$CACHE_FILE.tmp" "$LOCK_FILE"
  exit 0
fi

# --- Render mode ------------------------------------------------------------
raw=$(cat)

model= effort= cwd= pct_raw= win_size= used_tok= h5= d7= h5_reset= d7_reset=
eval "$(jq -r '@sh "model=\(.model.display_name // "")
  effort=\(.effort.level // "")
  cwd=\(.workspace.current_dir // .cwd // "")
  pct_raw=\(.context_window.used_percentage // "")
  win_size=\(.context_window.context_window_size // "")
  used_tok=\(.context_window.total_input_tokens // "")
  h5=\(.rate_limits.five_hour.used_percentage // "")
  h5_reset=\(.rate_limits.five_hour.resets_at // "")
  d7=\(.rate_limits.seven_day.used_percentage // "")
  d7_reset=\(.rate_limits.seven_day.resets_at // "")"' <<<"$raw" 2>/dev/null)"

[ -z "$model" ] && model='?'
# Every model we use is 1M-context now; drop the redundant "(1M context)" suffix
model=$(sed -E 's/[[:space:]]*\([^)]*context[^)]*\)[[:space:]]*$//' <<<"$model")
mtag="$model"                                   # effort absent if model has no effort param
[ -n "$effort" ] && mtag="$model $effort"
dir='?'
[ -n "$cwd" ] && dir=$(basename "$cwd")

pct=0
[ -n "$pct_raw" ] && pct=$(awk -v p="$pct_raw" 'BEGIN{printf "%d", int(p)}' 2>/dev/null)
[ "$pct" -lt 0 ] && pct=0
[ "$pct" -gt 100 ] && pct=100

# Absolute context tokens vs window size (more meaningful than % on the 1M-context model)
fmt_tokens() {
  awk -v n="$1" 'BEGIN{
    if (n >= 1000000) { v = n / 1000000; s = sprintf("%.1f", v); sub(/\.0$/, "", s); printf "%sM", s }
    else if (n >= 1000) { printf "%.0fk", n / 1000 }
    else { printf "%d", n }
  }'
}
ctx_detail=
if [ -n "$win_size" ]; then
  u='?'
  [ -n "$used_tok" ] && u=$(fmt_tokens "$used_tok")
  ctx_detail=" $u/$(fmt_tokens "$win_size")"
fi

# Context bar (block chars kept as literal UTF-8; the terminal is UTF-8 on mac)
block=$'▓'   # full-ish shade
light=$'░'   # light shade
filled=$((pct / 10))
bar=
for ((i = 0; i < filled; i++)); do bar+="$block"; done
for ((i = filled; i < 10; i++)); do bar+="$light"; done

# Color the context bar + % only when it wants attention: yellow 50-79, red 80+.
# Under 50% stays default terminal color.
esc=$'\033'
ctx_color=
if   [ "$pct" -ge 80 ]; then ctx_color="${esc}[31m"
elif [ "$pct" -ge 50 ]; then ctx_color="${esc}[33m"
fi
ctx_reset=
[ -n "$ctx_color" ] && ctx_reset="${esc}[0m"

# --- Anthropic health dot from cache; trigger background refresh if stale ---
# ANSI-tinted dot rather than a colour emoji: same signal, but it sits at text
# weight instead of shouting, and inherits the terminal's palette.
glyph() {
  local dot=$'●'
  case "$1" in
    0) printf '%s[32m%s%s[0m' "$esc" "$dot" "$esc" ;;  # green  - operational
    1) printf '%s[33m%s%s[0m' "$esc" "$dot" "$esc" ;;  # yellow - minor / degraded
    2) printf '%s[31m%s%s[0m' "$esc" "$dot" "$esc" ;;  # red    - major / critical
    *) printf '%s[2m%s%s[0m'  "$esc" "$dot" "$esc" ;;  # dim    - unknown
  esac
}

level=3 label=
if [ -f "$CACHE_FILE" ]; then
  cached=$(tr -d '\r\n' <"$CACHE_FILE" 2>/dev/null)
  head=${cached%%|*}
  case "$head" in
    ''|*[!0-9]*) ;;                 # non-numeric: leave level at 3 (unknown)
    *) level=$head ;;
  esac
  [ "$cached" != "$head" ] && label=${cached#*|}
fi

now=$(date +%s)
cache_stale=1
if [ -f "$CACHE_FILE" ]; then
  [ $((now - $(mtime_of "$CACHE_FILE"))) -gt "$CACHE_MAX_AGE_SEC" ] || cache_stale=0
fi
lock_busy=0
if [ -f "$LOCK_FILE" ]; then
  [ $((now - $(mtime_of "$LOCK_FILE"))) -lt 60 ] && lock_busy=1
fi
if [ "$cache_stale" -eq 1 ] && [ "$lock_busy" -eq 0 ]; then
  : >"$LOCK_FILE"
  ( bash "${BASH_SOURCE[0]}" --refresh >/dev/null 2>&1 & ) &
fi

dot=$(glyph "$level")
health="$dot"
[ -n "$label" ] && [ "$level" -ge 1 ] && health="$dot $label"

# Rate-limit usage (Claude.ai Pro/Max only; absent on most org plans -> segment omitted)
# Reset time shown in parens next to each window's %; epoch is UTC, rendered local.
fmt_reset() {  # epoch, date(1) format
  local epoch="${1%%.*}" fmt="$2" s
  [ -z "$epoch" ] && return
  s=$(date -r "$epoch" +"$fmt" 2>/dev/null) || return
  [ -z "$s" ] && return
  s=${s/AM/am}; s=${s/PM/pm}
  printf ' (%s)' "$s"
}
rl_parts=()
if [ -n "$h5" ]; then
  rl_parts+=("$(awk -v v="$h5" 'BEGIN{printf "5h:%.0f%%", v}')$(fmt_reset "$h5_reset" '%-I:%M%p')")
fi
if [ -n "$d7" ]; then
  rl_parts+=("$(awk -v v="$d7" 'BEGIN{printf "7d:%.0f%%", v}')$(fmt_reset "$d7_reset" '%a %-I:%M%p')")
fi

# Assemble trailing groups separated by pipe dividers so each section scans cleanly
segments=("${ctx_color}${bar} ${pct}%${ctx_detail}${ctx_reset}")
if [ "${#rl_parts[@]}" -gt 0 ]; then
  joined="${rl_parts[0]}"
  for ((i = 1; i < ${#rl_parts[@]}; i++)); do joined+="   ${rl_parts[$i]}"; done
  segments+=("$joined")
fi
segments+=("$health")

line="${segments[0]}"
for ((i = 1; i < ${#segments[@]}; i++)); do line+="  |  ${segments[$i]}"; done
printf '[%s] %s  %s\n' "$mtag" "$dir" "$line"
