const std = @import("std");
const build_options = @import("build_options");
const types = @import("types.zig");
const api = if (build_options.embedded) @import("api_ble.zig") else @import("api.zig");
const json = @import("json.zig");
const react = @import("react.zig");
const Context = @import("context.zig").Context;

const Color = struct {
    const reset = "\x1b[0m";
    const cyan = "\x1b[36m";
    const yellow = "\x1b[33m";
    const green = "\x1b[32m";
    const red = "\x1b[31m";
    const dim = "\x1b[2m";
    const bold = "\x1b[1m";
    const magenta = "\x1b[35m";
};

pub const Agent = struct {
    allocator: std.mem.Allocator,
    client: api.Client,
    config: types.Config,
    messages: std.ArrayList(types.Message),
    context: Context,
    total_input_tokens: u64,
    total_output_tokens: u64,
    stdout: std.fs.File.DeprecatedWriter,
    loop_hashes: [8][2]u64 = .{
        .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 },
        .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 },
    },
    loop_idx: usize = 0,

    pub fn init(allocator: std.mem.Allocator, config: types.Config) Agent {
        return .{
            .allocator = allocator,
            .client = api.Client.init(allocator, config),
            .config = config,
            .messages = .{},
            .context = Context.init(allocator, config),
            .total_input_tokens = 0,
            .total_output_tokens = 0,
            .stdout = std.fs.File.stdout().deprecatedWriter(),
        };
    }

    pub fn deinit(self: *Agent) void {
        self.client.deinit();
        self.messages.deinit(self.allocator);
    }

    /// Run the ReAct agent loop: think → act → observe, max 10 iterations.
    pub fn run(self: *Agent, prompt: []const u8) !void {
        // Add user message
        const user_content = try self.allocator.alloc(types.ContentBlock, 1);
        user_content[0] = .{
            .type = .text,
            .text = try self.allocator.dupe(u8, prompt),
        };
        try self.messages.append(self.allocator, .{
            .role = .user,
            .content = user_content,
        });

        var iteration: u32 = 0;
        while (iteration < react.MAX_ITERATIONS) : (iteration += 1) {
            // Context window management
            try self.context.truncate(&self.messages);

            // === THINK: Call LLM ===
            try self.stdout.print("\n{s}[think]{s} ", .{ Color.cyan, Color.reset });

            const response = if (self.config.streaming)
                self.client.sendMessagesStreaming(self.messages.items, &printTextDelta) catch |err| {
                    return self.handleApiError(err);
                }
            else
                self.client.sendMessages(self.messages.items) catch |err| {
                    return self.handleApiError(err);
                };

            self.total_input_tokens += response.input_tokens;
            self.total_output_tokens += response.output_tokens;

            // Add assistant response to history
            try self.messages.append(self.allocator, .{
                .role = .assistant,
                .content = response.content,
            });

            // === Classify step ===
            const step = react.classify(response);

            switch (step) {
                .done => {
                    // Print text if not streaming
                    if (!self.config.streaming) {
                        if (react.extractThought(response.content)) |thought| {
                            try self.stdout.print("{s}", .{thought});
                        }
                    }
                    try self.stdout.print("\n", .{});
                    break;
                },
                .max_tokens => {
                    try self.stdout.print("\n{s}(max tokens){s}\n", .{ Color.yellow, Color.reset });
                    break;
                },
                .needs_observation => {
                    // Print thought (reasoning before action) if not streaming
                    if (!self.config.streaming) {
                        if (react.extractThought(response.content)) |thought| {
                            try self.stdout.print("{s}", .{thought});
                        }
                    }

                    // === ACT: Execute tools ===
                    for (response.content) |block| {
                        if (block.type != .tool_use) continue;
                        const tu = block.tool_use orelse continue;
                        try self.stdout.print("\n{s}[act]{s} {s}{s}{s}", .{
                            Color.yellow, Color.reset,
                            Color.bold,   tu.name,
                            Color.reset,
                        });
                        // Show tool-specific context
                        if (std.mem.eql(u8, tu.name, "bash")) {
                            if (json.extractString(tu.input_raw, "command")) |c| {
                                try self.stdout.print(" {s}{s}{s}", .{ Color.dim, c, Color.reset });
                            }
                        } else if (std.mem.eql(u8, tu.name, "read_file") or
                            std.mem.eql(u8, tu.name, "write_file") or
                            std.mem.eql(u8, tu.name, "edit_file"))
                        {
                            if (json.extractString(tu.input_raw, "path")) |p| {
                                try self.stdout.print(" {s}{s}{s}", .{ Color.dim, p, Color.reset });
                            }
                        } else if (std.mem.eql(u8, tu.name, "search")) {
                            if (json.extractString(tu.input_raw, "pattern")) |p| {
                                try self.stdout.print(" {s}/{s}/{s}", .{ Color.dim, p, Color.reset });
                            }
                        }
                        try self.stdout.print("\n", .{});
                    }

                    // Execute all tools via react module
                    const tool_results = try react.executeTools(
                        self.allocator,
                        response.content,
                        &self.loop_hashes,
                        &self.loop_idx,
                    );

                    // === OBSERVE: Show results ===
                    for (tool_results) |result| {
                        const output = result.content orelse "";
                        const display = if (output.len > 500) output[0..500] else output;
                        if (result.is_error) {
                            try self.stdout.print("{s}[observe]{s} {s}{s}{s}\n", .{
                                Color.red, Color.reset, Color.red, display, Color.reset,
                            });
                        } else {
                            try self.stdout.print("{s}[observe]{s} {s}{s}{s}\n", .{
                                Color.green, Color.reset, Color.dim, display, Color.reset,
                            });
                        }
                        if (output.len > 500) {
                            try self.stdout.print("{s}... ({d} bytes total){s}\n", .{ Color.dim, output.len, Color.reset });
                        }
                    }

                    // Add observations to message history
                    try self.messages.append(self.allocator, .{
                        .role = .user,
                        .content = tool_results,
                    });
                },
            }
        }

        if (iteration >= react.MAX_ITERATIONS) {
            try self.stdout.print("\n{s}(react: max {d} iterations reached){s}\n", .{
                Color.yellow, react.MAX_ITERATIONS, Color.reset,
            });
        }

        // Usage summary
        const ctx_usage = self.context.usageString(self.allocator, self.messages.items) catch "?";
        try self.stdout.print("{s}[tokens] in:{d} out:{d} | ctx:{s}{s}\n", .{
            Color.dim,
            self.total_input_tokens,
            self.total_output_tokens,
            ctx_usage,
            Color.reset,
        });
    }

    fn handleApiError(self: *Agent, err: anyerror) !void {
        try self.stdout.print("{s}API error: {}{s}\n", .{ Color.red, err, Color.reset });
        if (err == api.ApiError.RateLimited) {
            try self.stdout.print("{s}Rate limited. Wait and retry.{s}\n", .{ Color.yellow, Color.reset });
        } else if (err == api.ApiError.AuthError) {
            try self.stdout.print("{s}Check your API key.{s}\n", .{ Color.yellow, Color.reset });
        } else if (err == api.ApiError.ConnectionRefused) {
            try self.stdout.print("{s}Cannot connect. Check base URL and network.{s}\n", .{ Color.yellow, Color.reset });
        }
        return err;
    }
};

/// Streaming text callback — prints text deltas as they arrive.
fn printTextDelta(text: []const u8) void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    stdout.writeAll(text) catch {};
}

/// Multilingual stop phrases — EN, ES, FR, ZH, HI, AR, JA, DE, PT, RU
/// Uses FNV-1a hash table for minimal binary footprint (~200 bytes vs ~800 for string table).
/// Collision-free verified at comptime.
pub fn isStopPhrase(input: []const u8) bool {
    if (input.len == 0 or input.len > 20) return false;
    const h = fnv1a(input);
    for (stop_hashes) |sh| {
        if (sh == h) return true;
    }
    return false;
}

fn fnv1a(s: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (s) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    return h;
}

const stop_hashes = blk: {
    const phrases = [_][]const u8{
        // EN
        "stop", "cancel", "quit", "exit",
        // ES
        "parar", "cancelar", "salir",
        // FR
        "arrêter", "annuler", "quitter",
        // ZH / JA (停止 shared)
        "停止", "取消", "退出", "中止", "終了",
        // HI
        "रुको", "रद्द", "बंद",
        // AR
        "توقف", "إلغاء", "خروج",
        // DE
        "stopp", "abbrechen", "beenden",
        // PT (parar/cancelar shared with ES)
        "sair",
        // RU
        "стоп", "отмена", "выход",
    };
    var hashes: [phrases.len]u64 = undefined;
    for (phrases, 0..) |p, i| {
        var h: u64 = 0xcbf29ce484222325;
        for (p) |b| {
            h ^= b;
            h *%= 0x100000001b3;
        }
        // Verify no collisions
        for (hashes[0..i]) |prev| {
            if (prev == h) @compileError("FNV-1a collision in stop phrases");
        }
        hashes[i] = h;
    }
    break :blk hashes;
};

// --- Tests ---

test "isStopPhrase English" {
    try std.testing.expect(isStopPhrase("stop"));
    try std.testing.expect(isStopPhrase("cancel"));
    try std.testing.expect(isStopPhrase("quit"));
    try std.testing.expect(isStopPhrase("exit"));
}

test "isStopPhrase multilingual" {
    // ES
    try std.testing.expect(isStopPhrase("parar"));
    try std.testing.expect(isStopPhrase("salir"));
    // FR
    try std.testing.expect(isStopPhrase("quitter"));
    // ZH
    try std.testing.expect(isStopPhrase("停止"));
    try std.testing.expect(isStopPhrase("退出"));
    // JA
    try std.testing.expect(isStopPhrase("中止"));
    try std.testing.expect(isStopPhrase("終了"));
    // DE
    try std.testing.expect(isStopPhrase("stopp"));
    try std.testing.expect(isStopPhrase("abbrechen"));
    // RU
    try std.testing.expect(isStopPhrase("стоп"));
    try std.testing.expect(isStopPhrase("выход"));
    // HI
    try std.testing.expect(isStopPhrase("रुको"));
    // AR
    try std.testing.expect(isStopPhrase("توقف"));
    // PT
    try std.testing.expect(isStopPhrase("sair"));
}

test "isStopPhrase rejects non-stop input" {
    try std.testing.expect(!isStopPhrase("hello"));
    try std.testing.expect(!isStopPhrase("stopping"));
    try std.testing.expect(!isStopPhrase(""));
    try std.testing.expect(!isStopPhrase("STOP")); // case-sensitive
}
