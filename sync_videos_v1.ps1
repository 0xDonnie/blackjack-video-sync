# =============================================================================
# blackjack-video-sync - sync_videos_v1.ps1 v1.0
# https://github.com/0xDonnie/blackjack-video-sync
#
# Keeps local video folders in sync with YouTube playlists. Downloads new
# entries as MP4, never deletes or overwrites existing files. Matches
# existing files using duration + title to avoid re-downloading. Maintains
# _id_map.txt, .archive and .m3u for each playlist folder.
# =============================================================================

param(
    [string]$ConfigOverride = ""
)

# Load config — defaults to video_config.ps1 next to this script.
$configPath = if ($ConfigOverride -and (Test-Path -LiteralPath $ConfigOverride)) {
    $ConfigOverride
} else {
    Join-Path $PSScriptRoot "video_config.ps1"
}

if (-not (Test-Path -LiteralPath $configPath)) {
    Write-Error "video_config.ps1 not found. Copy video_config.example.ps1 to video_config.ps1 and fill in your values."
    exit 1
}
. $configPath

# Optional config defaults
if (-not $COOKIES_FROM_BROWSER) { $COOKIES_FROM_BROWSER = "" }
if (-not $COOKIES_FILE)         { $COOKIES_FILE         = "" }
if (-not $MAX_VIDEO_HEIGHT)     { $MAX_VIDEO_HEIGHT     = 1080 }

# -----------------------------------------------------------------------------
# FOLDER NAME SANITIZATION (must match video_gui_v1.ps1)
# -----------------------------------------------------------------------------

function ConvertTo-SafeFolderName {
    param([string]$Name)
    if (-not $Name) { return "" }
    $map = @{
        '<'  = '-'
        '>'  = '-'
        ':'  = ' -'
        '"'  = "'"
        '/'  = ' - '
        '\'  = ' - '
        '|'  = ' - '
        '?'  = ''
        '*'  = ''
        '['  = '('
        ']'  = ')'
    }
    $s = $Name
    foreach ($k in $map.Keys) { $s = $s.Replace($k, $map[$k]) }
    $s = $s -replace '[\x00-\x1F\x7F]', ''
    # Strip emoji / pictographic symbols
    $s = $s -replace '[\uD83C-\uD83E][\uDC00-\uDFFF]', ''
    $s = $s -replace '[\u2600-\u27BF]', ''
    $s = $s -replace '[\u2B00-\u2BFF]', ''
    $s = $s -replace '[\uFE0F\u200D]', ''
    $s = $s -replace '\s+', ' '
    $s = $s -replace '(\s*-\s*){2,}', ' - '
    $s = $s.Trim().TrimEnd('. ')
    $reserved = @('CON','PRN','AUX','NUL',
                  'COM1','COM2','COM3','COM4','COM5','COM6','COM7','COM8','COM9',
                  'LPT1','LPT2','LPT3','LPT4','LPT5','LPT6','LPT7','LPT8','LPT9')
    if ($reserved -contains $s.ToUpper()) { $s = "_$s" }
    return $s
}

# -----------------------------------------------------------------------------
# LOG
# -----------------------------------------------------------------------------

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp][$Level] $Message"
    Write-Host $line
    Add-Content -Path "$BASE_DIR\video_sync.log" -Value $line
}

# -----------------------------------------------------------------------------
# ID MAP
# Maps local filename => YouTube video ID
# File: _id_map.txt in each playlist folder
# Format: "01. Video title.mp4|youtubeID"
# -----------------------------------------------------------------------------

function Load-IdMap {
    param([string]$MapPath)
    $map = @{}
    if (Test-Path -LiteralPath $MapPath) {
        Get-Content -LiteralPath $MapPath | ForEach-Object {
            $parts = $_ -split '\|'
            if ($parts.Count -eq 2) {
                $map[$parts[0].Trim()] = $parts[1].Trim()
            }
        }
    }
    return $map
}

function Save-IdMap {
    param([string]$MapPath, [hashtable]$Map)
    $lines = $Map.GetEnumerator() | Sort-Object Key | ForEach-Object {
        "$($_.Key)|$($_.Value)"
    }
    Set-Content -LiteralPath $MapPath -Value $lines -Encoding UTF8
}

# -----------------------------------------------------------------------------
# LOCAL FILES
# -----------------------------------------------------------------------------

function Get-LocalMp4s {
    param([string]$FolderPath)
    # Skip yt-dlp's *.part / *.temp scratch files — partial downloads.
    return Get-ChildItem -LiteralPath $FolderPath -Filter "*.mp4" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike "*.part.mp4" -and $_.Name -notlike "*.temp.mp4" }
}

function Get-FileDuration {
    param([string]$FilePath)
    $result = ffprobe -v quiet -show_entries format=duration -of csv=p=0 $FilePath 2>$null
    if ($result) { return [double]$result }
    return $null
}

function Get-M3uFile {
    param([string]$FolderPath)
    return Get-ChildItem -LiteralPath $FolderPath -Filter "*.m3u" -ErrorAction SilentlyContinue | Select-Object -First 1
}

# -----------------------------------------------------------------------------
# YOUTUBE
# -----------------------------------------------------------------------------

function Get-PlaylistEntries {
    param([string]$Url)
    Write-Log "Fetching playlist metadata from YouTube..."
    $tempErr = [System.IO.Path]::GetTempFileName()
    try {
        $json = yt-dlp --flat-playlist --dump-single-json --quiet $Url 2>$tempErr
        if (-not $json -or $json -eq "null") {
            $errText = ""
            if (Test-Path -LiteralPath $tempErr) {
                $errText = (Get-Content -LiteralPath $tempErr -Raw -ErrorAction SilentlyContinue) -as [string]
            }
            if ($errText -match 'does not exist' -or $errText -match '(?i)private') {
                Write-Log "Playlist is PRIVATE or does not exist." "ERROR"
                Write-Log "  → Open it on YouTube and change visibility to 'Unlisted' (or Public) to enable sync." "ERROR"
            } elseif ($errText -match '(?i)sign in|cookies|authentication') {
                Write-Log "Playlist requires authentication (age-restricted or members-only)." "ERROR"
                Write-Log "  → See COOKIES.md for how to pass browser cookies to yt-dlp." "ERROR"
            } else {
                Write-Log "Could not fetch playlist metadata." "ERROR"
                if ($errText) {
                    $firstLine = ($errText -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
                    if ($firstLine) { Write-Log "  → yt-dlp: $firstLine" "ERROR" }
                }
            }
            return $null
        }
        $data = $json | ConvertFrom-Json
        return $data.entries
    } finally {
        if (Test-Path -LiteralPath $tempErr) {
            Remove-Item -LiteralPath $tempErr -Force -ErrorAction SilentlyContinue
        }
    }
}

# -----------------------------------------------------------------------------
# TITLE NORMALIZATION
# -----------------------------------------------------------------------------

function Normalize-Title {
    param([string]$Title)
    $t = $Title.ToLower()
    $t = $t -replace '[^\w\s]', ' '
    $t = $t -replace '\s+', ' '
    return $t.Trim()
}

function Strip-TrackNumber {
    param([string]$FileName)
    return ($FileName -replace '^\d+\.\s*', '').Trim()
}

# -----------------------------------------------------------------------------
# MATCHING
# -----------------------------------------------------------------------------

function Match-Entries {
    param(
        [System.IO.FileInfo[]]$LocalFiles,
        [array]$YoutubeEntries,
        [hashtable]$IdMap
    )

    $matched = 0

    foreach ($ytEntry in $YoutubeEntries) {
        $ytId    = $ytEntry.id
        $ytTitle = $ytEntry.title
        $ytDur   = $ytEntry.duration

        if ($IdMap.Values -contains $ytId) { continue }

        $normalizedYt = Normalize-Title -Title $ytTitle
        $bestMatch = $null

        foreach ($file in $LocalFiles) {
            $baseName        = Strip-TrackNumber -FileName $file.BaseName
            $normalizedLocal = Normalize-Title -Title $baseName

            $minLen = [Math]::Min($normalizedYt.Length, $normalizedLocal.Length)
            $titleMatch = $minLen -ge 8 -and (
                $normalizedLocal -like "*$normalizedYt*" -or
                $normalizedYt -like "*$normalizedLocal*"
            )
            if (-not $titleMatch) { continue }

            if ($ytDur -and $ytDur -gt 0) {
                $localDur = Get-FileDuration -FilePath $file.FullName
                if ($localDur) {
                    $diff = [Math]::Abs($localDur - $ytDur)
                    if ($diff -le $DURATION_TOLERANCE) {
                        $bestMatch = $file.Name
                        break
                    }
                    continue
                }
            }

            $bestMatch = $file.Name
            break
        }

        if ($bestMatch) {
            Write-Log "Match: '$bestMatch' => '$ytTitle' (ID: $ytId)"
            $IdMap[$bestMatch] = $ytId
            $matched++
        }
    }

    Write-Log "New matches found: $matched"
    return $IdMap
}

# -----------------------------------------------------------------------------
# ARCHIVE
# -----------------------------------------------------------------------------

function Populate-Archive {
    param([string]$ArchivePath, [hashtable]$IdMap)
    $archivedIds = @()
    if (Test-Path -LiteralPath $ArchivePath) {
        $archivedIds = Get-Content -LiteralPath $ArchivePath | ForEach-Object { ($_ -split ' ')[-1] }
    }
    $added = 0
    foreach ($id in $IdMap.Values) {
        if ($archivedIds -notcontains $id) {
            Add-Content -LiteralPath $ArchivePath -Value "youtube $id"
            $added++
        }
    }
    Write-Log "IDs added to yt-dlp archive: $added"
}

# -----------------------------------------------------------------------------
# M3U
# -----------------------------------------------------------------------------

function Update-M3u {
    param([string]$FolderPath, [string]$PlaylistName)

    $m3u = Get-M3uFile -FolderPath $FolderPath
    if (-not $m3u) {
        $m3uPath = Join-Path $FolderPath "$PlaylistName.m3u"
        New-Item -Path $m3uPath -ItemType File | Out-Null
        $m3u = Get-Item -LiteralPath $m3uPath
    }

    $existing   = Get-Content -LiteralPath $m3u.FullName | Where-Object { $_ -match '\.mp4$' } | ForEach-Object { $_.Trim() }
    $allMp4s    = Get-ChildItem -LiteralPath $FolderPath -Filter "*.mp4" |
                    Where-Object { $_.Name -notlike "*.part.mp4" -and $_.Name -notlike "*.temp.mp4" } |
                    Sort-Object Name | ForEach-Object { $_.Name }
    $newEntries = $allMp4s | Where-Object { $existing -notcontains $_ }

    if ($newEntries.Count -gt 0) {
        Add-Content -LiteralPath $m3u.FullName -Value $newEntries
        Write-Log "M3U updated with $($newEntries.Count) new video(s)."
    } else {
        Write-Log "M3U already up to date."
    }
}

# -----------------------------------------------------------------------------
# MAIN SYNC FUNCTION
# -----------------------------------------------------------------------------

function Sync-Playlist {
    param([string]$Name, [string]$Url)

    $folderName  = ConvertTo-SafeFolderName -Name $Name
    $destDir     = Join-Path $BASE_DIR $folderName
    $archivePath = Join-Path $destDir ".archive"
    $mapPath     = Join-Path $destDir "_id_map.txt"

    Write-Log "==============================="
    Write-Log "Syncing: $Name"
    if ($folderName -ne $Name) {
        Write-Log "  (folder name sanitized to: $folderName)"
    }

    if (-not (Test-Path -LiteralPath $destDir)) {
        New-Item -ItemType Directory -Path $destDir | Out-Null
        Write-Log "Created folder: $destDir"
    }

    # Normalize URL to clean playlist form
    if ($Url -match 'list=([\w-]+)') {
        $cleanUrl = "https://www.youtube.com/playlist?list=$($matches[1])"
        if ($cleanUrl -ne $Url) {
            Write-Log "  URL normalized: $cleanUrl"
            $Url = $cleanUrl
        }
    }

    $ytEntries = Get-PlaylistEntries -Url $Url
    if (-not $ytEntries) {
        Write-Log "Skipping: $Name" "ERROR"
        return
    }
    Write-Log "Videos on YouTube: $($ytEntries.Count)"

    $idMap = Load-IdMap -MapPath $mapPath
    Write-Log "Already mapped: $($idMap.Count)"

    $localFiles = Get-LocalMp4s -FolderPath $destDir
    if ($localFiles.Count -gt 0) {
        Write-Log "Local files: $($localFiles.Count) - matching..."
        $idMap = Match-Entries -LocalFiles $localFiles -YoutubeEntries $ytEntries -IdMap $idMap
        Save-IdMap -MapPath $mapPath -Map $idMap
    }

    Populate-Archive -ArchivePath $archivePath -IdMap $idMap

    Write-Log "Downloading missing videos..."
    $ytOutputPath = Join-Path $env:TEMP ("_yt_video_output_tmp_" + [guid]::NewGuid().Guid + ".log")
    # Use a local temp dir for all intermediate yt-dlp / ffmpeg work — NAS
    # (SMB) is flaky under heavy concurrent read+write, so we download and
    # process locally and move only the final .mp4 to the destination.
    $ytTempDir = Join-Path $env:TEMP "blackjack-ytdlp-video-work"
    if (-not (Test-Path -LiteralPath $ytTempDir)) {
        New-Item -Path $ytTempDir -ItemType Directory -Force | Out-Null
    }

    # Format selector: best video+audio under height cap, preferring mp4.
    # Falls back to any best single file if the split streams aren't available.
    $formatSpec = "bv*[height<=?$MAX_VIDEO_HEIGHT]+ba/b[height<=?$MAX_VIDEO_HEIGHT]/bv*+ba/b"

    $ytArgs = @(
        "--format", $formatSpec,
        "--merge-output-format", "mp4",
        "--embed-thumbnail",
        "--add-metadata",
        "--embed-metadata",
        "--no-overwrites",
        "--yes-playlist",
        "--remote-components", "ejs:github",
        "--download-archive", $archivePath,
        "--paths", "temp:$ytTempDir",
        "--paths", "home:$destDir",
        "--output", "%(playlist_index)s. %(title)s.%(ext)s",
        "--ignore-errors"
    )
    if ($COOKIES_FROM_BROWSER) {
        $ytArgs += @("--cookies-from-browser", $COOKIES_FROM_BROWSER)
        Write-Log "Using cookies from browser: $COOKIES_FROM_BROWSER"
    }
    if ($COOKIES_FILE -and (Test-Path -LiteralPath $COOKIES_FILE)) {
        $ytArgs += @("--cookies", $COOKIES_FILE)
        Write-Log "Using cookies file: $COOKIES_FILE"
    }
    $ytArgs += $Url

    # Native redirect to a local temp file so yt-dlp's stdout is never
    # preempted mid-stream by a PowerShell pipeline.
    & yt-dlp @ytArgs *> $ytOutputPath
    $ytExitCode = $LASTEXITCODE
    Write-Log "yt-dlp exit code: $ytExitCode"
    if (Test-Path -LiteralPath $ytOutputPath) {
        Get-Content -LiteralPath $ytOutputPath | Write-Host
    }

    # Post-download file name cleanup: yt-dlp names files after the YouTube
    # title which can contain emoji / reserved chars. Sanitize the same way
    # ConvertTo-SafeFolderName does, preserving the "NN. " prefix.
    Get-ChildItem -LiteralPath $destDir -Filter "*.mp4" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike "*.part.mp4" -and $_.Name -notlike "*.temp.mp4" } |
        ForEach-Object {
            $oldName = $_.Name
            $base    = [System.IO.Path]::GetFileNameWithoutExtension($oldName)
            $ext     = $_.Extension
            $trackPrefix = ""
            $title       = $base
            if ($base -match '^(\d+\.\s+)(.*)$') {
                $trackPrefix = $matches[1]
                $title       = $matches[2]
            }
            $cleanTitle = ConvertTo-SafeFolderName -Name $title
            if ([string]::IsNullOrWhiteSpace($cleanTitle)) { return }
            $newName = "$trackPrefix$cleanTitle$ext"
            if ($newName -eq $oldName) { return }
            $newPath = Join-Path $destDir $newName
            if (Test-Path -LiteralPath $newPath) { return }
            try {
                Rename-Item -LiteralPath $_.FullName -NewName $newName -ErrorAction Stop
                Write-Log "  Renamed: '$oldName' -> '$newName'"
            } catch {
                Write-Log "  Could not rename '$oldName': $($_.Exception.Message)" "ERROR"
            }
        }

    # Rebuild _unavailable.txt from this run's ERROR lines
    $unavailablePath = Join-Path $destDir "_unavailable.txt"
    $currentUnavailable = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath $ytOutputPath) {
        Get-Content -LiteralPath $ytOutputPath | ForEach-Object {
            if ($_ -match 'ERROR: \[youtube\] (\S+):') {
                $id = $matches[1]
                if (-not $currentUnavailable.Contains($id)) {
                    [void]$currentUnavailable.Add($id)
                }
            }
        }
        Remove-Item -LiteralPath $ytOutputPath -ErrorAction SilentlyContinue
    }
    $previousUnavailable = @()
    if (Test-Path -LiteralPath $unavailablePath) {
        $previousUnavailable = Get-Content -LiteralPath $unavailablePath | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    }
    if ($currentUnavailable.Count -gt 0) {
        Set-Content -LiteralPath $unavailablePath -Value $currentUnavailable -Encoding UTF8
        $recovered = @($previousUnavailable | Where-Object { $currentUnavailable -notcontains $_ }).Count
        if ($recovered -gt 0) {
            Write-Log "Unavailable videos: $($currentUnavailable.Count) total ($recovered recovered since last sync)"
        } else {
            Write-Log "Unavailable videos: $($currentUnavailable.Count) total"
        }
    } elseif (Test-Path -LiteralPath $unavailablePath) {
        Remove-Item -LiteralPath $unavailablePath -ErrorAction SilentlyContinue
        Write-Log "All videos now downloadable - cleaned up _unavailable.txt"
    }

    $newLocalFiles = Get-LocalMp4s -FolderPath $destDir
    if ($newLocalFiles.Count -gt $localFiles.Count) {
        Write-Log "Updating _id_map.txt with newly downloaded videos..."
        $idMap = Match-Entries -LocalFiles $newLocalFiles -YoutubeEntries $ytEntries -IdMap $idMap
        Save-IdMap -MapPath $mapPath -Map $idMap
    }

    Update-M3u -FolderPath $destDir -PlaylistName $folderName

    Write-Log "Done: $Name"
    Write-Log "==============================="
}

# -----------------------------------------------------------------------------
# ENTRY POINT
# -----------------------------------------------------------------------------

Write-Log "============================================="
Write-Log "blackjack-video-sync v1.0 - starting"
Write-Log "============================================="

foreach ($entry in $PLAYLISTS.GetEnumerator()) {
    Sync-Playlist -Name $entry.Key -Url $entry.Value
}

Write-Log "============================================="
Write-Log "All playlists synced."
Write-Log "============================================="
