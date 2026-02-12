param(
  [string]$DmgPath,
  [string]$WorkDir = (Join-Path $PSScriptRoot "..\work"),
  [string]$CodexCliPath,
  [string]$Account,
  [string]$AccountsRoot,
  [string]$SourceHome,
  [switch]$ListAccounts,
  [switch]$Reuse,
  [switch]$NoLaunch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-Command([string]$Name) {
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "$Name not found."
  }
}

function Resolve-7z([string]$BaseDir) {
  $cmd = Get-Command 7z -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Path }
  $p1 = Join-Path $env:ProgramFiles "7-Zip\7z.exe"
  $p2 = Join-Path ${env:ProgramFiles(x86)} "7-Zip\7z.exe"
  if (Test-Path $p1) { return $p1 }
  if (Test-Path $p2) { return $p2 }
  $wg = Get-Command winget -ErrorAction SilentlyContinue
  if ($wg) {
    & winget install --id 7zip.7zip -e --source winget --accept-package-agreements --accept-source-agreements --silent | Out-Null
    if (Test-Path $p1) { return $p1 }
    if (Test-Path $p2) { return $p2 }
  }
  if (-not $BaseDir) { return $null }
  $tools = Join-Path $BaseDir "tools"
  New-Item -ItemType Directory -Force -Path $tools | Out-Null
  $sevenZipDir = Join-Path $tools "7zip"
  New-Item -ItemType Directory -Force -Path $sevenZipDir | Out-Null
  $home = "https://www.7-zip.org/"
  try { $html = (Invoke-WebRequest -Uri $home -UseBasicParsing).Content } catch { return $null }
  $extra = [regex]::Match($html, 'href="a/(7z[0-9]+-extra\.7z)"').Groups[1].Value
  if (-not $extra) { return $null }
  $extraUrl = "https://www.7-zip.org/a/$extra"
  $sevenRUrl = "https://www.7-zip.org/a/7zr.exe"
  $sevenR = Join-Path $tools "7zr.exe"
  $extraPath = Join-Path $tools $extra
  if (-not (Test-Path $sevenR)) { Invoke-WebRequest -Uri $sevenRUrl -OutFile $sevenR }
  if (-not (Test-Path $extraPath)) { Invoke-WebRequest -Uri $extraUrl -OutFile $extraPath }
  & $sevenR x -y $extraPath -o"$sevenZipDir" | Out-Null
  $p3 = Join-Path $sevenZipDir "7z.exe"
  if (Test-Path $p3) { return $p3 }
  return $null
}

function Resolve-CodexCliPath([string]$Explicit) {
  if ($Explicit) {
    if (Test-Path $Explicit) { return (Resolve-Path $Explicit).Path }
    throw "Codex CLI not found: $Explicit"
  }

  $envOverride = $env:CODEX_CLI_PATH
  if ($envOverride -and (Test-Path $envOverride)) {
    return (Resolve-Path $envOverride).Path
  }

  $candidates = @()

  try {
    $whereExe = & where.exe codex.exe 2>$null
    if ($whereExe) { $candidates += $whereExe }
    $whereCmd = & where.exe codex 2>$null
    if ($whereCmd) { $candidates += $whereCmd }
  } catch {}

  try {
    $npmRoot = (& npm root -g 2>$null).Trim()
    if ($npmRoot) {
      $arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "aarch64-pc-windows-msvc" } else { "x86_64-pc-windows-msvc" }
      $candidates += (Join-Path $npmRoot "@openai\codex\vendor\$arch\codex\codex.exe")
      $candidates += (Join-Path $npmRoot "@openai\codex\vendor\x86_64-pc-windows-msvc\codex\codex.exe")
      $candidates += (Join-Path $npmRoot "@openai\codex\vendor\aarch64-pc-windows-msvc\codex\codex.exe")
    }
  } catch {}

  foreach ($c in $candidates) {
    if (-not $c) { continue }
    if ($c -match '\.cmd$' -and (Test-Path $c)) {
      try {
        $cmdDir = Split-Path $c -Parent
        $vendor = Join-Path $cmdDir "node_modules\@openai\codex\vendor"
        if (Test-Path $vendor) {
          $found = Get-ChildItem -Recurse -Filter "codex.exe" $vendor -ErrorAction SilentlyContinue | Select-Object -First 1
          if ($found) { return (Resolve-Path $found.FullName).Path }
        }
      } catch {}
    }
    if (Test-Path $c) {
      return (Resolve-Path $c).Path
    }
  }

  return $null
}

function Write-Header([string]$Text) {
  Write-Host "`n=== $Text ===" -ForegroundColor Cyan
}

function Get-SafePathSegment([string]$Value) {
  if (-not $Value) { return $null }
  $safe = $Value.Trim().ToLowerInvariant()
  $safe = ($safe -replace "\s+", "-")
  $safe = ($safe -replace "[^a-z0-9_-]", "")
  if (-not $safe) { return $null }
  return $safe
}

function Get-AccountLayout([string]$BaseRoot, [string]$AccountName) {
  if (-not $AccountName) { return $null }
  $requested = $AccountName.Trim()
  if (-not $requested) {
    throw "Account name cannot be empty."
  }
  $safe = Get-SafePathSegment $requested
  if (-not $safe) {
    throw "Account name '$AccountName' is invalid."
  }
  $root = Join-Path $BaseRoot $safe
  return [PSCustomObject]@{
    RequestedName = $requested
    SafeName = $safe
    Root = $root
    UserData = (Join-Path $root "electron-userdata")
    Cache = (Join-Path $root "electron-cache")
    CodexHome = $root
  }
}

function Show-Accounts([string]$BaseRoot) {
  if (-not (Test-Path $BaseRoot)) {
    Write-Host "No accounts found. Accounts root does not exist: $BaseRoot" -ForegroundColor Yellow
    return
  }

  $accounts = Get-ChildItem -Path $BaseRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name
  if (-not $accounts -or $accounts.Count -eq 0) {
    Write-Host "No accounts found in: $BaseRoot" -ForegroundColor Yellow
    return
  }

  Write-Host "Accounts in $BaseRoot" -ForegroundColor Cyan
  foreach ($acct in $accounts) {
    $metaPath = Join-Path $acct.FullName "account.json"
    $label = ""
    $email = ""
    if (Test-Path $metaPath) {
      try {
        $meta = Get-Content -Raw -Path $metaPath | ConvertFrom-Json
        if ($meta -and $meta.label) { $label = [string]$meta.label }
        if ($meta -and $meta.email) { $email = [string]$meta.email }
      } catch {}
    }
    $auth = if (Test-Path (Join-Path $acct.FullName "auth.json")) { "signed in" } else { "no auth" }
    $extras = @()
    if (-not [string]::IsNullOrWhiteSpace($label)) { $extras += "label=$label" }
    if (-not [string]::IsNullOrWhiteSpace($email)) { $extras += "email=$email" }
    $extraText = if ($extras.Count -gt 0) { " | " + ($extras -join " | ") } else { "" }
    Write-Host (" - {0}: {1}{2}" -f $acct.Name, $auth, $extraText)
  }
}

function Replace-Directory([string]$SourceDir, [string]$DestinationDir) {
  if (-not (Test-Path $SourceDir)) { return $false }
  if (Test-Path $DestinationDir) {
    Remove-Item -Recurse -Force $DestinationDir
  }
  New-Item -ItemType Directory -Force -Path $DestinationDir | Out-Null
  Copy-Item -Recurse -Force (Join-Path $SourceDir "*") $DestinationDir
  return $true
}

function Sync-SharedConfigToAccount([string]$AccountHome, [string]$SourceHomePath) {
  if (-not (Test-Path $SourceHomePath)) { return }
  $srcConfig = Join-Path $SourceHomePath "config.toml"
  if (Test-Path $srcConfig) {
    Copy-Item -Force $srcConfig (Join-Path $AccountHome "config.toml")
  } elseif (-not (Test-Path (Join-Path $AccountHome "config.toml"))) {
    "" | Set-Content -Encoding utf8 -Path (Join-Path $AccountHome "config.toml")
  }
  $srcRules = Join-Path $SourceHomePath "rules"
  Replace-Directory -SourceDir $srcRules -DestinationDir (Join-Path $AccountHome "rules") | Out-Null
}

function Touch-AccountTracking([string]$AccountHome) {
  $metaPath = Join-Path $AccountHome "account.json"
  $meta = $null
  if (Test-Path $metaPath) {
    try { $meta = Get-Content -Raw -Path $metaPath | ConvertFrom-Json } catch { $meta = $null }
  }
  if (-not $meta) { $meta = [pscustomobject]@{} }
  if (-not $meta.tracking) { $meta | Add-Member -NotePropertyName tracking -NotePropertyValue ([pscustomobject]@{}) -Force }

  $nowUtc = (Get-Date).ToUniversalTime()
  $meta.tracking.last_launch_utc = $nowUtc.ToString("o")

  $fiveStart = $null
  if ($meta.tracking.five_hour_window_start_utc) {
    try { $fiveStart = [datetime]::Parse($meta.tracking.five_hour_window_start_utc).ToUniversalTime() } catch { $fiveStart = $null }
  }
  if (-not $fiveStart -or $fiveStart.AddHours(5) -le $nowUtc) {
    $meta.tracking.five_hour_window_start_utc = $nowUtc.ToString("o")
  }

  $weekStart = $null
  if ($meta.tracking.weekly_window_start_utc) {
    try { $weekStart = [datetime]::Parse($meta.tracking.weekly_window_start_utc).ToUniversalTime() } catch { $weekStart = $null }
  }
  if (-not $weekStart -or $weekStart.AddDays(7) -le $nowUtc) {
    $meta.tracking.weekly_window_start_utc = $nowUtc.ToString("o")
  }

  ($meta | ConvertTo-Json -Depth 10) | Set-Content -Encoding utf8 -Path $metaPath
}

function Patch-Preload([string]$AppDir) {
  $preload = Join-Path $AppDir ".vite\build\preload.js"
  if (-not (Test-Path $preload)) { return }
  $raw = Get-Content -Raw $preload
  $processExpose = 'const P={env:process.env,platform:process.platform,versions:process.versions,arch:process.arch,cwd:()=>process.env.PWD,argv:process.argv,pid:process.pid};n.contextBridge.exposeInMainWorld("process",P);'
  if ($raw -notlike "*$processExpose*") {
    $re = 'n\.contextBridge\.exposeInMainWorld\("codexWindowType",[A-Za-z0-9_$]+\);n\.contextBridge\.exposeInMainWorld\("electronBridge",[A-Za-z0-9_$]+\);'
    $m = [regex]::Match($raw, $re)
    if (-not $m.Success) { throw "preload patch point not found." }
    $raw = $raw.Replace($m.Value, "$processExpose$m")
    Set-Content -NoNewline -Path $preload -Value $raw
  }
}

function Copy-IfDifferent([string]$SourcePath, [string]$DestinationPath) {
  if (-not (Test-Path $SourcePath)) {
    throw "Missing patch file: $SourcePath"
  }

  $dstDir = Split-Path $DestinationPath -Parent
  New-Item -ItemType Directory -Force -Path $dstDir | Out-Null

  $srcRaw = Get-Content -Raw $SourcePath
  $dstRaw = if (Test-Path $DestinationPath) { Get-Content -Raw $DestinationPath } else { $null }
  if ($srcRaw -ne $dstRaw) {
    Set-Content -NoNewline -Path $DestinationPath -Value $srcRaw
  }
}

function Copy-WithLockTolerance([string]$SourcePath, [string]$DestinationPath, [int]$MaxRetries = 4, [int]$DelayMs = 250) {
  if (-not (Test-Path $SourcePath)) {
    throw "Source file not found: $SourcePath"
  }

  $dstDir = Split-Path $DestinationPath -Parent
  if ($dstDir) {
    New-Item -ItemType Directory -Force -Path $dstDir | Out-Null
  }

  for ($i = 0; $i -le $MaxRetries; $i++) {
    try {
      Copy-Item -Force $SourcePath $DestinationPath
      return $true
    } catch [System.IO.IOException] {
      if ($i -lt $MaxRetries) {
        Start-Sleep -Milliseconds $DelayMs
        continue
      }
      if (Test-Path $DestinationPath) {
        Write-Host "File locked, keeping existing binary: $DestinationPath" -ForegroundColor Yellow
        return $false
      }
      throw
    }
  }

  return $false
}

function Patch-MainEntryForAccountSwitcher([string]$AppDir) {
  $mainEntry = Join-Path $AppDir ".vite\build\main.js"
  if (-not (Test-Path $mainEntry)) { throw "main.js not found." }

  $raw = Get-Content -Raw $mainEntry
  if ($raw -like "*account-switcher-patch.js*") { return }

  $mapLine = "//# sourceMappingURL=main.js.map"
  if ($raw -like "*$mapLine*") {
    $raw = $raw.Replace($mapLine, "require(""./account-switcher-patch.js"");`n$mapLine")
  } else {
    $raw = "$raw`nrequire(""./account-switcher-patch.js"");"
  }

  Set-Content -NoNewline -Path $mainEntry -Value $raw
}

function Patch-PreloadForAccountSwitcher([string]$AppDir, [string]$PatchSource) {
  $preload = Join-Path $AppDir ".vite\build\preload.js"
  if (-not (Test-Path $preload)) { throw "preload.js not found." }

  $raw = Get-Content -Raw $preload
  if ($raw -like "*__codexAccountSwitcherPreloadV7*") { return }

  $snippet = Get-Content -Raw $PatchSource
  $raw = "$raw`n$snippet"
  Set-Content -NoNewline -Path $preload -Value $raw
}

function Patch-IndexForAccountSwitcher([string]$AppDir) {
  $indexPath = Join-Path $AppDir "webview\index.html"
  if (-not (Test-Path $indexPath)) { throw "webview index.html not found." }

  $raw = Get-Content -Raw $indexPath
  if ($raw -like "*account-switcher.js*") { return }

  $injection = '    <script src="./assets/account-switcher.js"></script>'
  if ($raw -notlike "*</body>*") {
    throw "webview index patch point not found."
  }

  $raw = $raw.Replace("</body>", "$injection`n  </body>")
  Set-Content -NoNewline -Path $indexPath -Value $raw
}

function Install-AccountSwitcherPatches([string]$AppDir) {
  $patchRoot = Join-Path $PSScriptRoot "patches"
  $mainPatchSource = Join-Path $patchRoot "account-switcher-main.js"
  $preloadPatchSource = Join-Path $patchRoot "account-switcher-preload.js"
  $uiPatchSource = Join-Path $patchRoot "account-switcher-ui.js"

  $mainPatchTarget = Join-Path $AppDir ".vite\build\account-switcher-patch.js"
  $uiPatchTarget = Join-Path $AppDir "webview\assets\account-switcher.js"

  Copy-IfDifferent $mainPatchSource $mainPatchTarget
  Copy-IfDifferent $uiPatchSource $uiPatchTarget
  Patch-MainEntryForAccountSwitcher $AppDir
  Patch-PreloadForAccountSwitcher $AppDir $preloadPatchSource
  Patch-IndexForAccountSwitcher $AppDir
}


function Ensure-GitOnPath() {
  $candidates = @(
    (Join-Path $env:ProgramFiles "Git\cmd\git.exe"),
    (Join-Path $env:ProgramFiles "Git\bin\git.exe"),
    (Join-Path ${env:ProgramFiles(x86)} "Git\cmd\git.exe"),
    (Join-Path ${env:ProgramFiles(x86)} "Git\bin\git.exe")
  ) | Where-Object { $_ -and (Test-Path $_) }
  if (-not $candidates -or $candidates.Count -eq 0) { return }
  $gitDir = Split-Path $candidates[0] -Parent
  if ($env:PATH -notlike "*$gitDir*") {
    $env:PATH = "$gitDir;$env:PATH"
  }
}

Ensure-Command node
Ensure-Command npm
Ensure-Command npx

foreach ($k in @("npm_config_runtime","npm_config_target","npm_config_disturl","npm_config_arch","npm_config_build_from_source")) {
  if (Test-Path "Env:$k") { Remove-Item "Env:$k" -ErrorAction SilentlyContinue }
}

if (-not $DmgPath) {
  $default = Join-Path (Resolve-Path (Join-Path $PSScriptRoot "..")) "Codex.dmg"
  if (Test-Path $default) {
    $DmgPath = $default
  } else {
    $cand = Get-ChildItem -Path (Resolve-Path (Join-Path $PSScriptRoot "..")) -Filter "*.dmg" -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cand) {
      $DmgPath = $cand.FullName
    } else {
      throw "No DMG found."
    }
  }
}

$DmgPath = (Resolve-Path $DmgPath).Path
$WorkDir = (Resolve-Path (New-Item -ItemType Directory -Force -Path $WorkDir)).Path

if (-not $AccountsRoot) {
  $AccountsRoot = Join-Path $HOME ".codex-accounts"
}
$AccountsRoot = (Resolve-Path (New-Item -ItemType Directory -Force -Path $AccountsRoot)).Path

if (-not $SourceHome) {
  $SourceHome = Join-Path $HOME ".codex"
}
if (Test-Path $SourceHome) {
  $SourceHome = (Resolve-Path $SourceHome).Path
} else {
  $SourceHome = (Join-Path $HOME ".codex")
}

if ($ListAccounts) {
  Write-Header "Available accounts"
  Show-Accounts $AccountsRoot
  return
}

$sevenZip = Resolve-7z $WorkDir
if (-not $sevenZip) { throw "7z not found." }

$extractedDir = Join-Path $WorkDir "extracted"
$electronDir  = Join-Path $WorkDir "electron"
$appDir       = Join-Path $WorkDir "app"
$nativeDir    = Join-Path $WorkDir "native-builds"

$accountLayout = Get-AccountLayout $AccountsRoot $Account
if ($accountLayout) {
  $userDataDir = $accountLayout.UserData
  $cacheDir = $accountLayout.Cache
} else {
  $userDataDir = Join-Path $WorkDir "userdata"
  $cacheDir = Join-Path $WorkDir "cache"
}

if (-not $Reuse) {
  Write-Header "Extracting DMG"
  New-Item -ItemType Directory -Force -Path $extractedDir | Out-Null
  & $sevenZip x -y $DmgPath -o"$extractedDir" | Out-Null

  Write-Header "Extracting app.asar"
  New-Item -ItemType Directory -Force -Path $electronDir | Out-Null
  $hfs = Join-Path $extractedDir "4.hfs"
  if (Test-Path $hfs) {
    & $sevenZip x -y $hfs "Codex Installer/Codex.app/Contents/Resources/app.asar" "Codex Installer/Codex.app/Contents/Resources/app.asar.unpacked" -o"$electronDir" | Out-Null
  } else {
    $directApp = Join-Path $extractedDir "Codex Installer\Codex.app\Contents\Resources\app.asar"
    if (-not (Test-Path $directApp)) {
      throw "app.asar not found."
    }
    $directUnpacked = Join-Path $extractedDir "Codex Installer\Codex.app\Contents\Resources\app.asar.unpacked"
    New-Item -ItemType Directory -Force -Path (Split-Path $directApp -Parent) | Out-Null
    $destBase = Join-Path $electronDir "Codex Installer\Codex.app\Contents\Resources"
    New-Item -ItemType Directory -Force -Path $destBase | Out-Null
    Copy-Item -Force $directApp (Join-Path $destBase "app.asar")
    if (Test-Path $directUnpacked) {
      & robocopy $directUnpacked (Join-Path $destBase "app.asar.unpacked") /E /NFL /NDL /NJH /NJS /NC /NS | Out-Null
    }
  }

  Write-Header "Unpacking app.asar"
  New-Item -ItemType Directory -Force -Path $appDir | Out-Null
  $asar = Join-Path $electronDir "Codex Installer\Codex.app\Contents\Resources\app.asar"
  if (-not (Test-Path $asar)) { throw "app.asar not found." }
  & npx --yes @electron/asar extract $asar $appDir

  Write-Header "Syncing app.asar.unpacked"
  $unpacked = Join-Path $electronDir "Codex Installer\Codex.app\Contents\Resources\app.asar.unpacked"
  if (Test-Path $unpacked) {
    & robocopy $unpacked $appDir /E /NFL /NDL /NJH /NJS /NC /NS | Out-Null
  }
}

Write-Header "Patching preload"
Patch-Preload $appDir

Write-Header "Installing account switcher"
Install-AccountSwitcherPatches $appDir

Write-Header "Reading app metadata"
$pkgPath = Join-Path $appDir "package.json"
if (-not (Test-Path $pkgPath)) { throw "package.json not found." }
$pkg = Get-Content -Raw $pkgPath | ConvertFrom-Json
$electronVersion = $pkg.devDependencies.electron
$betterVersion = $pkg.dependencies."better-sqlite3"
$ptyVersion = $pkg.dependencies."node-pty"

if (-not $electronVersion) { throw "Electron version not found." }

Write-Header "Preparing native modules"
$arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "win32-arm64" } else { "win32-x64" }
$bsDst = Join-Path $appDir "node_modules\better-sqlite3\build\Release\better_sqlite3.node"
$ptyDstPre = Join-Path $appDir "node_modules\node-pty\prebuilds\$arch"
$skipNative = $Reuse -and (Test-Path $bsDst) -and (Test-Path (Join-Path $ptyDstPre "pty.node"))
if ($skipNative) {
  Write-Host "Native modules already present in app. Skipping rebuild." -ForegroundColor Cyan
} else {
New-Item -ItemType Directory -Force -Path $nativeDir | Out-Null
Push-Location $nativeDir
if (-not (Test-Path (Join-Path $nativeDir "package.json"))) {
  & npm init -y | Out-Null
}

$bsSrcProbe = Join-Path $nativeDir "node_modules\better-sqlite3\build\Release\better_sqlite3.node"
$ptySrcProbe = Join-Path $nativeDir "node_modules\node-pty\prebuilds\$arch\pty.node"
$electronExe = Join-Path $nativeDir "node_modules\electron\dist\electron.exe"
$haveNative = (Test-Path $bsSrcProbe) -and (Test-Path $ptySrcProbe) -and (Test-Path $electronExe)

if (-not $haveNative) {
  $deps = @(
    "better-sqlite3@$betterVersion",
    "node-pty@$ptyVersion",
    "@electron/rebuild",
    "prebuild-install",
    "electron@$electronVersion"
  )
  & npm install --no-save @deps
  if ($LASTEXITCODE -ne 0) { throw "npm install failed." }
  $electronExe = Join-Path $nativeDir "node_modules\electron\dist\electron.exe"
} else {
  Write-Host "Native modules already present. Skipping rebuild." -ForegroundColor Cyan
}

Write-Host "Rebuilding native modules for Electron $electronVersion..." -ForegroundColor Cyan
$rebuildOk = $true
if (-not $haveNative) {
  try {
    $rebuildCli = Join-Path $nativeDir "node_modules\@electron\rebuild\lib\cli.js"
    if (-not (Test-Path $rebuildCli)) { throw "electron-rebuild not found." }
    & node $rebuildCli -v $electronVersion -w "better-sqlite3,node-pty" | Out-Null
  } catch {
    $rebuildOk = $false
    Write-Host "electron-rebuild failed: $($_.Exception.Message)" -ForegroundColor Yellow
  }
}

if (-not $rebuildOk -and -not $haveNative) {
  Write-Host "Trying prebuilt Electron binaries for better-sqlite3..." -ForegroundColor Yellow
  $bsDir = Join-Path $nativeDir "node_modules\better-sqlite3"
  if (Test-Path $bsDir) {
    Push-Location $bsDir
    $prebuildCli = Join-Path $nativeDir "node_modules\prebuild-install\bin.js"
    if (-not (Test-Path $prebuildCli)) { throw "prebuild-install not found." }
    & node $prebuildCli -r electron -t $electronVersion --tag-prefix=electron-v | Out-Null
    Pop-Location
  }
}

$env:ELECTRON_RUN_AS_NODE = "1"
if (-not (Test-Path $electronExe)) { throw "electron.exe not found." }
if (-not (Test-Path (Join-Path $nativeDir "node_modules\better-sqlite3"))) {
  throw "better-sqlite3 not installed."
}
& $electronExe -e "try{require('./node_modules/better-sqlite3');process.exit(0)}catch(e){console.error(e);process.exit(1)}" | Out-Null
Remove-Item Env:ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue
if ($LASTEXITCODE -ne 0) { throw "better-sqlite3 failed to load." }

Pop-Location

$bsSrc = Join-Path $nativeDir "node_modules\better-sqlite3\build\Release\better_sqlite3.node"
$bsDstDir = Split-Path $bsDst -Parent
New-Item -ItemType Directory -Force -Path $bsDstDir | Out-Null
if (-not (Test-Path $bsSrc)) { throw "better_sqlite3.node not found." }
$bsDstFile = Join-Path $bsDstDir "better_sqlite3.node"
Copy-WithLockTolerance -SourcePath $bsSrc -DestinationPath $bsDstFile | Out-Null

$ptySrcDir = Join-Path $nativeDir "node_modules\node-pty\prebuilds\$arch"
$ptyDstRel = Join-Path $appDir "node_modules\node-pty\build\Release"
New-Item -ItemType Directory -Force -Path $ptyDstPre | Out-Null
New-Item -ItemType Directory -Force -Path $ptyDstRel | Out-Null

$ptyFiles = @("pty.node", "conpty.node", "conpty_console_list.node")
foreach ($f in $ptyFiles) {
  $src = Join-Path $ptySrcDir $f
  if (Test-Path $src) {
    Copy-WithLockTolerance -SourcePath $src -DestinationPath (Join-Path $ptyDstPre $f) | Out-Null
    Copy-WithLockTolerance -SourcePath $src -DestinationPath (Join-Path $ptyDstRel $f) | Out-Null
  }
}
}

if (-not $NoLaunch) {
  Write-Header "Resolving Codex CLI"
  $cli = Resolve-CodexCliPath $CodexCliPath
  if (-not $cli) {
    throw "codex.exe not found."
  }

  Write-Header "Launching Codex"
  $rendererUrl = (New-Object System.Uri (Join-Path $appDir "webview\index.html")).AbsoluteUri
  Remove-Item Env:ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue
  $env:ELECTRON_RENDERER_URL = $rendererUrl
  $env:ELECTRON_FORCE_IS_PACKAGED = "1"
  $buildNumber = if ($pkg.PSObject.Properties.Name -contains "codexBuildNumber" -and $pkg.codexBuildNumber) { $pkg.codexBuildNumber } else { "510" }
  $buildFlavor = if ($pkg.PSObject.Properties.Name -contains "codexBuildFlavor" -and $pkg.codexBuildFlavor) { $pkg.codexBuildFlavor } else { "prod" }
  $env:CODEX_BUILD_NUMBER = $buildNumber
  $env:CODEX_BUILD_FLAVOR = $buildFlavor
  $env:BUILD_FLAVOR = $buildFlavor
  $env:NODE_ENV = "production"
  $env:CODEX_CLI_PATH = $cli
  $env:CODEX_ACCOUNTS_ROOT = $AccountsRoot
  $env:CODEX_ACCOUNTS_SOURCE_HOME = $SourceHome
  $env:PWD = $appDir
  Ensure-GitOnPath

  New-Item -ItemType Directory -Force -Path $userDataDir | Out-Null
  New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
  if ($accountLayout) {
    New-Item -ItemType Directory -Force -Path $accountLayout.CodexHome | Out-Null
    Sync-SharedConfigToAccount -AccountHome $accountLayout.CodexHome -SourceHomePath $SourceHome
    Touch-AccountTracking -AccountHome $accountLayout.CodexHome
    $env:CODEX_HOME = $accountLayout.CodexHome
    $env:CODEX_ACCOUNTS_CURRENT = $accountLayout.SafeName
    Write-Host "Using account profile '$($accountLayout.RequestedName)' ($($accountLayout.SafeName))." -ForegroundColor Cyan
  } else {
    if (-not $env:CODEX_HOME) {
      Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue
    }
    Remove-Item Env:CODEX_ACCOUNTS_CURRENT -ErrorAction SilentlyContinue
  }

  Start-Process -FilePath $electronExe -ArgumentList "$appDir","--enable-logging","--user-data-dir=`"$userDataDir`"","--disk-cache-dir=`"$cacheDir`"" -NoNewWindow -Wait
}
