#!/usr/bin/env pwsh
<#
Runs the downstream-link matrix: tauri-build x tauri-utils versions, config switches,
cargo subcommands, crt-static.

Usage:
    pwsh -File run_matrix.ps1              # runs in a temp copy, keeps the repo clean
    pwsh -File run_matrix.ps1 -InPlace     # runs in place (rewrites Cargo.lock and
                                           # down/src/lib.rs)

Needs these versions in the local cargo registry cache: tauri-build 2.6.3/2.7.0/2.7.1 and
tauri-utils 2.9.3/2.10.0/2.10.1.
#>
param([switch]$InPlace)

$ErrorActionPreference = 'Continue'

$srcRoot = $PSScriptRoot
if ($InPlace) {
    $work = $srcRoot
}
else {
    $work = Join-Path ([IO.Path]::GetTempPath()) ("tsvr-tauri-" + (Get-Date -Format 'HHmmss'))
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    Get-ChildItem -LiteralPath $srcRoot -Force | Where-Object { $_.Name -ne 'target' } |
        ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $work -Recurse -Force
        }
}

$downDir = Join-Path $work 'down'
$lock = Join-Path $downDir 'Cargo.lock'
$pristineLock = Join-Path $work 'Cargo.lock.pristine'
if (-not (Test-Path -LiteralPath $pristineLock)) {
    Copy-Item -LiteralPath $lock -Destination $pristineLock -Force
}

function Get-Locked {
    param([string]$Name)
    $lines = Get-Content -LiteralPath $lock
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "^name = ""$([regex]::Escape($Name))""$") {
            if ($lines[$i + 1] -match '^version = "(.*)"$') { return $Matches[1] }
        }
    }
    return '?'
}

function Get-Stub {
    $buildRoot = Join-Path $downDir 'target'
    $found = Get-ChildItem -LiteralPath $buildRoot -Recurse -Force -File `
        -ErrorAction SilentlyContinue |
        Where-Object {
            # up's OUT_DIR also holds tauri-winres' resource.lib, so match the stub name only.
            $_.FullName -match '\\build\\up-' -and
            $_.Name -in @('msvcrt.lib', 'foo.lib')
        } | Select-Object -First 1
    if ($found) { return "$($found.Name) $($found.Length)B" }
    return 'none'
}

function Get-VerdictLine {
    param([string]$Text)
    $lnk = $Text -split "`r?`n" | Where-Object { $_ -match 'LNK\d{4}' } | Select-Object -First 1
    if ($lnk) { return ($lnk.Trim() -replace '\s+', ' ') }
    $err = $Text -split "`r?`n" | Where-Object { $_ -match '^\s*error' } | Select-Object -First 1
    if ($err) { return ($err.Trim() -replace '\s+', ' ') }
    return ''
}

function Clear-TestEnv {
    foreach ($v in 'STATIC_VCRUNTIME', 'TAURI_CONFIG', 'RUSTFLAGS', 'REPRO_MODE') {
        Remove-Item "Env:\$v" -ErrorAction SilentlyContinue
    }
}

# Each cell: version pins, env vars, cargo subcommand, optional cargo clean, optional touch.
$cells = @(
    @{ Id = '1'; Build = '2.6.3'; Utils = '2.10.1'; Args = @('test', '--no-run')
       Env = @{}; Note = 'baseline: 2.6.3 default (no env set)' }
    @{ Id = '2'; Build = '2.6.3'; Utils = '2.10.1'; Args = @('test', '--no-run')
       Env = @{ STATIC_VCRUNTIME = 'true' }; Clean = $true
       Note = 'key: 2.6.3 + legacy env switch; no rerun-if-env-changed, so clean first' }
    @{ Id = '3'; Build = '2.7.0'; Utils = '2.10.0'; Args = @('test', '--no-run')
       Env = @{}; Note = 'version pair: 2.7.0 x 2.10.0' }
    @{ Id = '4'; Build = '2.7.1'; Utils = '2.10.1'; Args = @('test', '--no-run')
       Env = @{}; Note = 'baseline: 2.7.1 x 2.10.1, defaults' }
    @{ Id = '5a'; Build = '2.7.1'; Utils = '2.10.1'; Args = @('test', '--no-run')
       Env = @{ STATIC_VCRUNTIME = 'false' }; Touch = $true
       Note = 'env off but no clean; touch a file to force a relink (stale args persist)' }
    @{ Id = '5b'; Build = '2.7.1'; Utils = '2.10.1'; Args = @('test', '--no-run')
       Env = @{ STATIC_VCRUNTIME = 'false' }; Clean = $true
       Note = 'same, but after a cargo clean' }
    @{ Id = '6'; Build = '2.7.1'; Utils = '2.10.1'; Args = @('test', '--no-run')
       Env = @{ TAURI_CONFIG = '{"build":{"windows":{"staticVCRuntime":false}}}' }
       Touch = $true; Note = 'staticVCRuntime disabled in the config' }
    @{ Id = '7'; Build = '2.7.1'; Utils = '2.10.1'; Args = @('check', '--all-targets')
       Env = @{}; Note = 'command matrix: cargo check --all-targets' }
    @{ Id = '8'; Build = '2.7.1'; Utils = '2.10.1'; Args = @('build')
       Env = @{}; Touch = $true; Note = 'command matrix: cargo build (down has a bin target)' }
    @{ Id = '9'; Build = '2.7.1'; Utils = '2.10.1'; Args = @('test', '--no-run')
       Env = @{ RUSTFLAGS = '-C target-feature=+crt-static' }; Note = 'with a static CRT' }
)

$rows = @()
foreach ($cell in $cells) {
    Copy-Item -LiteralPath $pristineLock -Destination $lock -Force
    Clear-TestEnv
    foreach ($k in $cell.Env.Keys) { Set-Item "Env:\$k" $cell.Env[$k] }

    if ($cell.Build) {
        & cargo update --offline --manifest-path (Join-Path $downDir 'Cargo.toml') `
            -p tauri-build --precise $cell.Build 2>&1 | Out-Null
    }
    if ($cell.Utils) {
        & cargo update --offline --manifest-path (Join-Path $downDir 'Cargo.toml') `
            -p tauri-utils --precise $cell.Utils 2>&1 | Out-Null
    }

    if ($cell.Clean) {
        & cargo clean --manifest-path (Join-Path $downDir 'Cargo.toml') 2>&1 | Out-Null
    }
    if ($cell.Touch) {
        # Leaves up untouched; only down's own test binary relinks, reusing up's stale args.
        Add-Content -LiteralPath (Join-Path $downDir 'src\lib.rs') `
            -Value "// touch $($cell.Id) $((Get-Date).Ticks)" -Encoding utf8
    }

    $text = (& cargo @($cell.Args) --manifest-path (Join-Path $downDir 'Cargo.toml') 2>&1 |
        Out-String)
    $ok = ($LASTEXITCODE -eq 0)

    $rows += [pscustomobject]@{
        Id = $cell.Id
        Note = $cell.Note
        Cmd = 'cargo ' + ($cell.Args -join ' ')
        Locked = "$(Get-Locked 'tauri-build') / $(Get-Locked 'tauri-utils')"
        Result = if ($ok) { 'pass' } else { 'FAIL' }
        Stub = Get-Stub
        Verdict = Get-VerdictLine -Text $text
    }
}

Clear-TestEnv
if (-not $InPlace) { Write-Output "workdir: $work" }
Write-Output ''
Write-Output '| # | what | cmd | locked (build/utils) | downstream | lib in OUT_DIR | verdict |'
Write-Output '| --- | --- | --- | --- | --- | --- | --- |'
foreach ($r in $rows) {
    Write-Output ("| {0} | {1} | {2} | {3} | {4} | {5} | {6} |" -f `
        $r.Id, $r.Note, $r.Cmd, $r.Locked, $r.Result, $r.Stub, $r.Verdict)
}
