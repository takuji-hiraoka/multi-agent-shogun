#!/usr/bin/env bash
# scripts/context_all.sh — 全エージェントのコンテキスト使用状況一覧
#
# Usage:
#   bash scripts/context_all.sh
set -euo pipefail

# ─── Collect agent panes (exclude shogun = current session) ───
declare -A AGENT_PANES

while IFS= read -r line; do
    pane=$(echo "$line" | awk '{print $1}')
    agent_id=$(echo "$line" | awk '{print $2}')
    if [[ -n "$agent_id" && "$agent_id" != "shogun" ]]; then
        AGENT_PANES["$agent_id"]="$pane"
    fi
done < <(tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} #{@agent_id}' 2>/dev/null || true)

if [[ ${#AGENT_PANES[@]} -eq 0 ]]; then
    echo "エージェントペインが見つかりません（multiagentセッション未起動?）"
    exit 1
fi

# ─── Send /context to each pane ───
for agent in "${!AGENT_PANES[@]}"; do
    pane="${AGENT_PANES[$agent]}"
    tmux send-keys -t "$pane" '/context' Enter 2>/dev/null || true
done

# ─── Wait for responses ───
sleep 4

# ─── Capture and display ───
printf "\n"
printf "%-14s %-18s %-8s\n" "エージェント" "使用量" "使用率"
printf "%-14s %-18s %-8s\n" "--------------" "------------------" "--------"

for agent in $(echo "${!AGENT_PANES[@]}" | tr ' ' '\n' | sort); do
    pane="${AGENT_PANES[$agent]}"
    # Capture last 50 lines, strip all ANSI escape sequences
    output=$(tmux capture-pane -t "$pane" -p -S -50 2>/dev/null \
        | sed 's/\x1b\[[0-9;]*[A-Za-z]//g' \
        || echo "")

    # Extract "XXk/200k tokens (YY%)" pattern
    usage=$(echo "$output" | grep -oE '[0-9]+(\.[0-9]+)?k/[0-9]+k tokens \([0-9]+%\)' | tail -1 || true)

    if [[ -n "$usage" ]]; then
        tokens=$(echo "$usage" | grep -oE '^[0-9]+(\.[0-9]+)?k/[0-9]+k')
        pct=$(echo "$usage" | grep -oE '\([0-9]+%\)')
        printf "%-14s %-18s %-8s\n" "$agent" "$tokens" "$pct"
    else
        printf "%-14s %-18s %-8s\n" "$agent" "N/A (busy?)" ""
    fi
done

printf "\n"
