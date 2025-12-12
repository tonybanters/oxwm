use std::process::{Command, Stdio};

pub fn spawn_detached(cmd: &str) {
    // Double fork method - properly detach from parent
    let _ = Command::new("sh")
        .arg("-c")
        .arg(format!("nohup {} >/dev/null 2>&1 &", cmd))
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();
}

pub fn spawn_detached_with_args(program: &str, args: &[&str]) {
    let escaped_args: Vec<String> = args.iter().map(|a| shell_escape(a)).collect();
    let full_cmd = if escaped_args.is_empty() {
        program.to_string()
    } else {
        format!("{} {}", program, escaped_args.join(" "))
    };
    spawn_detached(&full_cmd)
}

fn shell_escape(s: &str) -> String {
    if s.contains(|c: char| c.is_whitespace() || c == '\'' || c == '"' || c == '\\') {
        format!("'{}'", s.replace('\'', "'\\''"))
    } else {
        s.to_string()
    }
}
