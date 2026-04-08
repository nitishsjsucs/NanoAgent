//! Shared API response parsing for both HTTP (api.zig) and BLE (api_ble.zig) paths.
//!
//! Extracted to avoid duplicating ~170 lines of JSON parsing logic.
//! These functions only depend on std, types.zig, and json.zig — no std.http.

const std = @import("std");
const types = @import("types.zig");
const json = @import("json.zig");

pub const ParseError = error{
    InvalidResponse,
    OutOfMemory,
};

pub fn parseClaudeResponse(allocator: std.mem.Allocator, body: []const u8) !types.ApiResponse {
    const id = json.extractString(body, "id") orelse return ParseError.InvalidResponse;
    const stop_str = json.extractString(body, "stop_reason") orelse "unknown";
    const stop_reason = parseStopReason(stop_str);

    const usage_json = json.extractObject(body, "usage") orelse "{}";
    const input_tokens = json.extractInt(usage_json, "input_tokens") orelse 0;
    const output_tokens = json.extractInt(usage_json, "output_tokens") orelse 0;

    const content_json = json.extractArray(body, "content") orelse return ParseError.InvalidResponse;
    const blocks = try parseContentBlocks(allocator, content_json);

    return .{
        .id = try allocator.dupe(u8, id),
        .stop_reason = stop_reason,
        .content = blocks,
        .input_tokens = input_tokens,
        .output_tokens = output_tokens,
    };
}

pub fn parseOpenAiResponse(allocator: std.mem.Allocator, body: []const u8) !types.ApiResponse {
    const id = json.extractString(body, "id") orelse "";
    const choices = json.extractArray(body, "choices") orelse return ParseError.InvalidResponse;

    const finish = json.extractString(choices, "finish_reason") orelse "stop";
    const stop_reason: types.StopReason = if (std.mem.eql(u8, finish, "stop"))
        .end_turn
    else if (std.mem.eql(u8, finish, "tool_calls"))
        .tool_use
    else if (std.mem.eql(u8, finish, "length"))
        .max_tokens
    else
        .unknown;

    const message = json.extractObject(choices, "message") orelse return ParseError.InvalidResponse;

    var blocks: std.ArrayList(types.ContentBlock) = .{};

    if (json.extractString(message, "content")) |text| {
        if (text.len > 0) {
            try blocks.append(allocator, .{
                .type = .text,
                .text = try allocator.dupe(u8, text),
            });
        }
    }

    if (json.extractArray(message, "tool_calls")) |tool_calls_json| {
        try parseOpenAiToolCalls(allocator, tool_calls_json, &blocks);
    }

    const usage = json.extractObject(body, "usage") orelse "{}";

    return .{
        .id = try allocator.dupe(u8, id),
        .stop_reason = stop_reason,
        .content = try blocks.toOwnedSlice(allocator),
        .input_tokens = json.extractInt(usage, "prompt_tokens") orelse 0,
        .output_tokens = json.extractInt(usage, "completion_tokens") orelse 0,
    };
}

fn parseOpenAiToolCalls(allocator: std.mem.Allocator, tool_calls_json: []const u8, blocks: *std.ArrayList(types.ContentBlock)) !void {
    var pos: usize = 0;
    while (pos < tool_calls_json.len) : (pos += 1) {
        if (tool_calls_json[pos] != '{') continue;

        var depth: u32 = 0;
        var in_string = false;
        var end = pos;
        while (end < tool_calls_json.len) : (end += 1) {
            if (tool_calls_json[end] == '\\' and in_string) {
                end += 1;
                continue;
            }
            if (tool_calls_json[end] == '"') in_string = !in_string;
            if (!in_string) {
                if (tool_calls_json[end] == '{') depth += 1;
                if (tool_calls_json[end] == '}') {
                    depth -= 1;
                    if (depth == 0) break;
                }
            }
        }

        const obj = tool_calls_json[pos .. end + 1];
        const tc_id = json.extractString(obj, "id") orelse "";
        const func = json.extractObject(obj, "function") orelse {
            pos = end;
            continue;
        };
        const name = json.extractString(func, "name") orelse "";
        const arguments = json.extractString(func, "arguments") orelse "{}";

        try blocks.append(allocator, .{
            .type = .tool_use,
            .tool_use = .{
                .id = try allocator.dupe(u8, tc_id),
                .name = try allocator.dupe(u8, name),
                .input_raw = try allocator.dupe(u8, arguments),
            },
        });

        pos = end;
    }
}

pub fn parseContentBlocks(allocator: std.mem.Allocator, content_json: []const u8) ![]types.ContentBlock {
    var blocks: std.ArrayList(types.ContentBlock) = .{};

    var pos: usize = 0;
    while (pos < content_json.len) : (pos += 1) {
        if (content_json[pos] != '{') continue;

        var depth: u32 = 0;
        var in_string = false;
        var end = pos;
        while (end < content_json.len) : (end += 1) {
            if (content_json[end] == '\\' and in_string) {
                end += 1;
                continue;
            }
            if (content_json[end] == '"') in_string = !in_string;
            if (!in_string) {
                if (content_json[end] == '{') depth += 1;
                if (content_json[end] == '}') {
                    depth -= 1;
                    if (depth == 0) break;
                }
            }
        }

        const obj = content_json[pos .. end + 1];
        const block_type = json.extractString(obj, "type") orelse {
            pos = end;
            continue;
        };

        if (std.mem.eql(u8, block_type, "text")) {
            try blocks.append(allocator, .{
                .type = .text,
                .text = try allocator.dupe(u8, json.extractString(obj, "text") orelse ""),
            });
        } else if (std.mem.eql(u8, block_type, "tool_use")) {
            try blocks.append(allocator, .{
                .type = .tool_use,
                .tool_use = .{
                    .id = try allocator.dupe(u8, json.extractString(obj, "id") orelse ""),
                    .name = try allocator.dupe(u8, json.extractString(obj, "name") orelse ""),
                    .input_raw = try allocator.dupe(u8, json.extractObject(obj, "input") orelse "{}"),
                },
            });
        }

        pos = end;
    }

    return blocks.toOwnedSlice(allocator);
}

pub fn parseStopReason(s: []const u8) types.StopReason {
    if (std.mem.eql(u8, s, "end_turn")) return .end_turn;
    if (std.mem.eql(u8, s, "tool_use")) return .tool_use;
    if (std.mem.eql(u8, s, "max_tokens")) return .max_tokens;
    return .unknown;
}

// --- Tests ---

test "parseStopReason" {
    try std.testing.expectEqual(types.StopReason.end_turn, parseStopReason("end_turn"));
    try std.testing.expectEqual(types.StopReason.tool_use, parseStopReason("tool_use"));
    try std.testing.expectEqual(types.StopReason.max_tokens, parseStopReason("max_tokens"));
    try std.testing.expectEqual(types.StopReason.unknown, parseStopReason("something_else"));
}
