const std = @import("std");
const build_options = @import("build_options");
const types = @import("types.zig");
const config_mod = if (!build_options.embedded) @import("config.zig") else struct {};
const agent_mod = @import("agent.zig");
const Agent = agent_mod.Agent;
const cron = if (!build_options.embedded) @import("cron.zig") else struct {};
const arena_mod = if (build_options.embedded) @import("arena.zig") else struct {};
const trigger_mod = if (build_options.embedded) @import("trigger.zig") else struct {};
const sensor_mod = if (build_options.embedded) @import("sensor.zig") else struct {};
const event_queue_mod = if (build_options.embedded) @import("event_queue.zig") else struct {};
const swarm_mod = if (build_options.embedded) @import("swarm.zig") else struct {};

const VERSION = "0.1.0";

const Color = struct {
    const reset = "\x1b[0m";
    const cyan = "\x1b[36m";
    const yellow = "\x1b[33m";
    const dim = "\x1b[2m";
    const bold = "\x1b[1m";
};

pub fn main() !void {
    if (build_options.embedded) {
        return mainEmbedded();
    } else {
        return mainFull();
    }
}

fn mainEmbedded() !void {
    var arena_instance = arena_mod.Arena128K.init();
    const allocator = arena_instance.allocator();
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stdin = std.fs.File.stdin().deprecatedReader();

    // Hardcoded config for embedded — no config file, no env vars, no CLI parsing
    // On real hardware, config comes from kv store or BLE provisioning
    const config = types.Config{
        .transport = .ble,
        .streaming = false, // BLE doesn't support streaming
    };

    // BLE wake support: on real hardware, the phone can push prompts over BLE
    // without the device needing to poll. The BLE RX characteristic write
    // triggers an interrupt that wakes the MCU from sleep.
    //
    // For now (desktop simulation), we read from stdin.
    // On hardware: BLE RX → interrupt → set ble_wake_pending flag → main loop picks it up.
    var ble_wake_pending: bool = false;
    var ble_wake_prompt: [512]u8 = undefined;
    var ble_wake_len: usize = 0;

    // Edge Intelligence subsystems (instantiated once, persist across agent runs)
    var trigger_engine = trigger_mod.TriggerEngine{};
    var sensor_ring = sensor_mod.RingBuffer{};
    var event_queue = event_queue_mod.EventQueue{};
    _ = &trigger_engine;
    _ = &sensor_ring;
    _ = &event_queue;

    // Interactive REPL (for BLE-simulated testing on Linux)
    try stdout.print("{s}NanoAgent Lite v{s} — IoT agent{s}\n", .{ Color.cyan, VERSION, Color.reset });

    while (true) {
        // Check BLE wake first — phone-pushed prompts take priority
        if (ble_wake_pending) {
            ble_wake_pending = false;
            const prompt = ble_wake_prompt[0..ble_wake_len];
            try stdout.print("{s}[ble]{s} wake: {s}\n", .{ Color.cyan, Color.reset, prompt });
            var agent = Agent.init(allocator, config);
            defer agent.deinit();
            agent.run(prompt) catch |err| {
                try stdout.print("{s}Error: {}{s}\n", .{ Color.yellow, err, Color.reset });
            };
            arena_instance.reset();
            continue;
        }

        try stdout.print("\n{s}>{s} ", .{ Color.cyan, Color.reset });

        const line = stdin.readUntilDelimiterAlloc(allocator, '\n', 1024 * 4) catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };
        defer allocator.free(line);

        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;
        if (agent_mod.isStopPhrase(trimmed)) break;
        if (std.mem.eql(u8, trimmed, "/quit") or std.mem.eql(u8, trimmed, "/q")) break;

        // Simulate BLE wake for testing: /ble-wake <prompt>
        if (std.mem.startsWith(u8, trimmed, "/ble-wake ")) {
            const wake_prompt = trimmed[10..];
            const copy_len = @min(wake_prompt.len, ble_wake_prompt.len);
            @memcpy(ble_wake_prompt[0..copy_len], wake_prompt[0..copy_len]);
            ble_wake_len = copy_len;
            ble_wake_pending = true;
            try stdout.print("{s}[ble]{s} wake queued\n", .{ Color.dim, Color.reset });
            continue;
        }

        var agent = Agent.init(allocator, config);
        defer agent.deinit();
        agent.run(trimmed) catch |err| {
            try stdout.print("{s}Error: {}{s}\n", .{ Color.yellow, err, Color.reset });
        };
        // Reset arena between agent runs to reclaim memory
        arena_instance.reset();
    }

    try stdout.print("\n{s}bye{s}\n", .{ Color.dim, Color.reset });
    _ = &ble_wake_pending; // suppress unused variable in testing
}

fn mainFull() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stdin = std.fs.File.stdin().deprecatedReader();

    // Load config: file → env → CLI
    var config = try config_mod.load(allocator);
    const one_shot = try config_mod.applyCli(&config, allocator);

    // Validate API key
    if (config.api_key.len == 0) {
        const env_name: []const u8 = switch (config.provider) {
            .claude => "ANTHROPIC_API_KEY",
            .openai => "OPENAI_API_KEY",
            .ollama => "",
        };
        if (config.provider == .ollama) {
            // Ollama doesn't need a key
        } else {
            try stdout.print("{s}Error: {s} not set{s}\n", .{ Color.yellow, env_name, Color.reset });
            try stdout.print("  export {s}=...\n", .{env_name});
            std.process.exit(1);
        }
    }

    // One-shot mode
    if (one_shot) |prompt| {
        var agent = Agent.init(allocator, config);
        defer agent.deinit();
        try agent.run(prompt);
        return;
    }

    // Cron/daemon mode
    if (config.cron_interval > 0 or config.heartbeat_interval > 0) {
        var sched = cron.Scheduler.init(.{
            .interval_s = config.cron_interval,
            .prompt = config.cron_prompt,
            .heartbeat_s = config.heartbeat_interval,
            .max_runs = config.cron_max_runs,
        });

        try stdout.print("{s}[cron]{s} Starting scheduler", .{ Color.cyan, Color.reset });
        if (config.cron_interval > 0) {
            try stdout.print(" (agent every {d}s)", .{config.cron_interval});
        }
        if (config.heartbeat_interval > 0) {
            try stdout.print(" (heartbeat every {d}s)", .{config.heartbeat_interval});
        }
        if (config.cron_max_runs > 0) {
            try stdout.print(" (max {d} runs)", .{config.cron_max_runs});
        }
        try stdout.print("\n", .{});

        while (!sched.isComplete()) {
            if (sched.shouldHeartbeat()) {
                sched.emitHeartbeat();
            }

            if (sched.shouldRunAgent()) {
                try stdout.print("\n{s}[cron]{s} Run #{d}\n", .{ Color.cyan, Color.reset, sched.run_count });
                var agent = Agent.init(allocator, config);
                defer agent.deinit();
                agent.run(sched.getCronPrompt()) catch |err| {
                    try stdout.print("{s}[cron] Agent error: {}{s}\n", .{ Color.yellow, err, Color.reset });
                };
            }

            sched.sleepUntilNext();
        }

        try stdout.print("{s}[cron]{s} Complete ({d} runs)\n", .{ Color.cyan, Color.reset, sched.run_count });
        return;
    }

    // Interactive REPL
    try printBanner(stdout, config);

    while (true) {
        try stdout.print("\n{s}>{s} ", .{ Color.cyan, Color.reset });

        const line = stdin.readUntilDelimiterAlloc(allocator, '\n', 1024 * 16) catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };
        defer allocator.free(line);

        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;

        // Multilingual stop phrases
        if (agent_mod.isStopPhrase(trimmed)) break;

        // REPL commands
        if (std.mem.eql(u8, trimmed, "/quit") or
            std.mem.eql(u8, trimmed, "/exit") or
            std.mem.eql(u8, trimmed, "/q"))
        {
            break;
        }
        if (std.mem.eql(u8, trimmed, "/help")) {
            config_mod.printHelp();
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "/model ")) {
            config.model = trimmed[7..];
            try stdout.print("{s}Model: {s}{s}\n", .{ Color.dim, config.model, Color.reset });
            continue;
        }
        if (std.mem.eql(u8, trimmed, "/model")) {
            try stdout.print("{s}Model: {s}{s}\n", .{ Color.dim, config.model, Color.reset });
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "/provider ")) {
            const p = trimmed[10..];
            if (std.mem.eql(u8, p, "claude")) config.provider = .claude;
            if (std.mem.eql(u8, p, "openai")) config.provider = .openai;
            if (std.mem.eql(u8, p, "ollama")) config.provider = .ollama;
            try stdout.print("{s}Provider: {s}{s}\n", .{ Color.dim, p, Color.reset });
            continue;
        }

        var agent = Agent.init(allocator, config);
        defer agent.deinit();
        agent.run(trimmed) catch |err| {
            try stdout.print("{s}Error: {}{s}\n", .{ Color.yellow, err, Color.reset });
        };
    }

    try stdout.print("\n{s}bye{s}\n", .{ Color.dim, Color.reset });
}

fn printBanner(w: anytype, config: types.Config) !void {
    const provider_str: []const u8 = switch (config.provider) {
        .claude => "claude",
        .openai => "openai",
        .ollama => "ollama",
    };

    try w.print(
        \\
        \\{s}  _   _                    _                    _
        \\ | \ | | __ _ _ __   ___  / \   __ _  ___ _ __ | |_
        \\ |  \| |/ _` | '_ \ / _ \/ _ \ / _` |/ _ \ '_ \| __|
        \\ | |\  | (_| | | | | (_) / ___ \ (_| |  __/ | | | |_
        \\ |_| \_|\__,_|_| |_|\___/_/   \_\__, |\___|_| |_|\__|
        \\                                |___/
        \\{s}
        \\ {s}v{s} — the world's smallest AI agent runtime{s}
        \\
        \\ Provider: {s}  Model: {s}
        \\ Commands: /help /quit /model <name> /provider <name>
    , .{
        Color.cyan,
        Color.reset,
        Color.dim,
        VERSION,
        Color.reset,
        provider_str,
        config.model,
    });
}

// Pull in all modules for testing
test {
    _ = @import("types.zig");
    _ = @import("json.zig");
    if (build_options.embedded) {
        _ = @import("api_ble.zig");
    } else {
        _ = @import("api.zig");
        _ = @import("stream.zig");
    }
    _ = @import("tools.zig");
    _ = @import("context.zig");
    _ = @import("config.zig");
    _ = @import("transport.zig");
    _ = @import("arena.zig");
    _ = @import("cron.zig");
    _ = @import("trigger.zig");
    _ = @import("sensor.zig");
    _ = @import("fault_log.zig");
    _ = @import("event_queue.zig");
    _ = @import("power.zig");
    _ = @import("swarm.zig");
    _ = @import("api_parse.zig");
    _ = @import("tools_shared.zig");
    _ = @import("agent.zig");
    if (build_options.enable_ble) {
        _ = @import("ble.zig");
    }
    if (build_options.enable_serial) {
        _ = @import("serial.zig");
    }
}
