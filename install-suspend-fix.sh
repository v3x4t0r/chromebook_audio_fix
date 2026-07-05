#!/bin/bash
# install-suspend-fix.sh
# Installs the suspend/resume workaround for the SOF DSP on Google Copano:
#   - /usr/local/sbin/sof-audio-recover       (recovery script, also run manually)
#   - /etc/systemd/system/sof-audio-resume.service
#       (runs the recovery automatically after every resume)
#
# Also removes the old /usr/lib/systemd/system-sleep/sof-audio hook if
# present: system-sleep hooks deadlock against systemd's user-session
# freezing (see sof-audio-resume.service for details).
#
# Usage: sudo bash install-suspend-fix.sh

set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo bash $0"; exit 1; }

HERE=$(dirname "$(readlink -f "$0")")

# The old sleep-hook approach hangs suspend/resume — make sure it is gone.
rm -f /usr/lib/systemd/system-sleep/sof-audio

install -m 755 "$HERE/sof-audio-recover.sh" /usr/local/sbin/sof-audio-recover
install -m 755 "$HERE/sof-audio-watchdog.sh" /usr/local/sbin/sof-audio-watchdog
install -m 644 "$HERE/sof-audio-resume.service" /etc/systemd/system/sof-audio-resume.service
install -m 644 "$HERE/sof-audio-watchdog.service" /etc/systemd/system/sof-audio-watchdog.service
systemctl daemon-reload
systemctl enable sof-audio-resume.service
systemctl enable --now sof-audio-watchdog.service

echo "Installed:"
echo "  /etc/systemd/system/sof-audio-resume.service   — resets the DSP after every resume"
echo "  /etc/systemd/system/sof-audio-watchdog.service — auto-recovers if the DSP wedges without a suspend"
echo "  /usr/local/sbin/sof-audio-recover              — run 'sudo sof-audio-recover' to recover manually"
echo "Removed old sleep hook: /usr/lib/systemd/system-sleep/sof-audio"
