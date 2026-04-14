# =============================================================================
# blackjack-video-sync - video_gui_v1.ps1 v1.0
# https://github.com/0xDonnie/blackjack-video-sync
# WinForms GUI to manage YouTube video playlists.
# =============================================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# --- Config ---
$configPath = Join-Path $PSScriptRoot "video_config.ps1"
if (-not (Test-Path -LiteralPath $configPath)) {
    [System.Windows.Forms.MessageBox]::Show(
        "video_config.ps1 not found.`nCopy video_config.example.ps1 to video_config.ps1 and fill in your details.",
        "blackjack-video-sync", "OK", "Error")
    exit
}
. $configPath

$syncScriptPath = Join-Path $PSScriptRoot "sync_videos_v1.ps1"

# --- Colors (slightly different accent so the two GUIs are visually distinct) ---
$bgColor     = [System.Drawing.Color]::FromArgb(15, 15, 20)
$panelColor  = [System.Drawing.Color]::FromArgb(25, 25, 35)
$cardColor   = [System.Drawing.Color]::FromArgb(35, 35, 50)
$accentColor = [System.Drawing.Color]::FromArgb(236, 72, 153)   # pink-ish, to tell apart from music GUI (indigo)
$textColor   = [System.Drawing.Color]::FromArgb(240, 240, 255)
$mutedColor  = [System.Drawing.Color]::FromArgb(130, 130, 160)
$greenColor  = [System.Drawing.Color]::FromArgb(52, 211, 153)
$orangeColor = [System.Drawing.Color]::FromArgb(251, 146, 60)
$redColor    = [System.Drawing.Color]::FromArgb(248, 113, 113)
$gridLine    = [System.Drawing.Color]::FromArgb(50, 50, 70)

# --- Fonts ---
$fontMain    = New-Object System.Drawing.Font("Segoe UI", 9)
$fontBold    = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$fontTitle   = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
$fontMono    = New-Object System.Drawing.Font("Consolas", 8.5)

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

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

function Get-LocalCount {
    param([string]$Name)
    $folder = ConvertTo-SafeFolderName -Name $Name
    $dir = Join-Path $BASE_DIR $folder
    if (-not (Test-Path -LiteralPath $dir)) { return 0 }
    return (Get-ChildItem -LiteralPath $dir -Filter "*.mp4" -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notlike "*.part.mp4" -and $_.Name -notlike "*.temp.mp4" }).Count
}

function Get-UnavailableCount {
    param([string]$Name)
    $folder = ConvertTo-SafeFolderName -Name $Name
    $path = Join-Path (Join-Path $BASE_DIR $folder) "_unavailable.txt"
    if (-not (Test-Path -LiteralPath $path)) { return 0 }
    return (Get-Content -LiteralPath $path | Where-Object { $_.Trim() -ne "" }).Count
}

function Get-YoutubeCount {
    param([string]$Url)
    try {
        $json = yt-dlp --flat-playlist --dump-single-json --quiet $Url 2>$null
        if ($json -and $json -ne "null") {
            $data = $json | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($data -and $data.entries) { return $data.entries.Count }
        }
    } catch {}
    return -1
}

function Get-YoutubePlaylistTitle {
    param([string]$Url)
    try {
        $json = yt-dlp --flat-playlist --dump-single-json --quiet $Url 2>$null
        if ($json -and $json -ne "null") {
            $data = $json | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($data -and $data.title) { return $data.title }
        }
    } catch {}
    return ""
}

function Add-PlaylistToConfig {
    param([string]$Name, [string]$Url)
    $lines = Get-Content -LiteralPath $configPath
    $newLine = "    `"$Name`" = `"$Url`""
    $inPlaylists = $false
    $insertIndex = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\$PLAYLISTS\s*=') { $inPlaylists = $true }
        if ($inPlaylists -and $lines[$i].Trim() -eq '}') {
            $insertIndex = $i
            break
        }
    }
    if ($insertIndex -ge 0) {
        $newLines = @($lines[0..($insertIndex - 1)]) + $newLine + @($lines[$insertIndex..($lines.Count - 1)])
        Set-Content -LiteralPath $configPath $newLines -Encoding UTF8
        return $true
    }
    return $false
}

function Remove-PlaylistFromConfig {
    param([string]$Name)
    if (-not (Test-Path -LiteralPath $configPath)) { return $false }
    $lines = Get-Content -LiteralPath $configPath
    $prefix = '"' + ($Name -replace '"','`"') + '"'
    $newLines = New-Object System.Collections.Generic.List[string]
    $removed = $false
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if (-not $removed -and $trimmed.StartsWith($prefix)) {
            $removed = $true
            continue
        }
        [void]$newLines.Add($line)
    }
    if ($removed) {
        Set-Content -LiteralPath $configPath -Value $newLines -Encoding UTF8
    }
    return $removed
}

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "HH:mm:ss"
    $line = "[$timestamp] $Message"
    $logBox.Invoke([Action]{
        $logBox.AppendText($line + "`r`n")
        $logBox.ScrollToCaret()
    })
}

function Make-Button {
    param([string]$Text, [System.Drawing.Color]$Bg, [int]$W = 140, [int]$H = 34)
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = $Text
    $btn.Font = $fontBold
    $btn.FlatStyle = "Flat"
    $btn.FlatAppearance.BorderSize = 0
    $btn.BackColor = $Bg
    $btn.ForeColor = $textColor
    $btn.Size = New-Object System.Drawing.Size($W, $H)
    $btn.Cursor = [System.Windows.Forms.Cursors]::Hand
    return $btn
}

function Make-Label {
    param([string]$Text, [System.Drawing.Font]$Font = $null, [System.Drawing.Color]$Color = $([System.Drawing.Color]::Empty))
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $Text
    $lbl.Font = if ($Font) { $Font } else { $fontMain }
    $lbl.ForeColor = if ($Color -ne [System.Drawing.Color]::Empty) { $Color } else { $textColor }
    $lbl.AutoSize = $true
    $lbl.BackColor = [System.Drawing.Color]::Transparent
    return $lbl
}

function Make-TextBox {
    param([int]$W = 300, [string]$Placeholder = "")
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Font = $fontMain
    $tb.BackColor = $cardColor
    $tb.ForeColor = $textColor
    $tb.BorderStyle = "FixedSingle"
    $tb.Width = $W
    $tb.Height = 28
    if ($Placeholder) { $tb.Text = $Placeholder; $tb.ForeColor = $mutedColor }
    return $tb
}

# =============================================================================
# FORM
# =============================================================================

$form = New-Object System.Windows.Forms.Form
$form.Text = "blackjack-video-sync"
$form.Size = New-Object System.Drawing.Size(920, 840)
$form.MinimumSize = New-Object System.Drawing.Size(920, 840)
$form.BackColor = $bgColor
$form.ForeColor = $textColor
$form.Font = $fontMain
$form.StartPosition = "CenterScreen"

# =============================================================================
# HEADER
# =============================================================================

$header = New-Object System.Windows.Forms.Panel
$header.Dock = "Top"
$header.Height = 60
$header.BackColor = $panelColor
$header.Padding = New-Object System.Windows.Forms.Padding(20, 0, 20, 0)

$titleLabel = Make-Label "blackjack-video-sync" $fontTitle $accentColor
$titleLabel.Location = New-Object System.Drawing.Point(20, 10)

$versionLabel = Make-Label "v1.0" $fontMain $mutedColor
$versionLabel.Location = New-Object System.Drawing.Point(20, 38)

$header.Controls.AddRange(@($titleLabel, $versionLabel))
$form.Controls.Add($header)


# =============================================================================
# GRID - PLAYLIST TABLE
# =============================================================================

$gridLabel = Make-Label "YOUR VIDEO PLAYLISTS" $fontBold $mutedColor
$gridLabel.Location = New-Object System.Drawing.Point(16, 76)
$form.Controls.Add($gridLabel)

$grid = New-Object System.Windows.Forms.DataGridView
$grid.Location = New-Object System.Drawing.Point(16, 98)
$grid.Size = New-Object System.Drawing.Size(859, 240)
$grid.Anchor = "Top,Left"
$grid.BackgroundColor = $panelColor
$grid.BorderStyle = "None"
$grid.CellBorderStyle = "SingleHorizontal"
$grid.GridColor = $gridLine
$grid.RowHeadersVisible = $false
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.AllowUserToResizeRows = $false
$grid.MultiSelect = $true
$grid.SelectionMode = "FullRowSelect"
$grid.Font = $fontMain
$grid.AutoSizeColumnsMode = "None"

# Columns
$colSel = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
$colSel.HeaderText = ""
$colSel.Width = 30
$colSel.AutoSizeMode = "None"
$colSel.ReadOnly = $false
$grid.Columns.Add($colSel) | Out-Null

foreach ($col in @("Playlist","Local","YouTube","Unavailable","Status")) {
    $c = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $c.HeaderText = $col
    $c.ReadOnly = $true
    $c.AutoSizeMode = "None"
    switch ($col) {
        "Playlist"    { $c.Width = 449 }
        "Local"       { $c.Width = 65  }
        "YouTube"     { $c.Width = 65  }
        "Unavailable" { $c.Width = 90  }
        "Status"      { $c.Width = 160 }
    }
    $grid.Columns.Add($c) | Out-Null
}

# Styling
$grid.DefaultCellStyle.BackColor = $panelColor
$grid.DefaultCellStyle.ForeColor = $textColor
$grid.DefaultCellStyle.SelectionBackColor = $cardColor
$grid.DefaultCellStyle.SelectionForeColor = $textColor
$grid.DefaultCellStyle.Padding = New-Object System.Windows.Forms.Padding(4, 6, 4, 6)
$grid.AlternatingRowsDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 45)
$grid.ColumnHeadersDefaultCellStyle.BackColor = $cardColor
$grid.ColumnHeadersDefaultCellStyle.ForeColor = $mutedColor
$grid.ColumnHeadersDefaultCellStyle.Font = $fontBold
$grid.ColumnHeadersDefaultCellStyle.SelectionBackColor = $cardColor
$grid.ColumnHeadersHeight = 36
$grid.RowTemplate.Height = 38
$grid.EnableHeadersVisualStyles = $false
$grid.ScrollBars = [System.Windows.Forms.ScrollBars]::None

$grid.add_CurrentCellDirtyStateChanged({
    if ($grid.IsCurrentCellDirty) {
        $grid.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit)
    }
})

foreach ($entry in $PLAYLISTS.GetEnumerator()) {
    $row = $grid.Rows.Add($false, $entry.Key, "...", "?", "...", "Not checked")
    $grid.Rows[$row].Tag = $entry.Value
}

# Custom VScrollBar — the DataGridView's internal one doesn't render
# reliably inside a TabPage with Windows 11 dark theme.
$gridVScroll = New-Object System.Windows.Forms.VScrollBar
$gridVScroll.Location    = New-Object System.Drawing.Point(875, 98)
$gridVScroll.Size        = New-Object System.Drawing.Size(17, 240)
$gridVScroll.Minimum     = 0
$gridVScroll.SmallChange = 1

function Update-GridScrollbar {
    $visible = [Math]::Max(1, [int](($grid.Height - $grid.ColumnHeadersHeight) / $grid.RowTemplate.Height))
    $overflow = $grid.Rows.Count - $visible
    if ($overflow -le 0) {
        $gridVScroll.Enabled     = $false
        $gridVScroll.Maximum     = 0
        $gridVScroll.LargeChange = 1
    } else {
        $gridVScroll.Enabled     = $true
        $gridVScroll.LargeChange = $visible
        $gridVScroll.Maximum     = $overflow + $visible - 1
    }
}
Update-GridScrollbar

$gridVScroll.add_Scroll({
    $target = [Math]::Max(0, [Math]::Min($gridVScroll.Value, $grid.Rows.Count - 1))
    try { $grid.FirstDisplayedScrollingRowIndex = $target } catch {}
})

$grid.add_MouseWheel({
    param($s, $e)
    $delta = if ($e.Delta -gt 0) { -3 } else { 3 }
    $newVal = [Math]::Max($gridVScroll.Minimum, [Math]::Min(($gridVScroll.Maximum - $gridVScroll.LargeChange + 1), $gridVScroll.Value + $delta))
    if ($newVal -lt 0) { $newVal = 0 }
    $gridVScroll.Value = $newVal
    try { $grid.FirstDisplayedScrollingRowIndex = $newVal } catch {}
})

$form.Controls.Add($grid)
$form.Controls.Add($gridVScroll)

# =============================================================================
# BUTTONS ROW
# =============================================================================

$btnPanel = New-Object System.Windows.Forms.Panel
$btnPanel.Location = New-Object System.Drawing.Point(16, 348)
$btnPanel.Size = New-Object System.Drawing.Size(876, 44)
$btnPanel.BackColor = $bgColor

$btnRefresh   = Make-Button "↻  Refresh Status" $cardColor 140
$btnSyncSel   = Make-Button "▶  Sync Selected" $accentColor 140
$btnSyncAll   = Make-Button "▶▶  Sync All" ([System.Drawing.Color]::FromArgb(190, 24, 93)) 120
$btnStopSync  = Make-Button "■  Stop sync" $cardColor 110
$btnStopSync.ForeColor  = $redColor
$btnStopSync.Enabled    = $false
$btnRemoveSel = Make-Button "✕  Remove" $cardColor 100
$btnRemoveSel.ForeColor = $redColor
$btnSelectAll = Make-Button "Select All" $cardColor 100

$btnRefresh.Location   = New-Object System.Drawing.Point(0, 5)
$btnSyncSel.Location   = New-Object System.Drawing.Point(150, 5)
$btnSyncAll.Location   = New-Object System.Drawing.Point(300, 5)
$btnStopSync.Location  = New-Object System.Drawing.Point(430, 5)
$btnRemoveSel.Location = New-Object System.Drawing.Point(550, 5)
$btnSelectAll.Location = New-Object System.Drawing.Point(770, 5)

$btnPanel.Controls.AddRange(@($btnRefresh, $btnSyncSel, $btnSyncAll, $btnStopSync, $btnRemoveSel, $btnSelectAll))
$form.Controls.Add($btnPanel)

# =============================================================================
# ADD PLAYLIST PANEL
# =============================================================================

$addPanelBg = New-Object System.Windows.Forms.Panel
$addPanelBg.Location = New-Object System.Drawing.Point(16, 402)
$addPanelBg.Size = New-Object System.Drawing.Size(876, 110)
$addPanelBg.BackColor = $panelColor
$addPanelBg.Padding = New-Object System.Windows.Forms.Padding(16)

$addLabel = Make-Label "ADD NEW PLAYLIST" $fontBold $mutedColor
$addLabel.Location = New-Object System.Drawing.Point(16, 12)

$urlLabel  = Make-Label "URL" $fontMain $mutedColor
$urlLabel.Location = New-Object System.Drawing.Point(16, 38)

$urlBox = Make-TextBox 480
$urlBox.Location = New-Object System.Drawing.Point(60, 35)

$btnFetch = Make-Button "Fetch Name" $cardColor 110
$btnFetch.Location = New-Object System.Drawing.Point(550, 34)

$nameLabel = Make-Label "Name" $fontMain $mutedColor
$nameLabel.Location = New-Object System.Drawing.Point(16, 74)

$nameBox = Make-TextBox 480
$nameBox.Location = New-Object System.Drawing.Point(60, 71)

$btnAdd = Make-Button "Add & Save" $greenColor 110
$btnAdd.Location = New-Object System.Drawing.Point(550, 70)

$addPanelBg.Controls.AddRange(@($addLabel, $urlLabel, $urlBox, $btnFetch, $nameLabel, $nameBox, $btnAdd))
$form.Controls.Add($addPanelBg)

# =============================================================================
# LOG PANEL
# =============================================================================

$logLabel = Make-Label "LOG" $fontBold $mutedColor
$logLabel.Location = New-Object System.Drawing.Point(16, 524)
$form.Controls.Add($logLabel)

$logBox = New-Object System.Windows.Forms.RichTextBox
$logBox.Location = New-Object System.Drawing.Point(16, 544)
$logBox.Size = New-Object System.Drawing.Size(876, 130)
$logBox.BackColor = $panelColor
$logBox.ForeColor = [System.Drawing.Color]::FromArgb(180, 255, 180)
$logBox.Font = $fontMono
$logBox.BorderStyle = "None"
$logBox.ReadOnly = $true
$logBox.ScrollBars = "Vertical"
$form.Controls.Add($logBox)

# Hard cap on log box size — RichTextBox becomes unusable past ~1MB of text.
$script:logMaxLines     = 2000
$script:logTrimTarget   = 1500
$script:logCheckEvery   = 200

$script:logAppendCount = 0
function Append-Log {
    param([string]$Text)
    if (-not $Text) { return }
    $logBox.AppendText($Text)
    $logBox.SelectionStart = $logBox.TextLength
    $logBox.ScrollToCaret()
    $script:logAppendCount = $script:logAppendCount + 1
    if ($script:logAppendCount -lt $script:logCheckEvery) { return }
    $script:logAppendCount = 0
    $lineCount = $logBox.Lines.Count
    if ($lineCount -le $script:logMaxLines) { return }
    $linesToDrop = $lineCount - $script:logTrimTarget
    if ($linesToDrop -le 0) { return }
    $cutAt = $logBox.GetFirstCharIndexFromLine($linesToDrop)
    if ($cutAt -le 0) { return }
    $logBox.Select(0, $cutAt)
    $logBox.SelectedText = ""
    $logBox.SelectionStart = $logBox.TextLength
    $logBox.ScrollToCaret()
}

# =============================================================================
# PROGRESS PANEL
# =============================================================================

$progressLabel = Make-Label "SYNC PROGRESS" $fontBold $mutedColor
$progressLabel.Location = New-Object System.Drawing.Point(16, 686)
$form.Controls.Add($progressLabel)

$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(16, 710)
$progressBar.Size     = New-Object System.Drawing.Size(780, 22)
$progressBar.Minimum  = 0
$progressBar.Maximum  = 100
$progressBar.Value    = 0
$progressBar.Style    = "Continuous"
$form.Controls.Add($progressBar)

$progressPercentLabel = Make-Label "0%" $fontBold $accentColor
$progressPercentLabel.Location = New-Object System.Drawing.Point(806, 712)
$form.Controls.Add($progressPercentLabel)

$progressStatusLabel = Make-Label "Idle" $fontMain $textColor
$progressStatusLabel.Location = New-Object System.Drawing.Point(16, 742)
$form.Controls.Add($progressStatusLabel)

$progressEtaLabel = Make-Label "ETA: --" $fontMain $mutedColor
$progressEtaLabel.Location = New-Object System.Drawing.Point(16, 766)
$form.Controls.Add($progressEtaLabel)

# =============================================================================
# TAB CONTROL
# =============================================================================

$tabControl                   = New-Object System.Windows.Forms.TabControl
$tabControl.Dock              = "Fill"
$tabControl.Font              = $fontMain

$syncPage                     = New-Object System.Windows.Forms.TabPage
$syncPage.Text                = "  Sync  "
$syncPage.BackColor           = $bgColor
$syncPage.UseVisualStyleBackColor = $false
[void]$tabControl.TabPages.Add($syncPage)

$monitorPage                  = New-Object System.Windows.Forms.TabPage
$monitorPage.Text             = "  Monitor  "
$monitorPage.BackColor        = $bgColor
$monitorPage.UseVisualStyleBackColor = $false
[void]$tabControl.TabPages.Add($monitorPage)

$controlsToMove = @(
    $gridLabel, $grid, $gridVScroll, $btnPanel, $addPanelBg,
    $logLabel, $logBox,
    $progressLabel, $progressBar, $progressPercentLabel,
    $progressStatusLabel, $progressEtaLabel
)
foreach ($c in $controlsToMove) {
    if (-not $c) { continue }
    if ($form.Controls.Contains($c)) {
        $form.Controls.Remove($c)
    }
    $newY = $c.Location.Y - 60
    $c.Location = New-Object System.Drawing.Point($c.Location.X, $newY)
    $syncPage.Controls.Add($c)
}

$form.Controls.Remove($header)
$form.Controls.Add($tabControl)
$form.Controls.Add($header)
$form.PerformLayout()

# =============================================================================
# MONITOR TAB CONTENT
# =============================================================================

$monLblSchedTitle = Make-Label "SCHEDULE" $fontBold $mutedColor
$monLblSchedTitle.Location = New-Object System.Drawing.Point(16, 16)
$monitorPage.Controls.Add($monLblSchedTitle)

$monSchedStatusLabel = Make-Label "Loading..." $fontMain $textColor
$monSchedStatusLabel.AutoSize = $false
$monSchedStatusLabel.Size = New-Object System.Drawing.Size(870, 50)
$monSchedStatusLabel.Location = New-Object System.Drawing.Point(16, 40)
$monitorPage.Controls.Add($monSchedStatusLabel)

$btnMonSchedule = Make-Button "📅  Schedule..." $cardColor 160
$btnMonSchedule.Location = New-Object System.Drawing.Point(16, 100)
$monitorPage.Controls.Add($btnMonSchedule)

$btnMonCheckNow = Make-Button "↻  Check now" $accentColor 160
$btnMonCheckNow.Location = New-Object System.Drawing.Point(186, 100)
$monitorPage.Controls.Add($btnMonCheckNow)

$btnMonUnschedule = Make-Button "✕  Unschedule" $cardColor 140
$btnMonUnschedule.Location = New-Object System.Drawing.Point(356, 100)
$btnMonUnschedule.ForeColor = $redColor
$btnMonUnschedule.Enabled = $false
$monitorPage.Controls.Add($btnMonUnschedule)

$monLblPendingTitle = Make-Label "PENDING UPDATES" $fontBold $mutedColor
$monLblPendingTitle.Location = New-Object System.Drawing.Point(16, 160)
$monitorPage.Controls.Add($monLblPendingTitle)

$monPendingStatusLabel = Make-Label "—" $fontBold $textColor
$monPendingStatusLabel.AutoSize = $false
$monPendingStatusLabel.Size = New-Object System.Drawing.Size(870, 24)
$monPendingStatusLabel.Location = New-Object System.Drawing.Point(16, 186)
$monitorPage.Controls.Add($monPendingStatusLabel)

$monPendingList = New-Object System.Windows.Forms.RichTextBox
$monPendingList.Location    = New-Object System.Drawing.Point(16, 218)
$monPendingList.Size        = New-Object System.Drawing.Size(876, 400)
$monPendingList.BackColor   = $panelColor
$monPendingList.ForeColor   = $textColor
$monPendingList.Font        = $fontMono
$monPendingList.BorderStyle = "None"
$monPendingList.ReadOnly    = $true
$monPendingList.ScrollBars  = "Vertical"
$monitorPage.Controls.Add($monPendingList)

$btnMonSyncPending = Make-Button "▶  Sync pending now" ([System.Drawing.Color]::FromArgb(190, 24, 93)) 200
$btnMonSyncPending.Location = New-Object System.Drawing.Point(16, 632)
$btnMonSyncPending.Enabled  = $false
$monitorPage.Controls.Add($btnMonSyncPending)

# =============================================================================
# PROCESS RUNNER
# =============================================================================

$script:syncProcess     = $null
$script:syncStdoutFile  = Join-Path $PSScriptRoot "_temp_video_sync_stdout.log"
$script:syncStderrFile  = Join-Path $PSScriptRoot "_temp_video_sync_stderr.log"
$script:syncStdoutPos   = 0
$script:syncStderrPos   = 0

$script:syncStartTime           = $null
$script:syncPlaylistsTotal      = 0
$script:syncPlaylistsDone       = 0
$script:syncCurrentName         = ""
$script:syncCurrentItem         = 0
$script:syncCurrentTotal        = 0
$script:syncCurrentItemProgress = 0.0
$script:syncLineBuffer          = ""
$script:syncProgressSamples     = $null
$script:syncEtaWindowSeconds    = 60

function Update-ProgressFromText {
    param([string]$Text)
    if (-not $Text) { return }
    $buffer = $script:syncLineBuffer + $Text
    $lines  = $buffer -split "`r?`n"
    if ($lines.Count -lt 2) {
        $script:syncLineBuffer = $buffer
        return
    }
    $script:syncLineBuffer = $lines[$lines.Count - 1]
    for ($li = 0; $li -lt ($lines.Count - 1); $li++) {
        $line = $lines[$li]
        if ($line -match '\[INFO\]\s*Syncing:\s*(.+?)\s*$') {
            $script:syncCurrentName         = $matches[1]
            $script:syncCurrentItem         = 0
            $script:syncCurrentTotal        = 0
            $script:syncCurrentItemProgress = 0.0
        }
        elseif ($line -match '\[INFO\]\s*(?:Tracks|Videos) on YouTube:\s*(\d+)') {
            $script:syncCurrentTotal = [int]$matches[1]
        }
        elseif ($line -match 'Downloading item\s+(\d+)\s+of\s+(\d+)') {
            $script:syncCurrentItem         = [int]$matches[1]
            $script:syncCurrentTotal        = [int]$matches[2]
            $script:syncCurrentItemProgress = 0.0
        }
        elseif ($line -match '\[download\]\s+([\d.]+)%\s+of') {
            $pct = [double]$matches[1]
            if ($pct -ge 0 -and $pct -le 100) {
                $script:syncCurrentItemProgress = $pct / 100.0
            }
        }
        elseif ($line -match '\[INFO\]\s*Done:\s*(.+?)\s*$') {
            $script:syncPlaylistsDone       = $script:syncPlaylistsDone + 1
            $script:syncCurrentItem         = 0
            $script:syncCurrentTotal        = 0
            $script:syncCurrentItemProgress = 0.0
        }
    }
}

function Update-ProgressUI {
    if (-not $script:syncStartTime -or $script:syncPlaylistsTotal -le 0) { return }

    try {
        $playlistFraction = 0.0
        if ($script:syncCurrentTotal -gt 0 -and $script:syncCurrentItem -gt 0) {
            $itemsCompleted = [double]($script:syncCurrentItem - 1) + [double]$script:syncCurrentItemProgress
            if ($itemsCompleted -lt 0) { $itemsCompleted = 0 }
            $playlistFraction = [Math]::Min(1.0, $itemsCompleted / [double]$script:syncCurrentTotal)
        }
        $overall = ([double]$script:syncPlaylistsDone + $playlistFraction) / [double]$script:syncPlaylistsTotal
        if ($overall -gt 1.0) { $overall = 1.0 }
        if ($overall -lt 0.0) { $overall = 0.0 }
        $percent = [int]([Math]::Round($overall * 100))
        if ($percent -lt 0)   { $percent = 0 }
        if ($percent -gt 100) { $percent = 100 }
        $progressBar.Value = $percent
        $progressPercentLabel.Text = "$percent%"

        $nextNum = $script:syncPlaylistsDone + 1
        if ($nextNum -gt $script:syncPlaylistsTotal) { $nextNum = $script:syncPlaylistsTotal }

        if ($script:syncCurrentName) {
            if ($script:syncCurrentTotal -gt 0) {
                $progressStatusLabel.Text = "Playlist $nextNum/$($script:syncPlaylistsTotal): $($script:syncCurrentName) (item $($script:syncCurrentItem)/$($script:syncCurrentTotal))  [$($script:syncPlaylistsDone) done]"
            } else {
                $progressStatusLabel.Text = "Playlist $nextNum/$($script:syncPlaylistsTotal): $($script:syncCurrentName)  [$($script:syncPlaylistsDone) done]"
            }
        } else {
            $progressStatusLabel.Text = "Preparing..."
        }

        $now        = Get-Date
        $elapsed    = $now - $script:syncStartTime
        $elapsedStr = $elapsed.ToString("hh\:mm\:ss")

        if (-not $script:syncProgressSamples) {
            $script:syncProgressSamples = New-Object System.Collections.Generic.List[object]
        }
        $script:syncProgressSamples.Add([pscustomobject]@{
            Time    = $now
            Overall = $overall
        })
        $cutoff = $now.AddSeconds(-$script:syncEtaWindowSeconds)
        while ($script:syncProgressSamples.Count -gt 0 -and $script:syncProgressSamples[0].Time -lt $cutoff) {
            $script:syncProgressSamples.RemoveAt(0)
        }

        $windowRate = 0.0
        if ($script:syncProgressSamples.Count -ge 2) {
            $oldest = $script:syncProgressSamples[0]
            $newest = $script:syncProgressSamples[$script:syncProgressSamples.Count - 1]
            $dt = ($newest.Time - $oldest.Time).TotalSeconds
            $dp = $newest.Overall - $oldest.Overall
            if ($dt -gt 0.5 -and $dp -gt 0) {
                $windowRate = $dp / $dt
            }
        }

        if ($overall -ge 1.0) {
            $progressEtaLabel.Text = "ETA: done   |   elapsed $elapsedStr"
        } elseif ($windowRate -gt 0) {
            $remaining = 1.0 - $overall
            $remainSec = $remaining / $windowRate
            if ($remainSec -gt 86400) { $remainSec = 86400 }
            $eta    = [TimeSpan]::FromSeconds([int]$remainSec)
            $etaStr = $eta.ToString("hh\:mm\:ss")
            $progressEtaLabel.Text = "ETA: $etaStr   |   elapsed $elapsedStr"
        } elseif ($script:syncProgressSamples.Count -lt 3) {
            $progressEtaLabel.Text = "ETA: estimating...   |   elapsed $elapsedStr"
        } else {
            $progressEtaLabel.Text = "ETA: stalled   |   elapsed $elapsedStr"
        }
    } catch {
        $progressEtaLabel.Text = "ETA err: $($_.Exception.Message)"
    }
}

function Read-NewBytes {
    param([string]$Path, [long]$FromOffset)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $fs = [System.IO.FileStream]::new(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite
        )
    } catch {
        return $null
    }
    try {
        if ($fs.Length -le $FromOffset) { return [pscustomobject]@{ Text = ""; NewOffset = $FromOffset } }
        $fs.Seek($FromOffset, [System.IO.SeekOrigin]::Begin) | Out-Null
        $remaining = [int]($fs.Length - $FromOffset)
        $buffer = New-Object byte[] $remaining
        [void]$fs.Read($buffer, 0, $remaining)
        $text = [System.Text.Encoding]::UTF8.GetString($buffer)
        return [pscustomobject]@{ Text = $text; NewOffset = $fs.Length }
    } finally {
        $fs.Close()
    }
}

$pollTimer = New-Object System.Windows.Forms.Timer
$pollTimer.Interval = 500
$pollTimer.add_Tick({
  try {
    $result = Read-NewBytes -Path $script:syncStdoutFile -FromOffset $script:syncStdoutPos
    if ($result -and $result.Text) {
        $script:syncStdoutPos = $result.NewOffset
        Append-Log $result.Text
        Update-ProgressFromText -Text $result.Text
    }
    $result = Read-NewBytes -Path $script:syncStderrFile -FromOffset $script:syncStderrPos
    if ($result -and $result.Text) {
        $script:syncStderrPos = $result.NewOffset
        Append-Log $result.Text
        Update-ProgressFromText -Text $result.Text
    }

    if ($script:syncStartTime) { Update-ProgressUI }
  } catch {
    $logBox.AppendText("[TICK ERR] $($_.Exception.Message)`r`n")
  }

    if ($script:syncProcess -and $script:syncProcess.HasExited) {
        $pollTimer.Stop()
        $btnSyncAll.Enabled  = $true
        $btnSyncSel.Enabled  = $true
        $btnStopSync.Enabled = $false
        $logBox.AppendText("[DONE] Sync completed.`r`n")
        $logBox.ScrollToCaret()
        for ($i = 0; $i -lt $grid.Rows.Count; $i++) {
            $name = $grid.Rows[$i].Cells[1].Value
            $grid.Rows[$i].Cells[2].Value = Get-LocalCount       -Name $name
            $grid.Rows[$i].Cells[4].Value = Get-UnavailableCount -Name $name
            $grid.Rows[$i].Cells[5].Value = "Refresh to check"
        }
        $progressBar.Value = 100
        $progressPercentLabel.Text = "100%"
        $progressStatusLabel.Text  = "Completed"
        $progressEtaLabel.Text     = "ETA: done"
    }
})

function Start-Sync {
    param([hashtable]$PlaylistsToSync)

    if ($script:syncProcess -and -not $script:syncProcess.HasExited) {
        [System.Windows.Forms.MessageBox]::Show("A sync is already running.", "blackjack-video-sync")
        return
    }

    $tempConfig = Join-Path $PSScriptRoot "_temp_video_sync_config.ps1"
    $cookiesBrowser = ""
    $cookiesFile    = ""
    $maxHeight      = 1080
    if (Get-Variable -Name COOKIES_FROM_BROWSER -ErrorAction SilentlyContinue) {
        $cookiesBrowser = $COOKIES_FROM_BROWSER
    }
    if (Get-Variable -Name COOKIES_FILE -ErrorAction SilentlyContinue) {
        $cookiesFile = $COOKIES_FILE
    }
    if (Get-Variable -Name MAX_VIDEO_HEIGHT -ErrorAction SilentlyContinue) {
        $maxHeight = $MAX_VIDEO_HEIGHT
    }
    $lines = @(
        "`$BASE_DIR = `"$BASE_DIR`"",
        "`$DURATION_TOLERANCE = $DURATION_TOLERANCE",
        "`$MAX_VIDEO_HEIGHT = $maxHeight",
        "`$COOKIES_FROM_BROWSER = `"$($cookiesBrowser -replace '"','`"')`"",
        "`$COOKIES_FILE = `"$($cookiesFile -replace '"','`"')`"",
        "`$PLAYLISTS = [ordered]@{"
    )
    foreach ($entry in $PlaylistsToSync.GetEnumerator()) {
        $escapedKey = $entry.Key -replace '"', '`"'
        $lines += "    `"$escapedKey`" = `"$($entry.Value)`""
    }
    $lines += "}"
    Set-Content $tempConfig $lines -Encoding UTF8

    if (Test-Path -LiteralPath $script:syncStdoutFile) { Remove-Item -LiteralPath $script:syncStdoutFile -Force }
    if (Test-Path -LiteralPath $script:syncStderrFile) { Remove-Item -LiteralPath $script:syncStderrFile -Force }
    New-Item -Path $script:syncStdoutFile -ItemType File -Force | Out-Null
    New-Item -Path $script:syncStderrFile -ItemType File -Force | Out-Null
    $script:syncStdoutPos = 0
    $script:syncStderrPos = 0

    $script:syncStartTime           = Get-Date
    $script:syncPlaylistsTotal      = $PlaylistsToSync.Count
    $script:syncPlaylistsDone       = 0
    $script:syncCurrentName         = ""
    $script:syncCurrentItem         = 0
    $script:syncCurrentTotal        = 0
    $script:syncCurrentItemProgress = 0.0
    $script:syncLineBuffer          = ""
    $script:syncProgressSamples     = New-Object System.Collections.Generic.List[object]
    $progressBar.Value         = 0
    $progressPercentLabel.Text = "0%"
    $progressStatusLabel.Text  = "Starting..."
    $progressEtaLabel.Text     = "ETA: --"

    $btnSyncAll.Enabled  = $false
    $btnSyncSel.Enabled  = $false
    $btnStopSync.Enabled = $true
    $logBox.Clear()
    $logBox.AppendText("[START] Syncing $($PlaylistsToSync.Count) playlist(s)...`r`n")

    try {
        $script:syncProcess = Start-Process -FilePath "pwsh.exe" `
            -ArgumentList @(
                "-ExecutionPolicy", "Bypass",
                "-File", "`"$syncScriptPath`"",
                "-ConfigOverride", "`"$tempConfig`""
            ) `
            -RedirectStandardOutput $script:syncStdoutFile `
            -RedirectStandardError  $script:syncStderrFile `
            -NoNewWindow `
            -PassThru
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Failed to start sync: $_", "blackjack-video-sync", "OK", "Error")
        $btnSyncAll.Enabled = $true
        $btnSyncSel.Enabled = $true
        return
    }

    $pollTimer.Start()
}

# =============================================================================
# MONITOR TAB — helpers + dialog
# =============================================================================

$script:v3TaskName = "BlackjackVideoSyncCheck"

function Refresh-MonitorDisplay {
    $task = Get-ScheduledTask -TaskName $script:v3TaskName -ErrorAction SilentlyContinue
    if ($task) {
        $info = Get-ScheduledTaskInfo -TaskName $script:v3TaskName -ErrorAction SilentlyContinue
        $parts = @("✓ SCHEDULED  ·  task '$($script:v3TaskName)'")
        if ($info) {
            if ($info.NextRunTime -and $info.NextRunTime.Year -ge 2010) {
                $parts += "Next run: $($info.NextRunTime)"
            }
            if ($info.LastRunTime -and $info.LastRunTime.Year -ge 2010) {
                $parts += "Last run: $($info.LastRunTime)"
            } else {
                $parts += "Last run: never"
            }
        }
        $monSchedStatusLabel.Text      = $parts -join "`r`n"
        $monSchedStatusLabel.ForeColor = $greenColor
        $btnMonUnschedule.Enabled      = $true
    } else {
        $monSchedStatusLabel.Text      = "Not scheduled.`r`nClick 'Schedule...' to set up automatic checks."
        $monSchedStatusLabel.ForeColor = $mutedColor
        $btnMonUnschedule.Enabled      = $false
    }

    $pendingPath = Join-Path $PSScriptRoot "_v3_video_pending.json"
    if (-not (Test-Path -LiteralPath $pendingPath)) {
        $monPendingStatusLabel.Text = "No check has been run yet — click 'Check now'."
        $monPendingStatusLabel.ForeColor = $mutedColor
        $monPendingList.Text = ""
        $btnMonSyncPending.Enabled = $false
        return
    }
    try {
        $state = Get-Content -LiteralPath $pendingPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        $monPendingStatusLabel.Text = "Could not read _v3_video_pending.json: $($_.Exception.Message)"
        $monPendingStatusLabel.ForeColor = $redColor
        $monPendingList.Text = ""
        $btnMonSyncPending.Enabled = $false
        return
    }

    $totalPending = [int]$state.TotalPending
    $playlistsWithUpdates = @($state.PlaylistsWithUpdates)
    $tsString = ""
    if ($state.Timestamp) {
        try {
            $tsString = "  ·  last check: $([datetime]$state.Timestamp)"
        } catch {}
    }

    if ($totalPending -gt 0) {
        $monPendingStatusLabel.Text      = "$totalPending new video(s) in $($playlistsWithUpdates.Count) playlist(s)$tsString"
        $monPendingStatusLabel.ForeColor = $orangeColor
        $btnMonSyncPending.Enabled       = $true

        $sb = New-Object System.Text.StringBuilder
        foreach ($p in $playlistsWithUpdates) {
            [void]$sb.AppendLine(">> $($p.Name)  ($($p.Pending))")
            foreach ($t in $p.PendingTitles) {
                [void]$sb.AppendLine("     - $t")
            }
            [void]$sb.AppendLine("")
        }
        $monPendingList.Text = $sb.ToString()
    } else {
        $monPendingStatusLabel.Text      = "Up to date$tsString"
        $monPendingStatusLabel.ForeColor = $greenColor
        $btnMonSyncPending.Enabled       = $false
        $monPendingList.Text = ""
    }
}

function Show-ScheduleDialog {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text            = "Schedule update check (video)"
    $dlg.Size            = New-Object System.Drawing.Size(460, 340)
    $dlg.StartPosition   = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox     = $false
    $dlg.MinimizeBox     = $false
    $dlg.BackColor       = $bgColor
    $dlg.ForeColor       = $textColor
    $dlg.Font            = $fontMain

    $lblTitle = Make-Label "Auto-check for new videos" $fontTitle $accentColor
    $lblTitle.Location = New-Object System.Drawing.Point(16, 14)
    $dlg.Controls.Add($lblTitle)

    $lblFreq = Make-Label "Frequency" $fontBold $mutedColor
    $lblFreq.Location = New-Object System.Drawing.Point(16, 60)
    $dlg.Controls.Add($lblFreq)

    $cboFreq = New-Object System.Windows.Forms.ComboBox
    $cboFreq.DropDownStyle = "DropDownList"
    $cboFreq.Location      = New-Object System.Drawing.Point(16, 84)
    $cboFreq.Size          = New-Object System.Drawing.Size(410, 26)
    $cboFreq.BackColor     = $cardColor
    $cboFreq.ForeColor     = $textColor
    [void]$cboFreq.Items.AddRange(@(
        "Daily",
        "Every 3 days",
        "Weekly (every 7 days)",
        "Monthly (every 30 days)",
        "Semestral (every 180 days)"
    ))
    $cboFreq.SelectedIndex = 2
    $dlg.Controls.Add($cboFreq)

    $lblTime = Make-Label "Time of day (HH:MM)" $fontBold $mutedColor
    $lblTime.Location = New-Object System.Drawing.Point(16, 124)
    $dlg.Controls.Add($lblTime)

    $txtTime = New-Object System.Windows.Forms.TextBox
    $txtTime.Location    = New-Object System.Drawing.Point(16, 148)
    $txtTime.Size        = New-Object System.Drawing.Size(120, 26)
    $txtTime.BackColor   = $cardColor
    $txtTime.ForeColor   = $textColor
    $txtTime.BorderStyle = "FixedSingle"
    $txtTime.Text        = "09:30"
    $dlg.Controls.Add($txtTime)

    $lblStatus = Make-Label "" $fontMain $mutedColor
    $lblStatus.Location = New-Object System.Drawing.Point(16, 188)
    $lblStatus.AutoSize = $false
    $lblStatus.Size     = New-Object System.Drawing.Size(420, 40)
    $dlg.Controls.Add($lblStatus)

    $existingTask = Get-ScheduledTask -TaskName $script:v3TaskName -ErrorAction SilentlyContinue
    if ($existingTask) {
        $lblStatus.Text      = "Currently scheduled. Save will overwrite, Remove will delete."
        $lblStatus.ForeColor = $greenColor
    } else {
        $lblStatus.Text      = "Not currently scheduled."
        $lblStatus.ForeColor = $mutedColor
    }

    $btnSave = Make-Button "Save" $accentColor 110
    $btnSave.Location = New-Object System.Drawing.Point(16, 250)
    $btnSave.add_Click({
        $intervalMap = @{
            "Daily"                       = 1
            "Every 3 days"                = 3
            "Weekly (every 7 days)"       = 7
            "Monthly (every 30 days)"     = 30
            "Semestral (every 180 days)"  = 180
        }
        $interval = $intervalMap[$cboFreq.SelectedItem]
        $timeStr  = $txtTime.Text.Trim()
        try {
            $atTime = [datetime]::ParseExact($timeStr, "HH:mm", $null)
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Invalid time format. Use HH:MM (e.g. 09:00).", "Error") | Out-Null
            return
        }

        $checkScript = Join-Path $PSScriptRoot "video_check_updates_v1.ps1"
        $pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
        $pwshPath = if ($pwshCmd) { $pwshCmd.Source } else { "pwsh.exe" }

        $action = New-ScheduledTaskAction `
            -Execute $pwshPath `
            -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$checkScript`" -Quiet" `
            -WorkingDirectory $PSScriptRoot

        $trigger = New-ScheduledTaskTrigger -Daily -DaysInterval $interval -At $atTime

        $settings = New-ScheduledTaskSettingsSet `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries `
            -StartWhenAvailable `
            -RunOnlyIfNetworkAvailable `
            -ExecutionTimeLimit (New-TimeSpan -Hours 1)

        $userId = "$env:USERDOMAIN\$env:USERNAME"
        if (-not $env:USERDOMAIN) { $userId = "$env:COMPUTERNAME\$env:USERNAME" }
        $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited

        if (Get-ScheduledTask -TaskName $script:v3TaskName -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $script:v3TaskName -Confirm:$false
        }

        try {
            Register-ScheduledTask `
                -TaskName $script:v3TaskName `
                -Action $action `
                -Trigger $trigger `
                -Settings $settings `
                -Principal $principal `
                -Description "blackjack-video-sync update check ($($cboFreq.SelectedItem))" `
                -ErrorAction Stop | Out-Null

            [System.Windows.Forms.MessageBox]::Show(
                "Schedule saved.`n`nFrequency: $($cboFreq.SelectedItem)`nTime: $timeStr",
                "Saved") | Out-Null
            $dlg.Close()
        } catch {
            [System.Windows.Forms.MessageBox]::Show(
                "Failed to register task:`n$($_.Exception.Message)",
                "Error") | Out-Null
        }
    })
    $dlg.Controls.Add($btnSave)

    $btnRemove = Make-Button "Remove" $cardColor 110
    $btnRemove.Location = New-Object System.Drawing.Point(136, 250)
    $btnRemove.add_Click({
        if (Get-ScheduledTask -TaskName $script:v3TaskName -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $script:v3TaskName -Confirm:$false
            [System.Windows.Forms.MessageBox]::Show("Schedule removed.", "Removed") | Out-Null
            $dlg.Close()
        } else {
            [System.Windows.Forms.MessageBox]::Show("No schedule to remove.", "Info") | Out-Null
        }
    })
    $dlg.Controls.Add($btnRemove)

    $btnCancel = Make-Button "Cancel" $cardColor 110
    $btnCancel.Location = New-Object System.Drawing.Point(316, 250)
    $btnCancel.add_Click({ $dlg.Close() })
    $dlg.Controls.Add($btnCancel)

    [void]$dlg.ShowDialog()
}

# =============================================================================
# EVENT HANDLERS
# =============================================================================

$btnSelectAll.add_Click({
    $allChecked = $true
    for ($i = 0; $i -lt $grid.Rows.Count; $i++) {
        if (-not $grid.Rows[$i].Cells[0].Value) { $allChecked = $false; break }
    }
    for ($i = 0; $i -lt $grid.Rows.Count; $i++) {
        $grid.Rows[$i].Cells[0].Value = -not $allChecked
    }
})

$btnRefresh.add_Click({
    $btnRefresh.Enabled  = $false
    $btnRefresh.Text     = "Checking..."
    $btnSyncSel.Enabled  = $false
    $btnSyncAll.Enabled  = $false
    $form.Cursor         = [System.Windows.Forms.Cursors]::WaitCursor
    $progressStatusLabel.Text = "Refresh in progress — please wait, this can take a while on a slow NAS..."
    $logBox.Clear()
    $logBox.AppendText("[INFO] Checking playlist status...`r`n")
    [System.Windows.Forms.Application]::DoEvents()

    $totalRows = $grid.Rows.Count
    for ($i = 0; $i -lt $totalRows; $i++) {
        $name = $grid.Rows[$i].Cells[1].Value
        $url  = $grid.Rows[$i].Tag

        $progressStatusLabel.Text = "Refreshing $($i + 1)/$totalRows : $name"
        [System.Windows.Forms.Application]::DoEvents()

        $local   = Get-LocalCount       -Name $name
        $yt      = Get-YoutubeCount     -Url  $url
        $unavail = Get-UnavailableCount -Name $name

        $grid.Rows[$i].Cells[2].Value = $local
        $grid.Rows[$i].Cells[4].Value = $unavail
        if ($yt -lt 0) {
            $grid.Rows[$i].Cells[3].Value = "Error"
            $grid.Rows[$i].Cells[5].Value = "Could not check"
            $grid.Rows[$i].DefaultCellStyle.ForeColor = $redColor
        } else {
            $grid.Rows[$i].Cells[3].Value = $yt
            $expected = $yt - $unavail
            if ($local -ge $expected) {
                if ($unavail -gt 0) {
                    $grid.Rows[$i].Cells[5].Value = "✓  In sync (${unavail} unavail.)"
                } else {
                    $grid.Rows[$i].Cells[5].Value = "✓  In sync"
                }
                $grid.Rows[$i].DefaultCellStyle.ForeColor = $greenColor
            } else {
                $missing = $expected - $local
                $grid.Rows[$i].Cells[5].Value = "⚠  $missing missing"
                $grid.Rows[$i].DefaultCellStyle.ForeColor = $orangeColor
            }
        }
        $logBox.AppendText("[OK] $name - local: $local, YouTube: $yt, unavail: $unavail`r`n")
        $logBox.ScrollToCaret()
        [System.Windows.Forms.Application]::DoEvents()
    }

    $btnRefresh.Enabled       = $true
    $btnRefresh.Text          = "↻  Refresh Status"
    $btnSyncSel.Enabled       = $true
    $btnSyncAll.Enabled       = $true
    $form.Cursor              = [System.Windows.Forms.Cursors]::Default
    $progressStatusLabel.Text = "Idle"
    $logBox.AppendText("[DONE] Status check complete.`r`n")
})

$btnSyncSel.add_Click({
    $selected = [ordered]@{}
    for ($i = 0; $i -lt $grid.Rows.Count; $i++) {
        if ($grid.Rows[$i].Cells[0].Value -eq $true) {
            $name = $grid.Rows[$i].Cells[1].Value
            $url  = $grid.Rows[$i].Tag
            $selected[$name] = $url
        }
    }
    if ($selected.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Select at least one playlist using the checkboxes.", "blackjack-video-sync")
        return
    }
    Start-Sync -PlaylistsToSync $selected
})

$btnSyncAll.add_Click({
    $all = [ordered]@{}
    for ($i = 0; $i -lt $grid.Rows.Count; $i++) {
        $all[$grid.Rows[$i].Cells[1].Value] = $grid.Rows[$i].Tag
    }
    Start-Sync -PlaylistsToSync $all
})

$btnRemoveSel.add_Click({
    $selected = @()
    for ($i = 0; $i -lt $grid.Rows.Count; $i++) {
        if ($grid.Rows[$i].Cells[0].Value -eq $true) {
            $selected += [pscustomobject]@{
                Index = $i
                Name  = [string]$grid.Rows[$i].Cells[1].Value
            }
        }
    }
    if ($selected.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show(
            "Select at least one playlist using the checkboxes.",
            "blackjack-video-sync") | Out-Null
        return
    }
    $msg = "Remove $($selected.Count) playlist(s) from video_config.ps1?`n`n"
    $msg += (($selected | ForEach-Object { "  - $($_.Name)" }) -join "`n")
    $msg += "`n`nThe folders on the NAS are NOT deleted. Only the config entries are removed."
    $result = [System.Windows.Forms.MessageBox]::Show(
        $msg, "Confirm removal", "YesNo", "Warning")
    if ($result -ne "Yes") { return }

    foreach ($s in $selected) {
        Remove-PlaylistFromConfig -Name $s.Name | Out-Null
    }
    foreach ($s in ($selected | Sort-Object Index -Descending)) {
        $grid.Rows.RemoveAt($s.Index)
    }
    Update-GridScrollbar
    $logBox.AppendText("[OK] Removed $($selected.Count) playlist(s) from video_config.ps1.`r`n")
})

$btnStopSync.add_Click({
    if (-not $script:syncProcess -or $script:syncProcess.HasExited) {
        [System.Windows.Forms.MessageBox]::Show("No sync is running.", "blackjack-video-sync") | Out-Null
        return
    }
    $result = [System.Windows.Forms.MessageBox]::Show(
        "Stop the running sync?`n`nAny video currently being downloaded will be abandoned. Completed videos stay on disk.",
        "blackjack-video-sync",
        "YesNo",
        "Warning")
    if ($result -ne "Yes") { return }

    try {
        $script:syncProcess.Kill()
    } catch {}
    Get-Process yt-dlp, ffmpeg -ErrorAction SilentlyContinue | ForEach-Object {
        try { $_.Kill() } catch {}
    }
    $logBox.AppendText("[STOPPED] Sync aborted by user.`r`n")
    $btnStopSync.Enabled = $false
})

$btnFetch.add_Click({
    $url = $urlBox.Text.Trim()
    if (-not $url -or $url -eq "") {
        [System.Windows.Forms.MessageBox]::Show("Paste a YouTube playlist URL first.", "blackjack-video-sync")
        return
    }
    $btnFetch.Enabled = $false
    $btnFetch.Text    = "Fetching..."
    $form.Cursor      = [System.Windows.Forms.Cursors]::WaitCursor
    $logBox.AppendText("[INFO] Fetching playlist name from YouTube (can take a few seconds)...`r`n")
    [System.Windows.Forms.Application]::DoEvents()

    $title = Get-YoutubePlaylistTitle -Url $url
    if ($title) {
        $safeTitle = ConvertTo-SafeFolderName -Name $title
        $nameBox.Text = $safeTitle
        $nameBox.ForeColor = $textColor
        if ($safeTitle -ne $title) {
            $logBox.AppendText("[OK] Found: $title`r`n")
            $logBox.AppendText("[INFO] Sanitized to: $safeTitle`r`n")
        } else {
            $logBox.AppendText("[OK] Found: $title`r`n")
        }
    } else {
        $logBox.AppendText("[ERROR] Could not fetch playlist name.`r`n")
    }
    $form.Cursor      = [System.Windows.Forms.Cursors]::Default
    $btnFetch.Enabled = $true
    $btnFetch.Text    = "Fetch Name"
})

$btnAdd.add_Click({
    $url  = $urlBox.Text.Trim()
    $name = $nameBox.Text.Trim()
    if (-not $url -or -not $name) {
        [System.Windows.Forms.MessageBox]::Show("Fill in both URL and Name.", "blackjack-video-sync")
        return
    }

    $newListId = ""
    if ($url -match 'list=([\w-]+)') { $newListId = $matches[1] }

    $existingName = $null
    for ($i = 0; $i -lt $grid.Rows.Count; $i++) {
        $existingRowName = [string]$grid.Rows[$i].Cells[1].Value
        $existingRowUrl  = [string]$grid.Rows[$i].Tag
        $existingListId  = ""
        if ($existingRowUrl -match 'list=([\w-]+)') { $existingListId = $matches[1] }

        if ($existingRowName -eq $name) {
            $existingName = $existingRowName
            break
        }
        if ($newListId -and $existingListId -and ($newListId -eq $existingListId)) {
            $existingName = $existingRowName
            break
        }
    }
    if ($existingName) {
        [System.Windows.Forms.MessageBox]::Show(
            "This playlist is already in your list as:`n`n  `"$existingName`"`n`nNo change made.",
            "blackjack-video-sync",
            "OK",
            "Information") | Out-Null
        return
    }

    $ok = Add-PlaylistToConfig -Name $name -Url $url
    if ($ok) {
        $row = $grid.Rows.Add($false, $name, 0, "?", 0, "Not checked")
        $grid.Rows[$row].Tag = $url
        $urlBox.Text = ""
        $nameBox.Text = ""
        $logBox.AppendText("[OK] Added `"$name`" to video_config.ps1`r`n")
        Update-GridScrollbar
    } else {
        $logBox.AppendText("[ERROR] Could not write to video_config.ps1`r`n")
    }
})

# --- Monitor tab event handlers ---

$tabControl.add_SelectedIndexChanged({
    if ($tabControl.SelectedTab -eq $monitorPage) {
        Refresh-MonitorDisplay
    }
})

$btnMonSchedule.add_Click({
    Show-ScheduleDialog
    Refresh-MonitorDisplay
})

$btnMonUnschedule.add_Click({
    $result = [System.Windows.Forms.MessageBox]::Show(
        "Remove the scheduled update check?`n`nAutomatic checks will stop until you re-schedule.",
        "blackjack-video-sync",
        "YesNo",
        "Question")
    if ($result -ne "Yes") { return }
    if (Get-ScheduledTask -TaskName $script:v3TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $script:v3TaskName -Confirm:$false
    }
    Refresh-MonitorDisplay
})

$btnMonCheckNow.add_Click({
    $btnMonCheckNow.Enabled = $false
    $btnMonCheckNow.Text    = "Checking..."
    $btnMonSchedule.Enabled = $false
    $form.Cursor            = [System.Windows.Forms.Cursors]::WaitCursor
    $monPendingStatusLabel.Text      = "Check in progress — querying YouTube for each playlist..."
    $monPendingStatusLabel.ForeColor = $mutedColor
    [System.Windows.Forms.Application]::DoEvents()
    try {
        $checkScript = Join-Path $PSScriptRoot "video_check_updates_v1.ps1"
        & pwsh.exe -NoProfile -ExecutionPolicy Bypass -File $checkScript -Quiet | Out-Null
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Check failed: $($_.Exception.Message)", "blackjack-video-sync") | Out-Null
    }
    Refresh-MonitorDisplay
    $form.Cursor            = [System.Windows.Forms.Cursors]::Default
    $btnMonCheckNow.Enabled = $true
    $btnMonCheckNow.Text    = "↻  Check now"
    $btnMonSchedule.Enabled = $true
})

$btnMonSyncPending.add_Click({
    $pendingPath = Join-Path $PSScriptRoot "_v3_video_pending.json"
    if (-not (Test-Path -LiteralPath $pendingPath)) {
        [System.Windows.Forms.MessageBox]::Show(
            "No pending state file. Click 'Check now' first.",
            "blackjack-video-sync") | Out-Null
        return
    }
    try {
        $state = Get-Content -LiteralPath $pendingPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Could not read pending state: $($_.Exception.Message)",
            "blackjack-video-sync") | Out-Null
        return
    }
    $playlistsWithUpdates = @($state.PlaylistsWithUpdates)
    if ($playlistsWithUpdates.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show(
            "Nothing pending. Click 'Check now' to refresh.",
            "blackjack-video-sync") | Out-Null
        return
    }

    $playlistsToSync = [ordered]@{}
    foreach ($p in $playlistsWithUpdates) {
        $playlistsToSync[[string]$p.Name] = [string]$p.Url
    }

    $tabControl.SelectedTab = $syncPage
    Start-Sync -PlaylistsToSync $playlistsToSync
})

# Cleanup on close
$form.add_FormClosing({
    if ($script:syncProcess -and -not $script:syncProcess.HasExited) {
        try { $script:syncProcess.Kill() } catch {}
    }
    $pollTimer.Stop()
    $tempConfig = Join-Path $PSScriptRoot "_temp_video_sync_config.ps1"
    if (Test-Path -LiteralPath $tempConfig)             { Remove-Item -LiteralPath $tempConfig -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $script:syncStdoutFile)  { Remove-Item -LiteralPath $script:syncStdoutFile -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $script:syncStderrFile)  { Remove-Item -LiteralPath $script:syncStderrFile -Force -ErrorAction SilentlyContinue }
})

# =============================================================================
# RUN
# =============================================================================

$logBox.AppendText("[READY] blackjack-video-sync v1.0`r`n")
$logBox.AppendText("[INFO] Click 'Refresh Status' to check all playlists.`r`n")

[System.Windows.Forms.Application]::Run($form)
