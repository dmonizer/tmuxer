# tmuxer.sh — Code Review Report

Reviewed: `/home/nimda/IdeaProjects/tmuxer/tmuxer.sh` (679 lines)  
Date: 2026-06-09

---

## Summary

| Severity | Count |
|----------|-------|
| Critical (bugs that break functionality) | 4 |
| Significant (correctness / security) | 7 |
| Medium (robustness / portability) | 5 |
| Minor (cleanliness) | 5 |

---

## Critical Bugs

### C1 — Cleanup hook deletes PID file before killing the process (line 539)

```bash
tmux set-hook session-closed "run-shell 'rm -f $LISTENER_PID_FILE ...; kill \$(cat $LISTENER_PID_FILE 2>/dev/null) 2>/dev/null'"
```

`rm -f $LISTENER_PID_FILE` runs first, so by the time `kill $(cat $LISTENER_PID_FILE)` executes, the file is already gone. The `cat` returns nothing, `kill` receives no PID, and the socat listener process is never killed on session close. The process leaks as an orphan.

**Fix:** Swap the order — kill first, then rm:

```bash
tmux set-hook session-closed "run-shell 'kill \$(cat $LISTENER_PID_FILE 2>/dev/null) 2>/dev/null; sleep 0.2; rm -f $LISTENER_PID_FILE $HOSTS_FILE ...'"
```

---

### C2 — Non-fzf F2 fallback generates invalid shell code: `%%q`/`%%s` don't substitute (lines 360, 365)

```bash
# Line 360 (SSH case):
printf '  %%q) tmux new-window -n %%q "ssh %%s || ..." ;;\n' "$key" "$rest" "$rest"

# Line 365 (GS case):
printf '  %%q) tmux new-window -n %%q "gs-netcat -s %%s -i || ..." ;;\n' "$key" "$gs_name" "$gs_secret"
```

`%%` in bash `printf` is an escape for a literal `%`. So `%%q` outputs the literal text `%q` — it is NOT a format specifier. The arguments `$key`, `$rest`, `$gs_name`, `$gs_secret` are passed but never consumed. The generated case statement contains literal `%q)` and `%s` placeholders instead of actual values, which is invalid bash.

Compare to the **correct** F5 fallback at lines 427/429 which uses `%q` (single percent) correctly.

**Fix:** Use single-percent format specifiers, consistent with the working F5 fallback:

```bash
# SSH:
printf '  %q) tmux new-window -n %q "ssh %s || ..." ;;\n' "$key" "$rest" "$rest"

# GS:
printf '  %q) tmux new-window -n %q "gs-netcat -s %q -i || ..." ;;\n' "$key" "$gs_name" "$gs_secret"
```

Note: the GS secret should use `%q` (not `%s`) to shell-quote the secret value.

---

### C3 — `SELF` not resolved through symlinks — `--install` creates a circular symlink (line 8)

```bash
SELF="$(cd "$(dirname "$0")" || exit; pwd)/$(basename "$0")"
```

This canonicalises the path but does **not** resolve symlinks. When the script is invoked via the installed symlink `/usr/local/bin/tmuxer`, `$0` is `/usr/local/bin/tmuxer`, so `SELF` becomes `/usr/local/bin/tmuxer`. Running `--install` again then executes `ln -s /usr/local/bin/tmuxer /usr/local/bin/tmuxer` — a self-referencing circular symlink.

**Fix:** Resolve to the real file path at startup:

```bash
# Cross-platform (Linux + macOS)
if command -v realpath &>/dev/null; then
  SELF="$(realpath "$0")"
elif command -v readlink &>/dev/null && readlink -f "$0" &>/dev/null; then
  SELF="$(readlink -f "$0")"
else
  SELF="$(cd "$(dirname "$0")" && pwd -P)/$(basename "$0")"
fi
```

---

### C4 — `wait -n` requires bash 4.3+ — fails on macOS default bash (line 601)

```bash
wait -n $in_pid $out_pid
```

`wait -n` (wait for the next child to finish) was added in bash 4.3. macOS ships bash 3.2 as the system default (GPL2 constraint). This silently fails or causes an error on stock macOS, breaking the connection handler entirely.

**Fix:** Use a portable alternative. Since you want to exit when _either_ direction closes:

```bash
# Portable: wait for both, rely on the fifo closing to unblock the other
wait $in_pid $out_pid 2>/dev/null
```

Or use a trap-based approach where each background job kills the other on exit:

```bash
_cleanup_conns() { kill $in_pid $out_pid 2>/dev/null; }
trap _cleanup_conns EXIT
wait $in_pid
```

---

## Significant Issues

### S1 — `choice=$(tmux display-menu ...)` — display-menu does not write to stdout (lines 342, 411)

```bash
printf 'choice=$(tmux display-menu -T "Hosts" \...'
```

`tmux display-menu` is a tmux command that pops up an interactive menu and runs a tmux command for the chosen item. It does **not** write the selection to stdout. `choice` will always be an empty string. The `case "$choice" in` block that follows never matches any branch. The entire non-fzf fallback for both F2 and F5 is silently broken.

**Fix:** Embed the actions directly as tmux commands in the menu item definitions:

```bash
# Each item: "label" "key" "tmux-command"
tmux display-menu -T "Hosts" \
  "hostname1" "a" "new-window -n hostname1 'ssh hostname1'" \
  "hostname2" "b" "new-window -n hostname2 'ssh hostname2'"
```

Build this dynamically instead of a `choice`/`case` pattern.

---

### S2 — `install()` ignores configured `gsocket_hosts` path (line 91)

```bash
# In install():
local gs="${gsocket_hosts:-$HOME/.gsocket/hosts}"
```

`load_config()` is never called before `install()` (CLI parsing calls `install` directly). The lowercase `$gsocket_hosts` config variable is always empty here, so the custom path in `~/.tmuxer.conf` is silently ignored and the default `~/.gsocket/hosts` is always used.

**Fix:** Call `load_config` at the top of `install()`, or reference the already-defaulted `$GSOCKET_HOSTS` (uppercase):

```bash
local gs="$GSOCKET_HOSTS"
```

---

### S3 — GSocket secret exposed in process list (lines 327, 365, 473)

```bash
tmux new-window -n "$gs_name" "gs-netcat -s '$gs_secret' -i || ..."
```

The GSocket shared secret is passed as a command-line argument, making it visible in `ps aux` / `/proc/$pid/cmdline` to any user on the system while the connection is active.

**Fix:** Pass the secret via an environment variable or a named pipe instead:

```bash
# In the generated command, use env var:
GS_SECRET='$gs_secret' gs-netcat -s "\$GS_SECRET" -i
# Or use stdin if gs-netcat supports it
```

Check if `gs-netcat` supports `-s -` to read the secret from stdin, which is the cleanest option.

---

### S4 — `ip` and `hostname -I` are Linux-only; macOS IP detection silently falls through (lines 213–215)

```bash
ip=$(ip route get 1.1.1.1 2>/dev/null | awk ...)
ip=${ip:-$(hostname -I 2>/dev/null | awk '{print $1}')}
ip=${ip:-"<your-ip>"}
```

Both `ip route` and `hostname -I` are Linux-only. On macOS both return nothing, so `$ip` becomes the unhelpful literal `<your-ip>` in the generated reverse shells.

**Fix:** Add macOS-aware fallback between the two existing attempts:

```bash
ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1);exit}}')
ip=${ip:-$(hostname -I 2>/dev/null | awk '{print $1}')}
# macOS fallback
ip=${ip:-$(ifconfig 2>/dev/null | awk '/inet / && !/127\.0\.0\.1/{print $2; exit}')}
ip=${ip:-"<your-ip>"}
```

---

### S5 — No dependency checks at startup

The script requires `tmux` (mandatory), `socat` (for F9 listener), and optionally `fzf` and `gs-netcat`. Only `fzf` is checked (via `type -P fzf`). Missing `tmux` would cause a cryptic failure in `enforce_tmux`. Missing `socat` causes F9 to silently start a process that immediately dies.

**Fix:** Add a startup dependency check:

```bash
check_deps() {
  local missing=()
  command -v tmux  &>/dev/null || missing+=("tmux")
  command -v socat &>/dev/null || missing+=("socat")
  command -v awk   &>/dev/null || missing+=("awk")
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "error: missing required tools: ${missing[*]}"
    exit 1
  fi
}
```

Call this at the start of `start_tmuxer`.

---

### S6 — `source "$config_file"` executes arbitrary code (line 127)

```bash
source "$config_file"
```

Sourcing `~/.tmuxer.conf` runs arbitrary shell code in the current process as the current user. A compromised or malicious config file can do anything. Since this is a pentesting tool that may be run with elevated awareness of trust, this is acceptable — but it is undocumented.

**Recommendation:** Add a note to the usage/config documentation: "Warning: config file is sourced as shell code." Consider adding a permission check (e.g., require 600) similar to the gsocket hosts check.

---

### S7 — `tmux display-menu` requires tmux 3.0+ — not checked

The non-fzf fallback (already broken per S1) uses `display-menu`, which was introduced in tmux 3.0. No version check is performed. Users on tmux < 3.0 get no error and no menu.

**Fix:** Check tmux version at startup alongside the fzf check, and warn if < 3.0 when fzf is absent.

---

## Medium Issues

### M1 — SSH hostname injected unquoted into tmux window shell command (line 319)

```bash
tmux new-window -n "$rest" "ssh $rest || { echo; echo 'SSH failed (press Enter)'; head -n1 >/dev/null; }"
```

`$rest` is an SSH Host entry parsed from `~/.ssh/config`. If a `Host` entry contains shell metacharacters (quotes, semicolons, backticks), the shell command passed to `tmux new-window` would be broken or injectable. This is unlikely with typical hostnames but violates least-privilege parsing.

**Fix:** Use `printf %q` to shell-quote `$rest` before embedding in the command string, or restructure to avoid dynamic command construction.

---

### M2 — Logdir with spaces silently breaks socat EXEC (lines 469–473)

```bash
socat TCP4-LISTEN:${port},reuseaddr,fork EXEC:"$self handler $logdir",nofork
```

If `$logdir` contains spaces, socat will split the EXEC argument on the space and pass `handler` and the first path component as separate arguments to the shell. The handler won't receive the correct logdir.

**Fix:** Quote the path, or use an env variable instead of a positional arg:

```bash
export HANDLER_LOGDIR="$logdir"
socat TCP4-LISTEN:${port},reuseaddr,fork EXEC:"$self handler",nofork
# In handle_connection: local logdir="${HANDLER_LOGDIR:-}"
```

---

### M3 — `((i++))` is `set -e` hostile when `i=0` (lines 347, 356, 413, 422)

```bash
((i++))
```

Bash's `((expr))` returns exit code 1 when the expression evaluates to zero. `((i++))` when `i=0` evaluates to 0 (post-increment returns the old value), returning exit code 1. Under `set -e` (not currently used, but a common addition), the script would exit on the first increment.

**Fix:** Use `(( ++i ))` (pre-increment, always non-zero after first use) or `i=$(( i + 1 ))`:

```bash
(( ++i ))  # pre-increment: evaluates to new value, so 1+ = true
```

---

### M4 — `parse_ssh_config_file` doesn't handle `Match` block exit correctly (lines 159–163)

```bash
if [[ "$line" =~ ^[Mm]atch[[:space:]] ]]; then in_match=1; continue; fi
if [[ $in_match -eq 1 ]]; then
  [[ "$line" =~ ^[Hh]ost[[:space:]] ]] && in_match=0
  [[ $in_match -eq 1 ]] && continue
fi
```

The `in_match` flag is cleared when a `Host` line is seen inside a `Match` block, which is correct. However, `Match` blocks can also be terminated by another `Match` line. The current code would continue skipping lines in what it thinks is a `Match` block, missing `Host` entries after a second `Match` block.

**Fix:**

```bash
if [[ "$line" =~ ^[Mm]atch[[:space:]] ]]; then in_match=1; continue; fi
if [[ $in_match -eq 1 ]]; then
  [[ "$line" =~ ^([Hh]ost|[Mm]atch)[[:space:]] ]] && in_match=0 || continue
fi
```

---

### M5 — `script` command argument order for Linux is unconventional (lines 641–644)

```bash
if script /dev/null -c true >/dev/null 2>&1; then
    exec script "$local_log" -c bash 2>/dev/null
else
    exec script -q "$local_log" bash 2>/dev/null
fi
```

The detection uses `script /dev/null -c true` to distinguish Linux (GNU util-linux `script`) from macOS (BSD `script`). On macOS, `-c` is not a valid option, so the test fails and the else branch runs — which is the correct macOS syntax `script -q logfile bash`.

On Linux, `script logfile -c bash` works (GNU script accepts options after positional args), but `script -c bash logfile` is the conventional order per the manpage. The current order is technically valid but unusual and may fail on non-GNU `script` implementations.

**Fix:** Use canonical ordering for Linux:

```bash
exec script -q -c bash "$local_log" 2>/dev/null
```

And update the detection test accordingly.

---

## Minor Issues

### N1 — Help and listener info box widths are inconsistent

`HELP_FILE` box is 80 chars wide; `LISTENER_INFO_FILE` box is 79 chars wide. Minor cosmetic inconsistency, but noticeable when switching between F1 and F9 displays.

---

### N2 — `head -n 1 >/dev/null` as "press Enter" is less clear than `read`

```bash
printf '\nPress Enter to close...'
head -n 1 >/dev/null
```

`head -n 1` works but reads a full line including the newline. In some edge cases (piped input, empty stdin in popup) it may return immediately without waiting. More idiomatic:

```bash
read -r _
```

---

### N3 — SSH host display format includes `SSH:` prefix, degrading fzf UX

```bash
echo "SSH:$h|SSH:$h"
```

The fzf display shows `SSH:hostname` instead of just `hostname`. For a large host list, the prefix adds visual noise. A cleaner format would separate the display label from the type tag:

```bash
echo "$h|SSH:$h"
```

(display `hostname`, action `SSH:hostname`)

---

### N4 — `build_data_files` uses `local` inside a loop in a function — no issue, but duplicate variable names shadow outer scope

In `build_data_files()`, `local name`, `local rest`, `local description` shadow identically-named variables in `parse_gsocket_hosts()`. Since they're separate functions this is fine, but the naming overlap can cause confusion during maintenance.

---

### N5 — Unreachable code after `exec` in `start_tmuxer` (lines 643–648)

```bash
exec script "$local_log" -c bash 2>/dev/null
echo "script exec failed, log: $local_log" >> /tmp/tmuxer_script_err.log
exec bash
```

`exec` replaces the current process — if it succeeds, the lines after it never run. If it fails (e.g., `script` binary missing or bad args), execution falls through to the error log line and `exec bash`. This is intentional as a fallback, but the `2>/dev/null` on the `exec script` line suppresses the error message that would explain why exec failed. Remove `2>/dev/null` so failures are visible.

---

## macOS vs Linux Compatibility Summary

| Feature | Linux | macOS (default) | Notes |
|---------|-------|-----------------|-------|
| `ip route get` | ✓ | ✗ | No `ip` command |
| `hostname -I` | ✓ | ✗ | Not supported |
| `stat -c '%a'` | ✓ | ✗ (falls to `stat -f '%Lp'`) | Handled via `\|\|` |
| `wait -n` | ✓ (bash ≥ 4.3) | ✗ (bash 3.2) | Breaks handler |
| `script -c` | ✓ | ✗ (detected by test) | Detection works |
| `netstat -tulip` | ✓ | ✗ | Only in remote recon cmd |
| `readlink -f` | ✓ | ✗ (no `-f`) | Not used; needed for C3 fix |

---

## Priority Fix Order

1. **C1** — Swap rm/kill order in session-closed hook (5-line fix)
2. **C3** — Fix `SELF` to resolve symlinks (10-line fix)
3. **C2** — Fix `%%q`/`%%s` to `%q`/`%s` in F2 non-fzf codegen (2-line fix)
4. **C4** — Replace `wait -n` with portable `wait` (5-line fix)
5. **S1** — Rewrite non-fzf menus to use `display-menu` correctly (significant rework)
6. **S4** — Add macOS `ifconfig` fallback for IP detection (3-line fix)
7. **S5** — Add startup dependency checks (10-line fix)
8. **S2** — Fix `install()` to use `$GSOCKET_HOSTS` (1-line fix)
