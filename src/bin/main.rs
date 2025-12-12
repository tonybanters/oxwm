use std::path::PathBuf;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    oxwm::signal::prevent_zombie_processes();

    let arguments: Vec<String> = std::env::args().collect();

    let mut custom_config_path: Option<PathBuf> = None;

    match arguments.get(1).map(|string| string.as_str()) {
        Some("--version") => {
            println!("oxwm {}", env!("CARGO_PKG_VERSION"));
            return Ok(());
        }
        Some("--help") => {
            print_help();
            return Ok(());
        }
        Some("--init") => {
            init_config()?;
            return Ok(());
        }
        Some("--config") => {
            if let Some(path) = arguments.get(2) {
                custom_config_path = Some(PathBuf::from(path));
            } else {
                eprintln!("Error: --config requires a path argument");
                std::process::exit(1);
            }
        }
        _ => {}
    }

    let (config, had_broken_config) = load_config(custom_config_path)?;

    let mut window_manager = oxwm::window_manager::WindowManager::new(config)?;

    if had_broken_config {
        window_manager.show_migration_overlay();
    }

    let should_restart = window_manager.run()?;

    drop(window_manager);

    if should_restart {
        use std::os::unix::process::CommandExt;
        let error = std::process::Command::new(&arguments[0]).args(&arguments[1..]).exec();
        eprintln!("Failed to restart: {}", error);
    }

    Ok(())
}

fn load_config(custom_path: Option<PathBuf>) -> Result<(oxwm::Config, bool), Box<dyn std::error::Error>> {
    let config_path = if let Some(path) = custom_path {
        path
    } else {
        let config_directory = get_config_path();
        let lua_path = config_directory.join("config.lua");

        if !lua_path.exists() {
            let ron_path = config_directory.join("config.ron");
            let had_ron_config = ron_path.exists();

            println!("No config found at {:?}", config_directory);
            println!("Creating default Lua config...");
            init_config()?;

            if had_ron_config {
                println!("\n NOTICE: OXWM has migrated to Lua configuration.");
                println!("   Your old config.ron has been preserved, but is no longer used.");
                println!("   Your settings have been reset to defaults.");
                println!("   Please manually port your configuration to the new Lua format.");
                println!("   See the new config.lua template for examples.\n");
            }
        }

        lua_path
    };

    let config_string = std::fs::read_to_string(&config_path)
        .map_err(|error| format!("Failed to read config file: {}", error))?;

    let config_directory = config_path.parent();

    match oxwm::config::parse_lua_config(&config_string, config_directory) {
        Ok(config) => Ok((config, false)),
        Err(_error) => {
            let template = include_str!("../../templates/config.lua");
            let config = oxwm::config::parse_lua_config(template, None)
                .map_err(|error| format!("Failed to parse default template config: {}", error))?;
            Ok((config, true))
        }
    }
}

fn init_config() -> Result<(), Box<dyn std::error::Error>> {
    let config_directory = get_config_path();
    std::fs::create_dir_all(&config_directory)?;

    let config_template = include_str!("../../templates/config.lua");
    let config_path = config_directory.join("config.lua");
    std::fs::write(&config_path, config_template)?;

    println!("✓ Config created at {:?}", config_path);
    println!("  Edit the file and reload with Mod+Shift+R");
    println!("  No compilation needed - changes take effect immediately!");

    Ok(())
}

fn get_config_path() -> PathBuf {
    dirs::config_dir()
        .expect("Could not find config directory")
        .join("oxwm")
}

fn print_help() {
    println!("OXWM - A dynamic window manager written in Rust\n");
    println!("USAGE:");
    println!("    oxwm [OPTIONS]\n");
    println!("OPTIONS:");
    println!("    --init              Create default config in ~/.config/oxwm/config.lua");
    println!("    --config <PATH>     Use custom config file");
    println!("    --version           Print version information");
    println!("    --help              Print this help message\n");
    println!("CONFIG:");
    println!("    Location: ~/.config/oxwm/config.lua");
    println!("    Edit the config file and use Mod+Shift+R to reload");
    println!("    No compilation needed - instant hot-reload!");
    println!("    LSP support included with oxwm.lua type definitions\n");
    println!("FIRST RUN:");
    println!("    Run 'oxwm --init' to create a config file");
    println!("    Or just start oxwm and it will create one automatically\n");
}
