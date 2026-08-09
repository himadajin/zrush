//! zle-integration tests driving a real host zsh on a pty.
//!
//! Scope is the same as the zsh driver these tests replace: everything Rust
//! cannot verify on its own -- that the real zle/compsys wiring captures
//! candidates, ships them to the persistent worker, and applies the returned
//! plan to POSTDISPLAY/region_highlight/BUFFER under real key input.

mod apply;
mod async_plumbing;
mod cache;
mod capture;
mod confirm;
mod death;
mod dismiss;
mod fake;
mod fifo;
mod fixtures;
mod hist;
mod hist_compsys;
mod hist_config;
mod hist_delegation;
mod hist_lifecycle;
mod host;
mod pty;
mod select;
mod sendbreak;
mod tab;
