const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");
const js_engine = @import("js_engine.zig");
const manifest_mod = @import("manifest.zig");
const tree_mod = @import("tree.zig");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

pub const Model = struct {
    tree: tree_mod.Tree = .{},
    engine: ?*js_engine.Engine = null,
    timer_fires: u64 = 0,
};

pub const Msg = union(enum) {
    timer: native_sdk.EffectTimer,
};

const WidgetApp = native_sdk.UiAppWithFeatures(Model, Msg, .{ .runtime_markup = false });
const WidgetUi = WidgetApp.Ui;
const Effects = WidgetApp.Effects;
var presented_frames: u64 = 0;
var first_present_ns: u64 = 0;

fn initEffects(model: *Model, effects: *Effects) void {
    const engine = model.engine orelse return;
    const interval_ms = engine.intervalMs();
    if (interval_ms == 0) return;
    effects.startTimer(.{
        .key = 1,
        .interval_ms = interval_ms,
        .mode = .repeating,
        .on_fire = Effects.timerMsg(.timer),
    });
}

/// One SDK timer delivery is one JS batch. All retained-tree ops complete
/// before update returns, after which UiApp derives and presents once.
fn update(model: *Model, msg: Msg, _: *Effects) void {
    switch (msg) {
        .timer => |timer| {
            if (timer.outcome != .fired) {
                std.log.err("widget timer was rejected", .{});
                return;
            }
            const before = model.tree.generation;
            (model.engine orelse return).fireTimer() catch |err| {
                std.log.err("widget timer callback failed: {s}", .{@errorName(err)});
                return;
            };
            model.timer_fires += 1;
            if (model.timer_fires % 10 == 0) {
                std.log.info("widget timer: {d} callbacks, generation {d}, changed={}", .{ model.timer_fires, model.tree.generation, before != model.tree.generation });
            }
        },
    }
}

fn onFrame(_: *const Model, frame: native_sdk.platform.GpuFrame) ?Msg {
    if (first_present_ns == 0) first_present_ns = frame.timestamp_ns;
    presented_frames += 1;
    if (presented_frames % 10 == 0) {
        const elapsed_ns = frame.timestamp_ns -| first_present_ns;
        std.log.info("widget present: {d} frames in {d} ms", .{ presented_frames, elapsed_ns / std.time.ns_per_ms });
    }
    return null;
}

fn view(ui: *WidgetUi, model: *const Model) WidgetUi.Node {
    const root_id = model.tree.root orelse return ui.panel(.{}, .{});
    return buildNode(ui, &model.tree, root_id);
}

fn buildNode(ui: *WidgetUi, tree: *const tree_mod.Tree, id: tree_mod.NodeId) WidgetUi.Node {
    const retained = tree.nodeConst(id) catch return ui.panel(.{}, .{});
    var options: WidgetUi.ElementOptions = .{
        .padding = retained.padding,
        .gap = retained.gap,
        .opacity = retained.opacity,
        .style = .{
            .background = retained.background,
            .radius = if (retained.radius > 0) retained.radius else null,
            .quiet_hover = true,
        },
    };
    if (retained.kind == .panel) options.grow = 1;
    if (retained.kind == .text) {
        const span = [_]native_sdk.canvas.TextSpan{.{
            .text = retained.textSlice(),
            .weight = switch (retained.font_weight) {
                .regular => .regular,
                .medium => .medium,
                .bold => .bold,
            },
            .scale = retained.font_scale,
        }};
        return ui.paragraph(options, &span);
    }
    const children = ui.arena.alloc(WidgetUi.Node, retained.child_count) catch return ui.panel(.{}, .{});
    for (retained.children[0..retained.child_count], 0..) |child_id, index| {
        children[index] = buildNode(ui, tree, child_id);
    }
    return switch (retained.kind) {
        .column => ui.column(options, children),
        .row => ui.row(options, children),
        .panel => ui.panel(options, children),
        .text => unreachable,
    };
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 2) {
        std.debug.print("usage: weaver-widget.exe <widget-directory>\n", .{});
        return error.InvalidArguments;
    }
    const loaded = try manifest_mod.load(init.io, allocator, args[1]);
    const frame = manifest_mod.desktopFrame(loaded.manifest);
    const shell_views = [_]native_sdk.ShellView{.{
        .label = "widget-canvas",
        .kind = .gpu_surface,
        .fill = true,
        .role = "Weaver widget canvas",
        .accessibility_label = loaded.manifest.name,
        .gpu_backend = .software,
        .gpu_pixel_format = .bgra8_unorm,
        .gpu_present_mode = .timer,
        .gpu_alpha_mode = .premultiplied,
        .gpu_color_space = .srgb,
        .gpu_vsync = true,
    }};
    const shell_windows = [_]native_sdk.ShellWindow{.{
        .label = "main",
        .title = loaded.manifest.name,
        .width = loaded.manifest.size[0],
        .height = loaded.manifest.size[1],
        .x = frame.x,
        .y = frame.y,
        .resizable = false,
        .restore_state = false,
        .titlebar = .chromeless,
        .transparent = true,
        .layer = .bottom,
        .click_through = false,
        .no_activate = true,
        .views = &shell_views,
    }};
    const scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

    var tokens = native_sdk.canvas.DesignTokens.theme(.{ .pack = .geist, .color_scheme = .dark });
    tokens.colors.background = native_sdk.canvas.Color.rgba8(0, 0, 0, 0);
    const app_state = try WidgetApp.create(std.heap.page_allocator, .{
        .name = loaded.manifest.name,
        .scene = scene,
        .canvas_label = "widget-canvas",
        .tokens = tokens,
        .update_fx = update,
        .init_fx = initEffects,
        .view = view,
        .on_frame = onFrame,
    });
    defer app_state.destroy();
    const engine = try js_engine.Engine.create(std.heap.page_allocator, &app_state.model.tree);
    defer engine.destroy(std.heap.page_allocator);
    app_state.model.engine = engine;
    try engine.evaluate(loaded.bundle, "bundle.js");

    try runner.runWithOptions(app_state.app(), .{
        .app_name = "weaver-widget",
        .window_title = loaded.manifest.name,
        .bundle_id = "com.weaver.widget",
        .default_frame = frame,
        .restore_state = false,
        .js_window_api = false,
    }, init);
}

test {
    _ = @import("tree.zig");
    _ = @import("manifest.zig");
}
