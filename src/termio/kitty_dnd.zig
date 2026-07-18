const std = @import("std");
const Allocator = std.mem.Allocator;

const terminal = @import("../terminal/main.zig");

const EventType = terminal.osc.Command.KittyDndEventType;
const OSC = terminal.osc.Command.KittyDndProtocol;
const ParsedMetadata = @import("../terminal/osc/parsers/kitty_dnd_protocol.zig").ParsedMetadata;
const DndError = @import("../apprt/kitty_dnd_format.zig").DndError;

const log = std.log.scoped(.kitty_dnd);

const base64_decoder = std.base64.standard.Decoder;
const base64_decoder_no_pad = std.base64.standard_no_pad.Decoder;
const png_signature = "\x89PNG\r\n\x1a\n";

/// Aggregate byte limits for inbound OSC 72 transfers.
const DataLimits = struct {
    const mime: usize = 1024 * 1024;
    const data: usize = 128 * 1024 * 1024;
    const image: usize = 64 * 1024 * 1024;
    const control: usize = 64 * 1024;
};

/// State machine to decode, validate and assemble chunked payloads of
/// application-to-terminal OSC 72 sequences fed by the stream handler.
pub const Decoder = struct {
    pending: ?Pending = null,
    awaiting_eof: ?Metadata = null,
    last_failure: ?Failure = null,

    pub const max_chunk_size = 4096;

    pub const Metadata = struct {
        event: EventType,
        session: ?i32,
        o: ?i32,
        x: ?i32,
        y: ?i32,
        X: ?i32,
        Y: ?i32,

        pub fn fromParsed(parsed: ParsedMetadata) ?Metadata {
            const event = parsed.event orelse return null;
            return .{
                .event = event,
                .session = parsed.session,
                .o = parsed.o,
                .x = parsed.x,
                .y = parsed.y,
                .X = parsed.X,
                .Y = parsed.Y,
            };
        }
    };

    pub const Complete = struct {
        metadata: Metadata,
        payload: []u8,
    };

    pub const Query = struct {
        session: ?i32,
    };

    pub const Failure = struct {
        err: DndError,
        metadata: ?Metadata,
    };

    pub const Result = union(enum) {
        incomplete,
        query: Query,
        complete: Complete,
        invalid,
    };

    const Mode = enum {
        plain,
        base64,
    };

    const Pending = struct {
        metadata: Metadata,
        mode: Mode,
        limit: usize,
        buf: std.ArrayListUnmanaged(u8) = .empty,
        base64_padded: bool = false,
    };

    pub fn deinit(self: *Decoder, alloc: Allocator) void {
        self.reset(alloc);
    }

    pub fn reset(self: *Decoder, alloc: Allocator) void {
        if (self.pending) |*pending| {
            pending.buf.deinit(alloc);
            self.pending = null;
        }
        self.awaiting_eof = null;
        self.last_failure = null;
    }

    pub fn resetDrag(self: *Decoder, alloc: Allocator, session: ?i32) void {
        if (self.pending) |pending| {
            if (pending.metadata.session == session and isSourceOfferEvent(pending.metadata.event)) {
                self.reset(alloc);
                return;
            }
        }
        if (self.awaiting_eof) |metadata| {
            if (metadata.session == session and isSourceOfferEvent(metadata.event)) {
                self.awaiting_eof = null;
            }
        }
    }

    pub fn feed(self: *Decoder, alloc: Allocator, cmd: OSC) Result {
        self.last_failure = null;

        const parsed = cmd.parse() catch {
            log.warn("OSC 72 contains malformed metadata", .{});
            const metadata = if (self.pending) |pending|
                pending.metadata
            else
                metadataFromCommand(cmd);
            return self.fail(alloc, .invalid, metadata);
        };

        const metadata = if (self.pending) |pending|
            pending.metadata
        else
            Metadata.fromParsed(parsed);

        const payload: []const u8 = if (cmd.payload) |p| p else "";

        if (payload.len > max_chunk_size) {
            log.warn("OSC 72 payload exceeds encoded chunk limit", .{});
            return self.fail(alloc, .too_large, metadata);
        }

        if (parsed.event == .query) {
            if (!validQuery(parsed, payload)) {
                return self.fail(alloc, .invalid, metadata);
            }
            return .{ .query = .{
                .session = parsed.session,
            } };
        }

        if (self.awaiting_eof) |last_completed_metadata| {
            if (isEof(last_completed_metadata, parsed, payload)) {
                self.awaiting_eof = null;
                return .incomplete;
            }
            self.awaiting_eof = null;
        }

        if (self.pending) |*pending| {
            if (!identityMatches(pending.metadata, parsed)) {
                log.warn("OSC 72 chunk identity mismatch", .{});
                return self.fail(alloc, .invalid, pending.metadata);
            }

            return self.consume(alloc, parsed, payload);
        }

        const event = parsed.event orelse {
            log.warn("OSC 72 continuation received without active transfer", .{});
            self.last_failure = .{ .err = .invalid, .metadata = null };
            return .invalid;
        };

        if (event == .uri_list_data) {
            log.debug("OSC 72 t=k is not implemented", .{});
            return .invalid;
        }

        const mode: Mode = if (event == .present_data or
            (event == .drag_offer_event and
            (parsed.x orelse 0) == 0 and
            (parsed.y != null or parsed.more != null or cmd.payload != null))
        ) .base64 else .plain;

        self.pending = .{
            .metadata = metadata.?,
            .mode = mode,
            .limit = limitFor(metadata.?, mode),
        };
        return self.consume(alloc, parsed, cmd.payload orelse "");
    }

    fn consume(self: *Decoder, alloc: Allocator, parsed: ParsedMetadata, payload: []const u8) Result {
        const pending = &self.pending.?;
        switch (pending.mode) {
            .plain => {
                if (pending.buf.items.len +| payload.len > pending.limit) {
                    log.warn("OSC 72 plain transfer exceeded aggregate limit", .{});
                    return self.fail(alloc, .too_large, pending.metadata);
                }
                pending.buf.appendSlice(alloc, payload) catch
                    return self.fail(alloc, .out_of_memory, pending.metadata);
                if (parsed.more orelse false) return .incomplete;
                return self.finish(alloc);
            },

            .base64 => {
                appendBase64Encoded(pending, alloc, payload) catch |err| {
                    log.warn("OSC 72 contains malformed or oversized base64", .{});
                    return self.fail(alloc, switch (err) {
                        error.PayloadTooLarge => .too_large,
                        error.OutOfMemory => .out_of_memory,
                        error.InvalidBase64 => .invalid,
                    }, pending.metadata);
                };

                if (parsed.more orelse false) return .incomplete;

                decodeBase64(pending) catch {
                    log.warn("OSC 72 base64 stream ended with malformed data", .{});
                    return self.fail(alloc, .invalid, pending.metadata);
                };

                const result = self.finish(alloc);
                if (result == .complete and payload.len != 0) {
                    self.awaiting_eof = result.complete.metadata;
                }
                return result;
            },
        }
    }

    fn finish(self: *Decoder, alloc: Allocator) Result {
        const pending = &self.pending.?;
        const metadata = pending.metadata;
        const payload = pending.buf.toOwnedSlice(alloc) catch
            return self.fail(alloc, .out_of_memory, metadata);
        self.pending = null;
        return .{ .complete = .{
            .metadata = metadata,
            .payload = payload,
        } };
    }

    fn fail(self: *Decoder, alloc: Allocator, err: DndError, metadata: ?Metadata) Result {
        self.reset(alloc);
        self.last_failure = .{ .err = err, .metadata = metadata };
        return .invalid;
    }

    fn metadataFromCommand(cmd: OSC) ?Metadata {
        const event = cmd.readOption(.t) orelse return null;
        return .{
            .event = event,
            .session = cmd.readOption(.i),
            .o = cmd.readOption(.o),
            .x = cmd.readOption(.x),
            .y = cmd.readOption(.y),
            .X = cmd.readOption(.X),
            .Y = cmd.readOption(.Y),
        };
    }

    fn limitFor(metadata: Metadata, mode: Mode) usize {
        if (mode == .base64) {
            if (metadata.event == .present_data and
                (metadata.x orelse 0) < 0)
            {
                return DataLimits.image;
            }
            return DataLimits.data;
        }

        return switch (metadata.event) {
            .accept_drops, .drop_set_operation, .offer_drag => DataLimits.mime,
            else => DataLimits.control,
        };
    }

    fn validQuery(parsed: ParsedMetadata, payload: []const u8) bool {
        return parsed.more == null and
            parsed.o == null and
            parsed.x == null and
            parsed.y == null and
            parsed.X == null and
            parsed.Y == null and
            payload.len == 0;
    }

    /// Session IDs must be present on every multiplexed sequence. Other
    /// first-chunk metadata may be omitted by continuation sequences.
    fn identityMatches(first: Metadata, next: ParsedMetadata) bool {
        if (next.event) |event| {
            if (event != first.event) return false;
        }
        if (!optionalExact(first.session, next.session)) return false;
        if (!optionalRepeated(first.o, next.o)) return false;
        if (!optionalRepeated(first.x, next.x)) return false;
        if (!optionalRepeated(first.y, next.y)) return false;
        if (!optionalRepeated(first.X, next.X)) return false;
        if (!optionalRepeated(first.Y, next.Y)) return false;
        return true;
    }

    fn optionalExact(first: ?i32, next: ?i32) bool {
        if (first == null or next == null) return first == null and next == null;
        return first.? == next.?;
    }

    fn optionalRepeated(first: ?i32, next: ?i32) bool {
        const value = next orelse return true;
        return (first orelse 0) == value;
    }

    fn isEof(metadata: Metadata, parsed: ParsedMetadata, payload: []const u8) bool {
        return payload.len == 0 and
            !(parsed.more orelse false) and
            identityMatches(metadata, parsed);
    }

    fn maxDecodedLen(encoded_len: usize) usize {
        return (encoded_len * 3 + 3) / 4;
    }

    fn appendBase64Encoded(pending: *Pending, alloc: Allocator, encoded: []const u8) !void {
        if (pending.base64_padded) return error.InvalidBase64;

        for (encoded) |byte| {
            if (byte == '=') continue;
            if (base64_decoder.char_to_index[byte] == 0xff) {
                return error.InvalidBase64;
            }
        }
        if (std.mem.indexOfScalar(u8, encoded, '=') != null) {
            pending.base64_padded = true;
        }

        const new_len = pending.buf.items.len + encoded.len;
        if (maxDecodedLen(new_len) > pending.limit) {
            return error.PayloadTooLarge;
        }

        try pending.buf.appendSlice(alloc, encoded);
    }

    fn decodeBase64(pending: *Pending) !void {
        if (pending.buf.items.len == 0) return;

        const encoded = pending.buf.items;
        const written = if (pending.base64_padded) decoded_len: {
            const len = base64_decoder.calcSizeForSlice(encoded) catch
                return error.InvalidBase64;
            base64_decoder.decode(encoded[0..len], encoded) catch
                return error.InvalidBase64;
            break :decoded_len len;
        } else decoded_len: {
            const len = base64_decoder_no_pad.calcSizeUpperBound(encoded.len) catch
                return error.InvalidBase64;
            base64_decoder_no_pad.decode(encoded[0..len], encoded) catch
                return error.InvalidBase64;
            break :decoded_len len;
        };
        pending.buf.shrinkRetainingCapacity(written);
    }
};

/// Bounds for pre-sent drag images (`t=p:x<0`).
const DragImageLimits = struct {
    const max_count: usize = 16;
    const max_dimension: i32 = 4096;
    const max_decoded_pixels: usize = 4096 * 4096;
    const max_text_size: usize = 2048;
};

/// Source-side OSC 72 registration and active-offer validation state.
pub const OfferState = struct {
    registered: bool = false,
    session: ?i32 = null,
    active: bool = false,
    mime_count: usize = 0,
    next_image: i32 = 0,
    pre_sent_bytes: usize = 0,
    image_bytes: usize = 0,
    image_count: usize = 0,
    decoded_pixels: usize = 0,
    lazy_bytes: usize = 0,

    pub fn offererMatches(self: OfferState, session: ?i32) bool {
        return self.registered and self.session == session;
    }

    pub fn offerMatches(self: OfferState, session: ?i32) bool {
        return self.active and self.offererMatches(session);
    }

    pub fn clearActive(self: *OfferState) void {
        self.active = false;
        self.mime_count = 0;
        self.next_image = 0;
        self.pre_sent_bytes = 0;
        self.image_bytes = 0;
        self.image_count = 0;
        self.decoded_pixels = 0;
        self.lazy_bytes = 0;
    }

    pub fn reset(self: *OfferState) void {
        self.registered = false;
        self.session = null;
        self.clearActive();
    }

    pub fn validMimeIndex(self: OfferState, mime_index: i32) bool {
        return mime_index >= 0 and @as(usize, @intCast(mime_index)) < self.mime_count;
    }

    pub fn registerPreSentData(self: *OfferState, mime_index: i32, bytes: usize) ?DndError {
        if (!self.validMimeIndex(mime_index)) return .invalid;
        if (bytes > DataLimits.data -| self.pre_sent_bytes) return .too_large;
        self.pre_sent_bytes += bytes;
        return null;
    }

    pub fn registerLazyData(self: *OfferState, mime_index: i32, bytes: usize) ?DndError {
        if (!self.validMimeIndex(mime_index)) return .invalid;
        if (bytes > DataLimits.data -| self.lazy_bytes) return .too_large;
        self.lazy_bytes += bytes;
        return null;
    }

    pub fn registerImage(
        self: *OfferState,
        format: i32,
        width: i32,
        height: i32,
        opacity: i32,
        payload: []const u8,
    ) ?DndError {
        if (self.image_count >= DragImageLimits.max_count) return .too_large;
        if (width <= 0 or height <= 0) return .invalid;
        if (width > DragImageLimits.max_dimension or height > DragImageLimits.max_dimension) {
            return .too_large;
        }
        if (opacity < 0 or opacity > 1024) return .invalid;

        switch (format) {
            0 => {
                if (payload.len > DragImageLimits.max_text_size) return .too_large;
            },
            24, 32, 100 => {
                const pixels = @as(usize, @intCast(width)) * @as(usize, @intCast(height));
                if (self.decoded_pixels + pixels > DragImageLimits.max_decoded_pixels) {
                    return .too_large;
                }

                if (format == 100) {
                    if (!validPngPayload(payload)) return .invalid;
                } else {
                    const samples: usize = if (format == 24) 3 else 4;
                    if (pixels * samples != payload.len) return .invalid;
                }
                self.decoded_pixels += pixels;
            },
            else => return .invalid,
        }

        if (payload.len > DataLimits.image -| self.image_bytes) return .too_large;
        self.image_bytes += payload.len;
        self.image_count += 1;
        return null;
    }

    pub fn register(self: *OfferState, session: ?i32) void {
        self.registered = true;
        self.session = session;
        self.clearActive();
    }

    pub fn beginOffer(self: *OfferState, mime_count: usize) void {
        self.clearActive();
        self.active = true;
        self.mime_count = mime_count;
        self.next_image = 0;
    }

    pub fn unregister(self: *OfferState) void {
        self.reset();
    }
};

/// Destination-side OSC 72 registration and session validation state.
pub const DestinationState = struct {
    accepting: bool = false,
    session: ?i32 = null,

    pub fn matches(self: DestinationState, session: ?i32) bool {
        return self.accepting and self.session == session;
    }

    pub fn register(self: *DestinationState, session: ?i32) void {
        self.accepting = true;
        self.session = session;
    }

    pub fn unregister(self: *DestinationState) void {
        self.accepting = false;
        self.session = null;
    }

    pub fn reset(self: *DestinationState) void {
        self.unregister();
    }
};


pub fn isSourceOfferEvent(event: EventType) bool {
    return switch (event) {
        .offer_drag,
        .present_data,
        .change_drag_image,
        .drag_offer_event,
        .drag_offer_error,
        => true,
        else => false,
    };
}

/// Returns the number of space-separated MIME types in `payload`, or `null` if
/// the list is syntactically invalid. An empty payload is valid and returns `0`.
pub fn countMimes(payload: []const u8) ?usize {
    if (std.mem.indexOfScalar(u8, payload, 0) != null) return null;
    var count: usize = 0;
    var it = std.mem.tokenizeScalar(u8, payload, ' ');
    while (it.next()) |mime| {
        if (std.mem.indexOfScalar(u8, mime, '/') == null) return null;
        for (mime) |byte| {
            if (byte <= 0x20 or byte >= 0x7F) return null;
        }
        count += 1;
    }
    return count;
}

/// Returns whether `payload` is a valid space-separated MIME type list.
pub fn validMimeList(payload: []const u8) bool {
    return countMimes(payload) != null;
}

/// Returns whether `payload` is a valid machine id for remote drag-and-drop.
pub fn validMachineId(payload: []const u8) bool {
    for (payload) |byte| {
        if (byte < 0x20 or byte > 0x7E) return false;
    }
    return true;
}

/// Returns whether `payload` begins with a PNG file signature.
pub fn validPngPayload(payload: []const u8) bool {
    return payload.len >= png_signature.len and
        std.mem.eql(u8, payload[0..png_signature.len], png_signature);
}

/// Returns whether `payload` is a valid client drag-offer error response.
pub fn validClientError(payload: []const u8) bool {
    if (payload.len < 2 or payload[0] != 'E' or
        !std.unicode.utf8ValidateSlice(payload))
    {
        return false;
    }

    const name_end = std.mem.indexOfScalar(u8, payload, ':') orelse payload.len;
    for (payload[0..name_end]) |byte| {
        if (!std.ascii.isUpper(byte) and
            !std.ascii.isDigit(byte) and
            byte != '_')
        {
            return false;
        }
    }
    for (payload[name_end..]) |byte| {
        if (byte < 0x20 or byte == 0x7F) return false;
    }
    return true;
}

fn feedString(decoder: *Decoder, alloc: Allocator, input: []const u8) Decoder.Result {
    var parser: terminal.osc.Parser = .init(alloc);
    defer parser.deinit();
    for (input) |byte| parser.next(byte);
    const cmd = parser.end('\x1b').?.kitty_dnd_protocol;
    return decoder.feed(alloc, cmd);
}

test "OSC 72 decoder retains first metadata for continuation-only chunks" {
    const testing = std.testing;
    var decoder: Decoder = .{};
    defer decoder.deinit(testing.allocator);

    try testing.expect(feedString(
        &decoder,
        testing.allocator,
        "72;t=o:i=7:o=3:m=1;text/plain ",
    ) == .incomplete);
    const result = feedString(
        &decoder,
        testing.allocator,
        "72;m=0:i=7;text/uri-list",
    );
    try testing.expect(result == .complete);
    defer testing.allocator.free(result.complete.payload);
    try testing.expectEqual(EventType.offer_drag, result.complete.metadata.event);
    try testing.expectEqual(@as(?i32, 7), result.complete.metadata.session);
    try testing.expectEqual(@as(?i32, 3), result.complete.metadata.o);
    try testing.expectEqualStrings(
        "text/plain text/uri-list",
        result.complete.payload,
    );
}

test "OSC 72 decoder permits query interleaving" {
    const testing = std.testing;
    var decoder: Decoder = .{};
    defer decoder.deinit(testing.allocator);

    try testing.expect(feedString(
        &decoder,
        testing.allocator,
        "72;t=o:i=7:o=1:m=1;text/",
    ) == .incomplete);
    const query = feedString(&decoder, testing.allocator, "72;t=q:i=99");
    try testing.expect(query == .query);
    try testing.expectEqual(@as(?i32, 99), query.query.session);
    try testing.expect(decoder.pending != null);

    const result = feedString(&decoder, testing.allocator, "72;m=0:i=7;plain");
    try testing.expect(result == .complete);
    defer testing.allocator.free(result.complete.payload);
    try testing.expectEqualStrings("text/plain", result.complete.payload);
}

test "OSC 72 decoder rejects session and transfer identity mismatches" {
    const testing = std.testing;
    var decoder: Decoder = .{};
    defer decoder.deinit(testing.allocator);

    try testing.expect(feedString(
        &decoder,
        testing.allocator,
        "72;t=p:i=1:x=0:m=1;YQ",
    ) == .incomplete);
    try testing.expect(feedString(
        &decoder,
        testing.allocator,
        "72;m=0:i=2;",
    ) == .invalid);
    try testing.expect(decoder.pending == null);

    try testing.expect(feedString(
        &decoder,
        testing.allocator,
        "72;t=p:i=1:x=0:m=1;YQ",
    ) == .incomplete);
    try testing.expect(feedString(
        &decoder,
        testing.allocator,
        "72;t=p:i=1:x=1:m=0;",
    ) == .invalid);
}

test "OSC 72 decoder decodes padded base64 across sequence boundaries" {
    const testing = std.testing;
    var decoder: Decoder = .{};
    defer decoder.deinit(testing.allocator);

    try testing.expect(feedString(
        &decoder,
        testing.allocator,
        "72;t=p:x=0:m=1;aGV",
    ) == .incomplete);
    const result = feedString(
        &decoder,
        testing.allocator,
        "72;m=0;sbG8=",
    );
    try testing.expect(result == .complete);
    defer testing.allocator.free(result.complete.payload);
    try testing.expectEqualStrings("hello", result.complete.payload);
    try testing.expect(
        feedString(&decoder, testing.allocator, "72;m=0;") == .incomplete,
    );
}

test "OSC 72 decoder decodes unpadded base64 with optional EOF" {
    const testing = std.testing;
    var decoder: Decoder = .{};
    defer decoder.deinit(testing.allocator);

    const result = feedString(
        &decoder,
        testing.allocator,
        "72;t=e:y=0:m=0;YQ",
    );
    try testing.expect(result == .complete);
    defer testing.allocator.free(result.complete.payload);
    try testing.expectEqual(EventType.drag_offer_event, result.complete.metadata.event);
    try testing.expectEqual(@as(?i32, 0), result.complete.metadata.y);
    try testing.expectEqualStrings("a", result.complete.payload);
    try testing.expect(
        feedString(&decoder, testing.allocator, "72;m=0;") == .incomplete,
    );
}

test "OSC 72 decoder accepts explicitly repeated default metadata" {
    const testing = std.testing;
    var decoder: Decoder = .{};
    defer decoder.deinit(testing.allocator);

    const result = feedString(
        &decoder,
        testing.allocator,
        "72;t=e:m=0;YQ",
    );
    try testing.expect(result == .complete);
    defer testing.allocator.free(result.complete.payload);
    try testing.expectEqual(EventType.drag_offer_event, result.complete.metadata.event);
    try testing.expectEqualStrings("a", result.complete.payload);
    try testing.expect(feedString(
        &decoder,
        testing.allocator,
        "72;t=e:x=0:y=0",
    ) == .incomplete);
}

test "OSC 72 decoder accepts image without trailing empty EOF" {
    const testing = std.testing;
    var decoder: Decoder = .{};
    defer decoder.deinit(testing.allocator);

    const offer = feedString(
        &decoder,
        testing.allocator,
        "72;t=o:o=3;text/uri-list",
    );
    try testing.expect(offer == .complete);
    defer testing.allocator.free(offer.complete.payload);

    const data = feedString(
        &decoder,
        testing.allocator,
        "72;t=p:x=0:m=0;ZmlsZTovLy90bXAvZmlsZQ0K",
    );
    try testing.expect(data == .complete);
    defer testing.allocator.free(data.complete.payload);
    try testing.expect(
        feedString(&decoder, testing.allocator, "72;t=p:x=0") == .incomplete,
    );

    const image = feedString(
        &decoder,
        testing.allocator,
        "72;t=p:x=-1:y=0:X=6:Y=4:o=0:m=0;MSBzZWxlY3RlZCBmaWxlKHMp",
    );
    try testing.expect(image == .complete);
    defer testing.allocator.free(image.complete.payload);
    try testing.expectEqualStrings("1 selected file(s)", image.complete.payload);

    const start = feedString(&decoder, testing.allocator, "72;t=P:x=-1");
    try testing.expect(start == .complete);
    defer testing.allocator.free(start.complete.payload);
    try testing.expectEqual(EventType.change_drag_image, start.complete.metadata.event);
    try testing.expectEqual(@as(?i32, -1), start.complete.metadata.x);
}

test "OSC 72 decoder accepts reference client default-valued EOF" {
    const testing = std.testing;
    var decoder: Decoder = .{};
    defer decoder.deinit(testing.allocator);

    const result = feedString(
        &decoder,
        testing.allocator,
        "72;t=p:o=3:m=0;ZmlsZTovLy90bXAvZmlsZQ0K",
    );
    try testing.expect(result == .complete);
    defer testing.allocator.free(result.complete.payload);
    try testing.expectEqual(EventType.present_data, result.complete.metadata.event);
    try testing.expectEqualStrings("file:///tmp/file\r\n", result.complete.payload);
    try testing.expect(feedString(
        &decoder,
        testing.allocator,
        "72;t=p:o=3",
    ) == .incomplete);

    const image = feedString(
        &decoder,
        testing.allocator,
        "72;t=p:x=-1:X=6:Y=1:m=0;75KK",
    );
    try testing.expect(image == .complete);
    defer testing.allocator.free(image.complete.payload);
    try testing.expectEqual(@as(?i32, -1), image.complete.metadata.x);
    try testing.expectEqualStrings("", image.complete.payload);
    try testing.expect(feedString(
        &decoder,
        testing.allocator,
        "72;t=p:x=-1:X=6:Y=1",
    ) == .incomplete);

    const start = feedString(&decoder, testing.allocator, "72;t=P:x=-1");
    try testing.expect(start == .complete);
    defer testing.allocator.free(start.complete.payload);
    try testing.expectEqual(EventType.change_drag_image, start.complete.metadata.event);
    try testing.expectEqual(@as(?i32, -1), start.complete.metadata.x);
}

test "OSC 72 decoder distinguishes plain MIME lists from base64 streams" {
    const testing = std.testing;
    var decoder: Decoder = .{};
    defer decoder.deinit(testing.allocator);

    const result = feedString(
        &decoder,
        testing.allocator,
        "72;t=o:o=3:m=0;text/plain",
    );
    try testing.expect(result == .complete);
    defer testing.allocator.free(result.complete.payload);
    try testing.expectEqualStrings("text/plain", result.complete.payload);
}

test "OSC 72 decoder rejects malformed base64 and noncanonical residual bits" {
    const testing = std.testing;
    var decoder: Decoder = .{};
    defer decoder.deinit(testing.allocator);

    try testing.expect(feedString(
        &decoder,
        testing.allocator,
        "72;t=p:x=0:m=1;!!!!",
    ) == .invalid);

    try testing.expect(feedString(
        &decoder,
        testing.allocator,
        "72;t=p:x=0:m=1;AB",
    ) == .incomplete);
    try testing.expect(feedString(
        &decoder,
        testing.allocator,
        "72;m=0;",
    ) == .invalid);
}

test "OSC 72 decoder preserves drag context on malformed metadata" {
    const testing = std.testing;
    var decoder: Decoder = .{};
    defer decoder.deinit(testing.allocator);

    try testing.expect(feedString(
        &decoder,
        testing.allocator,
        "72;t=p:i=7:x=0:m=1:m=0;YQ",
    ) == .invalid);
    const failure = decoder.last_failure.?;
    try testing.expectEqual(DndError.invalid, failure.err);
    try testing.expectEqual(EventType.present_data, failure.metadata.?.event);
    try testing.expectEqual(@as(?i32, 7), failure.metadata.?.session);
}

test "OSC 72 decoder enforces per-chunk payload limit" {
    const testing = std.testing;
    var decoder: Decoder = .{};
    defer decoder.deinit(testing.allocator);

    const oversized = try testing.allocator.alloc(u8, Decoder.max_chunk_size + 1);
    defer testing.allocator.free(oversized);
    @memset(oversized, 'a');
    const input = try std.fmt.allocPrint(testing.allocator, "72;t=o:o=1;{s}", .{oversized});
    defer testing.allocator.free(input);
    try testing.expect(feedString(&decoder, testing.allocator, input) == .invalid);
    try testing.expectEqual(DndError.too_large, decoder.last_failure.?.err);
    try testing.expectEqual(
        EventType.offer_drag,
        decoder.last_failure.?.metadata.?.event,
    );
}

test "OfferState enforces pre-sent and lazy data limits" {
    var offer: OfferState = .{};
    offer.mime_count = 1;
    offer.pre_sent_bytes = DataLimits.data;
    try std.testing.expectEqual(DndError.too_large, offer.registerPreSentData(0, 1));

    offer.clearActive();
    offer.mime_count = 1;
    offer.lazy_bytes = DataLimits.data;
    try std.testing.expectEqual(DndError.too_large, offer.registerLazyData(0, 1));
}

test "OSC 72 decoder reset frees an in-progress transfer" {
    const testing = std.testing;
    var decoder: Decoder = .{};
    defer decoder.deinit(testing.allocator);

    try testing.expect(feedString(
        &decoder,
        testing.allocator,
        "72;t=o:o=1:m=1;text/",
    ) == .incomplete);
    decoder.reset(testing.allocator);
    try testing.expect(decoder.pending == null);
}

test "OSC 72 decoder drag reset preserves destination transfers" {
    const testing = std.testing;
    var decoder: Decoder = .{};
    defer decoder.deinit(testing.allocator);

    try testing.expect(feedString(
        &decoder,
        testing.allocator,
        "72;t=e:i=7:y=0:m=1;YQ",
    ) == .incomplete);
    decoder.resetDrag(testing.allocator, 7);
    try testing.expect(decoder.pending == null);

    try testing.expect(feedString(
        &decoder,
        testing.allocator,
        "72;t=a:i=7:m=1;text/",
    ) == .incomplete);
    decoder.resetDrag(testing.allocator, 7);
    try testing.expect(decoder.pending != null);
}

test "OSC 72 decoder preserves every local drag command shape" {
    const testing = std.testing;
    const cases = .{
        .{ "72;t=o:i=8:x=1;1:machine", EventType.offer_drag, @as(?i32, 1), @as(?i32, null), @as(?i32, null), "1:machine" },
        .{ "72;t=o:i=8:x=2", EventType.offer_drag, @as(?i32, 2), @as(?i32, null), @as(?i32, null), "" },
        .{ "72;t=o:i=8:o=3;text/plain", EventType.offer_drag, @as(?i32, null), @as(?i32, null), @as(?i32, 3), "text/plain" },
        .{ "72;t=P:i=8:x=0", EventType.change_drag_image, @as(?i32, 0), @as(?i32, null), @as(?i32, null), "" },
        .{ "72;t=P:i=8:x=-1", EventType.change_drag_image, @as(?i32, -1), @as(?i32, null), @as(?i32, null), "" },
        .{ "72;t=E:i=8:y=0;ENOENT", EventType.drag_offer_error, @as(?i32, null), @as(?i32, 0), @as(?i32, null), "ENOENT" },
        .{ "72;t=E:i=8:y=-1", EventType.drag_offer_error, @as(?i32, null), @as(?i32, -1), @as(?i32, null), "" },
    };

    inline for (cases) |case| {
        var decoder: Decoder = .{};
        defer decoder.deinit(testing.allocator);
        const result = feedString(&decoder, testing.allocator, case[0]);
        try testing.expect(result == .complete);
        defer testing.allocator.free(result.complete.payload);
        try testing.expectEqual(case[1], result.complete.metadata.event);
        try testing.expectEqual(@as(?i32, 8), result.complete.metadata.session);
        try testing.expectEqual(case[2], result.complete.metadata.x);
        try testing.expectEqual(case[3], result.complete.metadata.y);
        try testing.expectEqual(case[4], result.complete.metadata.o);
        try testing.expectEqualStrings(case[5], result.complete.payload);
    }
}

test "OSC 72 decoder preserves zero-based data and image metadata" {
    const testing = std.testing;

    {
        var decoder: Decoder = .{};
        defer decoder.deinit(testing.allocator);
        const result = feedString(
            &decoder,
            testing.allocator,
            "72;t=p:i=3:x=0:y=7:X=11:Y=12:o=13:m=0;YQ",
        );
        try testing.expect(result == .complete);
        defer testing.allocator.free(result.complete.payload);
        try testing.expectEqual(@as(?i32, 0), result.complete.metadata.x);
        try testing.expectEqual(@as(?i32, 7), result.complete.metadata.y);
        try testing.expectEqual(@as(?i32, 11), result.complete.metadata.X);
        try testing.expectEqual(@as(?i32, 12), result.complete.metadata.Y);
        try testing.expectEqual(@as(?i32, 13), result.complete.metadata.o);
        try testing.expectEqualStrings("a", result.complete.payload);
        try testing.expect(
            feedString(&decoder, testing.allocator, "72;m=0:i=3;") == .incomplete,
        );
    }

    {
        var decoder: Decoder = .{};
        defer decoder.deinit(testing.allocator);
        const result = feedString(
            &decoder,
            testing.allocator,
            "72;t=p:i=3:x=-1:y=100:X=16:Y=16:o=1024:m=0;aQ",
        );
        try testing.expect(result == .complete);
        defer testing.allocator.free(result.complete.payload);
        try testing.expectEqual(@as(?i32, -1), result.complete.metadata.x);
        try testing.expectEqual(@as(?i32, 100), result.complete.metadata.y);
        try testing.expectEqualStrings("i", result.complete.payload);
        try testing.expect(
            feedString(&decoder, testing.allocator, "72;m=0:i=3;") == .incomplete,
        );
    }

    {
        var decoder: Decoder = .{};
        defer decoder.deinit(testing.allocator);
        const result = feedString(
            &decoder,
            testing.allocator,
            "72;t=e:i=3:y=0:m=0;eg",
        );
        try testing.expect(result == .complete);
        defer testing.allocator.free(result.complete.payload);
        try testing.expectEqual(@as(?i32, 0), result.complete.metadata.y);
        try testing.expectEqualStrings("z", result.complete.payload);
        try testing.expect(
            feedString(&decoder, testing.allocator, "72;m=0:i=3;") == .incomplete,
        );
    }
}

test "OSC 72 default data limit accepts at least 64 MiB" {
    try std.testing.expect(DataLimits.data >= 64 * 1024 * 1024);
}

test "countMimes accepts empty and valid lists" {
    try std.testing.expectEqual(@as(?usize, 0), countMimes(""));
    try std.testing.expectEqual(@as(?usize, 2), countMimes("text/plain text/uri-list"));
    try std.testing.expect(countMimes("text/plain\x00evil") == null);
    try std.testing.expect(countMimes("not-a-mime") == null);
    try std.testing.expect(countMimes("text/plain\n") == null);
}

test "validPngPayload accepts PNG signature only" {
    const png = "\x89PNG\r\n\x1a\n" ++ [_]u8{0} ** 8;
    try std.testing.expect(validPngPayload(png));
    try std.testing.expect(!validPngPayload("not a png"));
}

test "OfferState enforces drag image budgets" {
    var offer: OfferState = .{};
    const rgb = [_]u8{0} ** (1024 * 1024 * 3);
    try std.testing.expect(offer.registerImage(24, 1024, 1024, 0, &rgb) == null);
    try std.testing.expectEqual(DndError.too_large, offer.registerImage(24, 4096, 4096, 0, &rgb));
    offer.clearActive();
    const text = [_]u8{0} ** DragImageLimits.max_text_size;
    try std.testing.expect(offer.registerImage(0, 6, 1, 0, &text) == null);
    const oversized_text = [_]u8{0} ** (DragImageLimits.max_text_size + 1);
    try std.testing.expectEqual(
        DndError.too_large,
        offer.registerImage(0, 6, 1, 0, &oversized_text),
    );
}

test "registerImage rejects non-PNG format 100 payloads" {
    var offer: OfferState = .{};
    const jpeg = [_]u8{ 0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0 };
    try std.testing.expectEqual(DndError.invalid, offer.registerImage(100, 1, 1, 0, &jpeg));
    const png = "\x89PNG\r\n\x1a\n" ++ [_]u8{0} ** 8;
    try std.testing.expect(offer.registerImage(100, 1, 1, 0, png) == null);
}

test "DestinationState validates multiplexer sessions" {
    var destination: DestinationState = .{};
    destination.register(5);
    try std.testing.expect(destination.matches(5));
    try std.testing.expect(!destination.matches(6));
    try std.testing.expect(!destination.matches(null));

    destination.unregister();
    try std.testing.expect(!destination.matches(5));

    destination.register(null);
    try std.testing.expect(destination.matches(null));
    try std.testing.expect(!destination.matches(0));
}
