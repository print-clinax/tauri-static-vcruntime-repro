//! Makes `cargo build -p down` actually produce an executable, which is what surfaces the
//! link-time failure.
//!
//! A lib-only target is never linked, so `cargo build` would pass either way - this cell can
//! only be observed through a bin target.
fn main() {
    println!("{}", down::v());
}
