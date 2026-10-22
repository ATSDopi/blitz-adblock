#requires -Version 5.1
<#
.SYNOPSIS
  Blitz Ad-Block patcher - blocks ads + hides empty ad slots in the Blitz.gg
  desktop app (Electron), and survives Blitz updates.

.DESCRIPTION
  Modes:
    -Install   First run (patch-blitz.bat): auto-detects the Blitz install,
               self-installs this kit to %APPDATA%\Blitz\patch-kit, patches,
               creates the "Blitz (patched)" desktop shortcut, launches Blitz.
    -Auto      Used by the desktop shortcut: checks patch state, re-patches if
               a Blitz update wiped it, then launches Blitz.
    -Check     Report state only, change nothing.
    -Force     Re-patch even if everything looks OK.
    -BlitzDir  Explicit Blitz install directory (skips auto-detection).
    -NoLaunch  Do not start Blitz at the end.
    -Launch    After work, wait and verify Blitz is alive + adblock loaded.

  No external dependency: asar tooling is vendored in .\node_modules, the
  xxHash32 needed by Blitz's VerifyApp integrity check is compiled inline via
  Add-Type. If no 'node' is on PATH, Blitz.exe itself is used as the Node
  runtime (ELECTRON_RUN_AS_NODE=1).
#>
param(
  [switch]$Install,
  [switch]$Auto,
  [switch]$Check,
  [switch]$Force,
  [switch]$Launch,
  [switch]$NoLaunch,
  [string]$BlitzDir
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# A stray ELECTRON_RUN_AS_NODE exported by dev shells would turn Blitz.exe
# into a bare node process and break every launch.
Remove-Item Env:\ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue

$Script:Root    = $PSScriptRoot
$Script:KitDir  = Join-Path $env:APPDATA 'Blitz\patch-kit'
$Script:Work    = Join-Path $Script:KitDir 'work'
$Script:CfgFile = Join-Path $Script:KitDir 'install-dir.txt'
$Script:Marker  = 'Adblock engine loaded'

function Say($m, $c = 'Gray') { Write-Host "[blitz-patch] $m" -ForegroundColor $c }
function Fail($m) { Say $m 'Red'; exit 1 }

# ---------------------------------------------------------------- xxHash32 --
# Blitz's VerifyApp (main.js in app.asar) compares xxHash32(app.asar) against a
# uint32 stored in the LAST 4 BYTES of icudtl.dat. We recompute it after repack.
$xxSrc = @'
public static class XXH32 {
  static uint Rotl(uint x,int r){return (x<<r)|(x>>(32-r));}
  public static uint Hash(byte[] b){
    const uint P1=2654435761u,P2=2246822519u,P3=3266489917u,P4=668265263u,P5=374761393u;
    int i=0,n=b.Length; uint h;
    unchecked {
    if(n>=16){
      uint v1=P1+P2,v2=P2,v3=0,v4=0-P1;
      while(i<=n-16){
        v1=Rotl(v1+System.BitConverter.ToUInt32(b,i)*P2,13)*P1; i+=4;
        v2=Rotl(v2+System.BitConverter.ToUInt32(b,i)*P2,13)*P1; i+=4;
        v3=Rotl(v3+System.BitConverter.ToUInt32(b,i)*P2,13)*P1; i+=4;
        v4=Rotl(v4+System.BitConverter.ToUInt32(b,i)*P2,13)*P1; i+=4;
      }
      h=Rotl(v1,1)+Rotl(v2,7)+Rotl(v3,12)+Rotl(v4,18);
    } else h=P5;
    h+=(uint)n;
    while(i<=n-4){h+=System.BitConverter.ToUInt32(b,i)*P3; h=Rotl(h,17)*P4; i+=4;}
    while(i<n){h+=b[i]*P5; h=Rotl(h,11)*P1; i++;}
    h=(h^(h>>15))*P2; h=(h^(h>>13))*P3; return h^(h>>16);
    }
  }
}
'@
Add-Type -TypeDefinition $xxSrc -Language CSharp

# ------------------------------------------------------------ small utils --
function Get-TailHash([string]$Path) {
  $fs = [IO.File]::Open($Path, 'Open', 'ReadWrite')
  try { $fs.Seek(-4, 'End') | Out-Null; $b = New-Object byte[] 4; $fs.Read($b, 0, 4) | Out-Null; return [BitConverter]::ToUInt32($b, 0) }
  finally { $fs.Close() }
}
function Set-TailHash([string]$Path, [uint32]$h) {
  $fs = [IO.File]::Open($Path, 'Open', 'ReadWrite')
  try { $fs.Seek(-4, 'End') | Out-Null; $fs.Write([BitConverter]::GetBytes($h), 0, 4) }
  finally { $fs.Close() }
}
function Test-AsarPatched([string]$Path) {
  $bytes = [IO.File]::ReadAllBytes($Path)
  return [Text.Encoding]::ASCII.GetString($bytes).Contains($Script:Marker)
}
# "unpacked" entries of the asar header JSON (needed to sync app.asar.unpacked)
function Get-AsarUnpacked([string]$Path) {
  $fs = [IO.File]::OpenRead($Path)
  $hdr = New-Object byte[] ([Math]::Min($fs.Length, 4MB))
  $fs.Read($hdr, 0, $hdr.Length) | Out-Null
  $fs.Close()
  $anchor = [Text.Encoding]::UTF8.GetBytes('{"files"')
  $jOff = -1
  for ($k = 0; $k -lt [Math]::Min(64, $hdr.Length - 8); $k++) {
    $ok = $true
    for ($m = 0; $m -lt $anchor.Length; $m++) { if ($hdr[$k + $m] -ne $anchor[$m]) { $ok = $false; break } }
    if ($ok) { $jOff = $k; break }
  }
  if ($jOff -lt 4) { Fail 'asar header not found - unsupported layout' }
  $jsonLen = [BitConverter]::ToUInt32($hdr, $jOff - 4)
  if ($jOff + $jsonLen -gt $hdr.Length) {
    $fs = [IO.File]::OpenRead($Path)
    $hdr = New-Object byte[] ($jOff + $jsonLen)
    $fs.Read($hdr, 0, $hdr.Length) | Out-Null
    $fs.Close()
  }
  $root = [Text.Encoding]::UTF8.GetString($hdr, $jOff, $jsonLen) | ConvertFrom-Json
  $out = New-Object System.Collections.Generic.List[string]
  function Walk($node, $prefix) {
    foreach ($p in $node.files.PSObject.Properties) {
      $rel = if ($prefix) { "$prefix\$($p.Name)" } else { $p.Name }
      if ($p.Value.PSObject.Properties['files']) { Walk $p.Value $rel }
      elseif ($p.Value.PSObject.Properties['unpacked'] -and $p.Value.unpacked) { $out.Add($rel) }
    }
  }
  Walk $root ''
  return $out
}

# ------------------------------------------------------- injected JS blocks --
# NOTE: the money-mouth emoji Blitz uses in ad-slot class names is written as
# \u{1F911} escapes so this file stays pure ASCII (encoding-proof).
$HeadBlock = @'
let adblockEngine;
function getAdblockEngine() {
  if (adblockEngine !== undefined) return adblockEngine;
  try {
    const fs = require("fs");
    const { FiltersEngine } = require("./adblocker.umd.min.js");
    const filters =
      fs.readFileSync(require.resolve("./easylist.txt"), "utf-8") +
      "\n" +
      fs.readFileSync(require.resolve("./easyprivacy.txt"), "utf-8") +
      "\n" +
      fs.readFileSync(require.resolve("./ublock-ads.txt"), "utf-8") +
      "\n" +
      fs.readFileSync(require.resolve("./ublock-privacy.txt"), "utf-8") +
      "\n" +
      fs.readFileSync(require.resolve("./peter-lowe-list.txt"), "utf-8") +
      "\ngoogleoptimize.com\n";
    adblockEngine = FiltersEngine.parse(filters);
    log.info("[core]", "Adblock engine loaded.");
  } catch (error) {
    adblockEngine = null;
    log.error("[core]", "adblock init failed", error);
  }
  return adblockEngine;
}

const COSMETIC_CSS = `
  [class*="\u{1F911}"], .leaderboard-promo, .blitz3-promo,
  .advertisement, .promotion,
  [data-primis-placement-id], [id^="qc-cmp2"],
  a[href*="/premium?"][href*="ref=right-rail-ads"],
  a[href*="/premium?"]:has(img[src*="/self-promotion/premium/"]),
  a[href*="/premium?"]:has(img[src*="/blitz/premium/cta/"])
    { display: none !important; }
  main.blitz-app:has(> [class~="\u{1F911}-wrapper"]), :root, main
    { --right-rail-width: 0px !important; --rail-gap: 0px !important; }
`;

'@

$BodyBlock = @'

  const attachCosmetics = () => {
    if (window.isDestroyed()) return;
    const wc = window.browserView && window.browserView.webContents;
    if (!wc) return setTimeout(attachCosmetics, 250);
    if (wc.__blitzCosmetics) return;
    wc.__blitzCosmetics = true;
    const userDir = app.getPath("userData");
    const fs = require("fs");
    const path = require("path");
    const userCssPath = path.join(userDir, "user.css");
    const userJsPath = path.join(userDir, "user.js");
    if (fs.existsSync(userCssPath))
      log.info("[core]", "user.css detected, will inject on dom-ready");
    if (fs.existsSync(userJsPath))
      log.info("[core]", "user.js detected, will inject on dom-ready");
    const inject = () => {
      let userCss = "";
      let userJs = "";
      try {
        userCss = fs.readFileSync(userCssPath, "utf-8");
      } catch (e) {}
      try {
        userJs = fs.readFileSync(userJsPath, "utf-8");
      } catch (e) {}
      wc.executeJavaScript(`(() => {
        const __css = ${JSON.stringify(COSMETIC_CSS)};
        const __ucss = ${JSON.stringify(userCss)};
        const __sel = '[class*="\\u{1F911}"], .advertisement, .promotion, .leaderboard-promo, .blitz3-promo, [data-primis-placement-id], [id^="qc-cmp2"]';
        const add = (id, text) => {
          let st = document.getElementById(id);
          if (!st) {
            st = document.createElement("style");
            st.id = id;
            (document.head || document.documentElement).appendChild(st);
          }
          if (st.textContent !== text) st.textContent = text;
        };
        const applyAll = () => {
          add("blitz-cosmetic-css", __css);
          if (__ucss.trim()) add("blitz-user-css", __ucss);
          for (const e of document.querySelectorAll(__sel)) {
            if (e.style.display !== "none") e.style.setProperty("display", "none", "important");
          }
        };
        applyAll();
        if (!window.__blitzCosmoObs) {
          window.__blitzCosmoObs = true;
          let t;
          new MutationObserver(() => {
            if (t) return;
            t = setTimeout(() => { t = null; applyAll(); }, 200);
          }).observe(document.documentElement, { childList: true, subtree: true });
        }
        try { ${userJs} } catch (e) {}
      })()`).catch(() => {});
    };
    wc.on("dom-ready", inject);
    wc.on("did-navigate", inject);
    wc.on("did-frame-finish-load", inject);
    inject();
    setTimeout(inject, 1500);
    setTimeout(inject, 4000);
  };
  setImmediate(attachCosmetics);

  const engine = getAdblockEngine();
  if (engine) {
    const { Request } = require("./adblocker.umd.min.js");
    window.webContents.session.webRequest.onBeforeRequest(
      { urls: ["*://*/*"] },
      (details, callback) => {
        const { match } = engine.match(
          Request.fromRawDetails({ url: details.url })
        );
        if (match === true) {
          log.info("[core]", "ADBLOCK BLOCKED:", details.url);
        }
        callback({ cancel: match === true });
      }
    );
  }
'@

# Deadlock handler fixes (upstream bugs we repair while we are in there).
$DlOrigPath = @'
      const oldPath = "common\\Project8Staging\\game\\bin\\win64\\deadlock.exe";
      const newPath = "common\\Deadlock\\game\\bin\\win64\\deadlock.exe";
      const manifestFile = "appmanifest_1422450.acf";

      // Determine the version path based on the process path
      let versionPath;
      if (deadlockProcess.path.includes(oldPath)) {
        versionPath = deadlockProcess.path.replace(oldPath, manifestFile);
      } else if (deadlockProcess.path.includes(newPath)) {
        versionPath = deadlockProcess.path.replace(newPath, manifestFile);
        log.warn("[core] [deadlock]", "Using secondary path for Project8.");
      } else {
        return log.error("[core] [deadlock]", "path not found.");
      }
'@ -replace "`r`n", "`n"

$DlNewPath = @'
      const manifestFile = "appmanifest_1422450.acf";
      // Normalize separators/case: ps-list can return either form and the
      // strict substring match used to fail with "path not found."
      const normalizedPath = deadlockProcess.path.replace(/\//g, "\\");
      const pathMatch = normalizedPath.match(
        /common\\(Project8Staging|Deadlock)\\game\\bin\\win64\\deadlock\.exe$/i
      );
      if (!pathMatch) {
        return log.error("[core] [deadlock]", "path not found.");
      }
      const versionPath =
        normalizedPath.slice(0, pathMatch.index) + manifestFile;
      if (pathMatch[1].toLowerCase() === "deadlock") {
        log.warn("[core] [deadlock]", "Using secondary path for Project8.");
      }
'@ -replace "`r`n", "`n"

$DlOrigFetch = @'
    // Fetch deadlock offsets
    const responseOffsets = await axios.get(
      `https://blitz-native.blitz.gg/${pathMode}/deadlock/${version}.json`
    );
'@ -replace "`r`n", "`n"

$DlNewFetch = @'
    // Fetch deadlock offsets (retry: CDN 403s transiently while Blitz
    // propagates offsets for a fresh game build)
    let responseOffsets;
    for (let attempt = 1; attempt <= 4; attempt++) {
      try {
        responseOffsets = await axios.get(
          `https://blitz-native.blitz.gg/${pathMode}/deadlock/${version}.json`
        );
        break;
      } catch (fetchError) {
        if (attempt === 4) throw fetchError;
        log.warn(
          "[core] [deadlock]",
          `Offsets fetch failed (${fetchError.message}), retry ${attempt}/3...`
        );
        await sleep(4000 * attempt);
      }
    }
'@ -replace "`r`n", "`n"

# ---------------------------------------------------------- Blitz detection --
function Resolve-BlitzDir {
  if ($BlitzDir) { return $BlitzDir }

  # 1. saved location from a previous -Install
  if (Test-Path $Script:CfgFile) {
    $saved = (Get-Content $Script:CfgFile -Raw).Trim()
    if ($saved -and (Test-Path (Join-Path $saved 'Blitz.exe'))) { return $saved }
  }
  # 2. default electron-updater location
  $def = Join-Path $env:LOCALAPPDATA 'Programs\Blitz'
  if (Test-Path (Join-Path $def 'Blitz.exe')) { return $def }
  # 3. uninstall registry keys
  foreach ($root in 'HKCU:', 'HKLM:') {
    foreach ($keyPath in "$root\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*") {
      try {
        $k = Get-ItemProperty $keyPath -ErrorAction SilentlyContinue
        if ($k.DisplayName -match 'blitz' -and $k.InstallLocation -and (Test-Path (Join-Path $k.InstallLocation 'Blitz.exe'))) {
          return $k.InstallLocation.TrimEnd('\')
        }
      } catch {}
    }
  }
  # 4. interactive fallback (install mode only - never block the shortcut)
  if ($Install -and -not $Auto) {
    Say 'Blitz introuvable automatiquement.' 'Yellow'
    $manual = Read-Host 'Chemin du dossier Blitz (contenant Blitz.exe), ex: C:\...\Programs\Blitz'
    if ($manual -and (Test-Path (Join-Path $manual.Trim('"') 'Blitz.exe'))) { return $manual.Trim('"').TrimEnd('\') }
  }
  return $null
}

# ------------------------------------------------------------- node runtime --
function Resolve-NodeRuntime {
  $n = (Get-Command node -ErrorAction SilentlyContinue).Source
  if ($n) { return @{ Exe = $n; EnvNode = $false } }
  $blitzExe = Join-Path $Script:BlitzDir 'Blitz.exe'
  if (Test-Path $blitzExe) { return @{ Exe = $blitzExe; EnvNode = $true } }
  return $null
}
function Invoke-Asar([string[]]$AsarArgs) {
  $nj = Resolve-NodeRuntime
  if (-not $nj) { Fail 'No JS runtime: install Node.js or keep Blitz.exe next to the patcher.' }
  $asarJs = Join-Path $Script:Root 'node_modules\asar\bin\asar.js'
  if ($nj.EnvNode) {
    # Blitz.exe doubles as a full Node runtime (embedded Electron node).
    $env:ELECTRON_RUN_AS_NODE = '1'
    try { & $nj.Exe $asarJs @AsarArgs | Out-Null }
    finally { Remove-Item Env:\ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue }
  } else {
    & $nj.Exe $asarJs @AsarArgs | Out-Null
  }
  return ($LASTEXITCODE -eq 0)
}

# --------------------------------------------------------------- kit install --
function Install-Kit {
  New-Item -ItemType Directory -Force $Script:KitDir | Out-Null
  foreach ($item in 'blitz-patch.ps1', 'patch-blitz.bat', 'payload', 'node_modules') {
    $src = Join-Path $Script:Root $item
    if (Test-Path $src) { Copy-Item $src $Script:KitDir -Recurse -Force }
  }
  [IO.File]::WriteAllText($Script:CfgFile, $Script:BlitzDir)
  Say "kit installe -> $Script:KitDir" 'Green'
}

function New-PatchedShortcut {
  $lnkName = 'Blitz (patched).lnk'
  $target  = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
  $args    = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}\blitz-patch.ps1" -Auto -Launch' -f $Script:KitDir
  $icon    = Join-Path $Script:BlitzDir 'Blitz.exe'
  $ws      = New-Object -ComObject WScript.Shell
  foreach ($dir in @([Environment]::GetFolderPath('Desktop'),
                    [Environment]::GetFolderPath('Programs'))) {
    $sc = $ws.CreateShortcut((Join-Path $dir $lnkName))
    $sc.TargetPath       = $target
    $sc.Arguments        = $args
    $sc.WorkingDirectory = $Script:BlitzDir
    $sc.IconLocation     = "$icon,0"
    $sc.Description      = 'Launch Blitz with the ad-block patch (auto re-patch after updates)'
    $sc.Save()
  }
  Say 'raccourci "Blitz (patched)" cree (Bureau + Menu Demarrer)' 'Green'
}

# =================================================================== main ==
if ($Install) {
  Say '--- installation ---' 'Cyan'
  $Script:BlitzDir = Resolve-BlitzDir
  if (-not $Script:BlitzDir) { Fail 'Blitz install not found - re-run with -BlitzDir "C:\path\to\Blitz"' }
  Say "Blitz: $Script:BlitzDir" 'Green'
  if (-not (Test-Path (Join-Path $Script:BlitzDir 'resources\app.asar'))) { Fail "app.asar absent sous $($Script:BlitzDir)\resources" }
  Install-Kit
  New-PatchedShortcut
  # Fall through: run the actual patch below with the freshly installed state.
  $Auto = $true; $Launch = $true
} else {
  $Script:BlitzDir = Resolve-BlitzDir
  if (-not $Script:BlitzDir) { Fail 'Blitz install not found - run patch-blitz.bat first, or pass -BlitzDir' }
}

$Res  = Join-Path $Script:BlitzDir 'resources'
$Asar = Join-Path $Res 'app.asar'
$Icu  = Join-Path $Script:BlitzDir 'icudtl.dat'
if (-not (Test-Path $Asar)) { Fail "app.asar introuvable: $Asar" }
if (-not (Test-Path $Icu))  { Fail "icudtl.dat introuvable: $Icu" }

$patched  = Test-AsarPatched $Asar
$hashAsar = [XXH32]::Hash([IO.File]::ReadAllBytes($Asar))
$hashTail = Get-TailHash $Icu
Say ('app.asar : patch={0} xxh32={1:x8} | icudtl tail={2:x8}' -f $patched, $hashAsar, $hashTail)

if (-not $Force -and $patched -and $hashAsar -eq $hashTail) {
  Say 'Patch deja en place, rien a faire.' 'Green'
} elseif (-not $Force -and $patched -and $hashAsar -ne $hashTail) {
  Say 'Patch present mais hash icudtl perime -> reecriture du hash seul.' 'Yellow'
  if (-not $Check) { Set-TailHash $Icu $hashAsar; Say ('icudtl tail <- {0:x8}' -f $hashAsar) 'Green' }
} elseif ($Check) {
  Say 'CHECK: patch manquant - une re-application serait necessaire.' 'Yellow'
  exit 2
} else {
  Say 'Patch manquant - application...' 'Cyan'

  Get-Process | Where-Object { $_.Name -match 'blitz' } | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep 1

  # Backups (.orig kept for restore / uninstall)
  if (-not (Test-Path "$Asar.orig")) { Copy-Item $Asar "$Asar.orig"; Say 'backup -> app.asar.orig' }
  if (-not (Test-Path "$Icu.orig"))  { Copy-Item $Icu  "$Icu.orig";  Say 'backup -> icudtl.dat.orig' }

  # Extract
  if (Test-Path $Script:Work) { Remove-Item $Script:Work -Recurse -Force }
  if (-not (Invoke-Asar @('extract', $Asar, "$Script:Work\extracted"))) { Fail 'extraction asar echouee' }
  if (-not (Test-Path "$Script:Work\extracted\src\electronWindowHandlers.js")) { Fail 'extraction incomplete (electronWindowHandlers.js absent)' }
  Say 'asar extrait'

  # ---- patch electronWindowHandlers.js (robust anchors) ----
  $ewhPath = "$Script:Work\extracted\src\electronWindowHandlers.js"
  $ewh = [IO.File]::ReadAllText($ewhPath) -replace "`r`n", "`n"
  if ($ewh.Contains($Script:Marker)) { Say 'deja patche (marker present)' }
  else {
    $sig = 'function interceptRequests(window) {'
    $docAnchor = "/**`n * @param {Electron.BrowserWindow} window`n */`n" + $sig
    $di = $ewh.IndexOf($docAnchor)
    if ($di -lt 0) { $di = $ewh.IndexOf($sig) }  # fallback: right before the signature
    if ($di -lt 0) { Say 'ANCRE MANQUANTE: interceptRequests introuvable - patch adblock NON applique.' 'Red' }
    else {
      $ewh = $ewh.Insert($di, $HeadBlock)
      $si = $ewh.IndexOf($sig)
      if ($si -lt 0) { Say 'ANCRE signature perdue - abort ewh.' 'Red' }
      else { $ewh = $ewh.Insert($si + $sig.Length, $BodyBlock) }
      [IO.File]::WriteAllText($ewhPath, $ewh)
      if ($ewh.Contains($Script:Marker) -and $ewh.Contains('COSMETIC_CSS')) { Say 'electronWindowHandlers.js patche' 'Green' }
      else { Say 'ATTENTION: insertion incomplete dans ewh.' 'Red' }
    }
  }

  # ---- patch deadlock/index.js (best-effort, non bloquant) ----
  $dlPath = "$Script:Work\extracted\src\gameHandlers\deadlock\index.js"
  if (Test-Path $dlPath) {
    $dl = [IO.File]::ReadAllText($dlPath) -replace "`r`n", "`n"
    if (-not $dl.Contains('pathMatch')) { $dl = $dl.Replace($DlOrigPath, $DlNewPath) }
    if ($dl -match 'const responseOffsets = await axios\.get\(') { $dl = $dl.Replace($DlOrigFetch, $DlNewFetch) }
    [IO.File]::WriteAllText($dlPath, $dl)
    if ($dl.Contains('pathMatch') -and $dl.Contains('attempt <= 4')) { Say 'deadlock/index.js patche' 'Green' }
    else { Say 'deadlock/index.js: ancres modifiees upstream - ignore (non bloquant).' 'Yellow' }
  }

  # Payload (engine + filter lists)
  Copy-Item (Join-Path $Script:Root 'payload\*') "$Script:Work\extracted\src\" -Force
  Say 'payload copie (adblocker + 5 listes)'

  # Repack preserving the original unpacked layout
  $newAsar = "$Asar.new"
  if (-not (Invoke-Asar @('pack', "$Script:Work\extracted", $newAsar, '--unpack', '*.node', '--unpack-dir', 'node_modules\lzma-native'))) { Fail 'repack asar echoue' }
  if (-not (Test-Path $newAsar)) { Fail 'repack asar echoue (sortie absente)' }

  # Sync unpacked entries to resources\app.asar.unpacked
  $miss = 0
  foreach ($rel in (Get-AsarUnpacked $newAsar)) {
    $dst = Join-Path $Res "app.asar.unpacked\$rel"
    if (-not (Test-Path $dst)) {
      $src = Join-Path "$Script:Work\extracted" $rel
      if (Test-Path $src) { New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null; Copy-Item $src $dst -Force; $miss++ }
    }
  }
  if ($miss) { Say "$miss fichier(s) unpacked synchronises" }
  Move-Item $newAsar $Asar -Force

  # VerifyApp: write the new xxHash32 into the icudtl.dat tail
  $h2 = [XXH32]::Hash([IO.File]::ReadAllBytes($Asar))
  Set-TailHash $Icu $h2
  Say ('icudtl tail <- {0:x8}' -f $h2) 'Green'
  Say 'Patch applique.' 'Green'
}

# ------------------------------------------------------------- launch/check --
if ($Check) { exit 0 }
if (-not $NoLaunch) {
  if (-not (Get-Process Blitz -ErrorAction SilentlyContinue)) {
    Start-Process (Join-Path $Script:BlitzDir 'Blitz.exe')
    Say 'Blitz relance.'
  } else { Say 'Blitz deja en cours.' }
}
if ($Launch) {
  Start-Sleep 15
  if (Get-Process Blitz -ErrorAction SilentlyContinue) { Say 'VERIF: Blitz vivant' 'Green' }
  else { Say 'VERIF: Blitz a quitte - voir %APPDATA%\Blitz\crash.log' 'Red' }
  $crash = Get-Content "$env:APPDATA\Blitz\crash.log" -ErrorAction SilentlyContinue
  if ($crash -match 'E[0-9] Error') { Say "VERIF: $($crash -join ' ')" 'Red' }
  $logTail = Get-Content "$env:APPDATA\Blitz\app.log" -Tail 60 -ErrorAction SilentlyContinue
  if ($logTail -match 'Adblock engine loaded') { Say 'VERIF: adblock actif' 'Green' } else { Say 'VERIF: adblock non vu dans le log' 'Yellow' }
}
