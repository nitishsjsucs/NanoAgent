//! Fault Log — boot breadcrumbs for Lite builds.
//!
//! Persists crash/reset information so the LLM can diagnose on reboot.
//! On real hardware: writes to a known flash address.
//! On Linux: writes to .kNanoAgent/fault_log file.
//!
//! The fault record is read on boot and included in the first
//! heartbeat prompt so the LLM has context about the last session.

const std = @import("std");
const build_options = @import("build_options");

const FAULT_MAGIC: u32 = 0xFA17_B00D;
const FAULT_PATH = ".kNanoAgent/fault_log";
const has_fs = !build_options.embedded or @hasDecl(std.fs, "cwd");

pub const ResetReason = enum(u8) {
    clean_shutdown = 0,
    watchdog = 1,
    panic = 2,
    power_loss = 3,
    ota_reboot = 4,
    user_reset = 5,
    unknown = 255,
};

pub const FaultRecord = struct {
    magic: u32 = FAULT_MAGIC,
    timestamp: u32 = 0,
    reason: ResetReason = .unknown,
    reset_count: u16 = 0,
    /// Last known program counter (for crash diagnosis)
    last_pc: u32 = 0,
    /// Last known link register
    last_lr: u32 = 0,

    /// Format as JSON for inclusion in LLM prompt.
    pub fn toJson(self: *const FaultRecord, buf: []u8) []const u8 {
        const reason_str: []const u8 = switch (self.reason) {
            .clean_shutdown => "clean_shutdown",
            .watchdog => "watchdog",
            .panic => "panic",
            .power_loss => "power_loss",
            .ota_reboot => "ota_reboot",
            .user_reset => "user_reset",
            .unknown => "unknown",
        };
        const result = std.fmt.bufPrint(buf,
            \\{{"last_reset":"{s}","timestamp":{d},"reset_count":{d},"pc":"0x{x:0>8}","lr":"0x{x:0>8}"}}
        , .{
            reason_str,
            self.timestamp,
            self.reset_count,
            self.last_pc,
            self.last_lr,
        }) catch return "{}";
        return result;
    }
};

/// Write a fault record to persistent storage.
/// On freestanding targets without std.fs, this is a no-op (use flash writes instead).
pub fn write(record: FaultRecord) void {
    if (!has_fs) return; // On bare-metal, flash write would go here
    std.fs.cwd().makePath(".kNanoAgent") catch return;
    const file = std.fs.cwd().createFile(FAULT_PATH, .{}) catch return;
    defer file.close();
    const bytes = std.mem.asBytes(&record);
    file.writeAll(bytes) catch {};
}

/// Read the last fault record from persistent storage.
/// Returns null if no valid record exists or on freestanding targets.
pub fn read() ?FaultRecord {
    if (!has_fs) return null; // On bare-metal, flash read would go here
    const file = std.fs.cwd().openFile(FAULT_PATH, .{}) catch return null;
    defer file.close();
    var record: FaultRecord = undefined;
    const bytes = std.mem.asBytes(&record);
    const n = file.readAll(bytes) catch return null;
    if (n < @sizeOf(FaultRecord)) return null;
    if (record.magic != FAULT_MAGIC) return null;
    return record;
}

/// Clear the fault log (after LLM has processed it).
pub fn clear() void {
    if (!has_fs) return;
    std.fs.cwd().deleteFile(FAULT_PATH) catch {};
}

// ============================================================
// Tests
// ============================================================

test "fault log write and read round-trip" {
    const record = FaultRecord{
        .timestamp = 1709337600,
        .reason = .watchdog,
        .reset_count = 3,
        .last_pc = 0x0800_1234,
        .last_lr = 0x0800_5678,
    };
    write(record);
    defer clear();

    const loaded = read().?;
    try std.testing.expectEqual(FAULT_MAGIC, loaded.magic);
    try std.testing.expectEqual(@as(u32, 1709337600), loaded.timestamp);
    try std.testing.expectEqual(ResetReason.watchdog, loaded.reason);
    try std.testing.expectEqual(@as(u16, 3), loaded.reset_count);
    try std.testing.expectEqual(@as(u32, 0x0800_1234), loaded.last_pc);
    try std.testing.expectEqual(@as(u32, 0x0800_5678), loaded.last_lr);
}

test "fault log read returns null when no file" {
    clear(); // ensure clean state
    try std.testing.expect(read() == null);
}

test "fault log toJson" {
    const record = FaultRecord{
        .timestamp = 1000,
        .reason = .panic,
        .reset_count = 1,
        .last_pc = 0x1234,
        .last_lr = 0x5678,
    };
    var buf: [256]u8 = undefined;
    const json = record.toJson(&buf);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"panic\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"timestamp\":1000") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"reset_count\":1") != null);
}

test "fault log clear removes file" {
    write(.{ .timestamp = 1, .reason = .clean_shutdown });
    try std.testing.expect(read() != null);
    clear();
    try std.testing.expect(read() == null);
}

test "fault log all reset reasons" {
    const reasons = [_]ResetReason{ .clean_shutdown, .watchdog, .panic, .power_loss, .ota_reboot, .user_reset, .unknown };
    for (reasons) |reason| {
        const record = FaultRecord{ .reason = reason };
        var buf: [256]u8 = undefined;
        const json = record.toJson(&buf);
        try std.testing.expect(json.len > 2); // not just "{}"
    }
}
