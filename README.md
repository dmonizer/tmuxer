# tmuxer

Reverse shell listener that opens each incoming connection in a dedicated tmux window, with session logging and built-in recon shortcuts.

## Requirements

- `tmux`
- `socat`

## Install

```
sudo ./tmuxer.sh --install
```

Creates `/usr/local/bin/tmuxer` as a symlink to the script.

## Usage

```
tmuxer [OPTIONS] <port>

Options:
  -p, --port <port>       Port to listen on
  --logdir <dir>          Log directory (default: ~/tmuxer-logs)
  --init-cmds <cmds>      Semicolon-separated commands sent via F5
                          (default: id;uname -a;w;netstat -tulip;ip a;arp -a;ip r;ps ax)
                          Pass empty string to disable: --init-cmds ""
  --install               Install as 'tmuxer' symlink in /usr/local/bin
```

Must be run from a plain terminal, not from inside an existing tmux session. tmuxer starts its own session automatically.

## Features

**Per-connection windows** — each reverse shell opens in a new tmux window named after the remote IP.

**Session logging** — both directions are logged to `~/tmuxer-logs/<IP>-<timestamp>.log` with `HH:MM:SS REMOTE:` / `USER:` prefixes. Override the directory with `--logdir`.

**Recon via F5** — pressing F5 sends a configurable set of recon commands to the active shell (id, uname -a, w, netstat -tulip, ip a, arp -a, ip r, ps ax by default). Each window shows the command list on connect.

**Activity indicator** — tmux window tabs turn yellow when a non-active window receives output.

**Keybindings** (active for the duration of the listener):

| Key     | Action                                      |
|---------|---------------------------------------------|
| F1      | Show help popup                             |
| F5      | Send recon commands to active shell         |
| Ctrl-c  | In window 0: exit tmuxer, kill all sessions |

## Log format

```
14:23:01 REMOTE: uid=0(root) gid=0(root) groups=0(root)
14:23:02 INIT:   uname -a
14:23:02 REMOTE: Linux target 5.15.0 ...
14:23:10 USER:   cat /etc/passwd
```
