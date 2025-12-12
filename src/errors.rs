use std::io;

#[derive(Debug)]
pub enum WmError {
    X11(X11Error),
    Io(io::Error),
    Config(ConfigError),
    Block(BlockError),
    Autostart(String, io::Error),
}

#[derive(Debug)]
pub enum X11Error {
    ConnectError(x11rb::errors::ConnectError),
    ConnectionError(x11rb::errors::ConnectionError),
    ReplyError(x11rb::errors::ReplyError),
    ReplyOrIdError(x11rb::errors::ReplyOrIdError),
    DisplayOpenFailed,
    FontLoadFailed(String),
    DrawCreateFailed,
}

#[derive(Debug)]
pub enum ConfigError {
    LuaError(String),
    InvalidModkey(String),
    UnknownKey(String),
    UnknownAction(String),
    UnknownBlockCommand(String),
    MissingCommandArg { command: String, field: String },
    ValidationError(String),
}

#[derive(Debug)]
pub enum BlockError {
    Io(io::Error),
    ParseInt(std::num::ParseIntError),
    MissingFile(String),
    InvalidData(String),
    CommandFailed(String),
}

impl std::fmt::Display for WmError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::X11(error) => write!(f, "{}", error),
            Self::Io(error) => write!(f, "{}", error),
            Self::Config(error) => write!(f, "{}", error),
            Self::Block(error) => write!(f, "{}", error),
            Self::Autostart(command, error) => write!(
                f,
                "Failed to spawn autostart command '{}': {}",
                command, error
            ),
        }
    }
}

impl std::error::Error for WmError {}

impl std::fmt::Display for X11Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::ConnectError(err) => write!(f, "{}", err),
            Self::ConnectionError(err) => write!(f, "{}", err),
            Self::ReplyError(err) => write!(f, "{}", err),
            Self::ReplyOrIdError(err) => write!(f, "{}", err),
            Self::DisplayOpenFailed => write!(f, "failed to open X11 display"),
            Self::FontLoadFailed(font_name) => write!(f, "failed to load Xft font: {}", font_name),
            Self::DrawCreateFailed => write!(f, "failed to create XftDraw"),
        }
    }
}

impl std::error::Error for X11Error {}

impl std::fmt::Display for ConfigError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::LuaError(msg) => write!(f, "{}", msg),
            Self::InvalidModkey(msg) => write!(f, "{}", msg),
            Self::UnknownKey(msg) => write!(f, "{}", msg),
            Self::UnknownAction(msg) => write!(f, "{}", msg),
            Self::UnknownBlockCommand(msg) => write!(f, "{}", msg),
            Self::MissingCommandArg { command, field } => {
                write!(f, "{} command requires {}", command, field)
            }
            Self::ValidationError(msg) => write!(f, "{}", msg),
        }
    }
}

impl std::error::Error for ConfigError {}

impl std::fmt::Display for BlockError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Io(err) => write!(f, "Block I/O error: {}", err),
            Self::ParseInt(err) => write!(f, "Block parse error: {}", err),
            Self::MissingFile(path) => write!(f, "Block missing file: {}", path),
            Self::InvalidData(msg) => write!(f, "Block invalid data: {}", msg),
            Self::CommandFailed(msg) => write!(f, "Block command failed: {}", msg),
        }
    }
}

impl std::error::Error for BlockError {}

impl<T: Into<X11Error>> From<T> for WmError {
    fn from(value: T) -> Self {
        Self::X11(value.into())
    }
}

impl From<io::Error> for WmError {
    fn from(value: io::Error) -> Self {
        Self::Io(value)
    }
}

impl From<ConfigError> for WmError {
    fn from(value: ConfigError) -> Self {
        Self::Config(value)
    }
}

impl From<BlockError> for WmError {
    fn from(value: BlockError) -> Self {
        Self::Block(value)
    }
}

impl From<io::Error> for BlockError {
    fn from(value: io::Error) -> Self {
        BlockError::Io(value)
    }
}

impl From<std::num::ParseIntError> for BlockError {
    fn from(value: std::num::ParseIntError) -> Self {
        BlockError::ParseInt(value)
    }
}

impl From<x11rb::errors::ConnectError> for X11Error {
    fn from(value: x11rb::errors::ConnectError) -> Self {
        X11Error::ConnectError(value)
    }
}

impl From<x11rb::errors::ConnectionError> for X11Error {
    fn from(value: x11rb::errors::ConnectionError) -> Self {
        X11Error::ConnectionError(value)
    }
}

impl From<x11rb::errors::ReplyError> for X11Error {
    fn from(value: x11rb::errors::ReplyError) -> Self {
        X11Error::ReplyError(value)
    }
}

impl From<x11rb::errors::ReplyOrIdError> for X11Error {
    fn from(value: x11rb::errors::ReplyOrIdError) -> Self {
        X11Error::ReplyOrIdError(value)
    }
}

impl From<mlua::Error> for ConfigError {
    fn from(err: mlua::Error) -> Self {
        ConfigError::LuaError(err.to_string())
    }
}

pub trait LuaResultExt<T> {
    fn lua_context(self, context: &str) -> Result<T, ConfigError>;
}

impl<T> LuaResultExt<T> for Result<T, mlua::Error> {
    fn lua_context(self, context: &str) -> Result<T, ConfigError> {
        self.map_err(|e| ConfigError::LuaError(format!("{}: {}", context, e)))
    }
}
