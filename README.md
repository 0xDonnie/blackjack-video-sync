# blackjack-video-sync

**Keep your local video library in sync with YouTube playlists — automatically, safely, and without ever touching files you already have.**

A Windows PowerShell tool with a WinForms GUI that mirrors YouTube playlists as MP4 files on a local folder, NAS, or any network drive. Companion to [blackjack-music-sync](https://github.com/0xDonnie/blackjack-music-sync) — same architecture, same matching logic, but for video.

---

## How it works

For each playlist, every time you sync:

1. Fetches the full video list and metadata from YouTube (no download yet)
2. Reads what you already have locally
3. Matches existing files to YouTube videos using **duration + title** — no re-downloads, no duplicates
4. Records matched IDs in `_id_map.txt` (the permanent source of truth per folder)
5. Downloads only the videos that are genuinely missing as MP4, capped at the resolution you choose
6. Embeds metadata + thumbnail
7. Updates the `.m3u` playlist file so VLC and other media players stay in sync

It **never deletes** anything. It **never overwrites** anything. Existing files are untouched.

---

## Requirements

- Windows with **PowerShell 7+**
- [yt-dlp](https://github.com/yt-dlp/yt-dlp) — `winget install yt-dlp`
- [ffmpeg](https://ffmpeg.org) (includes ffprobe) — `winget install ffmpeg`
- A destination folder — local, NAS, or network drive

---

## Setup

**1. Clone the repo**
```powershell
git clone https://github.com/0xDonnie/blackjack-video-sync
cd blackjack-video-sync
```

**2. Create your config**
```powershell
Copy-Item video_config.example.ps1 video_config.ps1
```
Open `video_config.ps1` and fill in:
- `$BASE_DIR` — where videos go
- `$MAX_VIDEO_HEIGHT` — quality cap (720, 1080, 1440, 2160…)
- `$PLAYLISTS` — your YouTube playlist URLs

**3. Launch the GUI**

Double-click **`blackjack-video-sync.vbs`** and the GUI opens with no console window.

Alternative from terminal:
```powershell
pwsh video_gui_v1.ps1
```

---

## GUI features

### Sync tab
- Playlist grid with Local / YouTube / Unavailable counts and status
- **Refresh Status** — checks every playlist against YouTube
- **Sync Selected** / **Sync All** — downloads missing videos
- **Stop sync** — kills the running sync and any yt-dlp/ffmpeg children
- **Add playlist** — paste a URL, click Fetch Name, save
- **Remove** — delete a playlist from config (does NOT touch files on disk)
- Live progress bar with sliding-window ETA
- Streaming log of yt-dlp output

### Monitor tab
- **Schedule…** — register a Windows Scheduled Task that auto-checks for new videos (daily / 3-day / weekly / monthly / semestral)
- **Check now** — run the update check immediately
- **Pending updates** — list of playlists with new videos waiting to download
- **Sync pending now** — one click downloads only what's pending

---

## File structure

Each playlist folder ends up looking like this:

```
Videos\
  My Video Playlist\
    01. Some video.mp4
    02. Another video.mp4
    ...
    My Video Playlist.m3u    # auto-updated playlist for VLC etc
    _id_map.txt              # maps filename => YouTube ID (source of truth)
    .archive                 # used by yt-dlp to skip already-downloaded videos
    _unavailable.txt         # YouTube IDs that can't be downloaded (private/blocked)
```

---

## Why duration + title matching?

Most tools either re-download everything or rely on the YouTube ID being embedded in the filename. This script uses `ffprobe` to read the actual duration of each local MP4 and compares it against the YouTube duration (within a 5-second tolerance), combined with a title similarity check. This lets it recognize files you already have even if they were downloaded with a different tool, renamed, or never had an ID in their name.

---

## Why local-disk processing?

yt-dlp downloads the video, extracts metadata, embeds the thumbnail, and merges streams via ffmpeg — all heavy concurrent I/O. Doing this directly on a NAS over SMB causes intermittent "audio conversion failed" errors on larger files, especially under load. The script uses yt-dlp's `--paths temp:%TEMP%` flag to do all intermediate work on the local SSD, then moves only the final `.mp4` to the destination. Saves a lot of headaches.

---

## Scope

Out of the box, this tool syncs **public and unlisted** YouTube playlists. That covers the vast majority of curated video playlists.

It does **not** out-of-the-box support:
- **Private playlists or videos** that require you to be signed in
- **Members-only / Premium-only** content
- **Age-restricted videos** that require an account to confirm age

These cases require yt-dlp to authenticate as your YouTube account by reading cookies from your browser. See [COOKIES.md](COOKIES.md) if you really need it.

---

## Notes

- **YouTube Mixes/Radio don't work.** URLs with `list=RD…` are auto-generated and change every time you open them. Only regular playlists (`list=PL…`) are supported.
- Some playlist videos become permanently unavailable on YouTube (uploader-deleted, copyright-removed, region-blocked, etc). The script tracks these in `_unavailable.txt` per folder and the GUI counts them separately so they don't show up as "missing" forever.
- yt-dlp updates frequently. Update with `winget upgrade yt-dlp` (winget) or `python -m pip install --upgrade yt-dlp` (pip) if you start hitting extraction errors.
- All activity is logged to `video_sync.log` in your base folder.
- **Folder/file name sanitization**: YouTube titles often contain emoji, fullwidth characters, or characters Windows forbids in filenames. The script automatically strips/replaces them before saving.

---

## License

MIT — see [LICENSE](LICENSE).
