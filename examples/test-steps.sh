#!/bin/bash
# Example HOOK_TEST: take a real screenshot with the Print Screen chord,
# then check what the extension did. gnome-ext-vm is on PATH and $GEV_VM
# is the VM under test, so no helper needs --vm. Exit non-zero to fail.

set -euo pipefail

gnome-ext-vm event step name=print-screen
gnome-ext-vm send-key Shift+Print
sleep 3
gnome-ext-vm screenshot --name after-print

# Anything the guest can tell you is a check: the journal, gsettings, files.
gnome-ext-vm event step name=check-journal
gnome-ext-vm ssh -- "journalctl --user -b --since '-1min' --no-pager | grep -q 'example: screenshot handled'"
