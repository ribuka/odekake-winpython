# GUI (dialogs and popups) and the default output folder
# Dot-sourced by build-offline.ps1. Not meant to be run on its own.

# Use an invisible topmost form as the owner so that dialogs do not hide behind the console.
function New-TopMostOwner {
    Add-Type -AssemblyName System.Windows.Forms
    $owner = New-Object System.Windows.Forms.Form
    $owner.TopMost = $true
    $owner.ShowInTaskbar = $false
    $owner.StartPosition = 'CenterScreen'
    $owner.Size = New-Object System.Drawing.Size(0, 0)
    $owner.Opacity = 0
    $owner.Show()
    $owner.Activate()
    return $owner
}

# Turns the initialDir setting into the path where the folder selection dialog starts (spec §8).
# Returns $null if not set (empty). Environment variables (such as %USERPROFILE%) are expanded.
# A relative path is an error (when started from the .bat, its base is unclear). If the folder does not exist, warns and returns $null.
function Resolve-InitialDir([string]$Value) {
    if (-not $Value) { return $null }
    $path = [Environment]::ExpandEnvironmentVariables($Value)
    if ($path -notmatch '^([A-Za-z]:[\\/]|\\\\)') {
        throw "Setting 'initialDir' must be an absolute path (C:\... or \\server\...): '$Value'"
    }
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        Write-Log "The folder in setting 'initialDir' does not exist, so the dialog opens without a start folder: $path" -Color Yellow
        return $null
    }
    return [System.IO.Path]::GetFullPath($path)
}

# If $InitialDir is given, the dialog opens inside that folder.
function Select-ProjectFolder([string]$InitialDir) {
    $owner = New-TopMostOwner
    try {
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = 'Select the folder of the uv project to pack (the folder that contains pyproject.toml)'
        $dialog.ShowNewFolderButton = $false
        if ($dialog.PSObject.Properties['UseDescriptionForTitle']) { $dialog.UseDescriptionForTitle = $true }
        if ($InitialDir) {
            # .NET 8 and later (PS 7) have InitialDirectory. SelectedPath opens the parent folder, so InitialDirectory is preferred.
            # .NET Framework (PS 5.1) has only SelectedPath. The tree is expanded down to that folder.
            if ($dialog.PSObject.Properties['InitialDirectory']) {
                $dialog.InitialDirectory = $InitialDir
            } else {
                $dialog.SelectedPath = $InitialDir
            }
        }
        if ($dialog.ShowDialog($owner) -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
        return $dialog.SelectedPath
    } finally {
        $owner.Dispose()
    }
}

function Show-Popup([string]$Text, [bool]$IsError) {
    try {
        $owner = New-TopMostOwner
        try {
            $icon = if ($IsError) { 'Error' } else { 'Information' }
            $title = if ($IsError) { 'odekake-winpython: Failed' } else { 'odekake-winpython: Done' }
            [System.Windows.Forms.MessageBox]::Show($owner, $Text, $title, 'OK', $icon) | Out-Null
        } finally {
            $owner.Dispose()
        }
    } catch {
        Write-Log "Could not show the popup: $($_.Exception.Message)" -Color Yellow
    }
}

function Get-DownloadsFolder {
    if (-not ('OdekakeKnownFolder' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class OdekakeKnownFolder {
    [DllImport("shell32.dll")]
    private static extern int SHGetKnownFolderPath(
        [MarshalAs(UnmanagedType.LPStruct)] Guid rfid, uint dwFlags, IntPtr hToken, out IntPtr ppszPath);

    public static string GetDownloads() {
        IntPtr p;
        int hr = SHGetKnownFolderPath(new Guid("374DE290-123F-4565-9164-39C4925E467B"), 0, IntPtr.Zero, out p);
        if (hr != 0) Marshal.ThrowExceptionForHR(hr);
        try { return Marshal.PtrToStringUni(p); } finally { Marshal.FreeCoTaskMem(p); }
    }
}
'@
    }
    return [OdekakeKnownFolder]::GetDownloads()
}
