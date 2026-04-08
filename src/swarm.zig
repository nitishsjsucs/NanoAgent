//! Swarm Primitives for Lite builds.
//!
//! Minimal building blocks for multi-agent coordination on edge devices.
//! Each device is an autonomous agent that can:
//!   - Identify itself (agent_id stored in kv)
//!   - Advertise capabilities (comptime manifest)
//!   - Accept/report tasks via BLE
//!   - Broadcast status via BLE advert byte
//!   - Wrap results in an envelope for aggregation
//!
//! Full swarm coordination (task decomposition, routing, aggregation)
//! happens on the phone/gateway — these are just the on-device primitives.

const std = @import("std");

// ============================================================
// Agent Identity
// ============================================================

pub const ID_LEN = 16;

pub const AgentId = struct {
    id: [ID_LEN]u8 = [_]u8{0} ** ID_LEN,
    id_len: u8 = 0,

    /// Create from a string.
    pub fn fromString(s: []const u8) AgentId {
        var aid = AgentId{};
        const copy_len = @min(s.len, ID_LEN);
        @memcpy(aid.id[0..copy_len], s[0..copy_len]);
        aid.id_len = @intCast(copy_len);
        return aid;
    }

    /// Get the id as a slice.
    pub fn slice(self: *const AgentId) []const u8 {
        return self.id[0..self.id_len];
    }
};

// ============================================================
// Capability Manifest (comptime)
// ============================================================

pub const Capability = enum(u8) {
    temperature = 0,
    humidity = 1,
    pressure = 2,
    motion = 3,
    light = 4,
    gpio = 5,
    adc = 6,
    ble_relay = 7,
};

pub const MAX_CAPABILITIES = 8;

/// Comptime-generated capability manifest. Describes what this device can do.
pub const Manifest = struct {
    capabilities: [MAX_CAPABILITIES]Capability = undefined,
    count: u8 = 0,
    firmware_version: u16 = 0,
    /// Bitmask of capabilities for compact BLE advertisement
    bitmask: u8 = 0,

    /// Build a manifest from a comptime list of capabilities.
    pub fn build(comptime caps: []const Capability, comptime version: u16) Manifest {
        var m = Manifest{ .firmware_version = version };
        for (caps) |c| {
            if (m.count < MAX_CAPABILITIES) {
                m.capabilities[m.count] = c;
                m.bitmask |= @as(u8, 1) << @as(u3, @intCast(@intFromEnum(c)));
                m.count += 1;
            }
        }
        return m;
    }

    /// Check if this device has a capability.
    pub fn has(self: *const Manifest, cap: Capability) bool {
        return (self.bitmask & (@as(u8, 1) << @as(u3, @intCast(@intFromEnum(cap))))) != 0;
    }

    /// Format as JSON.
    pub fn toJson(self: *const Manifest, buf: []u8) usize {
        var pos: usize = 0;
        const header = std.fmt.bufPrint(buf[pos..], "{{\"version\":{d},\"capabilities\":[", .{
            self.firmware_version,
        }) catch return 0;
        pos += header.len;

        var i: u8 = 0;
        while (i < self.count) : (i += 1) {
            if (i > 0) {
                if (pos >= buf.len) break;
                buf[pos] = ',';
                pos += 1;
            }
            const name = capabilityName(self.capabilities[i]);
            const entry = std.fmt.bufPrint(buf[pos..], "\"{s}\"", .{name}) catch break;
            pos += entry.len;
        }

        const footer = std.fmt.bufPrint(buf[pos..], "]}}", .{}) catch return pos;
        pos += footer.len;
        return pos;
    }
};

fn capabilityName(cap: Capability) []const u8 {
    return switch (cap) {
        .temperature => "temperature",
        .humidity => "humidity",
        .pressure => "pressure",
        .motion => "motion",
        .light => "light",
        .gpio => "gpio",
        .adc => "adc",
        .ble_relay => "ble_relay",
    };
}

// ============================================================
// Task Protocol
// ============================================================

pub const TaskState = enum(u8) {
    pending = 0,
    accepted = 1,
    running = 2,
    completed = 3,
    failed = 4,
};

pub const Task = struct {
    /// Task ID (assigned by coordinator)
    task_id: u16 = 0,
    /// Requesting agent
    from: AgentId = .{},
    /// Task description (compact)
    prompt: [128]u8 = [_]u8{0} ** 128,
    prompt_len: u8 = 0,
    state: TaskState = .pending,

    /// Accept a task.
    pub fn accept(self: *Task) void {
        self.state = .accepted;
    }

    /// Mark as running.
    pub fn start(self: *Task) void {
        self.state = .running;
    }

    /// Mark as completed.
    pub fn complete(self: *Task) void {
        self.state = .completed;
    }

    /// Mark as failed.
    pub fn fail(self: *Task) void {
        self.state = .failed;
    }
};

// ============================================================
// Status Beacon
// ============================================================

/// Status byte for BLE advertisement. Encodes device state in 1 byte.
/// Bits 0-2: state (idle/busy/error/sleeping/charging)
/// Bits 3-4: battery level (0-3 = critical/low/ok/full)
/// Bit 5: has pending events
/// Bit 6: task in progress
/// Bit 7: reserved
pub const StatusByte = struct {
    pub const State = enum(u3) {
        idle = 0,
        busy = 1,
        err = 2,
        sleeping = 3,
        charging = 4,
    };

    pub const BatteryLevel = enum(u2) {
        critical = 0,
        low = 1,
        ok = 2,
        full = 3,
    };

    pub fn encode(state: State, battery: BatteryLevel, has_events: bool, task_active: bool) u8 {
        var b: u8 = @intFromEnum(state);
        b |= @as(u8, @intFromEnum(battery)) << 3;
        if (has_events) b |= 1 << 5;
        if (task_active) b |= 1 << 6;
        return b;
    }

    pub fn decodeState(byte: u8) State {
        return @enumFromInt(@as(u3, @truncate(byte)));
    }

    pub fn decodeBattery(byte: u8) BatteryLevel {
        return @enumFromInt(@as(u2, @truncate(byte >> 3)));
    }

    pub fn hasEvents(byte: u8) bool {
        return (byte & (1 << 5)) != 0;
    }

    pub fn taskActive(byte: u8) bool {
        return (byte & (1 << 6)) != 0;
    }
};

// ============================================================
// Result Envelope
// ============================================================

/// Wraps an agent's output for aggregation by the coordinator.
pub const ResultEnvelope = struct {
    agent_id: AgentId = .{},
    task_id: u16 = 0,
    success: bool = true,
    /// Result payload (typically the agent's text output)
    payload: [256]u8 = [_]u8{0} ** 256,
    payload_len: u16 = 0,

    /// True if the payload was truncated to fit the 256-byte buffer.
    truncated: bool = false,

    pub fn wrap(agent_id: AgentId, task_id: u16, success: bool, payload: []const u8) ResultEnvelope {
        var env = ResultEnvelope{
            .agent_id = agent_id,
            .task_id = task_id,
            .success = success,
            .truncated = payload.len > 256,
        };
        const copy_len = @min(payload.len, 256);
        @memcpy(env.payload[0..copy_len], payload[0..copy_len]);
        env.payload_len = @intCast(copy_len);
        return env;
    }

    /// Format as JSON for BLE transmission.
    pub fn toJson(self: *const ResultEnvelope, buf: []u8) usize {
        const result = std.fmt.bufPrint(buf,
            \\{{"agent":"{s}","task_id":{d},"success":{s},"payload":"{s}"}}
        , .{
            self.agent_id.slice(),
            self.task_id,
            if (self.success) "true" else "false",
            self.payload[0..self.payload_len],
        }) catch return 0;
        return result.len;
    }
};

// ============================================================
// Tests
// ============================================================

test "agent id from string" {
    const aid = AgentId.fromString("sensor-node-01");
    try std.testing.expectEqualStrings("sensor-node-01", aid.slice());
}

test "agent id truncation" {
    const aid = AgentId.fromString("this-is-a-very-long-agent-id-string");
    try std.testing.expectEqual(@as(u8, ID_LEN), aid.id_len);
}

test "manifest build and has" {
    const m = Manifest.build(&.{ .temperature, .humidity, .gpio }, 100);
    try std.testing.expectEqual(@as(u8, 3), m.count);
    try std.testing.expect(m.has(.temperature));
    try std.testing.expect(m.has(.humidity));
    try std.testing.expect(m.has(.gpio));
    try std.testing.expect(!m.has(.motion));
    try std.testing.expectEqual(@as(u16, 100), m.firmware_version);
}

test "manifest toJson" {
    const m = Manifest.build(&.{ .temperature, .pressure }, 200);
    var buf: [256]u8 = undefined;
    const n = m.toJson(&buf);
    const json = buf[0..n];
    try std.testing.expect(n > 0);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"temperature\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"pressure\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"version\":200") != null);
}

test "manifest bitmask" {
    const m = Manifest.build(&.{ .temperature, .gpio }, 1);
    // temperature=0 → bit 0, gpio=5 → bit 5
    try std.testing.expectEqual(@as(u8, 0b00100001), m.bitmask);
}

test "task state transitions" {
    var task = Task{ .task_id = 42 };
    try std.testing.expectEqual(TaskState.pending, task.state);
    task.accept();
    try std.testing.expectEqual(TaskState.accepted, task.state);
    task.start();
    try std.testing.expectEqual(TaskState.running, task.state);
    task.complete();
    try std.testing.expectEqual(TaskState.completed, task.state);
}

test "task fail" {
    var task = Task{ .task_id = 1 };
    task.accept();
    task.start();
    task.fail();
    try std.testing.expectEqual(TaskState.failed, task.state);
}

test "status byte encode and decode" {
    const byte = StatusByte.encode(.busy, .ok, true, false);
    try std.testing.expectEqual(StatusByte.State.busy, StatusByte.decodeState(byte));
    try std.testing.expectEqual(StatusByte.BatteryLevel.ok, StatusByte.decodeBattery(byte));
    try std.testing.expect(StatusByte.hasEvents(byte));
    try std.testing.expect(!StatusByte.taskActive(byte));
}

test "status byte all combinations" {
    // idle, full battery, no events, no task
    const b1 = StatusByte.encode(.idle, .full, false, false);
    try std.testing.expectEqual(StatusByte.State.idle, StatusByte.decodeState(b1));
    try std.testing.expectEqual(StatusByte.BatteryLevel.full, StatusByte.decodeBattery(b1));
    try std.testing.expect(!StatusByte.hasEvents(b1));
    try std.testing.expect(!StatusByte.taskActive(b1));

    // sleeping, critical, events, task active
    const b2 = StatusByte.encode(.sleeping, .critical, true, true);
    try std.testing.expectEqual(StatusByte.State.sleeping, StatusByte.decodeState(b2));
    try std.testing.expectEqual(StatusByte.BatteryLevel.critical, StatusByte.decodeBattery(b2));
    try std.testing.expect(StatusByte.hasEvents(b2));
    try std.testing.expect(StatusByte.taskActive(b2));
}

test "result envelope wrap and toJson" {
    const aid = AgentId.fromString("node-01");
    const env = ResultEnvelope.wrap(aid, 42, true, "temp=22C");
    try std.testing.expectEqual(@as(u16, 42), env.task_id);
    try std.testing.expect(env.success);

    var buf: [512]u8 = undefined;
    const n = env.toJson(&buf);
    const json = buf[0..n];
    try std.testing.expect(n > 0);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"node-01\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"task_id\":42") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"success\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "temp=22C") != null);
}

test "result envelope failure" {
    const aid = AgentId.fromString("node-02");
    const env = ResultEnvelope.wrap(aid, 7, false, "timeout");
    try std.testing.expect(!env.success);
    var buf: [512]u8 = undefined;
    const n = env.toJson(&buf);
    const json = buf[0..n];
    try std.testing.expect(std.mem.indexOf(u8, json, "\"success\":false") != null);
}
