#!/usr/bin/env bats
# stop_hook_inbox.bats — stop_hook_inbox.sh ユニットテスト
#
# Issue #25: stop_hook_active=True時のinotifywait削除（stall解消）を検証
#
# テストケース:
#   SH-001: stop_hook_active=True + unread=0 → exit 0（即座）
#   SH-002: stop_hook_active=True + unread>0 → block応答（即座）
#   SH-003: stop_hook_active=True時にinotifywait不使用を確認（コード検査）
#   SH-004: stop_hook_active=False + unread=0 → exit 0（通常パス）
#   SH-005: agent_id未設定 → exit 0（スキップ）

setup_file() {
    export PROJECT_ROOT
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    export STOP_HOOK_SCRIPT="$PROJECT_ROOT/scripts/stop_hook_inbox.sh"
    export VENV_PYTHON="$PROJECT_ROOT/.venv/bin/python3"

    [ -f "$STOP_HOOK_SCRIPT" ] || return 1
    "$VENV_PYTHON" -c "import yaml" 2>/dev/null || return 1
}

setup() {
    export TEST_TMPDIR
    TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/stop_hook_inbox_test.XXXXXX")"

    mkdir -p "$TEST_TMPDIR/queue/inbox"
    mkdir -p "$TEST_TMPDIR/queue/tasks"

    export IDLE_FLAG_DIR="$TEST_TMPDIR/flags"
    mkdir -p "$IDLE_FLAG_DIR"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

# ─── ヘルパー: inbox YAMLを作成 ───
make_inbox() {
    local path="$1"
    local unread_count="$2"
    local read_count="${3:-0}"

    "$VENV_PYTHON" - "$path" "$unread_count" "$read_count" << 'PYEOF'
import sys, yaml
path, unread, read = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
messages = []
for i in range(unread):
    messages.append({
        'id': f'msg_unread_{i}',
        'from': 'karo',
        'timestamp': '2026-03-24T08:00:00',
        'type': 'task_assigned',
        'content': f'unread message {i}',
        'read': False
    })
for i in range(read):
    messages.append({
        'id': f'msg_read_{i}',
        'from': 'karo',
        'timestamp': '2026-03-24T07:00:00',
        'type': 'task_assigned',
        'content': f'read message {i}',
        'read': True
    })
with open(path, 'w') as f:
    yaml.dump({'messages': messages}, f, allow_unicode=True, default_flow_style=False)
PYEOF
}

# =============================================================================
# SH-001: stop_hook_active=True + unread=0 → exit 0（即座）
# =============================================================================

@test "SH-001: stop_hook_active=True, unread=0 → exit 0 immediately" {
    # 全て既読のinboxを作成
    make_inbox "$TEST_TMPDIR/queue/inbox/ashigaru1.yaml" 0 3

    run bash -c "
        export __STOP_HOOK_SCRIPT_DIR='$TEST_TMPDIR'
        export __STOP_HOOK_AGENT_ID='ashigaru1'
        export IDLE_FLAG_DIR='$IDLE_FLAG_DIR'
        printf '%s' '{\"stop_hook_active\": true, \"last_assistant_message\": \"\"}' | bash '$STOP_HOOK_SCRIPT'
    "

    # exit 0 であること
    [ "$status" -eq 0 ]

    # 出力にblockが含まれないこと（exit 0 = approve = no JSON output）
    [[ "$output" != *"block"* ]]

    # idle flagが作成されていること
    [ -f "$IDLE_FLAG_DIR/shogun_idle_ashigaru1" ]
}

# =============================================================================
# SH-002: stop_hook_active=True + unread>0 → block応答（即座）
# =============================================================================

@test "SH-002: stop_hook_active=True, unread>0 → block decision immediately" {
    # 未読2件のinboxを作成
    make_inbox "$TEST_TMPDIR/queue/inbox/ashigaru1.yaml" 2 1

    run bash -c "
        export __STOP_HOOK_SCRIPT_DIR='$TEST_TMPDIR'
        export __STOP_HOOK_AGENT_ID='ashigaru1'
        export IDLE_FLAG_DIR='$IDLE_FLAG_DIR'
        printf '%s' '{\"stop_hook_active\": true, \"last_assistant_message\": \"\"}' | bash '$STOP_HOOK_SCRIPT'
    "

    # exit 0 であること（blockはJSONで返す）
    [ "$status" -eq 0 ]

    # JSON出力にdecision=blockが含まれること
    "$VENV_PYTHON" - "$output" << 'PYEOF'
import json, sys
data = json.loads(sys.argv[1])
assert data['decision'] == 'block', f'Expected block, got {data["decision"]}'
print('SH-002: PASS')
PYEOF

    # idle flagが作成されていること
    [ -f "$IDLE_FLAG_DIR/shogun_idle_ashigaru1" ]
}

# =============================================================================
# SH-003: stop_hook_active=True分岐にinotifywaitが存在しないことを確認（コード検査）
# =============================================================================

@test "SH-003: stop_hook_active=True branch does NOT contain inotifywait call" {
    # stop_hook_active=True 分岐（if [ "$STOP_HOOK_ACTIVE" = "True" ]; then ... fi）を抽出して検査
    # bashのsedでブロックを抽出し、inotifywaitが含まれないことを確認
    run "$VENV_PYTHON" - "$STOP_HOOK_SCRIPT" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()

# STOP_HOOK_ACTIVE=True ブロックを抽出
lines = content.split('\n')
in_block = False
block_lines = []
brace_depth = 0

for line in lines:
    if 'if [ "$STOP_HOOK_ACTIVE" = "True" ]; then' in line:
        in_block = True
        brace_depth = 1
        block_lines.append(line)
        continue
    if in_block:
        block_lines.append(line)
        if line.strip() == 'fi':
            brace_depth -= 1
            if brace_depth <= 0:
                break
        elif line.strip().startswith('if ') or line.strip().startswith('if['):
            brace_depth += 1

block_text = '\n'.join(block_lines)

# コメント行を除外してinotifywait呼び出しがないことを確認
non_comment_lines = [l for l in block_lines if not l.strip().startswith('#')]
non_comment_text = '\n'.join(non_comment_lines)

assert 'inotifywait' not in non_comment_text, \
    f'inotifywait call found in stop_hook_active=True block:\n{non_comment_text}'

# WATCH_TARGETS_ACTIVEが存在しないことを確認（コメント行含む全体）
assert 'WATCH_TARGETS_ACTIVE' not in block_text, \
    f'WATCH_TARGETS_ACTIVE found in stop_hook_active=True block'

print('SH-003: PASS - inotifywait not present in stop_hook_active=True branch')
PYEOF

    [ "$status" -eq 0 ]
}

# =============================================================================
# SH-004: stop_hook_active=False + inbox存在しない → exit 0
# =============================================================================

@test "SH-004: stop_hook_active=False, inbox missing → exit 0" {
    # inboxファイルを作成しない（存在しない状態）

    run bash -c "
        export __STOP_HOOK_SCRIPT_DIR='$TEST_TMPDIR'
        export __STOP_HOOK_AGENT_ID='ashigaru1'
        export IDLE_FLAG_DIR='$IDLE_FLAG_DIR'
        printf '%s' '{\"stop_hook_active\": false, \"last_assistant_message\": \"\"}' | bash '$STOP_HOOK_SCRIPT'
    "

    [ "$status" -eq 0 ]
    [[ "$output" != *"block"* ]]
}

# =============================================================================
# SH-005: agent_id未設定 → exit 0（スキップ）
# =============================================================================

@test "SH-005: AGENT_ID empty → exit 0 (skip hook)" {
    run bash -c "
        export __STOP_HOOK_AGENT_ID=''
        export IDLE_FLAG_DIR='$IDLE_FLAG_DIR'
        printf '%s' '{\"stop_hook_active\": false, \"last_assistant_message\": \"\"}' | bash '$STOP_HOOK_SCRIPT'
    "

    [ "$status" -eq 0 ]
    [[ "$output" != *"block"* ]]
}
