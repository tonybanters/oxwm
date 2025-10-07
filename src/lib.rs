pub mod bar;
pub mod config;
pub mod keyboard;
pub mod layout;
pub mod window_manager;

pub use bar::{BlockCommand, BlockConfig};
pub use keyboard::{Arg, KeyAction, handlers::Key};
pub use layout::{GapConfig, Layout, WindowGeometry};
pub use window_manager::WindowManager;
pub use x11rb::protocol::xproto::KeyButMask;

pub fn run() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let mut window_manager = WindowManager::new()?;
    let should_restart = window_manager.run()?;
    drop(window_manager);

    if should_restart {
        use std::os::unix::process::CommandExt;

        let user_binary = std::env::var("HOME")
            .map(|h| format!("{}/.local/share/oxwm/target/release/oxwm-config", h))
            .ok()
            .filter(|p| std::path::Path::new(p).exists())
            .unwrap_or_else(|| args[0].clone());

        let err = std::process::Command::new(&user_binary)
            .args(&args[1..])
            .exec();
        eprintln!("Failed to restart: {}", err);
    }

    Ok(())
}
