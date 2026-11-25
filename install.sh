#!/usr/bin/env sh
# SPDX-License-Identifier: MIT OR Apache-2.0
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
TARGET_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/agent"

mkdir -p "$TARGET_DIR"
cp "$SCRIPT_DIR/zsh-os-agent.plugin.zsh" "$TARGET_DIR/zsh-os-agent.plugin.zsh"
cp "$SCRIPT_DIR/agent-sh.zsh" "$TARGET_DIR/agent-sh.zsh"

if [ ! -e "$TARGET_DIR/bash.agent" ]; then
  cp "$SCRIPT_DIR/examples/bash.agent" "$TARGET_DIR/bash.agent"
  chmod 0755 "$TARGET_DIR/bash.agent"
  echo "Installed default agent script to $TARGET_DIR/bash.agent"
else
  echo "Kept existing $TARGET_DIR/bash.agent"
fi

echo "Installed plugin to $TARGET_DIR/zsh-os-agent.plugin.zsh"
echo ""
echo "Add this line near the end of your ~/.zshrc (after autosuggestions/syntax-highlighting):"
echo "  [ -r \"$TARGET_DIR/zsh-os-agent.plugin.zsh\" ] && source \"$TARGET_DIR/zsh-os-agent.plugin.zsh\""
