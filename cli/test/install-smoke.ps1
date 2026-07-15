$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$cli = Join-Path $repoRoot "cli\bin\weaver.js"
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$scratch = [IO.Path]::GetFullPath((Join-Path $tempRoot ("weaver-install-smoke-" + [guid]::NewGuid().ToString("N"))))
if (-not $scratch.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
  throw "Unsafe install smoke path: $scratch"
}

function Invoke-Weaver {
  param([Parameter(ValueFromRemainingArguments = $true)][string[]]$CliArgs)
  & node $cli @CliArgs
  if ($LASTEXITCODE -ne 0) {
    throw "weaver $($CliArgs -join ' ') failed with exit $LASTEXITCODE"
  }
}

function Read-SmokeRegistry {
  Get-Content -Raw (Join-Path $env:LOCALAPPDATA "weaver\registry.json") | ConvertFrom-Json
}

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
}

$previousLocalAppData = $env:LOCALAPPDATA
New-Item -ItemType Directory -Path $scratch | Out-Null
$env:LOCALAPPDATA = Join-Path $scratch "local"

try {
  Push-Location $scratch
  try {
    Invoke-Weaver init clock
    Invoke-Weaver pack clock
    Invoke-Weaver install clock.weave

    $registry = Read-SmokeRegistry
    Assert-True (@($registry.widgets).Count -eq 1) "Archive install did not create exactly one registration"
    $first = [IO.Path]::GetFullPath([string]$registry.widgets[0].sourcePath)
    $widgetsRoot = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA "weaver\widgets"))
    Assert-True ($first.StartsWith($widgetsRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) "Archive install is not Weaver-owned: $first"
    Assert-True (Test-Path (Join-Path $first "weave.json")) "Archive install is missing weave.json"
    Assert-True (Test-Path (Join-Path $first "dist\bundle.js")) "Archive install is missing its runtime bundle"

    Invoke-Weaver install clock.weave
    $registry = Read-SmokeRegistry
    $second = [IO.Path]::GetFullPath([string]$registry.widgets[0].sourcePath)
    Assert-True ($second -ne $first) "Replacement did not publish a new immutable version"
    Assert-True (-not (Test-Path $first)) "Acknowledged replacement did not collect the old version"
    Assert-True (Test-Path (Join-Path $second "dist\bundle.js")) "Replacement version is incomplete"

    Invoke-Weaver uninstall Clock
    Assert-True (-not (Test-Path $second)) "Uninstall did not remove the archive-owned source"

    Invoke-Weaver install clock
    $registry = Read-SmokeRegistry
    $directoryOwned = [IO.Path]::GetFullPath([string]$registry.widgets[0].sourcePath)
    $workspace = [IO.Path]::GetFullPath((Join-Path $scratch "clock"))
    Assert-True ($directoryOwned -ne $workspace) "Directory install registered the developer workspace by reference"
    Assert-True (Test-Path (Join-Path $directoryOwned "weave.json")) "Directory install is not an owned artifact copy"

    Invoke-Weaver uninstall Clock
    Assert-True (-not (Test-Path $directoryOwned)) "Uninstall did not remove the directory-owned source"
    Assert-True (@((Read-SmokeRegistry).widgets).Count -eq 0) "Registry is not empty after uninstall"
  } finally {
    Pop-Location
  }
} finally {
  & node $cli down 2>$null | Out-Null
  $downExit = $LASTEXITCODE
  $env:LOCALAPPDATA = $previousLocalAppData
  if (Test-Path $scratch) {
    $resolved = [IO.Path]::GetFullPath($scratch)
    if (-not $resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
      throw "Refusing cleanup outside the temp directory: $resolved"
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
  }
  if ($downExit -ne 0) { throw "weaver down failed with exit $downExit" }
}

Write-Output "Portable install smoke passed"
