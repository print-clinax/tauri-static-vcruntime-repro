//! Mirrors tauri-build 2.7.1's static_vcruntime behaviour; REPRO_MODE picks the control.
//!
//! REPRO_MODE values:
//! - `stub` (default): write the `msvcrt.lib` stub + `rustc-link-search`, no neutralizing
//!   args.
//! - `no_stub`: emit `rustc-link-search` only, leave the directory empty.
//! - `stub_and_args`: stub + the full `/NODEFAULTLIB:`/`/DEFAULTLIB:` set (as upstream).
//! - `empty_file`: a 0-byte `msvcrt.lib` under the same name + `rustc-link-search`.
//! - `name_lib`: inverse control - the same bytes under `foo.lib` (shadows no CRT name) +
//!   `rustc-link-search`.
//! - `libpath`: fix option 1 prototype - stub + full arg set, but `/LIBPATH:` instead of
//!   `rustc-link-search`, so it only applies to the package's own link.
use std::io::Write as _;
use std::{env, fs, path::Path};

/// Copied verbatim from tauri-build 2.7.1's `override_msvcrt_lib`: the x86_64 machine
/// header (2 bytes) plus an 80-byte `.drectve`-only member, i.e. an 82-byte `msvcrt.lib`.
const MACHINE: &[u8] = &[0x64, 0x86];
const BYTES: &[u8] = &[
    1, 0, 94, 3, 96, 98, 60, 0, 0, 0, 1, 0, 0, 0, 0, 0, 132, 1, 46, 100,
    114, 101, 99, 116, 118, 101, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 60, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 10, 16, 0, 46, 100,
    114, 101, 99, 116, 118, 101, 0, 0, 0, 0, 1, 0, 0, 0, 3, 0, 4, 0, 0, 0,
];

fn main() {
    println!("cargo:rerun-if-env-changed=REPRO_MODE");
    let mode = env::var("REPRO_MODE").unwrap_or_else(|_| "stub".into());
    let out_dir = env::var("OUT_DIR").unwrap();

    // Only this control deliberately uses a different file name, to test whether the name
    // itself is the essential ingredient.
    let lib_name = if mode == "name_lib" {
        "foo.lib"
    } else {
        "msvcrt.lib"
    };

    if mode != "no_stub" {
        let path = Path::new(&out_dir).join(lib_name);
        if let Ok(mut f) = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&path)
        {
            if mode == "empty_file" {
                // Control: no stub, just a 0-byte file with the same name.
                f.write_all(&[]).unwrap();
            } else {
                f.write_all(MACHINE).unwrap();
                f.write_all(BYTES).unwrap();
            }
        }
    }

    if mode == "libpath" {
        // Fix option 1: keep the search path package-scoped so it does not leak downstream.
        println!("cargo:rustc-link-arg=/LIBPATH:{out_dir}");
    } else {
        // This is the line that propagates to dependents (tauri-build 2.7.1 emits it too).
        println!("cargo:rustc-link-search=native={out_dir}");
    }

    if mode == "stub_and_args" || mode == "libpath" {
        // Control B: verbatim copy of what tauri-build 2.7.1 emits for its own package
        // (8 NODEFAULTLIB + 3 DEFAULTLIB flags).
        for flag in [
            "/NODEFAULTLIB:libvcruntimed.lib",
            "/NODEFAULTLIB:vcruntime.lib",
            "/NODEFAULTLIB:vcruntimed.lib",
            "/NODEFAULTLIB:libcmtd.lib",
            "/NODEFAULTLIB:msvcrt.lib",
            "/NODEFAULTLIB:msvcrtd.lib",
            "/NODEFAULTLIB:libucrt.lib",
            "/NODEFAULTLIB:libucrtd.lib",
            "/DEFAULTLIB:libcmt.lib",
            "/DEFAULTLIB:libvcruntime.lib",
            "/DEFAULTLIB:ucrt.lib",
        ] {
            println!("cargo:rustc-link-arg={flag}");
        }
    }
}
