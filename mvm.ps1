param (
    [Alias("h")]
    [switch]$Help, # Handles -h and -Help
    [string]$command,
    [string]$version
)

# --- Dynamic Path Logic ---
$mvmRoot = $PSScriptRoot
$binPath = Join-Path $mvmRoot "bin"

# --- Move-Aware Warning ---
$currentEnvPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($currentEnvPath -notlike "*$binPath*" -and $command -notin @("setup", "install", "help", $null) -and !$Help) {
    Write-Host "WARNING: MVM is not in your PATH or was moved. Run 'mvm setup' to fix your paths." -ForegroundColor Yellow
}

# --- Node Path Logic ---
$base = Join-Path $mvmRoot "node"
$active = Join-Path $base "current"
$pathEntry = $active

# --- NVMRC: Helper to locate and parse a .nvmrc file ---
function Get-NvmrcVersion {
    # Walks upward from the current directory looking for a .nvmrc file,
    # mimicking the behavior of nvm/nvm-windows.
    $dir = Get-Location
    while ($true) {
        $candidate = Join-Path $dir ".nvmrc"
        if (Test-Path $candidate) {
            $raw = (Get-Content $candidate -Raw -ErrorAction SilentlyContinue).Trim()
            if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
            return $raw
        }

        $parent = Split-Path $dir -Parent
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }
    return $null
}

# --- Resolve a partial version (major, or major.minor) to the latest matching release ---
function Resolve-LatestNodeVersion {
    param([string]$Partial)

    try {
        $indexUrl = "https://nodejs.org/dist/index.json"
        $json = Invoke-RestMethod -Uri $indexUrl -UseBasicParsing
    }
    catch {
        Write-Host "Error: Could not reach nodejs.org to resolve version '$Partial': $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }

    $prefix = "v$Partial."
    $match = $json |
        Where-Object { $_.version.StartsWith($prefix) -and $_.files -contains "win-x64-zip" } |
        ForEach-Object {
            $clean = $_.version.Substring(1)
            if ([version]::TryParse($clean, [ref]$null)) {
                [PSCustomObject]@{
                    Version = $_.version
                    VerObj  = [version]$clean
                }
            }
        } |
        Sort-Object VerObj -Descending |
        Select-Object -First 1

    if (-not $match) { return $null }
    return $match.Version.Substring(1)  # return without leading 'v'
}

# --- Find the highest *installed* version matching a prefix (major or major.minor) ---
function Get-HighestInstalledVersion {
    param([string]$Prefix, [string]$BasePath)

    if (-not (Test-Path $BasePath)) { return $null }

    $searchPrefix = "v$Prefix."
    Get-ChildItem $BasePath -Directory |
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

# --- Help Logic ---
if ($Help -or $command -eq "help") {
    Write-Host "`nMini Version Manager (MVM) Help" -ForegroundColor Cyan
    Write-Host "-------------------------------"
    Write-Host "Usage:"
    Write-Host "  mvm list              - List installed versions"
    Write-Host "  mvm add <version>     - Download and install a version"
    Write-Host "                          (e.g., 20.10.0, or partial: 20, 20.10)"
    Write-Host "  mvm use <version>     - Switch to a version (e.g., 20, 18.20.5)"
    Write-Host "  mvm use               - Switch to the version specified in a .nvmrc file"
    Write-Host "  mvm remove <version>  - Uninstall a version"
    Write-Host "  mvm setup             - Add/repair MVM in your User PATH"
    Write-Host "`nOptions:"
    Write-Host "  -h, --help, help        : Show this help menu"
    Write-Host "`nNotes:"
    Write-Host "  - 'use' will automatically pick the latest installed minor/patch for the major version provided."
    Write-Host "  - 'mvm use' with no argument will search for a .nvmrc file in the current or parent directories."
    Write-Host "  - 'add' accepts partial versions (major, e.g. 20, or major.minor, e.g. 20.10) and will"
    Write-Host "    resolve the latest matching release from nodejs.org automatically."
    Write-Host "  - If a newer version is found for an already-installed major/minor line, 'add' will"
    Write-Host "    prompt before downloading it."
    return
}

# --- Command: Setup ---
if ($command -eq "setup" -or $command -eq "install") {
    Write-Host "Configuring MVM environment..." -ForegroundColor Cyan
    
    # Read raw string from HKCU Registry directly to avoid blocking system calls
    $userPath = (Get-ItemProperty -Path 'HKCU:\Environment' -Name Path -ErrorAction SilentlyContinue).Path
    if (-not $userPath) { $userPath = "" }
    
    $pathParts = $userPath.Split(";", [StringSplitOptions]::RemoveEmptyEntries)

    # Filter out any old MVM paths, then prepend new ones
    $cleanPath = $pathParts | Where-Object { $_ -notlike "*\mvm\bin" -and $_ -notlike "*\mvm\node\current" }
    $finalPath = @($binPath, $active) + $cleanPath -join ";"

    try {
        # Set-ItemProperty updates registry directly WITHOUT triggering blocking WM_SETTINGCHANGE broadcasts
        Set-ItemProperty -Path 'HKCU:\Environment' -Name Path -Value $finalPath -Type ExpandString

        # Update current session PATH immediately
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
    if (Test-Path $active) {
        $currentRealPath = (Get-Item $active).Target
    }

    Get-ChildItem $base -Directory | Where-Object { $_.Name -ne "current" } | ForEach-Object {
        if ($_.FullName -eq $currentRealPath) {
            Write-Host "$($_.Name) <- Active" -ForegroundColor Green
        }
        else {
            Write-Host $_.Name
        }
    }
    return
}

# --- Command: Add ---
if ($command -eq "add") {
    if (-not $version) { Write-Host "Usage: mvm add <version>" -ForegroundColor Yellow; return }

    $inputVersion = $version.TrimStart("v")
    $partsCount = ($inputVersion -split "\.").Count

    if ($partsCount -lt 3) {
        # Partial version (major, or major.minor) -> resolve against nodejs.org
        Write-Host "Resolving latest release for '$inputVersion'..." -ForegroundColor Cyan
        $resolved = Resolve-LatestNodeVersion -Partial $inputVersion

        if (-not $resolved) {
            Write-Host "No matching Node.js release found for '$inputVersion'." -ForegroundColor Red
            return
        }

        Write-Host "Latest match: v$resolved" -ForegroundColor Green

        # Check what's already installed for this major/minor line
        $installed = Get-HighestInstalledVersion -Prefix $inputVersion -BasePath $base

        if ($installed) {
            $installedVer = $installed.VerObj
            $resolvedVer  = [version]$resolved

            if ($resolvedVer -eq $installedVer) {
                Write-Host "You already have the latest version for '$inputVersion': v$installedVer" -ForegroundColor Yellow
                return
            }
            elseif ($resolvedVer -gt $installedVer) {
                $answer = Read-Host "You have v$installedVer installed, but v$resolvedVer is available. Download it as well? (Y/N)"
                if ($answer -notmatch "^[Yy]") {
                    Write-Host "Skipped." -ForegroundColor Gray
                    return
                }
            }
            # if resolvedVer < installedVer (unlikely), just proceed silently
        }

        $cleanVersion = $resolved
    }
    else {
        # Full version given explicitly, e.g. 16.20.2 -> use as-is
        $cleanVersion = $inputVersion
    }

    $folderName = "v$cleanVersion"
    $destFolder = Join-Path $base $folderName

    if (Test-Path $destFolder) { Write-Host "Version $folderName already added." -ForegroundColor Yellow; return }

    $url = "https://nodejs.org/dist/v$cleanVersion/node-v$cleanVersion-win-x64.zip"
    $tempZip = Join-Path $env:TEMP "node-$cleanVersion.zip"
    $extractTemp = Join-Path $env:TEMP "node_extract_$cleanVersion"

    $webClient = $null
    $source = $null
    $targetFile = $null
    $zip = $null

    try {
        # 1. DOWNLOAD PHASE
        $request = [System.Net.WebRequest]::Create($url)
        $request.Method = "HEAD"
        $response = $request.GetResponse()
        $totalBytes = $response.ContentLength
        $response.Close()
        
        Write-Host "1/2 Downloading $folderName ([$( [Math]::Round($totalBytes / 1MB, 2) ) MB])" -ForegroundColor Cyan
        
        $webClient = New-Object System.Net.WebClient
        $source = $webClient.OpenRead($url)
        $targetFile = [System.IO.File]::Create($tempZip)
        $buffer = New-Object byte[] 65536
        $currentBytes = 0
        $lastPercent = -1
        
        while (($count = $source.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $targetFile.Write($buffer, 0, $count)
            $currentBytes += $count
            $percent = [int](($currentBytes / $totalBytes) * 100)
            
            # Throttle console updates to prevent screen-buffer lockups
            if ($percent -ne $lastPercent) {
                $lastPercent = $percent
                $bar = ("#" * [int]($percent / 4)).PadRight(25, "-")
                Write-Host "`r    [$bar] $percent%" -NoNewline
            }
        }
        
        # Explicitly close handles before starting extraction
        $source.Close(); $source.Dispose(); $source = $null
        $targetFile.Close(); $targetFile.Dispose(); $targetFile = $null
        $webClient.Dispose(); $webClient = $null
        
        Write-Host "`nDownload complete." -ForegroundColor Gray

        # 2. UNZIP PHASE
        Write-Host "`n2/2 Extracting files to $folderName" -ForegroundColor Cyan
        
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

            # Throttle console updates to percentage changes only
            $percent = [int](($currentItem / $totalItems) * 100)
            if ($percent -ne $lastPercent) {
                $lastPercent = $percent
                $bar = ("#" * [int]($percent / 4)).PadRight(25, "-")
                Write-Host "`r    [$bar] $percent% ($currentItem/$totalItems)" -NoNewline
            }
        }
        
        # Free zip resources immediately after extraction loop
        $zip.Dispose(); $zip = $null

        $innerFolder = Get-ChildItem $extractTemp -Directory | Select-Object -First 1
        if (-not (Test-Path $base)) { New-Item -ItemType Directory -Path $base -Force | Out-Null }
        
        if (Test-Path $destFolder) { cmd /c "rmdir /s /q `"$destFolder`"" 2>$null }
        Move-Item -Path $innerFolder.FullName -Destination $destFolder
        
        Write-Host "`n`nSuccessfully added $folderName" -ForegroundColor Green
    }
    catch {
        Write-Host "`nError: $($_.Exception.Message)" -ForegroundColor Red
    }
    finally {
        # Safe stream cleanup
        if ($source) { $source.Close(); $source.Dispose() }
        if ($targetFile) { $targetFile.Close(); $targetFile.Dispose() }
        if ($webClient) { $webClient.Dispose() }
        if ($zip) { $zip.Dispose() }

        # Force garbage collection to ensure .NET releases file locks on $tempZip
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()

        # Non-blocking file & directory cleanup
        if (Test-Path $tempZip) { 
            Remove-Item $tempZip -Force -ErrorAction SilentlyContinue 
        }
        if (Test-Path $extractTemp) { 
            cmd /c "rmdir /s /q `"$extractTemp`"" 2>$null 
        }
    }
    return
}

# --- Command: Remove ---
if ($command -eq "remove") {
    if (-not $version) { Write-Host "Usage: mvm remove <full_version>" -ForegroundColor Yellow; return }

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
        
        # Fast non-blocking directory deletion
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

    # --- NVMRC: if no version was passed explicitly, try to read it from .nvmrc ---
    if (-not $version) {
        $nvmrcVersion = Get-NvmrcVersion
        if (-not $nvmrcVersion) {
            Write-Host "Usage: mvm use <version>" -ForegroundColor Yellow
            Write-Host "(No .nvmrc file found in current or parent directories.)" -ForegroundColor Gray
            return
        }

        # Guard against unsupported aliases like "lts/*" or "node" since
        # resolving these requires an external lookup of Node's release schedule.
        if ($nvmrcVersion -match "^(lts/|node$|stable$|iojs$)") {
            Write-Host "Found .nvmrc with alias '$nvmrcVersion', but MVM does not support aliases (lts/*, node, stable)." -ForegroundColor Yellow
            Write-Host "Please specify an explicit version number inside .nvmrc instead." -ForegroundColor Yellow
            return
        }

        $version = $nvmrcVersion
        Write-Host "Using version from .nvmrc: $version" -ForegroundColor Cyan
    }

    $searchPrefix = if ($version.StartsWith("v")) { $version } else { "v$version" }

    $target = Get-ChildItem $base -Directory | 
        Where-Object { $_.Name -like "$searchPrefix*" } |
        ForEach-Object {
            $cleanName = $_.Name.Substring(1)
            if ([version]::TryParse($cleanName, [ref]$null)) {
                [PSCustomObject]@{
                    Folder = $_
                    VerObj = [version]$cleanName
                }
            }
        } | 
        Sort-Object VerObj -Descending | 
        Select-Object -First 1

    if (-not $target) {
        Write-Host "No version matching '$version' found in $base" -ForegroundColor Red
        Write-Host "Run 'mvm add $version' to install it first." -ForegroundColor Gray
        return
    }

    $targetFolder = $target.Folder

    # Safely remove existing junction target without touching destination contents
    if (Test-Path $active) {
        cmd /c "rmdir `"$active`"" 2>$null
    }
    
    # Create the junction
    cmd /c "mklink /J `"$active`" `"$($targetFolder.FullName)`"" >$null

    Write-Host "Switched to $($targetFolder.Name)" -ForegroundColor Green
    return
}

Write-Host "Usage: mvm <list|add|use|remove> [version]" -ForegroundColor Yellow
Write-Host "Type 'mvm help' or 'mvm -h' for detailed usage." -ForegroundColor Gray
