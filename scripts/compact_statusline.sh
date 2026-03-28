#!/usr/bin/env bash
# compact_statusline.sh
# ccusage statusline のコンパクト表示ラッパースクリプト
#
# 表示順: 🧠コンテキスト → 🔥バーンレート → 💰コスト(session/today)
# モデル名は非表示（画面幅が狭いペイン向け）
#
# 使用例（~/.claude/settings.json）:
#   "statusLine": {
#     "type": "command",
#     "command": "bash /path/to/scripts/compact_statusline.sh",
#     "padding": 0
#   }

set -euo pipefail

# stdinをccusage statuslineに渡し、出力を取得
stdin_data=$(cat)

if [ -z "$stdin_data" ]; then
  exit 0
fi

full_output=$(echo "$stdin_data" | npx --yes ccusage@latest statusline --offline 2>/dev/null) || true

if [ -z "$full_output" ]; then
  exit 0
fi

# ccusage statuslineの出力フォーマット:
# "🤖 Model | 💰 $S session / $T today / $B block (time) | 🔥 $R/hr | 🧠 N (P%)"
# awk -F ' | ' で4フィールドに分割（ | は正規表現でエスケープ不要）

# コンテキスト（4番目フィールド）
context=$(echo "$full_output" | awk -F '[|]' '{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $4); print $4}')

# バーンレート（3番目フィールド）
burn=$(echo "$full_output" | awk -F '[|]' '{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $3); print $3}')

# コスト（2番目フィールド）からsessionとtodayの金額を抽出
cost_field=$(echo "$full_output" | awk -F '[|]' '{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2}')
session=$(echo "$cost_field" | grep -oP '\$[0-9]+\.[0-9]+(?= session)' || true)
today=$(echo "$cost_field" | grep -oP '\$[0-9]+\.[0-9]+(?= today)' || true)

# 組み立て
if [ -n "$session" ] && [ -n "$today" ]; then
  echo "${context} | ${burn} | 💰 ${session}/${today}"
elif [ -n "$context" ] && [ -n "$burn" ]; then
  # コスト抽出失敗時のフォールバック
  echo "${context} | ${burn}"
else
  # 完全フォールバック: 全出力をそのまま返す
  echo "$full_output"
fi
