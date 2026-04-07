#!/usr/bin/env bash
# validate_delegation.sh — bloom_level委譲ルール違反検知スクリプト
#
# Usage: bash scripts/validate_delegation.sh [--report] [--cmd CMD_ID]
#
# チェック項目:
#   1. bloom_level欠如（タスクYAML）
#   2. L1-L4タスクの足軽未委譲（家老直接実行疑い）
#   3. L4以上タスクの軍師QCレポート欠如
#   4. cmdに紐づくサブタスクが0件（家老直接実行疑い）

set -euo pipefail

QUEUE_DIR="$(cd "$(dirname "$0")/.." && pwd)/queue"
TASKS_DIR="$QUEUE_DIR/tasks"
REPORTS_DIR="$QUEUE_DIR/reports"

# Parse args
REPORT_MODE=false
TARGET_CMD=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --report) REPORT_MODE=true; shift ;;
        --cmd) TARGET_CMD="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

violations=0
warnings=0

warn() {
    echo "WARNING: $1"
    ((warnings++)) || true
}

violation() {
    echo "VIOLATION: $1"
    ((violations++)) || true
}

info() {
    echo "INFO: $1"
}

# Extract bloom_level numeric value from a YAML file
get_bloom_level() {
    local file="$1"
    local bl
    bl=$(grep -oP 'bloom_level:\s*L?(\d+)' "$file" 2>/dev/null | grep -oP '\d+' | head -1)
    echo "${bl:-0}"
}

echo "=== bloom_level Delegation Validation ==="
echo "Date: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# --- Check 1: cmd YAMLs without bloom_level ---
echo "--- Check 1: bloom_level presence in cmd YAMLs ---"
for cmd_file in "$TASKS_DIR"/cmd_*.yaml; do
    [[ -f "$cmd_file" ]] || continue
    cmd_id=$(basename "$cmd_file" .yaml)

    # Skip if targeting specific cmd
    [[ -n "$TARGET_CMD" && "$cmd_id" != "$TARGET_CMD" ]] && continue

    if ! grep -q 'bloom_level:' "$cmd_file" 2>/dev/null; then
        warn "$cmd_id: bloom_level フィールドなし"
    fi
done
echo ""

# --- Check 2: cmd assigned_to karo but bloom_level is L1-L4 ---
echo "--- Check 2: L1-L4 tasks assigned to karo (F001 violation) ---"
for cmd_file in "$TASKS_DIR"/cmd_*.yaml; do
    [[ -f "$cmd_file" ]] || continue
    cmd_id=$(basename "$cmd_file" .yaml)

    [[ -n "$TARGET_CMD" && "$cmd_id" != "$TARGET_CMD" ]] && continue

    assigned=$(grep -oP 'assigned_to:\s*(\S+)' "$cmd_file" 2>/dev/null | awk '{print $2}')
    bl=$(get_bloom_level "$cmd_file")

    if [[ "$assigned" == "karo" && "$bl" -ge 1 && "$bl" -le 4 ]]; then
        # Check if there are subtasks for this cmd (ashigaru delegation)
        subtask_count=0
        for ashigaru_file in "$TASKS_DIR"/ashigaru*.yaml; do
            [[ -f "$ashigaru_file" ]] || continue
            if grep -q "parent_cmd: $cmd_id" "$ashigaru_file" 2>/dev/null; then
                ((subtask_count++)) || true
            fi
        done

        if [[ $subtask_count -eq 0 ]]; then
            violation "$cmd_id: bloom_level L$bl (足軽範囲) だが家老に割当済み、サブタスク0件 → F001違反の疑い"
        else
            info "$cmd_id: bloom_level L$bl, 家老割当だがサブタスク${subtask_count}件あり（委譲済み）"
        fi
    fi
done
echo ""

# --- Check 3: L4+ tasks without gunshi QC report ---
echo "--- Check 3: L4+ tasks missing gunshi QC report ---"
for cmd_file in "$TASKS_DIR"/cmd_*.yaml; do
    [[ -f "$cmd_file" ]] || continue
    cmd_id=$(basename "$cmd_file" .yaml)

    [[ -n "$TARGET_CMD" && "$cmd_id" != "$TARGET_CMD" ]] && continue

    status=$(grep -oP 'status:\s*(\S+)' "$cmd_file" 2>/dev/null | awk '{print $2}')
    [[ "$status" != "done" ]] && continue

    bl=$(get_bloom_level "$cmd_file")
    [[ "$bl" -lt 4 ]] && continue

    # Check for QC report
    qc_file="$REPORTS_DIR/${cmd_id}_qc.yaml"
    if [[ ! -f "$qc_file" ]]; then
        violation "$cmd_id: bloom_level L$bl (QC必須) だが軍師QCレポートなし (${cmd_id}_qc.yaml)"
    else
        if ! grep -q 'reviewed_by: gunshi' "$qc_file" 2>/dev/null; then
            violation "$cmd_id: QCレポート存在するが reviewed_by: gunshi がない"
        else
            info "$cmd_id: bloom_level L$bl, 軍師QCレポート確認済み"
        fi
    fi
done
echo ""

# --- Check 4: Done cmds with no subtasks at all ---
echo "--- Check 4: Done cmds with zero subtasks (direct execution) ---"
for cmd_file in "$TASKS_DIR"/cmd_*.yaml; do
    [[ -f "$cmd_file" ]] || continue
    cmd_id=$(basename "$cmd_file" .yaml)

    [[ -n "$TARGET_CMD" && "$cmd_id" != "$TARGET_CMD" ]] && continue

    status=$(grep -oP 'status:\s*(\S+)' "$cmd_file" 2>/dev/null | awk '{print $2}')
    [[ "$status" != "done" ]] && continue

    subtask_count=0
    for ashigaru_file in "$TASKS_DIR"/ashigaru*.yaml "$TASKS_DIR"/subtask_*.yaml; do
        [[ -f "$ashigaru_file" ]] || continue
        if grep -q "parent_cmd: $cmd_id" "$ashigaru_file" 2>/dev/null; then
            ((subtask_count++)) || true
        fi
    done

    # Also check gunshi tasks
    if [[ -f "$TASKS_DIR/gunshi.yaml" ]]; then
        if grep -q "parent_cmd: $cmd_id" "$TASKS_DIR/gunshi.yaml" 2>/dev/null; then
            ((subtask_count++)) || true
        fi
    fi

    if [[ $subtask_count -eq 0 ]]; then
        warn "$cmd_id: 完了済みだがサブタスク0件 → 家老直接実行の可能性"
    fi
done
echo ""

# --- Summary ---
echo "=== Summary ==="
echo "Violations: $violations"
echo "Warnings:   $warnings"

if [[ $violations -gt 0 ]]; then
    echo ""
    echo "RESULT: FAIL — $violations 件の委譲ルール違反を検出"
    exit 1
elif [[ $warnings -gt 0 ]]; then
    echo ""
    echo "RESULT: WARN — 違反なし、$warnings 件の警告あり"
    exit 0
else
    echo ""
    echo "RESULT: PASS — 違反・警告なし"
    exit 0
fi
