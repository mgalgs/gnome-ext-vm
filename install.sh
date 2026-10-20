#!/bin/bash
# Install gnome-ext-vm: link bin/gnome-ext-vm into ~/.local/bin.
#
# Usage: ./install.sh [--check]
#
# The link points back into this checkout, so `git pull` is the upgrade.
# --check reports missing host tools and installs nothing.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$HOME/.local/bin"

missing=()
for tool in virsh virt-install qemu-img passt genisoimage magick rsync ssh scp flock curl; do
    command -v "$tool" >/dev/null || missing+=("$tool")
done
if (( ${#missing[@]} )); then
    echo "Missing host tools: ${missing[*]}"
    echo "  Arch:   pacman -S libvirt qemu-full virt-install passt cdrtools imagemagick rsync"
    echo "  Fedora: dnf install libvirt qemu-kvm virt-install passt genisoimage ImageMagick rsync"
fi
command -v virt-viewer >/dev/null || echo "Optional: virt-viewer (for gnome-ext-vm viewer)"

if [[ "${1:-}" == --check ]]; then
    (( ${#missing[@]} == 0 ))
    exit
fi

mkdir -p "$BIN_DIR"
target="$BIN_DIR/gnome-ext-vm"
source="$REPO_DIR/bin/gnome-ext-vm"
if [[ -L "$target" && "$(readlink "$target")" == "$source" ]]; then
    echo "gnome-ext-vm: already linked"
elif [[ -e "$target" && ! -L "$target" ]]; then
    echo "gnome-ext-vm: $target exists and is not a symlink; leaving it" >&2
    exit 1
else
    ln -sfn "$source" "$target"
    echo "gnome-ext-vm: linked $target -> $source"
fi

case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) echo "Add $BIN_DIR to your PATH." ;;
esac
