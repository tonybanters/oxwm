const std = @import("std");
const xlib = @import("x11/xlib.zig");
const Monitor = @import("monitor.zig").Monitor;

pub const Client = struct {
    name: [256]u8 = std.mem.zeroes([256]u8),
    min_aspect: f32 = 0,
    max_aspect: f32 = 0,
    x: i32 = 0,
    y: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,
    old_x: i32 = 0,
    old_y: i32 = 0,
    old_width: i32 = 0,
    old_height: i32 = 0,
    base_width: i32 = 0,
    base_height: i32 = 0,
    increment_width: i32 = 0,
    increment_height: i32 = 0,
    max_width: i32 = 0,
    max_height: i32 = 0,
    min_width: i32 = 0,
    min_height: i32 = 0,
    hints_valid: bool = false,
    border_width: i32 = 0,
    old_border_width: i32 = 0,
    tags: u32 = 0,
    is_fixed: bool = false,
    is_floating: bool = false,
    is_urgent: bool = false,
    never_focus: bool = false,
    old_state: bool = false,
    is_fullscreen: bool = false,
    next: ?*Client = null,
    stack_next: ?*Client = null,
    monitor: ?*Monitor = null,
    window: xlib.Window = 0,
};

/// Initialises a new `Client` for the given X window.
pub fn create(allocator: std.mem.Allocator, window: xlib.Window) ?*Client {
    const client = allocator.create(Client) catch return null;
    client.* = Client{ .window = window };
    return client;
}

/// Frees a client previously returned by `create`.
pub fn destroy(allocator: std.mem.Allocator, client: *Client) void {
    allocator.destroy(client);
}

/// Prepends `client` to the front of its monitor's client list.
pub fn attach(client: *Client) void {
    if (client.monitor) |monitor| {
        client.next = monitor.clients;
        monitor.clients = client;
    }
}

/// Removes `client` from its monitor's client list.
pub fn detach(client: *Client) void {
    if (client.monitor) |monitor| {
        var current_ptr: *?*Client = &monitor.clients;
        while (current_ptr.*) |current| {
            if (current == client) {
                current_ptr.* = client.next;
                return;
            }
            current_ptr = &current.next;
        }
    }
}

/// Prepends `client` to the front of its monitor's focus stack.
pub fn attachStack(client: *Client) void {
    if (client.monitor) |monitor| {
        client.stack_next = monitor.stack;
        monitor.stack = client;
    }
}

/// Removes `client` from its monitor's focus stack.
pub fn detachStack(client: *Client) void {
    if (client.monitor) |monitor| {
        var current_ptr: *?*Client = &monitor.stack;
        while (current_ptr.*) |current| {
            if (current == client) {
                current_ptr.* = client.stack_next;
                return;
            }
            current_ptr = &current.stack_next;
        }
    }
}

/// Searches all monitors for a client whose X window matches `window`.
///
/// `monitors` is the head of the monitor linked list.
pub fn windowToClient(monitors: ?*Monitor, window: xlib.Window) ?*Client {
    var current_monitor = monitors;
    while (current_monitor) |monitor| {
        var current_client = monitor.clients;
        while (current_client) |client| {
            if (client.window == window) return client;
            current_client = client.next;
        }
        current_monitor = monitor.next;
    }
    return null;
}

/// Returns true if `client` is visible on its monitor's currently selected
/// tag set.
pub fn isVisible(client: *Client) bool {
    if (client.monitor) |monitor| {
        return (client.tags & monitor.tagset[monitor.sel_tags]) != 0;
    }
    return false;
}

/// Returns true if `client` is visible on the given tag bitmask.
pub fn isVisibleOnTag(client: *Client, tags: u32) bool {
    return (client.tags & tags) != 0;
}

/// Returns the first non-floating, visible client at or after `client`.
pub fn nextTiled(client: ?*Client) ?*Client {
    var current = client;
    while (current) |iter| {
        if (!iter.is_floating and isVisible(iter)) return iter;
        current = iter.next;
    }
    return null;
}

/// Returns the first non-floating client on `client`'s monitor that shares
/// any tag with `client`. Used for `attach_aside` ordering.
pub fn nextTagged(client: *Client) ?*Client {
    const monitor = client.monitor orelse return null;
    var walked = monitor.clients;
    while (walked) |iter| {
        if (!iter.is_floating and isVisibleOnTag(iter, client.tags)) return iter;
        walked = iter.next;
    }
    return null;
}

/// Inserts `client` just after `target` in the monitor's client list.
/// Does nothing if they are on different monitors or target is null.
pub fn attachAfter(client: *Client, target: ?*Client) void {
    const at = target orelse {
        attachAside(client);
        return;
    };
    const monitor = at.monitor orelse {
        attachAside(client);
        return;
    };
    if (client.monitor != monitor) {
        attachAside(client);
        return;
    }
    client.next = at.next;
    at.next = client;
}

/// Inserts `client` just after the first client that shares its tags,
/// falling back to prepend if none exists.
pub fn attachAside(client: *Client) void {
    const at = nextTagged(client);
    if (at == null) {
        attach(client);
        return;
    }
    client.next = at.?.next;
    at.?.next = client;
}

/// Counts non-floating, visible clients on `monitor`.
pub fn countTiled(monitor: *Monitor) u32 {
    var count: u32 = 0;
    var current = nextTiled(monitor.clients);
    while (current) |client| {
        count += 1;
        current = nextTiled(client.next);
    }
    return count;
}

/// Returns the tiled client on `monitor` whose bounds contain (`point_x`,
/// `point_y`), excluding `exclude`.  Returns null if none found.
pub fn tiledWindowAt(exclude: *Client, monitor: *Monitor, point_x: i32, point_y: i32) ?*Client {
    const tags = monitor.tagset[monitor.sel_tags];
    var current = monitor.clients;

    while (current) |client| {
        if (client != exclude and !client.is_floating and (client.tags & tags) != 0) {
            const client_w = client.width + client.border_width * 2;
            const client_h = client.height + client.border_width * 2;

            if (point_x >= client.x and point_x < client.x + client_w and
                point_y >= client.y and point_y < client.y + client_h)
            {
                return client;
            }
        }
        current = client.next;
    }
    return null;
}

/// Moves `client` to just before `target` in the monitor's client list.
/// Does nothing if they are on different monitors.
pub fn insertBefore(client: *Client, target: *Client) void {
    const monitor = target.monitor orelse return;
    if (client.monitor != monitor) return;

    detach(client);

    if (monitor.clients == target) {
        client.next = target;
        monitor.clients = client;
        return;
    }

    var current = monitor.clients;
    while (current) |iter| {
        if (iter.next == target) {
            client.next = target;
            iter.next = client;
            return;
        }
        current = iter.next;
    }
}

/// Swaps the positions of `client_a` and `client_b` in their shared monitor's
/// client list.  Does nothing if they are on different monitors.
pub fn swapClients(client_a: *Client, client_b: *Client) void {
    const monitor = client_a.monitor orelse return;
    if (client_b.monitor != monitor) return;

    var prev_a: ?*Client = null;
    var prev_b: ?*Client = null;
    var iter = monitor.clients;

    while (iter) |client| {
        if (client.next == client_a) prev_a = client;
        if (client.next == client_b) prev_b = client;
        iter = client.next;
    }

    const next_a = client_a.next;
    const next_b = client_b.next;

    if (next_a == client_b) {
        client_a.next = next_b;
        client_b.next = client_a;
        if (prev_a) |prev| prev.next = client_b else monitor.clients = client_b;
    } else if (next_b == client_a) {
        client_b.next = next_a;
        client_a.next = client_b;
        if (prev_b) |prev| prev.next = client_a else monitor.clients = client_a;
    } else {
        client_a.next = next_b;
        client_b.next = next_a;
        if (prev_a) |prev| prev.next = client_b else monitor.clients = client_b;
        if (prev_b) |prev| prev.next = client_a else monitor.clients = client_a;
    }
}
