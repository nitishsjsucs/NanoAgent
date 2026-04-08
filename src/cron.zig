//! Lightweight cron/heartbeat scheduler for NanoAgent.
//!
//! Provides interval-based task scheduling with minimal binary footprint.
//! Designed for edge devices that need periodic agent runs, data collection
//! heartbeats, or keep-alive signals between connectivity windows.
//!
//! Usage:
//!   --cron-interval 300       Run agent every 300 seconds with cron prompt
//!   --cron-prompt "check sensors and report"
//!   --heartbeat 60            Log heartbeat every 60 seconds
//!
//! Architecture:
//!   Uses POSIX timer_create or std.time for scheduling. No threads — uses
//!   a simple poll loop between agent runs. Suitable for both Lite (BLE/Serial)
//!   and Full (HTTP) profiles.

const std = @import("std");
const types = @import("types.zig");

/// Cron configuration — parsed from CLI or config file.
pub const CronConfig = struct {
    /// Interval in seconds between agent runs. 0 = disabled.
    interval_s: u32 = 0,
    /// Prompt to send to the agent on each cron tick.
    prompt: []const u8 = "heartbeat: check status and report any anomalies",
    /// Heartbeat interval in seconds. 0 = disabled. Logs a heartbeat line.
    heartbeat_s: u32 = 0,
    /// Maximum number of cron runs. 0 = unlimited.
    max_runs: u32 = 0,
};

/// Scheduler state — tracks timing for cron and heartbeat.
/// Supports adaptive backoff: interval doubles on idle ticks, resets on rule fires.
pub const Scheduler = struct {
    config: CronConfig,
    last_cron: i64,
    last_heartbeat: i64,
    run_count: u32,
    start_time: i64,
    stdout: std.fs.File.DeprecatedWriter,
    /// Current adaptive interval (may differ from config.interval_s)
    current_interval: u32,
    /// Minimum interval (= config.interval_s)
    min_interval: u32,
    /// Maximum interval (= config.interval_s * 16, capped at 1 hour)
    max_interval: u32,
    /// Number of idle ticks since last event
    idle_ticks: u32 = 0,

    pub fn init(config: CronConfig) Scheduler {
        const now = std.time.timestamp();
        const max_i = @min(config.interval_s * 16, 3600); // cap at 1 hour
        return .{
            .config = config,
            .last_cron = now,
            .last_heartbeat = now,
            .run_count = 0,
            .start_time = now,
            .stdout = std.fs.File.stdout().deprecatedWriter(),
            .current_interval = config.interval_s,
            .min_interval = config.interval_s,
            .max_interval = if (config.interval_s > 0) max_i else 0,
        };
    }

    /// Signal that something interesting happened (rule fired, user input, etc.)
    /// Resets the adaptive backoff to minimum interval.
    pub fn resetBackoff(self: *Scheduler) void {
        self.current_interval = self.min_interval;
        self.idle_ticks = 0;
    }

    /// Signal an idle tick — doubles the interval up to max.
    pub fn backoff(self: *Scheduler) void {
        self.idle_ticks += 1;
        if (self.current_interval < self.max_interval) {
            self.current_interval = @min(self.current_interval * 2, self.max_interval);
        }
    }

    /// Check if it's time for a cron agent run.
    /// Uses current_interval (which may be backed off from config.interval_s).
    pub fn shouldRunAgent(self: *Scheduler) bool {
        if (self.config.interval_s == 0) return false;
        if (self.config.max_runs > 0 and self.run_count >= self.config.max_runs) return false;

        const now = std.time.timestamp();
        const elapsed: u64 = @intCast(now - self.last_cron);
        if (elapsed >= self.current_interval) {
            self.last_cron = now;
            self.run_count += 1;
            return true;
        }
        return false;
    }

    /// Check if it's time for a heartbeat log.
    pub fn shouldHeartbeat(self: *Scheduler) bool {
        if (self.config.heartbeat_s == 0) return false;

        const now = std.time.timestamp();
        const elapsed: u64 = @intCast(now - self.last_heartbeat);
        if (elapsed >= self.config.heartbeat_s) {
            self.last_heartbeat = now;
            return true;
        }
        return false;
    }

    /// Emit a heartbeat log line (lightweight, no allocation).
    pub fn emitHeartbeat(self: *Scheduler) void {
        const now = std.time.timestamp();
        const uptime: u64 = @intCast(now - self.start_time);
        self.stdout.print("[heartbeat] up:{d}s runs:{d}\n", .{ uptime, self.run_count }) catch {};
    }

    /// Get the cron prompt for this tick.
    pub fn getCronPrompt(self: *const Scheduler) []const u8 {
        return self.config.prompt;
    }

    /// Returns true if the scheduler is active (either cron or heartbeat enabled).
    pub fn isActive(self: *const Scheduler) bool {
        return self.config.interval_s > 0 or self.config.heartbeat_s > 0;
    }

    /// Sleep until the next event (cron or heartbeat), whichever comes first.
    /// Returns immediately if nothing is scheduled.
    pub fn sleepUntilNext(self: *const Scheduler) void {
        if (!self.isActive()) return;

        var min_wait: u64 = std.math.maxInt(u64);
        const now = std.time.timestamp();

        if (self.config.interval_s > 0) {
            const elapsed: u64 = @intCast(now - self.last_cron);
            const remaining = if (elapsed >= self.current_interval) 0 else self.current_interval - @as(u32, @intCast(elapsed));
            min_wait = @min(min_wait, remaining);
        }

        if (self.config.heartbeat_s > 0) {
            const elapsed: u64 = @intCast(now - self.last_heartbeat);
            const remaining = if (elapsed >= self.config.heartbeat_s) 0 else self.config.heartbeat_s - @as(u32, @intCast(elapsed));
            min_wait = @min(min_wait, remaining);
        }

        if (min_wait > 0 and min_wait < std.math.maxInt(u64)) {
            std.Thread.sleep(min_wait * std.time.ns_per_s);
        }
    }

    /// Returns true if we've hit the max run limit.
    pub fn isComplete(self: *const Scheduler) bool {
        if (self.config.max_runs == 0) return false;
        return self.run_count >= self.config.max_runs;
    }
};

/// Parse cron-related CLI arguments. Call after standard config parsing.
pub fn parseCronArgs(args_iter: anytype) CronConfig {
    var config = CronConfig{};

    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--cron-interval")) {
            if (args_iter.next()) |val| {
                config.interval_s = std.fmt.parseInt(u32, val, 10) catch 0;
            }
        } else if (std.mem.eql(u8, arg, "--cron-prompt")) {
            if (args_iter.next()) |val| {
                config.prompt = val;
            }
        } else if (std.mem.eql(u8, arg, "--heartbeat")) {
            if (args_iter.next()) |val| {
                config.heartbeat_s = std.fmt.parseInt(u32, val, 10) catch 0;
            }
        } else if (std.mem.eql(u8, arg, "--cron-max-runs")) {
            if (args_iter.next()) |val| {
                config.max_runs = std.fmt.parseInt(u32, val, 10) catch 0;
            }
        }
    }

    return config;
}

// --- Tests ---

test "scheduler init" {
    const config = CronConfig{ .interval_s = 60, .heartbeat_s = 10 };
    const sched = Scheduler.init(config);
    try std.testing.expect(sched.isActive());
    try std.testing.expect(!sched.isComplete());
    try std.testing.expectEqual(@as(u32, 0), sched.run_count);
}

test "scheduler disabled" {
    const config = CronConfig{};
    const sched = Scheduler.init(config);
    try std.testing.expect(!sched.isActive());
}

test "shouldRunAgent respects max_runs" {
    const config = CronConfig{ .interval_s = 1, .max_runs = 2 };
    var sched = Scheduler.init(config);
    // Simulate time passing by setting last_cron in the past
    sched.last_cron = std.time.timestamp() - 2;
    try std.testing.expect(sched.shouldRunAgent());
    try std.testing.expectEqual(@as(u32, 1), sched.run_count);

    sched.last_cron = std.time.timestamp() - 2;
    try std.testing.expect(sched.shouldRunAgent());
    try std.testing.expectEqual(@as(u32, 2), sched.run_count);

    // Should not run again — hit max
    sched.last_cron = std.time.timestamp() - 2;
    try std.testing.expect(!sched.shouldRunAgent());
    try std.testing.expect(sched.isComplete());
}

test "shouldHeartbeat timing" {
    const config = CronConfig{ .heartbeat_s = 1 };
    var sched = Scheduler.init(config);
    // Just initialized — shouldn't fire yet
    try std.testing.expect(!sched.shouldHeartbeat());

    // Simulate time passing
    sched.last_heartbeat = std.time.timestamp() - 2;
    try std.testing.expect(sched.shouldHeartbeat());
}

test "getCronPrompt returns configured prompt" {
    const config = CronConfig{ .prompt = "collect sensor data" };
    const sched = Scheduler.init(config);
    try std.testing.expectEqualStrings("collect sensor data", sched.getCronPrompt());
}

test "adaptive backoff doubles interval" {
    const config = CronConfig{ .interval_s = 60 };
    var sched = Scheduler.init(config);
    try std.testing.expectEqual(@as(u32, 60), sched.current_interval);
    sched.backoff();
    try std.testing.expectEqual(@as(u32, 120), sched.current_interval);
    sched.backoff();
    try std.testing.expectEqual(@as(u32, 240), sched.current_interval);
}

test "adaptive backoff caps at max_interval" {
    const config = CronConfig{ .interval_s = 60 };
    var sched = Scheduler.init(config);
    // max_interval = min(60*16, 3600) = 960
    try std.testing.expectEqual(@as(u32, 960), sched.max_interval);
    // Backoff until capped
    var i: u32 = 0;
    while (i < 10) : (i += 1) sched.backoff();
    try std.testing.expectEqual(@as(u32, 960), sched.current_interval);
}

test "adaptive backoff resetBackoff restores min" {
    const config = CronConfig{ .interval_s = 60 };
    var sched = Scheduler.init(config);
    sched.backoff();
    sched.backoff();
    try std.testing.expect(sched.current_interval > 60);
    sched.resetBackoff();
    try std.testing.expectEqual(@as(u32, 60), sched.current_interval);
    try std.testing.expectEqual(@as(u32, 0), sched.idle_ticks);
}

test "backoff integration with shouldRunAgent" {
    const config = CronConfig{ .interval_s = 1 };
    var sched = Scheduler.init(config);
    // Backoff to 2s
    sched.backoff();
    try std.testing.expectEqual(@as(u32, 2), sched.current_interval);

    // Set last_cron 1.5s in the past — should NOT fire (interval is now 2s)
    sched.last_cron = std.time.timestamp() - 1;
    try std.testing.expect(!sched.shouldRunAgent());

    // Set last_cron 3s in the past — should fire (elapsed > 2s interval)
    sched.last_cron = std.time.timestamp() - 3;
    try std.testing.expect(sched.shouldRunAgent());

    // Reset backoff, set last_cron 1.5s ago — should fire again (interval back to 1s)
    sched.resetBackoff();
    sched.last_cron = std.time.timestamp() - 2;
    try std.testing.expect(sched.shouldRunAgent());
}

test "adaptive backoff max capped at 1 hour" {
    const config = CronConfig{ .interval_s = 300 }; // 5 min
    const sched = Scheduler.init(config);
    // 300*16 = 4800 > 3600, so max should be 3600
    try std.testing.expectEqual(@as(u32, 3600), sched.max_interval);
}
