# GZ302EA — ROG Flow Z13 (2025) Windows 11 driver pack

Offline driver + firmware pack for a fresh Windows 11 install on the ASUS ROG
Flow Z13 GZ302EA (Strix Halo). All 26 ASUS packages are pinned by the SHA-256
hashes ASUS publishes in its support API (`SHA256SUMS`); versions current as
of 2026-07-23.

One line does it all on any Linux distro or macOS (needs `git` + `rust` +
7-Zip in any flavor; `innoextract` — or `wine` on unix — for the full
distill):

```text
❯ curl -fsSL https://raw.githubusercontent.com/foolish-dev/tools/main/GZ302EA/setup.sh | bash -s -- /mnt/usb
```

[`setup.sh`](setup.sh) builds the three Rust tools, downloads + verifies all
26 packages into the target dir, distills them to pnputil-ready payloads in
`Extracted/`, and previews the Windows install plan. Everything is
idempotent — re-runs verify instead of re-doing.

The tools also run individually (`cargo build --release` in each crate):

- **[`fetch/`](fetch)** `gz302ea-fetch [dir]` — download + verify. Pure Rust
  (rustls + sha2 — no curl, bash, or system TLS). `manifest.tsv` (sha + name
  + CDN path) is the source of truth; `cargo test` drift-checks it against
  `SHA256SUMS`, which stays around for plain `sha256sum -c`.
- **[`distill/`](distill)** `gz302ea-distill [dir]` — installers → raw
  payloads in `Extracted/` (7z overlay / wine silent-install; see below).
- **[`install/`](install)** `gz302ea-install [dir] [--dry-run]` — the Rust
  replacement for running the ASUS installer exes: on Windows, elevated,
  stages every driver INF via pnputil in dependency order (chipset first)
  and runs the Smart Display Control MSI. Tests pin the BIOS capsule and
  firmware tools as never-installed. `--dry-run` prints the plan anywhere.

Grab Windows
install media separately (MediaCreationTool / Installation Assistant from
Microsoft — no stable URLs or published hashes, so not part of the manifest).

## Install order

1. `AMD_Chipset_DriverOnly_ROG_AMD_Z_V1.2.0.126Sub14` — chipset first, reboot
2. `AMD_Graphic_DriverOnly_ROG_AMD_Z_V32.0.23033.5002` — Radeon 8060S (gfx1151)
3. `WirelessLan_ROG_MediaTek_Z_V5.7.0.5115Sub1` — Wi-Fi (needed before internet works)
4. `Bluetooth_ROG_MediaTek_Z_V1.1045.0.566Sub1`
5. `Audio_DriverOnly_Dolby_ROG_Realtek_Z_V6.0.9888.1` — Realtek codec
6. `SmartAMP_Cirrus_DCH_ROG_Cirrus_Z_V23.26.47.823` — speaker amp (audio is broken/quiet without it)
7. `DolbyAtmos_ASUS_Z_V10.806.1131.23`
8. `ASUSSystemControlInterfacev3_ASUS_Z_V3.1.67.0` — Fn keys, MyASUS backend
9. `ArmouryCrateControlInterface_ASUS_Z_V1.2.0.1`
10. `ASUSSmartDisplayControl_ASUS_Z_V2.11.31` — rotation / tablet mode
11. `PrecisionTouchPad_ROG_ASUS_Z_V16.0.0.32`
12. `Camera_ROG_AMD_Z_V11.04.02.1159` + `MSFT_MEP_ROG_Microsoft_Z_V2.0.11.0` (camera effects)
13. `CardReader_ROG_Genesys_Z_V1.1.54.0`
14. `Parade_Retimer_ROG_Parade_Z_V1.0.016.00` — USB4/Thunderbolt retimer
15. Armoury Crate — `AC_Full_Package_1.5.0.7_202508051359.zip` (v6.2.11, full
    offline package: unzip and run, no internet needed). Alternative:
    `ArmouryCrateInstallTool.zip` (v3.3.6.0 web installer → AC v6.4.7, needs
    internet). If an install wedges: `Armoury_Crate_Uninstall_Tool.zip`;
    for support-log collection: `Armoury_Crate_Lite_Log_Tool.zip`.
16. `VirtualAssistant_ASUS_Z_V4.1.1` — optional
17. `AuraWallpaperService_ASUS_Z_V2.1.10.0` — optional

## Firmware (run after drivers, on AC power)

- `ASUS_GZ302EA_311_BIOS_Update.exe` — BIOS 311 (2025-09-19, latest; 308 was
  flagged Critical)
- `GZ302EAAS311.zip` — same BIOS 311 for UEFI EZ Flash: unzip `GZ302EAAS.311`
  onto a FAT USB, no Windows needed
- `ROGPDFWupdate_ASUS_Z_V2.13.0.001` — USB-PD charging firmware
- `ROGNkeyFWupdate_ASUS_Z_V4.8.0.001` — keyboard firmware
- `ASUSLightBarFirmwareUpdateTool_ASUS_Z_V2.6.0.002` — light bar firmware

**Online-only trap:** the PD and keyboard packages ship only an
`AsusInstallerBI.exe` downloader harness — the actual Onekey tools
(`CSPDFWUpdateTool_GZ302EA_*` / `ROGKBFWUpdateTool_GZ302EA_*`) are fetched at
runtime, so these two need internet on Windows regardless. The light-bar tool
and both BIOS forms are fully offline.

## Microsoft Store only (no offline installer)

MyASUS (`9N7R5S6B0ZZH`), ScreenXpert (`9N5RFFGFHHP6`), GlideX (`9PLH2SV1DVK5`),
Realtek Codec Console (`9P2B8MCSVPLN`).

## Distilling installers → pnputil-ready INFs

Every ASUS package is an Inno Setup exe; `gz302ea-distill` pulls the raw
INF/SYS/CAT payloads out without running a single GUI installer. It prefers
`innoextract` (pure extraction, any OS — installers are never executed
natively); without it, two techniques cover all of them on unix:

- **7z overlay** — GPU, Realtek audio, WLAN, BT, MEP, ASCI v3 and the BIOS
  updater keep their payload 7z-readable: `7z x -oOUT package.exe` yields a
  clean driver tree.
- **wine silent install** — the rest (chipset, touchpad, camera sensor, card
  reader, retimer, SmartAMP, Dolby Atmos, utilities) unpack via
  `wine package.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /DIR='C:\payload\X'`
  in a throwaway prefix (`WINEPREFIX` must not live under /tmp). Packages that
  stage into Inno's self-deleting `{tmp}` need their payload copied out while
  the process runs.

With Wi-Fi INFs on the install USB, 24H2 OOBE's forced network check is
solvable offline — Shift+F10, then:

```text
pnputil /add-driver D:\GZ302EA\Extracted\WLAN_MediaTek\WLAN\mtkwecx.inf /install
```

Bulk-inject on a running system (`pnputil /add-driver ... /subdirs /install`)
or into an offline image (`DISM /Add-Driver /Recurse`). **Capsule trap:** the
BIOS updater's payload contains BIOS 311 as a UEFI capsule INF
(`GZ302EA_311.inf`) — injecting it stages a firmware flash on next boot; keep
it out of bulk sweeps. Also: the WLAN and BT packages ship the identical
MediaTek combo payload — one of them is enough when distilled.

## Source

ASUS support API (per-file `sha256` + CDN URL, works on www.asus.com — the
rog.asus.com variant fails):

```text
https://www.asus.com/support/api/product.asmx/GetPDDrivers?website=us&model=GZ302EA&osid=52
https://www.asus.com/support/api/product.asmx/GetPDBIOS?website=us&model=GZ302EA
```

Armoury Crate packages live under `model=Armoury%20Crate`. Human-readable:
<https://www.asus.com/us/supportonly/gz302ea/helpdesk_download/>.
