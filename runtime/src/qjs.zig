pub const c = @cImport({
    @cInclude("quickjs.h");
});

/// Zig 0.16's translate-c cannot default-initialize QuickJS's tagged union
/// while expanding JS_MKVAL. Construct the two sentinels explicitly instead.
pub fn undefinedValue() c.JSValue {
    return .{ .u = .{ .int32 = 0 }, .tag = c.JS_TAG_UNDEFINED };
}

pub fn exceptionValue() c.JSValue {
    return .{ .u = .{ .int32 = 0 }, .tag = c.JS_TAG_EXCEPTION };
}
