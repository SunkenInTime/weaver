const std = @import("std");
const bridge = @import("bridge.zig");
const qjs = @import("qjs.zig");
const tree_mod = @import("tree.zig");
const c = qjs.c;

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

    pub fn create(allocator: std.mem.Allocator, tree: *tree_mod.Tree) Error!*Engine {
        const self = allocator.create(Engine) catch return error.OutOfMemory;
        errdefer allocator.destroy(self);
        const runtime = c.JS_NewRuntime() orelse return error.OutOfMemory;
        errdefer c.JS_FreeRuntime(runtime);
        const context = c.JS_NewContext(runtime) orelse return error.OutOfMemory;
        errdefer c.JS_FreeContext(context);
        self.* = .{
            .runtime = runtime,
            .context = context,
            .bridge_state = .{ .tree = tree },
        };
        bridge.install(context, &self.bridge_state) catch return error.QuickJs;
        return self;
    }

    pub fn destroy(self: *Engine, allocator: std.mem.Allocator) void {
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
        const result = c.JS_Eval(self.context, terminated.ptr, source.len, file_name, c.JS_EVAL_TYPE_GLOBAL);
        defer c.JS_FreeValue(self.context, result);
        if (c.JS_IsException(result)) return self.reportException();
        try self.pumpJobs();
    }

    pub fn intervalMs(self: *const Engine) u64 {
        return self.bridge_state.interval_ms;
    }

    pub fn fireTimer(self: *Engine) Error!void {
        if (!c.JS_IsFunction(self.context, self.bridge_state.timer_callback)) return;
        const result = c.JS_Call(self.context, self.bridge_state.timer_callback, qjs.undefinedValue(), 0, null);
        defer c.JS_FreeValue(self.context, result);
        if (c.JS_IsException(result)) return self.reportException();
        try self.pumpJobs();
    }

    fn pumpJobs(self: *Engine) Error!void {
        while (true) {
            var job_context: ?*c.JSContext = null;
            const result = c.JS_ExecutePendingJob(self.runtime, &job_context);
            if (result == 0) return;
            if (result < 0) return self.reportExceptionFrom(job_context orelse self.context);
        }
    }

    fn reportException(self: *Engine) Error {
        return self.reportExceptionFrom(self.context);
    }

    fn reportExceptionFrom(_: *Engine, context: *c.JSContext) Error {
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
        return error.ScriptException;
    }
};
