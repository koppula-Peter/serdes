#!/usr/bin/env bash
# status.sh — instant session state: git position, dirty files, latest gates.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.."
echo "== GIT =="
git log --oneline -3
git status --short | head -8
echo "== HANDOFF =="
sed -n '/## SESSION HANDOFF/,/^## [^S]/p' CURRENT_WORK.md | head -14
echo "== LATEST GATES =="
grep -h "REGRESSION_RESULT" verification/regressions/latest/*.log 2>/dev/null | tail -4 || echo "(no regression logs yet)"
