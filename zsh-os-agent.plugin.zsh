# SPDX-License-Identifier: MIT OR Apache-2.0
# zsh-os-agent.plugin.zsh — Lightweight Zsh plugin for OS Agent v1.0
# https://github.com/Luthics/zsh-os-agent
#
# Architecture (zero core modifications; pure POSIX primitives):
#   - Per-Zsh-PID WAL context: /tmp/agent-sh-<pid>.ctx.jsonl (0600, NOT exported to subshells)
#   - Dedicated parent-shell prefill channel: $AGENT_PREFILL (/tmp/agent-sh-prefill-<pid>, 0600)
#   - Recent native shell commands ring buffer (cwd, cmd, exit_code) passed via fd 4 (<shell_context>)
#   - Invokes Agent with `-q` (explicit stderr) + `fd 3` structured trace (`AGENT_TRACE_LEVEL=deltas`):
#       * `thinking...` & `executing(<cmd>)` are strictly ephemeral single-line status indicators
#         erased via `\r\033[K` before any `$AGENT_OUT`/`$AGENT_ERR` output and on completion —
#         NEVER saved into terminal output or scrollback.
#       * stdout ($AGENT_OUT): streams cleanly to terminal in normal white
#       * Blank-output safety fallback: if a model drifts in a long session and writes 0 bytes to
#         $AGENT_OUT, $AGENT_ERR, and $AGENT_PREFILL, prints the final turn's text_delta in white
#         so the terminal never silently returns blank.
#       * $AGENT_PREFILL: prefilled into next editable Zsh prompt BUFFER for human confirmation
#
# Helper commands:
#   agent-reset   Clear current terminal's persistent WAL context file
#   agent-ctx     Print current terminal's WAL context file path
#   agent-sh-off  Temporarily disable natural-language interception in current shell
#   agent-sh-on   Re-enable interception

[[ -o interactive ]] || return 0

: "${AGENT_SH_SCRIPT:=$HOME/.config/agent/bash.agent}"
: "${AGENT_SH_HISTORY_SIZE:=10}"
: "${AGENT_SH_ENABLED:=1}"

# Bind WAL & prefill files strictly to THIS Zsh PID (non-exported so nested subshells get fresh WALs).
typeset -g AGENT_SH_CONTEXT="/tmp/agent-sh-$$.ctx.jsonl"
typeset -g AGENT_SH_PREFILL_FILE="/tmp/agent-sh-prefill-$$"

typeset -ga _agent_sh_history
typeset -g _agent_sh_pending_cmd=""
typeset -g _agent_sh_pending_cwd=""

autoload -Uz add-zsh-hook

_agent_sh_json_escape() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  print -rn -- "$s"
}

_agent_sh_preexec() {
  if [[ "$1" == *(API_KEY|SECRET|TOKEN|PASSWORD)*=* ]]; then
    _agent_sh_pending_cmd=""
    _agent_sh_pending_cwd=""
    return
  fi
  _agent_sh_pending_cmd="$1"
  _agent_sh_pending_cwd="$PWD"
}

_agent_sh_precmd() {
  local last_ec=$?
  if [[ -n "$_agent_sh_pending_cmd" ]]; then
    local esc_cwd esc_cmd entry
    esc_cwd=$(_agent_sh_json_escape "$_agent_sh_pending_cwd")
    esc_cmd=$(_agent_sh_json_escape "$_agent_sh_pending_cmd")
    entry="{\"cwd\":\"${esc_cwd}\",\"cmd\":\"${esc_cmd}\",\"exit_code\":${last_ec}}"
    _agent_sh_history+=("$entry")
    if (( ${#_agent_sh_history[@]} > AGENT_SH_HISTORY_SIZE )); then
      _agent_sh_history=("${_agent_sh_history[@]: -${AGENT_SH_HISTORY_SIZE}}")
    fi
    _agent_sh_pending_cmd=""
    _agent_sh_pending_cwd=""
  fi
}

_agent_sh_cleanup() {
  rm -f -- "/tmp/agent-sh-$$.ctx.jsonl" "/tmp/agent-sh-prefill-$$" \
           "/tmp/agent-sh-out-$$.fifo" "/tmp/agent-sh-err-$$.fifo" "/tmp/agent-sh-trace-$$.fifo"
}

add-zsh-hook preexec _agent_sh_preexec
add-zsh-hook precmd _agent_sh_precmd
add-zsh-hook zshexit _agent_sh_cleanup

_agent_sh_dump_history() {
  print -r -- "<shell_context cwd=\"${PWD}\" prefill=\"${AGENT_SH_PREFILL_FILE}\">"
  local item
  for item in "${_agent_sh_history[@]}"; do
    print -r -- "$item"
  done
  print -r -- "</shell_context>"
}

# Multiplex fd 1 ($AGENT_OUT), fd 2 ($AGENT_ERR/errors), and fd 3 (JSONL trace) so ephemeral
# single-line status (`thinking...`, `executing(...)`) is ALWAYS erased cleanly before any
# real output and on exit — never persisting in terminal scrollback.
# If the model wrote 0 bytes to $AGENT_OUT/$AGENT_ERR/$AGENT_PREFILL, falls back to printing
# the final turn's assistant text_delta cleanly in white.
_agent_sh_mux_display() {
  local out_fifo="$1"
  local err_fifo="$2"
  local trace_fifo="$3"
  local prefill_file="$4"
  local cols="${COLUMNS:-80}"

  perl -MIO::Select -e '
    use strict;
    use warnings;
    $| = 1;
    binmode(STDOUT);
    binmode(STDERR);

    my ($out_path, $err_path, $trace_path, $prefill_path, $cols) = @ARGV;
    $cols = 80 if !$cols || $cols < 20;

    open(my $out_fh, "<:raw", $out_path)   or die $!;
    open(my $err_fh, "<:raw", $err_path)   or die $!;
    open(my $tr_fh,  "<:raw", $trace_path) or die $!;

    my $sel = IO::Select->new($out_fh, $err_fh, $tr_fh);
    my $tr_buf = "";
    my $showing = 0;
    my $wrote_real = 0;
    my $last_was_nl = 1;
    my $last_turn_text = "";

    sub clear_status {
      if ($showing) {
        print STDERR "\r\033[K";
        $showing = 0;
      }
    }

    sub trunc_width {
      my ($s, $max_w) = @_;
      my $u = $s;
      utf8::decode($u);
      $u =~ s/[\r\n\t]+/ /g;
      my $res = "";
      my $w = 0;
      for my $ch (split //, $u) {
        my $cw = (ord($ch) > 127) ? 2 : 1;
        if ($w + $cw > $max_w - 3) {
          $res .= "...";
          last;
        }
        $res .= $ch;
        $w += $cw;
      }
      utf8::encode($res);
      return $res;
    }

    sub show_status {
      my ($text) = @_;
      if (!$last_was_nl) {
        print STDOUT "\n";
        $last_was_nl = 1;
      }
      print STDERR "\r\033[K" . $text;
      $showing = 1;
    }

    sub unescape_json_str {
      my ($s) = @_;
      my %map = (
        "n" => "\n", "r" => "\r", "t" => "\t",
        "b" => "\b", "f" => "\f", "\"" => "\"",
        "\\" => "\\", "/" => "/"
      );
      $s =~ s/\\(?:([nrtbf"\\\/])|u([0-9a-fA-F]{4}))/
        defined($1) ? $map{$1} : do {
          my $c = chr(hex($2));
          utf8::encode($c);
          $c;
        }
      /ge;
      return $s;
    }

    sub handle_trace_line {
      my ($line) = @_;
      return unless $line =~ /"type"\s*:\s*"([^"]+)"/;
      my $t = $1;
      if ($t eq "llm_request_start") {
        $last_turn_text = "";
        show_status("thinking...");
      } elsif ($t eq "text_delta") {
        if ($line =~ /"text"\s*:\s*"((?:[^"\\]|\\.)*)"/) {
          $last_turn_text .= unescape_json_str($1);
        }
      } elsif ($t eq "tool_start") {
        my $cmd = "";
        if ($line =~ /"cmd"\s*:\s*"((?:[^"\\]|\\.)*)"/) {
          $cmd = unescape_json_str($1);
        }
        my $max_cmd_w = $cols - 13;
        $max_cmd_w = 12 if $max_cmd_w < 12;
        my $short = trunc_width($cmd, $max_cmd_w);
        show_status("executing(" . $short . ")");
      } elsif ($t eq "llm_response" || $t eq "run_end") {
        clear_status();
      }
    }

    while ($sel->count() > 0) {
      my @ready = $sel->can_read(0.1);
      for my $fh (@ready) {
        my $chunk = "";
        my $n = sysread($fh, $chunk, 8192);
        if (!defined($n) || $n == 0) {
          $sel->remove($fh);
          close($fh);
          next;
        }
        if ($fh == $out_fh) {
          clear_status();
          print STDOUT $chunk;
          $wrote_real = 1;
          $last_was_nl = (substr($chunk, -1) eq "\n") ? 1 : 0;
        } elsif ($fh == $err_fh) {
          clear_status();
          print STDERR $chunk;
          $wrote_real = 1;
          $last_was_nl = (substr($chunk, -1) eq "\n") ? 1 : 0;
        } else {
          $tr_buf .= $chunk;
          while ($tr_buf =~ s/^([^\n]*)\n//) {
            handle_trace_line($1);
          }
        }
      }
    }

    clear_status();

    # Safety fallback: if the model forgot to write $AGENT_OUT (and wrote nothing to $AGENT_ERR
    # or $AGENT_PREFILL), display the final turn text_delta so the user never sees a blank screen.
    my $has_prefill = (-s $prefill_path) ? 1 : 0;
    if (!$wrote_real && !$has_prefill && $last_turn_text =~ /\S/) {
      print STDOUT $last_turn_text;
      $wrote_real = 1;
      $last_was_nl = (substr($last_turn_text, -1) eq "\n") ? 1 : 0;
    }

    if ($wrote_real && !$last_was_nl) {
      print STDOUT "\n";
    }
  ' "$out_fifo" "$err_fifo" "$trace_fifo" "$prefill_file" "$cols"
}

_agent_sh_is_shell_command() {
  local line="$1"
  local -a words
  words=(${(z)line}) 2>/dev/null || words=(${=line})
  (( ${#words[@]} == 0 )) && return 0

  local idx=1 w
  while (( idx <= ${#words[@]} )); do
    w="${words[$idx]}"
    if [[ "$w" =~ "^[A-Za-z_][A-Za-z0-9_]*=" ]]; then
      (( idx++ ))
    else
      break
    fi
  done
  (( idx > ${#words[@]} )) && return 0

  local first="${words[$idx]}"

  case "$first" in
    '('|'{'|'[['|'!'|'((') return 0 ;;
  esac

  if [[ "$first" == ./* || "$first" == /* || "$first" == ~/* || "$first" == ../* ]]; then
    return 0
  fi

  if whence -w -- "$first" >/dev/null 2>&1; then
    return 0
  fi

  return 1
}

_agent_sh_invoke() {
  setopt localoptions nomonitor nonotify
  local query="$1"
  local script="$AGENT_SH_SCRIPT"

  if [[ ! -x "$script" ]]; then
    print -u2 -r -- "[agent-sh] default agent script not executable: $script"
    return 1
  fi

  if [[ ! -e "$AGENT_SH_CONTEXT" ]]; then
    ( umask 077 && : > "$AGENT_SH_CONTEXT" )
  fi
  ( umask 077 && : > "$AGENT_SH_PREFILL_FILE" )

  local out_fifo="/tmp/agent-sh-out-$$.fifo"
  local err_fifo="/tmp/agent-sh-err-$$.fifo"
  local trace_fifo="/tmp/agent-sh-trace-$$.fifo"
  rm -f -- "$out_fifo" "$err_fifo" "$trace_fifo"
  ( umask 077 && mkfifo "$out_fifo" "$err_fifo" "$trace_fifo" )

  local mux_pid=0 ec=0
  {
    _agent_sh_mux_display "$out_fifo" "$err_fifo" "$trace_fifo" "$AGENT_SH_PREFILL_FILE" &
    mux_pid=$!

    AGENT_TRACE_LEVEL=deltas \
    AGENT_PREFILL="$AGENT_SH_PREFILL_FILE" \
    "$script" -q -c "$AGENT_SH_CONTEXT" -- "$query" \
      4< <(_agent_sh_dump_history) \
      1> "$out_fifo" \
      2> "$err_fifo" \
      3> "$trace_fifo"
    ec=$?
  } always {
    if (( mux_pid > 0 )); then
      wait "$mux_pid" 2>/dev/null || true
    fi
    rm -f -- "$out_fifo" "$err_fifo" "$trace_fifo"
  }

  local prefill=""
  if [[ -s "$AGENT_SH_PREFILL_FILE" ]]; then
    prefill="$(<"$AGENT_SH_PREFILL_FILE")"
    prefill="${prefill%$'\n'}"
    : > "$AGENT_SH_PREFILL_FILE"
  fi
  _AGENT_SH_PREFILL="$prefill"
  return $ec
}

_agent_sh_accept_line() {
  if [[ "${AGENT_SH_ENABLED}" != "1" || -n "${PREBUFFER}" ]]; then
    zle .accept-line
    return
  fi

  local raw="$BUFFER"
  local trimmed="${raw#"${raw%%[![:space:]]*}"}"

  if [[ -z "$trimmed" ]]; then
    zle .accept-line
    return
  fi

  local query=""
  local route_to_agent=0

  if [[ "$trimmed" == \?* ]]; then
    query="${trimmed#\?}"
    query="${query#"${query%%[![:space:]]*}"}"
    route_to_agent=1
  elif [[ "$trimmed" == \#* ]]; then
    query="${trimmed#\#}"
    query="${query#"${query%%[![:space:]]*}"}"
    route_to_agent=1
  elif _agent_sh_is_shell_command "$trimmed"; then
    zle .accept-line
    return
  else
    query="$trimmed"
    route_to_agent=1
  fi

  if (( route_to_agent == 0 )) || [[ -z "$query" ]]; then
    zle .accept-line
    return
  fi

  print -s -- "$raw"

  zle -I
  print -r -- ""

  _AGENT_SH_PREFILL=""
  _agent_sh_invoke "$query"

  if [[ -n "$_AGENT_SH_PREFILL" ]]; then
    BUFFER="$_AGENT_SH_PREFILL"
    CURSOR=${#BUFFER}
  else
    BUFFER=""
    CURSOR=0
  fi

  # zle -I already triggers a clean fresh prompt redraw on return
}

zle -N accept-line _agent_sh_accept_line

agent-reset() {
  rm -f -- "$AGENT_SH_CONTEXT" "$AGENT_SH_PREFILL_FILE"
  _agent_sh_history=()
  print -r -- "[agent-sh] context reset: $AGENT_SH_CONTEXT"
}

agent-ctx() {
  print -r -- "$AGENT_SH_CONTEXT"
}

agent-sh-off() {
  AGENT_SH_ENABLED=0
  print -r -- "[agent-sh] disabled in this shell"
}

agent-sh-on() {
  AGENT_SH_ENABLED=1
  print -r -- "[agent-sh] enabled in this shell"
}
