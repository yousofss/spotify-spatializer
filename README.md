<img src="AppIcon.svg" width="128" alt="Spatialize app icon">

# Spatialize

Apple-quality Spatial Audio (Fixed mode) for Spotify on macOS.

macOS only spatializes audio from Apple's media frameworks, so Spotify never gets the
"Spatialize Stereo" treatment that works system-wide on iPhone. Spatialize fixes that by
measuring what Apple's spatializer actually does and applying the exact same processing to
Spotify in real time:

1. Spatialize plays sine sweeps through Apple's own media renderer, where macOS applies its
   real spatializer (Apple's render runs inside the playing app's process).
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

Produces `build/Spatialize.app`.

## Measure (one-time, about a minute)

The measurement is personal: it bakes in your Personalized Spatial Audio profile and the
loudness curve at your listening volume. On first launch Spatialize walks you through it:

1. Put your AirPods on and pause other audio.
2. While Spatialize plays a test sound, open Control Center → Sound and set Spatialize Stereo
   to Fixed for your AirPods, then click Measure.
3. Spatialize measures silently for about 40 seconds, chimes, and starts using the result.

Re-measure with "Measure Spatial Audio…" in the menu if you change your Personalized Spatial
Audio profile, after major macOS updates, or to capture the loudness at a different volume.

## Use

Launch the app; an AirPods icon appears in the menu bar. It automatically attaches to the
target apps whenever they play audio and follows output device changes. Keep the system's own
Spatialize Stereo setting Off for the target apps (the processing is already in the IRs).

The menu shows current status and offers Pause/Resume, a Target Apps picker, Use Built-in Mic,
Measure Spatial Audio…, and Quit. Target Apps lists every app currently registered for audio; check as many as you like
(Spotify is the default). Anything they play gets spatialized: Spotify, YouTube in Firefox,
games, whatever.

Use Built-in Mic (on by default) switches the input back to the Mac's microphone whenever macOS
picks the AirPods mic, since that forces the AirPods into low-quality call mode. Turn it off to
take calls on the AirPods mic.

Avoid targeting apps that already receive Apple's spatialization (Safari or QuickTime playing
video, Apple Music) since their audio would be processed twice.

## Repository layout

- `Sources/`: menu bar app, convolution engine, and measurement
- `Tests/`: round-trip check for the IR extraction
- `build.sh`: builds the app bundle

---

This project is fully vibecoded. It works great on my machine, but if something breaks on
yours or you see room for improvement, PRs are very welcome.
