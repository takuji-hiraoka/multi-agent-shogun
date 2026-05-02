#!/usr/bin/env bash
# worktree を含む任意の作業ディレクトリで .venv を自動セットアップする
set -euo pipefail

PROJECT_ROOT="$(git rev-parse --show-toplevel)"

if [ -x "${PROJECT_ROOT}/.venv/bin/python3" ] && \
   "${PROJECT_ROOT}/.venv/bin/python3" -c "import yaml" 2>/dev/null; then
    exit 0
fi

echo "🔧 .venv を作成中: ${PROJECT_ROOT}/.venv"
python3 -m venv "${PROJECT_ROOT}/.venv"

if [ -f "${PROJECT_ROOT}/requirements.txt" ]; then
    "${PROJECT_ROOT}/.venv/bin/pip" install -r "${PROJECT_ROOT}/requirements.txt" -q
fi
