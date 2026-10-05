# WinPython の取得と展開
# build-offline.ps1 から dot-source される。単体では実行しない。

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

# $BuildDir\downloads にキャッシュした WinPython の zip を返す。ハッシュが合わなければ取り直す。
function Get-WinPythonArchive([hashtable]$Entry, [string]$BuildDir) {
    $downloadDir = Join-Path $BuildDir 'downloads'
    if (-not (Test-Path -LiteralPath $downloadDir)) { New-Item -ItemType Directory -Path $downloadDir | Out-Null }
    $fileName = [System.IO.Path]::GetFileName(([Uri]$Entry.Url).AbsolutePath)
    $path = Join-Path $downloadDir $fileName

    if (Test-Path -LiteralPath $path -PathType Leaf) {
        if ((Get-Sha256 $path) -eq $Entry.Sha256) {
            Write-Log "キャッシュを使います: $path"
            return $path
        }
        Write-Log "キャッシュの SHA-256 が一致しないため、ダウンロードし直します: $path" -Color Yellow
        Remove-Item -LiteralPath $path -Force
    }

    Write-Log "ダウンロード: $($Entry.Url)"
    Write-Log "保存先: $path"
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
    $partial = "$path.partial"
    if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
    Invoke-WebRequest -Uri $Entry.Url -OutFile $partial -UseBasicParsing
    $actual = Get-Sha256 $partial
    if ($actual -ne $Entry.Sha256) {
        Remove-Item -LiteralPath $partial -Force
        throw "ダウンロードした WinPython の SHA-256 が一致しません。`n期待値: $($Entry.Sha256)`n実際: $actual"
    }
    Move-Item -LiteralPath $partial -Destination $path
    return $path
}

# WinPython を $WorkDir\extract に展開し、最上位フォルダ(WPy64-xxxx)を取り除いて $Destination に置く。
function Expand-WinPython([string]$Archive, [string]$Destination, [string]$WorkDir) {
    $extractDir = Join-Path $WorkDir 'extract'
    Write-Log "展開: $Archive"
    [System.IO.Compression.ZipFile]::ExtractToDirectory($Archive, $extractDir)
    $top = @(Get-ChildItem -LiteralPath $extractDir -Force)
    if ($top.Count -ne 1 -or -not $top[0].PSIsContainer) {
        throw "WinPython の zip の最上位がフォルダ1つではありません: $Archive"
    }
    Write-Log "最上位フォルダ $($top[0].Name) を取り除いて、winpython\ に置きます"
    Move-Item -LiteralPath $top[0].FullName -Destination $Destination
    Remove-Item -LiteralPath $extractDir -Force
}
