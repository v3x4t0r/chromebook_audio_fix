#!/bin/bash
# sof-audio-recover.sh
# Recovers a wedged SOF DSP on Google Copano (sof-rt5682) WITHOUT rebooting.
#
# Symptom: audio worked, then disappeared (typically after suspend/resume);
# pipewire journal spams "snd_pcm_avail after recover: Broken pipe" and
# `wpctl status` hangs. Restarting wireplumber does not help because the
# DSP firmware itself is dead.
#
# Fix: tear down the audio PCI device and rescan the bus, which forces a
# fresh firmware download to the DSP — same effect as a reboot, in ~5s.
#
# Usage: sudo bash sof-audio-recover.sh

set -euo pipefail

AUDIO_PCI=0000:00:1f.3

[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo bash $0"; exit 1; }

REAL_USER="${SUDO_USER:-}"
[[ -n "$REAL_USER" ]] || { echo "Use sudo, not su/root directly."; exit 1; }
REAL_UID=$(id -u "$REAL_USER")

run_user() {
    sudo -u "$REAL_USER" \
        XDG_RUNTIME_DIR="/run/user/$REAL_UID" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$REAL_UID/bus" \
        "$@"
}

echo "[1/4] Stopping user audio stack..."
run_user systemctl --user stop \
    pipewire.socket pipewire-pulse.socket \
    pipewire.service pipewire-pulse.service wireplumber.service || true

echo "[2/4] Removing audio PCI device (unloads wedged DSP firmware)..."
if [[ -e /sys/bus/pci/devices/$AUDIO_PCI ]]; then
    echo 1 > "/sys/bus/pci/devices/$AUDIO_PCI/remove"
    sleep 1
fi

echo "[3/4] Rescanning PCI bus (re-downloads firmware to DSP)..."
echo 1 > /sys/bus/pci/rescan
sleep 2

grep -q sofrt5682 /proc/asound/cards \
    || { echo "ERROR: sound card did not come back after rescan."; exit 1; }

echo "[4/4] Starting user audio stack..."
run_user systemctl --user start \
    pipewire.socket pipewire-pulse.socket wireplumber.service
sleep 3

echo ""
run_user wpctl status 2>/dev/null | sed -n '/^Audio/,/^Video/p' | head -20 || true
echo ""
echo "If 'Internal Speakers' is listed above, audio is recovered."
