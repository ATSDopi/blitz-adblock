# Blitz Ad-Block

Blocks ads **and** hides the empty ad boxes in the [Blitz.gg](https://blitz.gg) desktop app (Electron), plus a few small bugfixes. Survives Blitz updates via a self-repairing launcher shortcut.

No Node.js, no admin rights, no external tools required — everything is vendored or compiled inline. Double-click one `.bat`, done.

## What it does

- **Network ad-blocking** — embeds the [@ghostery/adblocker](https://github.com/ghostery/adblocker) engine (the uBlock-class matcher) in Blitz's main process, hooked on `session.webRequest`. Filter lists: EasyList, EasyPrivacy, uBlock ads + privacy, Peter Lowe's list.
- **Cosmetic cleanup** — Blitz names its ad slots with the 🤑 emoji (`🤑-wrapper`, `🤑-sidebar`, `🤑-rectangle`…). A `<style>` element + a `MutationObserver` injected into the app view hide them, plus `.advertisement`, `.promotion`, `data-primis-placement-id` video slots, the Quantcast consent banner, premium upsell links — and collapses the right rail (`--right-rail-width: 0px`) so the content reclaims the full width. Empty ad boxes *and* their screen space are gone.
- **Deadlock fixes** (bonus, harmless if you don't play): normalizes the `deadlock.exe` path matching that made the overlay fail with `path not found`, and retries the offsets fetch on transient CDN 403s.
- **User hooks** — drop a `user.css` / `user.js` in `%APPDATA%\Blitz\` and it's injected into the app on every page load. Free theming.

## Install

1. Download / clone this repo anywhere.
2. Double-click **`patch-blitz.bat`** (or `powershell -File blitz-patch.ps1 -Install`).
3. It auto-detects your Blitz install (checks `%LOCALAPPDATA%\Programs\Blitz`, then uninstall registry keys, else asks for the path), patches it, installs a repair kit to `%APPDATA%\Blitz\patch-kit`, creates a **"Blitz (patched)"** shortcut on your Desktop + Start Menu, and launches Blitz.

From then on, **always launch Blitz via the "Blitz (patched)" shortcut**.

## Why the shortcut matters

Blitz auto-updates by **reinstalling its whole program folder** — every update silently wipes the patch. The "Blitz (patched)" shortcut runs a fast state check on every launch (`xxHash32(app.asar)` vs. the stored integrity value + patch marker) and re-applies the patch automatically if an update erased it. If nothing changed it just starts Blitz — the check adds ~1 s.

Manual re-patch anytime:

```powershell
powershell -ExecutionPolicy Bypass -File "$env:APPDATA\Blitz\patch-kit\blitz-patch.ps1" -Force -Launch
```

## How it works

Blitz's UI is a remote web app (`blitzapp.gg`) rendered in a `BrowserView`; the local `app.asar` only holds the Electron shell + native handlers. The patcher:

1. **Extracts** `resources\app.asar` (vendored `asar` npm package — run with your `node` if present, or **Blitz.exe itself** as the Node runtime via `ELECTRON_RUN_AS_NODE=1`).
2. **Patches `src\electronWindowHandlers.js`** at a stable anchor (`function interceptRequests(window) {`, called once per window): inserts the adblock engine + the cosmetic injector. Only the main app window has a `browserView`, so the in-game overlay is untouched.
3. **Patches `src\gameHandlers\deadlock\index.js`** (best-effort, anchor-verified).
4. Copies the payload (engine + filter lists) into `src\`, **repacks** preserving `unpacked` entries, and re-syncs `resources\app.asar.unpacked\`.
5. **Defeats `VerifyApp`** — Blitz's bootstrap computes `xxHash32(app.asar)` and compares it to a `uint32` stored in the **last 4 bytes of `icudtl.dat`** (mismatch → `E6` in `crash.log` and the app exits). We recompute the hash and rewrite those 4 bytes. The xxHash32 is a small inline C# class compiled with `Add-Type` — no dependency.
6. Originals are backed up once as `app.asar.orig` / `icudtl.dat.orig`.

If an anchor doesn't match a future Blitz build, the script warns instead of writing a broken patch.

## Uninstall

```powershell
cd "$env:LOCALAPPDATA\Programs\Blitz"
Copy-Item resources\app.asar.orig resources\app.asar -Force
Copy-Item icudtl.dat.orig icudtl.dat -Force
Remove-Item "$env:APPDATA\Blitz\patch-kit" -Recurse -Force
# and delete the "Blitz (patched)" shortcuts on Desktop / Start Menu
```

## Notes & disclaimer

- Modifies local app files — for personal use. Don't redistribute Blitz binaries; this repo only ships *patches* applied to your own installation.
- Not affiliated with Blitz. If an update breaks the anchors, the patcher degrades gracefully (warns) rather than corrupting the app — report it in Issues.
- Backups (`.orig`) are untouched originals — Blitz keeps working even if you never uninstall "cleanly".
- Third-party payloads: `@ghostery/adblocker` (MPL-2.0), `asar` (MIT), filter lists (EasyList/EasyPrivacy — CC-BY-SA/GPL, uBlock — GPL-3.0, Peter Lowe's list — free for non-commercial use).

---

# FR — Blitz Ad-Block

Bloque les pubs **et** masque les encarts vides dans l'app desktop Blitz.gg (Electron) + quelques petits bugfixes. Survit aux mises à jour Blitz grâce à un raccourci auto-réparateur.

Aucun Node.js, aucun droit admin, aucun outil externe — tout est embarqué ou compilé à la volée. Un double-clic sur un `.bat`, terminé.

## Ce que ça fait

- **Blocage réseau** — le moteur @ghostery/adblocker (EasyList, EasyPrivacy, uBlock, Peter Lowe) greffé sur `session.webRequest` dans le process principal.
- **Nettoyage cosmétique** — les slots pubs de Blitz s'appellent `🤑-wrapper`/`🤑-sidebar`/`🤑-rectangle`. `<style>` + `MutationObserver` injectés dans la vue les cachent (ainsi que `.advertisement`, `.promotion`, les slots vidéo `data-primis-placement-id`, le bandeau cookies Quantcast, les liens upsell premium) et replient la colonne de droite (`--right-rail-width: 0px`) — les carrés **et** leur espace disparaissent.
- **Fixes Deadlock** : corrige le matching du chemin `deadlock.exe` (`path not found`) et retente le fetch des offsets sur 403 transitoires.
- **user.css / user.js** — dépose-les dans `%APPDATA%\Blitz\`, injectés à chaque chargement de page. Theming libre.

## Installation

1. Télécharge / clone le repo.
2. Double-clique **`patch-blitz.bat`**.
3. Détection automatique de l'install Blitz → patch → kit installé dans `%APPDATA%\Blitz\patch-kit` → raccourci **"Blitz (patched)"** créé sur le Bureau + Menu Démarrer → Blitz lancé.

Ensuite, lance toujours Blitz via le raccourci **"Blitz (patched)"**.

## Pourquoi le raccourci

Chaque update Blitz **réinstalle tout le dossier** → le patch saute. Le raccourci vérifie l'état (`xxHash32(app.asar)` vs valeur d'intégrité stockée) à chaque lancement et repatche tout seul si besoin (~1 s de check sinon).

Re-patch manuel :

```powershell
powershell -ExecutionPolicy Bypass -File "$env:APPDATA\Blitz\patch-kit\blitz-patch.ps1" -Force -Launch
```

## Désinstallation

```powershell
cd "$env:LOCALAPPDATA\Programs\Blitz"
Copy-Item resources\app.asar.orig resources\app.asar -Force
Copy-Item icudtl.dat.orig icudtl.dat -Force
Remove-Item "$env:APPDATA\Blitz\patch-kit" -Recurse -Force
# supprime aussi les raccourcis "Blitz (patched)" (Bureau / Menu Démarrer)
```

## Avertissement

Modifie les fichiers locaux de l'app — usage personnel uniquement ; ce repo ne contient que des *patchs* appliqués à ta propre installation, aucun binaire Blitz. Non affilié à Blitz. Backups `.orig` = originaux intacts.
