const std = @import("std");
const tree_mod = @import("tree.zig");
const network = @import("network.zig");
const provider_mod = @import("provider.zig");
const qjs = @import("qjs.zig");
const storage_mod = @import("storage.zig");
const c = qjs.c;

pub const State = struct {
    tree: *tree_mod.Tree,
    storage: *storage_mod.Store,
    provider: *provider_mod.Client,
    origins: []const []const u8,
    timers: [max_timers]TimerSlot = [_]TimerSlot{.{}} ** max_timers,
    next_timer_id: u64 = 1,
    event_callback: c.JSValue = qjs.undefinedValue(),
    provider_callback: c.JSValue = qjs.undefinedValue(),
    canvas_frames: [max_canvas_frames]CanvasFrameSlot = [_]CanvasFrameSlot{.{}} ** max_canvas_frames,
    fetches: [max_fetches]FetchSlot = [_]FetchSlot{.{}} ** max_fetches,
};

pub const max_timers: usize = 16;
pub const max_fetches: usize = 4;
pub const max_canvas_frames: usize = tree_mod.max_canvases;

pub const TimerSlot = struct {
    id: u64 = 0,
    interval_ms: u64 = 0,
    active: bool = false,
    callback: c.JSValue = qjs.undefinedValue(),
};

pub const CanvasFrameSlot = struct {
    node_id: tree_mod.NodeId = 0,
    callback: c.JSValue = qjs.undefinedValue(),
};

pub const FetchSlot = struct {
    active: bool = false,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    cancelled: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    thread: ?std.Thread = null,
    resolve: c.JSValue = qjs.undefinedValue(),
    reject: c.JSValue = qjs.undefinedValue(),
    request: network.Request = .{},
    result: network.Result = .{},
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
    try setFunction(ctx, native, "insertBefore", insertBefore, 3);
    try setFunction(ctx, native, "removeNode", removeNode, 1);
    try setFunction(ctx, native, "setRoot", setRoot, 1);
    try setFunction(ctx, native, "beginBatch", beginBatch, 0);
    try setFunction(ctx, native, "endBatch", endBatch, 0);
    try setFunction(ctx, native, "setHandler", setHandler, 3);
    try setFunction(ctx, native, "onEvent", onEvent, 1);
    try setFunction(ctx, native, "hostAvailable", hostAvailable, 0);
    try setFunction(ctx, native, "onProvider", onProvider, 1);
    try setFunction(ctx, native, "setInterval", setInterval, 1);
    try setFunction(ctx, native, "clearInterval", clearInterval, 1);
    try setFunction(ctx, native, "onTimer", onTimer, 2);
    try setFunction(ctx, native, "setCanvasCommands", setCanvasCommands, 2);
    try setFunction(ctx, native, "onCanvasFrame", onCanvasFrame, 2);
    try setFunction(ctx, native, "clearCanvasFrame", clearCanvasFrame, 1);
    try setFunction(ctx, native, "fetch", fetch, 4);
    try setFunction(ctx, native, "storageRead", storageRead, 0);
    try setFunction(ctx, native, "storageWrite", storageWrite, 1);
    try setFunction(ctx, native, "log", log, 1);
    if (c.JS_SetPropertyStr(ctx, global, "native", native) < 0) return error.QuickJs;
    const console = c.JS_NewObject(ctx);
    if (c.JS_IsException(console)) return error.QuickJs;
    errdefer c.JS_FreeValue(ctx, console);
    try setFunction(ctx, console, "log", consoleLog, 1);
    try setFunction(ctx, console, "warn", consoleLog, 1);
    try setFunction(ctx, console, "error", consoleLog, 1);
    if (c.JS_SetPropertyStr(ctx, global, "console", console) < 0) return error.QuickJs;
}

pub fn deinit(ctx: *c.JSContext, bridge_state: *State) void {
    for (&bridge_state.timers) |*timer| {
        c.JS_FreeValue(ctx, timer.callback);
        timer.* = .{};
    }
    for (&bridge_state.canvas_frames) |*frame| {
        c.JS_FreeValue(ctx, frame.callback);
        frame.* = .{};
    }
    c.JS_FreeValue(ctx, bridge_state.event_callback);
    c.JS_FreeValue(ctx, bridge_state.provider_callback);
    for (&bridge_state.fetches) |*slot| {
        if (slot.thread != null) slot.cancelled.store(1, .release);
    }
    for (&bridge_state.fetches) |*slot| {
        if (slot.thread) |thread| thread.join();
        c.JS_FreeValue(ctx, slot.resolve);
        c.JS_FreeValue(ctx, slot.reject);
        slot.request.deinit(std.heap.page_allocator);
        slot.result.deinit(std.heap.page_allocator);
        slot.* = .{};
    }
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

fn insertBefore(ctx: ?*c.JSContext, _: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const js = ctx orelse return qjs.exceptionValue();
    if (argc != 3) return fail(js, "insertBefore expects parent, child, and before ids");
    const parent = idArg(js, argv[0]) catch return fail(js, "invalid parent id");
    const child = idArg(js, argv[1]) catch return fail(js, "invalid child id");
    const before = idArg(js, argv[2]) catch return fail(js, "invalid before id");
    state(js).tree.insertBefore(parent, child, before) catch return fail(js, "insertBefore failed");
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

fn beginBatch(ctx: ?*c.JSContext, _: c.JSValueConst, argc: c_int, _: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const js = ctx orelse return qjs.exceptionValue();
    if (argc != 0) return fail(js, "beginBatch expects no arguments");
    state(js).tree.beginBatch();
    return qjs.undefinedValue();
}

fn endBatch(ctx: ?*c.JSContext, _: c.JSValueConst, argc: c_int, _: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const js = ctx orelse return qjs.exceptionValue();
    if (argc != 0) return fail(js, "endBatch expects no arguments");
    state(js).tree.endBatch();
    return qjs.undefinedValue();
}

fn setHandler(ctx: ?*c.JSContext, _: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const js = ctx orelse return qjs.exceptionValue();
    if (argc != 3) return fail(js, "setHandler expects id, event kind, and enabled");
    const id = idArg(js, argv[0]) catch return fail(js, "invalid node id");
    const kind = stringArg(js, argv[1]) catch return fail(js, "event kind must be a string");
    defer c.JS_FreeCString(js, kind.raw);
    const enabled = c.JS_ToBool(js, argv[2]);
    if (enabled < 0) return fail(js, "handler enabled must be boolean");
    state(js).tree.setHandler(id, kind.bytes, enabled != 0) catch return fail(js, "unsupported event handler");
    return qjs.undefinedValue();
}

/// The SDK installs exactly one event dispatcher. Native nodes retain only
/// handler-presence bits; typed closures stay in the JS reconciler, and every
/// press/change returns through this `(nodeId, kind, payload)` choke point.
fn onEvent(ctx: ?*c.JSContext, _: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const js = ctx orelse return qjs.exceptionValue();
    if (argc != 1 or !c.JS_IsFunction(js, argv[0])) return fail(js, "onEvent expects one function");
    const bridge_state = state(js);
    c.JS_FreeValue(js, bridge_state.event_callback);
    bridge_state.event_callback = c.JS_DupValue(js, argv[0]);
    return qjs.undefinedValue();
}

fn hostAvailable(ctx: ?*c.JSContext, _: c.JSValueConst, argc: c_int, _: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const js = ctx orelse return qjs.exceptionValue();
    if (argc != 0) return fail(js, "hostAvailable expects no arguments");
    return c.JS_NewBool(js, state(js).provider.available);
}

/// One string callback is the complete host-provider capability. Keeping the
/// JSON-line parsing in the SDK means native IPC never manufactures arbitrary
/// JS object graphs, and the runtime still invokes QuickJS only on its loop.
fn onProvider(ctx: ?*c.JSContext, _: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const js = ctx orelse return qjs.exceptionValue();
    if (argc != 1 or !c.JS_IsFunction(js, argv[0])) return fail(js, "onProvider expects one function");
    const bridge_state = state(js);
    c.JS_FreeValue(js, bridge_state.provider_callback);
    bridge_state.provider_callback = c.JS_DupValue(js, argv[0]);
    return qjs.undefinedValue();
}

fn storageRead(ctx: ?*c.JSContext, _: c.JSValueConst, argc: c_int, _: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const js = ctx orelse return qjs.exceptionValue();
    if (argc != 0) return fail(js, "storageRead expects no arguments");
    const bytes = state(js).storage.read() catch return fail(js, "storageRead failed");
    if (bytes) |value| return c.JS_NewStringLen(js, value.ptr, value.len);
    return qjs.nullValue();
}

fn storageWrite(ctx: ?*c.JSContext, _: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const js = ctx orelse return qjs.exceptionValue();
    if (argc != 1) return fail(js, "storageWrite expects one JSON string");
    const value = stringArg(js, argv[0]) catch return fail(js, "storageWrite expects one JSON string");
    defer c.JS_FreeCString(js, value.raw);
    state(js).storage.write(value.bytes) catch |err| return if (err == error.StorageQuotaExceeded)
        fail(js, "StorageQuotaExceeded: widget storage exceeds 64 KB")
    else
        fail(js, "storageWrite failed");
    return qjs.undefinedValue();
}

fn setProp(ctx: ?*c.JSContext, _: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const js = ctx orelse return qjs.exceptionValue();
    if (argc != 3) return fail(js, "setProp expects id, key, and value");
    const id = idArg(js, argv[0]) catch return fail(js, "invalid node id");
    const key = stringArg(js, argv[1]) catch return fail(js, "property key must be a string");
    defer c.JS_FreeCString(js, key.raw);
    if (std.mem.eql(u8, key.bytes, "background") or std.mem.eql(u8, key.bytes, "textColor") or std.mem.eql(u8, key.bytes, "borderColor")) {
        const value = stringArg(js, argv[2]) catch return fail(js, "background must be #RRGGBBAA");
        defer c.JS_FreeCString(js, value.raw);
        const color = if (value.bytes.len == 0) null else parseColor(value.bytes) orelse return fail(js, "color must be #RRGGBBAA");
        if (std.mem.eql(u8, key.bytes, "background")) {
            state(js).tree.setBackground(id, color) catch return fail(js, "setProp failed");
        } else if (std.mem.eql(u8, key.bytes, "textColor")) {
            state(js).tree.setTextColor(id, color) catch return fail(js, "setProp failed");
        } else {
            state(js).tree.setBorderColor(id, color) catch return fail(js, "setProp failed");
        }
    } else if (std.mem.eql(u8, key.bytes, "shadow") or std.mem.eql(u8, key.bytes, "textShadow")) {
        const value = stringArg(js, argv[2]) catch return fail(js, "shadow must be a packed string");
        defer c.JS_FreeCString(js, value.raw);
        if (std.mem.eql(u8, key.bytes, "shadow")) {
            const shadow = if (value.bytes.len == 0) null else parseBoxShadow(value.bytes) orelse return fail(js, "shadow must be 'x y blur spread #RRGGBBAA'");
            state(js).tree.setShadow(id, shadow) catch return fail(js, "setProp failed");
        } else {
            const shadow = if (value.bytes.len == 0) null else parseTextShadow(value.bytes) orelse return fail(js, "textShadow must be 'x y blur #RRGGBBAA'");
            state(js).tree.setTextShadow(id, shadow) catch return fail(js, "setProp failed");
        }
    } else if (std.mem.eql(u8, key.bytes, "source")) {
        const value = stringArg(js, argv[2]) catch return fail(js, "source must be a string");
        defer c.JS_FreeCString(js, value.raw);
        state(js).tree.setSource(id, value.bytes) catch return fail(js, "image source is too long");
    } else if (std.mem.eql(u8, key.bytes, "iconPath")) {
        const value = stringArg(js, argv[2]) catch return fail(js, "iconPath must be a string");
        defer c.JS_FreeCString(js, value.raw);
        state(js).tree.setIconPath(id, value.bytes) catch |err| return if (err == error.IconPathTooLong)
            fail(js, "iconPath exceeds the 8192-byte per-node limit")
        else
            fail(js, "invalid iconPath");
    } else if (std.mem.eql(u8, key.bytes, "iconViewBox")) {
        const value = stringArg(js, argv[2]) catch return fail(js, "iconViewBox must be a string");
        defer c.JS_FreeCString(js, value.raw);
        state(js).tree.setIconViewBox(id, value.bytes) catch return fail(js, "invalid iconViewBox");
    } else if (std.mem.eql(u8, key.bytes, "imageFit")) {
        const value = stringArg(js, argv[2]) catch return fail(js, "imageFit must be a string");
        defer c.JS_FreeCString(js, value.raw);
        state(js).tree.setImageFit(id, value.bytes) catch return fail(js, "imageFit must be cover, contain, or stretch");
    } else if (std.mem.eql(u8, key.bytes, "fontWeight")) {
        const value = stringArg(js, argv[2]) catch return fail(js, "fontWeight must be a string");
        defer c.JS_FreeCString(js, value.raw);
        state(js).tree.setFontWeight(id, value.bytes) catch return fail(js, "invalid fontWeight");
    } else if (std.mem.eql(u8, key.bytes, "fontFamily")) {
        const value = stringArg(js, argv[2]) catch return fail(js, "fontFamily must be a string");
        defer c.JS_FreeCString(js, value.raw);
        state(js).tree.setFontFamily(id, value.bytes) catch return fail(js, "invalid fontFamily");
    } else if (std.mem.eql(u8, key.bytes, "textAlign")) {
        const value = stringArg(js, argv[2]) catch return fail(js, "textAlign must be a string");
        defer c.JS_FreeCString(js, value.raw);
        state(js).tree.setTextAlign(id, value.bytes) catch return fail(js, "invalid textAlign");
    } else if (std.mem.eql(u8, key.bytes, "crossAlign") or std.mem.eql(u8, key.bytes, "mainAlign") or std.mem.eql(u8, key.bytes, "alignSelf")) {
        const value = stringArg(js, argv[2]) catch return fail(js, "alignment must be a string");
        defer c.JS_FreeCString(js, value.raw);
        if (std.mem.eql(u8, key.bytes, "crossAlign")) {
            state(js).tree.setCrossAlign(id, value.bytes) catch return fail(js, "invalid cross alignment");
        } else if (std.mem.eql(u8, key.bytes, "alignSelf")) {
            state(js).tree.setAlignSelf(id, value.bytes) catch return fail(js, "invalid self alignment");
        } else {
            state(js).tree.setMainAlign(id, value.bytes) catch return fail(js, "invalid main alignment");
        }
    } else if (std.mem.eql(u8, key.bytes, "truncate") or std.mem.eql(u8, key.bytes, "overflowHidden") or std.mem.eql(u8, key.bytes, "flexWrap") or std.mem.eql(u8, key.bytes, "tabularNums") or std.mem.eql(u8, key.bytes, "shadowInset") or std.mem.eql(u8, key.bytes, "imageTile")) {
        const value = c.JS_ToBool(js, argv[2]);
        if (value < 0) return fail(js, "property must be boolean");
        if (std.mem.eql(u8, key.bytes, "truncate")) {
            state(js).tree.setTruncate(id, value != 0) catch return fail(js, "setProp failed");
        } else if (std.mem.eql(u8, key.bytes, "overflowHidden")) {
            state(js).tree.setOverflowHidden(id, value != 0) catch return fail(js, "setProp failed");
        } else if (std.mem.eql(u8, key.bytes, "flexWrap")) {
            state(js).tree.setFlexWrap(id, value != 0) catch return fail(js, "setProp failed");
        } else if (std.mem.eql(u8, key.bytes, "tabularNums")) {
            state(js).tree.setTabularNums(id, value != 0) catch return fail(js, "setProp failed");
        } else if (std.mem.eql(u8, key.bytes, "imageTile")) {
            state(js).tree.setImageTile(id, value != 0) catch return fail(js, "setProp failed");
        } else {
            state(js).tree.setShadowInset(id, value != 0) catch return fail(js, "setProp failed");
        }
    } else {
        var value: f64 = 0;
        if (c.JS_ToFloat64(js, &value, argv[2]) < 0) return fail(js, "property value must be numeric");
        if (std.mem.eql(u8, key.bytes, "value") or std.mem.eql(u8, key.bytes, "max")) {
            state(js).tree.setControlValue(id, key.bytes, @floatCast(value)) catch return fail(js, "unsupported control property");
        } else {
            state(js).tree.setNumberProp(id, key.bytes, @floatCast(value)) catch return fail(js, "unsupported property");
        }
    }
    return qjs.undefinedValue();
}

fn setInterval(ctx: ?*c.JSContext, _: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const js = ctx orelse return qjs.exceptionValue();
    if (argc != 1) return fail(js, "setInterval expects milliseconds");
    var milliseconds: i64 = 0;
    if (c.JS_ToInt64(js, &milliseconds, argv[0]) < 0 or milliseconds <= 0) return fail(js, "interval must be positive");
    const bridge_state = state(js);
    for (&bridge_state.timers) |*timer| {
        if (timer.active) continue;
        const id = bridge_state.next_timer_id;
        bridge_state.next_timer_id +%= 1;
        timer.* = .{ .id = id, .interval_ms = @intCast(milliseconds), .active = true };
        return c.JS_NewInt64(js, @intCast(id));
    }
    return fail(js, "timer capacity exhausted");
}

fn clearInterval(ctx: ?*c.JSContext, _: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const js = ctx orelse return qjs.exceptionValue();
    if (argc != 1) return fail(js, "clearInterval expects one timer id");
    var id: i64 = 0;
    if (c.JS_ToInt64(js, &id, argv[0]) < 0 or id <= 0) return fail(js, "invalid timer id");
    for (&state(js).timers) |*timer| {
        if (!timer.active or timer.id != @as(u64, @intCast(id))) continue;
        c.JS_FreeValue(js, timer.callback);
        timer.* = .{};
        return qjs.undefinedValue();
    }
    return qjs.undefinedValue();
}

/// Register one callback for one native-clocked timer. Timer ids are returned
/// by `setInterval`; this keyed shape keeps concurrent hook/provider timers
/// independent and lets `clearInterval` retire either without a JS dispatcher.
fn onTimer(ctx: ?*c.JSContext, _: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const js = ctx orelse return qjs.exceptionValue();
    if (argc != 2 or !c.JS_IsFunction(js, argv[1])) return fail(js, "onTimer expects a timer id and function");
    var id: i64 = 0;
    if (c.JS_ToInt64(js, &id, argv[0]) < 0 or id <= 0) return fail(js, "invalid timer id");
    for (&state(js).timers) |*timer| {
        if (!timer.active or timer.id != @as(u64, @intCast(id))) continue;
        c.JS_FreeValue(js, timer.callback);
        timer.callback = c.JS_DupValue(js, argv[1]);
        return qjs.undefinedValue();
    }
    return fail(js, "unknown timer id");
}

/// Copy one Float64Array command batch at the QuickJS boundary. The wire is
/// intentionally numeric and bounded: JS performs color parsing and command
/// construction, while Zig validates every value before replacing the node's
/// prior batch. No JS object graph survives the call.
fn setCanvasCommands(ctx: ?*c.JSContext, _: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const js = ctx orelse return qjs.exceptionValue();
    if (argc != 2) return fail(js, "setCanvasCommands expects id and Float64Array");
    const id = idArg(js, argv[0]) catch return fail(js, "invalid canvas node id");
    if (c.JS_GetTypedArrayType(argv[1]) != c.JS_TYPED_ARRAY_FLOAT64) {
        return fail(js, "setCanvasCommands expects id and Float64Array");
    }
    var byte_offset: usize = 0;
    var byte_length: usize = 0;
    var bytes_per_element: usize = 0;
    const array_buffer = c.JS_GetTypedArrayBuffer(js, argv[1], &byte_offset, &byte_length, &bytes_per_element);
    if (c.JS_IsException(array_buffer)) return qjs.exceptionValue();
    defer c.JS_FreeValue(js, array_buffer);
    var buffer_length: usize = 0;
    const buffer = c.JS_GetArrayBuffer(js, &buffer_length, array_buffer) orelse return fail(js, "canvas command buffer is detached");
    if (bytes_per_element != @sizeOf(f64) or byte_length % @sizeOf(f64) != 0 or
        byte_offset > buffer_length or byte_length > buffer_length - byte_offset)
    {
        return fail(js, "canvas command batch must be a valid Float64Array");
    }
    const length = byte_length / @sizeOf(f64);
    if (length > tree_mod.max_canvas_wire_values) {
        return fail(js, "canvas command batch exceeds the native limit");
    }
    var values: [tree_mod.max_canvas_wire_values]f64 = undefined;
    const source: [*]const f64 = @ptrCast(@alignCast(buffer + byte_offset));
    @memcpy(values[0..length], source[0..length]);
    state(js).tree.setCanvasCommands(id, values[0..length]) catch return fail(js, "invalid canvas command batch");
    return qjs.undefinedValue();
}

/// Register a max-rate canvas callback. Its clock is the gpu-surface present
/// completion, not a second OS timer: one visible present produces at most one
/// next frame, so 60 fps animation follows the surface scheduler without a
/// free-running render loop.
fn onCanvasFrame(ctx: ?*c.JSContext, _: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const js = ctx orelse return qjs.exceptionValue();
    if (argc != 2 or !c.JS_IsFunction(js, argv[1])) return fail(js, "onCanvasFrame expects id and function");
    const id = idArg(js, argv[0]) catch return fail(js, "invalid canvas node id");
    _ = state(js).tree.canvasState(id) catch return fail(js, "invalid canvas node id");
    var free: ?*CanvasFrameSlot = null;
    for (&state(js).canvas_frames) |*slot| {
        if (slot.node_id == id) {
            c.JS_FreeValue(js, slot.callback);
            slot.callback = c.JS_DupValue(js, argv[1]);
            return qjs.undefinedValue();
        }
        if (free == null and slot.node_id == 0) free = slot;
    }
    const slot = free orelse return fail(js, "canvas frame callback capacity exhausted");
    slot.* = .{ .node_id = id, .callback = c.JS_DupValue(js, argv[1]) };
    return qjs.undefinedValue();
}

fn clearCanvasFrame(ctx: ?*c.JSContext, _: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const js = ctx orelse return qjs.exceptionValue();
    if (argc != 1) return fail(js, "clearCanvasFrame expects one id");
    const id = idArg(js, argv[0]) catch return fail(js, "invalid canvas node id");
    for (&state(js).canvas_frames) |*slot| {
        if (slot.node_id != id) continue;
        c.JS_FreeValue(js, slot.callback);
        slot.* = .{};
        break;
    }
    return qjs.undefinedValue();
}

pub fn hasCanvasFrames(bridge_state: *const State) bool {
    for (&bridge_state.canvas_frames) |slot| if (slot.node_id != 0) return true;
    return false;
}

pub fn dispatchCanvasFrames(ctx: *c.JSContext, bridge_state: *State, timestamp_ns: u64) bool {
    const timestamp = c.JS_NewFloat64(ctx, @as(f64, @floatFromInt(timestamp_ns)) / @as(f64, std.time.ns_per_s));
    defer c.JS_FreeValue(ctx, timestamp);
    for (&bridge_state.canvas_frames) |*slot| {
        if (slot.node_id == 0 or !c.JS_IsFunction(ctx, slot.callback)) continue;
        var arguments = [_]c.JSValue{timestamp};
        const result = c.JS_Call(ctx, slot.callback, qjs.undefinedValue(), arguments.len, &arguments);
        const succeeded = !c.JS_IsException(result);
        c.JS_FreeValue(ctx, result);
        if (!succeeded) return false;
    }
    return true;
}

/// `wfetch` uses WinHTTP on Windows and ephemeral NSURLSession on macOS. The
/// bridge copies one bounded request into one of four slots and runs the
/// blocking exchange on a worker; only `drainFetches` touches QuickJS from the
/// Native main loop. Both transports return the original 3xx instead of
/// following it, so no request can escape the exact manifest host checked here.
fn fetch(ctx: ?*c.JSContext, _: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const js = ctx orelse return qjs.exceptionValue();
    if (argc != 4) return fail(js, "fetch expects url, method, headers JSON, and body");
    const url = stringArg(js, argv[0]) catch return fail(js, "fetch url must be a string");
    defer c.JS_FreeCString(js, url.raw);
    const method = stringArg(js, argv[1]) catch return fail(js, "fetch method must be a string");
    defer c.JS_FreeCString(js, method.raw);
    const headers_json = stringArg(js, argv[2]) catch return fail(js, "fetch headers must be JSON");
    defer c.JS_FreeCString(js, headers_json.raw);
    const body = stringArg(js, argv[3]) catch return fail(js, "fetch body must be a string");
    defer c.JS_FreeCString(js, body.raw);

    var resolving: [2]c.JSValue = undefined;
    const promise = c.JS_NewPromiseCapability(js, &resolving);
    if (c.JS_IsException(promise)) return promise;
    const parsed_url = network.parseHttpsUrl(url.bytes) catch {
        rejectPromise(js, resolving[1], "HttpsRequired: wfetch accepts only https:// URLs");
        c.JS_FreeValue(js, resolving[0]);
        c.JS_FreeValue(js, resolving[1]);
        return promise;
    };
    if (!network.originDeclared(state(js).origins, parsed_url.declared_host)) {
        var message_buffer: [320]u8 = undefined;
        const message = std.fmt.bufPrint(&message_buffer, "OriginNotDeclared: add \"{s}\" to origins in your widget config", .{parsed_url.declared_host}) catch "OriginNotDeclared";
        rejectPromise(js, resolving[1], message);
        c.JS_FreeValue(js, resolving[0]);
        c.JS_FreeValue(js, resolving[1]);
        return promise;
    }
    if (!network.requestWithinCap(url.bytes.len, headers_json.bytes.len, body.bytes.len)) {
        rejectPromise(js, resolving[1], "RequestTooLarge: wfetch request exceeds 5 MB");
        c.JS_FreeValue(js, resolving[0]);
        c.JS_FreeValue(js, resolving[1]);
        return promise;
    }
    const bridge_state = state(js);
    const slot = for (&bridge_state.fetches) |*candidate| {
        if (!candidate.active) break candidate;
    } else {
        rejectPromise(js, resolving[1], "FetchCapacityExceeded: at most 4 requests may run concurrently");
        c.JS_FreeValue(js, resolving[0]);
        c.JS_FreeValue(js, resolving[1]);
        return promise;
    };
    slot.* = .{ .active = true, .resolve = resolving[0], .reject = resolving[1] };
    slot.request.cancelled = &slot.cancelled;
    slot.request.method = if (std.ascii.eqlIgnoreCase(method.bytes, "GET")) .get else if (std.ascii.eqlIgnoreCase(method.bytes, "POST")) .post else {
        rejectAndResetFetch(js, slot, "wfetch method must be GET or POST");
        return promise;
    };
    slot.request.url = std.heap.page_allocator.dupe(u8, url.bytes) catch {
        rejectAndResetFetch(js, slot, "FetchFailed: request allocation failed");
        return promise;
    };
    slot.request.body = std.heap.page_allocator.dupe(u8, body.bytes) catch {
        rejectAndResetFetch(js, slot, "FetchFailed: request allocation failed");
        return promise;
    };
    slot.request.headers = copyHeadersJson(headers_json.bytes) orelse {
        rejectAndResetFetch(js, slot, "wfetch headers must be string values without CR/LF");
        return promise;
    };
    slot.thread = std.Thread.spawn(.{}, fetchWorker, .{slot}) catch {
        rejectAndResetFetch(js, slot, "FetchFailed: could not start request worker");
        return promise;
    };
    return promise;
}

fn copyHeadersJson(source: []const u8) ?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, source, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.heap.page_allocator);
    var iterator = parsed.value.object.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* != .string) return null;
        const name = entry.key_ptr.*;
        const value = entry.value_ptr.string;
        if (name.len == 0 or std.mem.indexOfAny(u8, name, ":\r\n") != null or std.mem.indexOfAny(u8, value, "\r\n") != null) return null;
        const line = std.fmt.allocPrint(std.heap.page_allocator, "{s}: {s}\r\n", .{ name, value }) catch return null;
        defer std.heap.page_allocator.free(line);
        output.appendSlice(std.heap.page_allocator, line) catch return null;
    }
    return output.toOwnedSlice(std.heap.page_allocator) catch null;
}

fn fetchWorker(slot: *FetchSlot) void {
    slot.result = network.perform(&slot.request, std.heap.page_allocator);
    slot.done.store(true, .release);
}

fn rejectPromise(ctx: *c.JSContext, reject: c.JSValue, message: []const u8) void {
    const reason = c.JS_NewStringLen(ctx, message.ptr, message.len);
    defer c.JS_FreeValue(ctx, reason);
    var arguments = [_]c.JSValue{reason};
    const result = c.JS_Call(ctx, reject, qjs.undefinedValue(), 1, &arguments);
    c.JS_FreeValue(ctx, result);
}

fn rejectAndResetFetch(ctx: *c.JSContext, slot: *FetchSlot, message: []const u8) void {
    rejectPromise(ctx, slot.reject, message);
    c.JS_FreeValue(ctx, slot.resolve);
    c.JS_FreeValue(ctx, slot.reject);
    slot.request.deinit(std.heap.page_allocator);
    slot.* = .{};
}

pub fn hasActiveFetches(bridge_state: *const State) bool {
    for (&bridge_state.fetches) |*slot| if (slot.active) return true;
    return false;
}

/// Resolve completed worker slots on the QuickJS/main-loop thread. The SDK's
/// promise continuation enters the ordinary pending-job queue, so its state
/// update is batched by the same reconciler path as a timer or button event.
pub fn drainFetches(ctx: *c.JSContext, bridge_state: *State) void {
    for (&bridge_state.fetches) |*slot| {
        if (!slot.active or !slot.done.load(.acquire)) continue;
        if (slot.thread) |thread| thread.join();
        slot.thread = null;
        if (slot.result.failure == .none) {
            const response = c.JS_NewObject(ctx);
            _ = c.JS_SetPropertyStr(ctx, response, "status", c.JS_NewUint32(ctx, slot.result.status));
            const body = slot.result.body orelse &.{};
            _ = c.JS_SetPropertyStr(ctx, response, "body", c.JS_NewStringLen(ctx, body.ptr, body.len));
            var arguments = [_]c.JSValue{response};
            const call_result = c.JS_Call(ctx, slot.resolve, qjs.undefinedValue(), 1, &arguments);
            c.JS_FreeValue(ctx, call_result);
            c.JS_FreeValue(ctx, response);
        } else {
            rejectPromise(ctx, slot.reject, switch (slot.result.failure) {
                .invalid_url => "HttpsRequired: wfetch accepts only https:// URLs",
                .timed_out => "FetchTimeout: request exceeded 15 seconds",
                .request_too_large => "RequestTooLarge: wfetch request exceeds 5 MB",
                .response_too_large => "ResponseTooLarge: wfetch response exceeds 5 MB",
                .cancelled => "FetchCancelled: request was cancelled",
                .request_failed => "FetchFailed: request failed",
                .none => unreachable,
            });
        }
        c.JS_FreeValue(ctx, slot.resolve);
        c.JS_FreeValue(ctx, slot.reject);
        slot.request.deinit(std.heap.page_allocator);
        slot.result.deinit(std.heap.page_allocator);
        slot.* = .{};
    }
}

pub fn dispatchEvent(ctx: *c.JSContext, bridge_state: *State, node_id: tree_mod.NodeId, kind: []const u8, payload: ?f64) bool {
    if (!c.JS_IsFunction(ctx, bridge_state.event_callback)) return true;
    const kind_value = c.JS_NewStringLen(ctx, kind.ptr, kind.len);
    defer c.JS_FreeValue(ctx, kind_value);
    const payload_value = if (payload) |value| c.JS_NewFloat64(ctx, value) else qjs.nullValue();
    defer c.JS_FreeValue(ctx, payload_value);
    var arguments = [_]c.JSValue{ c.JS_NewUint32(ctx, node_id), kind_value, payload_value };
    defer c.JS_FreeValue(ctx, arguments[0]);
    const result = c.JS_Call(ctx, bridge_state.event_callback, qjs.undefinedValue(), arguments.len, &arguments);
    const succeeded = !c.JS_IsException(result);
    c.JS_FreeValue(ctx, result);
    return succeeded;
}

pub fn dispatchProvider(ctx: *c.JSContext, bridge_state: *State, line: []const u8) bool {
    if (!c.JS_IsFunction(ctx, bridge_state.provider_callback)) return true;
    const value = c.JS_NewStringLen(ctx, line.ptr, line.len);
    defer c.JS_FreeValue(ctx, value);
    var arguments = [_]c.JSValue{value};
    const result = c.JS_Call(ctx, bridge_state.provider_callback, qjs.undefinedValue(), 1, &arguments);
    const succeeded = !c.JS_IsException(result);
    c.JS_FreeValue(ctx, result);
    return succeeded;
}

fn log(ctx: ?*c.JSContext, _: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const js = ctx orelse return qjs.exceptionValue();
    if (argc != 1) return fail(js, "log expects one string");
    const value = stringArg(js, argv[0]) catch return fail(js, "log expects one string");
    defer c.JS_FreeCString(js, value.raw);
    std.log.info("widget: {s}", .{value.bytes});
    return qjs.undefinedValue();
}

fn consoleLog(ctx: ?*c.JSContext, _: c.JSValueConst, argc: c_int, argv: [*c]c.JSValueConst) callconv(.c) c.JSValue {
    const js = ctx orelse return qjs.exceptionValue();
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    var index: usize = 0;
    while (index < @as(usize, @intCast(argc))) : (index += 1) {
        if (index > 0) writer.writeByte(' ') catch break;
        var len: usize = 0;
        const raw = c.JS_ToCStringLen2(js, &len, argv[index], false) orelse continue;
        defer c.JS_FreeCString(js, raw);
        writer.writeAll(raw[0..len]) catch break;
    }
    std.log.info("widget console: {s}", .{writer.buffered()});
    return qjs.undefinedValue();
}

fn parseColor(value: []const u8) ?@import("native_sdk").canvas.Color {
    if (value.len != 9 or value[0] != '#') return null;
    const rgba = std.fmt.parseInt(u32, value[1..], 16) catch return null;
    return @import("native_sdk").canvas.Color.rgba8(@truncate(rgba >> 24), @truncate(rgba >> 16), @truncate(rgba >> 8), @truncate(rgba));
}

fn parseBoxShadow(value: []const u8) ?tree_mod.BoxShadow {
    var fields = std.mem.tokenizeScalar(u8, value, ' ');
    const x = parseShadowFloat(fields.next()) orelse return null;
    const y = parseShadowFloat(fields.next()) orelse return null;
    const blur = parseShadowFloat(fields.next()) orelse return null;
    const spread = parseShadowFloat(fields.next()) orelse return null;
    const color = parseColor(fields.next() orelse return null) orelse return null;
    if (fields.next() != null or blur < 0) return null;
    return .{ .offset = .{ .dx = x, .dy = y }, .blur = blur, .spread = spread, .color = color };
}

fn parseTextShadow(value: []const u8) ?@import("native_sdk").canvas.TextShadow {
    var fields = std.mem.tokenizeScalar(u8, value, ' ');
    const x = parseShadowFloat(fields.next()) orelse return null;
    const y = parseShadowFloat(fields.next()) orelse return null;
    const blur = parseShadowFloat(fields.next()) orelse return null;
    const color = parseColor(fields.next() orelse return null) orelse return null;
    if (fields.next() != null or blur < 0) return null;
    return .{ .offset = .{ .dx = x, .dy = y }, .blur = blur, .color = color };
}

fn parseShadowFloat(value: ?[]const u8) ?f32 {
    const number = std.fmt.parseFloat(f32, value orelse return null) catch return null;
    return if (std.math.isFinite(number)) number else null;
}

test "packed shadow properties accept bounded tuples and reject malformed values" {
    const box = parseBoxShadow("-2 3 8 -1 #11223344") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(f32, -2), box.offset.dx);
    try std.testing.expectEqual(@as(f32, 8), box.blur);
    try std.testing.expectEqual(@as(f32, -1), box.spread);
    const text_shadow = parseTextShadow("1 2 4 #AABBCCDD") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(f32, 2), text_shadow.offset.dy);
    try std.testing.expectEqual(@as(f32, 4), text_shadow.blur);
    try std.testing.expect(parseBoxShadow("0 2 -4 0 #000000FF") == null);
    try std.testing.expect(parseBoxShadow("0 2 4 #000000FF") == null);
    try std.testing.expect(parseTextShadow("0 2 4 1 #000000FF") == null);
}
