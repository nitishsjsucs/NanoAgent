//! Power Budget Estimator for Lite builds.
//!
//! Tracks energy consumption by subsystem so the LLM can reason about
//! battery life and make power-aware decisions (e.g., reduce cron frequency,
//! skip non-critical sensor reads, defer BLE transmissions).
//!
//! All integer math. Energy is tracked in microwatt-hours (µWh) for precision
//! without floating point.
//!
//! Typical budget for a coin-cell (CR2032, 225mAh @ 3V = 675,000 µWh):
//!   CPU active:   ~10mA  → 30,000 µW
//!   BLE TX:       ~8mA   → 24,000 µW
//!   BLE RX:       ~5mA   → 15,000 µW
//!   Sensors:      ~1mA   → 3,000 µW
//!   Sleep:        ~5µA   → 15 µW

const std = @import("std");

pub const Subsystem = enum(u8) {
    cpu = 0,
    ble_tx = 1,
    ble_rx = 2,
    sensor = 3,
    gpio = 4,
    sleep = 5,
};

const NUM_SUBSYSTEMS = 6;

/// Default power draw per subsystem in microwatts (µW).
/// Can be overridden per-device via setBudget().
const default_power_uw = [NUM_SUBSYSTEMS]u32{
    30_000, // cpu active
    24_000, // ble_tx
    15_000, // ble_rx
    3_000, // sensor
    1_000, // gpio
    15, // sleep
};

pub const PowerStats = struct {
    /// Total energy consumed in µWh
    total_uwh: u64,
    /// Energy per subsystem in µWh
    per_subsystem: [NUM_SUBSYSTEMS]u64,
    /// Remaining budget in µWh (0 if no budget set)
    remaining_uwh: u64,
    /// Estimated hours remaining at current rate (0 if no budget or no time elapsed)
    hours_remaining: u32,
};

pub const PowerBudget = struct {
    /// Cumulative active time per subsystem in seconds
    active_s: [NUM_SUBSYSTEMS]u64 = [_]u64{0} ** NUM_SUBSYSTEMS,
    /// Power draw per subsystem in µW (configurable)
    power_uw: [NUM_SUBSYSTEMS]u32 = default_power_uw,
    /// Total battery budget in µWh (0 = no budget)
    budget_uwh: u64 = 0,
    /// Timestamp when tracking started
    start_time: u32 = 0,

    pub fn init() PowerBudget {
        return .{
            .start_time = @intCast(@as(u64, @bitCast(std.time.timestamp()))),
        };
    }

    /// Set total battery capacity (e.g., 675_000 for CR2032).
    pub fn setBudget(self: *PowerBudget, budget_uwh: u64) void {
        self.budget_uwh = budget_uwh;
    }

    /// Set power draw for a subsystem (µW).
    pub fn setPower(self: *PowerBudget, subsystem: Subsystem, power_uw: u32) void {
        self.power_uw[@intFromEnum(subsystem)] = power_uw;
    }

    /// Record that a subsystem was active for duration_s seconds.
    pub fn record(self: *PowerBudget, subsystem: Subsystem, duration_s: u32) void {
        self.active_s[@intFromEnum(subsystem)] += duration_s;
    }

    /// Get energy consumed by a subsystem in µWh.
    pub fn energyUwh(self: *const PowerBudget, subsystem: Subsystem) u64 {
        const idx = @intFromEnum(subsystem);
        // µWh = µW * seconds / 3600
        return self.active_s[idx] * self.power_uw[idx] / 3600;
    }

    /// Get total energy consumed across all subsystems in µWh.
    pub fn totalEnergyUwh(self: *const PowerBudget) u64 {
        var total: u64 = 0;
        for (0..NUM_SUBSYSTEMS) |i| {
            total += self.active_s[i] * self.power_uw[i] / 3600;
        }
        return total;
    }

    /// Get full stats including remaining budget.
    pub fn stats(self: *const PowerBudget) PowerStats {
        var per: [NUM_SUBSYSTEMS]u64 = undefined;
        var total: u64 = 0;
        for (0..NUM_SUBSYSTEMS) |i| {
            per[i] = self.active_s[i] * self.power_uw[i] / 3600;
            total += per[i];
        }

        const remaining = if (self.budget_uwh > total) self.budget_uwh - total else 0;
        const now: u32 = @intCast(@as(u64, @bitCast(std.time.timestamp())));
        const elapsed = if (now > self.start_time) now - self.start_time else 1;
        const hours_remaining: u32 = if (total > 0)
            @intCast(remaining * @as(u64, elapsed) / total / 3600)
        else
            0;

        return .{
            .total_uwh = total,
            .per_subsystem = per,
            .remaining_uwh = remaining,
            .hours_remaining = hours_remaining,
        };
    }

    /// Format as JSON for inclusion in LLM tool response.
    pub fn toJson(self: *const PowerBudget, buf: []u8) usize {
        const s = self.stats();
        const result = std.fmt.bufPrint(buf,
            \\{{"total_uwh":{d},"budget_uwh":{d},"remaining_uwh":{d},"hours_remaining":{d},"cpu_uwh":{d},"ble_tx_uwh":{d},"ble_rx_uwh":{d},"sensor_uwh":{d},"gpio_uwh":{d},"sleep_uwh":{d}}}
        , .{
            s.total_uwh,
            self.budget_uwh,
            s.remaining_uwh,
            s.hours_remaining,
            s.per_subsystem[0],
            s.per_subsystem[1],
            s.per_subsystem[2],
            s.per_subsystem[3],
            s.per_subsystem[4],
            s.per_subsystem[5],
        }) catch return 0;
        return result.len;
    }
};

// ============================================================
// Tests
// ============================================================

test "power budget init" {
    const pb = PowerBudget.init();
    try std.testing.expectEqual(@as(u64, 0), pb.totalEnergyUwh());
    try std.testing.expectEqual(@as(u64, 0), pb.budget_uwh);
}

test "power budget record and energy" {
    var pb = PowerBudget.init();
    pb.record(.cpu, 3600); // 1 hour of CPU
    // 30,000 µW * 3600s / 3600 = 30,000 µWh
    try std.testing.expectEqual(@as(u64, 30_000), pb.energyUwh(.cpu));
    try std.testing.expectEqual(@as(u64, 30_000), pb.totalEnergyUwh());
}

test "power budget multiple subsystems" {
    var pb = PowerBudget.init();
    pb.record(.cpu, 3600);
    pb.record(.ble_tx, 360); // 6 min TX
    pb.record(.sensor, 7200); // 2 hours sensor
    // CPU: 30000, BLE_TX: 24000*360/3600=2400, Sensor: 3000*7200/3600=6000
    try std.testing.expectEqual(@as(u64, 30_000), pb.energyUwh(.cpu));
    try std.testing.expectEqual(@as(u64, 2_400), pb.energyUwh(.ble_tx));
    try std.testing.expectEqual(@as(u64, 6_000), pb.energyUwh(.sensor));
    try std.testing.expectEqual(@as(u64, 38_400), pb.totalEnergyUwh());
}

test "power budget remaining" {
    var pb = PowerBudget.init();
    pb.setBudget(675_000); // CR2032
    pb.record(.cpu, 3600); // burns 30,000 µWh
    const s = pb.stats();
    try std.testing.expectEqual(@as(u64, 645_000), s.remaining_uwh);
}

test "power budget custom power draw" {
    var pb = PowerBudget.init();
    pb.setPower(.cpu, 50_000); // higher-power MCU
    pb.record(.cpu, 3600);
    try std.testing.expectEqual(@as(u64, 50_000), pb.energyUwh(.cpu));
}

test "power budget toJson" {
    var pb = PowerBudget.init();
    pb.setBudget(675_000);
    pb.record(.cpu, 3600);
    var buf: [512]u8 = undefined;
    const n = pb.toJson(&buf);
    const json = buf[0..n];
    try std.testing.expect(n > 0);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"total_uwh\":30000") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"budget_uwh\":675000") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"remaining_uwh\":645000") != null);
}

test "power budget zero consumption" {
    var pb = PowerBudget.init();
    pb.setBudget(100_000);
    const s = pb.stats();
    try std.testing.expectEqual(@as(u64, 0), s.total_uwh);
    try std.testing.expectEqual(@as(u64, 100_000), s.remaining_uwh);
    try std.testing.expectEqual(@as(u32, 0), s.hours_remaining); // no rate to extrapolate
}

test "power budget over-budget" {
    var pb = PowerBudget.init();
    pb.setBudget(100); // tiny budget
    pb.record(.cpu, 3600); // burns 30,000 µWh — way over budget
    const s = pb.stats();
    try std.testing.expectEqual(@as(u64, 0), s.remaining_uwh); // clamped to 0
}
