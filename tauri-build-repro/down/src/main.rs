//! Same as minimal-cargo: gives the downstream crate a bin target for the command-matrix
//! cells such as `cargo build -p down`.
fn main() {
    println!("{}", down::v());
}
