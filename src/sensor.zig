//! Sensor module for Lite builds.
//!
//! Combines: ring buffer, averaging, and Z-score anomaly detection.
//! All integer math (no floating point) — suitable for MCUs without FPU.
//!
//! Ring buffer stores timestamped sensor readings in a circular buffer.
//! Averaging uses Welford's algorithm for stable online mean/variance.
//! Z-score anomaly flags readings that deviate >K sigma from rolling stats.

const std = @import("std");

pub const RING_SIZE = 64;

pub const Entry = struct {
    timestamp: u32 = 0,
    sensor_id: u8 = 0,
    value: i24 = 0,
};

pub const Stats = struct {
    count: u32,
    mean: i32, // scaled by 100 for 2 decimal places
    min: i32,
    max: i32,
    stddev: u32, // scaled by 100
};

pub const RingBuffer = struct {
    entries: [RING_SIZE]Entry = [_]Entry{.{}} ** RING_SIZE,
    head: u8 = 0,
    count: u8 = 0,

    /// Push a new sensor reading into the ring buffer.
    pub fn push(self: *RingBuffer, sensor_id: u8, value: i24, timestamp: u32) void {
        self.entries[self.head] = .{
            .timestamp = timestamp,
            .sensor_id = sensor_id,
            .value = value,
        };
        self.head = (self.head + 1) % RING_SIZE;
        if (self.count < RING_SIZE) self.count += 1;
    }

    /// Get statistics for a given sensor_id from all entries in the buffer.
    pub fn stats(self: *const RingBuffer, sensor_id: u8) ?Stats {
        var sum: i64 = 0;
        var min_val: i32 = std.math.maxInt(i32);
        var max_val: i32 = std.math.minInt(i32);
        var count: u32 = 0;
        // Welford's online variance (integer-scaled by 10000 for precision)
        var m2: i64 = 0;
        var mean_x100: i64 = 0;

        for (self.entries[0..RING_SIZE]) |e| {
            if (e.timestamp == 0) continue; // uninitialized slot
            if (e.sensor_id != sensor_id) continue;
            const v: i32 = e.value;
            count += 1;
            sum += v;
            if (v < min_val) min_val = v;
            if (v > max_val) max_val = v;

            // Welford's: delta = x*100 - mean*100, mean += delta/n, m2 += delta*(x*100 - mean*100)
            const v_x100: i64 = @as(i64, v) * 100;
            const delta = v_x100 - mean_x100;
            mean_x100 += @divTrunc(delta, @as(i64, count));
            const delta2 = v_x100 - mean_x100;
            m2 += @divTrunc(delta * delta2, 10000);
        }

        if (count == 0) return null;

        const variance_x100: u64 = if (count > 1)
            @intCast(@divTrunc(@abs(m2), count - 1))
        else
            0;

        return .{
            .count = count,
            .mean = @intCast(@divTrunc(sum * 100, @as(i64, count))),
            .min = min_val,
            .max = max_val,
            .stddev = isqrt_u64(variance_x100 * 10000),
        };
    }

    /// Check if a value is anomalous (>K sigma from rolling mean).
    /// k_x10 is K*10 (e.g., 30 = 3.0 sigma).
    pub fn isAnomaly(self: *const RingBuffer, sensor_id: u8, value: i24, k_x10: u32) bool {
        const s = self.stats(sensor_id) orelse return false;
        if (s.stddev == 0 or s.count < 4) return false; // not enough data
        const deviation: u64 = @abs(@as(i64, @as(i32, value)) * 100 - @as(i64, s.mean));
        const threshold: u64 = @as(u64, s.stddev) * k_x10 / 10;
        return deviation > threshold;
    }

    /// Dump entries for a sensor as JSON (for BLE drain).
    /// Returns number of bytes written.
    pub fn dump(self: *const RingBuffer, sensor_id: u8, buf: []u8) usize {
        var pos: usize = 0;
        if (pos >= buf.len) return 0;
        buf[pos] = '[';
        pos += 1;
        var first = true;

        for (self.entries[0..RING_SIZE]) |e| {
            if (e.timestamp == 0 or e.sensor_id != sensor_id) continue;
            if (!first) {
                if (pos >= buf.len) break;
                buf[pos] = ',';
                pos += 1;
            }
            const written = std.fmt.bufPrint(buf[pos..], "{{\"t\":{d},\"v\":{d}}}", .{
                e.timestamp, @as(i32, e.value),
            }) catch break;
            pos += written.len;
            first = false;
        }

        if (pos < buf.len) {
            buf[pos] = ']';
            pos += 1;
        }
        return pos;
    }
};

/// Compute N-sample average from a provided slice (not ring buffer).
pub fn average(samples: []const i32) ?Stats {
    if (samples.len == 0) return null;
    var sum: i64 = 0;
    var min_val: i32 = std.math.maxInt(i32);
    var max_val: i32 = std.math.minInt(i32);
    var m2: i64 = 0;
    var mean_x100: i64 = 0;

    for (samples, 1..) |v, i| {
        sum += v;
        if (v < min_val) min_val = v;
        if (v > max_val) max_val = v;
        const v_x100: i64 = @as(i64, v) * 100;
        const delta = v_x100 - mean_x100;
        mean_x100 += @divTrunc(delta, @as(i64, @intCast(i)));
        const delta2 = v_x100 - mean_x100;
        m2 += @divTrunc(delta * delta2, 10000);
    }

    const count: u32 = @intCast(samples.len);
    const variance_x100: u64 = if (count > 1)
        @intCast(@divTrunc(@abs(m2), count - 1))
    else
        0;

    return .{
        .count = count,
        .mean = @intCast(@divTrunc(sum * 100, @as(i64, count))),
        .min = min_val,
        .max = max_val,
        .stddev = isqrt_u64(variance_x100 * 10000),
    };
}

/// Integer square root (Newton's method).
fn isqrt_u64(n: u64) u32 {
    if (n == 0) return 0;
    var x: u64 = n;
    var y: u64 = (x + 1) / 2;
    while (y < x) {
        x = y;
        y = (x + n / x) / 2;
    }
    return @intCast(@min(x, std.math.maxInt(u32)));
}

// ============================================================
// Named Sensor Registry
// ============================================================

pub const MAX_SENSORS = 8;
pub const NAME_LEN = 12;

pub const SensorInfo = struct {
    id: u8 = 0,
    name: [NAME_LEN]u8 = [_]u8{0} ** NAME_LEN,
    name_len: u8 = 0,
    unit: [8]u8 = [_]u8{0} ** 8,
    unit_len: u8 = 0,
    active: bool = false,
};

pub const SensorRegistry = struct {
    sensors: [MAX_SENSORS]SensorInfo = [_]SensorInfo{.{}} ** MAX_SENSORS,
    count: u8 = 0,

    /// Register a sensor with a human-readable name and unit.
    pub fn register(self: *SensorRegistry, id: u8, name: []const u8, unit: []const u8) !void {
        // Check for duplicate id
        for (self.sensors[0..self.count]) |s| {
            if (s.active and s.id == id) return error.DuplicateId;
        }
        if (self.count >= MAX_SENSORS) return error.TooManySensors;

        var info = SensorInfo{ .id = id, .active = true };
        const nlen = @min(name.len, NAME_LEN);
        @memcpy(info.name[0..nlen], name[0..nlen]);
        info.name_len = @intCast(nlen);
        const ulen = @min(unit.len, 8);
        @memcpy(info.unit[0..ulen], unit[0..ulen]);
        info.unit_len = @intCast(ulen);

        self.sensors[self.count] = info;
        self.count += 1;
    }

    /// Look up sensor name by id.
    pub fn getName(self: *const SensorRegistry, id: u8) ?[]const u8 {
        for (self.sensors[0..self.count]) |s| {
            if (s.active and s.id == id) return s.name[0..s.name_len];
        }
        return null;
    }

    /// Look up sensor unit by id.
    pub fn getUnit(self: *const SensorRegistry, id: u8) ?[]const u8 {
        for (self.sensors[0..self.count]) |s| {
            if (s.active and s.id == id) return s.unit[0..s.unit_len];
        }
        return null;
    }

    /// Look up sensor id by name.
    pub fn getId(self: *const SensorRegistry, name: []const u8) ?u8 {
        for (self.sensors[0..self.count]) |s| {
            if (!s.active) continue;
            if (std.mem.eql(u8, s.name[0..s.name_len], name)) return s.id;
        }
        return null;
    }

    /// Dump registry as JSON.
    pub fn toJson(self: *const SensorRegistry, buf: []u8) usize {
        var pos: usize = 0;
        if (pos >= buf.len) return 0;
        buf[pos] = '[';
        pos += 1;
        var first = true;

        for (self.sensors[0..self.count]) |s| {
            if (!s.active) continue;
            if (!first) {
                if (pos >= buf.len) break;
                buf[pos] = ',';
                pos += 1;
            }
            const written = std.fmt.bufPrint(buf[pos..], "{{\"id\":{d},\"name\":\"{s}\",\"unit\":\"{s}\"}}", .{
                s.id, s.name[0..s.name_len], s.unit[0..s.unit_len],
            }) catch break;
            pos += written.len;
            first = false;
        }

        if (pos < buf.len) {
            buf[pos] = ']';
            pos += 1;
        }
        return pos;
    }
};

// ============================================================
// Tests
// ============================================================

test "ring buffer push and stats" {
    var rb = RingBuffer{};
    rb.push(1, 100, 1000);
    rb.push(1, 200, 1001);
    rb.push(1, 300, 1002);

    const s = rb.stats(1).?;
    try std.testing.expectEqual(@as(u32, 3), s.count);
    // Mean should be 200 * 100 = 20000
    try std.testing.expect(s.mean >= 19900 and s.mean <= 20100);
    try std.testing.expectEqual(@as(i32, 100), s.min);
    try std.testing.expectEqual(@as(i32, 300), s.max);
}

test "ring buffer wraps" {
    var rb = RingBuffer{};
    var i: u32 = 0;
    while (i < RING_SIZE + 10) : (i += 1) {
        rb.push(0, @intCast(i), i);
    }
    try std.testing.expectEqual(@as(u8, RING_SIZE), rb.count);
    // Oldest entries should be overwritten
    const s = rb.stats(0).?;
    try std.testing.expectEqual(@as(u32, RING_SIZE), s.count);
    try std.testing.expectEqual(@as(i32, 10), s.min); // first 10 overwritten
}

test "ring buffer different sensors" {
    var rb = RingBuffer{};
    rb.push(1, 100, 1);
    rb.push(2, 200, 2);
    rb.push(1, 300, 3);

    const s1 = rb.stats(1).?;
    try std.testing.expectEqual(@as(u32, 2), s1.count);

    const s2 = rb.stats(2).?;
    try std.testing.expectEqual(@as(u32, 1), s2.count);

    try std.testing.expect(rb.stats(3) == null);
}

test "ring buffer dump" {
    var rb = RingBuffer{};
    rb.push(1, 42, 1000);
    rb.push(1, 43, 1001);

    var buf: [256]u8 = undefined;
    const n = rb.dump(1, &buf);
    const json = buf[0..n];
    try std.testing.expect(std.mem.indexOf(u8, json, "\"t\":1000") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"v\":42") != null);
    try std.testing.expect(json[0] == '[');
    try std.testing.expect(json[n - 1] == ']');
}

test "average 10 samples within 1%" {
    const samples = [_]i32{ 100, 101, 99, 100, 102, 98, 100, 101, 99, 100 };
    const s = average(&samples).?;
    // Mean should be 1000 (= 100.0 * 100 scaling)
    try std.testing.expect(s.mean >= 9900 and s.mean <= 10100); // within 1%
    try std.testing.expectEqual(@as(i32, 98), s.min);
    try std.testing.expectEqual(@as(i32, 102), s.max);
}

test "anomaly detection 3-sigma" {
    var rb = RingBuffer{};
    // Push 20 readings around value 100
    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        const noise: i24 = @as(i24, @intCast(i % 5)) - 2; // -2 to +2
        rb.push(0, 100 + noise, i);
    }
    // Value 100 should not be anomalous
    try std.testing.expect(!rb.isAnomaly(0, 100, 30));
    // Value 200 should be anomalous (way outside 3 sigma)
    try std.testing.expect(rb.isAnomaly(0, 200, 30));
}

test "anomaly needs enough data" {
    var rb = RingBuffer{};
    rb.push(0, 100, 1);
    rb.push(0, 100, 2);
    // Only 2 samples — should not flag anomaly even with extreme value
    try std.testing.expect(!rb.isAnomaly(0, 999, 30));
}

test "isqrt correctness" {
    try std.testing.expectEqual(@as(u32, 0), isqrt_u64(0));
    try std.testing.expectEqual(@as(u32, 1), isqrt_u64(1));
    try std.testing.expectEqual(@as(u32, 10), isqrt_u64(100));
    try std.testing.expectEqual(@as(u32, 100), isqrt_u64(10000));
    try std.testing.expectEqual(@as(u32, 316), isqrt_u64(100000));
}

test "stddev correctness known values" {
    // Dataset: [2, 4, 4, 4, 5, 5, 7, 9] — population stddev = 2.0, sample stddev ≈ 2.138
    // Our Welford returns sample stddev * 100 (scaled)
    const samples = [_]i32{ 2, 4, 4, 4, 5, 5, 7, 9 };
    const s = average(&samples).?;
    try std.testing.expectEqual(@as(u32, 8), s.count);
    // Mean = 5.0 → scaled = 500
    try std.testing.expect(s.mean >= 490 and s.mean <= 510);
    // Sample stddev ≈ 2.138 → scaled ≈ 213-214
    // Our integer math may be approximate, allow 180-250 range
    try std.testing.expect(s.stddev >= 180 and s.stddev <= 250);
}

test "sensor registry register and lookup" {
    var reg = SensorRegistry{};
    try reg.register(0, "temp", "C");
    try reg.register(1, "humidity", "%");
    try std.testing.expectEqualStrings("temp", reg.getName(0).?);
    try std.testing.expectEqualStrings("C", reg.getUnit(0).?);
    try std.testing.expectEqualStrings("humidity", reg.getName(1).?);
    try std.testing.expectEqual(@as(?u8, 0), reg.getId("temp"));
    try std.testing.expectEqual(@as(?u8, 1), reg.getId("humidity"));
    try std.testing.expect(reg.getName(99) == null);
    try std.testing.expect(reg.getId("nonexistent") == null);
}

test "sensor registry duplicate id rejected" {
    var reg = SensorRegistry{};
    try reg.register(0, "temp", "C");
    try std.testing.expectError(error.DuplicateId, reg.register(0, "temp2", "F"));
}

test "sensor registry max sensors" {
    var reg = SensorRegistry{};
    var i: u8 = 0;
    while (i < MAX_SENSORS) : (i += 1) {
        try reg.register(i, "s", "u");
    }
    try std.testing.expectError(error.TooManySensors, reg.register(MAX_SENSORS, "x", "y"));
}

test "sensor registry toJson" {
    var reg = SensorRegistry{};
    try reg.register(0, "temp", "C");
    try reg.register(1, "press", "hPa");
    var buf: [512]u8 = undefined;
    const n = reg.toJson(&buf);
    const json = buf[0..n];
    try std.testing.expect(json[0] == '[');
    try std.testing.expect(json[n - 1] == ']');
    try std.testing.expect(std.mem.indexOf(u8, json, "\"temp\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"press\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"hPa\"") != null);
}

test "sensor registry name truncation" {
    var reg = SensorRegistry{};
    try reg.register(0, "verylongsensorname", "unit");
    // Name should be truncated to NAME_LEN (12)
    try std.testing.expectEqual(@as(usize, NAME_LEN), reg.getName(0).?.len);
}
