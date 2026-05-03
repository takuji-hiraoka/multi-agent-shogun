#!/usr/bin/env bats
# test_context_all.bats — scripts/context_all.sh parse_context_usage() ユニットテスト
# Issue #76 (shogun表示) / Issue #95 (Opus 1M検出バグ) の修正検証

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    # Source only (main logic is guarded by BASH_SOURCE check)
    # shellcheck source=/dev/null
    source "$PROJECT_ROOT/scripts/context_all.sh"
}

# ─── parse_context_usage: 標準 k/k 形式 ───

@test "parse: k/k 形式を正しくパースする" {
    local output="Tokens: 123k/200k tokens (61%)"
    result=$(parse_context_usage "$output")
    [[ "$result" == "123k/200k (61%)" ]]
}

@test "parse: 小数点付き k/k 形式をパースする" {
    local output="Context: 1.5k/200k tokens (1%)"
    result=$(parse_context_usage "$output")
    [[ "$result" == "1.5k/200k (1%)" ]]
}

# ─── parse_context_usage: k/m 形式（Opus 4.7 / 1M window） ───

@test "parse: k/m 形式（Opus 1M）を正しくパースする" {
    local output="Context window: 50k/1m tokens (5%)"
    result=$(parse_context_usage "$output")
    [[ "$result" == "50k/1m (5%)" ]]
}

@test "parse: 小数点付き k/m 形式をパースする" {
    local output="Used: 1.2k/1m tokens (0%)"
    result=$(parse_context_usage "$output")
    [[ "$result" == "1.2k/1m (0%)" ]]
}

@test "parse: m/m 形式をパースする" {
    local output="Context: 0.5m/1m tokens (50%)"
    result=$(parse_context_usage "$output")
    [[ "$result" == "0.5m/1m (50%)" ]]
}

# ─── parse_context_usage: マッチしない入力 ───

@test "parse: 空文字列は空を返す" {
    result=$(parse_context_usage "")
    [[ -z "$result" ]]
}

@test "parse: コンテキスト情報のない出力は空を返す" {
    local output="claude is thinking..."
    result=$(parse_context_usage "$output")
    [[ -z "$result" ]]
}

@test "parse: 旧 k のみ形式（k/k 以外）は空を返す" {
    local output="123k/200 tokens (61%)"
    result=$(parse_context_usage "$output")
    [[ -z "$result" ]]
}

# ─── parse_context_usage: 複数行から最後の値を取得 ───

@test "parse: 複数行ある場合は最後のエントリを返す" {
    local output
    output="$(printf '10k/200k tokens (5%%)\n100k/200k tokens (50%%)')"
    result=$(parse_context_usage "$output")
    [[ "$result" == "100k/200k (50%)" ]]
}

# ─── スクリプトがソース可能かつシンタックスエラーなし ───

@test "script: bash -n でシンタックスエラーなし" {
    run bash -n "$PROJECT_ROOT/scripts/context_all.sh"
    [ "$status" -eq 0 ]
}
