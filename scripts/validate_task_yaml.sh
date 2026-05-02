#!/usr/bin/env bash
# validate_task_yaml.sh — タスクYAML妥当性検証スクリプト
# YAMLパース: .venv/bin/python3 + PyYAML（PR#91 setup_venv 前提）
# Usage: bash scripts/validate_task_yaml.sh [file.yaml ...]
# 引数なし: queue/tasks/*.yaml を対象

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# .venv 不在時は setup_venv.sh を自動呼び出し
VENV_PY="${REPO_ROOT}/.venv/bin/python3"
if [ ! -x "$VENV_PY" ]; then
    bash "${REPO_ROOT}/scripts/setup_venv.sh" >&2
fi

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
# YAMLパーサ: .venv/bin/python3 + PyYAML
# .task.{field} を優先、なければ .{field} を参照（yq ".task.X // .X" と同等）
# ──────────────────────────────────────────────
get_field() {
  local file="$1"
  local field="$2"
  # shellcheck disable=SC2016
  "$VENV_PY" - "$file" "$field" <<'PYEOF' 2>/dev/null || true
import sys, yaml
path, field = sys.argv[1], sys.argv[2]
with open(path) as f:
    data = yaml.safe_load(f) or {}
task = data.get("task") if isinstance(data.get("task"), dict) else None
if task and field in task:
    val = task[field]
else:
    val = data.get(field)
if val is None:
    sys.exit(0)
print(val)
PYEOF
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
