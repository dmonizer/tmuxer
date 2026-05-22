#!/usr/bin/env bash

# ── defaults ──────────────────────────────────────────────────────────────────
PORT=""
LOGDIR="$HOME/tmuxer-logs"
INIT_CMDS=$'id\nuname -a\nw\nnetstat -tulip\nip a\narp -a\nip r\nps ax'
ORIG_ARGS=("$@")

# ── functions ─────────────────────────────────────────────────────────────────

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS] <port>

Options:
  -p, --port <port>       Port to listen on
  --logdir <dir>          Log directory (default: ~/tmuxer-logs)
  --init-cmds <cmds>      Semicolon-separated commands mapped to F5 in each window
                          (default: id;uname -a;w;netstat -tulip;ip a;arp -a;ip r;ps ax)
                          Pass empty string to disable: --init-cmds ""
  --install               Install as 'tmuxer' symlink in /usr/local/bin

Examples:
  $(basename "$0") 4444
  $(basename "$0") --port 4444 --logdir /tmp/logs
  $(basename "$0") 4444 --init-cmds "id;uname -a;hostname"
  $(basename "$0") --install
EOF
  exit 0
}

install() {
  local self dest=/usr/local/bin/tmuxer
  self="$(cd "$(dirname "$0")"; pwd)/$(basename "$0")"
  if [[ -e "$dest" ]] || [[ -L "$dest" ]]; then
    echo "removing existing $dest"
    rm -f "$dest" || { echo "error: need sudo — run: sudo $0 --install"; exit 1; }
  fi
  ln -s "$self" "$dest" || { echo "error: need sudo — run: sudo $0 --install"; exit 1; }
  echo "installed: $dest -> $self"
  exit 0
}

enforce_tmux() {
  if [[ -n "$TMUX" ]] && [[ -z "$TMUXER_OWNED_SESSION" ]]; then
    echo "error: refusing to run inside an existing tmux session"
    echo "       run from a plain terminal instead"
    exit 1
  fi
  if [[ -z "$TMUX" ]]; then
    exec tmux new-session -e TMUXER_OWNED_SESSION=1 -- "$0" "${ORIG_ARGS[@]}"
  fi
}

apply_tmux_settings() {
  tmux set-option -g history-limit 100000
  tmux set-option -g mouse on
  tmux set-window-option -g mode-keys vi
  tmux set-option -g monitor-activity on
  tmux set-option -g visual-activity off
  tmux set-option -g window-status-activity-style 'fg=black,bg=yellow,bold'
}

bind_keys() {
  local help_file f5_script=""

  # F1: help popup
  help_file=$(mktemp /tmp/tmuxer_help_XXXXXX)
  cat > "$help_file" <<'EOF'
┌─ tmux tips ────────────────────────────────────────────────────────────────┐
│  Mouse     scroll to enter copy mode · click to focus pane                 │
│  Vi keys   in copy mode: hjkl move · Space start sel · Enter copy · q quit │
│  Paste     Ctrl-b ]                                                         │
│  Windows   Ctrl-b c new · Ctrl-b n/p next/prev · Ctrl-b & kill             │
│  Activity  inactive windows turn yellow in the status bar on new output     │
│  F1        show this help                                                   │
│  F5        send recon commands to active shell                              │
│  Ctrl-c    in window 0: exit tmuxer and kill all connections                │
└────────────────────────────────────────────────────────────────────────────┘
  Press any key to close
EOF
  tmux bind-key -n F1 display-popup -E -w 80 -h 13 "cat $help_file; read -rsk1 2>/dev/null || read -rs -n1"

  # F5: recon commands
  if [[ -n "$INIT_CMDS" ]]; then
    f5_script=$(mktemp /tmp/tmuxer_f5_XXXXXX)
    {
      printf '#!/usr/bin/env bash\n'
      while IFS= read -r cmd; do
        [[ -z "$cmd" ]] && continue
        printf 'tmux send-keys %q Enter\nsleep 0.3\n' "$cmd"
      done <<< "$INIT_CMDS"
    } > "$f5_script"
    chmod +x "$f5_script"
    tmux bind-key -n F5 run-shell "$f5_script"
  fi

  trap 'rm -f "$help_file" ${f5_script:+"$f5_script"}
        tmux unbind-key -n F1 2>/dev/null
        tmux unbind-key -n F5 2>/dev/null' EXIT
}

print_tips() {
  cat <<'EOF'
┌─ tmux tips ────────────────────────────────────────────────────────────────┐
│  Mouse     scroll to enter copy mode · click to focus pane                 │
│  Vi keys   in copy mode: hjkl move · Space start sel · Enter copy · q quit │
│  Paste     Ctrl-b ]                                                         │
│  Windows   Ctrl-b c new · Ctrl-b n/p next/prev · Ctrl-b & kill             │
│  Activity  inactive windows turn yellow in the status bar on new output     │
│  F1        show this help                                                   │
│  F5        send recon commands to active shell                              │
│  Ctrl-c    in window 0: exit tmuxer and kill all connections                │
└────────────────────────────────────────────────────────────────────────────┘
EOF
}

check_port() {
  if ss -tlnH "sport = :$PORT" 2>/dev/null | grep -q .; then
    echo "error: port $PORT is already in use"
    ss -tlnpH "sport = :$PORT" 2>/dev/null | awk '{print "       " $0}'
    exit 1
  fi
}

handle_connection() {
  local remote_ip="${SOCAT_PEERADDR:-unknown}"
  local in out logfile win_id new_pane_tty in_pid out_pid

  echo "[+] incoming connection from $remote_ip" >"$LISTENER_TTY"

  in=$(mktemp -u /tmp/sock_in_XXXXXX)
  out=$(mktemp -u /tmp/sock_out_XXXXXX)
  mkfifo "$in" "$out"

  if [[ -n "$LOGDIR" ]]; then
    mkdir -p "$LOGDIR"
    logfile="$LOGDIR/${remote_ip}-$(date +%d%m%y-%H%M%S).log"
    touch "$logfile"
  fi

  local init_display f5_hint=""
  init_display=$(printf '%s\n' "$INIT_CMDS" | paste -sd '|' | sed 's/|/ | /g')
  [[ -n "$INIT_CMDS" ]] && f5_hint="; echo '[F5] autorun: $init_display'"

  win_id=$(tmux new-window -P -F "#{window_id}" -n "$remote_ip" \
    "echo '[*] connection from $remote_ip'$f5_hint; trap 'rm -f $in $out' EXIT; cat <$in & cat >$out; wait")

  sleep 0.1
  new_pane_tty=$(tmux display-message -p -t "$win_id" "#{pane_tty}")

  if [[ -n "$logfile" ]]; then
    cat <&0 | tee >(while IFS= read -r line; do printf '%s REMOTE: %s\n' "$(date '+%H:%M:%S')" "$line"; done >>"$logfile") >"$in" &
  else
    cat <&0 >"$in" &
  fi
  in_pid=$!

  if [[ -n "$logfile" ]]; then
    cat <"$out" | tee >(while IFS= read -r line; do printf '%s USER:   %s\n' "$(date '+%H:%M:%S')" "$line"; done >>"$logfile") >&1 &
  else
    cat <"$out" >&1 &
  fi
  out_pid=$!

  wait -n $in_pid $out_pid
  kill $in_pid $out_pid 2>/dev/null

  echo "[!] connection from $remote_ip closed" >"$LISTENER_TTY"
  echo "[!] connection closed" >"$new_pane_tty"
  [[ -n "$logfile" ]] && echo "[*] log saved to $logfile" >"$LISTENER_TTY"

  rm -f "$in" "$out"
}

start_listener() {
  local self
  self="$(cd "$(dirname "$0")"; pwd)/$(basename "$0")"

  export LISTENER_TTY=$(tty)
  export LOGDIR
  export INIT_CMDS

  enforce_tmux
  apply_tmux_settings
  bind_keys
  print_tips
  check_port

  echo "[*] Listening on :$PORT"
  [[ -n "$LOGDIR" ]] && echo "[*] Logging to $LOGDIR"
  [[ -n "$INIT_CMDS" ]] && echo "[*] F5 autorun: $(printf '%s\n' "$INIT_CMDS" | paste -sd '|' | sed 's/|/ | /g')"

  socat TCP4-LISTEN:${PORT},reuseaddr,fork EXEC:"$self handler $LOGDIR",nofork
}

# ── parse args ────────────────────────────────────────────────────────────────
[[ $# -eq 0 ]] && usage

while [[ $# -gt 0 ]]; do
  case "$1" in
  -h | --help)   usage ;;
  --install)     install ;;
  handler)
    MODE=handler
    shift
    LOGDIR="${1:-}"
    shift
    ;;
  --logdir)      LOGDIR="$2";                    shift 2 ;;
  --init-cmds)   INIT_CMDS="${2//;/$'\n'}";      shift 2 ;;
  --port | -p)   PORT="$2";                      shift 2 ;;
  *)             PORT="$1";                      shift   ;;
  esac
done

# ── dispatch ──────────────────────────────────────────────────────────────────
if [[ "$MODE" == "handler" ]]; then
  handle_connection
else
  [[ -z "$PORT" ]] && { echo "error: port required"; usage; }
  start_listener
fi
