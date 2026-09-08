#!/bin/bash
#
# Grants DoubleShot permission to toggle lid-close sleep without a password.
#
# Why this is needed: macOS power assertions (what DoubleShot already uses) only defer
# *idle* sleep. Closing the lid is a separate forced path, and the only thing that stops
# it is `pmset -a disablesleep`, which requires root.
#
# What this installs: a sudoers rule permitting EXACTLY two commands and nothing else —
# turning lid sleep off, and turning it back on. It grants no other privilege.
#
#   sudo ./scripts/enable-lid-mode.sh
#
# Undo with ./scripts/disable-lid-mode.sh
set -euo pipefail

SUDOERS_FILE=/etc/sudoers.d/doubleshot
PMSET=/usr/bin/pmset

if [[ $EUID -ne 0 ]]; then
    echo "This needs root, because changing lid-sleep behaviour does." >&2
    echo "Run:  sudo $0" >&2
    exit 1
fi

# SUDO_USER is the human who ran sudo; $USER would be root here.
TARGET_USER="${SUDO_USER:-}"
if [[ -z "$TARGET_USER" || "$TARGET_USER" == "root" ]]; then
    echo "Could not determine which user to grant this to." >&2
    echo "Run it via sudo from your normal account, not as root directly." >&2
    exit 1
fi

if [[ ! -x "$PMSET" ]]; then
    echo "Expected pmset at $PMSET but it isn't there. Aborting rather than guessing." >&2
    exit 1
fi

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

cat > "$TMP" <<EOF
# Installed by DoubleShot (scripts/enable-lid-mode.sh)
#
# Lets DoubleShot keep the Mac running with the lid closed while Claude Code is
# working. Scoped to these two exact commands; no other privilege is granted.
# Remove with: sudo rm $SUDOERS_FILE
$TARGET_USER ALL=(root) NOPASSWD: $PMSET -a disablesleep 1, $PMSET -a disablesleep 0
EOF

chmod 0440 "$TMP"

# Never install a sudoers file without checking it first — a malformed one can lock
# you out of sudo entirely.
if ! visudo -cqf "$TMP"; then
    echo "Generated sudoers file failed validation. Nothing was installed." >&2
    exit 1
fi

install -m 0440 -o root -g wheel "$TMP" "$SUDOERS_FILE"

if ! visudo -cqf /etc/sudoers; then
    echo "sudoers validation failed after install; rolling back." >&2
    rm -f "$SUDOERS_FILE"
    exit 1
fi

echo "Installed $SUDOERS_FILE for user '$TARGET_USER'."
echo
echo "Granted, and nothing more:"
echo "  $PMSET -a disablesleep 1     (stop sleeping on lid close)"
echo "  $PMSET -a disablesleep 0     (restore normal behaviour)"
echo
echo "Now enable 'Keep running with lid closed' in the DoubleShot menu."
echo "Undo any time with: sudo rm $SUDOERS_FILE"
