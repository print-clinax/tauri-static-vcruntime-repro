#!/usr/bin/env pwsh
<#
Runs the minimal control matrix: for each REPRO_MODE, check whether `up` itself and the
downstream `down` crate can link.

Usage:
    pwsh -File run_controls.ps1

Each cell deletes the up/down target dirs first, so a stale OUT_DIR plus create_new(true)
cannot carry a previous cell's result over. Output is a markdown table.
#>
$ErrorActionPreference = 'Continue'

$root = $PSScriptRoot
$upDir = Join-Path $root 'up'
$downDir = Join-Path $root 'down'
$upManifest = Join-Path $upDir 'Cargo.toml'
$downManifest = Join-Path $downDir 'Cargo.toml'

$modes = @('stub', 'no_stub', 'stub_and_args', 'empty_file', 'name_lib', 'libpath')

# Pull the most telling line out of cargo's output: prefer an LNK error, else an error.
function Get-VerdictLine {
    param([string]$Text)
    $lnk = $Text -split "`r?`n" | Where-Object { $_ -match 'LNK\d{4}' } | Select-Object -First 1
    if ($lnk) { return $lnk.Trim() }
    $err = $Text -split "`r?`n" | Where-Object { $_ -match '^\s*error' } | Select-Object -First 1
    if ($err) { return $err.Trim() }
    return ''
}

# Locate the library file inside up's build-script OUT_DIR (msvcrt.lib, or foo.lib for the
# name_lib control). up's OUT_DIR also holds other .lib files (e.g. from tauri-winres), so
# only the stub name is matched here.
function Get-Stub {
    param([string]$DownDir)
    $found = Get-ChildItem -LiteralPath (Join-Path $DownDir 'target') -Recurse -Force -File `
        -ErrorAction SilentlyContinue |
        Where-Object {
            $_.FullName -match '\\build\\up-' -and
            $_.Name -in @('msvcrt.lib', 'foo.lib')
        } | Select-Object -First 1
    if ($found) { return "$($found.Name) ($($found.Length) B)" }
    return 'none'
}

$rows = @()
foreach ($mode in $modes) {
    foreach ($dir in @($upDir, $downDir)) {
        $t = Join-Path $dir 'target'
        if (Test-Path -LiteralPath $t) { Remove-Item -LiteralPath $t -Recurse -Force }
    }

    $env:REPRO_MODE = $mode

    $upText = (& cargo test --manifest-path $upManifest 2>&1 | Out-String)
    $upOk = ($LASTEXITCODE -eq 0)

    $downText = (& cargo test --manifest-path $downManifest 2>&1 | Out-String)
    $downOk = ($LASTEXITCODE -eq 0)

    $rows += [pscustomobject]@{
        Mode = $mode
        Up = if ($upOk) { 'pass' } else { 'FAIL' }
        Down = if ($downOk) { 'pass' } else { 'FAIL' }
        Stub = Get-Stub -DownDir $downDir
        'Up verdict' = Get-VerdictLine -Text $upText
        'Down verdict' = Get-VerdictLine -Text $downText
    }
}

Remove-Item Env:\REPRO_MODE -ErrorAction SilentlyContinue

$rows | Format-Table -AutoSize | Out-String -Width 400

Write-Output ''
Write-Output '| REPRO_MODE | up itself | down links | lib in OUT_DIR | down verdict |'
Write-Output '| --- | --- | --- | --- | --- |'
foreach ($r in $rows) {
    Write-Output "| $($r.Mode) | $($r.Up) | $($r.Down) | $($r.Stub) | $($r.'Down verdict') |"
}
