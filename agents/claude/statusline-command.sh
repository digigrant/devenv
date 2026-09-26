#!/bin/bash
# Claude Code status line: model | effort | current context | session token totals
input=$(cat)
j() { echo "$input" | jq -r "$1"; }

model=$(j '.model.display_name // "unknown"')
effort=$(j '.effort.level // empty')
size=$(j '.context_window.context_window_size // empty')
pct=$(j '.context_window.used_percentage // empty')
cur=$(j '(.context_window.current_usage // {}) | ((.input_tokens//0)+(.cache_creation_input_tokens//0)+(.cache_read_input_tokens//0))')
tin=$(j '.context_window.total_input_tokens // 0')
tout=$(j '.context_window.total_output_tokens // 0')

fmt() { awk -v n="${1:-0}" 'BEGIN{ if(n>=1e6) printf "%.1fM",n/1e6; else if(n>=1e3) printf "%.1fk",n/1e3; else printf "%d",n }'; }
sep=$'\033[2m | \033[0m'

out=$'\033[36m'"$model"$'\033[0m'
[ -n "$effort" ] && out+="$sep"$'\033[35m'"effort:$effort"$'\033[0m'
if [ -n "$size" ]; then
  ctx="ctx:$(fmt "$cur")/$(fmt "$size")"
  [ -n "$pct" ] && ctx+=" ($(printf '%.0f' "$pct")%)"
  out+="$sep"$'\033[33m'"$ctx"$'\033[0m'
fi
out+="$sep"$'\033[32m'"session: $(fmt "$tin") in / $(fmt "$tout") out"$'\033[0m'
printf '%s' "$out"
