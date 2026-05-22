#!/usr/bin/env bash

# ── parse args ────────────────────────────────────────────────────────────────
PORT=""
LOGDIR="$HOME/tmuxer-logs"
INIT_CMDS=$'id\nuname -a\nw\nnetstat -tulip\nip a\narp -a\nip r\nps ax'
ORIG_ARGS=("$@")

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS] <port>

Options:
  -p, --port <port>       Port to listen on
  --logdir <dir>          Log directory (default: ~/tmuxer-logs)
  --init-cmds <cmds>      Semicolon-separated commands mapped to F5 in each window
                          (default: id;uname -a;w;netstat -tulip;ip a;arp -a;ip r;ps ax)
                          Pass empty string to disable: --init-cmds ""

Examples:
  $(basename "$0") 4444
  $(basename "$0") --port 4444 --logdir /tmp/logs
  $(basename "$0") 4444 --init-cmds "id;uname -a;hostname"
EOF
  exit 0
}

[[ $# -eq 0 ]] && usage

while [[ $# -gt 0 ]]; do
  case "$1" in
  -h | --help)
    usage
    ;;
  handler)
    MODE=handler
    shift
    LOGDIR="${1:-}"
    shift
    ;;
  --logdir)
    LOGDIR="$2"
    shift 2
    ;;
  --init-cmds)
    INIT_CMDS="${2//;/$'\n'}"
    shift 2
    ;;
  --port | -p)
    PORT="$2"
    shift 2
    ;;
  *)
    PORT="$1"
    shift
    ;;
  esac
done

[[ -z "$PORT" ]] && [[ "$MODE" != "handler" ]] && { echo "error: port required"; usage; }

# ── auto-start tmux if not already inside ────────────────────────────────────
[[ -z "$TMUX" ]] && [[ "$MODE" != "handler" ]] && {
  exec tmux new-session -- "$0" "${ORIG_ARGS[@]}"
}

# ── handler mode (invoked by socat) ──────────────────────────────────────────
if [[ "$MODE" == "handler" ]]; then
  REMOTE_IP="${SOCAT_PEERADDR:-unknown}"
  echo "[+] incoming connection from $REMOTE_IP" >"$LISTENER_TTY"

  IN=$(mktemp -u /tmp/sock_in_XXXXXX)
  OUT=$(mktemp -u /tmp/sock_out_XXXXXX)
  mkfifo "$IN" "$OUT"

  # logging
  if [[ -n "$LOGDIR" ]]; then
    mkdir -p "$LOGDIR"
    LOGFILE="$LOGDIR/${REMOTE_IP}-$(date +%d%m%y-%H%M%S).log"
    touch "$LOGFILE"
  fi

  INIT_DISPLAY=$(printf '%s\n' "$INIT_CMDS" | paste -sd '|' | sed 's/|/ | /g')
  F5_HINT=""
  [[ -n "$INIT_CMDS" ]] && F5_HINT="; echo '[F5] autorun: $INIT_DISPLAY'"

  WIN_ID=$(tmux new-window -P -F "#{window_id}" -n "$REMOTE_IP" \
    "echo '[*] connection from $REMOTE_IP'$F5_HINT; trap 'rm -f $IN $OUT' EXIT; cat <$IN & cat >$OUT; wait")

  sleep 0.1
  NEW_PANE_TTY=$(tmux display-message -p -t "$WIN_ID" "#{pane_tty}")

  # remote -> log + tmux pane
  if [[ -n "$LOGFILE" ]]; then
    cat <&0 | tee >(while IFS= read -r line; do printf '%s REMOTE: %s\n' "$(date '+%H:%M:%S')" "$line"; done >>"$LOGFILE") >"$IN" &
  else
    cat <&0 >"$IN" &
  fi
  IN_PID=$!

  # tmux pane -> log + remote
  if [[ -n "$LOGFILE" ]]; then
    cat <"$OUT" | tee >(while IFS= read -r line; do printf '%s USER:   %s\n' "$(date '+%H:%M:%S')" "$line"; done >>"$LOGFILE") >&1 &
  else
    cat <"$OUT" >&1 &
  fi
  OUT_PID=$!

  wait -n $IN_PID $OUT_PID
  kill $IN_PID $OUT_PID 2>/dev/null

  echo "[!] connection from $REMOTE_IP closed" >"$LISTENER_TTY"
  echo "[!] connection closed" >"$NEW_PANE_TTY"
  [[ -n "$LOGFILE" ]] && echo "[*] log saved to $LOGFILE" >"$LISTENER_TTY"

  rm -f "$IN" "$OUT"
  exit 0
fi

# ── listener mode ─────────────────────────────────────────────────────────────
command -v socat &>/dev/null || {
  echo "socat required"
  exit 1
}

export LISTENER_TTY=$(tty)
export LOGDIR
export INIT_CMDS

# ── F5 keybinding ─────────────────────────────────────────────────────────────
if [[ -n "$INIT_CMDS" ]]; then
  INIT_SCRIPT=$(mktemp /tmp/tmuxer_f5_XXXXXX)
  {
    printf '#!/usr/bin/env bash\n'
    while IFS= read -r cmd; do
      [[ -z "$cmd" ]] && continue
      printf 'tmux send-keys %q Enter\nsleep 0.3\n' "$cmd"
    done <<< "$INIT_CMDS"
  } > "$INIT_SCRIPT"
  chmod +x "$INIT_SCRIPT"
  tmux bind-key -n F5 run-shell "$INIT_SCRIPT"
  trap 'rm -f "$INIT_SCRIPT"; tmux unbind-key -n F5 2>/dev/null' EXIT
fi

SELF="$(
  cd "$(dirname "$0")"
  pwd
)/$(basename "$0")"
echo "[*] Listening on :$PORT"
[[ -n "$LOGDIR" ]] && echo "[*] Logging to $LOGDIR"
[[ -n "$INIT_CMDS" ]] && echo "[*] F5 autorun: $(printf '%s\n' "$INIT_CMDS" | paste -sd '|' | sed 's/|/ | /g')"
socat TCP4-LISTEN:${PORT},reuseaddr,fork EXEC:"$SELF handler $LOGDIR",nofork
