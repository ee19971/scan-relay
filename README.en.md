# Scan-Relay — Real-time phone-to-Office barcode capture (Scan-IT to Office alternative)

Phone camera scanning / form capture → LAN relay service → Office add-in writes into **Excel / Word / PowerPoint** in real time.

```
┌─────────────┐   ws://<LAN-IP>:8765   ┌──────────────────┐   wss://localhost:4443/relay   ┌─────────────────┐
│ Phone app    │ ────────────────────► │ Python relay      │ ◄──────────────────────────── │ Office JS        │
│ (Flutter)    │   scan / form data    │ (FastAPI + WS)    │  (page hosted by the relay)   │ add-in (3 hosts) │
└─────────────┘                        └──────────────────┘                    └────────┬────────┘
      ▲ scan QR / type pairing URL           │ auto-detect LAN IP                        │ per-host writes
      └──────────────────────────────────────┴─────────────────────────────────────► cells / cursor / text box
```

## Contents

- `server/` — local relay service (pairing, sessions, WebSocket forwarding)
- `addin/`  — Office JS add-in (pairing QR, continuous scan, form designer)
- `mobile/` — Flutter phone app (Android / iOS, QR pairing + capture)
- `packaging/` — installer build (Inno Setup + bundled Python runtime)
- `docs/`   — supplementary docs

[中文文档](README.md)

## Quick start

### Install (recommended)

Grab `Scan-Relay-Setup-x.y.z.exe` from the Release and run it — **no admin rights, no UAC prompt**:

- Installs to `%LOCALAPPDATA%\Programs\Scan-Relay` (current user only)
- Registers itself as a trusted Office add-in catalog (Excel / Word / PowerPoint)
- Registers the `scanrelay://` protocol (the pane's "start server" button uses it)
- Creates Desktop and Start Menu shortcuts

Afterwards **fully quit** Excel/Word/PowerPoint (including any background process still in the
notification area) and reopen them; Scan-Relay appears under
**Home → Add-ins → My Add-ins → Shared folder**.

### Starting and stopping

```
Double-click the "Scan-Relay" icon (Desktop / Start Menu)
  → starts the relay + shows a "service started" notification + adds a tray icon

Tray icon right-click → open add-in page / send clipboard to document / start·restart relay / view log / quit
              single-click → open the add-in page
```

The relay runs **with no window**, so there is nothing to close by accident. The way to stop it is
the tray menu's **Quit** (or the pane's stop, equivalent to `scanrelay://stop`). The stop endpoint
only accepts `127.0.0.1`, so phones on the LAN cannot stop it.

> **No autostart whatsoever**: no Startup entry, no logon task — whether the service runs is entirely up to you.
>
> **Tray icon not visible**: Windows hides new tray icons in the notification-area overflow ("^") by
> default. Open it once and drag Scan-Relay out to pin it. That is a one-time step.
>
> **If the service stops**: the task pane's server status card probes every 3 s and shows a **Start server** button. It triggers the `scanrelay://` protocol which launches the tray in the background (Windows asks a one-time "open app?" confirmation); the pane auto-reconnects once the service is back. While the service is down, Office cannot even open the pane ("we can't start the add-in") — double-click the desktop icon to bring it back.
>
> Port note: the add-in page uses **4443**, not the usual 3000 — low ports like 3000 are often swallowed by Hyper-V/WinNAT dynamic reservations (`netsh int ipv4 show excludedportrange protocol=tcp`), which looks like "port busy but nothing in netstat" (bind fails with WinError 10013). To change it: set `RELAY_UI_PORT` and update every URL in `addin/manifest.xml`, then reinstall.

### Send the clipboard straight into the document

The tray menu's **Send clipboard to document** pushes the current clipboard text to every open
add-in window as an ordinary scan message — so column auto-advance, duplicate protection and the
streaming append behaviour all apply unchanged.

- Works with no phone connected (or even paired): the whole path stays on this PC
- Only takes effect in **streaming mode**; windows sitting in form mode are ignored
  (form mode is driven field-by-field from the phone)
- Clipping is capped at 10 000 characters so an accidental whole-document copy cannot flood the sheet
- The tray reports how many characters went to how many windows; if no window is open it says so

### Manual launch (development)

#### 1. Start the relay (PC)

```powershell
cd server
pip install -r requirements.txt
python -m uvicorn relay:app --host 0.0.0.0 --port 8765
```

- LAN IPs are auto-detected; override with `$env:RELAY_HOST="192.168.x.x"`
- **Windows Firewall**: allow access (TCP 8765) on the first prompt, or the phone cannot connect

#### 2. Start the add-in dev server (PC, only when changing the frontend)

```powershell
cd addin
npm install
npm start        # https://localhost:4443, installs a trusted dev certificate on first run
```

After frontend changes run `npm run build` so the one-click mode serves the new UI.

### 3. Sideload the add-in into Office (Excel / Word / PowerPoint)

**If you ran the installer, this step is already done for you**: it registers
`%LOCALAPPDATA%\Programs\Scan-Relay\addin` as a trusted add-in catalog (it writes
`HKCU\Software\Microsoft\Office\16.0\Wef\TrustedCatalogs`, no admin rights needed). After restarting Office:

1. Open desktop Excel / Word / PowerPoint
2. **Home → Add-ins → My Add-ins → Shared folder**, pick Scan-Relay
3. A **Scan-Relay → 扫码录入** button appears on the Home tab; click it to open the task pane
4. Click **Generate pairing code** — a QR code and connection status appear

> Personal sideloading needs no AppSource review. If a certificate prompt appears, choose Yes/Install.
>
> **No installer, sideloading by hand**: run `sideload.ps1` from the repo (copies the manifest into
> `C:\ScanRelay`, writes the trusted-catalog registry key, registers the `scanrelay://` protocol and
> creates shortcuts), or use **Insert → Add-ins → My Add-ins → Upload My Add-in** and pick
> `addin/manifest.xml`.

### Per-host write behavior

| Host | Continuous scan | Form capture |
|---|---|---|
| **Excel** | Tracks the selected cell (click where you want it), appends rows | Writes whole rows by column, row follows selection |
| **Word** | Inserts at the cursor, one paragraph per scan | Inserts "field: value" lines at the cursor |
| **PowerPoint** | Appends to the "ScanRelay.Text" text box on the current slide (created automatically if missing) | Appends "field: value" lines to the current slide's text box |

### 4. Pair the phone

```powershell
cd mobile
flutter run -d <device>        # or flutter build apk && adb install
```

App opens the camera → scan the QR in the Excel task pane → status turns "Connected".
(Emulator/no-camera: type `http://<IP>:8765/scan?token=...` manually on the pairing page.)

### Two capture modes

| Mode | In Excel | On the phone |
|---|---|---|
| Continuous scan | Start cell **auto-tracks the selection** (click where you want it) → appends row by row, with duplicate protection | Point at barcodes; each one is sent automatically. Manual input / scanner gun supported |
| Form capture | Design fields + columns → select start row → "Push config to phone" | Renders the form; "Submit row" writes the whole row |

## Connectivity decision tree (no router / no Wi-Fi?)

```
PC has Bluetooth?
 ├─ yes → Bluetooth HID keyboard mode (scans are "typed" straight into Excel;
 │        zero network dependency, Android only)
 └─ no  → PC has Wi-Fi or a router?
      ├─ yes → main path: phone and PC on the same LAN, ws://<IP>:8765 (quick start above)
      └─ no  → [USB cable] enable "USB tethering" on the phone
                PC gets an extra NIC, peer-to-peer; protocol unchanged
```

### USB tethering steps (desktop with no Bluetooth / no Wi-Fi)

1. Connect phone by cable, enable **Settings → Network → USB tethering** (some phones require mobile data or Wi-Fi on first)
2. Windows installs the built-in RNDIS/NCM driver; an "Ethernet N" NIC appears with a `192.168.42.x` address
3. Allow firewall access on the first prompt
4. Generate the pairing code — the pane lists **all candidate addresses**; the QR uses the default route (usually already pointing at the USB interface). If it fails, type one of the listed addresses into the phone manually

> Phone hotspot works the same: PC joins the phone's hotspot → same LAN.
> Note: Android's **USB HID keyboard mode is not usable** (needs system privileges/root); USB tethering is the way for offline setups.

## Bluetooth HID keyboard mode (offline, straight into Excel)

The phone impersonates a Bluetooth keyboard: scan results are typed like keystrokes into **whatever has focus** on the PC (Excel cell, Notepad, an ERP system…).
The PC needs **zero install and zero network** — just Bluetooth. Android only (iOS forbids keyboard emulation).

### Setup

1. Phone app → "Bluetooth keyboard mode" → follow the 4 steps:
   ① grant Bluetooth permissions and turn Bluetooth on → ② start the keyboard service → ③ make the phone discoverable (5-minute window)
2. PC: `Settings → Bluetooth & devices → Add device → Bluetooth` → pick your phone → **verify the same 6-digit code on both screens and confirm on both**
3. Step ④ in the app turns green when connected. Tap "Enter scan page", click the target Excel cell, then scan

### Behavior

- Each scan types the value + **Enter** (appends row after row)
- ASCII only (the HID keyboard protocol has no keys for CJK characters): mixed content sends only the ASCII part with a notice; pure CJK is skipped with a notice → **use network mode for Chinese text**
- Keep the app in the foreground while capturing; screen-off / background may drop the link
- Pair once; afterwards the PC auto-reconnects whenever the app starts the service

### Pairing troubleshooting (pairing dialog loops / AUTH_FAILURE)

The root cause is almost always **asymmetric stale link keys** (one side still has the old key). Delete the pairing on **both** sides, then pair fresh:

1. PC: Settings → Bluetooth & devices → find your phone → Remove device (`pnputil /remove-device` needs elevation; the registry key store `BTHPORT\Parameters\Keys` needs SYSTEM, normal admins cannot read it)
2. Phone: Settings → Bluetooth → the PC in the paired list → Forget
3. If the phone's pairing dialog flashes and disappears: MIUI/HyperOS suppresses repeated pairing popups (log shows `ignore the popupwindow`) — wait 2–3 minutes or reboot the phone
4. Restart app steps ②③ → add device again from the PC → **confirm promptly on both ends**

> Verified: Xiaomi 15 Pro (HyperOS) ↔ Windows 11 (Intel wireless Bluetooth); pair once, then instant reconnects.
> Implementation: own Kotlin `BluetoothHidDevice` service (standard 45-byte boot keyboard descriptor), MethodChannel `scanrelay/hid`, Android 9+.

## Test tools (server/)

```powershell
python test_relay.py                 # end-to-end automated test (pair/forward/config/teardown)
python fake_addin.py <token>         # fake add-in: prints phone messages (integration debugging)
python send_config.py <token>        # push a form config and listen for submissions
```

Browser debug entry: `http://<LAN-IP>:8765/scan?token=<token>` (built-in jsQR scanner — test the pipeline without a phone).

## Building the installer (for maintainers)

```powershell
# prerequisites: node/npm, Python (with Pillow), Inno Setup 6.3+
powershell -ExecutionPolicy Bypass -File packaging\build-release.ps1
```

Five steps: build the add-in → assemble the bundled Python runtime → generate the icon and notes →
compile with ISCC → verify and copy to the Desktop.

The installer is **self-contained**: it ships a complete embedded Python runtime (assembled by
`packaging\fetch-python.ps1`), so the target machine needs neither Python nor .NET — just double-click.

What each file in `packaging/` does:

| File | Purpose |
|---|---|
| `build-release.ps1` | one-shot entry point |
| `fetch-python.ps1` | downloads the python.org embeddable package + cross-installs pinned deps with `pip --target` |
| `requirements-bundle.txt` | dependency list for the embedded runtime (fewer dev-only extras than `server/requirements.txt`) |
| `smoke.py` | embedded-runtime self-test: exercises every path `relay.py` / `tray.py` actually use |
| `make-ico.py` | generates the multi-size `.ico` (same barcode motif as the add-in icon) |
| `scan-relay.iss` | the Inno Setup script |
| `install-notes.txt` | the notes shown at the end of installation |

> **One gotcha for build machines**: Inno Setup's official installer is now only published on GitHub
> Releases. When the direct connection is unreachable, download it through a mirror proxy — but
> **verify the signature before running it**. A proxy is only a courier; it cannot forge an
> Authenticode signature:
> ```powershell
> signtool verify /pa /v innosetup-x.y.z.exe     # ships with the Windows SDK
> innosetup-x.y.z.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-
> ```
> Also note: `Get-AuthenticodeSignature` can be unusable in some environments because of a PowerShell
> module conflict; fall back to `signtool` or read the certificate object directly
> (`[Security.Cryptography.X509Certificates.X509Certificate]::new($path)`).
> Do not identify the signer by parsing `signtool` output text — it is localized, and a Chinese-locale
> machine has no `Subject:` line at all.

## Verified

- [x] Relay end-to-end automated test (9/9 assertions)
- [x] Add-in webpack build + `/relay` reverse proxy (incl. WebSocket)
- [x] Android emulator end-to-end: `scan` and `form_submit` messages both reach the add-in
- [x] Real phone + Excel (M365) sideload, QR pairing and scan pipeline all working
- [x] Multi-host manifest (Workbook/Document/Presentation + generic Office 1.1 requirement set)
- [x] `scanrelay://` cold start: the task-pane button wakes the tray and starts the relay → both healthz endpoints up (avoids the Hyper-V-reserved 3000/3443)
- [x] Clipboard injection end-to-end: `POST /inject` (loopback only) → a fake `role=addin` connection receives `value` / `symbology=CLIPBOARD` / `source=clipboard`
- [x] Tray log fallback: when `relay.log` is held exclusively (cmd `>>` redirection does not share write access) tray logging falls back to `tray.log`, and the relay **still starts normally** (before the fix it gave up because writing the banner failed)
- [x] Installer end-to-end on a clean machine: silent install → URL protocol, shortcuts and the TrustedCatalogs key all correct; desktop-icon start brings the relay up in ~1 s; the embedded runtime passes a 17/17 self-test
- [x] Certificate path on a machine with no `office-addin-dev-certs`: the relay generates a self-signed cert, installs it into the user Root store and records its SHA-1 thumbprint
- [x] Clean uninstall: tray and relay exited, `{app}` and the state dir removed including runtime-generated `.certs` / `__pycache__`, the recorded certificate deleted from the Root store, and registry / protocol / shortcuts / ARP all gone
- [x] Double-click recovery: with the relay stopped but the tray still running, launching the icon again restarts the relay (previously the second instance hit the single-instance mutex and exited, leaving the service down for good)

## FAQ

- **Phone cannot connect**: allow 8765 in the firewall; phone and PC must be on the same LAN (guest networks are usually isolated); `curl http://<IP>:8765/` opening in the phone browser means it works
- **Add-in cannot connect**: start the relay first (the pane's status card / the desktop "Scan-Relay" icon / the tray menu's start·restart item — any one)
- **No Scan-Relay icon in the notification area**: Windows hides new tray icons inside the "show hidden icons" overflow ("^") by default. Open it once and drag the icon out to pin it — a one-time step. If it is not there at all, the service has never been started: double-click the desktop "Scan-Relay" icon.
- **After uninstalling and reinstalling, `https://localhost:4443` reports a certificate error**: expected — the old certificate was removed together with the uninstall. Double-click the desktop icon and the service generates and installs a fresh one.
- **"Port busy" but nothing in netstat**: Hyper-V/WinNAT dynamic port reservations swallowed the port (bind fails with WinError 10013); check with `netsh int ipv4 show excludedportrange protocol=tcp`. Defaults avoid this (8765/4443); if a custom port collides, pick another or reboot (reservations are re-assigned each boot)
- **Why the add-in does not connect to ws://LAN-IP directly**: Office add-in pages force HTTPS; a direct ws:// is blocked as mixed content, so traffic is proxied through `wss://localhost:4443/relay` (see the `/relay/*` routes in `server/relay.py`)
- **Excel sideload gotchas** (from real debugging):
  - `manifest.xml` `<Version>` must be ≥ 1.0, otherwise Excel rejects it
  - Registry sideloading uses the current official format: `HKCU\Software\Microsoft\Office\16.0\Wef\TrustedCatalogs\{GUID}` with values `Id` (braced GUID), `Url` (**points at a shared folder, not the manifest file**, UNC with double backslashes), `Flags`=dword:1; restart Excel completely afterwards
  - The shared folder can be the admin share `\\localhost\C$\ScanRelay`
  - Or use the UI: File → Options → Trust Center → Trusted Add-in Catalogs
  - UI entry: File → Get Add-ins → **My Add-ins** (not the Store)
- **Task pane buttons dead**: if the office.js CDN (appsforoffice.microsoft.com) fails to load, the pane JS dies; the code has an 8-second fallback (pairing does not depend on the Office API) and logs "degraded mode"
- **QR missing in the pane**: if the log says the image is fine but no QR appears, check for the old `connect()` bug (already fixed); "生成配对码失败" in the log means the relay is not running
- **Flutter on non-ASCII paths**: `android.overridePathCheck=true` is set in `mobile/android/gradle.properties`; `flutter analyze` still crashes under a Chinese path (environment bug) — verify with `flutter build apk` instead
  - **Release builds break too**: debug builds skip AOT so they are fine, but `flutter build apk --release` runs gen_snapshot which fails to read `app.dill` under a Chinese path ("Unable to read file", exit 255). Fix: create an ASCII-path junction and build there:
    ```powershell
    New-Item -ItemType Junction -Path C:\dev\scanmobile -Target "<repo>\mobile"
    cd C:\dev\scanmobile
    flutter build apk --release --split-per-abi   # output still lands in mobile\build\
    ```
- **permission_handler version**: pinned to `^12.0.0` (13.x requires SDK 37.0 layout incompatible with the current AGP)
- **Camera permission denied**: reinstall resets permission state; the app provides "Retry / Open system settings" buttons

## Roadmap

- Transport abstraction for the relay: `LocalTransport` today, `CloudTransport` (self-hosted cloud relay) later so phone and PC can be on different networks — no changes needed on either endpoint
- AppSource publishing: add icons/privacy policy to the manifest, move the add-in page to a fixed HTTPS domain

## License

[GPL-3.0](LICENSE)
