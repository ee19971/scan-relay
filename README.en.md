# Scan-Relay — Real-time phone-to-Excel barcode capture (Scan-IT to Office alternative)

Phone camera scanning / form capture → LAN relay service → Excel add-in writes cells in real time.

```
┌─────────────┐   ws://<LAN-IP>:8765   ┌──────────────────┐   wss://localhost:3000/relay   ┌─────────────────┐
│ Phone app    │ ────────────────────► │ Python relay      │ ◄──────────────────────────── │ Office JS        │
│ (Flutter)    │   scan / form data    │ (FastAPI + WS)    │  (webpack-dev-server proxy)   │ add-in (Excel)   │
└─────────────┘                        └──────────────────┘                    └────────┬────────┘
      ▲ scan QR / type pairing URL           │ auto-detect LAN IP                        │ Excel.run()
      └──────────────────────────────────────┴─────────────────────────────────────► worksheet
```

## Contents

- `server/` — local relay service (pairing, sessions, WebSocket forwarding)
- `addin/`  — Office JS add-in (pairing QR, continuous scan, form designer)
- `mobile/` — Flutter phone app (Android / iOS, QR pairing + capture)
- `启动Scan-Relay.bat` — one-click launcher (Windows)

[中文文档](README.md)

## Quick start

### One-click launch (recommended)

```
Double-click 启动Scan-Relay.bat
```

One process serves both the phone relay (8765) and the add-in page (https://localhost:3000). Minimize the window; closing it stops the service.

Then: open Excel → "Scan to Sheet" → generate pairing code → scan with phone.

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
npm start        # https://localhost:3000, installs a trusted dev certificate on first run
```

After frontend changes run `npm run build` so the one-click mode serves the new UI.

### 3. Sideload the add-in into Excel

1. Open desktop Excel
2. **Insert → Add-ins → My Add-ins → Upload My Add-in**, pick `addin/manifest.xml`
3. A **Scan-Relay** button appears on the Home tab; click it to open the task pane
4. Click **Generate pairing code** — a QR code and connection status appear

> Personal sideloading needs no AppSource review.

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

## Verified

- [x] Relay end-to-end automated test (9/9 assertions)
- [x] Add-in webpack build + `/relay` reverse proxy (incl. WebSocket)
- [x] Android emulator end-to-end: `scan` and `form_submit` messages both reach the add-in
- [x] Real phone + Excel (M365) sideload, QR pairing and scan pipeline all working

## FAQ

- **Phone cannot connect**: allow 8765 in the firewall; phone and PC must be on the same LAN (guest networks are usually isolated); `curl http://<IP>:8765/` opening in the phone browser means it works
- **Add-in cannot connect**: start the relay (8765) first, then `npm start` (3000)
- **Why the add-in does not connect to ws://LAN-IP directly**: Office add-in pages force HTTPS; a direct ws:// is blocked as mixed content, so traffic is proxied through `wss://localhost:3000/relay` (see `addin/webpack.config.js`)
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
