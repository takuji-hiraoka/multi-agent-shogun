#!/usr/bin/env bats
# test_stop_hook.bats — stop_hook_inbox.sh unit tests
#
# Calls the REAL production script with env var overrides:
#   __STOP_HOOK_SCRIPT_DIR → points to test temp directory
#   __STOP_HOOK_AGENT_ID   → mocks tmux agent detection
#
# テスト構成:
#   T-HOOK-001: stop_hook_active=true → exit 0
#   T-HOOK-002: agent不明 → exit 0
#   T-HOOK-003: agent_id=shogun → exit 0
#   T-HOOK-004: 完了メッセージ → inbox_writeが呼ばれる (report_completed)
#   T-HOOK-005: エラーメッセージ → inbox_writeが呼ばれる (error_report)
#   T-HOOK-006: 中立メッセージ → inbox_write呼ばれない
#   T-HOOK-007: last_assistant_message空 → inbox_write呼ばれない
#   T-HOOK-008: inbox未読あり → block JSON出力
#   T-HOOK-009: inbox未読なし + 完了メッセージ → exit 0 + 通知あり
#   T-HOOK-010: inbox未読あり + 完了メッセージ → block + 通知あり

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
HOOK_SCRIPT="$SCRIPT_DIR/scripts/stop_hook_inbox.sh"

setup() {
    TEST_TMP="$(mktemp -d)"
    mkdir -p "$TEST_TMP/scripts"
    mkdir -p "$TEST_TMP/queue/inbox"

    # Mock inbox_write.sh — logs arguments to file
    cat > "$TEST_TMP/scripts/inbox_write.sh" << 'MOCK'
#!/bin/bash
echo "$@" >> "$(dirname "$0")/../inbox_write_calls.log"
MOCK
    chmod +x "$TEST_TMP/scripts/inbox_write.sh"
}

teardown() {
    rm -rf "$TEST_TMP"
}

# Helper: run the REAL hook script with test overrides
run_hook() {
    local json="$1"
    local agent_id="${2:-ashigaru1}"
    __STOP_HOOK_SCRIPT_DIR="$TEST_TMP" \
    __STOP_HOOK_AGENT_ID="$agent_id" \
    run bash "$HOOK_SCRIPT" <<< "$json"
}

# Helper: run with no agent ID set
run_hook_no_agent() {
    local json="$1"
    __STOP_HOOK_SCRIPT_DIR="$TEST_TMP" \
    __STOP_HOOK_AGENT_ID="" \
    run bash "$HOOK_SCRIPT" <<< "$json"
}

@test "T-HOOK-001: stop_hook_active=true skips all processing" {
    run_hook '{"stop_hook_active": true, "last_assistant_message": "任務完了"}'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "T-HOOK-002: unknown agent (empty agent_id) exits 0" {
    run_hook_no_agent '{"stop_hook_active": false}'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "T-HOOK-003: shogun agent always exits 0" {
    run_hook '{"stop_hook_active": false, "last_assistant_message": "任務完了"}' "shogun"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "T-HOOK-004: completion message triggers inbox_write to karo" {
    run_hook '{"stop_hook_active": false, "last_assistant_message": "任務完了でござる。report YAML更新済み。"}'
    [ "$status" -eq 0 ]
    [ -f "$TEST_TMP/inbox_write_calls.log" ]
    grep -q "karo" "$TEST_TMP/inbox_write_calls.log"
    grep -q "report_completed" "$TEST_TMP/inbox_write_calls.log"
    grep -q "ashigaru1" "$TEST_TMP/inbox_write_calls.log"
}

@test "T-HOOK-005: error message triggers inbox_write to karo" {
    run_hook '{"stop_hook_active": false, "last_assistant_message": "ファイルが見つからない。エラーで中断する。"}'
    [ "$status" -eq 0 ]
    [ -f "$TEST_TMP/inbox_write_calls.log" ]
    grep -q "karo" "$TEST_TMP/inbox_write_calls.log"
    grep -q "error_report" "$TEST_TMP/inbox_write_calls.log"
}

@test "T-HOOK-006: neutral message does not trigger inbox_write" {
    run_hook '{"stop_hook_active": false, "last_assistant_message": "待機する。次の指示を待つ。"}'
    [ "$status" -eq 0 ]
    [ ! -f "$TEST_TMP/inbox_write_calls.log" ]
}

@test "T-HOOK-007: empty last_assistant_message does not trigger inbox_write" {
    run_hook '{"stop_hook_active": false, "last_assistant_message": ""}'
    [ "$status" -eq 0 ]
    [ ! -f "$TEST_TMP/inbox_write_calls.log" ]
}

@test "T-HOOK-008: unread inbox messages produce block JSON" {
    cat > "$TEST_TMP/queue/inbox/ashigaru1.yaml" << 'YAML'
messages:
  - id: msg_001
    from: karo
    type: task_assigned
    content: "新タスクだ"
    read: false
YAML
    run_hook '{"stop_hook_active": false, "last_assistant_message": ""}'
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"decision"'
    echo "$output" | grep -q '"block"'
}

@test "T-HOOK-009: no unread + completion message exits 0 with notification" {
    cat > "$TEST_TMP/queue/inbox/ashigaru1.yaml" << 'YAML'
messages:
  - id: msg_001
    from: karo
    type: task_assigned
    content: "古いメッセージ"
    read: true
YAML
    run_hook '{"stop_hook_active": false, "last_assistant_message": "タスク完了した。report YAML updated。"}'
    [ "$status" -eq 0 ]
    [ -z "$output" ] || ! echo "$output" | grep -q '"block"'
    [ -f "$TEST_TMP/inbox_write_calls.log" ]
    grep -q "report_completed" "$TEST_TMP/inbox_write_calls.log"
}

@test "T-HOOK-010: unread inbox + completion message blocks AND notifies" {
    cat > "$TEST_TMP/queue/inbox/ashigaru1.yaml" << 'YAML'
messages:
  - id: msg_001
    from: karo
    type: task_assigned
    content: "次のタスク"
    read: false
YAML
    run_hook '{"stop_hook_active": false, "last_assistant_message": "任務完了でござる。"}'
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"block"'
    [ -f "$TEST_TMP/inbox_write_calls.log" ]
    grep -q "report_completed" "$TEST_TMP/inbox_write_calls.log"
}

@test "T-HOOK-011 (S2): no unread + task status=assigned produces block JSON" {
    # Inbox fully read but task not started — stop_hook should block
    mkdir -p "$TEST_TMP/queue/inbox" "$TEST_TMP/queue/tasks"
    cat > "$TEST_TMP/queue/inbox/ashigaru1.yaml" << 'YAML'
messages:
  - id: msg_001
    from: karo
    type: task_assigned
    content: "タスク指示"
    read: true
YAML
    cat > "$TEST_TMP/queue/tasks/ashigaru1.yaml" << 'YAML'
task_id: subtask_test_001
worker_id: ashigaru1
status: assigned
YAML
    run_hook '{"stop_hook_active": false, "last_assistant_message": ""}'
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"decision"'
    echo "$output" | grep -q '"block"'
}

@test "T-HOOK-012 (S2): no unread + task status=done exits 0 (no block)" {
    # Inbox fully read and task is done — normal idle, should not block
    mkdir -p "$TEST_TMP/queue/inbox" "$TEST_TMP/queue/tasks"
    cat > "$TEST_TMP/queue/inbox/ashigaru1.yaml" << 'YAML'
messages:
  - id: msg_001
    from: karo
    type: task_assigned
    content: "タスク指示"
    read: true
YAML
    cat > "$TEST_TMP/queue/tasks/ashigaru1.yaml" << 'YAML'
task_id: subtask_test_002
worker_id: ashigaru1
status: done
YAML
    run_hook '{"stop_hook_active": false, "last_assistant_message": ""}'
    [ "$status" -eq 0 ]
    [ -z "$output" ] || ! echo "$output" | grep -q '"block"'
}

@test "T-HOOK-013 (S2): no unread + no task YAML exits 0 (no block)" {
    # No task YAML exists — normal idle (e.g., agent has no task)
    mkdir -p "$TEST_TMP/queue/inbox" "$TEST_TMP/queue/tasks"
    cat > "$TEST_TMP/queue/inbox/ashigaru1.yaml" << 'YAML'
messages:
  - id: msg_001
    from: karo
    type: task_assigned
    content: "古い完了タスク"
    read: true
YAML
    # task YAMLなし
    run_hook '{"stop_hook_active": false, "last_assistant_message": ""}'
    [ "$status" -eq 0 ]
    [ -z "$output" ] || ! echo "$output" | grep -q '"block"'
}

@test "T-HOOK-014: karo + cmd done + dashboard stale → block with dashboard reminder" {
    # karo が cmd を完了したがdashboard.mdをまだ更新していない場合、ブロックする
    mkdir -p "$TEST_TMP/queue/inbox" "$TEST_TMP/queue/tasks"
    cat > "$TEST_TMP/queue/inbox/karo.yaml" << 'YAML'
messages:
  - id: msg_001
    from: shogun
    type: cmd_new
    content: "テストcmd"
    read: true
YAML
    # dashboard.md を先に作成（古いmtime）
    cat > "$TEST_TMP/dashboard.md" << 'MD'
# 戦況報告
最終更新: 2026-03-28 08:00
MD
    sleep 1
    # cmd task を後から作成（新しいmtime）
    cat > "$TEST_TMP/queue/tasks/cmd_999.yaml" << 'YAML'
task_id: cmd_999
status: done
YAML
    __STOP_HOOK_SCRIPT_DIR="$TEST_TMP" \
    __STOP_HOOK_AGENT_ID="karo" \
    run bash "$HOOK_SCRIPT" <<< '{"stop_hook_active": false, "last_assistant_message": ""}'
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"decision"'
    echo "$output" | grep -q '"block"'
    echo "$output" | grep -q 'dashboard'
}

@test "T-HOOK-015: karo + cmd done + dashboard updated after cmd → dashboard block不発（inbox blockで終了）" {
    # dashboard.md がcmd完了後に更新済みなら、dashboardブロックしない
    # （高速化のため未読inboxを1件追加してinotifywait回避）
    mkdir -p "$TEST_TMP/queue/inbox" "$TEST_TMP/queue/tasks"
    # cmd task を先に作成（古いmtime）
    cat > "$TEST_TMP/queue/tasks/cmd_998.yaml" << 'YAML'
task_id: cmd_998
status: done
YAML
    sleep 1
    # dashboard.md を後から作成（新しいmtime = 更新済み）
    cat > "$TEST_TMP/dashboard.md" << 'MD'
# 戦況報告
最終更新: 2026-03-28 10:00
MD
    # 未読inbox（高速終了用 — dashboardブロックでないことを確認）
    cat > "$TEST_TMP/queue/inbox/karo.yaml" << 'YAML'
messages:
  - id: msg_001
    from: shogun
    type: cmd_new
    content: "次のタスク"
    read: false
YAML
    __STOP_HOOK_SCRIPT_DIR="$TEST_TMP" \
    __STOP_HOOK_AGENT_ID="karo" \
    run bash "$HOOK_SCRIPT" <<< '{"stop_hook_active": false, "last_assistant_message": ""}'
    [ "$status" -eq 0 ]
    # ブロックされるがdashboardの理由ではない（inboxブロック）
    echo "$output" | grep -q '"block"'
    ! echo "$output" | grep -q 'dashboard.md未更新'
}

@test "T-HOOK-016: karo + cmd in_progress (not done) → dashboard block不発（inbox blockで終了）" {
    # cmd が in_progress（完了前）ならdashboardブロックしない
    # （高速化のため未読inboxを1件追加してinotifywait回避）
    mkdir -p "$TEST_TMP/queue/inbox" "$TEST_TMP/queue/tasks"
    cat > "$TEST_TMP/dashboard.md" << 'MD'
# 戦況報告
最終更新: 2026-03-28 08:00
MD
    sleep 1
    cat > "$TEST_TMP/queue/tasks/cmd_997.yaml" << 'YAML'
task_id: cmd_997
status: in_progress
YAML
    cat > "$TEST_TMP/queue/inbox/karo.yaml" << 'YAML'
messages:
  - id: msg_001
    from: shogun
    type: cmd_new
    content: "次のタスク"
    read: false
YAML
    __STOP_HOOK_SCRIPT_DIR="$TEST_TMP" \
    __STOP_HOOK_AGENT_ID="karo" \
    run bash "$HOOK_SCRIPT" <<< '{"stop_hook_active": false, "last_assistant_message": ""}'
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"block"'
    ! echo "$output" | grep -q 'dashboard.md未更新'
}

@test "T-HOOK-017: ashigaru + cmd done + dashboard stale → dashboard block不発（karo専用のため）" {
    # ashigaruはdashboard freshnessチェック対象外
    # （高速化のため未読inboxを1件追加してinotifywait回避）
    mkdir -p "$TEST_TMP/queue/inbox" "$TEST_TMP/queue/tasks"
    cat > "$TEST_TMP/dashboard.md" << 'MD'
# 戦況報告
最終更新: 2026-03-28 08:00
MD
    sleep 1
    cat > "$TEST_TMP/queue/tasks/cmd_996.yaml" << 'YAML'
task_id: cmd_996
status: done
YAML
    cat > "$TEST_TMP/queue/inbox/ashigaru1.yaml" << 'YAML'
messages:
  - id: msg_001
    from: karo
    type: task_assigned
    content: "次のタスク"
    read: false
YAML
    run_hook '{"stop_hook_active": false, "last_assistant_message": ""}' "ashigaru1"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"block"'
    ! echo "$output" | grep -q 'dashboard.md未更新'
}

@test "T-HOOK-018: karo + cmd done today + daily log stale → daily log block" {
    # karo が今日cmdを完了したが logs/daily/YYYY-MM-DD.md が未更新の場合ブロック
    mkdir -p "$TEST_TMP/queue/inbox" "$TEST_TMP/queue/tasks" "$TEST_TMP/logs/daily"
    cat > "$TEST_TMP/queue/inbox/karo.yaml" << 'YAML'
messages:
  - id: msg_001
    from: shogun
    type: cmd_new
    content: "テストcmd"
    read: true
YAML
    # dashboard.md を先に作成（最新 = dashboardチェック通過）
    cat > "$TEST_TMP/queue/tasks/cmd_001.yaml" << 'YAML'
task_id: cmd_001
status: done
YAML
    sleep 1
    cat > "$TEST_TMP/dashboard.md" << 'MD'
# 戦況報告
最終更新: now
MD
    # logs/daily/ は空（daily logなし）= stale
    __STOP_HOOK_SCRIPT_DIR="$TEST_TMP" \
    __STOP_HOOK_AGENT_ID="karo" \
    run bash "$HOOK_SCRIPT" <<< '{"stop_hook_active": false, "last_assistant_message": ""}'
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"decision"'
    echo "$output" | grep -q '"block"'
    echo "$output" | grep -q '日報'
}

@test "T-HOOK-019: karo + cmd done today + daily log updated after cmd → daily log block不発（inbox blockで終了）" {
    # daily log が cmd 完了後に更新済みならブロックしない
    mkdir -p "$TEST_TMP/queue/inbox" "$TEST_TMP/queue/tasks" "$TEST_TMP/logs/daily"
    cat > "$TEST_TMP/queue/tasks/cmd_001.yaml" << 'YAML'
task_id: cmd_001
status: done
YAML
    sleep 1
    TODAY=$(date +%Y-%m-%d)
    cat > "$TEST_TMP/logs/daily/${TODAY}.md" << 'MD'
# 日報
## cmd_001
完了
MD
    sleep 1
    # dashboard も更新済み
    cat > "$TEST_TMP/dashboard.md" << 'MD'
# 戦況報告
最終更新: now
MD
    # 未読inbox（高速終了用 — daily logブロックでないことを確認）
    cat > "$TEST_TMP/queue/inbox/karo.yaml" << 'YAML'
messages:
  - id: msg_001
    from: shogun
    type: cmd_new
    content: "次のタスク"
    read: false
YAML
    __STOP_HOOK_SCRIPT_DIR="$TEST_TMP" \
    __STOP_HOOK_AGENT_ID="karo" \
    run bash "$HOOK_SCRIPT" <<< '{"stop_hook_active": false, "last_assistant_message": ""}'
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"block"'
    ! echo "$output" | grep -q '日報未追記'
}

@test "T-HOOK-020: karo + no logs/daily dir → daily log check スキップ（inbox blockで終了）" {
    # logs/daily/ が存在しない場合は daily log チェックをスキップ
    mkdir -p "$TEST_TMP/queue/inbox" "$TEST_TMP/queue/tasks"
    # logs/daily/ は作らない
    cat > "$TEST_TMP/queue/tasks/cmd_001.yaml" << 'YAML'
task_id: cmd_001
status: done
YAML
    sleep 1
    cat > "$TEST_TMP/dashboard.md" << 'MD'
# 戦況報告
最終更新: now
MD
    cat > "$TEST_TMP/queue/inbox/karo.yaml" << 'YAML'
messages:
  - id: msg_001
    from: shogun
    type: cmd_new
    content: "次のタスク"
    read: false
YAML
    __STOP_HOOK_SCRIPT_DIR="$TEST_TMP" \
    __STOP_HOOK_AGENT_ID="karo" \
    run bash "$HOOK_SCRIPT" <<< '{"stop_hook_active": false, "last_assistant_message": ""}'
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"block"'
    ! echo "$output" | grep -q '日報未追記'
}
