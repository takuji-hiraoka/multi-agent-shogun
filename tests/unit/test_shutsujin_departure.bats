#!/usr/bin/env bats
# test_shutsujin_departure.bats — shutsujin_departure.sh オプション解析ユニットテスト
#
# テスト対象: shutsujin_departure.sh の --auto-mode-on / --permission-mode オプション解析
#
# テスト一覧:
#   T-001: --auto-mode-on で PERMISSION_FLAG が --permission-mode auto になること
#   T-002: --auto-mode-on で auto-approved が PERMISSION_FLAG に出現しないこと
#   T-003: 回帰テスト — --permission-mode plan が正しく設定されること
#   T-004: オプションなし → デフォルト --dangerously-skip-permissions になること

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
SCRIPT="$SCRIPT_DIR/shutsujin_departure.sh"

setup_file() {
    [ -f "$SCRIPT" ] || return 1
}

# オプション解析セクションを実際のスクリプトから抽出してサブシェルで実行し
# PERMISSION_FLAG の値を返す
parse_permission_flag() {
    # SETUP_ONLY=false から最初の ^done$ までを抽出（オプション解析ブロック）
    local extract
    extract=$(awk '/^SETUP_ONLY=false/,/^done$/ { print; if (/^done$/) exit }' "$SCRIPT")
    bash -c "${extract}; echo \"\$PERMISSION_FLAG\"" -- "$@"
}

# ─── T-001 ───

@test "T-001: --auto-mode-on sets PERMISSION_FLAG to '--permission-mode auto'" {
    result=$(parse_permission_flag --auto-mode-on)
    [ "$result" = "--permission-mode auto" ]
}

# ─── T-002 ───

@test "T-002: --auto-mode-on does not produce 'auto-approved' in PERMISSION_FLAG" {
    result=$(parse_permission_flag --auto-mode-on)
    [[ "$result" != *"auto-approved"* ]]
}

# ─── T-003 ───

@test "T-003: --permission-mode plan sets PERMISSION_FLAG correctly (regression)" {
    result=$(parse_permission_flag --permission-mode plan)
    [ "$result" = "--permission-mode plan" ]
}

# ─── T-004 ───

@test "T-004: no options → default PERMISSION_FLAG is '--dangerously-skip-permissions'" {
    result=$(parse_permission_flag)
    [ "$result" = "--dangerously-skip-permissions" ]
}
