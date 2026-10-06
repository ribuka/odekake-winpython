# Logging and running external commands
# Dot-sourced by build-offline.ps1. Not meant to be run on its own.

# The log is a single state for the whole script, so it is kept in $script:.
# The log file name needs <name>, so lines are buffered in memory until pyproject is read.
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

# Writes the buffered lines to $LogDir\<Timestamp>_<Name>.log and appends to that file from then on.
function Open-LogFile([string]$Name, [string]$LogDir, [string]$Timestamp) {
    if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }
    $fileName = if ($Name) { "${Timestamp}_$Name.log" } else { "$Timestamp.log" }
    $script:LogPath = Join-Path $LogDir $fileName
    [System.IO.File]::AppendAllLines($script:LogPath, $script:LogBuffer, $script:LogEncoding)
    $script:LogBuffer.Clear()
}

# Runs an external command and writes stdout and stderr to the log. Throws if the exit code is not 0.
# With -Capture, returns stdout instead of logging it (stderr is still logged).
function Invoke-Native {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [switch]$Capture
    )
    Write-Log ("> {0} {1}" -f $FilePath, ($Arguments -join ' ')) -Color DarkGray
    $stdout = New-Object System.Collections.Generic.List[string]
    # In 5.1, redirecting stderr while the preference is Stop throws on the first stderr line
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
        throw "External command failed (exit code $code): $FilePath $($Arguments -join ' ')"
    }
    if ($Capture) { return , $stdout.ToArray() }
}
