const std = @import("std");
const tree_mod = @import("tree.zig");
const qjs = @import("qjs.zig");
const c = qjs.c;

pub const State = struct {
    tree: *tree_mod.Tree,
    interval_ms: u64 = 0,
    timer_callback: c.JSValue = qjs.undefinedValue(),
};

/// Install the complete M0 capability surface. QuickJS's libc helpers are not
/// linked, so this explicit object is also the widget sandbox boundary.
pub fn install(ctx: *c.JSContext, bridge_state: *State) !void {
    c.JS_SetContextOpaque(ctx, bridge_state);
    const global = c.JS_GetGlobalObject(ctx);
    defer c.JS_FreeValue(ctx, global);
    const native = c.JS_NewObject(ctx);
    if (c.JS_IsException(native)) return error.QuickJs;
    errdefer c.JS_FreeValue(ctx, native);
    try setFunction(ctx, native, "createNode", createNode, 1);
    try setFunction(ctx, native, "setProp", setProp, 3);
    try setFunction(ctx, native, "setText", setText, 2);
    try setFunction(ctx, native, "appendChild", appendChild, 2);
    try setFunction(ctx, native, "removeNode", removeNode, 1);
    try setFunction(ctx, native, "setRoot", setRoot, 1);
    try setFunction(ctx, native, "setInterval", setInterval, 1);
    try setFunction(ctx, native, "onTimer", onTimer, 1);
    try setFunction(ctx, native, "log", log, 1);
    if (c.JS_SetPropertyStr(ctx, global, "native", native) < 0) return error.QuickJs;
}

pub fn deinit(ctx: *c.JSContext, bridge_state: *State) void {
    c.JS_FreeValue(ctx, bridge_state.timer_callback);
    bridge_state.timer_callback = qjs.undefinedValue();
}

fn setFunction(ctx: *c.JSContext, object: c.JSValue, name: [*:0]const u8, function: c.JSCFunction, argc: c_int) !void {
    const value = c.JS_NewCFunction2(ctx, function, name, argc, c.JS_CFUNC_generic, 0);
    if (c.JS_IsException(value) or c.JS_SetPropertyStr(ctx, object, name, value) < 0) return error.QuickJs;
}

fn state(ctx: *c.JSContext) *State {
    return @ptrCast(@alignCast(c.JS_GetContextOpaque(ctx).?));
}

fn fail(ctx: *c.JSContext, message: [*:0]const u8) c.JSValue {
    return c.JS_ThrowTypeError(ctx, "%s", message);
}

fn idArg(ctx: *c.JSContext, value: c.JSValueConst) !tree_mod.NodeId {
    var id: u32 = 0;
    if (c.JS_ToUint32(ctx, &id, value) < 0) return error.InvalidArgument;
    return id;
}

fn stringArg(ctx: *c.JSContext, value: c.JSValueConst) !struct { bytes: []const u8, raw: [*c]const u8 } {
    var len: usize = 0;
    const raw = c.JS_ToCStringLen2(ctx, &len, value, false) orelse return error.InvalidArgument;
    return .{ .bytes = raw[0..len], .raw = raw };
}

fn createNode(ctx: ?*c.JSContext, _: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const js = ctx orelse return qjs.exceptionValue();
    if (argc != 1) return fail(js, "createNode expects one argument");
    const kind_text = stringArg(js, argv[0]) catch return fail(js, "node type must be a string");
    defer c.JS_FreeCString(js, kind_text.raw);
    const kind = tree_mod.Kind.parse(kind_text.bytes) orelse return fail(js, "unsupported node type");
    const id = state(js).tree.createNode(kind) catch return fail(js, "node capacity exhausted");
    return c.JS_NewUint32(js, id);
}

fn setText(ctx: ?*c.JSContext, _: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const js = ctx orelse return qjs.exceptionValue();
    if (argc != 2) return fail(js, "setText expects id and text");
    const id = idArg(js, argv[0]) catch return fail(js, "invalid node id");
    const value = stringArg(js, argv[1]) catch return fail(js, "text must be a string");
    defer c.JS_FreeCString(js, value.raw);
    state(js).tree.setText(id, value.bytes) catch return fail(js, "setText failed");
    return qjs.undefinedValue();
}

fn appendChild(ctx: ?*c.JSContext, _: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const js = ctx orelse return qjs.exceptionValue();
    if (argc != 2) return fail(js, "appendChild expects parent and child ids");
    const parent = idArg(js, argv[0]) catch return fail(js, "invalid parent id");
    const child = idArg(js, argv[1]) catch return fail(js, "invalid child id");
    state(js).tree.appendChild(parent, child) catch return fail(js, "appendChild failed");
    return qjs.undefinedValue();
}

fn removeNode(ctx: ?*c.JSContext, _: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const js = ctx orelse return qjs.exceptionValue();
    if (argc != 1) return fail(js, "removeNode expects one id");
    state(js).tree.removeNode(idArg(js, argv[0]) catch return fail(js, "invalid node id")) catch return fail(js, "removeNode failed");
    return qjs.undefinedValue();
}

fn setRoot(ctx: ?*c.JSContext, _: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const js = ctx orelse return qjs.exceptionValue();
    if (argc != 1) return fail(js, "setRoot expects one id");
    state(js).tree.setRoot(idArg(js, argv[0]) catch return fail(js, "invalid node id")) catch return fail(js, "setRoot failed");
    return qjs.undefinedValue();
}

fn setProp(ctx: ?*c.JSContext, _: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const js = ctx orelse return qjs.exceptionValue();
    if (argc != 3) return fail(js, "setProp expects id, key, and value");
    const id = idArg(js, argv[0]) catch return fail(js, "invalid node id");
    const key = stringArg(js, argv[1]) catch return fail(js, "property key must be a string");
    defer c.JS_FreeCString(js, key.raw);
    if (std.mem.eql(u8, key.bytes, "background")) {
        const value = stringArg(js, argv[2]) catch return fail(js, "background must be #RRGGBBAA");
        defer c.JS_FreeCString(js, value.raw);
        const color = parseColor(value.bytes) orelse return fail(js, "background must be #RRGGBBAA");
        state(js).tree.setBackground(id, color) catch return fail(js, "setProp failed");
    } else if (std.mem.eql(u8, key.bytes, "fontWeight")) {
        const value = stringArg(js, argv[2]) catch return fail(js, "fontWeight must be a string");
        defer c.JS_FreeCString(js, value.raw);
        state(js).tree.setFontWeight(id, value.bytes) catch return fail(js, "invalid fontWeight");
    } else {
        var value: f64 = 0;
        if (c.JS_ToFloat64(js, &value, argv[2]) < 0) return fail(js, "property value must be numeric");
        state(js).tree.setNumberProp(id, key.bytes, @floatCast(value)) catch return fail(js, "unsupported property");
    }
    return qjs.undefinedValue();
}

fn setInterval(ctx: ?*c.JSContext, _: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const js = ctx orelse return qjs.exceptionValue();
    if (argc != 1) return fail(js, "setInterval expects milliseconds");
    var milliseconds: i64 = 0;
    if (c.JS_ToInt64(js, &milliseconds, argv[0]) < 0 or milliseconds <= 0) return fail(js, "interval must be positive");
    state(js).interval_ms = @intCast(milliseconds);
    return c.JS_NewUint32(js, 1);
}

fn onTimer(ctx: ?*c.JSContext, _: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const js = ctx orelse return qjs.exceptionValue();
    if (argc != 1 or !c.JS_IsFunction(js, argv[0])) return fail(js, "onTimer expects a function");
    const bridge_state = state(js);
    c.JS_FreeValue(js, bridge_state.timer_callback);
    bridge_state.timer_callback = c.JS_DupValue(js, argv[0]);
    return qjs.undefinedValue();
}

fn log(ctx: ?*c.JSContext, _: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const js = ctx orelse return qjs.exceptionValue();
    if (argc != 1) return fail(js, "log expects one string");
    const value = stringArg(js, argv[0]) catch return fail(js, "log expects one string");
    defer c.JS_FreeCString(js, value.raw);
    std.log.info("widget: {s}", .{value.bytes});
    return qjs.undefinedValue();
}

fn parseColor(value: []const u8) ?@import("native_sdk").canvas.Color {
    if (value.len != 9 or value[0] != '#') return null;
    const rgba = std.fmt.parseInt(u32, value[1..], 16) catch return null;
    return @import("native_sdk").canvas.Color.rgba8(@truncate(rgba >> 24), @truncate(rgba >> 16), @truncate(rgba >> 8), @truncate(rgba));
}
