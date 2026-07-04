#!/bin/bash
# install-suspend-fix.sh
# Installs the suspend/resume workaround for the SOF DSP on Google Copano:
#   - /usr/lib/systemd/system-sleep/sof-audio   (auto-reset DSP around suspend)
#   - /usr/local/sbin/sof-audio-recover         (manual recovery, no reboot)
#
# Usage: sudo bash install-suspend-fix.sh

set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo bash $0"; exit 1; }

HERE=$(dirname "$(readlink -f "$0")")

install -m 755 "$HERE/sof-audio-sleep-hook.sh" /usr/lib/systemd/system-sleep/sof-audio
install -m 755 "$HERE/sof-audio-recover.sh" /usr/local/sbin/sof-audio-recover

echo "Installed:"
echo "  /usr/lib/systemd/system-sleep/sof-audio  — resets the DSP automatically on every suspend/resume"
echo "  /usr/local/sbin/sof-audio-recover        — run 'sudo sof-audio-recover' if audio ever wedges anyway"
