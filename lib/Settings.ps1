# 設定の読み込み
# build-offline.ps1 から dot-source される。単体では実行しない。

function Resolve-FullPath([string]$Path) {
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

# 設定ファイルを読み、型を確認して hashtable で返す。ファイルがなければ空。
# $SettingTypes は キー → 'string' / 'bool' / 'array' の辞書(build-offline.ps1 の固定値)。
function Read-SettingsFile([string]$Path, [System.Collections.IDictionary]$SettingTypes) {
    $result = @{}
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $result }
    Write-Log "設定ファイル: $Path"
    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    if (-not $text.Trim()) { return $result }
    try {
        $json = $text | ConvertFrom-Json
    } catch {
        throw "設定ファイルを JSON として読めません: $Path`n$($_.Exception.Message)"
    }
    if ($json -isnot [System.Management.Automation.PSCustomObject]) {
        throw "設定ファイルの最上位は { } のオブジェクトにしてください: $Path"
    }
    foreach ($prop in $json.PSObject.Properties) {
        $key = $prop.Name
        if (-not (@($SettingTypes.Keys) -ccontains $key)) {
            throw "設定ファイルに未知のキー '$key' があります: $Path`n使えるキー: $($SettingTypes.Keys -join ', ')"
        }
        $value = $prop.Value
        switch ($SettingTypes[$key]) {
            'string' {
                if ($value -isnot [string]) { throw "設定 '$key' は文字列にしてください: $Path" }
            }
            'bool' {
                if ($value -isnot [bool]) { throw "設定 '$key' は true / false にしてください: $Path" }
            }
            'array' {
                if ($value -is [string]) { throw "設定 '$key' は文字列の配列([`"...`"])にしてください: $Path" }
                $value = @($value)
                foreach ($item in $value) {
                    if ($item -isnot [string]) { throw "設定 '$key' の要素は文字列にしてください: $Path" }
                }
                $value = [string[]]$value
            }
        }
        $result[$key] = $value
    }
    return $result
}

# 既定値 < settings.json < settings.local.json < 引数 の順に、キー単位で上書きする。
# -ConfigPath がなければ $RepoRoot\config\settings.json を読む。
function Get-EffectiveSettings([hashtable]$BoundParameters, [System.Collections.IDictionary]$SettingTypes, [string]$RepoRoot) {
    $settings = @{}
    foreach ($key in $SettingTypes.Keys) {
        switch ($SettingTypes[$key]) {
            'string' { $settings[$key] = $null }
            'bool'   { $settings[$key] = $false }
            'array'  { $settings[$key] = [string[]]@() }
        }
    }

    $configFile = if ($BoundParameters.ContainsKey('ConfigPath')) {
        Resolve-FullPath $BoundParameters['ConfigPath']
    } else {
        Join-Path $RepoRoot 'config\settings.json'
    }
    if ($BoundParameters.ContainsKey('ConfigPath') -and -not (Test-Path -LiteralPath $configFile -PathType Leaf)) {
        throw "-ConfigPath で指定された設定ファイルがありません: $configFile"
    }
    $localFile = Join-Path (Split-Path -Parent $configFile) 'settings.local.json'

    foreach ($file in @($configFile, $localFile)) {
        $fromFile = Read-SettingsFile $file $SettingTypes
        foreach ($key in $fromFile.Keys) { $settings[$key] = $fromFile[$key] }
    }

    foreach ($key in $SettingTypes.Keys) {
        $paramName = $key.Substring(0, 1).ToUpper() + $key.Substring(1)
        if (-not $BoundParameters.ContainsKey($paramName)) { continue }
        # pythonVersion は .python-version との間に優先順位があるので、ここでは引数で上書きしない(Get-PythonMinor)
        if ($key -eq 'pythonVersion') { continue }
        $value = $BoundParameters[$paramName]
        switch ($SettingTypes[$key]) {
            'bool' { $value = [bool]$value }
            'array' {
                # .bat 経由(-File)だと -Groups a,b が1つの文字列で届くので、カンマで分ける
                $value = [string[]]@($value | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            }
        }
        $settings[$key] = $value
    }
    return $settings
}
