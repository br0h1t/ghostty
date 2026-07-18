//! Outbound formatting for the Kitty drag-and-drop (OSC 72) protocol
//! (https://sw.kovidgoyal.net/kitty/drag-and-drop-protocol/).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The OSC introducer plus the Kitty drag-and-drop command number (72) that
/// every outbound event begins with.
const osc_prefix = "\x1b]72;";

/// The string terminator that ends every outbound OSC 72 escape code.
const osc_terminator = "\x1b\\";

/// Returns the largest raw slice size for one frame of a chunked transfer.
const max_chunk_raw = 4096;
const max_chunk_encoded = 3072;

pub fn maxChunkSize(encoded: bool) usize {
    return if (encoded) max_chunk_encoded else max_chunk_raw;
}

/// Which pointer event to format: a move (`t=m`, sent repeatedly while a drag
/// is over the window) or a drop (`t=M`, sent once when the user releases)
pub const PointerKind = enum { move, drop };

/// The location of a pointer event, in both grid cells (`x`/`y`) and pixels
/// from the top-left (`X`/`Y`), as the protocol reports both.
pub const Position = struct {
    cell_x: i32,
    cell_y: i32,
    px_x: i32,
    px_y: i32,
};

/// Terminal-to-client status events for an active source drag.
pub const DragStatus = union(enum) {
    accepted: i32,
    action_changed: i32,
    dropped,
    finished: bool,
};

/// POSIX symbolic error names reported on the source drag `t=E` channel.
pub const DndError = enum {
    invalid,
    too_large,
    out_of_memory,
    permission,
    timed_out,

    pub fn posixName(self: DndError) []const u8 {
        return switch (self) {
            .invalid => "EINVAL",
            .too_large => "EFBIG",
            .out_of_memory => "ENOMEM",
            .permission => "EPERM",
            .timed_out => "ETIMEDOUT",
        };
    }
};

/// Generic formatter with additional handling for outbound OSC 72 events.
const Formatter = struct {
    stream: std.Io.Writer.Allocating,
    osc: bool,

    pub fn init(alloc: Allocator, session: ?i32, osc: bool) !Formatter {
        var format: Formatter = .{
            .stream = .init(alloc),
            .osc = osc,
        };
        const w = format.writer();
        if (osc) {
            try w.writeAll(osc_prefix);
            if (session) |value| try w.print("i={d}:", .{value});
        }

        return format;
    }

    pub fn writer(self: *Formatter) *std.Io.Writer {
        return &self.stream.writer;
    }

    pub fn finalize(self: *Formatter) ![]u8 {
        defer self.stream.deinit();
        if (self.osc) try self.writer().writeAll(osc_terminator);
        return self.stream.toOwnedSlice();
    }
};

/// Formats the terminal's direct reply to an inbound `t=q` capability query.
pub fn formatCapabilityQuery(
    alloc: Allocator,
    session: ?i32,
) ![]u8 {
    var format = try Formatter.init(alloc, session, true);
    const w = format.writer();
    try w.writeAll("t=q;");
    return format.finalize();
}

/// Formats one frame of a possibly chunked OSC 72 payload transfer.
pub fn formatPayload(
    alloc: Allocator,
    metadata: ?[]const u8,
    more: bool,
    session: ?i32,
    raw: []const u8,
    encoded: bool,
) ![]u8 {
    const Encoder = std.base64.standard_no_pad.Encoder;
    var enc_buf: [Encoder.calcSize(max_chunk_encoded)]u8 = undefined;
    const payload = if (!encoded) raw else if (raw.len == 0) "" else Encoder.encode(&enc_buf, raw);

    var format = try Formatter.init(alloc, session, true);
    const w = format.writer();
    if (metadata) |m| {
        try w.writeAll(m);
        try w.writeAll(":");
    }
    try w.print("m={d};", .{@intFromBool(more)});
    try w.writeAll(payload);

    return format.finalize();
}

/// Formats an outbound `t=m` or `t=M` event. This identifies the cell, pixel positions
/// and allowed operations for the native OS drag. If it has a payload, only the metadata
/// is sent back so that it can be forwarded to formatPaylaod.
pub fn formatPointer(
    alloc: Allocator,
    kind: PointerKind,
    pos: Position,
    ops: i32,
    session: ?i32,
    has_payload: bool,
) ![]u8 {
    var format = try Formatter.init(alloc, session, !has_payload);
    const w = format.writer();
    try w.print("t={c}", .{switch (kind) {
        .move => @as(u8, 'm'),
        .drop => @as(u8, 'M'),
    }});
    try w.print(":x={d}:y={d}:X={d}:Y={d}:o={d}", .{
        pos.cell_x,
        pos.cell_y,
        pos.px_x,
        pos.px_y,
        ops,
    });
    return format.finalize();
}

/// Formats the outbound `t=m:x=-1:y=-1` "drag left the window" event.
pub fn formatLeave(alloc: Allocator, session: ?i32) ![]u8 {
    var format = try Formatter.init(alloc, session, true);
    const w = format.writer();
    try w.writeAll("t=m:x=-1:y=-1;");
    return format.finalize();
}

/// Formats the metadata for a `t=r:x=mime_index` data response.
pub fn formatData(alloc: Allocator, mime_index: i32) ![]u8 {
    var format = try Formatter.init(alloc, null, false);
    const w = format.writer();
    try w.print("t=r:x={d}", .{mime_index});
    return format.finalize();
}

pub fn formatDataEof(
    alloc: Allocator,
    mime_index: i32,
    session: ?i32,
) ![]u8 {
    var format = try Formatter.init(alloc, session, true);
    const w = format.writer();
    try w.print("t=r:x={d}:m=0;", .{mime_index});
    return format.finalize();
}

/// Formats an outbound `t=R:x=mime_index` error response.
pub fn formatDataError(
    alloc: Allocator,
    mime_index: i32,
    session: ?i32,
    posix_name: []const u8,
    desc: ?[]const u8,
) ![]u8 {
    var format = try Formatter.init(alloc, session, true);
    const w = format.writer();
    try w.print("t=R:x={d}", .{mime_index});
    try w.print(";{s}", .{posix_name});
    if (desc) |d| try w.print(":{s}", .{d});
    return format.finalize();
}

/// Formats the terminal's `t=o` source-gesture prompt event.
pub fn formatDragPrompt(
    alloc: Allocator,
    session: ?i32,
    pos: Position,
) ![]u8 {
    var format = try Formatter.init(alloc, session, true);
    const w = format.writer();
    try w.writeAll("t=o");
    try w.print(":x={d}:y={d}:X={d}:Y={d}", .{
        pos.cell_x,
        pos.cell_y,
        pos.px_x,
        pos.px_y,
    });
    return format.finalize();
}

/// Formats a per-MIME source offer error during an active drag (`t=E:y=idx`).
pub fn formatDragOfferError(
    alloc: Allocator,
    session: ?i32,
    mime_index: i32,
    posix_name: []const u8,
    desc: ?[]const u8,
) ![]u8 {
    if (posix_name.len == 0) return error.InvalidPosixName;
    if (mime_index < 0) return error.InvalidMimeIndex;

    var format = try Formatter.init(alloc, session, true);
    const w = format.writer();
    try w.writeAll("t=E");
    try w.print(":y={d};{s}", .{ mime_index, posix_name });
    if (desc) |value| try w.print(":{s}", .{value});
    return format.finalize();
}

/// Formats a source start result or terminal-side source error (`t=E`).
pub fn formatDragResult(
    alloc: Allocator,
    session: ?i32,
    posix_name: []const u8,
    desc: ?[]const u8,
) ![]u8 {
    if (posix_name.len == 0) return error.InvalidPosixName;

    var format = try Formatter.init(alloc, session, true);
    const w = format.writer();
    try w.writeAll("t=E");
    try w.print(";{s}", .{posix_name});
    if (desc) |value| try w.print(":{s}", .{value});
    return format.finalize();
}

/// Formats one of the terminal-emitted `t=e:x=1...4` source status events.
pub fn formatDragStatus(
    alloc: Allocator,
    session: ?i32,
    status: DragStatus,
) ![]u8 {
    var format = try Formatter.init(alloc, session, true);
    const w = format.writer();
    try w.writeAll("t=e");
    switch (status) {
        .accepted => |index| {
            if (index < 0) return error.InvalidMimeIndex;
            try w.print(":x=1:y={d}", .{index});
        },
        .action_changed => |operation| {
            if (operation < 0 or operation > 3) return error.InvalidOperation;
            try w.print(":x=2:o={d}", .{operation});
        },
        .dropped => try w.writeAll(":x=3"),
        .finished => |canceled| try w.print(":x=4:y={d}", .{@intFromBool(canceled)}),
    }
    return format.finalize();
}

/// Formats a lazy MIME request (`t=e:x=5:y=idx`).
pub fn formatDragDataRequest(
    alloc: Allocator,
    session: ?i32,
    mime_index: i32,
) ![]u8 {
    if (mime_index < 0) return error.InvalidMimeIndex;

    var format = try Formatter.init(alloc, session, true);
    const w = format.writer();
    try w.writeAll("t=e");
    try w.print(":x=5:y={d}", .{mime_index});
    return format.finalize();
}

test "dnd format: pointer move with mimes" {
    const testing = std.testing;
    const metadata = try formatPointer(
        testing.allocator,
        .move,
        .{ .cell_x = 5, .cell_y = 10, .px_x = 320, .px_y = 200 },
        3,
        null,
        true,
    );
    defer testing.allocator.free(metadata);
    try testing.expectEqualStrings("t=m:x=5:y=10:X=320:Y=200:o=3", metadata);

    const bytes = try formatPayload(
        testing.allocator,
        metadata,
        false,
        null,
        "text/plain text/uri-list",
        false,
    );
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings(
        "\x1b]72;t=m:x=5:y=10:X=320:Y=200:o=3:m=0;text/plain text/uri-list\x1b\\",
        bytes,
    );
}

test "dnd format: pointer move without mimes omits payload" {
    const testing = std.testing;
    const bytes = try formatPointer(
        testing.allocator,
        .move,
        .{ .cell_x = 0, .cell_y = 0, .px_x = 0, .px_y = 0 },
        1,
        null,
        false,
    );
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("\x1b]72;t=m:x=0:y=0:X=0:Y=0:o=1\x1b\\", bytes);
}

test "dnd format: drop includes session and mandatory mimes" {
    const testing = std.testing;
    const metadata = try formatPointer(
        testing.allocator,
        .drop,
        .{ .cell_x = 1, .cell_y = 2, .px_x = 3, .px_y = 4 },
        1,
        7,
        true,
    );
    defer testing.allocator.free(metadata);
    try testing.expectEqualStrings("t=M:x=1:y=2:X=3:Y=4:o=1", metadata);

    const bytes = try formatPayload(
        testing.allocator,
        metadata,
        false,
        7,
        "text/plain",
        false,
    );
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("\x1b]72;i=7:t=M:x=1:y=2:X=3:Y=4:o=1:m=0;text/plain\x1b\\", bytes);
}

test "dnd format: leave" {
    const testing = std.testing;
    const bytes = try formatLeave(testing.allocator, null);
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("\x1b]72;t=m:x=-1:y=-1;\x1b\\", bytes);
}

test "dnd format: data metadata" {
    const testing = std.testing;
    const metadata = try formatData(testing.allocator, 1);
    defer testing.allocator.free(metadata);
    try testing.expectEqualStrings("t=r:x=1", metadata);
}

test "dnd format: data small payload with EOF" {
    const testing = std.testing;
    const metadata = try formatData(testing.allocator, 1);
    defer testing.allocator.free(metadata);

    const chunk = try formatPayload(testing.allocator, metadata, false, null, "hello world", true);
    defer testing.allocator.free(chunk);
    try testing.expectEqualStrings(
        "\x1b]72;t=r:x=1:m=0;aGVsbG8gd29ybGQ\x1b\\",
        chunk,
    );

    const eof = try formatDataEof(testing.allocator, 1, null);
    defer testing.allocator.free(eof);
    try testing.expectEqualStrings("\x1b]72;t=r:x=1:m=0;\x1b\\", eof);
}

test "dnd format: data not-last emits no EOF" {
    const testing = std.testing;
    const metadata = try formatData(testing.allocator, 2);
    defer testing.allocator.free(metadata);

    const bytes = try formatPayload(testing.allocator, metadata, true, null, "abc", true);
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("\x1b]72;t=r:x=2:m=1;YWJj\x1b\\", bytes);
}

test "dnd format: unaligned non-final data uses unpadded base64" {
    const testing = std.testing;
    const metadata = try formatData(testing.allocator, 2);
    defer testing.allocator.free(metadata);

    const bytes = try formatPayload(testing.allocator, metadata, true, null, "a", true);
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("\x1b]72;t=r:x=2:m=1;YQ\x1b\\", bytes);
}

test "dnd format: data chunks payloads larger than max_chunk_raw" {
    const testing = std.testing;
    const metadata = try formatData(testing.allocator, 0);
    defer testing.allocator.free(metadata);

    const data = "a" ** (max_chunk_raw + 10);
    var offset: usize = 0;
    var more_count: usize = 0;
    var final_count: usize = 0;
    while (offset < data.len) {
        const end = @min(offset + max_chunk_raw, data.len);
        const more = end < data.len;
        const bytes = try formatPayload(
            testing.allocator,
            metadata,
            more,
            null,
            data[offset..end],
            false,
        );
        defer testing.allocator.free(bytes);
        if (more) {
            more_count += 1;
            try testing.expect(std.mem.indexOf(u8, bytes, ":m=1;") != null);
        } else {
            final_count += 1;
            try testing.expect(std.mem.indexOf(u8, bytes, ":m=0;") != null);
        }
        offset = end;
    }
    try testing.expectEqual(@as(usize, 1), more_count);
    try testing.expectEqual(@as(usize, 1), final_count);

    const eof = try formatDataEof(testing.allocator, 0, null);
    defer testing.allocator.free(eof);
    try testing.expect(std.mem.indexOf(u8, eof, ":m=0;") != null);
}

test "dnd format: data error" {
    const testing = std.testing;
    const bytes = try formatDataError(testing.allocator, 1, null, "ENOENT", null);
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("\x1b]72;t=R:x=1;ENOENT\x1b\\", bytes);
}

test "dnd format: data error with description and session" {
    const testing = std.testing;
    const bytes = try formatDataError(testing.allocator, 4, 9, "EIO", "disk error");
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("\x1b]72;i=9:t=R:x=4;EIO:disk error\x1b\\", bytes);
}

test "dnd format: source gesture prompt includes coordinates and session" {
    const testing = std.testing;
    const bytes = try formatDragPrompt(
        testing.allocator,
        17,
        .{ .cell_x = 2, .cell_y = 3, .px_x = 20, .px_y = 30 },
    );
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings(
        "\x1b]72;i=17:t=o:x=2:y=3:X=20:Y=30\x1b\\",
        bytes,
    );
}

test "dnd format: capability query reply preserves session and terminator" {
    const testing = std.testing;

    const with_session = try formatCapabilityQuery(testing.allocator, 9);
    defer testing.allocator.free(with_session);
    try testing.expectEqualStrings("\x1b]72;i=9:t=q;\x1b\\", with_session);

    const without_session = try formatCapabilityQuery(testing.allocator, null);
    defer testing.allocator.free(without_session);
    try testing.expectEqualStrings("\x1b]72;t=q;\x1b\\", without_session);
}

test "dnd format: source start OK and POSIX errors propagate session" {
    const testing = std.testing;
    const ok = try formatDragResult(testing.allocator, 4, "OK", null);
    defer testing.allocator.free(ok);
    try testing.expectEqualStrings("\x1b]72;i=4:t=E;OK\x1b\\", ok);

    const err = try formatDragResult(
        testing.allocator,
        null,
        "EPERM",
        "gesture ended",
    );
    defer testing.allocator.free(err);
    try testing.expectEqualStrings(
        "\x1b]72;t=E;EPERM:gesture ended\x1b\\",
        err,
    );
}

test "dnd format: per-MIME source offer errors include mime index" {
    const testing = std.testing;
    const err = try formatDragOfferError(
        testing.allocator,
        4,
        2,
        "ETIMEDOUT",
        null,
    );
    defer testing.allocator.free(err);
    try testing.expectEqualStrings(
        "\x1b]72;i=4:t=E:y=2;ETIMEDOUT\x1b\\",
        err,
    );
}

test "dnd format: every source status shape" {
    const testing = std.testing;
    const cases = .{
        .{ DragStatus{ .accepted = 0 }, "\x1b]72;i=9:t=e:x=1:y=0\x1b\\" },
        .{ DragStatus{ .action_changed = 2 }, "\x1b]72;i=9:t=e:x=2:o=2\x1b\\" },
        .{ DragStatus.dropped, "\x1b]72;i=9:t=e:x=3\x1b\\" },
        .{ DragStatus{ .finished = false }, "\x1b]72;i=9:t=e:x=4:y=0\x1b\\" },
        .{ DragStatus{ .finished = true }, "\x1b]72;i=9:t=e:x=4:y=1\x1b\\" },
    };
    inline for (cases) |case| {
        const bytes = try formatDragStatus(testing.allocator, 9, case[0]);
        defer testing.allocator.free(bytes);
        try testing.expectEqualStrings(case[1], bytes);
    }
}

test "dnd format: source lazy MIME request" {
    const testing = std.testing;
    const bytes = try formatDragDataRequest(testing.allocator, 12, 0);
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings(
        "\x1b]72;i=12:t=e:x=5:y=0\x1b\\",
        bytes,
    );
}
