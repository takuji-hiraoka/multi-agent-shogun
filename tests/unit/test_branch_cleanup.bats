#!/usr/bin/env bats
# test_branch_cleanup.bats — branch_cleanup.sh unit tests
#
# テスト構成:
#   T-BC-001: gitリポジトリでない → exit 0 (スキップ)
#   T-BC-002: originリモートなし → exit 0 (スキップ)
#   T-BC-003: gh CLIなし → exit 0 (スキップ)
#   T-BC-004: 当日ロックファイルあり → exit 0 (スキップ)
#   T-BC-005: main/masterブランチは削除しない
#   T-BC-006: マージ済みローカルブランチを削除する
#   T-BC-007: マージ済みリモートブランチを削除する
#   T-BC-008: 現在チェックアウト中のブランチは削除しない

SCRIPT="$HOME/.claude/scripts/branch_cleanup.sh"

setup() {
    TEST_TMP="$(mktemp -d)"
    export TEST_TMP

    # 偽gitリポジトリ作成（デフォルト）
    cd "$TEST_TMP" || exit 1
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    touch .gitkeep
    git add .gitkeep
    git commit -q -m "init"

    # mainブランチを確定
    git checkout -q -b main 2>/dev/null || true

    # ロックファイルのprefixを環境変数でオーバーライドできるようにする
    # （実際のスクリプトではリポジトリハッシュを使用）
    REPO_HASH="$(echo "$TEST_TMP" | md5sum | cut -c1-8)"
    TODAY="$(date +%Y%m%d)"
    export LOCK_FILE_PATH="/tmp/branch_cleanup_${TODAY}_${REPO_HASH}"

    # ロックファイルを削除しておく
    rm -f "$LOCK_FILE_PATH"
}

teardown() {
    rm -rf "$TEST_TMP"
    rm -f "$LOCK_FILE_PATH"
}

# ──────────────────────────────────────────────
# T-BC-001: gitリポジトリでない → スキップ
# ──────────────────────────────────────────────
@test "T-BC-001: gitリポジトリでない場合はexitコード0でスキップ" {
    NON_GIT_DIR="$(mktemp -d)"
    cd "$NON_GIT_DIR" || exit 1
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    rm -rf "$NON_GIT_DIR"
}

# ──────────────────────────────────────────────
# T-BC-002: originリモートなし → スキップ
# ──────────────────────────────────────────────
@test "T-BC-002: originリモートなしの場合はexitコード0でスキップ" {
    cd "$TEST_TMP" || exit 1
    # origin不在のgitリポジトリ
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
}

# ──────────────────────────────────────────────
# T-BC-003: gh CLIなし → スキップ
# ──────────────────────────────────────────────
@test "T-BC-003: gh CLIがない場合はexitコード0でスキップ" {
    cd "$TEST_TMP" || exit 1
    # 偽originを追加
    git remote add origin "file://$TEST_TMP" 2>/dev/null || true

    # PATH から gh を除外した状態で実行
    run env PATH="$(echo "$PATH" | tr ':' '\n' | grep -v '/usr/bin$' | paste -sd ':' -)" bash "$SCRIPT"
    [ "$status" -eq 0 ]
}

# ──────────────────────────────────────────────
# T-BC-004: 当日ロックファイルあり → スキップ
# ──────────────────────────────────────────────
@test "T-BC-004: 当日ロックファイルがある場合は実行をスキップ" {
    cd "$TEST_TMP" || exit 1
    git remote add origin "file://$TEST_TMP" 2>/dev/null || true

    # ロックファイルを事前作成
    touch "$LOCK_FILE_PATH"

    # gh をモックしてログを記録
    MOCK_BIN="$(mktemp -d)"
    cat > "$MOCK_BIN/gh" << 'EOF'
#!/bin/bash
echo "gh_called" >> /tmp/gh_called_test
exit 0
EOF
    chmod +x "$MOCK_BIN/gh"

    rm -f /tmp/gh_called_test
    run env PATH="$MOCK_BIN:$PATH" bash "$SCRIPT"
    [ "$status" -eq 0 ]
    # ロックファイルがあるためghは呼ばれない
    [ ! -f /tmp/gh_called_test ]
    rm -rf "$MOCK_BIN"
}

# ──────────────────────────────────────────────
# T-BC-005: main/masterブランチは削除しない
# ──────────────────────────────────────────────
@test "T-BC-005: main/masterブランチはマージ済みでも削除しない" {
    cd "$TEST_TMP" || exit 1
    git remote add origin "file://$TEST_TMP" 2>/dev/null || true

    MOCK_BIN="$(mktemp -d)"
    DELETED_LOG="$TEST_TMP/deleted.log"

    # gh: main と master をマージ済みとして返す
    cat > "$MOCK_BIN/gh" << 'EOF'
#!/bin/bash
echo "main"
echo "master"
EOF
    chmod +x "$MOCK_BIN/gh"

    # git をラップしてbranch -D呼び出しを記録
    cat > "$MOCK_BIN/git" << GITEOF
#!/bin/bash
if [ "\$1" = "branch" ] && [ "\$2" = "-D" ]; then
    echo "DELETE_ATTEMPT:\$3" >> "$DELETED_LOG"
    exit 0
fi
# それ以外は本物のgitを呼ぶ
exec /usr/bin/git "\$@"
GITEOF
    chmod +x "$MOCK_BIN/git"

    run env PATH="$MOCK_BIN:$PATH" bash "$SCRIPT"
    [ "$status" -eq 0 ]

    # main/master削除の試みがないことを確認
    if [ -f "$DELETED_LOG" ]; then
        run grep -c "DELETE_ATTEMPT" "$DELETED_LOG"
        [ "$output" -eq 0 ]
    fi
    rm -rf "$MOCK_BIN"
}

# ──────────────────────────────────────────────
# T-BC-006: マージ済みローカルブランチを削除
# ──────────────────────────────────────────────
@test "T-BC-006: マージ済みのローカルブランチを削除する" {
    cd "$TEST_TMP" || exit 1
    git remote add origin "file://$TEST_TMP" 2>/dev/null || true

    # ローカルブランチを作成
    git checkout -q -b feat/merged-feature
    git checkout -q main

    MOCK_BIN="$(mktemp -d)"
    DELETED_LOG="$TEST_TMP/deleted.log"

    # gh: feat/merged-feature をマージ済みとして返す
    cat > "$MOCK_BIN/gh" << 'EOF'
#!/bin/bash
echo "feat/merged-feature"
EOF
    chmod +x "$MOCK_BIN/gh"

    # git ラッパー: branch -D を記録し実行
    cat > "$MOCK_BIN/git" << GITEOF
#!/bin/bash
if [ "\$1" = "branch" ] && [ "\$2" = "-D" ]; then
    echo "DELETED_LOCAL:\$3" >> "$DELETED_LOG"
    exit 0
fi
exec /usr/bin/git "\$@"
GITEOF
    chmod +x "$MOCK_BIN/git"

    run env PATH="$MOCK_BIN:$PATH" bash "$SCRIPT"
    [ "$status" -eq 0 ]

    # feat/merged-feature が削除されたことを確認
    run grep "DELETED_LOCAL:feat/merged-feature" "$DELETED_LOG"
    [ "$status" -eq 0 ]
    rm -rf "$MOCK_BIN"
}

# ──────────────────────────────────────────────
# T-BC-007: マージ済みリモートブランチを削除
# ──────────────────────────────────────────────
@test "T-BC-007: マージ済みのリモートブランチを削除する" {
    cd "$TEST_TMP" || exit 1
    git remote add origin "file://$TEST_TMP" 2>/dev/null || true

    MOCK_BIN="$(mktemp -d)"
    DELETED_LOG="$TEST_TMP/deleted.log"

    # gh: feat/remote-merged をマージ済みとして返す
    cat > "$MOCK_BIN/gh" << 'EOF'
#!/bin/bash
echo "feat/remote-merged"
EOF
    chmod +x "$MOCK_BIN/gh"

    # git ラッパー: push --delete を記録
    cat > "$MOCK_BIN/git" << GITEOF
#!/bin/bash
if [ "\$1" = "push" ] && [ "\$3" = "--delete" ]; then
    echo "DELETED_REMOTE:\$4" >> "$DELETED_LOG"
    exit 0
fi
# ls-remote --exit-code --heads で存在するように見せる
if [ "\$1" = "ls-remote" ] && [ "\$2" = "--exit-code" ]; then
    echo "abc123\trefs/heads/feat/remote-merged"
    exit 0
fi
exec /usr/bin/git "\$@"
GITEOF
    chmod +x "$MOCK_BIN/git"

    run env PATH="$MOCK_BIN:$PATH" bash "$SCRIPT"
    [ "$status" -eq 0 ]

    # feat/remote-merged がリモートから削除されたことを確認
    run grep "DELETED_REMOTE:feat/remote-merged" "$DELETED_LOG"
    [ "$status" -eq 0 ]
    rm -rf "$MOCK_BIN"
}

# ──────────────────────────────────────────────
# T-BC-008: 現在チェックアウト中のブランチは削除しない
# ──────────────────────────────────────────────
@test "T-BC-008: 現在チェックアウト中のブランチは削除しない" {
    cd "$TEST_TMP" || exit 1
    git remote add origin "file://$TEST_TMP" 2>/dev/null || true

    # feat/current-branch をチェックアウトした状態
    git checkout -q -b feat/current-branch

    MOCK_BIN="$(mktemp -d)"
    DELETED_LOG="$TEST_TMP/deleted.log"

    # gh: feat/current-branch をマージ済みとして返す
    cat > "$MOCK_BIN/gh" << 'EOF'
#!/bin/bash
echo "feat/current-branch"
EOF
    chmod +x "$MOCK_BIN/gh"

    # git ラッパー: branch -D を記録
    cat > "$MOCK_BIN/git" << GITEOF
#!/bin/bash
if [ "\$1" = "branch" ] && [ "\$2" = "-D" ]; then
    echo "DELETED_LOCAL:\$3" >> "$DELETED_LOG"
    exit 0
fi
exec /usr/bin/git "\$@"
GITEOF
    chmod +x "$MOCK_BIN/git"

    run env PATH="$MOCK_BIN:$PATH" bash "$SCRIPT"
    [ "$status" -eq 0 ]

    # 現在のブランチは削除されない
    if [ -f "$DELETED_LOG" ]; then
        run grep "DELETED_LOCAL:feat/current-branch" "$DELETED_LOG"
        [ "$status" -ne 0 ]
    fi
    rm -rf "$MOCK_BIN"
}
