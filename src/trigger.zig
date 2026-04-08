//! Local Threshold Trigger Engine for Lite builds.
//!
//! Evaluates rules on each cron tick without any LLM involvement.
//! Sub-50ms reaction time for safety-critical thresholds.
//!
//! Rules are stored as a fixed array — no heap allocation.
//! Example: "if temp > 85 → gpio_write(fan_pin, 1)"

const std = @import("std");

pub const MAX_RULES = 16;

pub const Operator = enum(u8) {
    gt, // >
    lt, // <
    eq, // ==
    gte, // >=
    lte, // <=
    neq, // !=
};

pub const Action = enum(u8) {
    gpio_write,
    kv_set,
    ble_notify,
    none,
};

pub const Rule = struct {
    sensor_id: u8 = 0,
    operator: Operator = .gt,
    threshold: i32 = 0,
    action: Action = .none,
    /// For gpio_write: pin number. For kv_set: key hash. For ble_notify: event code.
    action_arg: u16 = 0,
    /// For gpio_write: value to write. For kv_set: not used.
    action_val: u16 = 0,
    active: bool = false,
};

pub const EvalResult = struct {
    rule_index: u8,
    action: Action,
    action_arg: u16,
    action_val: u16,
};

pub const TriggerEngine = struct {
    rules: [MAX_RULES]Rule = [_]Rule{.{}} ** MAX_RULES,
    rule_count: u8 = 0,
    fire_count: u32 = 0,

    pub fn addRule(self: *TriggerEngine, rule: Rule) !void {
        if (self.rule_count >= MAX_RULES) return error.TooManyRules;
        var r = rule;
        r.active = true;
        self.rules[self.rule_count] = r;
        self.rule_count += 1;
    }

    pub fn removeRule(self: *TriggerEngine, index: u8) void {
        if (index >= self.rule_count) return;
        self.rules[index].active = false;
    }

    /// Evaluate all active rules against a sensor reading.
    /// Returns fired actions in the provided buffer.
    pub fn evaluate(
        self: *TriggerEngine,
        sensor_id: u8,
        value: i32,
        results: []EvalResult,
    ) u8 {
        var count: u8 = 0;
        for (self.rules[0..self.rule_count], 0..) |rule, i| {
            if (!rule.active or rule.sensor_id != sensor_id) continue;
            if (!checkCondition(value, rule.operator, rule.threshold)) continue;

            if (count < results.len) {
                results[count] = .{
                    .rule_index = @intCast(i),
                    .action = rule.action,
                    .action_arg = rule.action_arg,
                    .action_val = rule.action_val,
                };
                count += 1;
                self.fire_count += 1;
            }
        }
        return count;
    }

    /// Evaluate all rules against multiple sensor readings.
    /// sensors is an array of {sensor_id, value} pairs.
    pub fn evaluateAll(
        self: *TriggerEngine,
        sensors: []const [2]i32,
        results: []EvalResult,
    ) u8 {
        var total: u8 = 0;
        for (sensors) |s| {
            const n = self.evaluate(@intCast(s[0]), s[1], results[total..]);
            total += n;
        }
        return total;
    }
};

fn checkCondition(value: i32, op: Operator, threshold: i32) bool {
    return switch (op) {
        .gt => value > threshold,
        .lt => value < threshold,
        .eq => value == threshold,
        .gte => value >= threshold,
        .lte => value <= threshold,
        .neq => value != threshold,
    };
}

// ============================================================
// Tests
// ============================================================

test "trigger basic gt fires" {
    var engine = TriggerEngine{};
    try engine.addRule(.{ .sensor_id = 1, .operator = .gt, .threshold = 85, .action = .gpio_write, .action_arg = 5, .action_val = 1 });

    var results: [4]EvalResult = undefined;
    const n = engine.evaluate(1, 90, &results);
    try std.testing.expectEqual(@as(u8, 1), n);
    try std.testing.expectEqual(Action.gpio_write, results[0].action);
    try std.testing.expectEqual(@as(u16, 5), results[0].action_arg);
    try std.testing.expectEqual(@as(u16, 1), results[0].action_val);
}

test "trigger basic gt does not fire" {
    var engine = TriggerEngine{};
    try engine.addRule(.{ .sensor_id = 1, .operator = .gt, .threshold = 85, .action = .gpio_write, .action_arg = 5, .action_val = 1 });

    var results: [4]EvalResult = undefined;
    const n = engine.evaluate(1, 80, &results);
    try std.testing.expectEqual(@as(u8, 0), n);
}

test "trigger wrong sensor does not fire" {
    var engine = TriggerEngine{};
    try engine.addRule(.{ .sensor_id = 1, .operator = .gt, .threshold = 85, .action = .gpio_write });

    var results: [4]EvalResult = undefined;
    const n = engine.evaluate(2, 90, &results); // sensor 2, not 1
    try std.testing.expectEqual(@as(u8, 0), n);
}

test "trigger multiple rules fire" {
    var engine = TriggerEngine{};
    try engine.addRule(.{ .sensor_id = 1, .operator = .gt, .threshold = 80, .action = .gpio_write, .action_arg = 5 });
    try engine.addRule(.{ .sensor_id = 1, .operator = .gt, .threshold = 90, .action = .ble_notify, .action_arg = 1 });

    var results: [4]EvalResult = undefined;
    const n = engine.evaluate(1, 95, &results);
    try std.testing.expectEqual(@as(u8, 2), n);
    try std.testing.expectEqual(Action.gpio_write, results[0].action);
    try std.testing.expectEqual(Action.ble_notify, results[1].action);
}

test "trigger all operators" {
    var engine = TriggerEngine{};
    try engine.addRule(.{ .sensor_id = 0, .operator = .lt, .threshold = 10, .action = .kv_set });
    try engine.addRule(.{ .sensor_id = 0, .operator = .eq, .threshold = 5, .action = .kv_set });
    try engine.addRule(.{ .sensor_id = 0, .operator = .gte, .threshold = 5, .action = .kv_set });
    try engine.addRule(.{ .sensor_id = 0, .operator = .lte, .threshold = 5, .action = .kv_set });
    try engine.addRule(.{ .sensor_id = 0, .operator = .neq, .threshold = 99, .action = .kv_set });

    var results: [8]EvalResult = undefined;
    const n = engine.evaluate(0, 5, &results);
    // lt(10): 5<10 ✓, eq(5): 5==5 ✓, gte(5): 5>=5 ✓, lte(5): 5<=5 ✓, neq(99): 5!=99 ✓
    try std.testing.expectEqual(@as(u8, 5), n);
}

test "trigger remove rule" {
    var engine = TriggerEngine{};
    try engine.addRule(.{ .sensor_id = 1, .operator = .gt, .threshold = 50, .action = .gpio_write });
    engine.removeRule(0);

    var results: [4]EvalResult = undefined;
    const n = engine.evaluate(1, 100, &results);
    try std.testing.expectEqual(@as(u8, 0), n);
}

test "trigger max rules" {
    var engine = TriggerEngine{};
    var i: u8 = 0;
    while (i < MAX_RULES) : (i += 1) {
        try engine.addRule(.{ .sensor_id = i, .operator = .gt, .threshold = 0, .action = .none });
    }
    // 17th rule should fail
    try std.testing.expectError(error.TooManyRules, engine.addRule(.{ .sensor_id = 0, .operator = .gt, .threshold = 0, .action = .none }));
}

test "trigger fire count tracks" {
    var engine = TriggerEngine{};
    try engine.addRule(.{ .sensor_id = 0, .operator = .gt, .threshold = 0, .action = .gpio_write });

    var results: [4]EvalResult = undefined;
    _ = engine.evaluate(0, 5, &results);
    _ = engine.evaluate(0, 10, &results);
    try std.testing.expectEqual(@as(u32, 2), engine.fire_count);
}

test "trigger evaluateAll multiple sensors" {
    var engine = TriggerEngine{};
    try engine.addRule(.{ .sensor_id = 0, .operator = .gt, .threshold = 50, .action = .gpio_write });
    try engine.addRule(.{ .sensor_id = 1, .operator = .lt, .threshold = 20, .action = .ble_notify });

    const sensors = [_][2]i32{ .{ 0, 75 }, .{ 1, 10 } };
    var results: [4]EvalResult = undefined;
    const n = engine.evaluateAll(&sensors, &results);
    try std.testing.expectEqual(@as(u8, 2), n);
}
