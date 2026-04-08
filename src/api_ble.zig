//! BLE Transport API Client for Lite builds.
//!
//! Replaces api.zig when building with -Dembedded=true.
//! Instead of HTTP/TLS, sends API requests over BLE transport RPC
//! to a phone/gateway that proxies to the LLM API.
//!
//! Protocol (defined in transport.zig):
//!   Request:  {"type":"api","provider":"claude","body":<request_json>}
//!   Response: {"type":"api_result","body":<response_json>}

const std = @import("std");
const types = @import("types.zig");
const json = @import("json.zig");
const transport_mod = @import("transport.zig");
const api_parse = @import("api_parse.zig");

pub const ApiError = error{
    HttpError,
    InvalidResponse,
    RateLimited,
    ServerError,
    AuthError,
    OutOfMemory,
    ParseError,
    ConnectionRefused,
    NoTransport,
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    config: types.Config,
    transport: ?transport_mod.Transport = null,

    pub fn init(allocator: std.mem.Allocator, config: types.Config) Client {
        return .{ .allocator = allocator, .config = config };
    }

    pub fn setTransport(self: *Client, t: transport_mod.Transport) void {
        self.transport = t;
    }

    pub fn deinit(self: *Client) void {
        _ = self;
    }

    /// Send messages via BLE transport RPC.
    pub fn sendMessages(self: *Client, messages: []const types.Message) !types.ApiResponse {
        const t = self.transport orelse return ApiError.NoTransport;

        // Build request body (same JSON as HTTP path)
        const body = switch (self.config.provider) {
            .claude => try json.buildClaudeRequest(self.allocator, self.config, messages),
            .openai, .ollama => try json.buildOpenAiRequest(self.allocator, self.config, messages),
        };
        defer self.allocator.free(body);

        // Build RPC envelope
        const provider_str: []const u8 = switch (self.config.provider) {
            .claude => "claude",
            .openai => "openai",
            .ollama => "ollama",
        };
        const rpc = try transport_mod.buildApiRpc(self.allocator, provider_str, body);
        defer self.allocator.free(rpc);

        // Send and receive response
        const response_raw = t.send(rpc) catch return ApiError.ConnectionRefused;

        // Parse RPC response envelope: {"type":"api_result","body":<json>}
        // The phone returns the full API response inside "body"
        const inner_body = json.extractObject(response_raw, "body") orelse response_raw;

        // Parse as standard API response
        return switch (self.config.provider) {
            .claude => api_parse.parseClaudeResponse(self.allocator, inner_body),
            .openai, .ollama => api_parse.parseOpenAiResponse(self.allocator, inner_body),
        };
    }

    /// Streaming not supported over BLE — falls back to non-streaming.
    pub fn sendMessagesStreaming(
        self: *Client,
        messages: []const types.Message,
        on_text: ?*const fn ([]const u8) void,
    ) !types.ApiResponse {
        _ = on_text;
        return self.sendMessages(messages);
    }
};

// Response parsing delegated to api_parse.zig (shared with api.zig)
