<#
.SYNOPSIS
    Build one or both AgentGateway MSI packages with WiX 3.11.

.DESCRIPTION
    Compiles and links Product.wxs + UI.wxs into a signed (optional) MSI.
    Supports per-machine (default) and per-user variants.
    Pass -Silent to embed SILENT=1 so the MSI skips dialogs at runtime.

.PARAMETER Variant
    "machine"  - per-machine MSI  (default, installs to Program Files)
    "user"     - per-user   MSI  (installs to LocalAppData, no UAC)
    "both"     - build both variants

.PARAMETER SourceDir
    Path to the folder containing AgentGateway.exe.
    Defaults to ..\src\bin\Release relative to the installer folder.

.PARAMETER OutputDir
    Where to place the finished .msi files.
    Defaults to .\output relative to the installer folder.

.PARAMETER WixDir
    Path to the WiX 3.11 bin directory.
    Defaults to C:\Program Files (x86)\WiX Toolset v3.11\bin

.PARAMETER Sign
    Sign the MSI with signtool after linking.
    Requires CertThumbprint or a suitable certificate in the current user store.

.PARAMETER CertThumbprint
    SHA-1 thumbprint of a code-signing certificate in the current user store.

.PARAMETER TimestampUrl
    RFC-3161 timestamp server URL.
    Default: http://timestamp.digicert.com

.EXAMPLE
    # Basic build (per-machine, no signing)
    .\build.ps1

    # Build both variants pointing at a custom source directory
    .\build.ps1 -Variant both -SourceDir C:\myapp\bin\Release

    # Silent MSI (no UI dialogs)
    .\build.ps1 -Silent

    # Signed release build
    .\build.ps1 -Variant both -Sign -CertThumbprint AABBCCDDEEFF00112233445566778899AABBCCDD
#>
[CmdletBinding()]
param(
    [ValidateSet("machine","user","both")]
    [string]$Variant      = "machine",

    [string]$SourceDir    = (Join-Path $PSScriptRoot "..\src\bin\Release"),
    [string]$OutputDir    = (Join-Path $PSScriptRoot "output"),
    [string]$WixTargetsPath       = "C:\Program Files\Microsoft Visual Studio\2022\Community\MSBuild\WixToolset\5.0\Imports\WixToolset.targets",

    [switch]$Sign,
    [string]$CertThumbprint = "",
    [string]$TimestampUrl   = "http://timestamp.digicert.com"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Resolve tool paths
# ---------------------------------------------------------------------------

$null = New-Item -ItemType Directory -Force -Path $OutputDir

$srcDir  = $PSScriptRoot
$iconDir = Join-Path $PSScriptRoot "icons"

# ---------------------------------------------------------------------------
# Determine product version
#   1. Read FileVersion from AgentGateway.exe   (preferred)
#   2. Fall back to version.txt          (used during development)
# ---------------------------------------------------------------------------


$vFile   = Join-Path $PSScriptRoot "version.txt"
$version = if (Test-Path $vFile) { (Get-Content $vFile -Raw).Trim() } else { "1.0.0.0" }


# Short version for MSI filename (drop 4th field)
$fullVersion = $version.TrimStart('v')
$shortVer = ($fullVersion -split '\.')[ 0..2 ] -join '.'

$ghRepo      = "mcpjungle/MCPJungle"
$downloadUrl = "https://github.com/{0}/releases/download/{1}/mcpjungle_Windows_x86_64.zip" -f $ghRepo, $shortVer # URL of the ZIP file
$stagingDir  = (Join-Path $PSScriptRoot "..\staging")					# Temporary staging folder

Write-Host ""
Write-Host "=======================================" -ForegroundColor Cyan
Write-Host "  MCPJungle MSI Builder" -ForegroundColor Cyan
Write-Host "  Version   : $version" -ForegroundColor Cyan
Write-Host "  Variant   : $Variant" -ForegroundColor Cyan
Write-Host "  SourceDir : $SourceDir" -ForegroundColor Cyan
Write-Host "  OutputDir : $OutputDir" -ForegroundColor Cyan
Write-Host "=======================================" -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------------------
# Shared candle defines
# ---------------------------------------------------------------------------
$defines = @(
    "-dSourceDir=$SourceDir"
    "-dIconDir=$iconDir"
    "-dProductVersion=$version"
)

# --------------------------------------------------------------------------
# Download and Extract function
# --------------------------------------------------------------------------
function Download-Extract {
	# --- CONFIGURATION ---
	 param(
		[string]$zipUrl,   		# URL of the ZIP file
		[string]$stagingPath,   # Temporary staging folder
		[string]$targetFolder  # Final destination
	)

    try {
		# Ensure staging directory exists (clean if exists)
        if (Test-Path $stagingPath) { Remove-Item "$stagingPath\*" -Recurse -Force }
		New-Item -Path $stagingPath -ItemType Directory -Force | Out-Null

		# Download ZIP
		$zipFilePath = Join-Path $stagingPath "download.zip"
		Write-Host "Downloading ZIP from $zipUrl ..."
		Invoke-WebRequest -Uri $zipUrl -OutFile $zipFilePath -UseBasicParsing

		if (-not (Test-Path $zipFilePath)) {
			throw "Download failed. ZIP file not found."
		}
        
        # Ensure target extract folder exists (clean if exists)
		if (Test-Path $targetFolder) { Remove-Item $targetFolder -Recurse -Force }
		New-Item -Path $targetFolder -ItemType Directory -Force | Out-Null

		# Extract entire ZIP
		Write-Host "Extracting ZIP to target folder..."
		Expand-Archive -Path $zipFilePath -DestinationPath $targetFolder -Force

		Write-Host "Extraction complete."

		Write-Host "Download complete."

	} catch {
		Write-Error "Error: $_"
	}
}


# ---------------------------------------------------------------------------
# Build function
# ---------------------------------------------------------------------------
function Invoke-WixBuild {
    param(
		[string]$WixProject,   # Path to installer.wixproj
        [string]$BuildType,    # BuildType - Machine, User
		[string]$prefix,
		[string]$ProductVersion,
		[string]$ShortVer,
		[string]$SourceDir,
		[string]$OutputDir,
		[string]$OutputMsi
    )

	# Ensure staging directory exists  (clean if exists)
	if (Test-Path $OutputDir) { Remove-Item $OutputDir -Recurse -Force }
	New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null
	$Scope	   = "per{0}" -f $BuildType
	
	$BuildDir = Join-Path $OutputDir "build"
	if (Test-Path $BuildDir) { Remove-Item $BuildDir -Recurse -Force }
	New-Item -Path $BuildDir -ItemType Directory -Force | Out-Null
	
	Write-Host "[dotnet] Compiling $(Split-Path $WixProject -Leaf) ..." -ForegroundColor DarkCyan

	$ProductWxs 	= Join-Path $PSScriptRoot "Product.wxs"
    
    $IconDir 	= Join-Path $PSScriptRoot "icons"
    $ConfigDir 	= Join-Path $PSScriptRoot "config"
    $BitmapDir 	= Join-Path $PSScriptRoot "bitmaps"
    $LicenseFile 	= Join-Path $PSScriptRoot "License.rtf"
	
	Write-Host "[wix] Compiling $(Split-Path $ProductWxs -Leaf) ..." -ForegroundColor DarkCyan
	wix build -arch "x64" -outputtype "Package" -culture "en-US" -b $SourceDir -out $OutputMsi `
			  -intermediatefolder $BuildDir -src $ProductWxs -ext WixToolset.Util.wixext -ext WixToolset.UI.wixext `
			  -d BuildType=$BuildType -d ProductVersion=$ProductVersion -d ShortVer=$ShortVer -d SourceDir=$SourceDir -d Scope=$Scope `
              -d IconDir=$IconDir -d ConfigDir=$ConfigDir -d BitmapDir=$BitmapDir -d LicenseFile=$LicenseFile

    Write-Host "[ok]     $OutputMsi" -ForegroundColor Green
    return $OutputMsi
}


# ---------------------------------------------------------------------------
# Signing helper
# ---------------------------------------------------------------------------
function Invoke-Sign {
    param([string]$MsiPath)
    if (-not $Sign) { return }

    # Auto-locate signtool.exe from Windows SDK
    $st = ""
    if (Test-Path "C:\Program Files (x86)\Windows Kits\10\bin") {
        $st = Get-ChildItem "C:\Program Files (x86)\Windows Kits\10\bin" `
                            -Recurse -Filter "signtool.exe" |
              Where-Object { $_.FullName -match 'x64' } |
              Sort-Object FullName -Descending |
              Select-Object -First 1 -ExpandProperty FullName
    }
    if (-not $st) { throw "signtool.exe not found. Install the Windows SDK." }

    $signArgs = @("sign", "/fd", "SHA256", "/tr", $TimestampUrl, "/td", "SHA256")
    if ($CertThumbprint) {
        $signArgs += @("/sha1", $CertThumbprint)
    } else {
        $signArgs += "/a"   # auto-select best available certificate
    }
    $signArgs += $MsiPath

    Write-Host "[sign]   Signing $(Split-Path $MsiPath -Leaf) ..." -ForegroundColor DarkCyan
    & $st @signArgs
    if ($LASTEXITCODE -ne 0) { throw "signtool.exe failed with exit code $LASTEXITCODE" }
    Write-Host "[ok]     Signed: $MsiPath" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Dispatch builds
# ---------------------------------------------------------------------------
$built = @()

Download-Extract -zipUrl $downloadURL `
				 -stagingPath $stagingDir `
				 -targetFolder $SourceDir 

if (-not (Test-Path $SourceDir)) {
    throw "SourceDir not found: $SourceDir`nBuild mcpjungle.exe first, or pass -SourceDir."
}


if ($Variant -in "machine","both") {
	$OutputFolder = Join-Path $OutputDir "Machine"
	$prefix = "mcpjungle-superuser"
	$fileName = "{0}-{1}.msi" -f $prefix, $shortVer
    $msi = Join-Path $OutputFolder $fileName
    Invoke-WixBuild -WixProject (Join-Path $srcDir "installer.wixproj") `
					-BuildType  "Machine" `
					-prefix     $prefix `
					-ProductVersion $version `
					-shortVer $shortVer `
					-SourceDir $SourceDir `
					-OutputDir  $OutputFolder `
                    -OutputMsi  $msi 
    Invoke-Sign $msi
    $built += $msi
}

if ($Variant -in "machine","both") {
	$OutputFolder = Join-Path $OutputDir "User"
	$prefix = "mcpjungle-enduser"
	$fileName = "{0}-{1}.msi" -f $prefix, $shortVer
    $msi = Join-Path $OutputFolder $fileName
    Invoke-WixBuild -WixProject (Join-Path $srcDir "installer.wixproj") `
					-BuildType  "User" `
					-prefix     $prefix `
					-ProductVersion $version `
					-shortVer $shortVer `
					-SourceDir $SourceDir `
					-OutputDir  $OutputFolder `
                    -OutputMsi  $msi 
    Invoke-Sign $msi
    $built += $msi
}

Write-Host ""
Write-Host "Build complete.  Output files:" -ForegroundColor Cyan
$built | ForEach-Object { Write-Host "  $_" -ForegroundColor White }
Write-Host ""
