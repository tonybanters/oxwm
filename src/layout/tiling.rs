use super::{GapConfig, Layout, WindowGeometry};
use x11rb::protocol::xproto::Window;

pub struct TilingLayout;

struct GapValues {
    outer_horizontal: u32,
    outer_vertical: u32,
    inner_horizontal: u32,
    inner_vertical: u32,
}

struct FactValues {
    master_facts: f32,
    stack_facts: f32,
    master_remainder: i32,
    stack_remainder: i32,
}

impl TilingLayout {
    fn getgaps(gaps: &GapConfig, window_count: usize, smartgaps_enabled: bool) -> GapValues {
        let outer_enabled = if smartgaps_enabled && window_count == 1 {
            0
        } else {
            1
        };
        let inner_enabled = 1;

        GapValues {
            outer_horizontal: gaps.outer_horizontal * outer_enabled,
            outer_vertical: gaps.outer_vertical * outer_enabled,
            inner_horizontal: gaps.inner_horizontal * inner_enabled,
            inner_vertical: gaps.inner_vertical * inner_enabled,
        }
    }

    fn getfacts(
        window_count: usize,
        num_master: i32,
        master_size: i32,
        stack_size: i32,
    ) -> FactValues {
        let num_master = num_master.max(0) as usize;
        let master_facts = window_count.min(num_master) as f32;
        let stack_facts = if window_count > num_master {
            (window_count - num_master) as f32
        } else {
            0.0
        };

        let mut master_total = 0;
        let mut stack_total = 0;

        for i in 0..window_count {
            if i < num_master {
                master_total += (master_size as f32 / master_facts) as i32;
            } else {
                if stack_facts > 0.0 {
                    stack_total += (stack_size as f32 / stack_facts) as i32;
                }
            }
        }

        FactValues {
            master_facts,
            stack_facts,
            master_remainder: master_size - master_total,
            stack_remainder: stack_size - stack_total,
        }
    }
}

impl Layout for TilingLayout {
    fn name(&self) -> &'static str {
        super::LayoutType::Tiling.as_str()
    }

    fn symbol(&self) -> &'static str {
        "[]="
    }

    fn arrange(
        &self,
        windows: &[Window],
        screen_width: u32,
        screen_height: u32,
        gaps: &GapConfig,
        master_factor: f32,
        num_master: i32,
        smartgaps_enabled: bool,
    ) -> Vec<WindowGeometry> {
        let window_count = windows.len();
        if window_count == 0 {
            return Vec::new();
        }

        let gap_values = Self::getgaps(gaps, window_count, smartgaps_enabled);

        let outer_gap_horizontal = gap_values.outer_horizontal;
        let outer_gap_vertical = gap_values.outer_vertical;
        let inner_gap_horizontal = gap_values.inner_horizontal;
        let inner_gap_vertical = gap_values.inner_vertical;

        let mut stack_x = outer_gap_vertical as i32;
        let mut stack_y = outer_gap_horizontal as i32;
        let master_x = outer_gap_vertical as i32;
        let mut master_y = outer_gap_horizontal as i32;

        let num_master_usize = num_master.max(0) as usize;
        let master_count = window_count.min(num_master_usize);
        let stack_count = if window_count > num_master_usize {
            window_count - num_master_usize
        } else {
            0
        };

        let master_height = (screen_height as i32)
            - (2 * outer_gap_horizontal) as i32
            - (inner_gap_horizontal as i32 * (master_count.saturating_sub(1)) as i32);
        let stack_height = (screen_height as i32)
            - (2 * outer_gap_horizontal) as i32
            - (inner_gap_horizontal as i32 * stack_count.saturating_sub(1) as i32);
        let mut stack_width = (screen_width as i32) - (2 * outer_gap_vertical) as i32;
        let mut master_width = stack_width;

        if num_master > 0 && window_count > num_master_usize {
            stack_width =
                ((master_width as f32 - inner_gap_vertical as f32) * (1.0 - master_factor)) as i32;
            master_width = master_width - inner_gap_vertical as i32 - stack_width;
            stack_x = master_x + master_width + inner_gap_vertical as i32;
        }

        let facts = Self::getfacts(window_count, num_master, master_height, stack_height);

        let mut geometries = Vec::new();

        for (i, _window) in windows.iter().enumerate() {
            if i < num_master_usize {
                let window_height = (master_height as f32 / facts.master_facts) as i32
                    + if (i as i32) < facts.master_remainder {
                        1
                    } else {
                        0
                    };

                geometries.push(WindowGeometry {
                    x_coordinate: master_x,
                    y_coordinate: master_y,
                    width: master_width as u32,
                    height: window_height as u32,
                });

                master_y += window_height + inner_gap_horizontal as i32;
            } else {
                let window_height = if facts.stack_facts > 0.0 {
                    (stack_height as f32 / facts.stack_facts) as i32
                        + if ((i - num_master_usize) as i32) < facts.stack_remainder {
                            1
                        } else {
                            0
                        }
                } else {
                    stack_height
                };

                geometries.push(WindowGeometry {
                    x_coordinate: stack_x,
                    y_coordinate: stack_y,
                    width: stack_width as u32,
                    height: window_height as u32,
                });

                stack_y += window_height + inner_gap_horizontal as i32;
            }
        }

        geometries
    }
}
