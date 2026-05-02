#!/usr/bin/env bats
# test_validate_task_yaml.bats — validate_task_yaml.sh unit tests
#
# テスト構成（全7ケース、SKIP=0厳守）:
#   T-VTY-001: 正常系 L3 + ashigaru1 → エラー0、終了コード0
#   T-VTY-002: 正常系 L5 + gunshi → エラー0、終了コード0
#   T-VTY-003: 異常系 L2 + karo → エラー1、終了コード1
#   T-VTY-004: 異常系 L6 + ashigaru3 → エラー1、終了コード1
#   T-VTY-005: 警告系 bloom_level 未定義 → WARN、終了コード0
#   T-VTY-006: 警告系 assigned_to 未定義 → WARN、終了コード0
#   T-VTY-007: 複数ファイル混在 → 終了コード1、違反のみ報告

load "../test_helper/bats-support/load"
load "../test_helper/bats-assert/load"

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
VALIDATE_SCRIPT="$SCRIPT_DIR/scripts/validate_task_yaml.sh"

setup() {
    TEST_TMP="$(mktemp -d)"
}

teardown() {
    rm -rf "$TEST_TMP"
}

# ヘルパー: テスト用YAML作成
make_yaml() {
    local file="$1"
    local bloom="$2"
    local assigned="$3"
    {
        echo "task:"
        [[ -n "$bloom" ]] && echo "  bloom_level: ${bloom}"
        [[ -n "$assigned" ]] && echo "  assigned_to: ${assigned}"
        echo "  status: assigned"
    } > "$file"
}

@test "T-VTY-001: L3 + ashigaru1 → エラー0、終了コード0" {
    make_yaml "$TEST_TMP/normal_l3.yaml" "L3" "ashigaru1"
    run bash "$VALIDATE_SCRIPT" "$TEST_TMP/normal_l3.yaml"
    [ "$status" -eq 0 ]
    refute_output --partial "[ERROR]"
    assert_output --partial "PASS"
}

@test "T-VTY-002: L5 + gunshi → エラー0、終了コード0" {
    make_yaml "$TEST_TMP/normal_l5.yaml" "L5" "gunshi"
    run bash "$VALIDATE_SCRIPT" "$TEST_TMP/normal_l5.yaml"
    [ "$status" -eq 0 ]
    refute_output --partial "[ERROR]"
    assert_output --partial "PASS"
}

@test "T-VTY-003: L2 + karo → エラー1、終了コード1" {
    make_yaml "$TEST_TMP/error_l2_karo.yaml" "L2" "karo"
    run bash "$VALIDATE_SCRIPT" "$TEST_TMP/error_l2_karo.yaml"
    [ "$status" -eq 1 ]
    assert_output --partial "[ERROR]"
    assert_output --partial "L1-L4 タスクは家老でなく足軽に委譲せよ"
}

@test "T-VTY-004: L6 + ashigaru3 → エラー1、終了コード1" {
    make_yaml "$TEST_TMP/error_l6_ashigaru.yaml" "L6" "ashigaru3"
    run bash "$VALIDATE_SCRIPT" "$TEST_TMP/error_l6_ashigaru.yaml"
    [ "$status" -eq 1 ]
    assert_output --partial "[ERROR]"
    assert_output --partial "L5-L6 タスクは足軽でなく軍師に委譲せよ"
}

@test "T-VTY-005: bloom_level 未定義 → WARN、終了コード0" {
    make_yaml "$TEST_TMP/no_bloom.yaml" "" "ashigaru2"
    run bash "$VALIDATE_SCRIPT" "$TEST_TMP/no_bloom.yaml"
    [ "$status" -eq 0 ]
    assert_output --partial "[WARN]"
    assert_output --partial "bloom_level 未定義"
}

@test "T-VTY-006: assigned_to 未定義 → WARN、終了コード0" {
    make_yaml "$TEST_TMP/no_assigned.yaml" "L3" ""
    run bash "$VALIDATE_SCRIPT" "$TEST_TMP/no_assigned.yaml"
    [ "$status" -eq 0 ]
    assert_output --partial "[WARN]"
    assert_output --partial "assigned_to 未定義"
}

@test "T-VTY-007: 複数ファイル混在 → 終了コード1、違反のみ報告" {
    make_yaml "$TEST_TMP/ok.yaml"    "L4" "ashigaru5"
    make_yaml "$TEST_TMP/ng.yaml"    "L3" "karo"
    run bash "$VALIDATE_SCRIPT" "$TEST_TMP/ok.yaml" "$TEST_TMP/ng.yaml"
    [ "$status" -eq 1 ]
    assert_output --partial "[ERROR]"
    assert_output --partial "ng.yaml"
    refute_output --partial "ok.yaml"
}
