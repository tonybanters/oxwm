pub mod grid;
pub mod horizon;
pub mod monocle;
pub mod normie;
pub mod tabbed;
pub mod tiling;

use std::str::FromStr;

use x11rb::protocol::xproto::Window;

pub type LayoutBox = Box<dyn Layout>;

pub struct GapConfig {
    pub inner_horizontal: u32,
    pub inner_vertical: u32,
    pub outer_horizontal: u32,
    pub outer_vertical: u32,
}

pub enum LayoutType {
    Tiling,
    Normie,
    Grid,
    Monocle,
    Tabbed,
    Horizon,
}

impl LayoutType {
    pub fn to_boxed_layout(&self) -> LayoutBox {
        match self {
            Self::Tiling => Box::new(tiling::TilingLayout),
            Self::Normie => Box::new(normie::NormieLayout),
            Self::Grid => Box::new(grid::GridLayout),
            Self::Monocle => Box::new(monocle::MonocleLayout),
            Self::Tabbed => Box::new(tabbed::TabbedLayout),
            Self::Horizon => Box::new(horizon::HorizonLayout),
        }
    }

    pub fn next(&self) -> Self {
        match self {
            Self::Tiling => Self::Normie,
            Self::Normie => Self::Grid,
            Self::Grid => Self::Monocle,
            Self::Monocle => Self::Tabbed,
            Self::Tabbed => Self::Horizon,
            Self::Horizon => Self::Tiling,
        }
    }

    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Tiling => "tiling",
            Self::Normie => "normie",
            Self::Grid => "grid",
            Self::Monocle => "monocle",
            Self::Tabbed => "tabbed",
            Self::Horizon => "horizon",
        }
    }
}

impl FromStr for LayoutType {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, String> {
        match s.to_lowercase().as_str() {
            "tiling" => Ok(Self::Tiling),
            "normie" | "floating" => Ok(Self::Normie),
            "grid" => Ok(Self::Grid),
            "monocle" => Ok(Self::Monocle),
            "tabbed" => Ok(Self::Tabbed),
            "horizon" => Ok(Self::Horizon),
            _ => Err(format!("Invalid Layout Type: {}", s)),
        }
    }
}

pub fn layout_from_str(s: &str) -> Result<LayoutBox, String> {
    let layout_type = LayoutType::from_str(s)?;
    Ok(layout_type.to_boxed_layout())
}

pub fn next_layout(current_name: &str) -> &'static str {
    LayoutType::from_str(current_name)
        .ok()
        .map(|layout_type| layout_type.next())
        .unwrap_or(LayoutType::Tiling)
        .as_str()
}

pub trait Layout {
    fn arrange(
        &self,
        windows: &[Window],
        screen_width: u32,
        screen_height: u32,
        gaps: &GapConfig,
        master_factor: f32,
        num_master: i32,
        smartgaps_enabled: bool,
    ) -> Vec<WindowGeometry>;
    fn name(&self) -> &'static str;
    fn symbol(&self) -> &'static str;
}

#[derive(Clone)]
pub struct WindowGeometry {
    pub x_coordinate: i32,
    pub y_coordinate: i32,
    pub width: u32,
    pub height: u32,
}
