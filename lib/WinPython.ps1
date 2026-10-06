# Downloading and extracting WinPython
# Dot-sourced by build-offline.ps1. Not meant to be run on its own.

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

# Returns the WinPython zip cached in $BuildDir\downloads. Downloads it again if the hash does not match.
function Get-WinPythonArchive([hashtable]$Entry, [string]$BuildDir) {
    $downloadDir = Join-Path $BuildDir 'downloads'
    if (-not (Test-Path -LiteralPath $downloadDir)) { New-Item -ItemType Directory -Path $downloadDir | Out-Null }
    $fileName = [System.IO.Path]::GetFileName(([Uri]$Entry.Url).AbsolutePath)
    $path = Join-Path $downloadDir $fileName

    if (Test-Path -LiteralPath $path -PathType Leaf) {
        if ((Get-Sha256 $path) -eq $Entry.Sha256) {
            Write-Log "Using the cache: $path"
            return $path
        }
        Write-Log "The SHA-256 of the cache does not match. Downloading again: $path" -Color Yellow
        Remove-Item -LiteralPath $path -Force
    }

    Write-Log "Downloading: $($Entry.Url)"
    Write-Log "Saving to: $path"
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
    $partial = "$path.partial"
    if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
    Invoke-WebRequest -Uri $Entry.Url -OutFile $partial -UseBasicParsing
    $actual = Get-Sha256 $partial
    if ($actual -ne $Entry.Sha256) {
        Remove-Item -LiteralPath $partial -Force
        throw "The SHA-256 of the downloaded WinPython does not match.`nExpected: $($Entry.Sha256)`nActual: $actual"
    }
    Move-Item -LiteralPath $partial -Destination $path
    return $path
}

# Extracts WinPython into $WorkDir\extract, strips the top-level folder (WPy64-xxxx), and places it at $Destination.
function Expand-WinPython([string]$Archive, [string]$Destination, [string]$WorkDir) {
    $extractDir = Join-Path $WorkDir 'extract'
    Write-Log "Extracting: $Archive"
    [System.IO.Compression.ZipFile]::ExtractToDirectory($Archive, $extractDir)
    $top = @(Get-ChildItem -LiteralPath $extractDir -Force)
    if ($top.Count -ne 1 -or -not $top[0].PSIsContainer) {
        throw "The top level of the WinPython zip is not a single folder: $Archive"
    }
    Write-Log "Stripping the top-level folder $($top[0].Name) and placing it at winpython\"
    Move-Item -LiteralPath $top[0].FullName -Destination $Destination
    Remove-Item -LiteralPath $extractDir -Force
}
