// gz302ea-install — apply the distilled GZ302EA driver payloads on Windows
//
// The Rust replacement for the ASUS installer exes' install-time behavior:
// walks Extracted/ (produced by ../distill) in dependency order and stages
// every driver INF with `pnputil /add-driver ... /install`; Smart Display
// Control ships as an MSI and goes through msiexec. Run from an elevated
// prompt; `--dry-run` prints the exact commands instead (works anywhere,
// e.g. for inspection from Linux).
//
// Deliberately NOT covered, and asserted so by tests:
// - FW_BIOS_Updater / BIOS_EZFlash — the capsule INF stages a firmware flash
// - FW_PD / FW_Keyboard / FW_LightBar tools — run those exes directly
// - AuraWallpaper, VirtualAssistant, Armoury Crate — apps with own installers

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

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

enum Kind {
    /// pnputil every .inf under the component dir.
    Drivers,
    /// msiexec the named MSI inside the component dir.
    Msi(&'static str),
}

struct Step {
    dir: &'static str,
    kind: Kind,
}

/// Install order — chipset first, then GPU, network, the audio stack,
/// platform services, input, camera, peripherals. WLAN and BT carry the
/// identical MediaTek payload; pnputil no-ops the second copy.
const ORDER: &[Step] = &[
    Step {
        dir: "Chipset_AMD",
        kind: Kind::Drivers,
    },
    Step {
        dir: "GPU_AMD",
        kind: Kind::Drivers,
    },
    Step {
        dir: "WLAN_MediaTek",
        kind: Kind::Drivers,
    },
    Step {
        dir: "BT_MediaTek",
        kind: Kind::Drivers,
    },
    Step {
        dir: "Audio_Realtek_Dolby",
        kind: Kind::Drivers,
    },
    Step {
        dir: "Audio_CirrusAmp",
        kind: Kind::Drivers,
    },
    Step {
        dir: "Audio_DolbyAtmos",
        kind: Kind::Drivers,
    },
    Step {
        dir: "ASCI_v3",
        kind: Kind::Drivers,
    },
    Step {
        dir: "ArmouryCrateCI",
        kind: Kind::Drivers,
    },
    Step {
        dir: "SmartDisplayControl",
        kind: Kind::Msi("ASUSSmartDisplayControl.msi"),
    },
    Step {
        dir: "Touchpad_ASUS",
        kind: Kind::Drivers,
    },
    Step {
        dir: "Camera_AMD",
        kind: Kind::Drivers,
    },
    Step {
        dir: "Camera_MEP",
        kind: Kind::Drivers,
    },
    Step {
        dir: "CardReader_Genesys",
        kind: Kind::Drivers,
    },
    Step {
        dir: "USB4_Retimer_Parade",
        kind: Kind::Drivers,
    },
];

fn infs_under(dir: &Path) -> Vec<PathBuf> {
    let mut found = Vec::new();
    let mut stack = vec![dir.to_path_buf()];
    while let Some(d) = stack.pop() {
        let Ok(rd) = fs::read_dir(&d) else { continue };
        for e in rd.flatten() {
            let p = e.path();
            if p.is_dir() {
                stack.push(p);
            } else if p.extension().is_some_and(|x| x.eq_ignore_ascii_case("inf")) {
                found.push(p);
            }
        }
    }
    found.sort();
    found
}

fn run(program: &str, args: &[&str], dry: bool) -> bool {
    let shown = format!("{program} {}", args.join(" "));
    if dry {
        println!("    {shown}");
        return true;
    }
    match Command::new(program).args(args).output() {
        Ok(out) if out.status.success() => true,
        Ok(out) => {
            fail(&format!("{shown} → {}", out.status));
            let text = String::from_utf8_lossy(&out.stdout);
            if let Some(line) = text.lines().rev().find(|l| !l.trim().is_empty()) {
                println!("    {}", line.trim());
            }
            false
        }
        Err(e) => {
            fail(&format!("{shown}: {e}"));
            false
        }
    }
}

fn main() {
    let mut dry = false;
    let mut pack = PathBuf::from(".");
    for a in std::env::args().skip(1) {
        if a == "--dry-run" {
            dry = true;
        } else {
            pack = PathBuf::from(a);
        }
    }

    if !dry && !cfg!(windows) {
        fail("applying drivers only works on Windows — use --dry-run here");
        std::process::exit(1);
    }

    let extracted = pack.join("Extracted");
    if !extracted.is_dir() {
        fail(&format!(
            "{} not found — run gz302ea-fetch and gz302ea-distill first",
            extracted.display()
        ));
        std::process::exit(1);
    }

    let mut failed = 0u32;
    let mut staged = 0usize;
    for step in ORDER {
        let dir = extracted.join(step.dir);
        if !dir.is_dir() {
            fail(&format!("{} missing — re-run gz302ea-distill", step.dir));
            failed += 1;
            continue;
        }
        match &step.kind {
            Kind::Drivers => {
                let infs = infs_under(&dir);
                if infs.is_empty() {
                    fail(&format!("{}: no INFs found", step.dir));
                    failed += 1;
                    continue;
                }
                info(&format!("{} — {} INF(s)", step.dir, infs.len()));
                let mut bad = 0;
                for inf in &infs {
                    let p = inf.to_string_lossy();
                    if run("pnputil", &["/add-driver", &p, "/install"], dry) {
                        staged += 1;
                    } else {
                        bad += 1;
                    }
                }
                if bad == 0 {
                    ok(step.dir);
                } else {
                    fail(&format!("{}: {bad} INF(s) failed", step.dir));
                    failed += 1;
                }
            }
            Kind::Msi(name) => {
                let msi = dir.join(name);
                if !msi.is_file() {
                    fail(&format!("{}: {name} missing", step.dir));
                    failed += 1;
                    continue;
                }
                info(&format!("{} — msiexec {name}", step.dir));
                let p = msi.to_string_lossy();
                if run("msiexec", &["/i", &p, "/qn", "/norestart"], dry) {
                    ok(step.dir);
                } else {
                    failed += 1;
                }
            }
        }
    }

    warn("not covered here: BIOS/firmware (run the FW_* tools / EZ Flash), Armoury Crate, apps");
    if failed == 0 {
        ok(&format!(
            "{} component(s), {staged} INF(s) staged{} — reboot recommended",
            ORDER.len(),
            if dry { " (dry run)" } else { "" }
        ));
    } else {
        fail(&format!("{failed} component(s) failed"));
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeSet;

    const DISTILL_SRC: &str = include_str!("../../distill/src/main.rs");

    #[test]
    fn order_is_sane_and_excludes_firmware() {
        let dirs: BTreeSet<_> = ORDER.iter().map(|s| s.dir).collect();
        assert_eq!(dirs.len(), ORDER.len(), "duplicate step");
        for forbidden in [
            "FW_BIOS_Updater",
            "BIOS_EZFlash",
            "FW_PD_Updater",
            "FW_Keyboard_Updater",
            "FW_LightBar_Updater",
        ] {
            assert!(
                !dirs.contains(forbidden),
                "{forbidden} must never be installed"
            );
        }
        assert_eq!(ORDER[0].dir, "Chipset_AMD", "chipset must come first");
    }

    #[test]
    fn every_step_dir_exists_in_distill() {
        for s in ORDER {
            assert!(
                DISTILL_SRC.contains(&format!("\"{}\"", s.dir)),
                "{} is not a distill component",
                s.dir
            );
        }
    }

    #[test]
    fn inf_enumeration_is_recursive_case_insensitive_and_sorted() {
        let dir = std::env::temp_dir().join("gz302ea-install-test-infs");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join("b")).unwrap();
        fs::write(dir.join("b/z.INF"), b"x").unwrap();
        fs::write(dir.join("a.inf"), b"x").unwrap();
        fs::write(dir.join("readme.txt"), b"x").unwrap();
        let got = infs_under(&dir);
        let names: Vec<_> = got
            .iter()
            .map(|p| p.strip_prefix(&dir).unwrap().to_string_lossy().into_owned())
            .collect();
        assert_eq!(names, vec!["a.inf".to_string(), "b/z.INF".to_string()]);
        let _ = fs::remove_dir_all(&dir);
    }
}
