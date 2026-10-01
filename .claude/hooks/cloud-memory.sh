#!/bin/bash
# Activates the claude-memory-compiler only inside cloud sessions, leaving
# local/desktop sessions untouched (they already run it via ~/.claude/settings.json).
# Usage: cloud-memory.sh <session-start|pre-compact|session-end>
set -e

if [ "$CLAUDE_CODE_REMOTE" != "true" ]; then
  exit 0
fi

TOOL_DIR="$HOME/.cache/claude-memory-compiler"

if [ ! -d "$TOOL_DIR/.git" ]; then
  git clone --depth 1 https://github.com/sbranham314/claude-memory-compiler.git "$TOOL_DIR" >/dev/null 2>&1 || exit 0
  (cd "$TOOL_DIR" && uv sync >/dev/null 2>&1) || true
fi

exec uv run --directory "$TOOL_DIR" python "$TOOL_DIR/hooks/$1.py"
