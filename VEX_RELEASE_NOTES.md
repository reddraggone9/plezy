Plezy Vex fork: an unofficial Plezy build for Android (Fire HD 10 and similar), vibe-coded by Claude Opus 5.5. See the README for details.

- Jellyfin "Original" quality automatically uses a server transcode when the hardware decoder or screen can't handle the file. Otherwise it direct-plays.
- Transcodes are capped to the screen resolution and tone-mapped on SDR screens.
- A failed direct play retries once as a transcode.
- Downloads: a file the device can't play downloads as a 1080p MP4 transcode (Settings → Downloads → Device-compatible downloads). This also applies to Keep Synced rules. Transcoded downloads can't resume: if the connection drops, the file restarts from the beginning (about 7 minutes per hour of video on a LAN).
- Downloads run only on unmetered networks by default; a phone hotspot doesn't count. Change this under Settings → Downloads.

Install `plezy-vex-*-arm64-v8a.apk` (Fire HD 10, most phones) or via Obtainium. Installs alongside stock Plezy.
