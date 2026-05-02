#!/usr/bin/env bash
# validate_task_yaml.sh — タスクYAML妥当性検証スクリプト
# Usage: bash scripts/validate_task_yaml.sh [file.yaml ...]
# 引数なし: queue/tasks/*.yaml を対象

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# 引数なし → queue/tasks/*.yaml を対象
if [[ $# -eq 0 ]]; then
  set -- "$REPO_ROOT"/queue/tasks/*.yaml
fi

error_count=0

err() {
  echo "[ERROR] $1"
  ((error_count++)) || true
}

warn() {
  echo "[WARN]  $1"
}

# ──────────────────────────────────────────────
# YAMLパーサ: yq 優先、なければ grep/sed フォールバック
# ──────────────────────────────────────────────
get_field() {
  local file="$1"
  local field="$2"
  if command -v yq &>/dev/null; then
    yq e ".task.${field} // .${field}" "$file" 2>/dev/null | grep -v '^null$' || true
  else
    grep -oP "${field}:\s*\K\S+" "$file" 2>/dev/null | head -1 || true
  fi
}

# ──────────────────────────────────────────────
# check1: bloom_level ↔ assigned_to 整合性
# ──────────────────────────────────────────────
check_bloom_assigned_consistency() {
  local file="$1"
  local bloom assigned level

  bloom="$(get_field "$file" "bloom_level")"
  assigned="$(get_field "$file" "assigned_to")"

  # bloom_level 未定義 → WARNING のみ
  if [[ -z "$bloom" ]]; then
    warn "${file}: bloom_level 未定義"
    return 0
  fi

  # assigned_to 未定義 → WARNING のみ
  if [[ -z "$assigned" ]]; then
    warn "${file}: assigned_to 未定義"
    return 0
  fi

  # L数字を抽出
  level="${bloom#L}"

  # L1-L4 かつ assigned_to: karo → ERROR
  if [[ "$level" =~ ^[1-4]$ ]] && [[ "$assigned" == "karo" ]]; then
    err "${file}: bloom_level=${bloom}, assigned_to=${assigned} — L1-L4 タスクは家老でなく足軽に委譲せよ"
    return 0
  fi

  # L5-L6 かつ assigned_to が ashigaru* → ERROR
  if [[ "$level" =~ ^[5-6]$ ]] && [[ "$assigned" == ashigaru* ]]; then
    err "${file}: bloom_level=${bloom}, assigned_to=${assigned} — L5-L6 タスクは足軽でなく軍師に委譲せよ"
    return 0
  fi
}

# ──────────────────────────────────────────────
# check配列（将来 check2〜5 後付け容易な構造）
# ──────────────────────────────────────────────
CHECKS=(check_bloom_assigned_consistency)

# ──────────────────────────────────────────────
# メイン処理
# ──────────────────────────────────────────────
for file in "$@"; do
  [[ -f "$file" ]] || continue
  for check in "${CHECKS[@]}"; do
    "$check" "$file"
  done
done

if [[ $error_count -gt 0 ]]; then
  echo ""
  echo "RESULT: FAIL — ${error_count} 件のエラーを検出"
  exit 1
else
  echo "RESULT: PASS"
  exit 0
fi
