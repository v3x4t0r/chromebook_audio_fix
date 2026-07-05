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

# Never allow two recoveries at once: the resume service and the watchdog
# can both react to the same wedge, and interleaved PCI remove/rescan
# cycles leave the card in a broken (silent) state.
exec 9>/run/sof-audio-recover.lock
flock -n 9 || { echo "Another sof-audio recovery is already running; skipping."; exit 0; }

# Owner of the pipewire session: the sudo caller, or (when run from
# sof-audio-resume.service, where SUDO_USER is unset) the first regular
# logged-in user.
REAL_USER="${SUDO_USER:-}"
if [[ -z "$REAL_USER" ]]; then
    read -r _ REAL_USER < <(loginctl list-users --no-legend | awk '$1 >= 1000 {print $1, $2; exit}')
fi
[[ -n "${REAL_USER:-}" ]] || { echo "No logged-in user found."; exit 1; }
REAL_UID=$(id -u "$REAL_USER")

run_user() {
    sudo -u "$REAL_USER" \
        XDG_RUNTIME_DIR="/run/user/$REAL_UID" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$REAL_UID/bus" \
        "$@"
}

echo "[1/5] Stopping user audio stack (max 15s — pipewire may be stuck on the dead PCM)..."
# When the DSP is wedged, pipewire can hang in a kernel call on the PCM and
# ignore SIGTERM; don't wait for it. The PCI remove below force-disconnects
# the card, which wakes the stuck process with ENODEV and unblocks it.
timeout 15 sudo -u "$REAL_USER" \
    XDG_RUNTIME_DIR="/run/user/$REAL_UID" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$REAL_UID/bus" \
    systemctl --user stop \
    pipewire.socket pipewire-pulse.socket \
    pipewire.service pipewire-pulse.service wireplumber.service || true

# After resume, the platform needs time to settle before the hardware
# surgery below sticks (see sof-audio-resume.service, which sets this).
if [[ "${SOF_SETTLE:-0}" -gt 0 ]]; then
    echo "Waiting ${SOF_SETTLE}s for the platform to settle after resume..."
    sleep "$SOF_SETTLE"
fi

echo "[2/5] Removing audio PCI device (unloads wedged DSP firmware)..."
if [[ -e /sys/bus/pci/devices/$AUDIO_PCI ]]; then
    echo 1 > "/sys/bus/pci/devices/$AUDIO_PCI/remove"
    sleep 1
fi

echo "[3/5] Rebinding audio I2C chips (codec jack detect + speaker amps)..."
# Both must happen while the PCI device is removed — rebinding under a
# live card corrupts the DSP pipeline refcounts (widget ... count -1).
#
# rt5682 codec: a card rebuild leaves it falsely reporting headphones
# plugged ('Headphone Jack' latches on); a re-probe redoes jack detection.
# max98373 amps: s2idle suspend leaves them silently dead in a way the
# PCI reset alone does not repair (verified 2026-07-04: every recovery
# without the amp re-probe came back silent; the one with it was audible).
CODEC=i2c-10EC5682:00
CODEC_DRV=/sys/bus/i2c/drivers/rt5682
if [[ -e "$CODEC_DRV/$CODEC" ]]; then
    echo "$CODEC" > "$CODEC_DRV/unbind"
    sleep 1
    echo "$CODEC" > "$CODEC_DRV/bind"
    sleep 1
fi
AMP_DRV=/sys/bus/i2c/drivers/max98373
for amp in i2c-MX98373:00 i2c-MX98373:01; do
    if [[ -e "$AMP_DRV/$amp" ]]; then
        echo "$amp" > "$AMP_DRV/unbind"
        sleep 1
        echo "$amp" > "$AMP_DRV/bind"
        sleep 1
    fi
done

echo "[4/5] Rescanning PCI bus (re-downloads firmware to DSP)..."
echo 1 > /sys/bus/pci/rescan
sleep 2

grep -q sofrt5682 /proc/asound/cards \
    || { echo "ERROR: sound card did not come back after rescan."; exit 1; }

echo "[5/5] Starting user audio stack..."
# restart, not start: if the stop above timed out, the units are still
# marked active and a plain start would be a no-op on a broken pipewire.
run_user systemctl --user restart \
    pipewire.socket pipewire-pulse.socket wireplumber.service
sleep 3

echo ""
timeout 10 sudo -u "$REAL_USER" XDG_RUNTIME_DIR="/run/user/$REAL_UID" \
    wpctl status 2>/dev/null | sed -n '/^Audio/,/^Video/p' | head -20 || true
echo ""
echo "If 'Internal Speakers' is listed above, audio is recovered."
