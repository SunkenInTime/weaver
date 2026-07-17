/// PR 03 has no daemon and therefore no provider transport to connect to.
/// Absence is inert; a declared endpoint fails loudly instead of pretending
/// the requested host capabilities are available. Unix-domain transport lands
/// with the daemon in PR 10.
pub const Client = struct {
    available: bool = false,

    pub fn init(_: *Client, endpoint: ?[]const u8) !void {
        if (endpoint != null) return error.UnsupportedHostEndpoint;
    }

    pub fn deinit(self: *Client) void {
        self.available = false;
    }

    pub fn take(_: *Client, _: []u8) ?[]const u8 {
        return null;
    }
};
