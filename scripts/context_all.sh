#!/usr/bin/env bash
# scripts/context_all.sh — 全エージェントのコンテキスト使用状況一覧
#
# Usage:
#   bash scripts/context_all.sh
set -euo pipefail

# ─── Helper: parse context usage from captured pane output ───
# Prints "tokens_str pct_str" (e.g. "123k/200k (12%)") on success, empty on failure.
# Supports k (kilo) and m (mega) units for Opus 4.7+ 1M token windows.
parse_context_usage() {
    local output="$1"
    local usage
    usage=$(printf '%s' "$output" \
        | grep -oE '[0-9]+(\.[0-9]+)?[km]/[0-9]+(\.[0-9]+)?[km] tokens \([0-9]+%\)' \
        | tail -1 || true)
    if [[ -n "$usage" ]]; then
        local tokens pct
        tokens=$(printf '%s' "$usage" | grep -oE '^[0-9]+(\.[0-9]+)?[km]/[0-9]+(\.[0-9]+)?[km]')
        pct=$(printf '%s' "$usage" | grep -oE '\([0-9]+%\)')
        printf '%s %s' "$tokens" "$pct"
    fi
}

# Allow sourcing for unit tests without executing main logic
[[ "${BASH_SOURCE[0]}" != "${0}" ]] && return 0

# ─── Collect agent panes ───
declare -A AGENT_PANES
SHOGUN_PANE=""

while IFS= read -r line; do
    pane=$(echo "$line" | awk '{print $1}')
    agent_id=$(echo "$line" | awk '{print $2}')
    if [[ -n "$agent_id" ]]; then
        if [[ "$agent_id" == "shogun" ]]; then
            SHOGUN_PANE="$pane"
        else
            AGENT_PANES["$agent_id"]="$pane"
        fi
    fi
done < <(tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} #{@agent_id}' 2>/dev/null || true)

if [[ ${#AGENT_PANES[@]} -eq 0 && -z "$SHOGUN_PANE" ]]; then
    echo "エージェントペインが見つかりません（multiagentセッション未起動?）"
    exit 1
fi

# ─── Send /context to non-shogun panes only ───
for agent in "${!AGENT_PANES[@]}"; do
    pane="${AGENT_PANES[$agent]}"
    tmux send-keys -t "$pane" '/context' Enter 2>/dev/null || true
done

# ─── Wait for responses ───
sleep 4

# ─── Capture and display ───
printf "\n"
printf "%-14s %-22s %-8s\n" "エージェント" "使用量" "使用率"
printf "%-14s %-22s %-8s\n" "--------------" "----------------------" "--------"

# shogun: capture-only (no /context sent to avoid self-interruption)
if [[ -n "$SHOGUN_PANE" ]]; then
    output=$(tmux capture-pane -t "$SHOGUN_PANE" -p -S -50 2>/dev/null \
        | sed 's/\x1b\[[0-9;]*[A-Za-z]//g' \
        || echo "")
    result=$(parse_context_usage "$output")
    if [[ -n "$result" ]]; then
        tokens=$(echo "$result" | awk '{print $1}')
        pct=$(echo "$result" | awk '{print $2}')
        printf "%-14s %-22s %-8s\n" "shogun" "$tokens" "$pct"
    else
        printf "%-14s %-22s %-8s\n" "shogun" "N/A (unavailable)" ""
    fi
fi

# other agents: /context was sent; parse failure means still busy
for agent in $(echo "${!AGENT_PANES[@]}" | tr ' ' '\n' | sort); do
    pane="${AGENT_PANES[$agent]}"
    output=$(tmux capture-pane -t "$pane" -p -S -50 2>/dev/null \
        | sed 's/\x1b\[[0-9;]*[A-Za-z]//g' \
        || echo "")
    result=$(parse_context_usage "$output")
    if [[ -n "$result" ]]; then
        tokens=$(echo "$result" | awk '{print $1}')
        pct=$(echo "$result" | awk '{print $2}')
        printf "%-14s %-22s %-8s\n" "$agent" "$tokens" "$pct"
    else
        printf "%-14s %-22s %-8s\n" "$agent" "N/A (busy?)" ""
    fi
done

printf "\n"
