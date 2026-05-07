---
name: worktree-healthcheck
description: |
  worktree作成直後にプロジェクトの既存検証フロー（テスト/lint/build/pre-commit等）を
  1回流して「環境起因 Fail」と「仕様起因 Fail」を切り分ける診断スキル。
  npm/uv/poetry/cargo/go/bats/Makefile/pre-commit 等10種のプロジェクト形式を自動検出。
  「worktreeヘルスチェック」「wt検証」「healthcheck」「環境確認」「worktree確認」で起動。
  Do NOT use for: 通常のテスト実行（npm test 等を直接呼べばよい）、CI設定変更、本番環境チェック。
argument-hint: "[worktree_path]"
---

# /worktree-healthcheck — worktree作成直後の検証フロー実行

## 1. Overview — スキルの目的と適用範囲

worktree作成直後に既存の検証フロー（pre-commit/test/build等）を**1回**流して、
後続作業で発生する Fail が「環境起因」なのか「仕様起因（実装上の問題）」なのかを切り分ける診断スキル。

**適用範囲**: WSL2/Linux/Mac 上の git worktree。Bash が使える環境前提。

## 2. When to Use（発火条件・非発火条件）

**発火条件**:
- `git worktree add` した直後（足軽タスクをアサインする前）
- 「環境起因か仕様起因か切り分けたい」とき
- pre-commit が失敗したが原因が不明なとき
- 「worktreeヘルスチェック」「wt検証」「healthcheck」「環境確認」と言われたとき

**Do NOT use for**:
- 通常のテスト実行（`npm test` 等を直接呼べばよい）
- CI設定・ワークフロー変更
- 本番環境のヘルスチェック

## 3. Detection Patterns（10件、priority順）

| priority | 検出ファイル/条件 | 判定条件 | 実行コマンド | timeout |
|---|---|---|---|---|
| 1 | tools/pre-commit | `test -x tools/pre-commit` | `./tools/pre-commit` | 600s |
| 2 | .pre-commit-config.yaml | `test -f` + `command -v pre-commit` | `pre-commit run --all-files` | 600s |
| 3 | package.json (scripts.validate) | `jq -e '.scripts.validate'` | `npm install --silent && npm run validate` | 900s |
| 4 | package.json (scripts.test) | `jq -e '.scripts.test'` | `npm install --silent && npm test` | 600s |
| 5 | pyproject.toml + uv.lock | `test -f` 両方 | `uv sync && uv run pytest` | 900s |
| 6 | pyproject.toml + poetry.lock | `test -f` 両方 | `poetry install && poetry run pytest` | 900s |
| 7 | Cargo.toml | `test -f Cargo.toml` | `cargo check && cargo test` | 1200s |
| 8 | go.mod | `test -f go.mod` | `go mod download && go test ./...` | 600s |
| 9 | Makefile (test target) | `grep -qE '^(test\|check):'` | `make test` | 600s |
| 10 | tests/*.bats | `ls tests/*.bats` | `bats tests/` | 600s |

**No match**: SKIP + suggestion 出力（README / CONTRIBUTING / .github/workflows 参照を促す）

## 4. Decision Rule（複数該当時の優先順位）

priority 順で**最初にマッチしたパターンを採用**。より具体的・網羅的なものを優先。

**例**: my-save2notion worktree で tools/pre-commit と package.json 両方存在する場合
→ priority 1 (tools/pre-commit) を採用。内部で validate を呼び出しているため1コマンドで完結。

## 5. Output Format（Worktree Healthcheck Result 形式）

```
## Worktree Healthcheck Result

- **worktree path**: <絶対パス>
- **branch**: <現在のブランチ名>
- **detected pattern**: <ファイル> (priority N)
- **executed command**: `<実行コマンド>`
- **duration**: <秒数>s
- **result**: ✅ PASS / ❌ FAIL / ⚠️ SKIP
```

失敗時のみ追記:

```
### Output (last 20 lines)
\`\`\`
<stdout/stderr の最後20行>
\`\`\`

### Diagnostic
<失敗起因の切り分け示唆>
```

## 6. Failure Diagnostic（失敗時切り分け指針）

| カテゴリ | 検出キーワード | 推奨アクション |
|---|---|---|
| 環境起因（worktree設定不備） | node_modules, Cannot find module, biome: not found, eslint: not found, vitest: not found | npm install / uv sync 等の依存解決を再実行。.env ファイル確認 |
| ベース起因（main ブランチに同問題） | TS2304, TS2345, assertion fail（複数件） | main ブランチで同 healthcheck 実行して比較。main で PASS → 自 branch の実装問題 |
| ツール未インストール | permission denied, command not found, exec format error | 必要ツール導入（pre-commit/uv/poetry/cargo/go/bats）。chmod +x tools/pre-commit 確認 |
| タイムアウト | duration > timeout_seconds, SIGTERM | 大規模テストスイートの可能性。家老に timeout 延長を依頼 |

## 7. Examples（実行例）

### PASS 例（multi-agent-shogun）

```
## Worktree Healthcheck Result
- worktree path: /home/takuji.hiraoka/work/multi-agent-shogun
- branch: feat/skill-worktree-healthcheck
- detected pattern: tools/pre-commit (priority 1)
- executed command: `./tools/pre-commit`
- duration: 47s
- result: ✅ PASS
```

### FAIL 例（npm 環境起因）

```
## Worktree Healthcheck Result
- worktree path: /home/takuji.hiraoka/work/my-save2notion-wt/issue-XXX
- branch: feat/issue-XXX
- detected pattern: package.json scripts.validate (priority 3)
- executed command: `npm install --silent && npm run validate`
- duration: 32s
- result: ❌ FAIL

### Output (last 20 lines)
\`\`\`
sh: 1: biome: not found
ERR! ELIFECYCLE
\`\`\`

### Diagnostic
環境起因の可能性が高い: node_modules 未インストール、または devDependencies が不足。
`npm install` 再実行を推奨。
```

### SKIP 例（空ディレクトリ）

```
## Worktree Healthcheck Result
- worktree path: /tmp/empty-dir
- branch: (detached)
- result: ⚠️ SKIP
- reason: 検出可能なテストフレームワークが見つかりません
- suggestion: README.md / CONTRIBUTING.md の "Test" セクション参照
```

## 8. Guidelines（軍師・家老が判断する原則）

- worktree作成直後の**1回限定**（毎回流すのは過剰）
- timeout 内に終わらない場合は家老に延長依頼
- main ブランチでも同じ FAIL なら自 branch の問題ではない（ベース起因）
- WSL2 の場合、Windows 側の実行ファイルを参照していないか確認

## Implementation Note

本スキルの実行ロジックは `skills/worktree-healthcheck/scripts/healthcheck.sh` で実装される。
引数なしで実行すると現在ディレクトリを対象とし、パスを渡すと指定 worktree を対象とする。

```bash
# 現在ディレクトリ
bash skills/worktree-healthcheck/scripts/healthcheck.sh

# 別 worktree を指定
bash skills/worktree-healthcheck/scripts/healthcheck.sh /path/to/worktree
```
