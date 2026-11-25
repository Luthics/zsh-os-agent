# zsh-os-agent

Lightweight, zero-intrusion Zsh plugin for [OS Agent](https://github.com/Luthics/os-agent).

`zsh-os-agent` brings natural-language terminal assistance directly into your native Zsh prompt using pure POSIX primitives (`fd 1/2/3/4`, `-c` WAL sessions, and ZLE hooks) — with **zero** built-in LLM SDKs, **0 ms overhead** on normal shell commands, and 100% compatibility with your existing `.zshrc`, aliases, completions, Powerlevel10k, `zsh-autosuggestions`, and `zsh-syntax-highlighting`.

## Features

- **Deterministic Input Routing**
  1. Empty input → native Zsh (`0 ms`).
  2. Explicit `? <query>` or `# <query>` prefix → strips prefix and routes to your default OS Agent script.
  3. Valid shell commands (builtins, aliases, functions, executables in `$PATH`, `./`, `/`, `~/`, `../`, leading `KEY=VAL` env assignments, or shell constructs `(`, `{`, `[[`, `!`, `((`) → native Zsh (`0 ms`).
  4. Everything else (natural language) → seamlessly routed to OS Agent.
- **Per-Terminal Persistent Context (`-c` WAL)**
  - Each Zsh instance gets its own `0600` WAL context (`/tmp/agent-sh-<pid>.ctx.jsonl`), unexported so nested subshells start clean, and automatically cleaned up on `zshexit`.
- **Parent Shell Context via `fd 4` (`<shell_context>`)**
  - Captures recent native commands (`cwd`, `cmd`, `exit_code`) in an in-memory ring buffer (default 10 entries; commands matching `*(API_KEY|SECRET|TOKEN|PASSWORD)*=*` are automatically excluded) and feeds them via `fd 4`.
- **Clean Ephemeral Streaming Display (`fd 1` / `fd 2` / `fd 3`)**
  - Runs the agent with `-q` and `AGENT_TRACE_LEVEL=deltas`, multiplexing stdout (`$AGENT_OUT`), stderr (`$AGENT_ERR`), and structured JSONL trace (`fd 3`).
  - Transient `thinking...` and `executing(<cmd>)` status lines are cleanly erased via `\r\033[K` before any output and on exit — never polluting terminal scrollback.
  - Includes a blank-output safety fallback if a model omits writing to `$AGENT_OUT` in a long session.
- **Safe Parent-Shell State Changes (`$AGENT_PREFILL`)**
  - When an agent needs to mutate the parent shell (`cd`, `export`, etc.), it writes the single command line to `$AGENT_PREFILL`. The plugin prefills your next editable Zsh `BUFFER` so you can review and press Enter.

## Prerequisites

- [OS Agent](https://github.com/Luthics/os-agent) (`agent`, `msh`, and a configured provider in `~/.config/agent/config.toml`)
- Zsh 5.x+ (macOS or Linux)
- Perl (standard on macOS and almost all Linux distros, used for `IO::Select` non-blocking FD multiplexing)

## Installation

### Quick Local Install

```sh
git clone https://github.com/Luthics/zsh-os-agent.git
cd zsh-os-agent
./install.sh
```

Then add the following line **near the end of `~/.zshrc`** (after `zsh-autosuggestions` and `zsh-syntax-highlighting`):

```zsh
[ -r "$HOME/.config/agent/zsh-os-agent.plugin.zsh" ] && source "$HOME/.config/agent/zsh-os-agent.plugin.zsh"
```

### Oh My Zsh

```sh
git clone https://github.com/Luthics/zsh-os-agent.git \
  "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-os-agent"
```

Add `zsh-os-agent` at the **end** of `plugins=(...)` in `~/.zshrc`, and place your executable agent script at `~/.config/agent/bash.agent` (see [`examples/bash.agent`](examples/bash.agent)).

### Zinit / Antidote / Manual

```zsh
# Zinit
zinit light Luthics/zsh-os-agent

# Or manual source (after cloning)
source /path/to/zsh-os-agent/zsh-os-agent.plugin.zsh
```

## Configuration

| Environment Variable | Default | Description |
| :--- | :--- | :--- |
| `AGENT_SH_SCRIPT` | `$HOME/.config/agent/bash.agent` | Executable OS Agent script invoked for natural-language queries |
| `AGENT_SH_HISTORY_SIZE` | `10` | Max number of recent shell commands sent via `fd 4` `<shell_context>` |
| `AGENT_SH_ENABLED` | `1` | Set to `0` to start with interception disabled |

## Helper Commands

| Command | Description |
| :--- | :--- |
| `agent-reset` | Clear the current terminal's WAL context and shell history ring buffer |
| `agent-ctx` | Print the current terminal's WAL context file path |
| `agent-sh-off` | Temporarily disable interception in the current shell |
| `agent-sh-on` | Re-enable interception in the current shell |

## Usage Examples

```zsh
# Normal shell commands run natively with 0 ms overhead
ls -la
git status

# Natural language routes automatically to your agent
what is listening on port 3000?
总结一下最近 5 次 git commit 改了什么

# Explicit prefix forces routing even if the first word is a shell command
? find large files over 100MB in this repo
# explain the exit code of my last command

# Parent-shell mutation: agent writes `cd /path/to/dir` to $AGENT_PREFILL,
# which appears prefilled in your prompt for one-key Enter confirmation.
```

## License

Dual-licensed under either of:

- [MIT License](LICENSE-MIT)
- [Apache License, Version 2.0](LICENSE-APACHE)

at your option.
