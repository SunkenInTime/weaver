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
    armed_timers: [bridgeTimerCapacity()]ArmedTimer = [_]ArmedTimer{.{}} ** bridgeTimerCapacity(),
};

const ArmedTimer = struct { id: u64 = 0, interval_ms: u64 = 0 };
fn bridgeTimerCapacity() usize { return @import("bridge.zig").max_timers; }

pub const Msg = union(enum) {
    timer: native_sdk.EffectTimer,
};

const WidgetApp = native_sdk.UiAppWithFeatures(Model, Msg, .{ .runtime_markup = false });
const WidgetUi = WidgetApp.Ui;
const Effects = WidgetApp.Effects;
var rendered_presents: u64 = 0;
var first_render_ns: u64 = 0;
var last_canvas_revision: u64 = 0;

fn initEffects(model: *Model, effects: *Effects) void {
    syncTimers(model, effects);
}

/// One SDK timer delivery is one JS batch. All retained-tree ops complete
/// before update returns, after which UiApp derives and presents once.
fn update(model: *Model, msg: Msg, effects: *Effects) void {
    switch (msg) {
        .timer => |timer| {
            if (timer.outcome != .fired) {
                std.log.err("widget timer was rejected", .{});
                return;
            }
            const before = model.tree.generation;
            (model.engine orelse return).fireTimer(timer.key) catch |err| {
                std.log.err("widget timer callback failed: {s}", .{@errorName(err)});
                return;
            };
            syncTimers(model, effects);
            model.timer_fires += 1;
            if (model.timer_fires % 10 == 0) {
                std.log.info("widget timer: {d} callbacks, generation {d}, changed={}", .{ model.timer_fires, model.tree.generation, before != model.tree.generation });
            }
        },
    }
}

fn syncTimers(model: *Model, effects: *Effects) void {
    const engine = model.engine orelse return;
    for (&model.armed_timers) |*armed| {
        if (armed.id == 0) continue;
        var live = false;
        for (engine.timers()) |timer| {
            if (timer.active and timer.id == armed.id) {
                live = true;
                break;
            }
        }
        if (!live) {
            effects.cancelTimer(armed.id);
            armed.* = .{};
        }
    }
    for (engine.timers()) |timer| {
        if (!timer.active) continue;
        var slot: ?*ArmedTimer = null;
        for (&model.armed_timers) |*armed| {
            if (armed.id == timer.id) {
                slot = armed;
                break;
            }
            if (slot == null and armed.id == 0) slot = armed;
        }
        const armed = slot orelse continue;
        if (armed.id == timer.id and armed.interval_ms == timer.interval_ms) continue;
        effects.startTimer(.{
            .key = timer.id,
            .interval_ms = timer.interval_ms,
            .mode = .repeating,
            .on_fire = Effects.timerMsg(.timer),
        });
        armed.* = .{ .id = timer.id, .interval_ms = timer.interval_ms };
    }
}

fn onFrame(_: *const Model, frame: native_sdk.platform.GpuFrame) ?Msg {
    // A present completion produces a second frame event carrying the same
    // retained-canvas revision. M0 counted both events as presents; revision
    // edges identify actual newly rendered display lists at this callback.
    if (frame.canvas_revision == 0 or frame.canvas_revision == last_canvas_revision) return null;
    last_canvas_revision = frame.canvas_revision;
    if (first_render_ns == 0) first_render_ns = frame.timestamp_ns;
    rendered_presents += 1;
    if (rendered_presents % 10 == 0) {
        const elapsed_ns = frame.timestamp_ns -| first_render_ns;
        std.log.info("widget present: {d} rendered frames in {d} ms", .{ rendered_presents, elapsed_ns / std.time.ns_per_ms });
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
        .grow = retained.grow,
        .width = retained.width,
        .height = retained.height,
        .cross = switch (retained.cross_align) {
            .start => .start,
            .center => .center,
            .end, .baseline => .end,
        },
        .main = switch (retained.main_align) {
            .start => .start,
            .center => .center,
            .end => .end,
            .between => .space_between,
        },
        .style = .{
            .background = retained.background,
            .foreground = retained.text_color,
            .radius = if (retained.radius > 0) retained.radius else null,
            .quiet_hover = true,
        },
    };
    if (retained.kind == .text) {
        options.wrap = false;
        options.overflow = if (retained.truncate) .ellipsis else .clip;
        const span = [_]native_sdk.canvas.TextSpan{.{
            .text = retained.textSlice(),
            .weight = switch (retained.font_weight) {
                .light, .regular => .regular,
                .medium => .medium,
                .semibold, .bold => .bold,
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
        // SDK layout-only rows/columns do not paint their own style. A
        // styled column is contractually a column-layout box, which is the
        // builder's panel primitive; unstyled columns keep the lean node.
        // A styled row gets the same painting panel around its row layout.
        .column => if (retained.background != null) block: {
            const column_options: WidgetUi.ElementOptions = .{
                .gap = retained.gap,
                .grow = 1,
                .cross = options.cross,
                .main = options.main,
            };
            options.gap = 0;
            break :block ui.panel(options, .{ui.column(column_options, children)});
        } else ui.column(options, children),
        .row => if (retained.background != null) block: {
            const row_options: WidgetUi.ElementOptions = .{
                .gap = retained.gap,
                .grow = 1,
                .cross = options.cross,
                .main = options.main,
            };
            options.gap = 0;
            break :block ui.panel(options, .{ui.row(row_options, children)});
        } else ui.row(options, children),
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
        .layer = if (std.mem.eql(u8, loaded.manifest.layer, "desktop")) .bottom else if (std.mem.eql(u8, loaded.manifest.layer, "topmost")) .topmost else .normal,
        .click_through = loaded.manifest.clickThrough,
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
