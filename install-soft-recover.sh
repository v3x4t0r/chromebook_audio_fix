#!/bin/bash
# install-soft-recover.sh
# Installs the user-level DSP recovery for kernels 7.2+:
#   - ~/.local/bin/sof-audio-soft-recover   (also run manually)
#   - ~/.config/systemd/user/sof-audio-soft-watchdog.service
#
# The root-level services from install-suspend-fix.sh must be off on
# these kernels (their PCI rebuild corrupts the card name):
#   sudo systemctl disable --now sof-audio-resume.service sof-audio-watchdog.service
#
# Usage (as your normal user, NOT sudo): bash install-soft-recover.sh

set -euo pipefail

[[ $EUID -ne 0 ]] || { echo "Run as your normal user, not with sudo."; exit 1; }

HERE=$(dirname "$(readlink -f "$0")")

install -D -m 755 "$HERE/sof-audio-soft-recover.sh" "$HOME/.local/bin/sof-audio-soft-recover"
install -D -m 644 "$HERE/sof-audio-soft-watchdog.service" \
    "$HOME/.config/systemd/user/sof-audio-soft-watchdog.service"
systemctl --user daemon-reload
systemctl --user enable sof-audio-soft-watchdog.service
systemctl --user restart sof-audio-soft-watchdog.service

echo "Installed:"
echo "  ~/.config/systemd/user/sof-audio-soft-watchdog.service — power-cycles the DSP when it wedges"
echo "  ~/.local/bin/sof-audio-soft-recover                    — run it to recover manually"
