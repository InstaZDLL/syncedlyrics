const std = @import("std");

pub const Response = struct {
    status: std.http.Status,
    body: []u8,

    pub fn deinit(self: *Response, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
        self.* = undefined;
    }
};

pub const Header = std.http.Header;

pub fn get(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    url: []const u8,
    extra_headers: []const Header,
) !Response {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &writer.writer,
        .extra_headers = extra_headers,
        .keep_alive = true,
    });
    var list = writer.toArrayList();
    return .{ .status = result.status, .body = try list.toOwnedSlice(allocator) };
}
