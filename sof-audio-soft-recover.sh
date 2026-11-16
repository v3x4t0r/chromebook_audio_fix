#!/bin/bash
# sof-audio-soft-recover.sh
# Recovers a wedged SOF DSP on Google Copano (sof-rt5682) by letting the
# DSP power down and boot again — no root, no reboot, no PCI rebuild.
#
# The kernel runtime-suspends the DSP ~2 s after the last PCM is closed
# and downloads the firmware again on the next open. A wedged DSP only
# stays wedged because pipewire keeps the dead speaker PCM open (and
# hangs on it, ignoring SIGTERM). So: stop pipewire (kill it if it is
# stuck), wait for the DSP to reach "suspended", start pipewire again.
#
# Use this instead of sof-audio-recover.sh on kernels 7.2+, where the
# PCI remove/rescan brings the card back with a corrupted name.
#
# Usage (as your normal user, NOT sudo):
#   sof-audio-soft-recover.sh           recover once
#   sof-audio-soft-recover.sh --watch   follow the journal and recover
#                                       automatically (used by
#                                       sof-audio-soft-watchdog.service)

set -uo pipefail

AUDIO_PCI=0000:00:1f.3
PM_STATUS=/sys/bus/pci/devices/$AUDIO_PCI/power/runtime_status

[[ $EUID -ne 0 ]] || { echo "Run as your normal user, not with sudo."; exit 1; }

recover() {
    echo "[1/3] Stopping user audio stack (max 15s — pipewire may be stuck on the dead PCM)..."
    timeout 15 systemctl --user stop \
        pipewire.socket pipewire-pulse.socket \
        pipewire.service pipewire-pulse.service wireplumber.service || true
    # A pipewire hung in the kernel on the wedged PCM ignores SIGTERM.
    if pgrep -u "$EUID" -x pipewire >/dev/null; then
        echo "      pipewire is stuck — killing it."
        pkill -9 -u "$EUID" -x pipewire
    fi

    echo "[2/3] Waiting for the DSP to power down..."
    for _ in $(seq 1 20); do
        [[ "$(cat "$PM_STATUS" 2>/dev/null)" == "suspended" ]] && break
        sleep 1
    done
    [[ "$(cat "$PM_STATUS" 2>/dev/null)" == "suspended" ]] \
        || echo "      WARNING: DSP did not power down (something else holds the sound card open?)."

    echo "[3/3] Starting user audio stack..."
    systemctl --user reset-failed pipewire.service pipewire-pulse.service 2>/dev/null
    systemctl --user start pipewire.socket pipewire-pulse.socket wireplumber.service
    sleep 3

    if timeout 10 wpctl status 2>/dev/null | grep -q 'Internal Speakers'; then
        echo "Audio is back (Internal Speakers listed)."
    else
        echo "ERROR: Internal Speakers not listed after restart."
        return 1
    fi
}

watch() {
    # Same detection as sof-audio-watchdog.sh: the wedge logs this line
    # every ~6 s forever; 3 hits in 30 s means the permanent loop. Only
    # the untranslated prefix is matched (the errno text is localized).
    local pattern='snd_pcm_avail after recover:'
    local window=30 threshold=3 cooldown=120
    local count=0 window_start=0 last_recovery=0 now

    logger -t sof-audio-soft-watchdog "watching journal for wedged SOF DSP"
    while read -r _; do
        now=$(date +%s)
        if (( now - window_start > window )); then
            window_start=$now
            count=0
        fi
        (( count++ ))
        if (( count >= threshold )); then
            count=0
            if (( now - last_recovery >= cooldown )); then
                last_recovery=$now
                logger -t sof-audio-soft-watchdog "wedge loop detected — power-cycling the DSP"
                recover 2>&1 | logger -t sof-audio-soft-watchdog
            fi
        fi
    done < <(journalctl --user --follow --lines=0 --output=cat | grep --line-buffered --fixed-strings "$pattern")
}

case "${1:-}" in
    --watch) watch ;;
    "")      recover ;;
    *)       echo "Usage: $0 [--watch]"; exit 1 ;;
esac
