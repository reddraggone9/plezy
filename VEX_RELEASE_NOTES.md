Plezy Vex fork: an unofficial Plezy build for Android (Fire HD 10 and similar), vibe-coded by Claude Opus 5.5. See the README for details.

- Jellyfin "Original" quality automatically uses a server transcode when the hardware decoder or screen can't handle the file. Otherwise it direct-plays.
- Transcodes are capped to the screen resolution and tone-mapped on SDR screens.
- A failed direct play retries once as a transcode.
- Downloads: a file the device can't play downloads as a 1080p MP4 transcode (Settings → Downloads → Device-compatible downloads). This also applies to Keep Synced rules. Transcoded downloads can't resume: if the connection drops, the file restarts from the beginning (about 7 minutes per hour of video on a LAN).

New in 2.25.0-vex.5:
- Keep Synced refills in the background on Android (roughly every six hours), using the last active profile and saved sign-in. The existing Wi-Fi-only download setting is unchanged and honored; no new setting.
- Fix a first-open recovery race that could show an already-completed background download as queued.
- Downloads are handed to the existing native downloader, so the app does not have to remain open. Android's battery/network scheduling and force-stop behavior still apply.

New in 2.26.0-vex.3:
- Finished Jellyfin downloads pick up subtitles added on the server after they were downloaded (for example by Bazarr), and offline playback uses the server's current default audio and subtitle tracks. Checked about once a day with the background refill, on the same network policy; no need to download anything again.

New in 2.26.0-vex.4:
- Transcoded downloads that start while the app is in the background (Keep Synced refills, or the next download in a queue) no longer fail and hand their place to the next episode. Android 12+ doesn't let a background app start a foreground download, so such a download now runs as ordinary background work: if Android stops it, it starts over later on its own, and it moves to the foreground as soon as the app is opened. Setting Plezy Vex's battery usage to "Unrestricted" lets background downloads run in the foreground from the start.
- A transcode the server ended early is no longer saved as a finished download: its length is checked against the episode or movie, and it downloads again.
- A "Downloading…" notification no longer stays behind when nothing is downloading.

Install `plezy-vex-*-arm64-v8a.apk` (Fire HD 10, most phones) or via Obtainium. Installs alongside stock Plezy.
