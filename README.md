# Ding Detective

A floating desktop widget + menu bar item that tells you which app (or website) just made that sound, keeps a catalogue of every ding, and links you straight back to the source.

## How it knows

| Source | What it catches | Permission |
| --- | --- | --- |
| CoreAudio process list | Apps playing their own sounds (Slack, Chrome tabs, Messages…) | none |
| Per-app audio taps | Real sound onsets, ignoring silent streams; filters out music/video/calls (>5 s) | System Audio Recording |
| Non-app audio tap | Sounds macOS plays for notification banners and alerts | System Audio Recording |
| Notification database | Which app/site sent it and what it said; matched to the sound by time | Full Disk Access |

Clicking a ding opens the app, or for browser notifications, the sending site in that browser. Hover a row to open notification settings for that app or stop tracking it.

## Build

```bash
./build.sh
open "build/Ding Detective.app"
```

Needs only the Xcode Command Line Tools. Grant **System Audio Recording** (prompted on launch) and **Full Disk Access** (add the app manually) in System Settings → Privacy & Security.

The app is ad-hoc signed. If a rebuild ever causes the permissions to stop working, reset them and grant again:

```bash
tccutil reset AudioCapture com.cheapassjimmy.dingdetective
tccutil reset SystemPolicyAllFiles com.cheapassjimmy.dingdetective
```

## Files

- Data: `~/Library/Application Support/Ding Detective/dings.json`
- Debug log: `~/Library/Logs/DingDetective.log`
- Right-click the menu bar bell for: float vs. sit-on-desktop, ignored apps, launch at login, clear history.
