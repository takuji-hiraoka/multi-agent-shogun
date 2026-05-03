# タスクYAML スキーマ定義

## spec_citations フィールド

外部システム仕様の断定文に対する出典・検証参照。

タスクYAML内で外部システム（API / SDK / ブラウザ / OS）の挙動を断定する文言を含む場合に付与する。

```yaml
spec_citations:
  - claim: "存在しないプロパティはエラーにならない"
    source: "https://developers.notion.com/reference/page#property-values"
    verified_at: "2026-04-20"
    verified_by: cmd_XXX  # optional: 検証 cmd 番号
  - claim: "..."
    source: "..."  # URL または "in_task_step:N" でタスク内検証ステップ参照
    verified_at: "..."
```

### フィールド定義

| キー | 必須 | 説明 |
|------|------|------|
| `claim` | ✅ 必須 | 断定文の内容（仕様の主張） |
| `source` | ✅ 必須 | 一次情報源URL、または `"in_task_step:N"`（タスク内検証ステップ参照） |
| `verified_at` | 任意 | 検証日（YYYY-MM-DD） |
| `verified_by` | 任意 | 検証した cmd 番号（例: `cmd_123`） |

### source の記載パターン

| パターン | 例 | 説明 |
|---------|-----|------|
| 公式ドキュメントURL | `"https://example.com/docs/api#section"` | (a) 一次情報源URL |
| cmd参照 | `"cmd_042で実API確認済み"` | (b) 過去の検証 cmd 参照 |
| タスク内検証 | `"in_task_step:3"` | (c) 本タスクの手順3で verify する |

### ルール

- 断定文が複数ある場合は entries を列挙する
- 検証ソースのない断定文は **仮説として明示**し、`source: "in_task_step:N"` でタスク内検証ステップを参照すること
- 既存タスクYAMLへの遡及記述義務はない（Issue #83 導入以降の新規タスクから適用）

### 関連

- 将軍のタスクYAML作成ルール: `instructions/shogun.md` → 外部仕様断定文の検証要件
- 家老のタスクYAML確認義務: `instructions/karo.md` → 外部仕様断定文の検証義務
- 自動検証（断定表現の検出）: `scripts/validate_task_yaml.sh` check4（Issue #90 / Wave 3）で実装予定

## bloom_level 関連フィールド

### external_dependency
外部API/SDK 依存の有無と種類。

```yaml
external_dependency: none | notion_api | github_api | browser_extension | openai_api | ...
# none 以外は bloom_level L4+ 強制。
```

### user_facing_ui
エンドユーザー対面UI（Chrome 拡張、Web UI、デスクトップ UI 等）を含むか。

```yaml
user_facing_ui: true | false
# true なら bloom_level L4+ 強制。
```

### spec_assumptions
検証済みの外部仕様前提のリスト（詳細は spec_citations フィールド: Issue #83 参照）。

```yaml
spec_assumptions: []
# 空なら問題なし。非空なら spec_citations と整合させる。
```

※ 自動検証（external_dependency != none / user_facing_ui: true かつ bloom_level L3 以下の検出）は
  scripts/validate_task_yaml.sh check2-3（Issue #90 / Wave 3）で実装予定。

## manual_verification フィールド

`user_facing_ui: true` のタスクに必須。Chrome拡張・WebアプリなどCIで完全検証できない機能の手動実機確認仕様を定義する。

```yaml
manual_verification:
  required: true | false  # user_facing_ui: true なら強制 true
  cases:
    - id: MV001
      scenario: "正常系"
      expected: "期待する動作"
    - id: MV002
      scenario: "欠如系（プロパティ欠如など）"
      expected: "適切なフォールバック"
    - id: MV003
      scenario: "エラー系（認証エラーなど）"
      expected: "エラーメッセージ表示"
  evidence_required: screenshot | log | recording
```

### フィールド定義

| キー | 必須 | 説明 |
|------|------|------|
| `required` | ✅ 必須 | 実機確認が必要か（`user_facing_ui: true` なら強制 `true`） |
| `cases` | ✅ 必須 | テストケース一覧（最低3件） |
| `evidence_required` | ✅ 必須 | 証跡の種類（`screenshot` / `log` / `recording`） |

各 case の必須キー:

| キー | 必須 | 説明 |
|------|------|------|
| `id` | ✅ 必須 | ケースID（例: `MV001`） |
| `scenario` | ✅ 必須 | テストシナリオの説明 |
| `expected` | ✅ 必須 | 期待する動作 |

### ルール

- `user_facing_ui: true` のタスクは `manual_verification.required: true` 必須
- `cases` は最低3件（正常系・欠如系・エラー系を含むことを推奨）
- 足軽はPR bodyに `## 手動実機確認` セクションを設け、各caseの実施結果と証跡を記載する
- 詳細ルールは `CLAUDE.md` Test Rules 項目6（実機確認ゲート）を参照

### 関連

- 家老の受領義務: `instructions/karo.md` → Rule 6 運用（手動実機確認の発注時義務）
- 足軽の実施義務: `instructions/ashigaru.md` → Rule 6 運用（手動実機確認の実施義務）
- 自動検証は `scripts/validate_task_yaml.sh` check3（Issue #90 / Wave 3）で実装予定
