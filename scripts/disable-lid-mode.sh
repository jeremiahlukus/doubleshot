#!/bin/bash
#
# Reverses scripts/enable-lid-mode.sh: removes the sudoers rule and makes sure lid
# sleep is back on, in case it was left disabled.
#
#   sudo ./scripts/disable-lid-mode.sh
set -euo pipefail

SUDOERS_FILE=/etc/sudoers.d/doubleshot
MARKER_DIR="Library/Application Support/DoubleShot"

if [[ $EUID -ne 0 ]]; then
    echo "Run:  sudo $0" >&2
    exit 1
fi

# Restore normal lid behaviour first, while we still have the ability to do it.
/usr/bin/pmset -a disablesleep 0 || true
echo "Lid sleep restored to normal."

if [[ -f "$SUDOERS_FILE" ]]; then
    rm -f "$SUDOERS_FILE"
    echo "Removed $SUDOERS_FILE."
else
    echo "No $SUDOERS_FILE to remove."
fi

# Clear the armed marker so the app doesn't think a previous run died armed.
if [[ -n "${SUDO_USER:-}" ]]; then
    HOME_DIR=$(eval echo "~$SUDO_USER")
    rm -f "$HOME_DIR/$MARKER_DIR/lid-armed" 2>/dev/null || true
fi

echo "Done. 'Keep running with lid closed' will show as unavailable in DoubleShot."
