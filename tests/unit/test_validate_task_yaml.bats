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

    # .venv が存在しなければ自動セットアップ（bats 直接実行時も動作するよう保証）
    if [ ! -x "${SCRIPT_DIR}/.venv/bin/python3" ]; then
        bash "${SCRIPT_DIR}/scripts/setup_venv.sh" >/dev/null 2>&1
    fi
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

# ──────────────────────────────────────────────
# check2: external_dependency 整合
# ──────────────────────────────────────────────

@test "T-VTY-008: external_dep=notion_api, L3 → ERROR" {
    cat > "$TEST_TMP/ext_dep_error.yaml" <<'YAML'
task:
  bloom_level: L3
  assigned_to: ashigaru1
  external_dependency: notion_api
  status: assigned
YAML
    run bash "$VALIDATE_SCRIPT" "$TEST_TMP/ext_dep_error.yaml"
    [ "$status" -eq 1 ]
    assert_output --partial "[ERROR]"
    assert_output --partial "外部API依存タスクは bloom_level L4+ 必須"
}

@test "T-VTY-009: external_dep=none, L3 → PASS" {
    cat > "$TEST_TMP/ext_dep_none.yaml" <<'YAML'
task:
  bloom_level: L3
  assigned_to: ashigaru1
  external_dependency: none
  status: assigned
YAML
    run bash "$VALIDATE_SCRIPT" "$TEST_TMP/ext_dep_none.yaml"
    [ "$status" -eq 0 ]
    refute_output --partial "[ERROR]"
    assert_output --partial "PASS"
}

# ──────────────────────────────────────────────
# check3: manual_verification 整合
# ──────────────────────────────────────────────

@test "T-VTY-010: user_facing_ui=true, manual_verification.required=false → ERROR" {
    cat > "$TEST_TMP/mv_false.yaml" <<'YAML'
task:
  bloom_level: L3
  assigned_to: ashigaru1
  user_facing_ui: true
  manual_verification:
    required: false
  status: assigned
YAML
    run bash "$VALIDATE_SCRIPT" "$TEST_TMP/mv_false.yaml"
    [ "$status" -eq 1 ]
    assert_output --partial "[ERROR]"
    assert_output --partial "manual_verification.required が false/未設定"
}

@test "T-VTY-011: user_facing_ui=true, required=true → PASS" {
    cat > "$TEST_TMP/mv_true.yaml" <<'YAML'
task:
  bloom_level: L3
  assigned_to: ashigaru1
  user_facing_ui: true
  manual_verification:
    required: true
  status: assigned
YAML
    run bash "$VALIDATE_SCRIPT" "$TEST_TMP/mv_true.yaml"
    [ "$status" -eq 0 ]
    refute_output --partial "[ERROR]"
    assert_output --partial "PASS"
}

# ──────────────────────────────────────────────
# check4: spec_citations 欠如警告
# ──────────────────────────────────────────────

@test "T-VTY-012: spec_assumptions非空, spec_citations未設定 → WARN" {
    cat > "$TEST_TMP/no_citations.yaml" <<'YAML'
task:
  bloom_level: L3
  assigned_to: ashigaru1
  spec_assumptions:
    - "APIはv2.0以降のみ対応"
  status: assigned
YAML
    run bash "$VALIDATE_SCRIPT" "$TEST_TMP/no_citations.yaml"
    [ "$status" -eq 0 ]
    assert_output --partial "[WARN]"
    assert_output --partial "外部仕様断定文に出典を付与せよ"
}

@test "T-VTY-013: spec_assumptions非空, spec_citations設定 → PASS" {
    cat > "$TEST_TMP/with_citations.yaml" <<'YAML'
task:
  bloom_level: L3
  assigned_to: ashigaru1
  spec_assumptions:
    - "APIはv2.0以降のみ対応"
  spec_citations:
    - "https://example.com/api-docs"
  status: assigned
YAML
    run bash "$VALIDATE_SCRIPT" "$TEST_TMP/with_citations.yaml"
    [ "$status" -eq 0 ]
    refute_output --partial "[ERROR]"
    assert_output --partial "PASS"
}

# ──────────────────────────────────────────────
# check5: forced_conditions QCタスク確認
# ──────────────────────────────────────────────

@test "T-VTY-014: forced_conditions該当, gunshi idle → WARN" {
    cat > "$TEST_TMP/forced.yaml" <<'YAML'
task:
  bloom_level: L4
  assigned_to: ashigaru1
  external_dependency: github_api
  status: assigned
YAML
    cat > "$TEST_TMP/gunshi.yaml" <<'YAML'
task:
  status: idle
YAML
    GUNSHI_YAML_PATH="$TEST_TMP/gunshi.yaml" run bash "$VALIDATE_SCRIPT" "$TEST_TMP/forced.yaml"
    [ "$status" -eq 0 ]
    assert_output --partial "[WARN]"
    assert_output --partial "軍師QCタスクが未アサイン"
}

@test "T-VTY-015: forced_conditions非該当 → PASS（WARNなし）" {
    cat > "$TEST_TMP/not_forced.yaml" <<'YAML'
task:
  bloom_level: L3
  assigned_to: ashigaru1
  external_dependency: none
  user_facing_ui: false
  status: assigned
YAML
    run bash "$VALIDATE_SCRIPT" "$TEST_TMP/not_forced.yaml"
    [ "$status" -eq 0 ]
    refute_output --partial "[WARN]"
    assert_output --partial "PASS"
}
