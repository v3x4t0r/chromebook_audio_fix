#!/bin/bash
# sof-audio-sleep-hook.sh
# Installed as /usr/lib/systemd/system-sleep/sof-audio by install-suspend-fix.sh.
#
# The SOF DSP on Google Copano (sof-rt5682) does not survive s2idle
# suspend: after resume the speaker PCM is permanently broken
# ("snd_pcm_avail after recover: Broken pipe") until the firmware is
# reloaded. systemd runs this script with $1=pre before sleep and
# $1=post after resume.
#
# pre:  stop the user audio stack so no PCM is open across suspend.
# post: remove + rescan the audio PCI device (forces a fresh firmware
#       download to the DSP), then start the user audio stack again.

AUDIO_PCI=0000:00:1f.3

# First regular (uid >= 1000) logged-in user owns the pipewire session.
read -r AUDIO_UID AUDIO_USER < <(loginctl list-users --no-legend | awk '$1 >= 1000 {print $1, $2; exit}')
[ -n "${AUDIO_USER:-}" ] || exit 0

run_user() {
    setpriv --reuid="$AUDIO_UID" --regid="$AUDIO_UID" --init-groups \
        env XDG_RUNTIME_DIR="/run/user/$AUDIO_UID" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$AUDIO_UID/bus" \
        "$@"
}

case "$1" in
    pre)
        run_user systemctl --user stop \
            pipewire.socket pipewire-pulse.socket \
            pipewire.service pipewire-pulse.service wireplumber.service
        ;;
    post)
        if [ -e "/sys/bus/pci/devices/$AUDIO_PCI" ]; then
            echo 1 > "/sys/bus/pci/devices/$AUDIO_PCI/remove"
            sleep 1
        fi
        echo 1 > /sys/bus/pci/rescan
        sleep 2
        run_user systemctl --user start \
            pipewire.socket pipewire-pulse.socket wireplumber.service
        ;;
esac

exit 0
