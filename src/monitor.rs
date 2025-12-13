use crate::client::TagMask;
use crate::errors::WmError;
use x11rb::protocol::xinerama::ConnectionExt as _;
use x11rb::protocol::xproto::{Screen, Window};
use x11rb::rust_connection::RustConnection;

type WmResult<T> = Result<T, WmError>;

#[derive(Debug, Clone)]
pub struct Monitor {
    pub layout_symbol: String,
    pub master_factor: f32,
    pub num_master: i32,
    pub monitor_number: usize,
    pub bar_y_position: i32,
    pub screen_x: i32,
    pub screen_y: i32,
    pub screen_width: i32,
    pub screen_height: i32,
    pub window_area_x: i32,
    pub window_area_y: i32,
    pub window_area_width: i32,
    pub window_area_height: i32,
    pub gap_inner_horizontal: i32,
    pub gap_inner_vertical: i32,
    pub gap_outer_horizontal: i32,
    pub gap_outer_vertical: i32,
    pub selected_tags_index: usize,
    pub selected_layout_index: usize,
    pub tagset: [u32; 2],
    pub show_bar: bool,
    pub top_bar: bool,
    pub clients_head: Option<Window>,
    pub selected_client: Option<Window>,
    pub stack_head: Option<Window>,
    pub bar_window: Option<Window>,
    pub layout_indices: [usize; 2],
}

impl Monitor {
    pub fn new(x: i32, y: i32, width: u32, height: u32) -> Self {
        Self {
            layout_symbol: String::from("[]"),
            master_factor: 0.55,
            num_master: 1,
            monitor_number: 0,
            bar_y_position: 0,
            screen_x: x,
            screen_y: y,
            screen_width: width as i32,
            screen_height: height as i32,
            window_area_x: x,
            window_area_y: y,
            window_area_width: width as i32,
            window_area_height: height as i32,
            gap_inner_horizontal: 3,
            gap_inner_vertical: 3,
            gap_outer_horizontal: 3,
            gap_outer_vertical: 3,
            selected_tags_index: 0,
            selected_layout_index: 0,
            tagset: [1, 1],
            show_bar: true,
            top_bar: true,
            clients_head: None,
            selected_client: None,
            stack_head: None,
            bar_window: None,
            layout_indices: [0, 1],
        }
    }

    pub fn contains_point(&self, x: i32, y: i32) -> bool {
        x >= self.screen_x
            && x < self.screen_x + self.screen_width
            && y >= self.screen_y
            && y < self.screen_y + self.screen_height
    }

    pub fn get_selected_tag(&self) -> TagMask {
        self.tagset[self.selected_tags_index]
    }
}

pub fn detect_monitors(
    connection: &RustConnection,
    screen: &Screen,
    _root: Window,
) -> WmResult<Vec<Monitor>> {
    let fallback_monitors = || {
        vec![Monitor::new(
            0,
            0,
            screen.width_in_pixels as u32,
            screen.height_in_pixels as u32,
        )]
    };

    let mut monitors = Vec::<Monitor>::new();

    let xinerama_active = connection
        .xinerama_is_active()
        .ok()
        .and_then(|cookie| cookie.reply().ok())
        .map_or(false, |reply| reply.state != 0);

    if xinerama_active {
        let Ok(xinerama_cookie) = connection.xinerama_query_screens() else {
            return Ok(fallback_monitors());
        };
        let Ok(xinerama_reply) = xinerama_cookie.reply() else {
            return Ok(fallback_monitors());
        };

        for screen_info in &xinerama_reply.screen_info {
            let has_valid_dimensions = screen_info.width > 0 && screen_info.height > 0;
            if !has_valid_dimensions {
                continue;
            }

            let x_position = screen_info.x_org as i32;
            let y_position = screen_info.y_org as i32;
            let width_in_pixels = screen_info.width as u32;
            let height_in_pixels = screen_info.height as u32;

            let is_duplicate_monitor = monitors.iter().any(|monitor| {
                monitor.screen_x == x_position
                    && monitor.screen_y == y_position
                    && monitor.screen_width == width_in_pixels as i32
                    && monitor.screen_height == height_in_pixels as i32
            });

            if !is_duplicate_monitor {
                monitors.push(Monitor::new(
                    x_position,
                    y_position,
                    width_in_pixels,
                    height_in_pixels,
                ));
            }
        }
    }

    if monitors.is_empty() {
        monitors = fallback_monitors();
    }

    monitors.sort_by(|a, b| match a.screen_y.cmp(&b.screen_y) {
        std::cmp::Ordering::Equal => a.screen_x.cmp(&b.screen_x),
        other => other,
    });

    Ok(monitors)
}
