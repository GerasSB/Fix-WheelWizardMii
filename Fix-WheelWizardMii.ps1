<#
.SYNOPSIS
    Fixes "my Mii shows in Wheel Wizard but not in Mario Kart Wii" for the
    WiiCompiled / recomp backend.

.DESCRIPTION
    In recomp mode with "use Dolphin data" turned off, the game boots against a
    private NAND at %APPDATA%\CT-MKWII\Recomp\UserData\NAND, but Wheel Wizard's
    Mii editor writes RFL_DB.dat to <Dolphin user folder>\Wii\shared2\menu\FaceLib.
    When no Dolphin folder is configured, the two never meet: the game logs

        [nand] NANDSafeOpen: FAILED to open ...\FaceLib\RFL_DB.dat for reading

    and every Mii slot is empty.

    This script finds your Miis wherever they ended up (loose .mii files, or any
    other RFL_DB.dat on the machine) and writes a valid Mii database into the
    NAND the game actually reads.

.PARAMETER WheelWizardRoot
    Wheel Wizard's data folder. Defaults to %APPDATA%\CT-MKWII.

.PARAMETER ExtraMiiSource
    Additional folder to scan for .mii files or an RFL_DB.dat.

.PARAMETER DryRun
    Report what would happen without writing anything.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Fix-WheelWizardMii.ps1

.NOTES
    Safe to re-run. Any existing RFL_DB.dat is backed up before it is replaced.
    Works on Windows PowerShell 5.1 and PowerShell 7+.
#>

[CmdletBinding()]
param(
    [string]$WheelWizardRoot,
    [string]$ExtraMiiSource,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# --- RFL_DB.dat layout constants (see wiibrew.org RFL_DB.dat) -----------------
$MiiLength   = 74
$MaxMiiSlots = 100
$HeaderOffset = 0x04
$CrcOffset   = 0x1F1DE
$DbSize      = 779968   # what Wheel Wizard itself generates

function Write-Step { param($m) Write-Host "  $m" }
function Write-Good { param($m) Write-Host "  $m" -ForegroundColor Green }
function Write-Warn { param($m) Write-Host "  $m" -ForegroundColor Yellow }

function Get-Crc16Ccitt {
    param([byte[]]$Buffer, [int]$Length)
    $crc = 0
    for ($i = 0; $i -lt $Length; $i++) {
        $crc = $crc -bxor ([int]$Buffer[$i] -shl 8)
        for ($bit = 0; $bit -lt 8; $bit++) {
            if ($crc -band 0x8000) { $crc = (($crc -shl 1) -bxor 0x1021) -band 0xFFFF }
            else                   { $crc = ($crc -shl 1) -band 0xFFFF }
        }
    }
    return $crc
}

function Get-MiiId {
    param([byte[]]$Block)
    return ([uint32]$Block[0x18] -shl 24) -bor ([uint32]$Block[0x19] -shl 16) -bor `
           ([uint32]$Block[0x1A] -shl 8)  -bor  [uint32]$Block[0x1B]
}

function Test-MiiBlock {
    param([byte[]]$Block)
    if ($null -eq $Block -or $Block.Length -ne $MiiLength) { return $false }
    # bit 15 of the flags word marks the slot invalid/empty
    if ($Block[0] -band 0x80) { return $false }
    if ((Get-MiiId $Block) -eq 0) { return $false }
    foreach ($b in $Block) { if ($b -ne 0) { return $true } }
    return $false
}

function Get-MiiName {
    param([byte[]]$Block)
    $chars = New-Object System.Collections.Generic.List[char]
    for ($i = 0x02; $i -lt 0x16; $i += 2) {
        $c = ([int]$Block[$i] -shl 8) -bor [int]$Block[$i + 1]
        if ($c -eq 0) { break }
        if ($c -ge 0xE000) { $c = 0x003F }  # Wii private-use glyph -> '?'
        $chars.Add([char]$c)
    }
    return -join $chars
}

function Get-MiiBlocksFromDatabase {
    param([string]$Path)
    $found = New-Object System.Collections.Generic.List[byte[]]
    try { $bytes = [System.IO.File]::ReadAllBytes($Path) } catch { return ,$found }
    if ($bytes.Length -lt ($HeaderOffset + $MiiLength)) { return ,$found }
    for ($i = 0; $i -lt $MaxMiiSlots; $i++) {
        $off = $HeaderOffset + ($i * $MiiLength)
        if (($off + $MiiLength) -gt $bytes.Length) { break }
        $block = New-Object byte[] $MiiLength
        [Array]::Copy($bytes, $off, $block, 0, $MiiLength)
        if (Test-MiiBlock $block) { $found.Add($block) }
    }
    return ,$found
}

function Get-TomlPath {
    param([string]$ConfigToml, [string]$Key)
    if (-not (Test-Path -LiteralPath $ConfigToml)) { return $null }
    foreach ($line in [System.IO.File]::ReadAllLines($ConfigToml)) {
        $t = $line.Trim()
        if ($t -match "^$Key\s*=\s*`"(.+)`"\s*$") {
            return $Matches[1].Replace('\\', '\')
        }
    }
    return $null
}

# --- 1. Locate Wheel Wizard ---------------------------------------------------
Write-Host ""
Write-Host "Wheel Wizard Mii fix" -ForegroundColor Cyan
Write-Host ""

function Read-CleanPath {
    param([string]$Prompt)
    $raw = Read-Host $Prompt
    if ($null -eq $raw) { return '' }
    $t = $raw.Trim()
    # Strip one layer of surrounding quotes (single or double), if present,
    # so paths typed as "C:\My Folder" or 'C:\My Folder' work the same as
    # an unquoted C:\My Folder (Read-Host already preserves inner spaces
    # either way - the quotes are only stripped here for tidiness).
    if ($t.Length -ge 2) {
        $first = $t[0]
        $last  = $t[$t.Length - 1]
        if (($first -eq '"' -and $last -eq '"') -or ($first -eq "'" -and $last -eq "'")) {
            $t = $t.Substring(1, $t.Length - 2)
        }
    }
    return $t.Trim()
}

if (-not $WheelWizardRoot) {
    if ($env:APPDATA) {
        $WheelWizardRoot = Join-Path $env:APPDATA 'CT-MKWII'
    }
}

while (-not $WheelWizardRoot -or -not (Test-Path -LiteralPath $WheelWizardRoot)) {
    if ($WheelWizardRoot) {
        Write-Warn "Wheel Wizard folder not found at: $WheelWizardRoot"
    } else {
        Write-Warn "APPDATA is not set, so the default Wheel Wizard path could not be guessed."
    }
    Write-Host ""
    Write-Host "  Enter the full path to your Wheel Wizard folder (the one containing 'Recomp')." -ForegroundColor Cyan
    Write-Host "  Quotes around the path are fine either way, e.g.:" -ForegroundColor Cyan
    Write-Host "      C:\Users\Name\AppData\Roaming\CT-MKWII" -ForegroundColor Cyan
    Write-Host "      `"C:\Users\Name With Spaces\AppData\Roaming\CT-MKWII`"" -ForegroundColor Cyan
    Write-Host ""
    $WheelWizardRoot = Read-CleanPath "  Path"
    if (-not $WheelWizardRoot) {
        Write-Warn "No path entered. Press Ctrl+C to cancel, or try again."
    }
}
Write-Step "Wheel Wizard: $WheelWizardRoot"

# --- 2. Work out which NAND the game actually boots against -------------------
$configToml = Join-Path $WheelWizardRoot 'Recomp\UserData\Config.toml'
$nandRoot = Get-TomlPath -ConfigToml $configToml -Key 'nand_root'
if ($nandRoot) {
    Write-Step "NAND root from Config.toml: $nandRoot"
} else {
    $nandRoot = Join-Path $WheelWizardRoot 'Recomp\UserData\NAND'
    Write-Step "NAND root (private, default): $nandRoot"
}
if (-not (Test-Path -LiteralPath $nandRoot)) {
    throw "The game's NAND folder does not exist yet: $nandRoot`nLaunch Retro Rewind once through Wheel Wizard, then re-run this script."
}

$faceLib  = Join-Path $nandRoot 'shared2\menu\FaceLib'
$targetDb = Join-Path $faceLib 'RFL_DB.dat'

# --- 3. Collect Miis from everywhere they might be hiding ---------------------
$sources = New-Object System.Collections.Generic.List[object]
$seenIds = New-Object System.Collections.Generic.HashSet[uint32]

function Add-Blocks {
    param($Blocks, [string]$From)
    if ($null -eq $Blocks) { return }
    # a single byte[] must not be iterated byte by byte
    if ($Blocks -is [byte[]]) { $Blocks = ,$Blocks }
    $added = 0
    foreach ($b in $Blocks) {
        $id = Get-MiiId $b
        if ($seenIds.Add($id)) {
            $sources.Add([pscustomobject]@{ Block = $b; Name = (Get-MiiName $b); From = $From })
            $added++
        }
    }
    if ($added -gt 0) { Write-Good "$added Mii(s) from $From" }
}

# 3a. Loose .mii files that Wheel Wizard or the user dropped anywhere.
#     Scanned FIRST so a freshly re-exported .mii (e.g. after an edit) wins
#     over a stale copy of the same Mii already sitting in a database below.
$looseRoots = @($WheelWizardRoot)
if ($ExtraMiiSource) { $looseRoots += $ExtraMiiSource }
foreach ($root in $looseRoots) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    Get-ChildItem -LiteralPath $root -Filter *.mii -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Length -eq $MiiLength } |
        ForEach-Object {
            $block = [System.IO.File]::ReadAllBytes($_.FullName)
            if (Test-MiiBlock $block) { Add-Blocks @(,$block) $_.Name }
        }
}

# 3b. Miis already in the target database keep their slots (skipped here if
#     a loose .mii file with the same Mii ID was already added above).
if (Test-Path -LiteralPath $targetDb) {
    Add-Blocks (Get-MiiBlocksFromDatabase $targetDb) 'the game NAND (existing)'
}

# 3c. Any other RFL_DB.dat on the machine - most importantly the one Wheel
#     Wizard's own Mii editor writes into a Dolphin user folder.
$otherDbs = New-Object System.Collections.Generic.List[string]

$configJson = Join-Path $WheelWizardRoot 'config.json'
if (Test-Path -LiteralPath $configJson) {
    try {
        $cfg = Get-Content -LiteralPath $configJson -Raw | ConvertFrom-Json
        foreach ($p in @($cfg.UserFolderPath, $cfg.DolphinLocation)) {
            if ($p) { $otherDbs.Add((Join-Path $p 'Wii\shared2\menu\FaceLib\RFL_DB.dat')) }
        }
    } catch { Write-Warn "Could not parse config.json - skipping it." }
}
$otherDbs.Add((Join-Path $WheelWizardRoot 'Recomp\Nand\shared2\menu\FaceLib\RFL_DB.dat'))
if ($env:APPDATA) {
    $otherDbs.Add((Join-Path $env:APPDATA 'Dolphin Emulator\Wii\shared2\menu\FaceLib\RFL_DB.dat'))
}
if ($env:USERPROFILE) {
    $otherDbs.Add((Join-Path $env:USERPROFILE 'Documents\Dolphin Emulator\Wii\shared2\menu\FaceLib\RFL_DB.dat'))
    $otherDbs.Add((Join-Path $env:USERPROFILE 'OneDrive\Documents\Dolphin Emulator\Wii\shared2\menu\FaceLib\RFL_DB.dat'))
}
if ($ExtraMiiSource) {
    $otherDbs.Add((Join-Path $ExtraMiiSource 'RFL_DB.dat'))
    $otherDbs.Add((Join-Path $ExtraMiiSource 'Wii\shared2\menu\FaceLib\RFL_DB.dat'))
}

foreach ($db in $otherDbs) {
    if ((Test-Path -LiteralPath $db) -and ($db -ne $targetDb)) {
        Add-Blocks (Get-MiiBlocksFromDatabase $db) $db
    }
}

if ($sources.Count -eq 0) {
    Write-Host ""
    Write-Warn "No Miis found anywhere."
    Write-Warn "Make a Mii in Wheel Wizard's 'My Miis' page first, then re-run this."
    Write-Warn "If your Mii lives somewhere unusual, point at it with -ExtraMiiSource <folder>."
    return
}

Write-Host ""
Write-Step "Miis to install ($($sources.Count)):"
foreach ($s in $sources) { Write-Step "    - $($s.Name)" }

if ($sources.Count -gt $MaxMiiSlots) {
    Write-Warn "More than $MaxMiiSlots Miis found; only the first $MaxMiiSlots will be kept."
}

# --- 4. Build the database ----------------------------------------------------
$db = New-Object byte[] $DbSize
[byte[]]$rnod = [System.Text.Encoding]::ASCII.GetBytes('RNOD')
[byte[]]$rnhd = [System.Text.Encoding]::ASCII.GetBytes('RNHD')
[Array]::Copy($rnod, 0, $db, 0x0000, 4)
$db[0x1CE0 + 0x0C] = 0x80
[Array]::Copy($rnhd, 0, $db, 0x1D00, 4)
$db[0x1D04] = 0xFF; $db[0x1D05] = 0xFF; $db[0x1D06] = 0xFF; $db[0x1D07] = 0xFF

$slot = 0
foreach ($s in $sources) {
    if ($slot -ge $MaxMiiSlots) { break }
    [Array]::Copy($s.Block, 0, $db, $HeaderOffset + ($slot * $MiiLength), $MiiLength)
    $slot++
}

$crc = Get-Crc16Ccitt -Buffer $db -Length $CrcOffset
$db[$CrcOffset]     = [byte](($crc -shr 8) -band 0xFF)
$db[$CrcOffset + 1] = [byte]($crc -band 0xFF)

# --- 5. Write it out ----------------------------------------------------------
Write-Host ""
if ($DryRun) {
    Write-Warn "Dry run - nothing written."
    Write-Step "Would write $slot Mii(s) to: $targetDb"
    return
}

if (-not (Test-Path -LiteralPath $faceLib)) {
    New-Item -ItemType Directory -Path $faceLib -Force | Out-Null
}
if (Test-Path -LiteralPath $targetDb) {
    $backup = "$targetDb.bak-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
    Copy-Item -LiteralPath $targetDb -Destination $backup -Force
    Write-Step "Backed up old database to: $(Split-Path -Leaf $backup)"
}
[System.IO.File]::WriteAllBytes($targetDb, $db)

Write-Good "Wrote $slot Mii(s) to $targetDb"
Write-Host ""
Write-Host "Done. Launch Retro Rewind - your Mii should appear when you pick one." -ForegroundColor Cyan
Write-Host "(If you have no licence yet, the game will walk you through making one.)"
Write-Host ""
