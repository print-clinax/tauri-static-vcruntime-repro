//! Stands in for the real tauri crate's single build-script directive: `cargo:dev` (read
//! as `DEP_TAURI_DEV` by tauri-build).
fn main() {
    println!("cargo:dev=false");
}
