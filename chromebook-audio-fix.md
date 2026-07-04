# Fixing Audio on Google Chromebooks (sof-rt5682) on Linux

Applies to: Chromebooks with Intel Tiger Lake and Realtek RT5682 codec running Linux
(e.g. ASUS C436FA "Copano", and other Google TGL Chromebooks)

Tested on: Ubuntu 26.04 LTS, kernel 7.0.0, alsa-ucm-conf 1.2.15.3

---

## Symptom

Sound card is detected (`aplay -l` shows the card), but PipeWire/WirePlumber
only produces a "Dummy Output" sink. No real audio devices appear in system
settings or `wpctl status`.

---

## Step 1 — Confirm this is your problem

Run:
```bash
aplay -l
```

You should see something like:
```
card 0: sofrt5682 [sof-rt5682], device 0: smart373-spk (*) []
card 0: sofrt5682 [sof-rt5682], device 1: Headset (*) []
...
```

Then confirm UCM config is missing:
```bash
alsaucm -c sof-rt5682 list _verbs
```

If you get:
```
ALSA lib main.c:...: [error.ucm] failed to import sof-rt5682 use case configuration -2
```
...this guide applies to you.

---

## Step 2 — Find your card's driver name

```bash
cat /proc/asound/cards
```

Example output:
```
 0 [sofrt5682      ]: sof-rt5682 - sof-rt5682
                      Google-Copano-rev3
```

Note down:
- **Card driver** (middle column after `]:`): `sof-rt5682`
- **Card long name** (after ` - ` on first line, or second line): `sof-rt5682` or `Google-Copano-rev3`

The driver name is what goes in the `conf.d/` directory.

---

## Step 3 — List the PCM devices

```bash
aplay -l
arecord -l
```

Note all device numbers. For the Copano:
- `device 0`: Speaker (MAX98373 smart amp)
- `device 1`: Headset (RT5682 headphone + mic)
- `device 2–5`: HDMI 1–4
- `device 99`: DMIC (internal mic — **exclude this from UCM**, see note below)

---

## Step 4 — List the ALSA mixer controls

```bash
amixer -c 0 controls | grep -E "Switch|Volume|Jack"
```

You need to identify:
- Speaker enable switches: `Left Spk Switch`, `Right Spk Switch`
- Headphone output switches: `HPOL Playback Switch`, `HPOR Playback Switch`
- Headset mic switch: `Headset Mic Switch`
- Jack detection controls: `Headphone Jack`, `Headset Mic Jack`
- HDMI jack controls: `HDMI/DP,pcm=N Jack`

---

## Step 5 — Create the UCM config files

### 5a. Create the directory

```bash
sudo mkdir -p /usr/share/alsa/ucm2/sof-rt5682
```

### 5b. Create the main config file

```bash
sudo tee /usr/share/alsa/ucm2/sof-rt5682/sof-rt5682.conf << 'EOF'
Syntax 4

SectionUseCase."HiFi" {
	File "/sof-rt5682/HiFi.conf"
	Comment "Play HiFi quality Music"
}
EOF
```

### 5c. Create the HiFi use case file

Adjust the PCM device numbers and mixer control names to match what you found
in Steps 3 and 4.

```bash
sudo tee /usr/share/alsa/ucm2/sof-rt5682/HiFi.conf << 'EOF'
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
```

> **Note on DMIC (internal microphone):** The DMIC uses PCM device 99 on this
> hardware. The ALSA UCM plugin cannot create device aliases for numbers this
> high, causing the entire HiFi profile to be rejected with "Profile not
> supported". Leaving it out of the UCM is intentional. The headset mic still
> works via PCM device 1.

---

## Step 6 — Create the conf.d routing entry

ALSA 1.2.12+ searches `conf.d/${CardDriver}/` first and does **not** fall back
to the legacy `ucm2/<name>/` path by default. You must create this entry or
`alsaucm` will never find the config.

```bash
sudo mkdir -p /usr/share/alsa/ucm2/conf.d/sof-rt5682
sudo cp /usr/share/alsa/ucm2/sof-rt5682/sof-rt5682.conf \
        /usr/share/alsa/ucm2/conf.d/sof-rt5682/sof-rt5682.conf
```

---

## Step 7 — Verify UCM is found

```bash
alsaucm -c sof-rt5682 list _verbs
```

Expected output:
```
  0: HiFi
    Play HiFi quality Music
```

If you still get the "failed to import" error, check the driver name:
```bash
cat /proc/asound/cards
# The driver name (between ]: and -) must match your conf.d directory name
```

---

## Step 8 — Restart WirePlumber

Run as your **normal user** (not sudo):
```bash
systemctl --user restart wireplumber
sleep 3
wpctl status
```

You should now see real sinks under `Audio > Sinks`:
```
Audio
 ├─ Sinks:
 │      45. ... HDMI 2
 │      46. ... Headphones
 │  *   72. ... Internal Speakers   ← default
 ...
```

---

## Troubleshooting

### Still showing Dummy Output after restart

Run WirePlumber with debug to find the failing device:
```bash
systemctl --user stop wireplumber
WIREPLUMBER_DEBUG=3 wireplumber 2>&1 | grep -i "profile\|fail\|error\|open" &
sleep 4
wpctl status
kill %1
systemctl --user start wireplumber
```

Look for lines like:
```
Profile 'HiFi' mapping 'HiFi: DMIC: source': input PCM open failed
Profile HiFi not supported
```

The device name before "open failed" is the problem. Remove or fix that
`SectionDevice` block in `HiFi.conf` and restart WirePlumber again.

### Hardware test (verify ALSA works independently)

```bash
speaker-test -c 2 -D hw:sofrt5682,0 -t sine -l 1
```

If you hear a tone, the hardware is fine and the issue is in WirePlumber/UCM only.

### Which conf.d path does ALSA actually search?

```bash
strace -e trace=access,openat alsaucm -c sof-rt5682 list _verbs 2>&1 \
  | grep -E "ucm|conf\.d"
```

This shows the exact paths ALSA probes, which tells you the correct directory
name to use in `conf.d/`.

---

## Audio dies after suspend/resume (DSP wedge)

**Symptom:** Audio works after boot, then "randomly" disappears. Restarting
WirePlumber does not help; only a reboot used to fix it.

**Root cause:** It is not random — the SOF DSP firmware does not survive
s2idle suspend on this hardware. ~90 seconds after resume, the speaker PCM
enters a permanent error loop. Diagnose with:

```bash
journalctl --user -u pipewire -n 5
# spa.alsa: hw:sofrt5682,0p: (45 suppressed) snd_pcm_avail after recover: Broken pipe
#   ...repeating every ~6 seconds → the DSP is wedged
journalctl -b -1 | grep -E "PM: suspend (entry|exit)"
#   ...confirms the wedge follows a suspend/resume cycle
```

`aplay -l` still lists the card and `wpctl status` may hang — userspace
restarts can't fix it because the dead firmware lives in the DSP itself.

**Fix without rebooting:** tear down the audio PCI device and rescan, which
forces a fresh firmware download to the DSP (verified working):

```bash
sudo bash sof-audio-recover.sh
```

**Permanent fix:** install the systemd sleep hook, which stops the audio
stack before suspend and resets the DSP after every resume:

```bash
sudo bash install-suspend-fix.sh
```

Files:
- `sof-audio-recover.sh` — manual recovery (also installed as
  `/usr/local/sbin/sof-audio-recover`)
- `sof-audio-sleep-hook.sh` — installed as
  `/usr/lib/systemd/system-sleep/sof-audio`
- `install-suspend-fix.sh` — installer for both

**Note on boot-time DMIC errors:** at every PipeWire start the kernel logs a
burst of `sof_ipc3_pcm_hw_params: pcm100 (DMIC16kHz) ... ipc failed` errors.
This is PipeWire probing the DMIC PCM that the topology exposes but the
firmware rejects (NHLT reports 0 DMICs). It is harmless noise — the DSP
survives it — and unrelated to the suspend wedge above.

---

## Making it survive package upgrades

If `alsa-ucm-conf` is upgraded, it may overwrite files in
`/usr/share/alsa/ucm2/sof-rt5682/` but will not remove the `conf.d/sof-rt5682/`
directory (which we created). Back up the files:

```bash
mkdir -p ~/audio-ucm-backup
cp /usr/share/alsa/ucm2/sof-rt5682/*.conf ~/audio-ucm-backup/
cp /usr/share/alsa/ucm2/conf.d/sof-rt5682/*.conf ~/audio-ucm-backup/
```

After any upgrade that breaks audio again, restore with:
```bash
sudo cp ~/audio-ucm-backup/sof-rt5682.conf /usr/share/alsa/ucm2/sof-rt5682/
sudo cp ~/audio-ucm-backup/HiFi.conf /usr/share/alsa/ucm2/sof-rt5682/
sudo cp ~/audio-ucm-backup/sof-rt5682.conf /usr/share/alsa/ucm2/conf.d/sof-rt5682/
systemctl --user restart wireplumber
```
