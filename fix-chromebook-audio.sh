#!/bin/bash
# fix-chromebook-audio.sh
# Fixes "Dummy Output" on ASUS Chromebook (Google Copano) with sof-rt5682
# on Ubuntu 26.04 (or any distro with alsa-ucm-conf 1.2.12+).
#
# Usage: sudo bash fix-chromebook-audio.sh

set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo bash $0"; exit 1; }

REAL_USER="${SUDO_USER:-}"
[[ -n "$REAL_USER" ]] || { echo "Use sudo, not su/root directly."; exit 1; }
REAL_UID=$(id -u "$REAL_USER")

echo "[1/4] Writing UCM config files..."

UCM2=/usr/share/alsa/ucm2

sudo mkdir -p "$UCM2/sof-rt5682"
sudo mkdir -p "$UCM2/conf.d/sof-rt5682"

# ── Main config ──────────────────────────────────────────────────────────────
sudo tee "$UCM2/sof-rt5682/sof-rt5682.conf" > /dev/null <<'EOF'
Syntax 4

SectionUseCase."HiFi" {
	File "/sof-rt5682/HiFi.conf"
	Comment "Play HiFi quality Music"
}
EOF

# ── HiFi use case ────────────────────────────────────────────────────────────
sudo tee "$UCM2/sof-rt5682/HiFi.conf" > /dev/null <<'EOF'
SectionVerb {
	Value {
		TQ "HiFi"
	}

	EnableSequence [
		disdevall ""
	]
}

SectionDevice."Speaker" {
	Comment "Internal Speakers"

	EnableSequence [
		cset "name='Left Spk Switch' on"
		cset "name='Right Spk Switch' on"
	]

	DisableSequence [
		cset "name='Left Spk Switch' off"
		cset "name='Right Spk Switch' off"
	]

	Value {
		PlaybackPriority 100
		PlaybackPCM "hw:${CardId},0"
		PlaybackChannels 2
	}
}

SectionDevice."Headphones" {
	Comment "Headphones"

	EnableSequence [
		cset "name='HPOL Playback Switch' 1"
		cset "name='HPOR Playback Switch' 1"
	]

	DisableSequence [
		cset "name='HPOL Playback Switch' 0"
		cset "name='HPOR Playback Switch' 0"
	]

	Value {
		PlaybackPriority 200
		PlaybackPCM "hw:${CardId},1"
		PlaybackChannels 2
		JackControl "Headphone Jack"
	}
}

SectionDevice."Headset Mic" {
	Comment "Headset Microphone"

	EnableSequence [
		cset "name='Headset Mic Switch' on"
	]

	DisableSequence [
		cset "name='Headset Mic Switch' off"
	]

	Value {
		CapturePriority 200
		CapturePCM "hw:${CardId},1"
		CaptureChannels 2
		JackControl "Headset Mic Jack"
	}
}

SectionDevice."HDMI1" {
	Comment "HDMI 1"

	Value {
		PlaybackPriority 50
		PlaybackPCM "hw:${CardId},2"
		JackControl "HDMI/DP,pcm=2 Jack"
	}
}

SectionDevice."HDMI2" {
	Comment "HDMI 2"

	Value {
		PlaybackPriority 50
		PlaybackPCM "hw:${CardId},3"
		JackControl "HDMI/DP,pcm=3 Jack"
	}
}

SectionDevice."HDMI3" {
	Comment "HDMI 3"

	Value {
		PlaybackPriority 50
		PlaybackPCM "hw:${CardId},4"
		JackControl "HDMI/DP,pcm=4 Jack"
	}
}

SectionDevice."HDMI4" {
	Comment "HDMI 4"

	Value {
		PlaybackPriority 50
		PlaybackPCM "hw:${CardId},5"
		JackControl "HDMI/DP,pcm=5 Jack"
	}
}
EOF

# ── conf.d routing entry (required by ALSA 1.2.12+) ─────────────────────────
sudo cp "$UCM2/sof-rt5682/sof-rt5682.conf" \
        "$UCM2/conf.d/sof-rt5682/sof-rt5682.conf"

echo "[2/4] Verifying UCM is recognised..."
alsaucm -c sof-rt5682 list _verbs 2>/dev/null | grep -q "HiFi" \
    || { echo "ERROR: UCM still not found. Something went wrong."; exit 1; }
echo "      OK — HiFi verb found."

echo "[3/4] Restarting WirePlumber..."
sudo -u "$REAL_USER" \
    XDG_RUNTIME_DIR="/run/user/$REAL_UID" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$REAL_UID/bus" \
    systemctl --user restart wireplumber
sleep 3

echo "[4/4] Backing up UCM files to ~/audio-ucm-backup..."
BACKUP="/home/$REAL_USER/audio-ucm-backup"
mkdir -p "$BACKUP"
cp "$UCM2/sof-rt5682"/*.conf "$BACKUP/"
cp "$UCM2/conf.d/sof-rt5682"/*.conf "$BACKUP/"
chown -R "$REAL_USER:$REAL_USER" "$BACKUP"

echo ""
echo "Done. Current audio status:"
sudo -u "$REAL_USER" \
    XDG_RUNTIME_DIR="/run/user/$REAL_UID" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$REAL_UID/bus" \
    wpctl status 2>/dev/null | grep -A 15 "^Audio" || true

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
if [[ -f "$SCRIPT_DIR/install-suspend-fix.sh" ]]; then
    echo ""
    echo "Installing suspend/resume DSP reset hook..."
    bash "$SCRIPT_DIR/install-suspend-fix.sh"
fi

echo ""
echo "If you see 'Internal Speakers' above, audio is working."
echo "To restore after a system upgrade that breaks audio:"
echo "  sudo cp $BACKUP/*.conf $UCM2/sof-rt5682/"
echo "  sudo cp $BACKUP/sof-rt5682.conf $UCM2/conf.d/sof-rt5682/"
echo "  systemctl --user restart wireplumber"
