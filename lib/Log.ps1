# ログと外部コマンドの実行
# build-offline.ps1 から dot-source される。単体では実行しない。

# ログはスクリプト全体で1つの状態なので、$script: に持つ。
# ログファイル名には <name> が要るので、pyproject を読むまではメモリに溜める。
$script:LogBuffer = New-Object System.Collections.Generic.List[string]
$script:LogPath = $null
$script:LogEncoding = New-Object System.Text.UTF8Encoding($false)

function Write-Log {
    param([string]$Message = '', [string]$Color)
    if ($Color) { Write-Host $Message -ForegroundColor $Color } else { Write-Host $Message }
    $line = '{0:HH:mm:ss} {1}' -f (Get-Date), $Message
    if ($script:LogPath) {
        [System.IO.File]::AppendAllText($script:LogPath, $line + "`r`n", $script:LogEncoding)
    } else {
        $script:LogBuffer.Add($line)
    }
}

function Write-Step([string]$Message) {
    Write-Log ''
    Write-Log "== $Message" -Color Cyan
}

# 溜めたログを $LogDir\<Timestamp>_<Name>.log に書き出し、以降はそのファイルに追記する。
function Open-LogFile([string]$Name, [string]$LogDir, [string]$Timestamp) {
    if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }
    $fileName = if ($Name) { "${Timestamp}_$Name.log" } else { "$Timestamp.log" }
    $script:LogPath = Join-Path $LogDir $fileName
    [System.IO.File]::AppendAllLines($script:LogPath, $script:LogBuffer, $script:LogEncoding)
    $script:LogBuffer.Clear()
}

# 外部コマンドを実行し、stdout と stderr をログに書く。終了コードが 0 以外なら例外。
# -Capture を付けると、stdout をログに書かずに返す(stderr はログに書く)。
function Invoke-Native {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [switch]$Capture
    )
    Write-Log ("> {0} {1}" -f $FilePath, ($Arguments -join ' ')) -Color DarkGray
    $stdout = New-Object System.Collections.Generic.List[string]
    # 5.1 では Stop のまま stderr をリダイレクトすると、stderr の1行目で例外になる
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $FilePath @Arguments 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) {
                Write-Log ([string]$_.Exception.Message)
            } elseif ($Capture) {
                $stdout.Add([string]$_)
            } else {
                Write-Log ([string]$_)
            }
        }
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEap
    }
    if ($code -ne 0) {
        throw "外部コマンドが失敗しました(終了コード $code): $FilePath $($Arguments -join ' ')"
    }
    if ($Capture) { return , $stdout.ToArray() }
}
