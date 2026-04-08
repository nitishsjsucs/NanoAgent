//! Offline Event Queue for Lite builds.
//!
//! Buffers events (trigger fires, anomalies, heartbeats) while BLE is
//! disconnected. Drains to the phone/gateway on reconnect.
//!
//! Fixed-size circular buffer — no heap allocation. Events that arrive
//! when the buffer is full overwrite the oldest entry.
//!
//! Usage:
//!   var eq = EventQueue{};
//!   eq.push(.trigger_fire, 1, 90);   // sensor 1 hit 90
//!   eq.push(.anomaly, 2, 500);       // sensor 2 anomaly at 500
//!   // On BLE reconnect:
//!   const json = eq.drain(buf);       // serialize and clear

const std = @import("std");

pub const MAX_EVENTS = 16;

pub const EventKind = enum(u8) {
    trigger_fire = 0,
    anomaly = 1,
    heartbeat = 2,
    fault = 3,
    user_action = 4,
    sensor_reading = 5,
};

pub const Event = struct {
    kind: EventKind = .heartbeat,
    sensor_id: u8 = 0,
    value: i32 = 0,
    timestamp: u32 = 0,
};

pub const EventQueue = struct {
    events: [MAX_EVENTS]Event = [_]Event{.{}} ** MAX_EVENTS,
    head: u8 = 0,
    count: u8 = 0,
    /// Total events pushed (including overwritten ones)
    total_pushed: u32 = 0,
    /// Total events dropped (overwritten before drain)
    total_dropped: u32 = 0,

    /// Push an event into the queue. Overwrites oldest if full.
    pub fn push(self: *EventQueue, kind: EventKind, sensor_id: u8, value: i32) void {
        self.pushWithTimestamp(kind, sensor_id, value, @intCast(@as(u64, @bitCast(std.time.timestamp()))));
    }

    /// Push with explicit timestamp (for testing).
    pub fn pushWithTimestamp(self: *EventQueue, kind: EventKind, sensor_id: u8, value: i32, timestamp: u32) void {
        if (self.count == MAX_EVENTS) {
            self.total_dropped += 1;
        }
        self.events[self.head] = .{
            .kind = kind,
            .sensor_id = sensor_id,
            .value = value,
            .timestamp = timestamp,
        };
        self.head = (self.head + 1) % MAX_EVENTS;
        if (self.count < MAX_EVENTS) self.count += 1;
        self.total_pushed += 1;
    }

    /// Number of pending events.
    pub fn pending(self: *const EventQueue) u8 {
        return self.count;
    }

    /// Returns true if the queue has events to drain.
    pub fn hasPending(self: *const EventQueue) bool {
        return self.count > 0;
    }

    /// Drain all pending events as a JSON array into buf.
    /// Returns number of bytes written. Always produces valid JSON (closing `]` guaranteed).
    /// Clears the queue.
    pub fn drain(self: *EventQueue, buf: []u8) usize {
        if (buf.len < 2) return 0; // Need at least "[]"

        if (self.count == 0) {
            buf[0] = '[';
            buf[1] = ']';
            return 2;
        }

        var pos: usize = 0;
        buf[pos] = '[';
        pos += 1;

        // Walk from oldest to newest
        const start = if (self.count == MAX_EVENTS)
            self.head // oldest is at head when full
        else
            (self.head + MAX_EVENTS - self.count) % MAX_EVENTS;

        var first = true;
        var i: u8 = 0;
        while (i < self.count) : (i += 1) {
            const idx = (start + i) % MAX_EVENTS;
            const e = self.events[idx];

            // Reserve 1 byte for closing ']'
            const remaining = buf.len - pos;
            if (remaining <= 1) break;

            const comma_cost: usize = if (first) 0 else 1;
            const kind_str: []const u8 = switch (e.kind) {
                .trigger_fire => "trigger",
                .anomaly => "anomaly",
                .heartbeat => "heartbeat",
                .fault => "fault",
                .user_action => "user",
                .sensor_reading => "sensor",
            };

            // Try to format into remaining space (minus 1 for ']')
            if (!first) {
                if (remaining <= 2) break; // need comma + ']'
                buf[pos] = ',';
                pos += 1;
            }
            _ = comma_cost;

            const written = std.fmt.bufPrint(buf[pos .. buf.len - 1], "{{\"k\":\"{s}\",\"s\":{d},\"v\":{d},\"t\":{d}}}", .{
                kind_str, e.sensor_id, e.value, e.timestamp,
            }) catch {
                // Undo comma if we added one
                if (!first) pos -= 1;
                break;
            };
            pos += written.len;
            first = false;
        }

        buf[pos] = ']';
        pos += 1;

        // Clear the queue
        self.count = 0;
        self.head = 0;

        return pos;
    }

    /// Clear the queue without draining.
    pub fn clear(self: *EventQueue) void {
        self.count = 0;
        self.head = 0;
    }
};

// ============================================================
// Tests
// ============================================================

test "event queue push and pending" {
    var eq = EventQueue{};
    try std.testing.expectEqual(@as(u8, 0), eq.pending());
    eq.pushWithTimestamp(.trigger_fire, 1, 90, 1000);
    try std.testing.expectEqual(@as(u8, 1), eq.pending());
    eq.pushWithTimestamp(.anomaly, 2, 500, 1001);
    try std.testing.expectEqual(@as(u8, 2), eq.pending());
    try std.testing.expect(eq.hasPending());
}

test "event queue drain produces JSON" {
    var eq = EventQueue{};
    eq.pushWithTimestamp(.trigger_fire, 1, 90, 1000);
    eq.pushWithTimestamp(.anomaly, 2, 500, 1001);

    var buf: [512]u8 = undefined;
    const n = eq.drain(&buf);
    const json = buf[0..n];
    try std.testing.expect(json[0] == '[');
    try std.testing.expect(json[n - 1] == ']');
    try std.testing.expect(std.mem.indexOf(u8, json, "\"trigger\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"anomaly\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"t\":1000") != null);
    // Queue should be empty after drain
    try std.testing.expectEqual(@as(u8, 0), eq.pending());
}

test "event queue drain empty" {
    var eq = EventQueue{};
    var buf: [64]u8 = undefined;
    const n = eq.drain(&buf);
    try std.testing.expectEqualStrings("[]", buf[0..n]);
}

test "event queue overflow wraps and tracks drops" {
    var eq = EventQueue{};
    var i: u32 = 0;
    while (i < MAX_EVENTS + 4) : (i += 1) {
        eq.pushWithTimestamp(.sensor_reading, 0, @intCast(i), i);
    }
    try std.testing.expectEqual(@as(u8, MAX_EVENTS), eq.pending());
    try std.testing.expectEqual(@as(u32, MAX_EVENTS + 4), eq.total_pushed);
    try std.testing.expectEqual(@as(u32, 4), eq.total_dropped);

    // Oldest should be i=4 (first 4 overwritten)
    var buf: [2048]u8 = undefined;
    const n = eq.drain(&buf);
    const json = buf[0..n];
    // Should contain value 4 (oldest kept) and 19 (newest)
    try std.testing.expect(std.mem.indexOf(u8, json, "\"v\":4") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"v\":19") != null);
}

test "event queue clear" {
    var eq = EventQueue{};
    eq.pushWithTimestamp(.heartbeat, 0, 0, 100);
    eq.pushWithTimestamp(.heartbeat, 0, 0, 200);
    try std.testing.expectEqual(@as(u8, 2), eq.pending());
    eq.clear();
    try std.testing.expectEqual(@as(u8, 0), eq.pending());
}

test "event queue all event kinds" {
    var eq = EventQueue{};
    const kinds = [_]EventKind{ .trigger_fire, .anomaly, .heartbeat, .fault, .user_action, .sensor_reading };
    for (kinds, 0..) |kind, i| {
        eq.pushWithTimestamp(kind, 0, 0, @intCast(i));
    }
    try std.testing.expectEqual(@as(u8, 6), eq.pending());
    var buf: [1024]u8 = undefined;
    const n = eq.drain(&buf);
    const json = buf[0..n];
    try std.testing.expect(std.mem.indexOf(u8, json, "\"trigger\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"anomaly\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"heartbeat\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"fault\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"user\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"sensor\"") != null);
}

test "event queue drain small buffer guarantees closing bracket" {
    var eq = EventQueue{};
    eq.pushWithTimestamp(.trigger_fire, 1, 90, 1000);
    eq.pushWithTimestamp(.anomaly, 2, 500, 1001);

    // Buffer too small for any event but must still produce valid JSON
    var tiny_buf: [2]u8 = undefined;
    const n_tiny = eq.drain(&tiny_buf);
    try std.testing.expectEqualStrings("[]", tiny_buf[0..n_tiny]);

    // Re-push since drain cleared
    eq.pushWithTimestamp(.trigger_fire, 1, 90, 1000);

    // Buffer big enough for '[' + one event + ']' but not two
    var small_buf: [64]u8 = undefined;
    const n_small = eq.drain(&small_buf);
    const json = small_buf[0..n_small];
    try std.testing.expect(json[0] == '[');
    try std.testing.expect(json[n_small - 1] == ']');

    // Buffer of 1 byte — returns 0
    var one_buf: [1]u8 = undefined;
    eq.pushWithTimestamp(.heartbeat, 0, 0, 100);
    const n_one = eq.drain(&one_buf);
    try std.testing.expectEqual(@as(usize, 0), n_one);
}

test "event queue preserves order on drain" {
    var eq = EventQueue{};
    eq.pushWithTimestamp(.sensor_reading, 0, 10, 100);
    eq.pushWithTimestamp(.sensor_reading, 0, 20, 200);
    eq.pushWithTimestamp(.sensor_reading, 0, 30, 300);

    var buf: [512]u8 = undefined;
    const n = eq.drain(&buf);
    const json = buf[0..n];
    // 10 should appear before 20, which should appear before 30
    const pos10 = std.mem.indexOf(u8, json, "\"v\":10").?;
    const pos20 = std.mem.indexOf(u8, json, "\"v\":20").?;
    const pos30 = std.mem.indexOf(u8, json, "\"v\":30").?;
    try std.testing.expect(pos10 < pos20);
    try std.testing.expect(pos20 < pos30);
}
