const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");
const js_engine = @import("js_engine.zig");
const manifest_mod = @import("manifest.zig");
const provider_mod = @import("provider.zig");
const platform = @import("platform/root.zig");
const storage_mod = @import("storage.zig");
const tree_mod = @import("tree.zig");
const widget_log = @import("widget_log.zig");

comptime {
    if (native_sdk.platform.max_windows != 1 or
        native_sdk.platform.max_views != 1 or
        native_sdk.platform.max_webviews != 1 or
        native_sdk.runtime.max_canvas_commands_per_view != 128 or
        native_sdk.runtime.max_canvas_path_elements_per_view != 256 or
        native_sdk.runtime.max_canvas_widget_nodes_per_view != 128)
    {
        @compileError("Weaver runtime must be built with the Native SDK widget profile");
    }
}

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);
pub const std_options: std.Options = .{ .logFn = widget_log.logFn };

pub const Model = struct {
    tree: tree_mod.Tree = .{},
    engine: ?*js_engine.Engine = null,
    provider: provider_mod.Client = .{},
    io: ?std.Io = null,
    storage: ?*storage_mod.Store = null,
    origins: []const []const u8 = &.{},
    bundle_path: []const u8 = &.{},
    dev: bool = false,
    dev_seen_mtime: i128 = 0,
    timer_fires: u64 = 0,
    armed_timers: [bridgeTimerCapacity()]ArmedTimer = [_]ArmedTimer{.{}} ** bridgeTimerCapacity(),
    fetch_poll_armed: bool = false,
    provider_poll_armed: bool = false,
    provider_poll_interval_ms: u64 = 1000,
    slider_values: [tree_mod.max_nodes]f32 = @splat(0),
    images: [max_images]ImageAsset = [_]ImageAsset{.{}} ** max_images,
    image_count: usize = 0,
};

const ArmedTimer = struct { id: u64 = 0, interval_ms: u64 = 0 };
fn bridgeTimerCapacity() usize {
    return @import("bridge.zig").max_timers;
}
const max_images: usize = 16;
const fetch_poll_key: u64 = 0x7766_6574_6368;
const provider_poll_key: u64 = 0x7770_726f_7669;
const dev_reload_key: u64 = 0x7764_6576_726c;
const ImageAsset = struct { id: u64 = 0, bytes: []const u8 = &.{} };

pub const Msg = union(enum) {
    timer: native_sdk.EffectTimer,
    press: tree_mod.NodeId,
    slider: tree_mod.NodeId,
    canvas_frame: u64,
};

const WidgetApp = native_sdk.UiAppWithFeatures(Model, Msg, .{ .runtime_markup = false });
const WidgetUi = WidgetApp.Ui;
const Effects = WidgetApp.Effects;
var rendered_presents: u64 = 0;
var first_render_ns: u64 = 0;
var logged_backend: bool = false;
var logged_present_path: bool = false;
var last_backend: native_sdk.platform.GpuSurfaceBackend = .none;
var requested_software_backend: bool = false;
var diagnostic_runtime: ?*native_sdk.Runtime = null;

fn initEffects(model: *Model, effects: *Effects) void {
    for (model.images[0..model.image_count]) |image| {
        _ = effects.registerImageBytes(image.id, image.bytes) catch |err| {
            std.log.err("widget image {d} failed to decode/register: {s}", .{ image.id, @errorName(err) });
        };
    }
    if (model.dev) effects.startTimer(.{
        .key = dev_reload_key,
        .interval_ms = 100,
        .mode = .repeating,
        .on_fire = Effects.timerMsg(.timer),
    });
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
            if (timer.key == dev_reload_key) {
                reloadIfChanged(model, effects) catch |err| {
                    std.log.err("dev hot swap failed; keeping previous bundle: {s}", .{@errorName(err)});
                };
                return;
            }
            if (timer.key == fetch_poll_key) {
                (model.engine orelse return).drainFetches() catch |err| {
                    std.log.err("widget fetch completion failed: {s}", .{@errorName(err)});
                };
                syncTimers(model, effects);
                return;
            }
            if (timer.key == provider_poll_key) {
                (model.engine orelse return).drainProviders() catch |err| {
                    std.log.err("widget provider dispatch failed: {s}", .{@errorName(err)});
                };
                syncTimers(model, effects);
                return;
            }
            if (model.provider_poll_interval_ms <= 33) {
                (model.engine orelse return).drainProviders() catch |err| {
                    std.log.err("widget provider dispatch failed: {s}", .{@errorName(err)});
                };
            }
            const before = model.tree.generation;
            (model.engine orelse return).fireTimer(timer.key, timer.timestamp_ns) catch |err| {
                std.log.err("widget timer callback failed: {s}", .{@errorName(err)});
                return;
            };
            syncTimers(model, effects);
            model.timer_fires += 1;
            if (model.timer_fires % 300 == 0) {
                std.log.info("widget timer: {d} callbacks, generation {d}, changed={}", .{ model.timer_fires, model.tree.generation, before != model.tree.generation });
            }
        },
        .press => |id| {
            (model.engine orelse return).fireEvent(id, "press", null) catch |err| {
                std.log.err("widget press callback failed: {s}", .{@errorName(err)});
            };
            syncTimers(model, effects);
        },
        .slider => |id| {
            const value = model.slider_values[id - 1];
            (model.engine orelse return).fireEvent(id, "change", value) catch |err| {
                std.log.err("widget slider callback failed: {s}", .{@errorName(err)});
            };
            syncTimers(model, effects);
        },
        .canvas_frame => |timestamp_ns| {
            if (model.provider_poll_interval_ms <= 33) {
                (model.engine orelse return).drainProviders() catch |err| {
                    std.log.err("widget provider dispatch failed: {s}", .{@errorName(err)});
                };
            }
            (model.engine orelse return).fireCanvasFrames(timestamp_ns) catch |err| {
                std.log.err("widget canvas frame callback failed: {s}", .{@errorName(err)});
            };
            syncTimers(model, effects);
        },
    }
}

fn reloadIfChanged(model: *Model, effects: *Effects) !void {
    const io = model.io orelse return;
    const stat = try std.Io.Dir.cwd().statFile(io, model.bundle_path, .{});
    const mtime = stat.mtime.nanoseconds;
    if (mtime == model.dev_seen_mtime) return;
    model.dev_seen_mtime = mtime;

    const source = try std.Io.Dir.cwd().readFileAlloc(io, model.bundle_path, std.heap.page_allocator, .limited(1024 * 1024));
    defer std.heap.page_allocator.free(source);
    const old_engine = model.engine orelse return error.MissingEngine;
    const snapshot = old_engine.captureHotSwap(std.heap.page_allocator);
    defer if (snapshot) |bytes| std.heap.page_allocator.free(bytes);

    var candidate_tree: tree_mod.Tree = .{};
    var preserved = snapshot != null;
    const candidate = evaluateCandidate(model, &candidate_tree, source, snapshot) catch |err| switch (err) {
        error.HotSwapMismatch => block: {
            preserved = false;
            candidate_tree = .{};
            break :block try evaluateCandidate(model, &candidate_tree, source, null);
        },
        else => return err,
    };
    candidate_tree.generation = model.tree.generation +% 1;
    model.tree = candidate_tree;
    candidate.setTree(&model.tree);
    model.engine = candidate;
    old_engine.destroy(std.heap.page_allocator);
    syncTimers(model, effects);
    std.log.info("dev hot swap applied ({s} root hook state)", .{if (preserved) "preserved" else "fresh"});
}

fn evaluateCandidate(model: *Model, tree: *tree_mod.Tree, source: []const u8, seed: ?[]const u8) !*js_engine.Engine {
    const storage = model.storage orelse return error.MissingStorage;
    const candidate = try js_engine.Engine.create(std.heap.page_allocator, tree, storage, model.origins, &model.provider);
    errdefer candidate.destroy(std.heap.page_allocator);
    if (seed) |value| try candidate.setHotSwapSeed(value);
    try candidate.evaluate(source, "bundle.js");
    if (seed != null and !candidate.hotSwapAccepted()) return error.HotSwapMismatch;
    return candidate;
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
    if (engine.hasActiveFetches() and !model.fetch_poll_armed) {
        effects.startTimer(.{
            .key = fetch_poll_key,
            .interval_ms = 25,
            .mode = .repeating,
            .on_fire = Effects.timerMsg(.timer),
        });
        model.fetch_poll_armed = true;
    } else if (!engine.hasActiveFetches() and model.fetch_poll_armed) {
        effects.cancelTimer(fetch_poll_key);
        model.fetch_poll_armed = false;
    }
    var has_fast_clock = engine.hasCanvasFrames();
    if (!has_fast_clock) for (engine.timers()) |timer| {
        if (timer.active and timer.interval_ms <= 40) {
            has_fast_clock = true;
            break;
        }
    };
    const needs_provider_timer = engine.hasHostProvider() and !(model.provider_poll_interval_ms <= 33 and has_fast_clock);
    // Audio providers need a low-latency drain while a canvas is active, but
    // silence deliberately stops that clock. Polling the empty pipe ring at
    // 30 Hz was the measured 3.75-4.48% hosted-idle residual. A 1 Hz resume
    // probe makes silence effectively idle; the first resumed frame re-arms
    // the canvas clock and provider delivery returns to its 30 Hz path.
    const provider_interval_ms = if (model.provider_poll_interval_ms <= 33 and !has_fast_clock) @as(u64, 1000) else model.provider_poll_interval_ms;
    if (needs_provider_timer and !model.provider_poll_armed) {
        effects.startTimer(.{
            .key = provider_poll_key,
            .interval_ms = provider_interval_ms,
            .mode = .repeating,
            .on_fire = Effects.timerMsg(.timer),
        });
        model.provider_poll_armed = true;
    } else if (!needs_provider_timer and model.provider_poll_armed) {
        effects.cancelTimer(provider_poll_key);
        model.provider_poll_armed = false;
    }
}

/// The fork owns a slider's optimistic drag value until dispatch. Stable
/// global keys make its layout id computable from the retained node id, so the
/// sync hook maps every concurrent slider back without closures or fork code.
fn syncNativeState(model: *Model, layout: native_sdk.canvas.WidgetLayoutTree) void {
    for (&model.tree.nodes, 0..) |*node, index| {
        if (!node.alive or node.kind != .slider) continue;
        const id: tree_mod.NodeId = @intCast(index + 1);
        const widget_id = native_sdk.canvas.globalWidgetId(.slider, .{ .int = id });
        for (layout.nodes) |layout_node| {
            if (layout_node.widget.id != widget_id) continue;
            model.slider_values[index] = layout_node.widget.value * node.max;
            break;
        }
    }
}

fn onFrame(model: *const Model, frame: native_sdk.platform.GpuFrame) ?Msg {
    if (!logged_backend) {
        logged_backend = true;
        std.log.info("widget host surface backend={s}", .{@tagName(frame.backend)});
    } else if (frame.backend != last_backend) {
        if (last_backend == .d3d11 and frame.backend == .software) {
            std.log.warn("widget renderer demoted d3d11 -> software", .{});
        } else if (last_backend == .software and frame.backend == .d3d11) {
            std.log.info("widget renderer promoted software -> d3d11", .{});
        } else {
            std.log.info("widget renderer backend changed {s} -> {s}", .{ @tagName(last_backend), @tagName(frame.backend) });
        }
    }
    last_backend = frame.backend;
    if (!logged_present_path) {
        if (diagnostic_runtime) |runtime| {
            var view_buffer: [1]native_sdk.platform.ViewInfo = undefined;
            for (runtime.listViews(frame.window_id, &view_buffer)) |view_info| {
                if (!std.mem.eql(u8, view_info.label, frame.label)) continue;
                logged_present_path = true;
                std.log.info("widget presenter path={s}", .{@tagName(view_info.gpu_present_path)});
            }
        }
    }
    const engine = model.engine orelse return null;
    const canvas_clock = engine.hasCanvasFrames();
    if (!canvas_clock) return null;
    // Hybrid presentation now rejects a clean completion revision before it
    // reaches the renderer. The completion event itself is the 60 Hz canvas
    // clock, so do not suppress it by comparing the pre-present revision in
    // the platform event; doing so parks max-rate canvases after frame one.
    if (first_render_ns == 0) first_render_ns = frame.timestamp_ns;
    rendered_presents += 1;
    if (rendered_presents % 300 == 0) {
        const elapsed_ns = frame.timestamp_ns -| first_render_ns;
        std.log.info("widget present: {d} rendered frames in {d} ms", .{ rendered_presents, elapsed_ns / std.time.ns_per_ms });
    }
    return Msg{ .canvas_frame = frame.timestamp_ns };
}

fn view(ui: *WidgetUi, model: *const Model) WidgetUi.Node {
    const root_id = model.tree.root orelse return ui.panel(.{}, .{});
    return buildNode(ui, &model.tree, root_id);
}

fn buildNode(ui: *WidgetUi, tree: *const tree_mod.Tree, id: tree_mod.NodeId) WidgetUi.Node {
    const retained = tree.nodeConst(id) catch return ui.panel(.{}, .{});
    var options: WidgetUi.ElementOptions = .{
        .global_key = .{ .int = id },
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
        .on_press = if (retained.handles_press) Msg{ .press = id } else null,
        .on_change = if (retained.handles_change) Msg{ .slider = id } else null,
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
        .button => ui.panel(options, children),
        .slider => ui.el(.slider, block: {
            options.value = std.math.clamp(retained.value / retained.max, 0, 1);
            break :block options;
        }, .{}),
        .image => block: {
            options.image = id;
            break :block ui.image(options);
        },
        .canvas => ui.immediateCanvas(options, (tree.canvasStateConst(id) catch return ui.panel(.{}, .{})).slice()),
        .text => unreachable,
    };
}

fn loadLocalImages(io: std.Io, allocator: std.mem.Allocator, directory: []const u8, model: *Model) !void {
    for (&model.tree.nodes, 0..) |*node, index| {
        if (!node.alive or node.kind != .image) continue;
        const source = node.sourceSlice();
        if (!isLocalAssetPath(source)) {
            std.log.err("RemoteImageUnsupported: <image> remote sources arrive in M3; use a local widget path", .{});
            return error.RemoteImageUnsupported;
        }
        if (model.image_count == max_images) return error.TooManyImages;
        const relative = if (std.mem.startsWith(u8, source, "./") or std.mem.startsWith(u8, source, ".\\")) source[2..] else source;
        const path = try std.fs.path.join(allocator, &.{ directory, relative });
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
        model.images[model.image_count] = .{ .id = @intCast(index + 1), .bytes = bytes };
        model.image_count += 1;
    }
}

fn isLocalAssetPath(source: []const u8) bool {
    if (source.len == 0 or std.fs.path.isAbsolute(source) or std.mem.indexOf(u8, source, "://") != null) return false;
    var components = std.mem.tokenizeAny(u8, source, "/\\");
    while (components.next()) |component| if (std.mem.eql(u8, component, "..")) return false;
    return true;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    const dev = args.len == 3 and std.mem.eql(u8, args[1], "--dev");
    if ((!dev and args.len != 2) or (dev and args.len != 3)) {
        std.debug.print("usage: weaver-widget [--dev] <widget-directory>\n", .{});
        return error.InvalidArguments;
    }
    const directory = args[if (dev) 2 else 1];
    const loaded = try manifest_mod.load(init.io, allocator, directory);
    const local_app_data = init.environ_map.get("LOCALAPPDATA");
    const home = init.environ_map.get("HOME");
    const data_root = try platform.dataRoot(allocator, local_app_data, home);
    const log_directory = try platform.logsRoot(allocator, local_app_data, home);
    try std.Io.Dir.cwd().createDirPath(init.io, log_directory);
    const log_name = try safeLogName(allocator, loaded.manifest.name);
    const log_path = try std.fs.path.join(allocator, &.{ log_directory, log_name });
    try widget_log.init(init.io, log_path);
    std.log.info("widget runtime starting pid={d}{s}", .{ platform.currentProcessId(), if (dev) " dev=true" else "" });
    var storage = try storage_mod.Store.init(init.io, allocator, data_root, loaded.manifest.name);
    const bundle_path = try std.fs.path.join(allocator, &.{ directory, "bundle.js" });
    const bundle_stat = try std.Io.Dir.cwd().statFile(init.io, bundle_path, .{});
    const frame = manifest_mod.desktopFrame(loaded.manifest);
    const shell_views = [_]native_sdk.ShellView{.{
        .label = "widget-canvas",
        .kind = .gpu_surface,
        .fill = true,
        .role = "Weaver widget canvas",
        .accessibility_label = loaded.manifest.name,
        .gpu_backend = declaredGpuBackend(loaded.manifest.renderBackend),
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
        .sync = syncNativeState,
        .on_frame = onFrame,
    });
    defer app_state.destroy();
    try app_state.model.provider.init(platform.providerEndpoint(
        init.environ_map.get("WEAVER_HOST_PIPE"),
        init.environ_map.get("WEAVER_HOST_ENDPOINT"),
    ));
    defer app_state.model.provider.deinit();
    const engine = try js_engine.Engine.create(std.heap.page_allocator, &app_state.model.tree, &storage, loaded.manifest.origins, &app_state.model.provider);
    app_state.model.engine = engine;
    defer if (app_state.model.engine) |current| current.destroy(std.heap.page_allocator);
    app_state.model.io = init.io;
    app_state.model.storage = &storage;
    app_state.model.origins = loaded.manifest.origins;
    app_state.model.bundle_path = bundle_path;
    app_state.model.dev = dev;
    app_state.model.dev_seen_mtime = bundle_stat.mtime.nanoseconds;
    for (loaded.manifest.subscribe) |provider| {
        if (std.mem.eql(u8, provider, "audio")) app_state.model.provider_poll_interval_ms = 33;
    }
    try engine.evaluate(loaded.bundle, "bundle.js");
    try loadLocalImages(init.io, allocator, directory, &app_state.model);

    requested_software_backend = std.mem.eql(u8, loaded.manifest.renderBackend, "software");
    var app = app_state.app();
    app.start_fn = startRendererDiagnostics;
    try runner.runWithOptions(app, .{
        .app_name = "weaver-widget",
        .window_title = loaded.manifest.name,
        .bundle_id = "com.weaver.widget",
        .default_frame = frame,
        .restore_state = false,
        .primary_display_anchor = if (@import("builtin").os.tag == .macos) manifest_mod.primaryDisplayAnchor(loaded.manifest) else null,
        .js_window_api = false,
    }, init);
}

fn declaredGpuBackend(render_backend: []const u8) native_sdk.app_manifest.GpuSurfaceBackend {
    if (std.mem.eql(u8, render_backend, "software")) return .software;
    return switch (@import("builtin").os.tag) {
        .windows => .d3d11,
        .macos => .metal,
        else => .none,
    };
}

/// Capture the live runtime for one present-path diagnostic. Presentation
/// selection itself belongs to Native SDK and follows the declared backend.
fn startRendererDiagnostics(_: *anyopaque, runtime: *native_sdk.Runtime) !void {
    diagnostic_runtime = runtime;
    if (!requested_software_backend) {
        std.log.info("widget renderer selected=gpu presenter=host", .{});
        return;
    }
    std.log.info("widget renderer selected=software presenter=pixels", .{});
}

fn safeLogName(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const base_len = @max(name.len, 6);
    const output = try allocator.alloc(u8, base_len + 4);
    for (name, 0..) |byte, index| {
        output[index] = if (byte < 32 or std.mem.indexOfScalar(u8, "<>:\"/\\|?*", byte) != null) '_' else byte;
    }
    var cursor = name.len;
    while (cursor > 0 and (output[cursor - 1] == '.' or output[cursor - 1] == ' ')) : (cursor -= 1) output[cursor - 1] = '_';
    var end = name.len;
    if (name.len == 0) {
        @memcpy(output[0..6], "widget");
        end = 6;
    }
    @memcpy(output[end .. end + 4], ".log");
    return output[0 .. end + 4];
}

test {
    _ = @import("tree.zig");
    _ = @import("manifest.zig");
    _ = @import("network.zig");
    _ = @import("storage.zig");
    _ = @import("provider.zig");
    _ = @import("widget_log.zig");
    try std.testing.expectEqual(native_sdk.app_manifest.GpuSurfaceBackend.software, declaredGpuBackend("software"));
    const native_gpu_backend: native_sdk.app_manifest.GpuSurfaceBackend = switch (@import("builtin").os.tag) {
        .windows => .d3d11,
        .macos => .metal,
        else => .none,
    };
    try std.testing.expectEqual(native_gpu_backend, declaredGpuBackend("gpu"));
}
