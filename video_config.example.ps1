# =============================================================================
# video_config.example.ps1
# Copy this file to video_config.ps1 and fill in your own values.
# video_config.ps1 is gitignored and will never be committed.
# =============================================================================

# Base folder where your video playlist subfolders live.
# Examples:
#   "C:\Videos\Playlists"
#   "Z:\MyVideos"            (network drive)
#   "\\192.168.1.x\videos"   (UNC path)
$BASE_DIR = "C:\Videos\Playlists"

# Duration tolerance in seconds for local file vs YouTube duration matching.
# 5 seconds works well for most cases.
$DURATION_TOLERANCE = 5

# Maximum video height (vertical resolution) to download. yt-dlp picks the
# best stream at or below this cap. Common values: 720, 1080, 1440, 2160.
$MAX_VIDEO_HEIGHT = 1080

# OPTIONAL: cookies for authenticated YouTube access (private/age-restricted
# videos, members-only content, etc.). Leave both empty if you don't need them.
# See COOKIES.md for the full setup guide and caveats.
#
#   $COOKIES_FROM_BROWSER = "firefox"   # or "chrome", "edge", "brave", ...
#   $COOKIES_FILE         = "C:\path\to\cookies.txt"
$COOKIES_FROM_BROWSER = ""
$COOKIES_FILE         = ""

# Your video playlists: folder name => YouTube playlist URL.
# The folder name will be created under $BASE_DIR if it doesn't exist.
$PLAYLISTS = [ordered]@{
    "My Tutorials"  = "https://www.youtube.com/playlist?list=XXXXXXXXXXXXXXXXXXX"
    "Travel Vlogs"  = "https://www.youtube.com/playlist?list=XXXXXXXXXXXXXXXXXXX"
    # Add as many as you want...
}
