# Loading settings
# Dot-sourced by build-offline.ps1. Not meant to be run on its own.

function Resolve-FullPath([string]$Path) {
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

# Returns the type name from a $SettingTypes value. An array value means 'choice', which accepts only the listed values.
function Get-SettingKind($Type) {
    if ($Type -is [array]) { return 'choice' }
    return $Type
}

# Validates a choice value. Case-sensitive (same as unknown keys).
function Assert-SettingChoice([string]$Key, $Value, [string[]]$Choices, [string]$Source) {
    if ($Value -isnot [string] -or -not ($Choices -ccontains $Value)) {
        $list = ($Choices | ForEach-Object { '"' + $_ + '"' }) -join ' / '
        throw "Setting '$Key' must be one of $list ($Source): '$Value'"
    }
}

# Reads a settings file, checks the types, and returns a hashtable. Empty if the file does not exist.
# $SettingTypes maps each key to 'string' / 'bool' / 'array' / an array of values (choice) (a constant in build-offline.ps1).
function Read-SettingsFile([string]$Path, [System.Collections.IDictionary]$SettingTypes) {
    $result = @{}
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $result }
    Write-Log "Settings file: $Path"
    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    if (-not $text.Trim()) { return $result }
    try {
        $json = $text | ConvertFrom-Json
    } catch {
        throw "Cannot read the settings file as JSON: $Path`n$($_.Exception.Message)"
    }
    if ($json -isnot [System.Management.Automation.PSCustomObject]) {
        throw "The top level of the settings file must be a { } object: $Path"
    }
    foreach ($prop in $json.PSObject.Properties) {
        $key = $prop.Name
        if (-not (@($SettingTypes.Keys) -ccontains $key)) {
            throw "Unknown key '$key' in the settings file: $Path`nValid keys: $($SettingTypes.Keys -join ', ')"
        }
        $value = $prop.Value
        switch (Get-SettingKind $SettingTypes[$key]) {
            'choice' { Assert-SettingChoice $key $value $SettingTypes[$key] $Path }
            'string' {
                if ($value -isnot [string]) { throw "Setting '$key' must be a string: $Path" }
            }
            'bool' {
                if ($value -isnot [bool]) { throw "Setting '$key' must be true / false: $Path" }
            }
            'array' {
                if ($value -is [string]) { throw "Setting '$key' must be an array of strings ([`"...`"]): $Path" }
                $value = @($value)
                foreach ($item in $value) {
                    if ($item -isnot [string]) { throw "The items of setting '$key' must be strings: $Path" }
                }
                $value = [string[]]$value
            }
        }
        $result[$key] = $value
    }
    return $result
}

# Overrides key by key in the order defaults < settings.json < settings.local.json < arguments.
# Without -ConfigPath, reads $RepoRoot\config\settings.json.
function Get-EffectiveSettings([hashtable]$BoundParameters, [System.Collections.IDictionary]$SettingTypes, [string]$RepoRoot) {
    $settings = @{}
    foreach ($key in $SettingTypes.Keys) {
        switch (Get-SettingKind $SettingTypes[$key]) {
            'choice' { $settings[$key] = $SettingTypes[$key][0] }
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
        throw "Settings file specified by -ConfigPath not found: $configFile"
    }
    $localFile = Join-Path (Split-Path -Parent $configFile) 'settings.local.json'

    foreach ($file in @($configFile, $localFile)) {
        $fromFile = Read-SettingsFile $file $SettingTypes
        foreach ($key in $fromFile.Keys) { $settings[$key] = $fromFile[$key] }
    }

    foreach ($key in $SettingTypes.Keys) {
        $paramName = $key.Substring(0, 1).ToUpper() + $key.Substring(1)
        if (-not $BoundParameters.ContainsKey($paramName)) { continue }
        # pythonVersion has a priority relative to .python-version, so the argument does not override it here (see Get-PythonMinor)
        if ($key -eq 'pythonVersion') { continue }
        $value = $BoundParameters[$paramName]
        switch (Get-SettingKind $SettingTypes[$key]) {
            'choice' { Assert-SettingChoice $key $value $SettingTypes[$key] "argument -$paramName" }
            'bool' { $value = [bool]$value }
            'array' {
                # Through the .bat (-File), -Groups a,b arrives as a single string, so split it on commas
                $value = [string[]]@($value | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            }
        }
        $settings[$key] = $value
    }
    return $settings
}
