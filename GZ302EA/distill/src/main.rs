// gz302ea-distill — distill the GZ302EA driver pack into raw payloads
//
// Reproduces Extracted/ from the downloaded installers (see ../fetch), all of
// which are Inno Setup exes: seven keep their payload 7z-readable in the PE
// overlay; the rest carry it in the compressed Inno stream. For those,
// innoextract is preferred (pure extraction, works on any OS); the fallback
// on unix is a real silent install under wine in a throwaway prefix, where
// two packages stage into Inno's self-deleting {tmp} and are captured by
// polling while the installer runs. Idempotent: components whose output
// directory already has files are skipped.
//
// Needs 7-Zip on PATH (any of 7z/7zz/7za); the Inno-stream components
// additionally need innoextract, or wine on unix. Installers are never run
// natively — on Windows that would install, not extract.
// The BIOS updater payload contains BIOS 311 as a UEFI capsule INF — never
// bulk-inject Extracted/FW_BIOS_Updater with pnputil.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::OnceLock;
use std::time::{Duration, Instant};

const WINE_TIMEOUT: Duration = Duration::from_secs(300);

const GRN: &str = "\x1b[0;32m";
const RED: &str = "\x1b[0;31m";
const YLW: &str = "\x1b[1;33m";
const BLU: &str = "\x1b[0;34m";
const RST: &str = "\x1b[0m";

fn info(msg: &str) {
    println!("{BLU}[*]{RST} {msg}");
}

fn ok(msg: &str) {
    println!("{GRN}[OK]{RST} {msg}");
}

fn warn(msg: &str) {
    println!("{YLW}[!!]{RST} {msg}");
}

fn fail(msg: &str) {
    println!("{RED}[!!]{RST} {msg}");
}

#[derive(Clone, Copy, PartialEq)]
enum Method {
    /// Payload is 7z-readable straight from the PE overlay (or a plain zip).
    SevenZ,
    /// wine silent install with /DIR into the prefix, payload copied out.
    Wine,
    /// Like Wine, but payload lands in Inno's self-deleting {tmp}: poll-copy
    /// it into <dst>/tool while the installer runs.
    WineTmp,
}

struct Comp {
    file: &'static str,
    dst: &'static str,
    method: Method,
}

const COMPONENTS: &[Comp] = &[
    // 7z overlay
    Comp {
        file: "WirelessLan_ROG_MediaTek_Z_V5.7.0.5115Sub1_47888.exe",
        dst: "WLAN_MediaTek",
        method: Method::SevenZ,
    },
    Comp {
        file: "Bluetooth_ROG_MediaTek_Z_V1.1045.0.566Sub1_47887.exe",
        dst: "BT_MediaTek",
        method: Method::SevenZ,
    },
    Comp {
        file: "AMD_Graphic_DriverOnly_ROG_AMD_Z_V32.0.23033.5002_50395.exe",
        dst: "GPU_AMD",
        method: Method::SevenZ,
    },
    Comp {
        file: "Audio_DriverOnly_Dolby_ROG_Realtek_Z_V6.0.9888.1_45209.exe",
        dst: "Audio_Realtek_Dolby",
        method: Method::SevenZ,
    },
    Comp {
        file: "MSFT_MEP_ROG_Microsoft_Z_V2.0.11.0_40680_1.exe",
        dst: "Camera_MEP",
        method: Method::SevenZ,
    },
    Comp {
        file: "ASUSSystemControlInterfacev3_ASUS_Z_V3.1.67.0_17767.exe",
        dst: "ASCI_v3",
        method: Method::SevenZ,
    },
    Comp {
        file: "ASUS_GZ302EA_311_BIOS_Update.exe",
        dst: "FW_BIOS_Updater",
        method: Method::SevenZ,
    },
    Comp {
        file: "GZ302EAAS311.zip",
        dst: "BIOS_EZFlash",
        method: Method::SevenZ,
    },
    // wine silent install
    Comp {
        file: "AMD_Chipset_DriverOnly_ROG_AMD_Z_V1.2.0.126Sub14_44613_1.exe",
        dst: "Chipset_AMD",
        method: Method::Wine,
    },
    Comp {
        file: "Camera_ROG_AMD_Z_V11.04.02.1159_49857.exe",
        dst: "Camera_AMD",
        method: Method::Wine,
    },
    Comp {
        file: "CardReader_ROG_Genesys_Z_V1.1.54.0_45794.exe",
        dst: "CardReader_Genesys",
        method: Method::Wine,
    },
    Comp {
        file: "PrecisionTouchPad_ROG_ASUS_Z_V16.0.0.32_41630_1.exe",
        dst: "Touchpad_ASUS",
        method: Method::Wine,
    },
    Comp {
        file: "Parade_Retimer_ROG_Parade_Z_V1.0.016.00_41617_1.exe",
        dst: "USB4_Retimer_Parade",
        method: Method::Wine,
    },
    Comp {
        file: "SmartAMP_Cirrus_DCH_ROG_Cirrus_Z_V23.26.47.823_41267_1.exe",
        dst: "Audio_CirrusAmp",
        method: Method::Wine,
    },
    Comp {
        file: "DolbyAtmos_ASUS_Z_V10.806.1131.23_16879_2.exe",
        dst: "Audio_DolbyAtmos",
        method: Method::Wine,
    },
    Comp {
        file: "ASUSSmartDisplayControl_ASUS_Z_V2.11.31_16960.exe",
        dst: "SmartDisplayControl",
        method: Method::Wine,
    },
    Comp {
        file: "ArmouryCrateControlInterface_ASUS_Z_V1.2.0.1_16991.exe",
        dst: "ArmouryCrateCI",
        method: Method::Wine,
    },
    Comp {
        file: "AuraWallpaperService_ASUS_Z_V2.1.10.0_17044.exe",
        dst: "AuraWallpaper",
        method: Method::Wine,
    },
    Comp {
        file: "VirtualAssistant_ASUS_Z_V4.1.1_16838_2.exe",
        dst: "VirtualAssistant",
        method: Method::Wine,
    },
    Comp {
        file: "ASUSLightBarFirmwareUpdateTool_ASUS_Z_V2.6.0.002_16591_2.exe",
        dst: "FW_LightBar_Updater",
        method: Method::Wine,
    },
    // wine + {tmp} capture (online-harness packages: only the tool lands)
    Comp {
        file: "ROGPDFWupdate_ASUS_Z_V2.13.0.001_16989.exe",
        dst: "FW_PD_Updater",
        method: Method::WineTmp,
    },
    Comp {
        file: "ROGNkeyFWupdate_ASUS_Z_V4.8.0.001_16686_2.exe",
        dst: "FW_Keyboard_Updater",
        method: Method::WineTmp,
    },
];

fn have(cmd: &str) -> bool {
    Command::new(cmd)
        .arg("--version")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok()
}

/// First available 7-Zip binary: `7z` (p7zip/7zip), `7zz` (official
/// Linux/macOS build), `7za` (standalone).
fn sevenz() -> Option<&'static str> {
    static BIN: OnceLock<Option<&'static str>> = OnceLock::new();
    *BIN.get_or_init(|| ["7z", "7zz", "7za"].into_iter().find(|b| have(b)))
}

fn innoextract_available() -> bool {
    static HAVE: OnceLock<bool> = OnceLock::new();
    *HAVE.get_or_init(|| have("innoextract"))
}

fn wine_available() -> bool {
    static HAVE: OnceLock<bool> = OnceLock::new();
    *HAVE.get_or_init(|| cfg!(unix) && have("wine"))
}

fn dir_has_files(dir: &Path) -> bool {
    fn walk(d: &Path) -> bool {
        fs::read_dir(d).is_ok_and(|rd| rd.flatten().any(|e| e.path().is_file() || walk(&e.path())))
    }
    dir.is_dir() && walk(dir)
}

fn copy_dir(src: &Path, dst: &Path) -> std::io::Result<()> {
    fs::create_dir_all(dst)?;
    for e in fs::read_dir(src)?.flatten() {
        let to = dst.join(e.file_name());
        let p = e.path();
        if p.is_dir() {
            copy_dir(&p, &to)?;
        } else if !to.exists() || to.metadata()?.len() != p.metadata()?.len() {
            fs::copy(&p, &to)?;
        }
    }
    Ok(())
}

fn inf_count(dir: &Path) -> usize {
    let mut n = 0;
    let mut stack = vec![dir.to_path_buf()];
    while let Some(d) = stack.pop() {
        let Ok(rd) = fs::read_dir(&d) else { continue };
        for e in rd.flatten() {
            let p = e.path();
            if p.is_dir() {
                stack.push(p);
            } else if p.extension().is_some_and(|x| x.eq_ignore_ascii_case("inf")) {
                n += 1;
            }
        }
    }
    n
}

/// PE-section artifacts mean 7z saw no real payload, only the executable.
fn is_junk(dir: &Path) -> bool {
    dir.join("[0]").exists() || dir.join(".text").exists()
}

fn seven_z(archive: &Path, dst: &Path) -> Result<(), String> {
    let bin = sevenz().ok_or("no 7-Zip binary found")?;
    let status = Command::new(bin)
        .arg("x")
        .arg("-y")
        .arg(format!("-o{}", dst.display()))
        .arg(archive)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map_err(|e| format!("spawn {bin}: {e}"))?;
    // 7z exits non-zero on warnings for PE containers; judge by content.
    let _ = status;
    if is_junk(dst) {
        return Err("payload not 7z-reachable (PE sections only)".into());
    }
    if !dir_has_files(dst) {
        return Err(format!("{bin} produced no files"));
    }
    Ok(())
}

/// Align innoextract's layout with the wine method's: {app} contents at the
/// component root, {tmp} (the harness/tool staging) as tool/.
fn hoist_inno_layout(dst: &Path) {
    let app = dst.join("app");
    if app.is_dir() {
        if let Ok(rd) = fs::read_dir(&app) {
            for e in rd.flatten() {
                let _ = fs::rename(e.path(), dst.join(e.file_name()));
            }
        }
        let _ = fs::remove_dir(&app);
    }
    let tmp = dst.join("tmp");
    if tmp.is_dir() {
        let _ = fs::rename(&tmp, dst.join("tool"));
    }
}

fn inno_extract(archive: &Path, dst: &Path) -> Result<(), String> {
    let status = Command::new("innoextract")
        .arg("-s")
        .arg("-d")
        .arg(dst)
        .arg(archive)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map_err(|e| format!("spawn innoextract: {e}"))?;
    if !status.success() {
        return Err(format!("innoextract {status} (Inno version unsupported?)"));
    }
    hoist_inno_layout(dst);
    if !dir_has_files(dst) {
        return Err("innoextract produced no files".into());
    }
    Ok(())
}

fn wine_prefix() -> PathBuf {
    let home = std::env::var_os("HOME").expect("HOME unset");
    Path::new(&home).join(".cache/gz302ea-distill")
}

fn wine_spawn(installer: &Path, dst_name: &str) -> std::io::Result<Child> {
    Command::new("wine")
        .arg(installer)
        .arg("/VERYSILENT")
        .arg("/SUPPRESSMSGBOXES")
        .arg("/NORESTART")
        .arg(format!("/DIR=C:\\payload\\{dst_name}"))
        .env("WINEPREFIX", wine_prefix())
        .env("WINEDEBUG", "-all")
        .env("WINEDLLOVERRIDES", "mscoree=d;mshtml=d")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
}

/// Wait for the child, killing it after WINE_TIMEOUT (some firmware tools
/// hang in [Run] under wine after the payload has already landed). While
/// waiting, invoke `tick` — used by the {tmp} capture method.
fn wine_wait(mut child: Child, mut tick: impl FnMut()) {
    let start = Instant::now();
    loop {
        tick();
        match child.try_wait() {
            Ok(Some(_)) => return,
            Ok(None) if start.elapsed() > WINE_TIMEOUT => {
                let _ = child.kill();
                let _ = child.wait();
                return;
            }
            Ok(None) => std::thread::sleep(Duration::from_millis(50)),
            Err(_) => return,
        }
    }
}

/// Visit every Temp/is-*.tmp staging dir in the wine prefix.
fn for_each_tmp_stage(mut f: impl FnMut(&Path)) {
    let users = wine_prefix().join("drive_c/users");
    let Ok(rd) = fs::read_dir(users) else { return };
    for user in rd.flatten() {
        let temp = user.path().join("AppData/Local/Temp");
        let Ok(td) = fs::read_dir(temp) else { continue };
        for e in td.flatten() {
            let p = e.path();
            let name = e.file_name();
            let name = name.to_string_lossy();
            if p.is_dir() && name.starts_with("is-") && name.ends_with(".tmp") {
                f(&p);
            }
        }
    }
}

/// Copy the contents of every Temp/is-*.tmp/<pkg>/ dir into `cap`.
fn scrape_tmp(cap: &Path) {
    for_each_tmp_stage(|stage| {
        let Ok(inner) = fs::read_dir(stage) else {
            return;
        };
        for pkg in inner.flatten() {
            if pkg.path().is_dir() {
                let _ = copy_dir(&pkg.path(), cap);
            }
        }
    });
}

/// Remove leftover staging dirs (a killed installer — the light-bar tool
/// hangs under wine — never cleans its {tmp}, and a later scrape would
/// sweep the stale payload into the wrong component).
fn clear_tmp() {
    for_each_tmp_stage(|stage| {
        let _ = fs::remove_dir_all(stage);
    });
}

/// Drop Inno copy artifacts from a {tmp} capture: the setup helper and
/// is-*.tmp mid-copy files (their finished counterparts have real names).
fn clean_capture(cap: &Path) {
    let Ok(rd) = fs::read_dir(cap) else { return };
    for e in rd.flatten() {
        let name = e.file_name();
        let name = name.to_string_lossy().into_owned();
        let mid_copy = name.starts_with("is-") && name.ends_with(".tmp");
        if name == "_setup64.tmp" || mid_copy {
            let _ = fs::remove_file(e.path());
        }
    }
}

fn distill(pack: &Path, c: &Comp) -> Result<usize, String> {
    let src = pack.join(c.file);
    if !src.is_file() {
        return Err(format!("missing {}", c.file));
    }
    let dst = pack.join("Extracted").join(c.dst);
    fs::create_dir_all(&dst).map_err(|e| format!("mkdir {}: {e}", dst.display()))?;

    // For the Inno-stream methods, innoextract (any OS, no code execution)
    // is preferred; wine is the unix fallback.
    if c.method != Method::SevenZ && innoextract_available() {
        match inno_extract(&src, &dst) {
            Ok(()) => return Ok(inf_count(&dst)),
            Err(e) if wine_available() => {
                warn(&format!("{}: {e} — falling back to wine", c.dst));
                // Clear the partial attempt before the wine run repopulates.
                let _ = fs::remove_dir_all(&dst);
                fs::create_dir_all(&dst).map_err(|e| format!("mkdir {}: {e}", dst.display()))?;
            }
            Err(e) => return Err(e),
        }
    }

    match c.method {
        Method::SevenZ => seven_z(&src, &dst)?,
        Method::Wine => {
            let child = wine_spawn(&src, c.dst).map_err(|e| format!("spawn wine: {e}"))?;
            wine_wait(child, || {});
            let payload = wine_prefix().join("drive_c/payload").join(c.dst);
            if !dir_has_files(&payload) {
                return Err("no payload landed in wine prefix".into());
            }
            copy_dir(&payload, &dst).map_err(|e| format!("copy payload: {e}"))?;
        }
        Method::WineTmp => {
            let cap = dst.join("tool");
            fs::create_dir_all(&cap).map_err(|e| format!("mkdir {}: {e}", cap.display()))?;
            clear_tmp();
            let child = wine_spawn(&src, c.dst).map_err(|e| format!("spawn wine: {e}"))?;
            wine_wait(child, || scrape_tmp(&cap));
            clean_capture(&cap);
            // The /DIR payload (usually just the install .bat) rides along too.
            let payload = wine_prefix().join("drive_c/payload").join(c.dst);
            if dir_has_files(&payload) {
                let _ = copy_dir(&payload, &dst);
            }
            if !dir_has_files(&cap) {
                return Err("nothing captured from Inno {tmp}".into());
            }
        }
    }
    Ok(inf_count(&dst))
}

fn main() {
    let pack = PathBuf::from(std::env::args().nth(1).unwrap_or_else(|| ".".into()));
    if !pack.is_dir() {
        fail(&format!("not a directory: {}", pack.display()));
        std::process::exit(1);
    }

    let Some(sz) = sevenz() else {
        fail("no 7-Zip binary found on PATH (looked for 7z, 7zz, 7za)");
        std::process::exit(1);
    };
    info(&format!("using {sz}"));
    let inno_ok = innoextract_available() || wine_available();
    if !inno_ok {
        warn(if cfg!(unix) {
            "neither innoextract nor wine found — Inno-stream components will be skipped"
        } else {
            "innoextract not found — Inno-stream components will be skipped"
        });
    }

    let mut failed = 0u32;
    let mut skipped = 0u32;
    let mut infs = 0usize;
    for c in COMPONENTS {
        let dst = pack.join("Extracted").join(c.dst);
        if dir_has_files(&dst) {
            infs += inf_count(&dst);
            ok(&format!("{} (already distilled)", c.dst));
            continue;
        }
        if c.method != Method::SevenZ && !inno_ok {
            warn(&format!(
                "{} skipped (needs innoextract, or wine on unix)",
                c.dst
            ));
            skipped += 1;
            continue;
        }
        info(&format!("distilling {} ← {}", c.dst, c.file));
        match distill(&pack, c) {
            Ok(n) => {
                infs += n;
                ok(&format!("{}  infs:{n}", c.dst));
            }
            Err(e) => {
                let _ = fs::remove_dir_all(&dst);
                fail(&format!("{}: {e}", c.dst));
                failed += 1;
            }
        }
    }

    if cfg!(unix) {
        let _ = fs::remove_dir_all(wine_prefix());
    }

    if failed == 0 && skipped == 0 {
        ok(&format!(
            "all {} components distilled — {infs} INFs total",
            COMPONENTS.len()
        ));
    } else {
        warn(&format!(
            "{} ok, {failed} failed, {skipped} skipped — {infs} INFs",
            COMPONENTS.len() as u32 - failed - skipped
        ));
    }
    std::process::exit(i32::from(failed > 0));
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeSet;

    const MANIFEST: &str = include_str!("../../manifest.tsv");

    #[test]
    fn component_table_is_sane() {
        assert_eq!(COMPONENTS.len(), 22);
        let dsts: BTreeSet<_> = COMPONENTS.iter().map(|c| c.dst).collect();
        let files: BTreeSet<_> = COMPONENTS.iter().map(|c| c.file).collect();
        assert_eq!(dsts.len(), COMPONENTS.len(), "duplicate dst");
        assert_eq!(files.len(), COMPONENTS.len(), "duplicate file");
    }

    #[test]
    fn every_component_file_is_in_the_manifest() {
        let manifest_names: BTreeSet<_> = MANIFEST
            .lines()
            .map(str::trim)
            .filter(|l| !l.is_empty() && !l.starts_with('#'))
            .map(|l| l.split_whitespace().nth(1).unwrap())
            .collect();
        for c in COMPONENTS {
            assert!(
                manifest_names.contains(c.file),
                "{} not in manifest.tsv",
                c.file
            );
        }
    }

    #[test]
    fn hoist_aligns_innoextract_layout() {
        let dir = std::env::temp_dir().join("gz302ea-distill-test-hoist");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join("app/drivers")).unwrap();
        fs::write(dir.join("app/drivers/x.inf"), b"x").unwrap();
        fs::create_dir_all(dir.join("tmp")).unwrap();
        fs::write(dir.join("tmp/y.bat"), b"y").unwrap();
        hoist_inno_layout(&dir);
        assert!(dir.join("drivers/x.inf").is_file());
        assert!(dir.join("tool/y.bat").is_file());
        assert!(!dir.join("app").exists());
        assert!(!dir.join("tmp").exists());
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn clean_capture_drops_inno_artifacts() {
        let dir = std::env::temp_dir().join("gz302ea-distill-test-clean");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        for f in ["_setup64.tmp", "is-ABCDE.tmp", "7z.exe"] {
            fs::write(dir.join(f), b"x").unwrap();
        }
        clean_capture(&dir);
        let left: Vec<_> = fs::read_dir(&dir)
            .unwrap()
            .flatten()
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .collect();
        assert_eq!(left, vec!["7z.exe"]);
        let _ = fs::remove_dir_all(&dir);
    }
}
