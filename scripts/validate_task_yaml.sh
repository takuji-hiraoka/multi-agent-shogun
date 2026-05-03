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

def get_nested(d, keys):
    for k in keys:
        if not isinstance(d, dict):
            return None
        d = d.get(k)
        if d is None:
            return None
    return d

keys = field.split(".")
if task:
    val = get_nested(task, keys)
    if val is None:
        val = get_nested(data, keys)
else:
    val = get_nested(data, keys)

if val is None:
    sys.exit(0)
if isinstance(val, bool):
    print("true" if val else "false")
else:
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
# check2: external_dependency 整合（ERROR）
# ──────────────────────────────────────────────
check_external_dependency_bloom() {
  local file="$1"
  local ext_dep bloom level

  ext_dep="$(get_field "$file" "external_dependency")"
  [[ -z "$ext_dep" || "$ext_dep" == "none" ]] && return 0

  bloom="$(get_field "$file" "bloom_level")"
  [[ -z "$bloom" ]] && return 0

  level="${bloom#L}"
  if [[ "$level" =~ ^[1-3]$ ]]; then
    err "${file}: external_dependency=${ext_dep}, bloom_level=${bloom} — 外部API依存タスクは bloom_level L4+ 必須"
  fi
}

# ──────────────────────────────────────────────
# check3: manual_verification 整合（ERROR）
# ──────────────────────────────────────────────
check_manual_verification() {
  local file="$1"
  local ui_flag mv_required

  ui_flag="$(get_field "$file" "user_facing_ui")"
  [[ "$ui_flag" != "true" ]] && return 0

  mv_required="$(get_field "$file" "manual_verification.required")"
  if [[ -z "$mv_required" || "$mv_required" == "false" ]]; then
    err "${file}: user_facing_ui=true だが manual_verification.required が false/未設定 — UI タスクは手動検証必須"
  fi
}

# ──────────────────────────────────────────────
# check4: spec_citations 欠如警告（WARN）
# ──────────────────────────────────────────────
check_spec_citations() {
  local file="$1"
  local spec_assumptions spec_citations

  spec_assumptions="$(get_field "$file" "spec_assumptions")"
  [[ -z "$spec_assumptions" || "$spec_assumptions" == "[]" || "$spec_assumptions" == "{}" ]] && return 0

  spec_citations="$(get_field "$file" "spec_citations")"
  if [[ -z "$spec_citations" || "$spec_citations" == "[]" || "$spec_citations" == "{}" ]]; then
    warn "${file}: spec_assumptions あり、spec_citations なし — 外部仕様断定文に出典を付与せよ"
  fi
}

# ──────────────────────────────────────────────
# check5: forced_conditions QCタスク確認（WARN）
# ──────────────────────────────────────────────
check_forced_conditions_qc() {
  local file="$1"
  local ext_dep ui_flag gunshi_yaml gunshi_status is_forced

  ext_dep="$(get_field "$file" "external_dependency")"
  ui_flag="$(get_field "$file" "user_facing_ui")"

  is_forced=false
  [[ -n "$ext_dep" && "$ext_dep" != "none" ]] && is_forced=true
  [[ "$ui_flag" == "true" ]] && is_forced=true
  [[ "$is_forced" == "false" ]] && return 0

  gunshi_yaml="${GUNSHI_YAML_PATH:-${REPO_ROOT}/queue/tasks/gunshi.yaml}"
  [[ ! -f "$gunshi_yaml" ]] && return 0

  gunshi_status="$(get_field "$gunshi_yaml" "status")"
  if [[ "$gunshi_status" == "idle" ]]; then
    warn "${file}: forced_conditions 該当タスクだが軍師QCタスクが未アサイン"
  fi
}

# ──────────────────────────────────────────────
# check配列
# ──────────────────────────────────────────────
CHECKS=(check_bloom_assigned_consistency check_external_dependency_bloom check_manual_verification check_spec_citations check_forced_conditions_qc)

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
