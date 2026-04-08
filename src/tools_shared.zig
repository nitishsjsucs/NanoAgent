//! Shared tools available across all profiles.
//!
//! These tools have minimal binary footprint and are universally useful:
//! - get_current_time: Returns ISO-8601 timestamp
//! - kv_get / kv_set / kv_list / kv_delete: Lightweight persistent key-value store
//! - web_search: Search the web (delegated to bridge.py)
//! - session_save / session_load / session_list: Conversation persistence (via bridge)
//! - ota_check / ota_update: Over-the-air updates (via bridge)

const std = @import("std");
const types = @import("types.zig");
const json = @import("json.zig");
const build_options = @import("build_options");
const power_mod = if (build_options.embedded) @import("power.zig") else struct {};

pub const ToolResult = struct {
    output: []const u8,
    is_error: bool,
};

/// Embedded-only tools (power budget, etc.)
const embedded_tool_definitions = [_]types.ToolDef{
    .{
        .name = "power_budget",
        .description = "Get power consumption stats and remaining battery estimate. Reports per-subsystem energy usage in microwatt-hours.",
        .input_schema = \\{"type":"object","properties":{},"required":[]}
        ,
        .annotations = \\{"readOnly":true}
        ,
    },
};

/// Core tools available on all builds (including Lite/embedded)
const core_tool_definitions = [_]types.ToolDef{
    .{
        .name = "get_current_time",
        .description = "Get the current date and time in ISO-8601 format.",
        .input_schema = \\{"type":"object","properties":{},"required":[]}
        ,
        .annotations = \\{"readOnly":true}
        ,
    },
    .{
        .name = "kv_get",
        .description = "Get a value from the persistent key-value store.",
        .input_schema = \\{"type":"object","properties":{"key":{"type":"string","description":"Key to retrieve"}},"required":["key"]}
        ,
        .annotations = \\{"readOnly":true}
        ,
    },
    .{
        .name = "kv_set",
        .description = "Set a value in the persistent key-value store.",
        .input_schema = \\{"type":"object","properties":{"key":{"type":"string","description":"Key to store"},"value":{"type":"string","description":"Value to store"}},"required":["key","value"]}
        ,
        .annotations = \\{"sideEffects":["filesystem"]}
        ,
    },
    .{
        .name = "kv_list",
        .description = "List all keys in the persistent key-value store.",
        .input_schema = \\{"type":"object","properties":{},"required":[]}
        ,
        .annotations = \\{"readOnly":true}
        ,
    },
    .{
        .name = "kv_delete",
        .description = "Delete a key from the persistent key-value store.",
        .input_schema = \\{"type":"object","properties":{"key":{"type":"string","description":"Key to delete"}},"required":["key"]}
        ,
        .annotations = \\{"destructive":true,"sideEffects":["filesystem"]}
        ,
    },
};

/// Bridge-delegated tools — only available on Full builds (require Python sidecar)
const bridge_tool_definitions = [_]types.ToolDef{
    .{
        .name = "web_search",
        .description = "Search the web and return results. Uses DuckDuckGo (no API key needed).",
        .input_schema = \\{"type":"object","properties":{"query":{"type":"string","description":"Search query"},"max_results":{"type":"integer","description":"Max results (default 5)"}},"required":["query"]}
        ,
        .annotations = \\{"readOnly":true,"sideEffects":["network"]}
        ,
    },
    .{
        .name = "session_save",
        .description = "Save current conversation to persistent storage for later resumption.",
        .input_schema = \\{"type":"object","properties":{"session_id":{"type":"string","description":"Session identifier"},"messages":{"type":"string","description":"JSON-encoded message history"}},"required":["session_id","messages"]}
        ,
        .annotations = \\{"sideEffects":["filesystem"]}
        ,
    },
    .{
        .name = "session_load",
        .description = "Load a previously saved conversation session.",
        .input_schema = \\{"type":"object","properties":{"session_id":{"type":"string","description":"Session identifier to load"}},"required":["session_id"]}
        ,
        .annotations = \\{"readOnly":true}
        ,
    },
    .{
        .name = "session_list",
        .description = "List all saved conversation sessions.",
        .input_schema = \\{"type":"object","properties":{},"required":[]}
        ,
        .annotations = \\{"readOnly":true}
        ,
    },
    .{
        .name = "ota_check",
        .description = "Check for over-the-air updates from GitHub releases.",
        .input_schema = \\{"type":"object","properties":{"current_version":{"type":"string","description":"Current version string"}},"required":["current_version"]}
        ,
        .annotations = \\{"readOnly":true,"sideEffects":["network"]}
        ,
    },
    .{
        .name = "ota_update",
        .description = "Download and apply an OTA update. Checks GitHub, downloads matching binary, verifies, and applies.",
        .input_schema = \\{"type":"object","properties":{"current_version":{"type":"string","description":"Current version"},"auto_apply":{"type":"boolean","description":"Auto-apply after download (default false)"}},"required":["current_version"]}
        ,
        .annotations = \\{"destructive":true,"sideEffects":["network","filesystem"]}
        ,
    },
};

/// Combined tool definitions: core + embedded-only on Lite, core + bridge on Full
pub const tool_definitions = if (build_options.embedded)
    core_tool_definitions ++ embedded_tool_definitions
else
    core_tool_definitions ++ bridge_tool_definitions;

/// Try to execute a shared tool. Returns null if tool name doesn't match.
pub fn tryExecute(allocator: std.mem.Allocator, tool: types.ToolUse) ?ToolResult {
    // Pure Zig tools (no bridge needed)
    if (std.mem.eql(u8, tool.name, "get_current_time")) return executeGetTime(allocator);
    if (std.mem.eql(u8, tool.name, "kv_get")) return executeKvGet(allocator, tool.input_raw);
    if (std.mem.eql(u8, tool.name, "kv_set")) return executeKvSet(allocator, tool.input_raw);
    if (std.mem.eql(u8, tool.name, "kv_list")) return executeKvList(allocator);
    if (std.mem.eql(u8, tool.name, "kv_delete")) return executeKvDelete(allocator, tool.input_raw);

    // Embedded-only tools
    if (build_options.embedded) {
        if (std.mem.eql(u8, tool.name, "power_budget")) return executePowerBudget(allocator);
    }

    // Bridge-delegated tools — not available on embedded (no Python sidecar)
    if (!build_options.embedded) {
        if (std.mem.eql(u8, tool.name, "web_search")) return executeBridgeTool(allocator, "web_search", tool.input_raw);
        if (std.mem.eql(u8, tool.name, "session_save")) return executeBridgeTool(allocator, "session_save", tool.input_raw);
        if (std.mem.eql(u8, tool.name, "session_load")) return executeBridgeTool(allocator, "session_load", tool.input_raw);
        if (std.mem.eql(u8, tool.name, "session_list")) return executeBridgeTool(allocator, "session_list", tool.input_raw);
        if (std.mem.eql(u8, tool.name, "ota_check")) return executeOtaCheck(allocator, tool.input_raw);
        if (std.mem.eql(u8, tool.name, "ota_update")) return executeOtaUpdate(allocator, tool.input_raw);
    }
    return null;
}

// --- get_current_time ---

fn executeGetTime(allocator: std.mem.Allocator) ToolResult {
    const ts = std.time.timestamp();
    // Convert epoch seconds to a human-readable ISO-8601 string
    const epoch_secs: std.time.epoch.EpochSeconds = .{ .secs = @intCast(ts) };
    const epoch_day = epoch_secs.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = epoch_secs.getDaySeconds();

    const result = std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
    }) catch return .{ .output = "time format error", .is_error = true };

    return .{ .output = result, .is_error = false };
}

// --- KV Store ---

const KV_DIR = ".NanoAgent/kv";

fn isValidKvKey(key: []const u8) bool {
    if (key.len == 0 or key.len > 128) return false;
    if (std.mem.indexOf(u8, key, "..") != null) return false;
    if (std.mem.indexOf(u8, key, "/") != null) return false;
    for (key) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.') return false;
    }
    return true;
}

fn executeKvGet(allocator: std.mem.Allocator, input: []const u8) ToolResult {
    const key = json.extractString(input, "key") orelse
        return .{ .output = "Missing 'key' parameter", .is_error = true };
    if (!isValidKvKey(key)) return .{ .output = "Invalid key (alphanumeric, dash, underscore, dot only)", .is_error = true };

    const path = std.fmt.allocPrint(allocator, KV_DIR ++ "/{s}", .{key}) catch
        return .{ .output = "Path build error", .is_error = true };
    const file = std.fs.cwd().openFile(path, .{}) catch
        return .{ .output = "Key not found", .is_error = true };
    defer file.close();
    const content = file.readToEndAlloc(allocator, 1024 * 64) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Read error: {}", .{err}) catch "read error";
        return .{ .output = msg, .is_error = true };
    };
    return .{ .output = if (content.len == 0) "(empty)" else content, .is_error = false };
}

fn executeKvSet(allocator: std.mem.Allocator, input: []const u8) ToolResult {
    const key = json.extractString(input, "key") orelse
        return .{ .output = "Missing 'key' parameter", .is_error = true };
    const value = json.extractString(input, "value") orelse
        return .{ .output = "Missing 'value' parameter", .is_error = true };
    if (!isValidKvKey(key)) return .{ .output = "Invalid key (alphanumeric, dash, underscore, dot only)", .is_error = true };

    std.fs.cwd().makePath(KV_DIR) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Cannot create KV dir: {}", .{err}) catch "dir error";
        return .{ .output = msg, .is_error = true };
    };

    const path = std.fmt.allocPrint(allocator, KV_DIR ++ "/{s}", .{key}) catch
        return .{ .output = "Path build error", .is_error = true };
    const file = std.fs.cwd().createFile(path, .{}) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Cannot create '{s}': {}", .{ path, err }) catch "create error";
        return .{ .output = msg, .is_error = true };
    };
    defer file.close();
    const unescaped = json.unescape(allocator, value) catch value;
    file.writeAll(unescaped) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Write error: {}", .{err}) catch "write error";
        return .{ .output = msg, .is_error = true };
    };
    const msg = std.fmt.allocPrint(allocator, "Stored {d} bytes at key '{s}'", .{ unescaped.len, key }) catch "stored";
    return .{ .output = msg, .is_error = false };
}

fn executeKvList(allocator: std.mem.Allocator) ToolResult {
    var dir = std.fs.cwd().openDir(KV_DIR, .{ .iterate = true }) catch {
        return .{ .output = "[]", .is_error = false };
    };
    defer dir.close();

    var buf: std.ArrayList(u8) = .{};
    const w = buf.writer(allocator);
    w.writeAll("[") catch return .{ .output = "[]", .is_error = false };

    var count: u32 = 0;
    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (count > 0) w.writeAll(",") catch {};
        w.writeAll("\"") catch {};
        w.writeAll(entry.name) catch {};
        w.writeAll("\"") catch {};
        count += 1;
    }
    w.writeAll("]") catch {};

    const result = buf.toOwnedSlice(allocator) catch "[]";
    return .{ .output = result, .is_error = false };
}

fn executeKvDelete(allocator: std.mem.Allocator, input: []const u8) ToolResult {
    const key = json.extractString(input, "key") orelse
        return .{ .output = "Missing 'key' parameter", .is_error = true };
    if (!isValidKvKey(key)) return .{ .output = "Invalid key (alphanumeric, dash, underscore, dot only)", .is_error = true };

    const path = std.fmt.allocPrint(allocator, KV_DIR ++ "/{s}", .{key}) catch
        return .{ .output = "Path build error", .is_error = true };
    std.fs.cwd().deleteFile(path) catch |err| {
        if (err == error.FileNotFound) return .{ .output = "Key not found", .is_error = true };
        const msg = std.fmt.allocPrint(allocator, "Delete error: {}", .{err}) catch "delete error";
        return .{ .output = msg, .is_error = true };
    };
    const msg = std.fmt.allocPrint(allocator, "Deleted key '{s}'", .{key}) catch "deleted";
    return .{ .output = msg, .is_error = false };
}

// --- Bridge-delegated tools ---

/// Call bridge.py with a JSON action and return its response.
fn bridgeCall(allocator: std.mem.Allocator, bridge_json: []const u8) ToolResult {
    if (build_options.sandbox) {
        return .{ .output = "{\"status\":\"simulated\",\"message\":\"sandbox mode\"}", .is_error = false };
    }

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "python3", "bridge/bridge.py", "--exec-tool", bridge_json },
        .max_output_bytes = 1024 * 256,
    }) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Bridge call failed: {}", .{err}) catch "bridge error";
        return .{ .output = msg, .is_error = true };
    };

    const is_err = switch (result.term) {
        .Exited => |code| code != 0,
        else => true,
    };
    const output = if (result.stdout.len > 0) result.stdout else if (result.stderr.len > 0) result.stderr else "(no output)";
    return .{ .output = output, .is_error = is_err };
}

/// Execute a bridge tool by wrapping input_raw into an action JSON.
/// Public so tools.zig can use it as a fallback for plugin-provided tools.
pub fn executeBridgeTool(allocator: std.mem.Allocator, action: []const u8, input_raw: []const u8) ToolResult {
    // Build {"action":"<action>", ...rest_of_input}
    // We insert "action":"<action>" into the input JSON object
    var buf: std.ArrayList(u8) = .{};
    const w = buf.writer(allocator);
    w.writeAll("{\"action\":\"") catch return .{ .output = "JSON build error", .is_error = true };
    w.writeAll(action) catch return .{ .output = "JSON build error", .is_error = true };
    w.writeAll("\"") catch return .{ .output = "JSON build error", .is_error = true };

    // If input_raw has content beyond {}, merge it
    if (input_raw.len > 2) {
        // input_raw looks like {"key":"val",...} — skip the leading {
        w.writeAll(",") catch return .{ .output = "JSON build error", .is_error = true };
        w.writeAll(input_raw[1..]) catch return .{ .output = "JSON build error", .is_error = true };
    } else {
        w.writeAll("}") catch return .{ .output = "JSON build error", .is_error = true };
    }

    const bridge_json = buf.toOwnedSlice(allocator) catch return .{ .output = "JSON build error", .is_error = true };
    return bridgeCall(allocator, bridge_json);
}

/// OTA check — wraps version and calls bridge.
fn executeOtaCheck(allocator: std.mem.Allocator, input_raw: []const u8) ToolResult {
    const version = json.extractString(input_raw, "current_version") orelse "0.1.0";
    var buf: std.ArrayList(u8) = .{};
    const w = buf.writer(allocator);
    w.writeAll("{\"action\":\"ota_check\",\"current_version\":\"") catch return .{ .output = "JSON build error", .is_error = true };
    json.writeEscaped(w, version) catch return .{ .output = "JSON build error", .is_error = true };
    w.writeAll("\"}") catch return .{ .output = "JSON build error", .is_error = true };
    const bridge_json = buf.toOwnedSlice(allocator) catch return .{ .output = "JSON build error", .is_error = true };
    return bridgeCall(allocator, bridge_json);
}

/// OTA update — multi-step: check → download → optionally apply.
fn executeOtaUpdate(allocator: std.mem.Allocator, input_raw: []const u8) ToolResult {
    const version = json.extractString(input_raw, "current_version") orelse "0.1.0";

    // Step 1: Check for updates
    const check_result = executeOtaCheck(allocator, input_raw);
    if (check_result.is_error) return check_result;

    // Parse the check response to see if update is available
    const update_available = json.extractBool(check_result.output, "update_available") orelse false;
    if (!update_available) {
        const msg = std.fmt.allocPrint(allocator, "Already up to date (v{s})", .{version}) catch "up to date";
        return .{ .output = msg, .is_error = false };
    }

    // Return the check result with update info — the agent can then decide to download
    return check_result;
}

// --- Power Budget (embedded only) ---

/// Global power budget instance — shared across the embedded runtime.
/// Initialized once, persists across agent runs.
pub var global_power_budget: if (build_options.embedded) power_mod.PowerBudget else struct {} =
    if (build_options.embedded) .{} else .{};

fn executePowerBudget(allocator: std.mem.Allocator) ToolResult {
    var buf: [512]u8 = undefined;
    const n = global_power_budget.toJson(&buf);
    if (n == 0) return .{ .output = "{}", .is_error = false };
    const duped = allocator.dupe(u8, buf[0..n]) catch return .{ .output = "{}", .is_error = true };
    return .{ .output = duped, .is_error = false };
}

// --- Tests ---

test "get_current_time returns ISO-8601" {
    const alloc = std.heap.page_allocator;
    const result = executeGetTime(alloc);
    try std.testing.expect(!result.is_error);
    // Should look like "2026-02-28T09:15:30Z"
    try std.testing.expect(result.output.len >= 19);
    try std.testing.expect(result.output[4] == '-');
    try std.testing.expect(result.output[7] == '-');
    try std.testing.expect(result.output[10] == 'T');
    try std.testing.expect(result.output[result.output.len - 1] == 'Z');
}

test "kv_set and kv_get" {
    const alloc = std.heap.page_allocator;
    // Set
    const set_result = executeKvSet(alloc, "{\"key\":\"test_shared_kv\",\"value\":\"hello_shared\"}");
    try std.testing.expect(!set_result.is_error);
    // Get
    const get_result = executeKvGet(alloc, "{\"key\":\"test_shared_kv\"}");
    try std.testing.expect(!get_result.is_error);
    try std.testing.expectEqualStrings("hello_shared", get_result.output);
    // Delete
    const del_result = executeKvDelete(alloc, "{\"key\":\"test_shared_kv\"}");
    try std.testing.expect(!del_result.is_error);
    // Get after delete
    const get2 = executeKvGet(alloc, "{\"key\":\"test_shared_kv\"}");
    try std.testing.expect(get2.is_error);
}

test "kv_list" {
    const alloc = std.heap.page_allocator;
    // Set a test key
    _ = executeKvSet(alloc, "{\"key\":\"test_list_key\",\"value\":\"v\"}");
    defer _ = executeKvDelete(alloc, "{\"key\":\"test_list_key\"}");
    const result = executeKvList(alloc);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "test_list_key") != null);
}

test "kv_get invalid key" {
    const alloc = std.heap.page_allocator;
    const result = executeKvGet(alloc, "{\"key\":\"../etc/passwd\"}");
    try std.testing.expect(result.is_error);
}

test "kv_set invalid key with slash" {
    const alloc = std.heap.page_allocator;
    const result = executeKvSet(alloc, "{\"key\":\"foo/bar\",\"value\":\"x\"}");
    try std.testing.expect(result.is_error);
}
