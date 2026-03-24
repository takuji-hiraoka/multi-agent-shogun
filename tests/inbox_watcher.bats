#!/usr/bin/env bats
# inbox_watcher.bats — inbox_watcher.sh の /clear 再起動修正テスト
#
# Tests for Issue #27: /clear後再起動失敗修正（LAST_CLEAR_TS 30→10秒+post-clear nudge）
#
# テスト構成:
#   IW-001: LAST_CLEAR_TS busyガードが10秒であること（5秒後→busy）
#   IW-002: LAST_CLEAR_TS busyガードが10秒であること（10秒後→idle）
#   IW-003: LAST_CLEAR_TS busyガードが10秒であること（15秒後→idle）
#   IW-004: post-clear nudgeコードがclear_sentブロックに存在すること（構造テスト）

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
WATCHER_SCRIPT="$SCRIPT_DIR/scripts/inbox_watcher.sh"

setup_file() {
    export PROJECT_ROOT="$SCRIPT_DIR"
    export VENV_PYTHON="$PROJECT_ROOT/.venv/bin/python3"
    [ -f "$WATCHER_SCRIPT" ] || return 1
    "$VENV_PYTHON" -c "import yaml" 2>/dev/null || return 1
}

setup() {
    export IDLE_FLAG_DIR="$(mktemp -d "$BATS_TMPDIR/iw_test.XXXXXX")"
    export TEST_TMP="$(mktemp -d "$BATS_TMPDIR/iw_hook.XXXXXX")"

    mkdir -p "$TEST_TMP/queue/inbox"

    export WATCHER_HARNESS="$IDLE_FLAG_DIR/watcher_harness.sh"
    export MOCK_LOG="$IDLE_FLAG_DIR/tmux_calls.log"
    > "$MOCK_LOG"

    export MOCK_PGREP="$IDLE_FLAG_DIR/mock_pgrep"
    cat > "$MOCK_PGREP" << 'MOCK'
#!/bin/bash
exit 1
MOCK
    chmod +x "$MOCK_PGREP"

    cat > "$WATCHER_HARNESS" << HARNESS
#!/bin/bash
AGENT_ID="test_clear_agent"
PANE_TARGET="test:0.0"
CLI_TYPE="claude"
INBOX="$TEST_TMP/queue/inbox/test_clear_agent.yaml"
LOCKFILE="\${INBOX}.lock"
SCRIPT_DIR="$PROJECT_ROOT"
export IDLE_FLAG_DIR="$IDLE_FLAG_DIR"

tmux() {
    echo "tmux \$*" >> "$MOCK_LOG"
    if echo "\$*" | grep -q "capture-pane"; then
        echo "\${MOCK_CAPTURE_PANE:-}"
        return 0
    fi
    if echo "\$*" | grep -q "send-keys"; then
        return \${MOCK_SENDKEYS_RC:-0}
    fi
    if echo "\$*" | grep -q "show-options"; then
        echo "\${MOCK_PANE_CLI:-}"
        return 0
    fi
    if echo "\$*" | grep -q "list-clients"; then
        [ -n "\${MOCK_LIST_CLIENTS:-}" ] && echo "\$MOCK_LIST_CLIENTS"
        return 0
    fi
    if echo "\$*" | grep -q "display-message"; then
        echo "mock_session"
        return 0
    fi
    return 0
}
timeout() { shift; "\$@"; }
pgrep() { "$MOCK_PGREP" "\$@"; }
sleep() { :; }
export -f tmux timeout pgrep sleep

export __INBOX_WATCHER_TESTING__=1
source "$WATCHER_SCRIPT"
HARNESS
    chmod +x "$WATCHER_HARNESS"
}

teardown() {
    rm -rf "$IDLE_FLAG_DIR" "$TEST_TMP"
}

# ─── IW-001: /clear送信5秒後 → busyガード内（busy） ───

@test "IW-001: LAST_CLEAR_TS busyガード — 5秒後はbusyを返す（10秒閾値内）" {
    # idle flag を作成（フラグあり=idle扱いだが、cooldownが優先）
    touch "$IDLE_FLAG_DIR/shogun_idle_test_clear_agent"

    run bash -c "
        source '$WATCHER_HARNESS'
        CLI_TYPE='claude'
        now=\$(date +%s)
        LAST_CLEAR_TS=\$((now - 5))  # /clear送信5秒後（10秒cooldown内）
        agent_is_busy
    "
    [ "$status" -eq 0 ]  # 0 = busy
}

# ─── IW-002: /clear送信10秒後 → busyガード境界（idle） ───

@test "IW-002: LAST_CLEAR_TS busyガード — 10秒後はidleを返す（10秒閾値ちょうど）" {
    touch "$IDLE_FLAG_DIR/shogun_idle_test_clear_agent"

    run bash -c "
        source '$WATCHER_HARNESS'
        CLI_TYPE='claude'
        now=\$(date +%s)
        LAST_CLEAR_TS=\$((now - 10))  # /clear送信10秒後（閾値 -lt 10 なのでfalse）
        agent_is_busy
    "
    [ "$status" -eq 1 ]  # 1 = idle (10秒 < 10 はfalseなのでcooldown解除)
}

# ─── IW-003: /clear送信15秒後 → busyガード外（idle） ───

@test "IW-003: LAST_CLEAR_TS busyガード — 15秒後はidleを返す（10秒閾値超過）" {
    touch "$IDLE_FLAG_DIR/shogun_idle_test_clear_agent"

    run bash -c "
        source '$WATCHER_HARNESS'
        CLI_TYPE='claude'
        now=\$(date +%s)
        LAST_CLEAR_TS=\$((now - 15))  # /clear送信15秒後（10秒cooldown超過）
        agent_is_busy
    "
    [ "$status" -eq 1 ]  # 1 = idle
}

# ─── IW-004: post-clear nudgeコードがスクリプトに存在すること ───

@test "IW-004: inbox_watcher.shにpost-clear nudge（sleep 8 + touch + send_wakeup）が実装されている" {
    # clear_sentブロック内にpost-clear nudgeコードが存在することを確認
    grep -q "POST-CLEAR" "$WATCHER_SCRIPT"
    grep -q "sleep 8" "$WATCHER_SCRIPT"
    # idle flag touch（POST-CLEAR専用）
    grep -q 'touch.*IDLE_FLAG_DIR.*AGENT_ID' "$WATCHER_SCRIPT"
    # send_wakeupがpost_clear_countと共に呼ばれる
    grep -q "send_wakeup.*post_clear_count" "$WATCHER_SCRIPT"
}
