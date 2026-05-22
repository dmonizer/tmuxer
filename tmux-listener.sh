#!/usr/bin/env bash

# ── parse args ────────────────────────────────────────────────────────────────
PORT=4444
LOGDIR="$HOME/tmuxer-logs"
ORIG_ARGS=("$@")

while [[ $# -gt 0 ]]; do
  case "$1" in
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

  WIN_ID=$(tmux new-window -P -F "#{window_id}" -n "$REMOTE_IP" \
    "echo '[*] connection from $REMOTE_IP'; trap 'rm -f $IN $OUT' EXIT; cat <$IN & cat >$OUT; wait")

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

SELF="$(
  cd "$(dirname "$0")"
  pwd
)/$(basename "$0")"
echo "[*] Listening on :$PORT"
[[ -n "$LOGDIR" ]] && echo "[*] Logging to $LOGDIR"
socat TCP4-LISTEN:${PORT},reuseaddr,fork EXEC:"$SELF handler $LOGDIR",nofork
