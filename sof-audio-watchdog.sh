#!/bin/bash
# sof-audio-watchdog.sh
# Installed as /usr/local/sbin/sof-audio-watchdog by install-suspend-fix.sh,
# run by sof-audio-watchdog.service.
#
# The SOF DSP on Google Copano can wedge even without a suspend (seen
# 2026-07-04: speaker PCM died ~6 min into a fresh boot, audibly looping
# the last DMA buffer). When wedged, pipewire logs
# "snd_pcm_avail after recover: Broken pipe" every ~6 s forever.
#
# This watchdog follows the journal for that signature: 3 hits inside a
# 30 s window means the permanent loop (a one-off recovered xrun does not
# repeat), so it runs sof-audio-recover. A cooldown stops it from ever
# recovering more often than once per 2 minutes.

PATTERN='snd_pcm_avail after recover: Broken pipe'
WINDOW=30       # seconds; loop logs every ~6 s
THRESHOLD=3     # hits within WINDOW that mean "wedged"
COOLDOWN=120    # seconds between recoveries

count=0
window_start=0
last_recovery=0

logger -t sof-audio-watchdog "watching journal for wedged SOF DSP"

while read -r _; do
    now=$(date +%s)
    if (( now - window_start > WINDOW )); then
        window_start=$now
        count=0
    fi
    (( count++ ))
    if (( count >= THRESHOLD )); then
        count=0
        # The resume service reacts to the same wedge after suspend; while
        # it is running, these log lines are the wedge it is already
        # fixing — do not pile a second recovery on top.
        resume_state=$(systemctl is-active sof-audio-resume.service)
        if [[ "$resume_state" == "active" || "$resume_state" == "activating" ]]; then
            logger -t sof-audio-watchdog "loop detected but sof-audio-resume.service is already recovering; skipping"
            last_recovery=$now
            continue
        fi
        if (( now - last_recovery >= COOLDOWN )); then
            last_recovery=$now
            logger -t sof-audio-watchdog "Broken-pipe loop detected — running sof-audio-recover"
            /usr/local/sbin/sof-audio-recover \
                && logger -t sof-audio-watchdog "recovery finished" \
                || logger -t sof-audio-watchdog "recovery FAILED (exit $?)"
        else
            logger -t sof-audio-watchdog "loop detected but in cooldown ($((now - last_recovery))s since last recovery)"
        fi
    fi
# NOTE: journalctl's own --grep replays historical matches even with
# --lines=0 (observed: instant false trigger at service start), so the
# filtering must be done by grep on a follow-only stream.
done < <(journalctl --follow --lines=0 --output=cat | grep --line-buffered --fixed-strings "$PATTERN")
