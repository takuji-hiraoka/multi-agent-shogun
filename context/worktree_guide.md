# Worktree-based Task Flow Guide

足軽がgit worktreeを使って独立ブランチで作業するためのガイド。

## 対象タスク
タスクYAMLに `use_worktree: true` が指定されているタスク。

## フロー

1. `EnterWorktree` (name: タスクID) → 独立ブランチ・worktreeに切り替わる
2. 作業実施（ファイル編集、コード変更等）
3. `git status` で確認（git add -f 禁止）
4. mainの最新変更を取り込む（デグレ防止）
   ```bash
   git fetch origin main
   git rebase origin/main   # rebase推奨。コンフリクト時は merge でも可
   ```
5. コミット & push
6. PR作成 (`gh pr create --repo ...`)
7. `ExitWorktree(action: "remove")` → worktree削除・元のディレクトリに戻る

## 注意事項

- `git add -f` 禁止: git管理対象外ファイルを誤コミットする原因
- EnterWorktree後のCWDは `.claude/worktrees/subtask-084a/` になる
- worktreeは各自独立したブランチを持つため、他の足軽と干渉しない
- ExitWorktree(remove)前にコミット漏れがないか確認すること
