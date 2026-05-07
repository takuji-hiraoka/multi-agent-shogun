#!/bin/bash
# worktree-healthcheck: プロジェクト形式を自動検出して検証フローを実行する
# Usage: healthcheck.sh [worktree_path]

set -euo pipefail

WORKTREE_PATH="${1:-$(pwd)}"

if [[ ! -d "$WORKTREE_PATH" ]]; then
  echo "ERROR: ディレクトリが存在しません: $WORKTREE_PATH" >&2
  exit 1
fi

cd "$WORKTREE_PATH"

BRANCH=$(git branch --show-current 2>/dev/null || echo "(detached)")
START_TIME=$(date +%s)
PATTERN=""
CMD=""
TIMEOUT=600

pre_flight_env_symlink() {
  local main_wt
  main_wt=$(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2; exit}')

  if [[ -z "$main_wt" ]] || [[ "$main_wt" == "$WORKTREE_PATH" ]]; then
    return 0
  fi

  local env_files=(".env/local" ".env.local" ".env.test")
  local symlink_count=0
  local skip_count=0

  for f in "${env_files[@]}"; do
    local src="$main_wt/$f"
    local dst="$WORKTREE_PATH/$f"

    if [[ ! -f "$src" ]] && [[ ! -L "$src" ]]; then
      continue
    fi

    if [[ -e "$dst" ]] || [[ -L "$dst" ]]; then
      ((skip_count++))
      echo "[env-symlink] already_exists: $f"
      continue
    fi

    local dst_dir
    dst_dir=$(dirname "$dst")
    if [[ ! -d "$dst_dir" ]]; then
      mkdir -p "$dst_dir" 2>/dev/null || {
        echo "[env-symlink] WARN: mkdir failed for $dst_dir, skipping $f"
        continue
      }
    fi

    if ln -sf "$src" "$dst" 2>/dev/null; then
      ((symlink_count++))
      echo "[env-symlink] created: $f → $src"
    else
      echo "[env-symlink] WARN: symlink failed for $f"
    fi
  done

  if [[ $symlink_count -eq 0 ]] && [[ $skip_count -eq 0 ]]; then
    echo "[env-symlink] no env files in main worktree to link"
  fi
}

echo "## Pre-flight: .env Symlink"
echo ""
pre_flight_env_symlink
echo ""

# 検出ロジック (priority 1-10)
if [[ -x tools/pre-commit ]]; then
  PATTERN="tools/pre-commit (priority 1)"
  CMD="./tools/pre-commit"
  TIMEOUT=600
elif [[ -f .pre-commit-config.yaml ]] && command -v pre-commit > /dev/null 2>&1; then
  PATTERN=".pre-commit-config.yaml (priority 2)"
  CMD="pre-commit run --all-files"
  TIMEOUT=600
elif [[ -f package.json ]] && command -v jq > /dev/null 2>&1 && jq -e '.scripts.validate' package.json > /dev/null 2>&1; then
  PATTERN="package.json scripts.validate (priority 3)"
  CMD="npm install --silent && npm run validate"
  TIMEOUT=900
elif [[ -f package.json ]] && command -v jq > /dev/null 2>&1 && jq -e '.scripts.test' package.json > /dev/null 2>&1; then
  PATTERN="package.json scripts.test (priority 4)"
  CMD="npm install --silent && npm test"
  TIMEOUT=600
elif [[ -f pyproject.toml ]] && [[ -f uv.lock ]]; then
  PATTERN="pyproject.toml + uv.lock (priority 5)"
  CMD="uv sync && uv run pytest"
  TIMEOUT=900
elif [[ -f pyproject.toml ]] && [[ -f poetry.lock ]]; then
  PATTERN="pyproject.toml + poetry.lock (priority 6)"
  CMD="poetry install && poetry run pytest"
  TIMEOUT=900
elif [[ -f Cargo.toml ]]; then
  PATTERN="Cargo.toml (priority 7)"
  CMD="cargo check && cargo test"
  TIMEOUT=1200
elif [[ -f go.mod ]]; then
  PATTERN="go.mod (priority 8)"
  CMD="go mod download && go test ./..."
  TIMEOUT=600
elif [[ -f Makefile ]] && grep -qE '^(test|check):' Makefile 2>/dev/null; then
  PATTERN="Makefile test target (priority 9)"
  CMD="make test"
  TIMEOUT=600
elif ls tests/*.bats > /dev/null 2>&1; then
  PATTERN="tests/*.bats (priority 10)"
  CMD="bats tests/"
  TIMEOUT=600
else
  echo "## Worktree Healthcheck Result"
  echo ""
  echo "- **worktree path**: $WORKTREE_PATH"
  echo "- **branch**: $BRANCH"
  echo "- **result**: ⚠️ SKIP"
  echo "- **reason**: 検出可能なテストフレームワークが見つかりません"
  echo "- **suggestion**: README.md / CONTRIBUTING.md の \"Test\" セクション、または .github/workflows/*.yml の test job を参照してください"
  exit 0
fi

# 実行
OUTPUT_FILE=$(mktemp)
trap 'rm -f "$OUTPUT_FILE"' EXIT

EXIT_CODE=0
timeout "$TIMEOUT" bash -c "$CMD" > "$OUTPUT_FILE" 2>&1 || EXIT_CODE=$?

DURATION=$(($(date +%s) - START_TIME))

if [[ $EXIT_CODE -eq 0 ]]; then
  RESULT="✅ PASS"
elif [[ $EXIT_CODE -eq 124 ]]; then
  RESULT="❌ FAIL (timeout)"
else
  RESULT="❌ FAIL"
fi

echo "## Worktree Healthcheck Result"
echo ""
echo "- **worktree path**: $WORKTREE_PATH"
echo "- **branch**: $BRANCH"
echo "- **detected pattern**: $PATTERN"
echo "- **executed command**: \`$CMD\`"
echo "- **duration**: ${DURATION}s"
echo "- **result**: $RESULT"

if [[ "$RESULT" == *"FAIL"* ]]; then
  echo ""
  echo "### Output (last 20 lines)"
  echo '```'
  tail -20 "$OUTPUT_FILE"
  echo '```'
  echo ""
  echo "### Diagnostic"
  if grep -qiE "node_modules|Cannot find module|biome: not found|eslint: not found|vitest: not found|package-lock\.json missing|uv\.lock not found" "$OUTPUT_FILE"; then
    echo "**環境起因**の可能性が高い: 依存パッケージが未インストール。"
    echo "npm install / uv sync / cargo build 等の依存解決コマンドを再実行してください。"
    echo ".env / .env.test などの環境変数ファイルが配置されているかも確認してください。"
  elif grep -qiE "permission denied|command not found|exec format error" "$OUTPUT_FILE"; then
    echo "**ツール未インストール**の可能性: 必要なツール（pre-commit/uv/poetry/cargo/go/bats）を導入してください。"
    echo "tools/pre-commit の場合は \`chmod +x tools/pre-commit\` で実行権限を確認してください。"
  elif grep -qiE "TS[0-9]{4}|assertion (fail|error)|AssertionError" "$OUTPUT_FILE"; then
    echo "**ベース起因**の可能性: main ブランチで同じ healthcheck を実行して比較してください。"
    echo "main で PASS → 自 branch の実装問題。main でも FAIL → ベース起因（自 branch の問題ではない）。"
  elif [[ $EXIT_CODE -eq 124 ]]; then
    echo "**タイムアウト**: ${TIMEOUT}s 以内に完了しませんでした。"
    echo "大規模テストスイートの可能性があります。家老に timeout 延長を依頼してください。"
  else
    echo "原因特定には Output セクションの精査が必要です。"
    echo "家老に出力内容を共有して判断を仰いでください。"
  fi
fi

exit 0
