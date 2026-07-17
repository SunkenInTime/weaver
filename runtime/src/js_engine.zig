const std = @import("std");
const bridge = @import("bridge.zig");
const platform = @import("platform/root.zig");
const qjs = @import("qjs.zig");
const provider_mod = @import("provider.zig");
const tree_mod = @import("tree.zig");
const storage_mod = @import("storage.zig");
const c = qjs.c;

pub const memory_limit_bytes: usize = 32 * 1024 * 1024;
pub const turn_budget_ms: u64 = 100;

pub const Error = error{
    OutOfMemory,
    QuickJs,
    ScriptException,
};

/// A single-widget QuickJS isolate. It runs only when the Native SDK main loop
/// enters `fireTimer`; no JS thread, OS timer, or hidden render loop exists.
pub const Engine = struct {
    runtime: *c.JSRuntime,
    context: *c.JSContext,
    bridge_state: bridge.State,
    provider: *provider_mod.Client,
    deadline_ms: u64 = 0,
    executing: bool = false,

    pub fn create(allocator: std.mem.Allocator, tree: *tree_mod.Tree, storage: *storage_mod.Store, origins: []const []const u8, provider: *provider_mod.Client) !*Engine {
        const self = allocator.create(Engine) catch return error.OutOfMemory;
        errdefer allocator.destroy(self);
        const runtime = c.JS_NewRuntime() orelse return error.OutOfMemory;
        errdefer c.JS_FreeRuntime(runtime);
        const context = c.JS_NewContext(runtime) orelse return error.OutOfMemory;
        errdefer c.JS_FreeContext(context);
        self.* = .{
            .runtime = runtime,
            .context = context,
            .bridge_state = undefined,
            .provider = provider,
        };
        self.bridge_state = .{ .tree = tree, .storage = storage, .provider = provider, .origins = origins };
        c.JS_SetMemoryLimit(runtime, memory_limit_bytes);
        c.JS_SetInterruptHandler(runtime, interruptHandler, self);
        bridge.install(context, &self.bridge_state) catch return error.QuickJs;
        return self;
    }

    pub fn destroy(self: *Engine, allocator: std.mem.Allocator) void {
        self.flushStorage();
        bridge.deinit(self.context, &self.bridge_state);
        c.JS_FreeContext(self.context);
        c.JS_FreeRuntime(self.runtime);
        allocator.destroy(self);
    }

    pub fn evaluate(self: *Engine, source: []const u8, file_name: [*:0]const u8) Error!void {
        // The parser accepts a length but still uses one sentinel byte for
        // its end token. Widget files come from readFileAlloc, whose spare
        // capacity is not initialized, so make that byte explicit.
        const terminated = std.heap.page_allocator.dupeZ(u8, source) catch return error.OutOfMemory;
        defer std.heap.page_allocator.free(terminated);
        self.beginTurn();
        defer self.endTurn();
        const result = c.JS_Eval(self.context, terminated.ptr, source.len, file_name, c.JS_EVAL_TYPE_GLOBAL);
        defer c.JS_FreeValue(self.context, result);
        if (c.JS_IsException(result)) return self.reportException();
        try self.pumpJobs();
    }

    pub fn timers(self: *const Engine) []const bridge.TimerSlot {
        return &self.bridge_state.timers;
    }

    pub fn setTree(self: *Engine, tree: *tree_mod.Tree) void {
        self.bridge_state.tree = tree;
    }

    pub fn setHotSwapSeed(self: *Engine, seed: []const u8) Error!void {
        const global = c.JS_GetGlobalObject(self.context);
        defer c.JS_FreeValue(self.context, global);
        const value = c.JS_NewStringLen(self.context, seed.ptr, seed.len);
        if (c.JS_IsException(value) or c.JS_SetPropertyStr(self.context, global, "__weaverHotSwapSeed", value) < 0) return error.QuickJs;
    }

    pub fn captureHotSwap(self: *Engine, allocator: std.mem.Allocator) ?[]u8 {
        const result = self.callGlobal("__weaverCaptureHotSwap") catch return null;
        defer c.JS_FreeValue(self.context, result);
        if (!c.JS_IsString(result)) return null;
        var len: usize = 0;
        const raw = c.JS_ToCStringLen2(self.context, &len, result, false) orelse return null;
        defer c.JS_FreeCString(self.context, raw);
        return allocator.dupe(u8, raw[0..len]) catch null;
    }

    pub fn hotSwapAccepted(self: *Engine) bool {
        const result = self.callGlobal("__weaverHotSwapAccepted") catch return false;
        defer c.JS_FreeValue(self.context, result);
        return c.JS_ToBool(self.context, result) == 1;
    }

    pub fn fireTimer(self: *Engine, timer_id: u64, timestamp_ns: u64) Error!void {
        const timer = for (&self.bridge_state.timers) |*candidate| {
            if (candidate.active and candidate.id == timer_id) break candidate;
        } else return;
        if (!c.JS_IsFunction(self.context, timer.callback)) return;
        self.beginTurn();
        defer self.endTurn();
        const timestamp = c.JS_NewFloat64(self.context, @as(f64, @floatFromInt(timestamp_ns)) / @as(f64, std.time.ns_per_s));
        defer c.JS_FreeValue(self.context, timestamp);
        var arguments = [_]c.JSValue{timestamp};
        const result = c.JS_Call(self.context, timer.callback, qjs.undefinedValue(), arguments.len, &arguments);
        defer c.JS_FreeValue(self.context, result);
        if (c.JS_IsException(result)) return self.reportException();
        try self.pumpJobs();
    }

    pub fn fireEvent(self: *Engine, node_id: tree_mod.NodeId, kind: []const u8, payload: ?f64) Error!void {
        self.beginTurn();
        defer self.endTurn();
        if (!bridge.dispatchEvent(self.context, &self.bridge_state, node_id, kind, payload)) return self.reportException();
        try self.pumpJobs();
    }

    pub fn hasCanvasFrames(self: *const Engine) bool {
        return bridge.hasCanvasFrames(&self.bridge_state);
    }

    pub fn fireCanvasFrames(self: *Engine, timestamp_ns: u64) Error!void {
        self.beginTurn();
        defer self.endTurn();
        if (!bridge.dispatchCanvasFrames(self.context, &self.bridge_state, timestamp_ns)) return self.reportException();
        try self.pumpJobs();
    }

    pub fn hasActiveFetches(self: *const Engine) bool {
        return bridge.hasActiveFetches(&self.bridge_state);
    }

    pub fn drainFetches(self: *Engine) Error!void {
        self.beginTurn();
        defer self.endTurn();
        bridge.drainFetches(self.context, &self.bridge_state);
        try self.pumpJobs();
    }

    pub fn hasHostProvider(self: *const Engine) bool {
        return self.provider.available;
    }

    pub fn drainProviders(self: *Engine) Error!usize {
        self.beginTurn();
        defer self.endTurn();
        var line_buffer: [8192]u8 = undefined;
        var count: usize = 0;
        while (self.provider.take(&line_buffer)) |line| {
            if (!bridge.dispatchProvider(self.context, &self.bridge_state, line)) return self.reportException();
            count += 1;
        }
        try self.pumpJobs();
        return count;
    }

    fn pumpJobs(self: *Engine) Error!void {
        while (true) {
            var job_context: ?*c.JSContext = null;
            const result = c.JS_ExecutePendingJob(self.runtime, &job_context);
            if (result == 0) return;
            if (result < 0) return self.reportExceptionFrom(job_context orelse self.context);
        }
    }

    fn callGlobal(self: *Engine, name: [*:0]const u8) Error!c.JSValue {
        self.beginTurn();
        defer self.endTurn();
        const global = c.JS_GetGlobalObject(self.context);
        defer c.JS_FreeValue(self.context, global);
        const callback = c.JS_GetPropertyStr(self.context, global, name);
        defer c.JS_FreeValue(self.context, callback);
        if (!c.JS_IsFunction(self.context, callback)) return error.QuickJs;
        const result = c.JS_Call(self.context, callback, qjs.undefinedValue(), 0, null);
        if (c.JS_IsException(result)) {
            c.JS_FreeValue(self.context, result);
            return self.reportException();
        }
        return result;
    }

    fn beginTurn(self: *Engine) void {
        self.deadline_ms = platform.monotonicMilliseconds() + turn_budget_ms;
        self.executing = true;
    }

    fn endTurn(self: *Engine) void {
        self.executing = false;
    }

    /// SDK storage normally flushes on its 200 ms native debounce. A clean
    /// window close gets one final synchronous hook. weaverd posts WM_CLOSE
    /// before its bounded termination fallback, so ordinary dev restarts,
    /// uninstall, and host shutdown all take this path; only a crashed or
    /// externally force-killed widget relies on the completed debounce.
    fn flushStorage(self: *Engine) void {
        const global = c.JS_GetGlobalObject(self.context);
        defer c.JS_FreeValue(self.context, global);
        const callback = c.JS_GetPropertyStr(self.context, global, "__weaverFlushStorage");
        defer c.JS_FreeValue(self.context, callback);
        if (!c.JS_IsFunction(self.context, callback)) return;
        const result = c.JS_Call(self.context, callback, qjs.undefinedValue(), 0, null);
        defer c.JS_FreeValue(self.context, result);
        if (c.JS_IsException(result)) logExceptionFrom(self.context);
    }

    fn reportException(self: *Engine) Error {
        return self.reportExceptionFrom(self.context);
    }

    fn reportExceptionFrom(_: *Engine, context: *c.JSContext) Error {
        logExceptionFrom(context);
        return error.ScriptException;
    }
};

fn logExceptionFrom(context: *c.JSContext) void {
    const exception = c.JS_GetException(context);
    defer c.JS_FreeValue(context, exception);
    var len: usize = 0;
    const raw = c.JS_ToCStringLen2(context, &len, exception, false);
    if (raw) |text| {
        defer c.JS_FreeCString(context, text);
        std.log.err("widget JavaScript exception: {s}", .{text[0..len]});
    } else {
        std.log.err("widget JavaScript exception", .{});
    }
}

fn interruptHandler(_: ?*c.JSRuntime, context: ?*anyopaque) callconv(.c) c_int {
    const self: *Engine = @ptrCast(@alignCast(context orelse return 1));
    return if (self.executing and platform.monotonicMilliseconds() >= self.deadline_ms) 1 else 0;
}
