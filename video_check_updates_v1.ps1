# =============================================================================
# blackjack-video-sync - video_check_updates_v1.ps1
# https://github.com/0xDonnie/blackjack-video-sync
#
# Compares each YouTube playlist in video_config.ps1 against the local
# .archive and _unavailable.txt files, and writes _v3_video_pending.json
# with the state. Consumed by the Monitor tab in video_gui_v1.ps1.
#
# Flags:
#   -ConfigOverride PATH   Use a different config file
#   -Quiet                 Less console output (for scheduled runs)
# =============================================================================

param(
    [string]$ConfigOverride = "",
    [switch]$Quiet
)

$configPath = if ($ConfigOverride -and (Test-Path -LiteralPath $ConfigOverride)) {
    $ConfigOverride
} else {
    Join-Path $PSScriptRoot "video_config.ps1"
}

if (-not (Test-Path -LiteralPath $configPath)) {
    Write-Error "video_config.ps1 not found."
    exit 1
}
. $configPath

if (-not (Test-Path -LiteralPath $BASE_DIR)) {
    Write-Error "BASE_DIR not accessible: $BASE_DIR. Is the NAS mounted?"
    exit 1
}

function Write-Info {
    param([string]$Message)
    if (-not $Quiet) { Write-Host $Message }
}

function Get-PlaylistEntries {
    param([string]$Url)
    try {
        $json = yt-dlp --flat-playlist --dump-single-json --quiet $Url 2>$null
        if (-not $json -or $json -eq "null") { return $null }
        return ($json | ConvertFrom-Json -ErrorAction SilentlyContinue)
    } catch {
        return $null
    }
}

function Get-ArchivedIds {
    param([string]$ArchivePath)
    if (-not (Test-Path -LiteralPath $ArchivePath)) { return @() }
    return @(Get-Content -LiteralPath $ArchivePath |
        ForEach-Object { ($_ -split ' ')[-1].Trim() } |
        Where-Object { $_ })
}

function Get-UnavailableIds {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    return @(Get-Content -LiteralPath $Path |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ })
}

function ConvertTo-SafeFolderName {
    param([string]$Name)
    if (-not $Name) { return "" }
    $map = @{
        '<'='-'; '>'='-'; ':'=' -'; '"'="'"; '/'=' - '
        '\'=' - '; '|'=' - '; '?'=''; '*'=''
        '['='('; ']'=')'
    }
    $s = $Name
    foreach ($k in $map.Keys) { $s = $s.Replace($k, $map[$k]) }
    $s = $s -replace '[\x00-\x1F\x7F]', ''
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

function Check-Playlist {
    param([string]$Name, [string]$Url)

    $folderName  = ConvertTo-SafeFolderName -Name $Name
    $folder      = Join-Path $BASE_DIR $folderName
    $archivePath = Join-Path $folder ".archive"
    $unavailPath = Join-Path $folder "_unavailable.txt"

    Write-Info "Checking: $Name ..."

    $data = Get-PlaylistEntries -Url $Url
    if (-not $data -or -not $data.entries) {
        Write-Info "  ! Could not fetch playlist metadata"
        return [PSCustomObject]@{
            Name          = $Name
            Status        = "error"
            YouTubeTotal  = 0
            Archived      = 0
            Unavailable   = 0
            Pending       = 0
            PendingTitles = @()
        }
    }

    $ytEntries   = @($data.entries | Where-Object { $_.id })
    $archivedIds = Get-ArchivedIds    -ArchivePath $archivePath
    $unavailIds  = Get-UnavailableIds -Path $unavailPath

    $pendingEntries = @($ytEntries | Where-Object {
        ($archivedIds -notcontains $_.id) -and ($unavailIds -notcontains $_.id)
    })

    return [PSCustomObject]@{
        Name          = $Name
        Status        = "ok"
        YouTubeTotal  = $ytEntries.Count
        Archived      = $archivedIds.Count
        Unavailable   = $unavailIds.Count
        Pending       = $pendingEntries.Count
        PendingTitles = @($pendingEntries | ForEach-Object { $_.title })
    }
}

Write-Info "============================================="
Write-Info "blackjack-video-sync - update check"
Write-Info (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
Write-Info "============================================="

$results = @()
foreach ($entry in $PLAYLISTS.GetEnumerator()) {
    $results += Check-Playlist -Name $entry.Key -Url $entry.Value
}

$withUpdates  = @($results | Where-Object { $_.Pending -gt 0 })
$totalPending = ($results | Measure-Object -Property Pending -Sum).Sum
if (-not $totalPending) { $totalPending = 0 }
$errorCount   = @($results | Where-Object { $_.Status -eq "error" }).Count

Write-Info ""
Write-Info "============================================="
Write-Info "SUMMARY"
Write-Info "============================================="
Write-Info "Playlists checked: $($results.Count)"
Write-Info "Playlists with new videos: $($withUpdates.Count)"
Write-Info "Total new videos pending: $totalPending"
if ($errorCount -gt 0) {
    Write-Info "Playlists with check errors: $errorCount"
}

if ($withUpdates.Count -gt 0 -and -not $Quiet) {
    Write-Host ""
    Write-Host "Pending updates:" -ForegroundColor Yellow
    foreach ($u in $withUpdates) {
        Write-Host "  - $($u.Name): $($u.Pending) new video(s)" -ForegroundColor Yellow
        foreach ($t in $u.PendingTitles) {
            Write-Host "      * $t"
        }
    }
}

$state = [PSCustomObject]@{
    Timestamp            = (Get-Date).ToString('o')
    TotalPending         = $totalPending
    PlaylistsCheckedCount= $results.Count
    ErrorCount           = $errorCount
    PlaylistsWithUpdates = @($withUpdates | ForEach-Object {
        @{
            Name          = $_.Name
            Url           = $PLAYLISTS[$_.Name]
            Pending       = $_.Pending
            PendingTitles = $_.PendingTitles
        }
    })
}

$statePath = Join-Path $PSScriptRoot "_v3_video_pending.json"
$state | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $statePath -Encoding UTF8

Write-Info ""
Write-Info "State saved: $statePath"

exit 0
