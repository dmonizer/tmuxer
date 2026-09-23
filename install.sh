#!/usr/bin/env bash

# Install tmuxer without sudo. Override TMUXER_REF to install a tag or commit.
set -euo pipefail

repo="https://raw.githubusercontent.com/dmonizer/tmuxer"
ref="${TMUXER_REF:-master}"
install_dir="${TMUXER_INSTALL_DIR:-$HOME/.local/bin}"
destination="$install_dir/tmuxer"
temporary_file=""

cleanup() {
  [[ -n "$temporary_file" ]] && rm -f "$temporary_file"
}
trap cleanup EXIT

if ! command -v curl >/dev/null 2>&1; then
  echo "error: curl is required to install tmuxer" >&2
  exit 1
fi

mkdir -p "$install_dir"
temporary_file="$(mktemp "$install_dir/.tmuxer.XXXXXX")"
curl -fsSL "$repo/$ref/tmuxer.sh" -o "$temporary_file"
chmod 755 "$temporary_file"
mv -f "$temporary_file" "$destination"
temporary_file=""

"$destination" --setup

for dependency in tmux socat; do
  if ! command -v "$dependency" >/dev/null 2>&1; then
    echo "note: install required dependency: $dependency" >&2
  fi
done

case ":$PATH:" in
  *":$install_dir:"*) ;;
  *) echo "Add $install_dir to PATH, then run: tmuxer" ;;
esac

echo "installed: $destination"
