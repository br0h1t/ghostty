//! Kitty's drag and drop protocol (OSC 72)
//! Specification: https://sw.kovidgoyal.net/kitty/drag-and-drop-protocol/

const std = @import("std");

const assert = @import("../../../quirks.zig").inlineAssert;

const Parser = @import("../../osc.zig").Parser;
const Command = @import("../../osc.zig").Command;
const Terminator = @import("../../osc.zig").Terminator;

const log = std.log.scoped(.kitty_dnd_protocol);

pub const OSC = struct {
    /// The raw metadata that was received. Parse individual values with `readOption`.
    metadata: []const u8,
    /// The raw payload. Its meaning and encoding depend on the event type (`t` key).
    payload: ?[]const u8,
    /// The terminator used for this OSC, so any response can match it.
    terminator: Terminator,

    pub fn readOption(self: OSC, comptime key: Option) ?key.Type() {
        return key.read(self.metadata);
    }

    pub fn parse(self: OSC) ParseError!ParsedMetadata {
        return parseMetadata(self.metadata);
    }

    /// We don't currently support encoding this to C in any way. It is
    /// consumed entirely within the terminal IO handler.
    pub const C = void;

    pub fn cval(_: OSC) C {
        return {};
    }
};

/// Values for the `t` (event type) metadata key.
pub const EventType = enum {
    /// ('a') Terminal registers itself as willing to accept drops.
    accept_drops,
    /// ('A') Terminal unregisters itself; drops should no longer be forwarded.
    stop_accepting_drops,
    /// ('m') The operation the application will perform if a drop occurs.
    drop_set_operation,
    /// ('M') Items were dropped onto the terminal.
    drop_dropped,
    /// ('r') Terminal requests data for a specific MIME type from the drag source.
    request_data,
    /// ('R') Error response to a `request_data` event.
    request_error,
    /// ('o') Terminal offers data for an outgoing drag (drag-out from terminal).
    offer_drag,
    /// ('p') Drag source presents the actual payload for a previously requested MIME type.
    present_data,
    /// ('P') Replace the current drag image with a new one.
    change_drag_image,
    /// ('e') Notification of an event on an outgoing drag offer (e.g., accepted or rejected).
    drag_offer_event,
    /// ('E') Error on an outgoing drag offer.
    drag_offer_error,
    /// ('k') URI list data delivered as part of a drag or clipboard transfer.
    uri_list_data,
    /// ('q') Query terminal capabilities related to the drag-and-drop protocol.
    query,

    pub fn init(str: []const u8) ?EventType {
        if (str.len != 1) return null;
        return switch (str[0]) {
            'a' => .accept_drops,
            'A' => .stop_accepting_drops,
            'm' => .drop_set_operation,
            'M' => .drop_dropped,
            'r' => .request_data,
            'R' => .request_error,
            'o' => .offer_drag,
            'p' => .present_data,
            'P' => .change_drag_image,
            'e' => .drag_offer_event,
            'E' => .drag_offer_error,
            'k' => .uri_list_data,
            'q' => .query,
            else => null,
        };
    }
};

/// Metadata keys defined by the protocol. Keys are case-sensitive.
pub const Option = enum {
    /// Event type. Maps to `EventType`; present in every OSC 72 sequence.
    t,
    /// Chunking flag. `0` = this is the final (or only) chunk; `1` = more chunks follow.
    m,
    /// Multiplexer session ID. Echoed back in responses so a terminal multiplexer
    /// (e.g. tmux) can route data to the correct pane.
    i,
    /// Multi-purpose options whose meaning changes based on the event.
    o,
    x,
    y,
    X,
    Y,

    pub fn Type(comptime key: Option) type {
        return switch (key) {
            .t => EventType,
            .m, .i, .o, .x, .y, .X, .Y => i32,
        };
    }

    pub fn read(comptime key: Option, metadata: []const u8) ?key.Type() {
        const name = @tagName(key);

        const value: []const u8 = value: {
            var pos: usize = 0;
            while (pos < metadata.len) {
                while (pos < metadata.len and std.ascii.isWhitespace(metadata[pos])) pos += 1;
                if (pos >= metadata.len) return null;

                if (!std.mem.startsWith(u8, metadata[pos..], name)) {
                    pos = std.mem.indexOfScalarPos(u8, metadata, pos, ':') orelse return null;
                    pos += 1;
                    continue;
                }
                pos += name.len;

                while (pos < metadata.len and std.ascii.isWhitespace(metadata[pos])) pos += 1;
                if (pos >= metadata.len) return null;
                if (metadata[pos] != '=') return null;

                const end = std.mem.indexOfScalarPos(u8, metadata, pos, ':') orelse metadata.len;
                const start = pos + 1;
                break :value std.mem.trim(u8, metadata[start..end], &std.ascii.whitespace);
            }
            return null;
        };

        return switch (key) {
            .t => .init(value),
            .m, .i, .o, .x, .y, .X, .Y => parseInteger(value) catch null,
        };
    }

    pub fn parse(comptime key: Option, value: []const u8) ParseError!key.Type() {
        return switch (key) {
            .t => EventType.init(value) orelse error.InvalidMetadata,
            .m => m: {
                const number = try parseInteger(value);
                if (number != 0 and number != 1) return error.InvalidMetadata;
                break :m number;
            },
            .i => i: {
                const number = try parseInteger(value);
                if (number < 0) return error.InvalidMetadata;
                break :i number;
            },
            .o, .x, .y, .X, .Y => try parseInteger(value),
        };
    }
};

pub const ParsedMetadata = struct {
    event: ?EventType = null,
    more: ?bool = null,
    session: ?i32 = null,
    o: ?i32 = null,
    x: ?i32 = null,
    y: ?i32 = null,
    X: ?i32 = null,
    Y: ?i32 = null,
};

pub const ParseError = error{
    InvalidMetadata,
};

const ParsedKeyValue = struct {
    key: []const u8,
    value: []const u8,
};

/// Parse and validate all recognized OSC 72 metadata keys.
fn parseMetadata(metadata: []const u8) ParseError!ParsedMetadata {
    var result: ParsedMetadata = .{};
    var seen: u8 = 0;
    var it = std.mem.splitScalar(u8, metadata, ':');
    while (it.next()) |raw| {
        const parsed = try parseKeyValue(raw);
        if (std.meta.stringToEnum(Option, parsed.key)) |key| {
            try markSeen(&seen, @intFromEnum(key));
            try applyOption(&result, key, parsed.value);
        }
    }
    return result;
}

fn parseKeyValue(raw: []const u8) ParseError!ParsedKeyValue {
    const field = std.mem.trim(u8, raw, &std.ascii.whitespace);
    if (field.len == 0) return error.InvalidMetadata;
    const equals = std.mem.indexOfScalar(u8, field, '=') orelse
        return error.InvalidMetadata;
    return .{
        .key = std.mem.trim(u8, field[0..equals], &std.ascii.whitespace),
        .value = std.mem.trim(u8, field[equals + 1 ..], &std.ascii.whitespace),
    };
}

fn markSeen(seen: *u8, bit: u3) ParseError!void {
    const mask = @as(u8, 1) << bit;
    if (seen.* & mask != 0) return error.InvalidMetadata;
    seen.* |= mask;
}

fn applyOption(result: *ParsedMetadata, key: Option, value: []const u8) ParseError!void {
    switch (key) {
        .t => result.event = try Option.parse(.t, value),
        .m => result.more = (try Option.parse(.m, value)) == 1,
        .i => result.session = try Option.parse(.i, value),
        .o => result.o = try Option.parse(.o, value),
        .x => result.x = try Option.parse(.x, value),
        .y => result.y = try Option.parse(.y, value),
        .X => result.X = try Option.parse(.X, value),
        .Y => result.Y = try Option.parse(.Y, value),
    }
}

fn parseInteger(value: []const u8) ParseError!i32 {
    if (value.len == 0) return error.InvalidMetadata;
    return std.fmt.parseInt(i32, value, 10) catch error.InvalidMetadata;
}

test "OSC 72: metadata only, no payload" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "72;t=a";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_dnd_protocol);
    try testing.expectEqualStrings("t=a", cmd.kitty_dnd_protocol.metadata);
    try testing.expect(cmd.kitty_dnd_protocol.payload == null);
}

test "OSC 72: metadata and empty payload" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "72;t=a;";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_dnd_protocol);
    try testing.expectEqualStrings("t=a", cmd.kitty_dnd_protocol.metadata);
    try testing.expectEqualStrings("", cmd.kitty_dnd_protocol.payload.?);
}

test "OSC 72: metadata and non-empty payload" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "72;t=a:i=5;text/plain text/uri-list";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_dnd_protocol);
    try testing.expectEqualStrings("t=a:i=5", cmd.kitty_dnd_protocol.metadata);
    try testing.expectEqualStrings("text/plain text/uri-list", cmd.kitty_dnd_protocol.payload.?);
}

test "OSC 72: readOption .t valid event types" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const cases = .{
        .{ "72;t=a", EventType.accept_drops },
        .{ "72;t=A", EventType.stop_accepting_drops },
        .{ "72;t=m", EventType.drop_set_operation },
        .{ "72;t=M", EventType.drop_dropped },
        .{ "72;t=r", EventType.request_data },
        .{ "72;t=R", EventType.request_error },
        .{ "72;t=o", EventType.offer_drag },
        .{ "72;t=p", EventType.present_data },
        .{ "72;t=P", EventType.change_drag_image },
        .{ "72;t=e", EventType.drag_offer_event },
        .{ "72;t=E", EventType.drag_offer_error },
        .{ "72;t=k", EventType.uri_list_data },
        .{ "72;t=q", EventType.query },
    };

    inline for (cases) |case| {
        p.deinit();
        p = .init(testing.allocator);
        for (case[0]) |ch| p.next(ch);
        const cmd = p.end('\x1b').?.*;
        try testing.expect(cmd == .kitty_dnd_protocol);
        try testing.expectEqual(case[1], cmd.kitty_dnd_protocol.readOption(.t).?);
    }
}

test "OSC 72: readOption .t unknown value returns null" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "72;t=z";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_dnd_protocol);
    try testing.expect(cmd.kitty_dnd_protocol.readOption(.t) == null);
}

test "OSC 72: readOption integer keys" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "72;t=m:i=3:x=10:y=5:X=320:Y=200:o=1:m=0";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_dnd_protocol);
    try testing.expectEqual(@as(i32, 3), cmd.kitty_dnd_protocol.readOption(.i).?);
    try testing.expectEqual(@as(i32, 10), cmd.kitty_dnd_protocol.readOption(.x).?);
    try testing.expectEqual(@as(i32, 5), cmd.kitty_dnd_protocol.readOption(.y).?);
    try testing.expectEqual(@as(i32, 320), cmd.kitty_dnd_protocol.readOption(.X).?);
    try testing.expectEqual(@as(i32, 200), cmd.kitty_dnd_protocol.readOption(.Y).?);
    try testing.expectEqual(@as(i32, 1), cmd.kitty_dnd_protocol.readOption(.o).?);
    try testing.expectEqual(@as(i32, 0), cmd.kitty_dnd_protocol.readOption(.m).?);
}

test "OSC 72: readOption negative sentinel (-1 for drag leave)" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "72;t=m:x=-1:y=-1";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_dnd_protocol);
    try testing.expectEqual(@as(i32, -1), cmd.kitty_dnd_protocol.readOption(.x).?);
    try testing.expectEqual(@as(i32, -1), cmd.kitty_dnd_protocol.readOption(.y).?);
}

test "OSC 72: readOption case-sensitive key matching" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    // x=10 must not be returned when asking for .X
    const input = "72;x=10:Y=200";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_dnd_protocol);
    try testing.expectEqual(@as(i32, 10), cmd.kitty_dnd_protocol.readOption(.x).?);
    try testing.expect(cmd.kitty_dnd_protocol.readOption(.X) == null);
    try testing.expectEqual(@as(i32, 200), cmd.kitty_dnd_protocol.readOption(.Y).?);
    try testing.expect(cmd.kitty_dnd_protocol.readOption(.y) == null);
}

test "OSC 72: readOption absent key returns null" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "72;t=a";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_dnd_protocol);
    try testing.expect(cmd.kitty_dnd_protocol.readOption(.i) == null);
    try testing.expect(cmd.kitty_dnd_protocol.readOption(.x) == null);
    try testing.expect(cmd.kitty_dnd_protocol.readOption(.X) == null);
    try testing.expect(cmd.kitty_dnd_protocol.readOption(.m) == null);
}

test "OSC 72: readOption malformed integer returns null" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "72;x=notanumber";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_dnd_protocol);
    try testing.expect(cmd.kitty_dnd_protocol.readOption(.x) == null);
}

test "OSC 72: BEL terminator recorded" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "72;t=q";
    for (input) |ch| p.next(ch);

    const cmd = p.end(0x07).?.*;
    try testing.expect(cmd == .kitty_dnd_protocol);
    try testing.expect(cmd.kitty_dnd_protocol.terminator == .bel);
}

test "OSC 72: parse rejects duplicate keys" {
    const testing = std.testing;

    try testing.expectError(
        error.InvalidMetadata,
        parseMetadata("t=p:i=7:x=0:m=1:m=0"),
    );
}

test "OSC 72: parse validates m and session" {
    const testing = std.testing;

    const parsed = try parseMetadata("t=p:i=3:x=0:y=7:X=11:Y=12:o=13:m=0");
    try testing.expectEqual(EventType.present_data, parsed.event.?);
    try testing.expectEqual(@as(?i32, 3), parsed.session);
    try testing.expectEqual(@as(?i32, 0), parsed.x);
    try testing.expectEqual(@as(?i32, 7), parsed.y);
    try testing.expectEqual(@as(?i32, 11), parsed.X);
    try testing.expectEqual(@as(?i32, 12), parsed.Y);
    try testing.expectEqual(@as(?i32, 13), parsed.o);
    try testing.expectEqual(false, parsed.more.?);

    try testing.expectError(error.InvalidMetadata, parseMetadata("t=o:i=-1"));
    try testing.expectError(error.InvalidMetadata, parseMetadata("t=o:m=2"));
}

pub fn parse(parser: *Parser, terminator_ch: ?u8) ?*Command {
    assert(parser.state == .@"72");

    const cap = if (parser.capture) |*c| c else {
        parser.state = .invalid;
        return null;
    };

    const data = cap.trailing();

    const metadata: []const u8, const payload: ?[]const u8 = result: {
        const sep = std.mem.indexOfScalar(u8, data, ';') orelse break :result .{ data, null };
        break :result .{ data[0..sep], data[sep + 1 .. data.len] };
    };

    parser.command = .{
        .kitty_dnd_protocol = .{
            .metadata = metadata,
            .payload = payload,
            .terminator = .init(terminator_ch),
        },
    };

    return &parser.command;
}
