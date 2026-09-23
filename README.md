# tmuxer

Pentester toolkit built around tmux. Opens each incoming reverse shell in a dedicated window, manages SSH/GSocket host connections, and provides session logging and command shortcuts.

## Requirements

- `tmux`, `socat`
- Optional: `fzf` (better host/command picker), `gs-netcat` (GSocket support)

## Install

```
sudo ./tmuxer.sh --install
```

Creates `~/.tmuxer/config` with defaults and `/usr/local/bin/tmuxer` symlink.

## Config (`~/.tmuxer/config`)

```bash
listener_port=4444
logdir=~/.tmuxer/logs
prepend_space=1                   # prefix commands with space (hide from history)
gsocket_hosts=~/.tmuxer/gsocket-hosts    # name|description|secret

cmd_1_name="Disable History"
cmd_1="unset HISTFILE; export HISTSIZE=0 HISTFILESIZE=0 SAVEHIST=0; set +o history 2>/dev/null; setopt nohistory 2>/dev/null"

cmd_2_name="Quick Recon"
cmd_2="id; uname -a; hostname"
```

GSocket hosts file (`~/.tmuxer/gsocket-hosts`, mode 600):
```
# name|description|secret
my-box|home desktop|mysecretkey
```

## Keybindings

| Key | Action |
|-----|--------|
| F1  | Help + reverse shell one-liners for current IP:port |
| F2  | Host connector — SSH and GSocket hosts (fzf or numbered) |
| F3  | Toggle raw mode (for pty.spawn connections) |
| F4  | Open or hide the selected notes file in `$EDITOR` |
| Shift-F4 | Choose the notes file that the next F4 opens |
| F5  | Send command from config to active shell |
| F8  | Toggle Ctrl-C confirmation for remote shells |
| F9  | Toggle reverse shell listener on/off |
| Ctrl-C | Send to remote (confirmation is on by default; F8 toggles it) or pass through in any local window |

F2 and F5 include a **[ + Add new ... ]** entry to add hosts/commands on the fly — persisted to config immediately.

## Reverse shell listener

F9 starts a `socat` listener on the configured port. Each incoming connection opens in a new tmux window named after the remote IP, with PTY auto-detection and optional raw mode toggle (F3).

F1 shows ready-to-copy one-liners (bash, nc, python, reconnecting) for both Linux and macOS, pre-filled with your current IP and port.

## Session logging

Every connection is logged to `~/.tmuxer/logs/<IP>-<timestamp>.log` with timestamped, directional prefixes:

```
14:23:01 REMOTE: uid=0(root) gid=0(root)
14:23:05 USER:   cat /etc/passwd
```

The local shell is also logged on startup. Override the directory with `--logdir` or `logdir=` in config.

## Session notes

F4 opens the last selected file in `$EDITOR` in a vertical pane. Press F4 again to hide that pane without stopping the editor; press it once more to restore and focus it. On the first use, F4 presents a file browser rooted at `~/.tmuxer/notes/`. Shift-F4 always presents that browser and saves the chosen file for the next plain F4, without interrupting an editor already open.

## encode / revshell

Helper scripts for generating and encoding reverse shell payloads:

```bash
# Generate and encode in one step
encode to-be-encoded.sh H=10.0.0.1 P=4444

# Or separately
revshell H=10.0.0.1 P=4444        # writes to-be-encoded.sh
encode to-be-encoded.sh            # outputs base64 one-liners for all available compressors
```

`encode` tries gzip, xz, bzip2, and zopfli, printing a ready-to-run one-liner with char count for each.

## xz-test

Exhaustive compression benchmark — finds the shortest possible encoded payload across ~22 500 xz `--lzma2` combinations, gzip levels, and zopfli iterations × formats. Reports total one-liner length (payload + decoder overhead) and best pack/unpack commands per compressor.

```bash
xz-test to-be-encoded.sh
```
