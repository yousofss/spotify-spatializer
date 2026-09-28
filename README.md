<img src="AppIcon.svg" width="128" alt="Spatialize app icon">

# Spatialize

Apple-quality Spatial Audio (Fixed mode) for Spotify on macOS.

macOS only spatializes audio from Apple's media frameworks, so Spotify never gets the
"Spatialize Stereo" treatment that works system-wide on iPhone. Spatialize fixes that by
measuring what Apple's spatializer actually does and applying the exact same processing to
Spotify in real time:

1. A tiny video file with sine sweeps is played in QuickTime, where macOS applies its real
   spatializer (Apple's render runs inside the playing app's process).
2. A Core Audio process tap records the spatialized output, and the sweeps are deconvolved
   into the four impulse responses of the render: L→L, L→R, R→L, R→R. These include
   everything: the binaural room responses, Apple's private tuning stages, and your
   Personalized Spatial Audio profile.
3. The menu bar app taps Spotify, mutes its direct output, convolves the audio with those
   impulse responses (partitioned FFT, ~11 ms latency), and plays the result.

The result is indistinguishable from Apple's own Fixed mode, because it literally is Apple's
own processing.

## Requirements

- macOS 14.2 or later (Core Audio process taps)
- AirPods or any headphones (measurement captures the render for whatever is the default
  output device; use the same device for playback)
- 48 kHz output (the default for AirPods)

## Build

```
./build.sh
```

Produces `build/Spatialize.app` and the measurement tools in `build/tools/`.

## Measure your impulse responses (one-time, ~2 minutes)

Your `irs.bin` is personal: it bakes in your Personalized Spatial Audio profile and the
loudness curve at your listening volume. Make it on your own machine:

```bash
cd build/tools
./make-sweep                    # writes sweep.mov

# 1. Connect your AirPods, open sweep.mov, press play briefly,
#    and set Control Center → Sound → AirPods → Spatialize Stereo → Fixed.
open sweep.mov

# 2. Record the spatialized pass:
./record-tap com.apple.QuickTimePlayerX fixed.wav 18 & sleep 1; \
osascript -e 'tell application "QuickTime Player"' \
          -e 'set current time of document 1 to 0' -e 'play document 1' -e 'end tell'; wait

# 3. Set Spatialize Stereo → Off, then record the reference pass:
./record-tap com.apple.QuickTimePlayerX off.wav 18 & sleep 1; \
osascript -e 'tell application "QuickTime Player"' \
          -e 'set current time of document 1 to 0' -e 'play document 1' -e 'end tell'; wait

./extract-ir fixed.wav off.wav irs.bin
```

Then launch Spatialize.app and use "Import IR File…" to load `irs.bin`. Re-measure if you
change your Personalized Spatial Audio profile, after major macOS updates, or if you want the
loudness captured at a different volume.

## Use

Launch the app; an AirPods icon appears in the menu bar. It automatically attaches to the
target apps whenever they play audio and follows output device changes. Keep the system's own
Spatialize Stereo setting Off while using it (the processing is already in the IRs).

The menu shows current status and offers Pause/Resume, a Target Apps picker, Use Built-in Mic,
IR import, and Quit. Target Apps lists every app currently registered for audio; check as many as you like
(Spotify is the default). Anything they play gets spatialized: Spotify, YouTube in Firefox,
games, whatever.

Use Built-in Mic (on by default) switches the input back to the Mac's microphone whenever macOS
picks the AirPods mic, since that forces the AirPods into low-quality call mode. Turn it off to
take calls on the AirPods mic.

Avoid targeting apps that already receive Apple's spatialization (Safari or QuickTime playing
video, Apple Music) since their audio would be processed twice.

## Repository layout

- `Sources/` – menu bar app and the convolution engine
- `Tools/` – `make-sweep`, `record-tap`, `extract-ir` measurement pipeline
- `build.sh` – builds the app bundle and tools

---

This project is fully vibecoded. It works great on my machine, but if something breaks on
yours or you see room for improvement, PRs are very welcome.
