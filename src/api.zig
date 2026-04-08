const std = @import("std");
const types = @import("types.zig");
const json = @import("json.zig");
const StreamParser = @import("stream.zig").StreamParser;
const api_parse = @import("api_parse.zig");

const CLAUDE_API_VERSION = "2023-06-01";

pub const ApiError = error{
    HttpError,
    InvalidResponse,
    RateLimited,
    ServerError,
    AuthError,
    OutOfMemory,
    ParseError,
    ConnectionRefused,
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    config: types.Config,
    http_client: std.http.Client,

    pub fn init(allocator: std.mem.Allocator, config: types.Config) Client {
        return .{
            .allocator = allocator,
            .config = config,
            .http_client = std.http.Client{ .allocator = allocator },
        };
    }

    pub fn deinit(self: *Client) void {
        self.http_client.deinit();
    }

    /// Send messages and return parsed response (non-streaming).
    pub fn sendMessages(self: *Client, messages: []const types.Message) !types.ApiResponse {
        var cfg = self.config;
        cfg.streaming = false;
        return self.doRequest(cfg, messages, null);
    }

    /// Send messages with streaming. Calls on_text for each text chunk.
    pub fn sendMessagesStreaming(
        self: *Client,
        messages: []const types.Message,
        on_text: ?*const fn ([]const u8) void,
    ) !types.ApiResponse {
        var cfg = self.config;
        cfg.streaming = true;
        return self.doRequest(cfg, messages, on_text);
    }

    fn doRequest(
        self: *Client,
        config: types.Config,
        messages: []const types.Message,
        on_text: ?*const fn ([]const u8) void,
    ) !types.ApiResponse {
        // Build request body based on provider
        const body = switch (config.provider) {
            .claude => try json.buildClaudeRequest(self.allocator, config, messages),
            .openai, .ollama => try json.buildOpenAiRequest(self.allocator, config, messages),
        };
        defer self.allocator.free(body);

        // Determine URL
        const base = config.base_url orelse config.provider.baseUrl();
        const path = config.provider.messagesPath();
        const url = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ base, path });
        defer self.allocator.free(url);

        // Build headers based on provider
        var auth_buf: [512]u8 = undefined;

        const extra_headers: []const std.http.Header = switch (config.provider) {
            .claude => &.{
                .{ .name = "x-api-key", .value = config.api_key },
                .{ .name = "anthropic-version", .value = CLAUDE_API_VERSION },
                .{ .name = "content-type", .value = "application/json" },
            },
            .openai => blk: {
                const auth = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{config.api_key}) catch return ApiError.OutOfMemory;
                break :blk &.{
                    .{ .name = "Authorization", .value = auth },
                    .{ .name = "content-type", .value = "application/json" },
                };
            },
            .ollama => &.{
                .{ .name = "content-type", .value = "application/json" },
            },
        };

        const uri = std.Uri.parse(url) catch return ApiError.HttpError;

        // Use request() for both streaming and non-streaming
        var req = self.http_client.request(.POST, uri, .{
            .extra_headers = extra_headers,
        }) catch return ApiError.ConnectionRefused;
        defer req.deinit();

        // Send body
        req.transfer_encoding = .{ .content_length = body.len };
        var send_body = req.sendBodyUnflushed(&.{}) catch return ApiError.HttpError;
        send_body.writer.writeAll(body) catch return ApiError.HttpError;
        send_body.end() catch return ApiError.HttpError;
        req.connection.?.flush() catch return ApiError.HttpError;

        // Receive response head
        var head_buf: [16384]u8 = undefined;
        var response = req.receiveHead(&head_buf) catch return ApiError.HttpError;

        if (response.head.status != .ok) {
            return switch (response.head.status) {
                .too_many_requests => ApiError.RateLimited,
                .unauthorized => ApiError.AuthError,
                .internal_server_error, .bad_gateway, .service_unavailable => ApiError.ServerError,
                else => ApiError.HttpError,
            };
        }

        // Read response body
        var transfer_buf: [8192]u8 = undefined;
        const reader = response.reader(&transfer_buf);

        if (config.streaming) {
            return self.readStreaming(reader, on_text);
        }

        // Non-streaming: read all
        var resp_body_list: std.ArrayList(u8) = .{};
        defer resp_body_list.deinit(self.allocator);

        var read_buf: [4096]u8 = undefined;
        while (true) {
            const n = reader.readSliceShort(&read_buf) catch return ApiError.HttpError;
            if (n == 0) break;
            resp_body_list.appendSlice(self.allocator, read_buf[0..n]) catch return ApiError.OutOfMemory;
        }

        return parseResponse(self.allocator, resp_body_list.items, config.provider);
    }

    fn readStreaming(self: *Client, reader: anytype, on_text: ?*const fn ([]const u8) void) !types.ApiResponse {
        var parser = StreamParser.init(self.allocator);
        defer parser.deinit();

        var buf: [4096]u8 = undefined;
        while (true) {
            const n = reader.readSliceShort(&buf) catch return ApiError.HttpError;
            if (n == 0) break;

            const done = try parser.feed(buf[0..n], on_text);
            if (done) break;
        }

        return parser.toResponse();
    }
};

/// Parse a non-streaming Claude API response.
fn parseResponse(allocator: std.mem.Allocator, body: []const u8, provider: types.Provider) !types.ApiResponse {
    return switch (provider) {
        .claude => api_parse.parseClaudeResponse(allocator, body),
        .openai, .ollama => api_parse.parseOpenAiResponse(allocator, body),
    };
}

// Response parsing delegated to api_parse.zig (shared with api_ble.zig)
