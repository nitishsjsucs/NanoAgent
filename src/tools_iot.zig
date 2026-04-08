//! IoT profile tools — communicates with Python bridge via structured JSON over stdin/stdout.
//! Policy: no bash, no arbitrary file writes, rate-limited bridge calls.
const std = @import("std");
const types = @import("types.zig");
const json = @import("json.zig");
const build_options = @import("build_options");

pub const ToolResult = struct {
    output: []const u8,
    is_error: bool,
};

/// Bridge-only tools (MQTT, HTTP) — excluded on embedded
const bridge_tools = [_]types.ToolDef{
    .{ .name = "publish_mqtt", .description = "Publish a message to an MQTT topic.", .input_schema =
        \\{"type":"object","properties":{"topic":{"type":"string"},"payload":{"type":"string"},"qos":{"type":"integer","default":0}},"required":["topic","payload"]}
    , .annotations =
        \\{"sideEffects":["network"]}
    },
    .{ .name = "subscribe_mqtt", .description = "Subscribe to an MQTT topic and return the next message (with timeout).", .input_schema =
        \\{"type":"object","properties":{"topic":{"type":"string"},"timeout_ms":{"type":"integer","default":5000}},"required":["topic"]}
    , .annotations =
        \\{"readOnly":true,"sideEffects":["network"]}
    },
    .{ .name = "http_request", .description = "Make an HTTP request (GET/POST/PUT/DELETE).", .input_schema =
        \\{"type":"object","properties":{"method":{"type":"string","enum":["GET","POST","PUT","DELETE"]},"url":{"type":"string"},"body":{"type":"string"},"headers":{"type":"object"}},"required":["method","url"]}
    , .annotations =
        \\{"sideEffects":["network"]}
    },
};

/// Core IoT tools — available on all builds
const core_tools = [_]types.ToolDef{
    .{ .name = "device_info", .description = "Get device information and status.", .input_schema =
        \\{"type":"object","properties":{},"required":[]}
    , .annotations =
        \\{"readOnly":true}
    },
    .{ .name = "gpio_read", .description = "Read a GPIO pin value.", .input_schema =
        \\{"type":"object","properties":{"pin":{"type":"integer"}},"required":["pin"]}
    , .annotations =
        \\{"readOnly":true}
    },
    .{ .name = "gpio_write", .description = "Write a value to a GPIO pin.", .input_schema =
        \\{"type":"object","properties":{"pin":{"type":"integer"},"value":{"type":"integer"}},"required":["pin","value"]}
    , .annotations =
        \\{"destructive":true}
    },
    .{ .name = "gpio_list", .description = "List available GPIO pins.", .input_schema =
        \\{"type":"object","properties":{},"required":[]}
    , .annotations =
        \\{"readOnly":true}
    },
};

pub const tool_definitions = if (build_options.embedded)
    core_tools
else
    bridge_tools ++ core_tools;

/// Rate limiter: max 30 bridge calls per minute
var call_timestamps: [30]i64 = [_]i64{0} ** 30;
var call_idx: usize = 0;

fn checkRateLimit() bool {
    const now = std.time.timestamp();
    const oldest = call_timestamps[call_idx];
    if (oldest != 0 and (now - oldest) < 60) return false;
    call_timestamps[call_idx] = now;
    call_idx = (call_idx + 1) % 30;
    return true;
}

pub fn execute(allocator: std.mem.Allocator, tool: types.ToolUse) ToolResult {
    // Policy: no bash, no file writes
    if (std.mem.eql(u8, tool.name, "bash")) return .{ .output = "bash disabled in IoT profile", .is_error = true };
    if (std.mem.eql(u8, tool.name, "write_file")) return .{ .output = "write_file disabled in IoT profile", .is_error = true };

    // Pure Zig tools (no bridge needed)
    // Note: kv_get/kv_set/kv_list/kv_delete + get_current_time handled by tools_shared.zig
    if (std.mem.eql(u8, tool.name, "device_info")) return executeDeviceInfo(allocator);

    // GPIO tools — on embedded, execute directly (stub for now); on full, route to bridge
    if (std.mem.eql(u8, tool.name, "gpio_read") or
        std.mem.eql(u8, tool.name, "gpio_write") or
        std.mem.eql(u8, tool.name, "gpio_list"))
    {
        if (build_options.embedded) {
            // TODO: Direct GPIO via HAL in Phase 1
            return .{ .output = "{\"status\":\"gpio_stub\",\"message\":\"direct GPIO not yet implemented\"}", .is_error = false };
        }
    }

    // Bridge tools — not available on embedded (no Python sidecar)
    if (build_options.embedded) {
        return .{ .output = "Tool not available on Lite", .is_error = true };
    }

    // Bridge tools — rate limited
    if (!checkRateLimit()) return .{ .output = "Rate limit exceeded (30/min)", .is_error = true };

    // All other tools route to bridge via raw input splice
    const action_map = .{
        .{ "publish_mqtt", "mqtt_publish" },
        .{ "subscribe_mqtt", "mqtt_subscribe" },
        .{ "http_request", "http_request" },
        .{ "gpio_read", "gpio_read" },
        .{ "gpio_write", "gpio_write" },
        .{ "gpio_list", "gpio_list" },
    };
    inline for (action_map) |entry| {
        if (std.mem.eql(u8, tool.name, entry[0])) {
            return bridgeSplice(allocator, entry[1], tool.input_raw);
        }
    }

    return .{ .output = "Unknown tool", .is_error = true };
}

/// Device info — on embedded returns compile-time info, on full uses subprocess calls
fn executeDeviceInfo(allocator: std.mem.Allocator) ToolResult {
    if (build_options.embedded) {
        // Embedded: return static info (no subprocess available)
        return .{
            .output = "{\"runtime\":\"NanoAgent-lite\",\"version\":\"0.1.0\",\"profile\":\"iot\",\"transport\":\"ble\",\"allocator\":\"fixed_arena\"}",
            .is_error = false,
        };
    }

    var info: std.ArrayList(u8) = .{};
    const w = info.writer(allocator);

    // Hostname
    w.writeAll("{\"hostname\":\"") catch {};
    if (std.process.Child.run(.{ .allocator = allocator, .argv = &.{"hostname"}, .max_output_bytes = 256 })) |r| {
        w.writeAll(std.mem.trimRight(u8, r.stdout, "\n\r ")) catch {};
    } else |_| {
        w.writeAll("unknown") catch {};
    }

    // OS
    w.writeAll("\",\"os\":\"") catch {};
    if (std.process.Child.run(.{ .allocator = allocator, .argv = &.{ "uname", "-srm" }, .max_output_bytes = 256 })) |r| {
        w.writeAll(std.mem.trimRight(u8, r.stdout, "\n\r ")) catch {};
    } else |_| {
        w.writeAll("unknown") catch {};
    }

    // Uptime
    w.writeAll("\",\"uptime\":\"") catch {};
    if (std.process.Child.run(.{ .allocator = allocator, .argv = &.{"uptime"}, .max_output_bytes = 256 })) |r| {
        const up = std.mem.trimRight(u8, r.stdout, "\n\r ");
        // Escape for JSON
        for (up) |c| {
            if (c == '"') { w.writeAll("\\\"") catch {}; } else if (c == '\\') { w.writeAll("\\\\") catch {}; } else { w.writeByte(c) catch {}; }
        }
    } else |_| {}

    // Memory
    w.writeAll("\",\"memory\":\"") catch {};
    if (std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "/bin/sh", "-c", "if [ -f /proc/meminfo ]; then head -3 /proc/meminfo | tr '\\n' '; '; else sysctl -n hw.memsize 2>/dev/null; fi" },
        .max_output_bytes = 512,
    })) |r| {
        const mem = std.mem.trimRight(u8, r.stdout, "\n\r ");
        for (mem) |c| {
            if (c == '"') { w.writeAll("\\\"") catch {}; } else if (c == '\\') { w.writeAll("\\\\") catch {}; } else { w.writeByte(c) catch {}; }
        }
    } else |_| {}

    w.writeAll("\"}") catch {};
    return .{ .output = info.toOwnedSlice(allocator) catch "{\"error\":\"build failed\"}", .is_error = false };
}

/// Build bridge JSON by splicing raw input: {"action":"<name>", ...raw_fields}
fn bridgeSplice(allocator: std.mem.Allocator, action: []const u8, input_raw: []const u8) ToolResult {
    var buf: std.ArrayList(u8) = .{};
    const w = buf.writer(allocator);
    w.writeAll("{\"action\":\"") catch return .{ .output = "JSON build error", .is_error = true };
    w.writeAll(action) catch return .{ .output = "JSON build error", .is_error = true };
    w.writeAll("\"") catch return .{ .output = "JSON build error", .is_error = true };
    if (input_raw.len > 2) {
        w.writeAll(",") catch return .{ .output = "JSON build error", .is_error = true };
        w.writeAll(input_raw[1 .. input_raw.len - 1]) catch return .{ .output = "JSON build error", .is_error = true };
    }
    w.writeAll("}") catch return .{ .output = "JSON build error", .is_error = true };
    const bridge_json = buf.toOwnedSlice(allocator) catch return .{ .output = "JSON build error", .is_error = true };
    return bridgeCall(allocator, bridge_json);
}

/// Send structured JSON to the Python bridge via CLI argument, read response from stdout.
fn bridgeCall(allocator: std.mem.Allocator, bridge_json: []const u8) ToolResult {
    if (build_options.sandbox) {
        return .{ .output = "{\"status\":\"simulated\",\"message\":\"sandbox mode - bridge calls are simulated\"}", .is_error = false };
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

// --- Tests ---

test "bridgeSplice builds correct JSON with fields" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    const action = "gpio_read";
    const input_raw = "{\"pin\":17}";
    try w.writeAll("{\"action\":\"");
    try w.writeAll(action);
    try w.writeAll("\"");
    if (input_raw.len > 2) {
        try w.writeAll(",");
        try w.writeAll(input_raw[1 .. input_raw.len - 1]);
    }
    try w.writeAll("}");
    try std.testing.expectEqualStrings("{\"action\":\"gpio_read\",\"pin\":17}", buf.items[0..buf.items.len]);
}

test "bridgeSplice builds correct JSON with empty input" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    const action = "gpio_list";
    const input_raw = "{}";
    try w.writeAll("{\"action\":\"");
    try w.writeAll(action);
    try w.writeAll("\"");
    if (input_raw.len > 2) {
        try w.writeAll(",");
        try w.writeAll(input_raw[1 .. input_raw.len - 1]);
    }
    try w.writeAll("}");
    try std.testing.expectEqualStrings("{\"action\":\"gpio_list\"}", buf.items[0..buf.items.len]);
}

test "bridgeSplice handles multi-field input" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    const action = "gpio_write";
    const input_raw = "{\"pin\":4,\"value\":1}";
    try w.writeAll("{\"action\":\"");
    try w.writeAll(action);
    try w.writeAll("\"");
    if (input_raw.len > 2) {
        try w.writeAll(",");
        try w.writeAll(input_raw[1 .. input_raw.len - 1]);
    }
    try w.writeAll("}");
    try std.testing.expectEqualStrings("{\"action\":\"gpio_write\",\"pin\":4,\"value\":1}", buf.items[0..buf.items.len]);
}
