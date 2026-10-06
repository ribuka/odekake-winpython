# GUI(ダイアログ・ポップアップ)と出力先の既定値
# build-offline.ps1 から dot-source される。単体では実行しない。

# ダイアログがコンソールの裏に隠れないよう、最前面の見えないフォームを親にする。
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

# 設定 initialDir の値を、フォルダ選択ダイアログの初期位置にするパスへ直す(spec §8)。
# 未指定(空)なら $null。環境変数(%USERPROFILE% など)は展開する。
# 相対パスはエラー(.bat から起動すると基準が分かりにくいため)。存在しなければ警告して $null。
function Resolve-InitialDir([string]$Value) {
    if (-not $Value) { return $null }
    $path = [Environment]::ExpandEnvironmentVariables($Value)
    if ($path -notmatch '^([A-Za-z]:[\\/]|\\\\)') {
        throw "設定 'initialDir' は絶対パス(C:\... または \\server\...)にしてください: '$Value'"
    }
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        Write-Log "設定 'initialDir' のフォルダがないので、初期位置を指定せずにダイアログを開きます: $path" -Color Yellow
        return $null
    }
    return [System.IO.Path]::GetFullPath($path)
}

# $InitialDir があれば、その中を開いた状態でダイアログを出す。
function Select-ProjectFolder([string]$InitialDir) {
    $owner = New-TopMostOwner
    try {
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = '持ち出す uv プロジェクトのフォルダ(pyproject.toml があるフォルダ)を選んでください'
        $dialog.ShowNewFolderButton = $false
        if ($dialog.PSObject.Properties['UseDescriptionForTitle']) { $dialog.UseDescriptionForTitle = $true }
        if ($InitialDir) {
            # .NET 8 以降(PS 7)は InitialDirectory がある。SelectedPath だと親フォルダが開くため、こちらを優先する。
            # .NET Framework(PS 5.1)は SelectedPath だけ。ツリーがそのフォルダまで展開される。
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
            $title = if ($IsError) { 'odekake-winpython: 失敗' } else { 'odekake-winpython: 完了' }
            [System.Windows.Forms.MessageBox]::Show($owner, $Text, $title, 'OK', $icon) | Out-Null
        } finally {
            $owner.Dispose()
        }
    } catch {
        Write-Log "ポップアップを表示できませんでした: $($_.Exception.Message)" -Color Yellow
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
