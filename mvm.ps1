param (
	[Alias("h")]
    [switch]$Help, # Handles -h and -Help
    [string]$command,
    [string]$version
)

# --- Dynamic Path Logic ---
# $PSScriptRoot is '.../mvm' (where mvm.ps1 lives)
$mvmRoot = $PSScriptRoot
# $binPath is '.../mvm/bin' (where mvm.cmd lives)
$binPath = Join-Path $mvmRoot "bin"

# --- Move-Aware Warning ---
$currentEnvPath = [Environment]::GetEnvironmentVariable("Path", "User")
# We check against $binPath because that's what needs to be in the PATH for 'mvm' to work
if ($currentEnvPath -notlike "*$binPath*" -and $command -notin @("setup", "install", "help", $null) -and !$Help) {
    Write-Host "WARNING: MVM is not in your PATH or was moved. Run 'mvm setup' to fix your paths." -ForegroundColor Yellow
}

# --- Node Path Logic ---
$base = Join-Path $mvmRoot "node"
$active = Join-Path $base "current"
$pathEntry = $active

# --- Help Logic ---
# Triggers if -h, -Help is used, OR if the first argument is "help"
if ($Help -or $command -eq "help") {
    Write-Host "`nMini Version Manager (MVM) Help" -ForegroundColor Cyan
    Write-Host "-------------------------------"
    Write-Host "Usage:"
    Write-Host "  mvm list              - List installed versions"
    Write-Host "  mvm add <version>     - Download and install a version (e.g., 20.10.0)"
    Write-Host "  mvm use <version>     - Switch to a version (e.g., 20, 18.20.5)"
    Write-Host "  mvm remove <version>  - Uninstall a version"
	Write-Host "`nOptions:"
    Write-Host "  -h, --help, help        : Show this help menu"
    Write-Host "`nNote: 'use' will automatically pick the latest installed minor/patch for the major version provided."
    return
}

# --- Command: Setup ---
if ($command -eq "setup" -or $command -eq "install") {
    Write-Host "Configuring MVM environment..." -ForegroundColor Cyan
    
    # Get current User PATH
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $pathParts = $userPath.Split(";", [StringSplitOptions]::RemoveEmptyEntries)

    # Filter out any old MVM paths to prevent clutter, then add the new ones
    $cleanPath = $pathParts | Where-Object { $_ -notlike "*\mvm\bin" -and $_ -notlike "*\mvm\node\current" }
    $finalPath = @($binPath, $active) + $cleanPath -join ";"

    try {
        # 1. Update Registry (Permanent)
        [Environment]::SetEnvironmentVariable("Path", $finalPath, "User")
        # 2. Update Current Session (Immediate)
        $env:Path = $finalPath
        
        # Create the node folder if it doesn't exist
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

    # Get the physical path 'current' points to (if it exists)
    $currentRealPath = ""
    if (Test-Path $active) {
        $currentRealPath = (Get-Item $active).Target
    }

    Get-ChildItem $base -Directory | Where-Object { $_.Name -ne "current" } | ForEach-Object {
        # Check if this directory is the one linked to 'current'
        if ($_.FullName -eq $currentRealPath) {
            # Paint the active line green
            Write-Host "$($_.Name) <- Active" -ForegroundColor Green
        }
        else {
            # Standard output for inactive versions
            Write-Host $_.Name
        }
    }
    return
}

# --- Command: Add ---
if ($command -eq "add") {
    if (-not $version) { Write-Host "Usage: mvm add <full_version>" -ForegroundColor Yellow; return }
    
    $folderName = if ($version.StartsWith("v")) { $version } else { "v$version" }
    $cleanVersion = $folderName.Substring(1)
    $destFolder = Join-Path $base $folderName
    
    if (Test-Path $destFolder) { Write-Host "Version $folderName already added." -ForegroundColor Yellow; return }

    $url = "https://nodejs.org/dist/v$cleanVersion/node-v$cleanVersion-win-x64.zip"
    $tempZip = Join-Path $env:TEMP "node-$cleanVersion.zip"
    $extractTemp = Join-Path $env:TEMP "node_extract_$cleanVersion"

    try {
        $webClient = New-Object System.Net.WebClient
        
        # 1. DOWNLOAD PHASE
        $request = [System.Net.WebRequest]::Create($url)
        $request.Method = "HEAD"
        $response = $request.GetResponse()
        $totalBytes = $response.ContentLength
        $response.Close()
        
        Write-Host "1/2 Downloading $folderName ([$( [Math]::Round($totalBytes / 1MB, 2) ) MB])" -ForegroundColor Cyan
        $source = $webClient.OpenRead($url)
        $targetFile = [System.IO.File]::Create($tempZip)
        $buffer = New-Object byte[] 65536
        $currentBytes = 0
        
        while (($count = $source.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $targetFile.Write($buffer, 0, $count)
            $currentBytes += $count
            $percent = [int](($currentBytes / $totalBytes) * 100)
            $bar = ("#" * [int]($percent / 4)).PadRight(25, "-")
            Write-Host "`r    [$bar] $percent%" -NoNewline
        }
        $source.Close(); $targetFile.Close()
        Write-Host "`nDownload complete." -ForegroundColor Gray

        # 2. UNZIP PHASE (Strictly Console)
        Write-Host "`n2/2 Extracting files to $folderName" -ForegroundColor Cyan
        
        # Load the necessary .NET assembly
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        
        $zip = [System.IO.Compression.ZipFile]::OpenRead($tempZip)
        $totalItems = $zip.Entries.Count
        $currentItem = 0

        if (-not (Test-Path $extractTemp)) { New-Item -ItemType Directory -Path $extractTemp | Out-Null }

        foreach ($entry in $zip.Entries) {
            $currentItem++
            
            # Construct the destination path for the entry
            $targetPath = [System.IO.Path]::Combine($extractTemp, $entry.FullName)
            
            # Create subdirectories if the entry is a folder or in a subfolder
            $dir = [System.IO.Path]::GetDirectoryName($targetPath)
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

            # Extract the file (ignoring empty directory entries)
            if (-not [string]::IsNullOrEmpty($entry.Name)) {
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $targetPath, $true)
            }

            # Update the Console Bar
            $percent = [int](($currentItem / $totalItems) * 100)
            $bar = ("#" * [int]($percent / 4)).PadRight(25, "-")
            Write-Host "`r    [$bar] $percent% ($currentItem/$totalItems)" -NoNewline
        }
        $zip.Dispose()

        # Finalize naming convention (Same as before)
        $innerFolder = Get-ChildItem $extractTemp -Directory | Select-Object -First 1
        if (-not (Test-Path $base)) { New-Item -ItemType Directory -Path $base -Force | Out-Null }
        
        # Check if version folder already exists before moving (cleanup)
        if (Test-Path $destFolder) { Remove-Item $destFolder -Recurse -Force }
        Move-Item -Path $innerFolder.FullName -Destination $destFolder
        
        Write-Host "`n`nSuccessfully added $folderName" -ForegroundColor Green
    }
    catch {
        Write-Host "`nError: $($_.Exception.Message)" -ForegroundColor Red
    }
    finally {
        if ($source) { $source.Dispose() }
        if ($targetFile) { $targetFile.Dispose() }
        if (Test-Path $tempZip) { Remove-Item $tempZip -ErrorAction SilentlyContinue }
        if (Test-Path $extractTemp) { Remove-Item $extractTemp -Recurse -Force -ErrorAction SilentlyContinue }
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
        # Using ${folderName} to prevent the "Variable Drive" parser error
        Write-Host "Removing Node ${folderName}... " -NoNewline -ForegroundColor Cyan
        
        # Standard deletion is much faster than a per-file loop progress bar
        Remove-Item -Path $targetPath -Recurse -Force
        
        Write-Host "Done!" -ForegroundColor Green
    }
    catch {
        Write-Host "`nError: $($_.Exception.Message)" -ForegroundColor Red
    }
    return
}

# --- Command: Use ---
if ($command -eq "use") {
    if (-not $version) { Write-Host "Usage: mvm use <version>" -ForegroundColor Yellow; return }

    # Ensure search string starts with 'v'
    $searchPrefix = if ($version.StartsWith("v")) { $version } else { "v$version" }

    # 1. Get all folders that start with your input (e.g., 'v16')
    # 2. Filter to ensure we only get folders matching the version pattern
    # 3. Sort them using the [version] type to handle semantic versioning correctly
    $target = Get-ChildItem $base -Directory | 
        Where-Object { $_.Name -like "$searchPrefix*" } |
        ForEach-Object {
            # Create a custom object that holds the folder and a sortable version
            $cleanName = $_.Name.Substring(1) # Remove the 'v'
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
        return
    }

    $targetFolder = $target.Folder

    # Update the 'current' junction
    if (Test-Path $active) {
        cmd /c "rmdir `"$active`""
    }
    cmd /c "mklink /J `"$active`" `"$($targetFolder.FullName)`""

    Write-Host "Switched to $($targetFolder.Name)" -ForegroundColor Green
    return
}

Write-Host "Usage: mvm <list|add|use|remove> [version]" -ForegroundColor Yellow
Write-Host "Type 'mvm help' or 'mvm -h' for detailed usage." -ForegroundColor Gray
