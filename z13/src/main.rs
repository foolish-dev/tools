// z13 — setup + optimize for ASUS ROG Flow Z13 GZ302EA-RU004W (Arch Linux)
//
// Rust port of z13.sh, behavior-faithful:
//   z13                setup, then reboot; run 'z13 --optimize' after
//   z13 --optimize     post-reboot optimization
//   z13 --no-reboot    setup + optimize inline (testing)
//   z13 --status       verify current state without making changes
//   z13 --fix-touchpad rebind/uninhibit touchpad frozen by armoury crate
//
// Mutating modes self-escalate via sudo; --status is read-only and runs
// unprivileged (deviation from the bash version, which always escalated).

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};

/// 20 GiB iGPU VRAM cap (pages × 4 KiB).
const TTM: &str = "5242880";

const GRN: &str = "\x1b[0;32m";
const RED: &str = "\x1b[0;31m";
const YLW: &str = "\x1b[1;33m";
const BLU: &str = "\x1b[0;34m";
const RST: &str = "\x1b[0m";

static FAIL: AtomicU32 = AtomicU32::new(0);

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
    FAIL.fetch_add(1, Ordering::Relaxed);
}

fn failures() -> u32 {
    FAIL.load(Ordering::Relaxed)
}

fn have(cmd: &str) -> bool {
    Command::new(cmd)
        .arg("--version")
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .is_ok()
}

fn run(program: &str, args: &[&str]) -> bool {
    Command::new(program)
        .args(args)
        .status()
        .is_ok_and(|s| s.success())
}

fn run_quiet(program: &str, args: &[&str]) -> bool {
    Command::new(program)
        .args(args)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .is_ok_and(|s| s.success())
}

fn output_of(program: &str, args: &[&str]) -> String {
    Command::new(program)
        .args(args)
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_default()
}

fn read(path: impl AsRef<Path>) -> String {
    fs::read_to_string(path)
        .unwrap_or_default()
        .trim()
        .to_string()
}

fn euid() -> u32 {
    // Uid: <real> <effective> <saved> <fs>
    fs::read_to_string("/proc/self/status")
        .ok()
        .and_then(|s| {
            s.lines()
                .find(|l| l.starts_with("Uid:"))
                .and_then(|l| l.split_whitespace().nth(2).and_then(|v| v.parse().ok()))
        })
        .unwrap_or(u32::MAX)
}

fn escalate() {
    if euid() == 0 {
        return;
    }
    let exe = std::env::current_exe().expect("current_exe");
    let args: Vec<String> = std::env::args().skip(1).collect();
    use std::os::unix::process::CommandExt;
    let err = Command::new("sudo").arg("-E").arg(exe).args(args).exec();
    eprintln!("exec sudo: {err}");
    std::process::exit(1);
}

// ---------------------------------------------------------------- ROG key

static ROG_KEY_DONE: AtomicBool = AtomicBool::new(false);

const RYZEN_SMU_DROPIN: &str = "[Service]\nExecStart=/bin/sh -c 'for f in /sys/kernel/ryzen_smu_drv/smu_args /sys/kernel/ryzen_smu_drv/mp1_smu_cmd /sys/kernel/ryzen_smu_drv/rsmu_cmd; do [ -e \"$$f\" ] && chgrp input \"$$f\" && chmod g+w \"$$f\" || true; done'\n";

fn setup_rog_key() {
    if ROG_KEY_DONE.swap(true, Ordering::Relaxed) {
        return;
    }

    let Some(real_user) = std::env::var("SUDO_USER").ok().filter(|u| !u.is_empty()) else {
        warn("SUDO_USER unset — ROG key setup skipped");
        return;
    };

    if !have("z13ctl") {
        warn("z13ctl not found — ROG key setup skipped");
        return;
    }

    let rules = Path::new("/etc/udev/rules.d/99-z13ctl.rules");
    let svc = Path::new("/etc/systemd/system/z13ctl-perms.service");
    let dropin_dir = Path::new("/etc/systemd/system/z13ctl-perms.service.d");
    let dropin = dropin_dir.join("ryzen-smu.conf");
    let mut rules_changed = false;
    let mut perms_changed = false;

    // z13ctl setup writes 99-z13ctl.rules granting the group access to all
    // ASUS devices and installs z13ctl-perms.service for the battery
    // attribute that appears late in the asus_nb_wmi probe sequence.
    if !rules.is_file() || !read(rules).contains(r#"GROUP="input""#) {
        if run("z13ctl", &["setup", "--group", "input"]) {
            ok("z13ctl udev rules installed/updated");
            rules_changed = true;
            perms_changed = true; // setup may have (re)installed the service
        } else {
            fail("z13ctl setup");
        }
    }

    // Safety: z13ctl setup may emit the perms service with the wrong group.
    if svc.is_file() {
        let content = fs::read_to_string(svc).unwrap_or_default();
        if content.contains("chgrp users") {
            let bak = svc.with_extension("service.bak");
            if !bak.exists() {
                let _ = fs::copy(svc, &bak);
            }
            if fs::write(svc, content.replace("chgrp users", "chgrp input")).is_ok() {
                ok("z13ctl-perms.service: corrected group users→input");
                perms_changed = true;
            } else {
                fail("z13ctl-perms.service group fix");
            }
        }
    }

    // Move ryzen_smu perms into a drop-in so future z13ctl setup runs can't
    // erase them. Gated on the parent service existing — without it the
    // drop-in is orphaned and the restart below will fail.
    // `$$f` is systemd's escape for a literal `$f` — sh then expands it.
    if svc.is_file() && !dropin.is_file() {
        let _ = fs::create_dir_all(dropin_dir);
        if fs::write(&dropin, RYZEN_SMU_DROPIN).is_ok() {
            ok("z13ctl-perms: ryzen_smu drop-in installed");
            perms_changed = true;
        } else {
            fail("ryzen_smu drop-in write");
        }
    }

    if perms_changed && svc.is_file() {
        run_quiet("systemctl", &["daemon-reload"]);
        if run("systemctl", &["restart", "z13ctl-perms.service"]) {
            ok("z13ctl-perms.service restarted");
        } else {
            fail("z13ctl-perms.service restart");
        }
    }

    if rules_changed {
        run_quiet("udevadm", &["control", "--reload-rules"]);
        // Narrow trigger to ASUS-vendor (0b05) HID/input devices so we don't
        // disconnect/reconnect every input device on the system.
        run_quiet(
            "udevadm",
            &[
                "trigger",
                "--subsystem-match=hidraw",
                "--subsystem-match=input",
                "--attr-match=idVendor=0b05",
            ],
        );
        ok("udev rules reloaded");
    }

    if !in_group(&real_user, "input") {
        if run("usermod", &["-aG", "input", &real_user]) {
            ok(&format!("{real_user} → input group (re-login required)"));
        } else {
            fail(&format!("usermod -aG input {real_user}"));
        }
    }
}

fn in_group(user: &str, group: &str) -> bool {
    output_of("id", &["-nG", user])
        .split_whitespace()
        .any(|g| g == group)
}

// -------------------------------------------------------------- touchpad

const TOUCHPAD_RULE: &str = r#"ACTION=="bind", SUBSYSTEM=="hid", DRIVER=="hid-generic", ATTRS{idVendor}=="0b05", ATTRS{name}=="*[Tt]ouchpad*", RUN+="/usr/bin/systemd-run --no-block /bin/sh -c 'modprobe hid_multitouch; echo %k >/sys/bus/hid/drivers/hid-generic/unbind; echo %k >/sys/bus/hid/drivers/hid-multitouch/bind'"
"#;

fn setup_touchpad_rebind() {
    let rule = Path::new("/etc/udev/rules.d/99-z13-touchpad.rules");
    if rule.is_file() && read(rule).contains("hid-multitouch/bind") {
        return;
    }
    // When z13ctl opens the ASUS HID control interface the MCU sometimes
    // resets, causing the touchpad to reconnect bound to hid-generic instead
    // of hid-multitouch. This rule catches that bind event and corrects it.
    // systemd-run --no-block runs the work outside udev's synchronous
    // timeout, so modprobe + sysfs writes can't deadlock.
    if fs::write(rule, TOUCHPAD_RULE).is_ok() {
        ok("touchpad rebind rule installed");
        run_quiet("udevadm", &["control", "--reload-rules"]);
    } else {
        fail("touchpad rebind rule write");
    }
}

fn is_touchpad_name(name: &str) -> bool {
    name.to_lowercase().contains("touchpad")
}

/// Best-guess name if a HID device is a touchpad. The HID parent's `name`
/// file is often empty (i2c-hid, ASUS composite USB); fall back to uevent
/// HID_NAME and to child input names, where libinput-style "*Touchpad*"
/// labels actually live.
fn hid_touchpad_name(dev: &Path) -> Option<String> {
    let n = read(dev.join("name"));
    if is_touchpad_name(&n) {
        return Some(n);
    }
    for line in fs::read_to_string(dev.join("uevent"))
        .unwrap_or_default()
        .lines()
    {
        if let Some(v) = line.strip_prefix("HID_NAME=") {
            if is_touchpad_name(v) {
                return Some(v.to_string());
            }
        }
    }
    let input = dev.join("input");
    if let Ok(rd) = fs::read_dir(input) {
        for e in rd.flatten() {
            let n = read(e.path().join("name"));
            if is_touchpad_name(&n) {
                return Some(n);
            }
        }
    }
    None
}

fn hid_driver(dev: &Path) -> String {
    fs::read_link(dev.join("driver"))
        .ok()
        .and_then(|t| t.file_name().map(|f| f.to_string_lossy().into_owned()))
        .unwrap_or_else(|| "none".into())
}

fn hid_devices() -> Vec<PathBuf> {
    fs::read_dir("/sys/bus/hid/devices")
        .map(|rd| rd.flatten().map(|e| e.path()).collect())
        .unwrap_or_default()
}

fn fix_touchpad() {
    let mut any = false;

    // HID path: rebind USB touchpad from hid-generic → hid-multitouch
    for dev in hid_devices() {
        let Some(name) = hid_touchpad_name(&dev) else {
            continue;
        };
        any = true;
        let id = dev
            .file_name()
            .unwrap_or_default()
            .to_string_lossy()
            .into_owned();
        match hid_driver(&dev).as_str() {
            "hid-generic" => {
                let _ = run_quiet("modprobe", &["hid_multitouch"]);
                let _ = fs::write("/sys/bus/hid/drivers/hid-generic/unbind", &id);
                if fs::write("/sys/bus/hid/drivers/hid-multitouch/bind", &id).is_ok() {
                    ok(&format!("touchpad rebound to hid-multitouch: {name}"));
                } else {
                    fail(&format!("rebind failed: {name}"));
                }
            }
            "hid-multitouch" => ok(&format!("touchpad already on hid-multitouch: {name}")),
            drv => warn(&format!("touchpad driver={drv}: {name}")),
        }
    }

    // input path: uninhibit if kernel-inhibited (covers I2C and USB)
    if let Ok(rd) = fs::read_dir("/sys/class/input") {
        for e in rd.flatten() {
            let inh = e.path().join("device/inhibited");
            if !inh.is_file() {
                continue;
            }
            // name lives next to inhibited in the input device dir
            let nm = read(e.path().join("device/name"));
            if !is_touchpad_name(&nm) {
                continue;
            }
            any = true;
            if read(&inh) == "1" {
                if fs::write(&inh, "0").is_ok() {
                    ok(&format!("touchpad uninhibited: {nm}"));
                } else {
                    fail(&format!("uninhibit failed: {nm}"));
                }
            } else {
                ok(&format!("touchpad not inhibited: {nm}"));
            }
        }
    }

    if !any {
        warn("no touchpad found");
    }
}

// ------------------------------------------------------------------ setup

const DPM_RULE: &str = "ACTION==\"add\", SUBSYSTEM==\"drm\", KERNEL==\"card*\", ATTR{device/power_dpm_force_performance_level}=\"auto\"\n";

fn setup() {
    let prod = read("/sys/devices/dmi/id/product_name");
    if !(prod.contains("Z13") && prod.contains("GZ302")) {
        warn(&format!("unexpected product: {prod}"));
    }

    if !have("pacman") {
        warn("pacman not found — package install skipped (non-Arch?)");
    } else {
        for pkg in ["rocm-opencl-runtime", "rocm-device-libs", "hip-runtime-amd"] {
            if run_quiet("pacman", &["-Qi", pkg]) {
                continue;
            }
            if run("pacman", &["-S", "--noconfirm", "--needed", pkg]) {
                ok(pkg);
            } else {
                fail(pkg);
            }
        }
    }

    let cmdline = read("/proc/cmdline");
    for p in ["iommu=pt", "amd_iommu=on"] {
        if !cmdline.split_whitespace().any(|t| t == p) {
            warn(&format!("{p} missing from cmdline"));
        }
    }

    let rule = Path::new("/etc/udev/rules.d/99-amdgpu-dpm.rules");
    if !rule.is_file() {
        if fs::write(rule, DPM_RULE).is_ok() {
            run_quiet("udevadm", &["control", "--reload-rules"]);
            // Rule fires on add; cards are already added, so set existing
            // ones directly.
            if let Ok(rd) = fs::read_dir("/sys/class/drm") {
                for e in rd.flatten() {
                    let lvl = e.path().join("device/power_dpm_force_performance_level");
                    if lvl.is_file() {
                        let _ = fs::write(&lvl, "auto");
                    }
                }
            }
            ok("amdgpu DPM udev rule created");
        } else {
            fail("amdgpu DPM rule write");
        }
    }

    setup_rog_key();
    setup_touchpad_rebind();
}

// ----------------------------------------------------------------- status

fn boot_entries() -> Vec<PathBuf> {
    let mut v: Vec<PathBuf> = fs::read_dir("/boot/loader/entries")
        .map(|rd| {
            rd.flatten()
                .map(|e| e.path())
                .filter(|p| {
                    let n = p
                        .file_name()
                        .unwrap_or_default()
                        .to_string_lossy()
                        .into_owned();
                    n.ends_with("linux.conf") && !n.contains(".bak")
                })
                .collect()
        })
        .unwrap_or_default();
    v.sort();
    v
}

fn status() {
    let pages = read("/sys/module/ttm/parameters/pages_limit");
    let pool = read("/sys/module/ttm/parameters/page_pool_size");
    if pages == TTM {
        ok(&format!("ttm.pages_limit={TTM}"));
    } else {
        warn(&format!("ttm.pages_limit={pages} (reboot pending?)"));
    }
    if pool == TTM {
        ok(&format!("ttm.page_pool_size={TTM}"));
    } else {
        warn(&format!("ttm.page_pool_size={pool} (reboot pending?)"));
    }

    if output_of(
        "systemctl",
        &["is-enabled", "systemd-networkd-wait-online.service"],
    ) == "masked"
    {
        ok("networkd-wait-online masked");
    } else {
        fail("networkd-wait-online not masked");
    }

    if run_quiet("systemctl", &["is-active", "--quiet", "systemd-oomd"]) {
        ok("systemd-oomd active");
    } else {
        fail("systemd-oomd not active");
    }

    let wmsf = read("/proc/sys/vm/watermark_scale_factor");
    if wmsf == "100" {
        ok("vm.watermark_scale_factor=100");
    } else {
        fail(&format!("vm.watermark_scale_factor={wmsf}"));
    }

    for f in boot_entries() {
        let name = f
            .file_name()
            .unwrap_or_default()
            .to_string_lossy()
            .into_owned();
        if read(&f).contains(&format!("ttm.pages_limit={TTM}")) {
            ok(&format!("bootloader patched: {name}"));
        } else {
            warn(&format!("bootloader not patched: {name}"));
        }
    }

    let mut tp_found = false;
    for dev in hid_devices() {
        let Some(name) = hid_touchpad_name(&dev) else {
            continue;
        };
        tp_found = true;
        match hid_driver(&dev).as_str() {
            "hid-multitouch" => ok(&format!("touchpad: hid-multitouch ({name})")),
            "hid-generic" => fail(&format!("touchpad: hid-generic — needs rebind ({name})")),
            drv => warn(&format!("touchpad: driver={drv} ({name})")),
        }
    }
    if !tp_found {
        warn("touchpad not found in HID devices (may be I2C)");
    }

    let tp_rule = Path::new("/etc/udev/rules.d/99-z13-touchpad.rules");
    if tp_rule.is_file() && read(tp_rule).contains("hid-multitouch/bind") {
        ok("touchpad rebind rule installed");
    } else {
        warn("touchpad rebind rule missing");
    }

    if have("z13ctl") {
        let rules = Path::new("/etc/udev/rules.d/99-z13ctl.rules");
        if rules.is_file() && read(rules).contains(r#"GROUP="input""#) {
            ok("z13ctl rules: GROUP=input");
        } else {
            fail("z13ctl rules missing or wrong group");
        }
        if Path::new("/etc/systemd/system/z13ctl-perms.service.d/ryzen-smu.conf").is_file() {
            ok("z13ctl-perms: ryzen_smu drop-in present");
        } else {
            warn("z13ctl-perms: ryzen_smu drop-in missing");
        }
        let real_user = std::env::var("SUDO_USER")
            .or_else(|_| std::env::var("USER"))
            .unwrap_or_default();
        if !real_user.is_empty() {
            if in_group(&real_user, "input") {
                ok(&format!("{real_user} in input group"));
            } else {
                fail(&format!("{real_user} not in input group"));
            }
        }
    } else {
        warn("z13ctl not installed");
    }

    if failures() == 0 {
        ok("all checks passed");
    }
}

// --------------------------------------------------------------- optimize

/// Patch a systemd-boot entry's options line: strip stale VRAM-cap tokens,
/// append the ttm params. None if there is no options line.
fn patched_options(content: &str, ttm: &str) -> Option<String> {
    if !content.lines().any(|l| l.starts_with("options ")) {
        return None;
    }
    let mut out: Vec<String> = Vec::new();
    for line in content.lines() {
        if let Some(rest) = line.strip_prefix("options ") {
            let kept: Vec<&str> = rest
                .split_whitespace()
                .filter(|t| {
                    !t.starts_with("amdgpu.gttsize=")
                        && !t.starts_with("ttm.pages_limit=")
                        && !t.starts_with("ttm.page_pool_size=")
                })
                .collect();
            out.push(format!(
                "options {} ttm.pages_limit={ttm} ttm.page_pool_size={ttm}",
                kept.join(" ")
            ));
        } else {
            out.push(line.to_string());
        }
    }
    Some(out.join("\n") + "\n")
}

fn optimize() {
    setup_rog_key();
    setup_touchpad_rebind();
    // The udev rule only fires on the next bind event; correct an
    // already-bound touchpad now so --no-reboot / --optimize leaves the
    // system fully fixed.
    fix_touchpad();

    let entries = boot_entries();
    if entries.is_empty() {
        fail("no systemd-boot entry found");
        return;
    }

    for entry in &entries {
        let name = entry
            .file_name()
            .unwrap_or_default()
            .to_string_lossy()
            .into_owned();
        let content = fs::read_to_string(entry).unwrap_or_default();
        if content.contains(&format!("ttm.pages_limit={TTM}")) {
            continue;
        }
        let Some(patched) = patched_options(&content, TTM) else {
            fail(&format!("no options line in {name} — skipping"));
            continue;
        };
        // Preserve the original on first patch; never overwrite an existing .bak.
        let bak = PathBuf::from(format!("{}.bak", entry.display()));
        if !bak.exists() {
            let _ = fs::copy(entry, &bak);
        }
        if fs::write(entry, patched).is_ok() {
            ok(&format!("bootloader patched: {name}"));
        } else {
            fail(&format!("bootloader write: {name}"));
        }
    }

    if output_of(
        "systemctl",
        &["is-enabled", "systemd-networkd-wait-online.service"],
    ) != "masked"
    {
        let _ = run_quiet(
            "systemctl",
            &["disable", "--now", "systemd-networkd-wait-online.service"],
        );
        if run(
            "systemctl",
            &["mask", "systemd-networkd-wait-online.service"],
        ) {
            ok("networkd-wait-online masked");
        } else {
            fail("mask networkd-wait-online");
        }
    }

    if output_of("systemctl", &["is-enabled", "systemd-oomd.service"]) != "enabled" {
        if run("systemctl", &["enable", "--now", "systemd-oomd.service"]) {
            ok("systemd-oomd enabled");
        } else {
            fail("enable systemd-oomd");
        }
    }

    let conf = Path::new("/etc/sysctl.d/99-gz302-32gb.conf");
    let have_wmsf = fs::read_to_string(conf)
        .map(|c| {
            c.lines().any(|l| {
                let flat: String = l.split_whitespace().collect::<Vec<_>>().join("");
                flat.starts_with("vm.watermark_scale_factor=100")
            })
        })
        .unwrap_or(false);
    if !have_wmsf {
        if fs::write(conf, "vm.watermark_scale_factor = 100\n").is_ok()
            && run_quiet("sysctl", &["--system"])
        {
            ok("vm.watermark_scale_factor=100");
        } else {
            fail("sysctl --system");
        }
    }

    status();
}

// ------------------------------------------------------------------- main

fn usage() -> ! {
    eprintln!("usage: z13 [--optimize | --no-reboot | --status | --fix-touchpad]");
    std::process::exit(1);
}

fn main() {
    let mode = std::env::args().nth(1).unwrap_or_default();
    match mode.as_str() {
        "" => {
            escalate();
            setup();
            if failures() > 0 {
                std::process::exit(1);
            }
            info("rebooting in 10s — run 'z13 --optimize' after restart");
            std::thread::sleep(std::time::Duration::from_secs(10));
            let _ = run("shutdown", &["-r", "now"]);
        }
        "--optimize" => {
            escalate();
            optimize();
        }
        "--no-reboot" => {
            escalate();
            setup();
            if failures() > 0 {
                std::process::exit(1);
            }
            optimize();
        }
        "--status" => status(),
        "--fix-touchpad" => {
            escalate();
            fix_touchpad();
            if failures() == 0 {
                ok("touchpad OK");
            }
        }
        _ => usage(),
    }
    std::process::exit(i32::from(failures() > 0));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn options_line_is_patched_and_stale_tokens_stripped() {
        let content = "title Arch\nlinux /vmlinuz-linux\noptions root=/dev/nvme0n1p2 rw amdgpu.gttsize=1024 ttm.pages_limit=1 quiet\n";
        let got = patched_options(content, "5242880").unwrap();
        let options = got.lines().find(|l| l.starts_with("options ")).unwrap();
        assert!(options.contains("root=/dev/nvme0n1p2 rw quiet"));
        assert!(options.ends_with("ttm.pages_limit=5242880 ttm.page_pool_size=5242880"));
        assert!(!options.contains("amdgpu.gttsize"));
        assert!(!options.contains("ttm.pages_limit=1 "));
        assert!(got.lines().count() == 3);
    }

    #[test]
    fn no_options_line_is_an_error() {
        assert!(patched_options("title Arch\n", "5242880").is_none());
    }

    #[test]
    fn already_patched_content_would_be_stable() {
        let content = format!("options root=x rw ttm.pages_limit={TTM} ttm.page_pool_size={TTM}\n");
        let got = patched_options(&content, TTM).unwrap();
        assert_eq!(got.trim(), content.trim(), "patch must be idempotent");
    }

    #[test]
    fn touchpad_name_matching() {
        assert!(is_touchpad_name("ASUS TouchPad"));
        assert!(is_touchpad_name("ASUSTeK Computer Inc. GZ302EA Touchpad"));
        assert!(!is_touchpad_name("ASUS Keyboard"));
        assert!(!is_touchpad_name(""));
    }
}
