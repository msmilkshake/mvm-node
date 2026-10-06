# --- No param() block: all arguments are parsed manually from $args below. ---
# --- This avoids PowerShell's native parameter binder treating tokens like ---
# --- -v or --version as attempts to bind named parameters (which caused   ---
# --- "Missing an argument for parameter 'version'" errors previously).    ---

$flags = @($args | Where-Object { $_ -like "-*" })
$positional = @($args | Where-Object { $_ -notlike "-*" })

$command = $positional[0]
$version = $positional[1]

$Help = ($flags -contains "-h") -or ($flags -contains "--help") -or ($command -eq "help")
$ShowVersionFlag = ($flags -contains "-v") -or ($flags -contains "--version")
$ListVerboseFlag = ($flags -contains "-v") -or ($flags -contains "--verbose")

# --- MVM Version (bump this on every release!) ---
$MVM_VERSION = "1.0.2"

# --- GitHub repo used for self-update checks (EDIT BEFORE DISTRIBUTING) ---
$ghOwner = "msmilkshake"
$ghRepo  = "mvm-node"

# --- Dynamic Path Logic ---
$mvmRoot = $PSScriptRoot
$binPath = Join-Path $mvmRoot "bin"

# --- Node Path Logic ---
$base = Join-Path $mvmRoot "node"
$active = Join-Path $base "current"
$pathEntry = $active

$cacheFile = Join-Path $mvmRoot ".mvm-update-cache.json"

# =========================================================
# ===================  HELPER FUNCTIONS  ===================
# =========================================================

# --- Architecture detection (x64 / arm64) ---
function Get-NodeArch {
    try {
        $osArch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
        if ($osArch -eq [System.Runtime.InteropServices.Architecture]::Arm64) { return "arm64" }
        return "x64"
    }
    catch {
        if ($env:PROCESSOR_ARCHITEW6432 -eq "ARM64" -or $env:PROCESSOR_ARCHITECTURE -eq "ARM64") { return "arm64" }
        return "x64"
    }
}
$script:NodeArch = Get-NodeArch

# --- Generic upward directory search (used for .nvmrc / .mvmrc) ---
function Find-UpwardFile {
    param([string]$FileName)
    $dir = Get-Location
    while ($true) {
        $candidate = Join-Path $dir $FileName
        if (Test-Path $candidate) { return $candidate }
        $parent = Split-Path $dir -Parent
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }
    return $null
}

# --- .nvmrc parsing ---
function Get-NvmrcVersion {
    $path = Find-UpwardFile ".nvmrc"
    if (-not $path) { return $null }
    $raw = (Get-Content $path -Raw -ErrorAction SilentlyContinue).Trim()
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return $raw
}

# --- .mvmrc parsing (supports "version=", "proxy=", or a bare version like .nvmrc) ---
function Parse-Mvmrc {
    param([string]$Path)

    $result = @{ Version = $null; Proxy = $null }
    $lines = Get-Content $Path -ErrorAction SilentlyContinue
    if (-not $lines) { return $result }

    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith("#")) { continue }

        if ($trimmed -match "(?i)^version\s*=\s*(.+)$") {
            $result.Version = $matches[1].Trim().TrimStart("v")
        }
        elseif ($trimmed -match "(?i)^proxy\s*=\s*(.+)$") {
            $result.Proxy = $matches[1].Trim()
        }
        elseif (-not $result.Version) {
            $result.Version = $trimmed.TrimStart("v")
        }
    }

    return $result
}

# --- Inspect a Node install folder for bundled npm version and corepack status (100% accurate) ---
function Get-NodeBundleInfo {
    param(
        [string]$NodeFolderPath,
        [switch]$IncludeCorepackVersion  # spawns a process; opt-in for perf-sensitive callers
    )

    $info = [PSCustomObject]@{
        NpmVersion      = $null
        HasCorepack     = $false
        CorepackVersion = $null
        CorepackActive  = $false
    }

    $npmPkgJson = Join-Path $NodeFolderPath "node_modules\npm\package.json"
    $npmContent = Get-Content $npmPkgJson -Raw -ErrorAction SilentlyContinue
    if ($npmContent) {
        try {
            $info.NpmVersion = ($npmContent | ConvertFrom-Json).version
        }
        catch { }
    }

    $corepackCmd = Join-Path $NodeFolderPath "corepack.cmd"
    if (Test-Path $corepackCmd) {
        $info.HasCorepack = $true

        $shimCandidates = @("yarn.cmd", "pnpm.cmd", "yarnpkg.cmd", "pnpx.cmd")
        foreach ($shim in $shimCandidates) {
            $shimContent = Get-Content (Join-Path $NodeFolderPath $shim) -Raw -ErrorAction SilentlyContinue
            if ($shimContent -and $shimContent -match "corepack") {
                $info.CorepackActive = $true
                break
            }
        }

        if ($IncludeCorepackVersion) {
            try {
                $output = & $corepackCmd --version 2>$null
                if ($LASTEXITCODE -eq 0 -and $output) {
                    $info.CorepackVersion = $output.Trim()
                }
            }
            catch { }
        }
    }

    return $info
}

# --- Resolves the project's intended Node version: .mvmrc takes priority over .nvmrc ---
function Get-ProjectVersion {
    $mvmrcPath = Find-UpwardFile ".mvmrc"
    if ($mvmrcPath) {
        $data = Parse-Mvmrc -Path $mvmrcPath
        if ($data.Version) { return $data.Version }
    }
    return Get-NvmrcVersion
}

# --- Proxy discovery (runs once per invocation; used by all network calls below) ---
$script:ProxyUrl = $null
$mvmrcForProxy = Find-UpwardFile ".mvmrc"
if ($mvmrcForProxy) {
    $proxyData = Parse-Mvmrc -Path $mvmrcForProxy
    if ($proxyData.Proxy) { $script:ProxyUrl = $proxyData.Proxy }
}

# --- Proxy-aware network helpers ---
function Invoke-MvmRestMethod {
    param([string]$Uri, [hashtable]$Headers = $null, [int]$TimeoutSec = 15)
    $params = @{ Uri = $Uri; UseBasicParsing = $true; TimeoutSec = $TimeoutSec }
    if ($Headers) { $params.Headers = $Headers }
    if ($script:ProxyUrl) { $params.Proxy = $script:ProxyUrl }
    return Invoke-RestMethod @params
}

function Invoke-MvmWebRequest {
    param([string]$Uri, [int]$TimeoutSec = 15)
    $params = @{ Uri = $Uri; UseBasicParsing = $true; TimeoutSec = $TimeoutSec }
    if ($script:ProxyUrl) { $params.Proxy = $script:ProxyUrl }
    return Invoke-WebRequest @params
}

function New-MvmWebClient {
    $wc = New-Object System.Net.WebClient
    if ($script:ProxyUrl) { $wc.Proxy = New-Object System.Net.WebProxy($script:ProxyUrl) }
    return $wc
}

# --- Resolve an alias (lts/*, lts/<codename>, node, stable) to a concrete version ---
function Resolve-NodeAlias {
    param([string]$Alias)

    $fileKey = "win-$($script:NodeArch)-zip"
    try {
        $json = Invoke-MvmRestMethod -Uri "https://nodejs.org/dist/index.json"
    }
    catch {
        Write-Host "Error: Could not reach nodejs.org to resolve alias '$Alias': $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }

    $candidates = $json | Where-Object { $_.files -contains $fileKey }

    $match = $null
    if ($Alias -eq "node" -or $Alias -eq "stable") {
        $match = $candidates | Select-Object -First 1
    }
    elseif ($Alias -eq "lts/*") {
        $match = $candidates | Where-Object { $_.lts -ne $false } | Select-Object -First 1
    }
    elseif ($Alias -match "^lts/(.+)$") {
        $codename = $matches[1]
        $match = $candidates | Where-Object { $_.lts -and ($_.lts.ToString().ToLower() -eq $codename.ToLower()) } | Select-Object -First 1
    }

    if (-not $match) { return $null }
    return $match.version.TrimStart("v")
}

# --- Resolve a partial version (major, or major.minor) to the latest matching release ---
function Resolve-LatestNodeVersion {
    param([string]$Partial)

    $fileKey = "win-$($script:NodeArch)-zip"
    try {
        $json = Invoke-MvmRestMethod -Uri "https://nodejs.org/dist/index.json"
    }
    catch {
        Write-Host "Error: Could not reach nodejs.org to resolve version '$Partial': $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }

    $prefix = "v$Partial."
    $match = $json |
        Where-Object { $_.version.StartsWith($prefix) -and $_.files -contains $fileKey } |
        ForEach-Object {
            $clean = $_.version.Substring(1)
            if ([version]::TryParse($clean, [ref]$null)) {
                [PSCustomObject]@{ Version = $_.version; VerObj = [version]$clean }
            }
        } |
        Sort-Object VerObj -Descending |
        Select-Object -First 1

    if (-not $match) { return $null }
    return $match.Version.Substring(1)
}

# --- Highest *installed* version matching a prefix (major or major.minor), used by 'add' ---
function Get-HighestInstalledVersion {
    param([string]$Prefix, [string]$BasePath)

    if (-not (Test-Path $BasePath)) { return $null }

    $searchPrefix = "v$Prefix."
    Get-ChildItem $BasePath -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne "current" -and $_.Name.StartsWith($searchPrefix) } |
        ForEach-Object {
            $clean = $_.Name.Substring(1)
            if ([version]::TryParse($clean, [ref]$null)) {
                [PSCustomObject]@{ Folder = $_; VerObj = [version]$clean }
            }
        } |
        Sort-Object VerObj -Descending |
        Select-Object -First 1
}

# --- Find an installed version by prefix (handles both partial and exact full versions) ---
function Find-NodeVersion {
    param([string]$VersionPrefix, [string]$BasePath)

    $prefix = $VersionPrefix.TrimStart("v")

    $exactFolder = Join-Path $BasePath "v$prefix"
    if (Test-Path $exactFolder) {
        return [PSCustomObject]@{ Folder = (Get-Item $exactFolder); VerObj = [version]$prefix }
    }

    $pattern = "v$prefix."
    Get-ChildItem $BasePath -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne "current" -and $_.Name.StartsWith($pattern) } |
        ForEach-Object {
            $clean = $_.Name.Substring(1)
            if ([version]::TryParse($clean, [ref]$null)) {
                [PSCustomObject]@{ Folder = $_; VerObj = [version]$clean }
            }
        } |
        Sort-Object VerObj -Descending |
        Select-Object -First 1
}

# --- Checksum verification against Node's published SHASUMS256.txt ---
function Test-NodeChecksum {
    param([string]$CleanVersion, [string]$ZipPath, [string]$ArchSuffix)

    try {
        $sumsUrl = "https://nodejs.org/dist/v$CleanVersion/SHASUMS256.txt"
        $response = Invoke-MvmWebRequest -Uri $sumsUrl
        $content = $response.Content
    }
    catch {
        Write-Host "Warning: Could not fetch checksum file. Skipping verification." -ForegroundColor Yellow
        return $true
    }

    $fileName = "node-v$CleanVersion-win-$ArchSuffix.zip"
    $line = ($content -split "`r?`n") | Where-Object { $_ -match [regex]::Escape($fileName) } | Select-Object -First 1

    if (-not $line) {
        Write-Host "Warning: No checksum entry found for $fileName. Skipping verification." -ForegroundColor Yellow
        return $true
    }

    $expectedHash = ($line -split "\s+")[0].ToUpper()
    $actualHash = (Get-FileHash -Path $ZipPath -Algorithm SHA256).Hash.ToUpper()

    if ($expectedHash -ne $actualHash) {
        Write-Host "    Expected: $expectedHash" -ForegroundColor Gray
        Write-Host "    Actual:   $actualHash" -ForegroundColor Gray
        return $false
    }
    return $true
}

# --- Resolve the latest release tag via website redirect (no API, no rate limit) ---
function Get-LatestMvmTag {
    $url = "https://github.com/$ghOwner/$ghRepo/releases/latest"

    try {
        $request = [System.Net.HttpWebRequest]::Create($url)
        $request.Method = "HEAD"
        $request.AllowAutoRedirect = $false
        $request.Timeout = 5000
        if ($script:ProxyUrl) { $request.Proxy = New-Object System.Net.WebProxy($script:ProxyUrl) }

        $response = $request.GetResponse()
        $location = $response.Headers["Location"]
        $response.Close()
    }
    catch [System.Net.WebException] {
        if ($_.Exception.Response) {
            $location = $_.Exception.Response.Headers["Location"]
            $_.Exception.Response.Close()
        }
        else {
            return $null
        }
    }
    catch {
        return $null
    }

    if (-not $location) { return $null }
    if ($location -match "/releases/tag/(.+)$") { return $matches[1] }
    return $null
}

# --- Safely strip a leading 'v'/'V' and validate it parses as a real version ---
function Get-CleanMvmVersion {
    param([string]$RawTag)
    if (-not $RawTag) { return $null }
    $clean = $RawTag -replace "^[vV]", ""
    $parsed = $null
    if ([version]::TryParse($clean, [ref]$parsed)) {
        return $clean
    }
    return $null
}

function Test-MvmUpdateAvailable {
    try {
        $cached = $null
        if (Test-Path $cacheFile) {
            $cached = Get-Content $cacheFile -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
        }

        $needsRefresh = $true
        if ($cached -and $cached.lastChecked) {
            $lastChecked = [datetime]$cached.lastChecked
            if (((Get-Date) - $lastChecked) -lt (New-TimeSpan -Hours 24)) {
                $needsRefresh = $false
            }
        }

        $latest = if ($cached) { $cached.latestVersion } else { $null }

        if ($needsRefresh) {
            $tag = Get-LatestMvmTag
            if ($tag) {
                $cleanLatest = Get-CleanMvmVersion -RawTag $tag
                if ($cleanLatest) {
                    $latest = $cleanLatest
                    @{ lastChecked = (Get-Date).ToString("o"); latestVersion = $latest } |
                        ConvertTo-Json | Set-Content $cacheFile -ErrorAction SilentlyContinue
                }
            }
        }

        if ($latest -and ([version]$latest -gt [version]$MVM_VERSION)) {
            return $latest
        }
        return $null
    }
    catch {
        return $null
    }
}

# --- Core 'add' logic, extracted into a function so 'use' can auto-install too ---
function Invoke-AddCommand {
    param([string]$VersionSpec)

    $rawInput = $VersionSpec.TrimStart("v")
    $isAlias = $rawInput -match "^(lts/.*|node|stable)$"
    $isPartial = (-not $isAlias) -and (($rawInput -split "\.").Count -lt 3)

    if ($isAlias -or $isPartial) {
        Write-Host "Resolving version for '$rawInput'..." -ForegroundColor Cyan

        $resolved = if ($isAlias) { Resolve-NodeAlias -Alias $rawInput } else { Resolve-LatestNodeVersion -Partial $rawInput }

        if (-not $resolved) {
            Write-Host "No matching Node.js release found for '$rawInput'." -ForegroundColor Red
            return
        }

        Write-Host "Resolved: v$resolved" -ForegroundColor Green

        $checkPrefix = if ($isAlias) { ($resolved -split "\.")[0] } else { $rawInput }
        $installed = Get-HighestInstalledVersion -Prefix $checkPrefix -BasePath $base

        if ($installed) {
            $installedVer = $installed.VerObj
            $resolvedVer  = [version]$resolved

            if ($resolvedVer -eq $installedVer) {
                Write-Host "You already have the latest matching version: v$installedVer" -ForegroundColor Yellow
                return
            }
            elseif ($resolvedVer -gt $installedVer) {
                $answer = Read-Host "You have v$installedVer installed, but v$resolvedVer is available. Download it as well? (Y/N)"
                if ($answer -notmatch "^[Yy]") {
                    Write-Host "Skipped." -ForegroundColor Gray
                    return
                }
            }
        }

        $cleanVersion = $resolved
    }
    else {
        $cleanVersion = $rawInput
    }

    $folderName = "v$cleanVersion"
    $destFolder = Join-Path $base $folderName

    if (Test-Path $destFolder) { Write-Host "Version $folderName already added." -ForegroundColor Yellow; return }

    $archSuffix = $script:NodeArch
    $url = "https://nodejs.org/dist/v$cleanVersion/node-v$cleanVersion-win-$archSuffix.zip"
    $tempZip = Join-Path $env:TEMP "node-$cleanVersion-$archSuffix.zip"
    $extractTemp = Join-Path $env:TEMP "node_extract_$cleanVersion-$archSuffix"

    $webClient = $null
    $source = $null
    $targetFile = $null
    $zip = $null

    try {
        $request = [System.Net.WebRequest]::Create($url)
        if ($script:ProxyUrl) { $request.Proxy = New-Object System.Net.WebProxy($script:ProxyUrl) }
        $request.Method = "HEAD"
        $response = $request.GetResponse()
        $totalBytes = $response.ContentLength
        $response.Close()

        Write-Host "1/3 Downloading $folderName [$archSuffix] ([$( [Math]::Round($totalBytes / 1MB, 2) ) MB])" -ForegroundColor Cyan

        $webClient = New-MvmWebClient
        $source = $webClient.OpenRead($url)
        $targetFile = [System.IO.File]::Create($tempZip)
        $buffer = New-Object byte[] 65536
        $currentBytes = 0
        $lastPercent = -1

        while (($count = $source.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $targetFile.Write($buffer, 0, $count)
            $currentBytes += $count
            $percent = [int](($currentBytes / $totalBytes) * 100)

            if ($percent -ne $lastPercent) {
                $lastPercent = $percent
                $bar = ("#" * [int]($percent / 4)).PadRight(25, "-")
                Write-Host "`r    [$bar] $percent%" -NoNewline
            }
        }

        $source.Close(); $source.Dispose(); $source = $null
        $targetFile.Close(); $targetFile.Dispose(); $targetFile = $null
        $webClient.Dispose(); $webClient = $null

        Write-Host "`nDownload complete." -ForegroundColor Gray

        Write-Host "`n2/3 Verifying checksum..." -ForegroundColor Cyan
        $checksumOk = Test-NodeChecksum -CleanVersion $cleanVersion -ZipPath $tempZip -ArchSuffix $archSuffix
        if (-not $checksumOk) {
            Write-Host "Checksum verification FAILED. Aborting install (file may be corrupted or tampered)." -ForegroundColor Red
            return
        }
        Write-Host "Checksum OK." -ForegroundColor Green

        Write-Host "`n3/3 Extracting files to $folderName" -ForegroundColor Cyan

        Add-Type -AssemblyName System.IO.Compression.FileSystem

        $zip = [System.IO.Compression.ZipFile]::OpenRead($tempZip)
        $totalItems = $zip.Entries.Count
        $currentItem = 0
        $lastPercent = -1

        if (-not (Test-Path $extractTemp)) { New-Item -ItemType Directory -Path $extractTemp | Out-Null }

        foreach ($entry in $zip.Entries) {
            $currentItem++
            $targetPath = [System.IO.Path]::Combine($extractTemp, $entry.FullName)

            $dir = [System.IO.Path]::GetDirectoryName($targetPath)
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

            if (-not [string]::IsNullOrEmpty($entry.Name)) {
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $targetPath, $true)
            }

            $percent = [int](($currentItem / $totalItems) * 100)
            if ($percent -ne $lastPercent) {
                $lastPercent = $percent
                $bar = ("#" * [int]($percent / 4)).PadRight(25, "-")
                Write-Host "`r    [$bar] $percent% ($currentItem/$totalItems)" -NoNewline
            }
        }

        $zip.Dispose(); $zip = $null

        $innerFolder = Get-ChildItem $extractTemp -Directory | Select-Object -First 1
        if (-not (Test-Path $base)) { New-Item -ItemType Directory -Path $base -Force | Out-Null }

        if (Test-Path $destFolder) { cmd /c "rmdir /s /q `"$destFolder`"" 2>$null }
        Move-Item -Path $innerFolder.FullName -Destination $destFolder

        Write-Host "`n`nSuccessfully added $folderName [$archSuffix]" -ForegroundColor Green
    }
    catch {
        Write-Host "`nError: $($_.Exception.Message)" -ForegroundColor Red
    }
    finally {
        if ($source) { $source.Close(); $source.Dispose() }
        if ($targetFile) { $targetFile.Close(); $targetFile.Dispose() }
        if ($webClient) { $webClient.Dispose() }
        if ($zip) { $zip.Dispose() }

        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()

        if (Test-Path $tempZip) { Remove-Item $tempZip -Force -ErrorAction SilentlyContinue }
        if (Test-Path $extractTemp) { cmd /c "rmdir /s /q `"$extractTemp`"" 2>$null }
    }
}

# =========================================================
# ======================  TOP-LEVEL CHECKS  ================
# =========================================================

# --- mvm -v / mvm --version : print MVM's own version and exit immediately ---
if ($ShowVersionFlag -and -not $command) {
    Write-Host "MVM v$MVM_VERSION"
    return
}

# --- Move-Aware Warning ---
$currentEnvPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($currentEnvPath -notlike "*$binPath*" -and $command -notin @("setup", "install", "help", $null) -and !$Help) {
    Write-Host "WARNING: MVM is not in your PATH or was moved. Run 'mvm setup' to fix your paths." -ForegroundColor Yellow
}

# --- Self-update availability warning (skipped only for the 'update' command itself) ---
if ($command -ne "update") {
    $updateAvailable = Test-MvmUpdateAvailable
    if ($updateAvailable) {
        Write-Host "A new version of MVM is available: v$updateAvailable (current: v$MVM_VERSION). Run 'mvm update' to upgrade." -ForegroundColor Yellow
    }
}

# =========================================================
# =========================  COMMANDS  =====================
# =========================================================

# --- Help Logic ---
if ($Help -or $command -eq "help") {
    Write-Host "`nMini Version Manager (MVM) Help v$MVM_VERSION" -ForegroundColor Cyan
    Write-Host "-------------------------------"
    Write-Host "Usage:"
    Write-Host "  mvm list [-v|--verbose]  - List installed versions"
    Write-Host "                             (-v/--verbose also shows npm version and exact corepack status)"
    Write-Host "  mvm add VERSION          - Download and install a version"
    Write-Host "                             (full: 20.10.0 | partial: 20, 20.10 | alias: lts/*, lts/iron, node, stable)"
    Write-Host "  mvm use VERSION          - Switch to a version (e.g., 20, 18.20.5, lts/*)"
    Write-Host "                             Offers to auto-install if the version isn't installed yet"
    Write-Host "  mvm use                  - Switch using .mvmrc (preferred) or .nvmrc in current/parent directories"
    Write-Host "  mvm remove VERSION       - Uninstall a version"
    Write-Host "  mvm current              - Show the active version, its npm version, and corepack status"
    Write-Host "  mvm which [version]      - Show node.exe path (active version if omitted), npm version, and corepack status"
    Write-Host "  mvm ls-remote MAJOR      - List available remote releases for a major (e.g. 20) or major.minor (e.g. 20.10)"
    Write-Host "  mvm setup                - Add/repair MVM in your User PATH"
    Write-Host "  mvm update               - Self-update MVM to the latest released version"
    Write-Host "`nOptions:"
    Write-Host "  -h, --help, help           : Show this help menu"
    Write-Host "  -v, --version              : Show MVM's own version (when used with no command)"
    Write-Host "`nNotes:"
    Write-Host "  - 'use' auto-picks the latest installed minor/patch for a given major version."
    Write-Host "  - If the requested version isn't installed, 'use' will offer to install it automatically."
    Write-Host "  - 'add' resolves partial versions and aliases (lts/*, lts/<codename>, node, stable) against nodejs.org."
    Write-Host "  - Downloads are verified against Node's published SHA256 checksums before extraction."
    Write-Host "  - ARM64 Windows is auto-detected; the correct Node build (x64/arm64) is installed automatically."
    Write-Host "  - .mvmrc supports 'version=' and 'proxy=' lines (or a bare version, like .nvmrc)."
    Write-Host "    If present, .mvmrc's version takes priority over .nvmrc; if .mvmrc has no version, .nvmrc is used."
    Write-Host "  - .mvmrc and .nvmrc can coexist: e.g. share a team .nvmrc for version, and a personal,"
    Write-Host "    uncommitted .mvmrc containing only 'proxy=' for corporate network configuration."
    Write-Host "  - 'current', 'which', and 'list' report each version's bundled npm version and Corepack"
    Write-Host "    status (bundled/enabled), read directly from the install folder - no network calls."
    Write-Host "  - MVM checks for its own updates periodically (every 24h, cached) and will warn when"
    Write-Host "    'mvm update' is available. The check uses GitHub's release redirect, not the rate-limited API."
    return
}

# --- Command: Setup ---
if ($command -eq "setup" -or $command -eq "install") {
    Write-Host "Configuring MVM environment..." -ForegroundColor Cyan

    $userPath = (Get-ItemProperty -Path 'HKCU:\Environment' -Name Path -ErrorAction SilentlyContinue).Path
    if (-not $userPath) { $userPath = "" }

    $pathParts = $userPath.Split(";", [StringSplitOptions]::RemoveEmptyEntries)
    $cleanPath = $pathParts | Where-Object { $_ -notlike "*\mvm\bin" -and $_ -notlike "*\mvm\node\current" }
    $finalPath = @($binPath, $active) + $cleanPath -join ";"

    try {
        Set-ItemProperty -Path 'HKCU:\Environment' -Name Path -Value $finalPath -Type ExpandString
        $env:Path = $finalPath

        if (-not (Test-Path $base)) { New-Item -ItemType Directory -Path $base | Out-Null }

        Write-Host "Success! Added to PATH:" -ForegroundColor Green
        Write-Host "  $binPath"
        Write-Host "  $active"
        Write-Host "`nYou can now use 'mvm' and 'node' from any window." -ForegroundColor Cyan
    }
    catch {
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    }
    return
}

# --- Command: List ---
if ($command -eq "list") {
    if (-not (Test-Path $base)) {
        Write-Host "Node base directory not found."
        return
    }

    $currentRealPath = ""
    if (Test-Path $active) { $currentRealPath = (Get-Item $active).Target }

    $installed = Get-ChildItem $base -Directory | Where-Object { $_.Name -ne "current" }

    if (-not $installed) {
        Write-Host "No versions installed yet. Run 'mvm add VERSION' to get started." -ForegroundColor Yellow
        return
    }

    if ($ListVerboseFlag) {
        Write-Host "(verbose mode: querying npm and exact corepack versions, this may take a moment)`n" -ForegroundColor Gray
    }

    foreach ($folder in $installed) {
        if (-not $ListVerboseFlag) {
            # Fast path: just the folder name, no filesystem/npm/corepack inspection at all.
            if ($folder.FullName -eq $currentRealPath) {
                Write-Host "$($folder.Name) <- Active" -ForegroundColor Green
            }
            else {
                Write-Host $folder.Name
            }
            continue
        }

        # Verbose path: full npm version + corepack status (spawns corepack.cmd per version).
        $bundle = Get-NodeBundleInfo -NodeFolderPath $folder.FullName -IncludeCorepackVersion

        $npmTag = if ($bundle.NpmVersion) { "npm v$($bundle.NpmVersion)" } else { "npm ?" }

        $corepackTag = if (-not $bundle.HasCorepack) {
            "corepack: n/a"
        }
        elseif ($bundle.CorepackActive) {
            if ($bundle.CorepackVersion) { "corepack: v$($bundle.CorepackVersion) (enabled)" } else { "corepack: enabled" }
        }
        else {
            if ($bundle.CorepackVersion) { "corepack: v$($bundle.CorepackVersion) (available)" } else { "corepack: available" }
        }

        $line = "$($folder.Name)  [$npmTag, $corepackTag]"

        if ($folder.FullName -eq $currentRealPath) {
            Write-Host "$line <- Active" -ForegroundColor Green
        }
        else {
            Write-Host $line
        }
    }
    return
}

# --- Command: Current ---
if ($command -eq "current") {
    if (-not (Test-Path $active)) {
        Write-Host "No active version set. Run 'mvm use VERSION' first." -ForegroundColor Yellow
        return
    }
    $realPath = (Get-Item $active).Target
    $versionName = Split-Path $realPath -Leaf

    $bundle = Get-NodeBundleInfo -NodeFolderPath $realPath -IncludeCorepackVersion

    $npmTag = if ($bundle.NpmVersion) { "npm v$($bundle.NpmVersion)" } else { "npm version unknown" }

    $corepackTag = if (-not $bundle.HasCorepack) {
        "corepack not bundled in this version"
    }
    elseif ($bundle.CorepackActive) {
        "corepack v$($bundle.CorepackVersion) (enabled)"
    }
    else {
        "corepack v$($bundle.CorepackVersion) (available, not enabled - run 'corepack enable')"
    }

    Write-Host "$versionName" -ForegroundColor Green
    Write-Host "  $npmTag"
    Write-Host "  $corepackTag"
    return
}

# --- Command: Which ---
if ($command -eq "which") {
    $targetFolder = $null

    if (-not $version) {
        if (-not (Test-Path $active)) {
            Write-Host "No active version set. Run 'mvm use VERSION' first." -ForegroundColor Yellow
            return
        }
        $realPath = (Get-Item $active).Target
        $targetFolder = Get-Item $realPath
    }
    else {
        $match = Find-NodeVersion -VersionPrefix $version -BasePath $base
        if (-not $match) {
            Write-Host "No installed version matching '$version'." -ForegroundColor Red
            return
        }
        $targetFolder = $match.Folder
    }

    $nodeExe = Join-Path $targetFolder.FullName "node.exe"
    if (-not (Test-Path $nodeExe)) {
        Write-Host "Warning: node.exe not found in $($targetFolder.FullName)" -ForegroundColor Yellow
    }

    $bundle = Get-NodeBundleInfo -NodeFolderPath $targetFolder.FullName -IncludeCorepackVersion

    $npmTag = if ($bundle.NpmVersion) { "npm v$($bundle.NpmVersion)" } else { "npm version unknown" }
    $corepackTag = if (-not $bundle.HasCorepack) {
        "corepack not bundled in this version"
    }
    elseif ($bundle.CorepackActive) {
        "corepack v$($bundle.CorepackVersion) (enabled)"
    }
    else {
        "corepack v$($bundle.CorepackVersion) (available, not enabled)"
    }

    Write-Host $nodeExe -ForegroundColor Green
    Write-Host "  $npmTag"
    Write-Host "  $corepackTag"
    return
}

# --- Command: ls-remote ---
if ($command -eq "ls-remote") {
    if (-not $version) {
        Write-Host "Usage: mvm ls-remote MAJOR (e.g. 20) or MAJOR.MINOR (e.g. 20.10)" -ForegroundColor Yellow
        return
    }

    $clean = $version.TrimStart("v")
    if ($clean -notmatch "^\d+(\.\d+)?$") {
        Write-Host "ls-remote requires at least a major version number (e.g. 'mvm ls-remote 20')." -ForegroundColor Yellow
        return
    }

    $fileKey = "win-$($script:NodeArch)-zip"
    try {
        $json = Invoke-MvmRestMethod -Uri "https://nodejs.org/dist/index.json"
    }
    catch {
        Write-Host "Error: Could not reach nodejs.org: $($_.Exception.Message)" -ForegroundColor Red
        return
    }

    $prefix = "v$clean."
    $results = $json |
        Where-Object { $_.version.StartsWith($prefix) -and $_.files -contains $fileKey } |
        ForEach-Object {
            $cleanV = $_.version.Substring(1)
            if ([version]::TryParse($cleanV, [ref]$null)) {
                [PSCustomObject]@{ Version = $_.version; VerObj = [version]$cleanV; LTS = $_.lts }
            }
        } |
        Sort-Object VerObj -Descending

    if (-not $results) {
        Write-Host "No remote releases found matching '$clean' for architecture $($script:NodeArch)." -ForegroundColor Yellow
        return
    }

    foreach ($r in $results) {
        $ltsTag = if ($r.LTS -and $r.LTS -ne $false) { " (LTS: $($r.LTS))" } else { "" }
        Write-Host "$($r.Version)$ltsTag"
    }
    return
}

# --- Command: Add ---
if ($command -eq "add") {
    if (-not $version) { Write-Host "Usage: mvm add VERSION" -ForegroundColor Yellow; return }
    Invoke-AddCommand -VersionSpec $version
    return
}

# --- Command: Remove ---
if ($command -eq "remove") {
    if (-not $version) { Write-Host "Usage: mvm remove FULL_VERSION" -ForegroundColor Yellow; return }

    $folderName = if ($version.StartsWith("v")) { $version } else { "v$version" }
    $targetPath = Join-Path $base $folderName

    if (-not (Test-Path $targetPath)) {
        Write-Host "Version $folderName not found." -ForegroundColor Red
        return
    }

    if (Test-Path $active) {
        $currentRealPath = (Get-Item $active).Target
        if ($targetPath -eq $currentRealPath) {
            Write-Host "Cannot remove $($folderName): It is currently active." -ForegroundColor Red
            return
        }
    }

    try {
        Write-Host "Removing Node ${folderName}... " -NoNewline -ForegroundColor Cyan
        cmd /c "rmdir /s /q `"$targetPath`"" 2>$null
        Write-Host "Done!" -ForegroundColor Green
    }
    catch {
        Write-Host "`nError: $($_.Exception.Message)" -ForegroundColor Red
    }
    return
}

# --- Command: Use ---
if ($command -eq "use") {

    if (-not $version) {
        $projectVersion = Get-ProjectVersion
        if (-not $projectVersion) {
            Write-Host "Usage: mvm use VERSION" -ForegroundColor Yellow
            Write-Host "(No .mvmrc or .nvmrc file found in current or parent directories.)" -ForegroundColor Gray
            return
        }
        $version = $projectVersion
        Write-Host "Using project version: $version" -ForegroundColor Cyan
    }

    if ($version -match "^(lts/.*|node|stable)$") {
        Write-Host "Resolving alias '$version'..." -ForegroundColor Cyan
        $resolvedAlias = Resolve-NodeAlias -Alias $version
        if (-not $resolvedAlias) {
            Write-Host "Could not resolve alias '$version'." -ForegroundColor Red
            return
        }
        Write-Host "Alias '$version' resolved to v$resolvedAlias" -ForegroundColor Green
        $version = $resolvedAlias
    }

    $target = Find-NodeVersion -VersionPrefix $version -BasePath $base

    if (-not $target) {
        Write-Host "No version matching '$version' found locally." -ForegroundColor Yellow
        $answer = Read-Host "Download and install it now via 'mvm add'? (Y/N)"
        if ($answer -match "^[Yy]") {
            Invoke-AddCommand -VersionSpec $version
            $target = Find-NodeVersion -VersionPrefix $version -BasePath $base
            if (-not $target) {
                Write-Host "Installation failed or the version still could not be found." -ForegroundColor Red
                return
            }
        }
        else {
            Write-Host "Aborted. Run 'mvm add $version' manually when ready." -ForegroundColor Gray
            return
        }
    }

    $targetFolder = $target.Folder

    if (Test-Path $active) {
        cmd /c "rmdir `"$active`"" 2>$null
    }

    cmd /c "mklink /J `"$active`" `"$($targetFolder.FullName)`"" >$null

    Write-Host "Switched to $($targetFolder.Name)" -ForegroundColor Green
    return
}

# --- Command: Update (self-update) ---
if ($command -eq "update") {
    Write-Host "Checking for updates..." -ForegroundColor Cyan

    $tag = Get-LatestMvmTag
    if (-not $tag) {
        Write-Host "Error: Could not determine the latest release (network issue or GitHub unreachable)." -ForegroundColor Red
        return
    }

    $latestVersion = Get-CleanMvmVersion -RawTag $tag
    if (-not $latestVersion) {
        Write-Host "Error: Latest release tag '$tag' is not a valid version string. Aborting update." -ForegroundColor Red
        return
    }

    if ([version]$latestVersion -le [version]$MVM_VERSION) {
        Write-Host "You already have the latest version (v$MVM_VERSION)." -ForegroundColor Green
        return
    }

    Write-Host "Updating MVM: v$MVM_VERSION -> v$latestVersion" -ForegroundColor Cyan

    $downloadUrl = "https://github.com/$ghOwner/$ghRepo/releases/download/$tag/mvm.zip"

    $tempZip = Join-Path $env:TEMP "mvm-update-$latestVersion.zip"
    $extractTemp = Join-Path $env:TEMP "mvm-update-extract-$latestVersion"

    try {
        $wc = New-MvmWebClient
        $wc.DownloadFile($downloadUrl, $tempZip)
        $wc.Dispose()

        if (Test-Path $extractTemp) { cmd /c "rmdir /s /q `"$extractTemp`"" 2>$null }
        New-Item -ItemType Directory -Path $extractTemp | Out-Null

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($tempZip, $extractTemp)

        $sourceRoot = $extractTemp
        $innerMvm = Get-ChildItem $extractTemp -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path (Join-Path $_.FullName "mvm.ps1") } | Select-Object -First 1
        if ($innerMvm) { $sourceRoot = $innerMvm.FullName }

        $newPs1 = Join-Path $sourceRoot "mvm.ps1"
        $newCmd = Join-Path $sourceRoot "bin\mvm.cmd"

        if (-not (Test-Path $newPs1)) {
            Write-Host "Error: Downloaded package does not contain mvm.ps1." -ForegroundColor Red
            return
        }

        Copy-Item -Path $newPs1 -Destination (Join-Path $mvmRoot "mvm.ps1") -Force
        if (Test-Path $newCmd) {
            Copy-Item -Path $newCmd -Destination (Join-Path $binPath "mvm.cmd") -Force
        }

        @{ lastChecked = (Get-Date).ToString("o"); latestVersion = $latestVersion } |
            ConvertTo-Json | Set-Content $cacheFile -ErrorAction SilentlyContinue

        Write-Host "Successfully updated to v$latestVersion!" -ForegroundColor Green
        Write-Host "Your next 'mvm' command will use the new version." -ForegroundColor Gray
    }
    catch {
        Write-Host "Error during update: $($_.Exception.Message)" -ForegroundColor Red
    }
    finally {
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
        if (Test-Path $tempZip) { Remove-Item $tempZip -Force -ErrorAction SilentlyContinue }
        if (Test-Path $extractTemp) { cmd /c "rmdir /s /q `"$extractTemp`"" 2>$null }
    }
    return
}

Write-Host "Usage: mvm <list|add|use|remove|current|which|ls-remote|setup|update> [version]" -ForegroundColor Yellow
Write-Host "Type 'mvm help' or 'mvm -h' for detailed usage, or 'mvm -v' for MVM's version." -ForegroundColor Gray
