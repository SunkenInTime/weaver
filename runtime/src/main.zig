const std = @import("std");
const builtin = @import("builtin");
const runner = @import("runner");
const native_sdk = @import("native_sdk");
const geometry_mod = @import("geometry.zig");
const dev_reload = @import("dev_reload.zig");
const js_engine = @import("js_engine.zig");
const manifest_mod = @import("manifest.zig");
const provider_mod = @import("provider.zig");
const platform = @import("platform/root.zig");
const storage_mod = @import("storage.zig");
const windows_monitor = if (builtin.os.tag == .windows) @import("platform/windows_monitor.zig") else struct {};
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
    dev_seen_mtime: i128 = 0,
    timer_fires: u64 = 0,
    armed_timers: [bridgeTimerCapacity()]ArmedTimer = [_]ArmedTimer{.{}} ** bridgeTimerCapacity(),
    fetch_poll_armed: bool = false,
    provider_poll_armed: bool = false,
    provider_poll_interval_ms: u64 = 1000,
    provider_frames: u64 = 0,
    slider_values: [tree_mod.max_nodes]f32 = @splat(0),
    images: [max_images]ImageAsset = [_]ImageAsset{.{}} ** max_images,
    image_count: usize = 0,
    geometry: ?*const geometry_mod.Store = null,
    /// Last origin we consider settled (launch placement or the last
    /// persisted drag), in the platform's logical window space. Null
    /// until the first platform frame report names the launch position.
    frame_origin: ?[2]f32 = null,
    pending_frame: ?geometry_mod.Saved = null,
};

const ArmedTimer = struct { id: u64 = 0, interval_ms: u64 = 0 };
fn bridgeTimerCapacity() usize {
    return @import("bridge.zig").max_timers;
}
const max_images: usize = 16;
const fetch_poll_key: u64 = 0x7766_6574_6368;
const provider_poll_key: u64 = 0x7770_726f_7669;
const geometry_save_key: u64 = 0x7767_656f_6d65;
const ImageAsset = struct { id: u64 = 0, bytes: []const u8 = &.{} };

pub const Msg = union(enum) {
    timer: native_sdk.EffectTimer,
    press: tree_mod.NodeId,
    slider: tree_mod.NodeId,
    canvas_frame: u64,
    dev_reload,
    frame_moved: geometry_mod.Saved,
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
var dev_reload_runtime = std.atomic.Value(usize).init(0);
var dev_reload_pending = std.atomic.Value(bool).init(false);
var backend_status_io: ?std.Io = null;
var backend_status_path: ?[]const u8 = null;

fn initEffects(model: *Model, effects: *Effects) void {
    for (model.images[0..model.image_count]) |image| {
        _ = effects.registerImageBytes(image.id, image.bytes) catch |err| {
            std.log.err("widget image {d} failed to decode/register: {s}", .{ image.id, @errorName(err) });
        };
    }
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
            if (timer.key == geometry_save_key) {
                persistGeometry(model);
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
                drainProviderFrames(model) catch |err| {
                    std.log.err("widget provider dispatch failed: {s}", .{@errorName(err)});
                };
                syncTimers(model, effects);
                return;
            }
            if (model.provider_poll_interval_ms <= 33) {
                drainProviderFrames(model) catch |err| {
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
        .frame_moved => |moved| {
            const known = model.frame_origin orelse {
                // The first platform report names the launch placement
                // (creation/focus echo). The anchor — or the restored
                // origin — stays authoritative until the user actually
                // moves the window.
                model.frame_origin = .{ moved.x, moved.y };
                return;
            };
            if (@abs(known[0] - moved.x) < 0.5 and @abs(known[1] - moved.y) < 0.5) return;
            model.frame_origin = .{ moved.x, moved.y };
            model.pending_frame = moved;
            // OS drags report continuously. Re-starting the same key
            // REPLACES the pending one-shot, so the disk write lands
            // once, after the gesture settles.
            effects.startTimer(.{
                .key = geometry_save_key,
                .interval_ms = 400,
                .mode = .one_shot,
                .on_fire = Effects.timerMsg(.timer),
            });
        },
        .canvas_frame => |timestamp_ns| {
            if (model.provider_poll_interval_ms <= 33) {
                drainProviderFrames(model) catch |err| {
                    std.log.err("widget provider dispatch failed: {s}", .{@errorName(err)});
                };
            }
            (model.engine orelse return).fireCanvasFrames(timestamp_ns) catch |err| {
                std.log.err("widget canvas frame callback failed: {s}", .{@errorName(err)});
            };
            syncTimers(model, effects);
        },
        .dev_reload => {
            reloadIfChanged(model, effects) catch |err| {
                std.log.err("dev hot swap failed; keeping previous bundle: {s}", .{@errorName(err)});
            };
        },
    }
}

/// A dragged position is user state, not widget source (ADR 0004/0011):
/// it lands in its own per-widget geometry record, never in the
/// installed manifest and never in the widget's JS-visible storage doc.
fn persistGeometry(model: *Model) void {
    const pending = model.pending_frame orelse return;
    model.pending_frame = null;
    const store = model.geometry orelse return;
    store.save(pending) catch |err| {
        std.log.warn("widget could not persist dragged position: {s}", .{@errorName(err)});
        return;
    };
    std.log.info("widget position persisted x={d} y={d}", .{ pending.x, pending.y });
}

/// Every frame report maps to a Msg; the model decides what is a real
/// move. During the drag itself the OS owns the window — nothing here
/// touches JS or invalidates the presented surface.
fn onWindowFrame(event: native_sdk.runtime.WindowFrameEvent) ?Msg {
    return Msg{ .frame_moved = .{
        .x = event.frame.x,
        .y = event.frame.y,
        .scale = event.scale_factor,
    } };
}

fn drainProviderFrames(model: *Model) !void {
    const count = try (model.engine orelse return).drainProviders();
    if (count == 0) return;
    model.provider_frames += count;
    if (model.provider_frames == count) std.log.info("widget provider frames applied count={d}", .{count});
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
        publishBackendStatus(frame.backend);
    } else if (frame.backend != last_backend) {
        if ((last_backend == .d3d11 or last_backend == .metal) and frame.backend == .software) {
            std.log.warn("widget renderer demoted {s} -> software", .{@tagName(last_backend)});
        } else if (last_backend == .software and (frame.backend == .d3d11 or frame.backend == .metal)) {
            std.log.info("widget renderer promoted software -> {s}", .{@tagName(frame.backend)});
        } else {
            std.log.info("widget renderer backend changed {s} -> {s}", .{ @tagName(last_backend), @tagName(frame.backend) });
        }
        publishBackendStatus(frame.backend);
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
    if (dev_reload_pending.swap(false, .acq_rel)) return .dev_reload;
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
    const root_id = model.tree.root orelse return ui.panel(.{ .window_drag = true }, .{});
    return buildNode(ui, &model.tree, root_id, true);
}

fn hasPaintStyle(node: *const tree_mod.Node) bool {
    return node.background != null or node.border_color != null or node.border_width > 0 or node.radius > 0 or
        node.radius_top_left >= 0 or node.radius_top_right >= 0 or node.radius_bottom_right >= 0 or node.radius_bottom_left >= 0 or node.shadow != null;
}

fn attachEffects(ui: *WidgetUi, retained: *const tree_mod.Node, source: WidgetUi.Node) WidgetUi.Node {
    const count: usize = @intFromBool(retained.shadow != null) + @intFromBool(retained.text_shadow != null);
    if (count == 0) return source;
    const existing = source.widget.immediate_commands;
    const combined = ui.arena.alloc(native_sdk.canvas.ImmediateCanvasCommand, existing.len + count) catch return source;
    @memcpy(combined[0..existing.len], existing);
    var cursor: usize = existing.len;
    if (retained.shadow) |shadow| {
        combined[cursor] = .{ .box_shadow = .{
            .offset = shadow.offset,
            .blur = shadow.blur,
            .spread = shadow.spread,
            .color = shadow.color,
            .inset = retained.shadow_inset,
        } };
        cursor += 1;
    }
    if (retained.text_shadow) |shadow| combined[cursor] = .{ .text_shadow = shadow };
    var result = source;
    result.widget.immediate_commands = combined;
    return result;
}

fn buildNode(ui: *WidgetUi, tree: *const tree_mod.Tree, id: tree_mod.NodeId, is_root: bool) WidgetUi.Node {
    const retained = tree.nodeConst(id) catch return ui.panel(.{}, .{});
    var options: WidgetUi.ElementOptions = .{
        .global_key = .{ .int = id },
        // Every widget drags by its whole surface: the root is one OS
        // window-drag region, and press-claiming widgets inside it
        // (buttons, sliders) become exclusion rects automatically, so
        // their interactions win over the drag. The OS owns the pointer
        // for the whole gesture — no JS round-trip, no re-render.
        .window_drag = is_root,
        .padding = retained.padding,
        .padding_top = if (retained.padding_top >= 0) retained.padding_top else null,
        .padding_right = if (retained.padding_right >= 0) retained.padding_right else null,
        .padding_bottom = if (retained.padding_bottom >= 0) retained.padding_bottom else null,
        .padding_left = if (retained.padding_left >= 0) retained.padding_left else null,
        .margin_top = retained.margin_top,
        .margin_right = retained.margin_right,
        .margin_bottom = retained.margin_bottom,
        .margin_left = retained.margin_left,
        .gap = retained.gap,
        .opacity = retained.opacity,
        .grow = retained.grow,
        .shrink = retained.shrink,
        .self_align = switch (retained.align_self) {
            .auto => null,
            .start => .start,
            .center => .center,
            .end => .end,
            .stretch => .stretch,
        },
        .flex_wrap = retained.flex_wrap,
        .width = if (retained.width >= 0) retained.width else null,
        .height = if (retained.height >= 0) retained.height else null,
        .min_width = retained.min_width,
        .min_height = retained.min_height,
        .max_width = if (retained.max_width >= 0) retained.max_width else null,
        .max_height = if (retained.max_height >= 0) retained.max_height else null,
        .width_percent = retained.width_percent,
        .height_percent = retained.height_percent,
        .aspect_ratio = retained.aspect_ratio,
        .cross = switch (retained.cross_align) {
            .start => .start,
            .center => .center,
            .end, .baseline => .end,
            .stretch => .stretch,
        },
        .main = switch (retained.main_align) {
            .start => .start,
            .center => .center,
            .end => .end,
            .between => .space_between,
            .around => .space_around,
            .evenly => .space_evenly,
        },
        .style = .{
            .background = retained.background,
            .foreground = retained.text_color,
            .radius = if (retained.radius > 0) retained.radius else null,
            .radius_top_left = nativeCornerRadius(retained.radius_top_left),
            .radius_top_right = nativeCornerRadius(retained.radius_top_right),
            .radius_bottom_right = nativeCornerRadius(retained.radius_bottom_right),
            .radius_bottom_left = nativeCornerRadius(retained.radius_bottom_left),
            .border = retained.border_color,
            .stroke_width = retained.border_width,
            .quiet_hover = true,
        },
        .on_press = if (retained.handles_press) Msg{ .press = id } else null,
        .on_change = if (retained.handles_change) Msg{ .slider = id } else null,
    };
    if (retained.kind == .text) {
        options.text_alignment = switch (retained.text_align) {
            .start => .start,
            .center => .center,
            .end => .end,
        };
        options.text_line_height = if (retained.line_height > 0) retained.line_height * 14 * retained.font_scale else 0;
        options.text_letter_spacing = retained.letter_spacing;
        options.text_tabular_numbers = retained.tabular_nums;
        options.text_max_lines = @intFromFloat(@floor(std.math.clamp(retained.line_clamp, 0, 64)));
        options.wrap = retained.line_clamp > 0;
        options.overflow = if (retained.truncate or retained.line_clamp > 0) .ellipsis else .clip;
        if (retained.truncate or retained.line_clamp > 0) {
            options.text_scale = retained.font_scale;
            options.text_weight = switch (retained.font_weight) {
                .light, .regular => .regular,
                .medium => .medium,
                .semibold, .bold => .bold,
            };
            return attachEffects(ui, retained, ui.text(options, retained.textSlice()));
        }
        const span = [_]native_sdk.canvas.TextSpan{.{
            .text = retained.textSlice(),
            .weight = switch (retained.font_weight) {
                .light, .regular => .regular,
                .medium => .medium,
                .semibold, .bold => .bold,
            },
            .scale = retained.font_scale,
        }};
        return attachEffects(ui, retained, ui.paragraph(options, &span));
    }
    const children = ui.arena.alloc(WidgetUi.Node, retained.child_count) catch return ui.panel(.{}, .{});
    for (retained.children[0..retained.child_count], 0..) |child_id, index| {
        children[index] = buildNode(ui, tree, child_id, false);
    }
    const result = switch (retained.kind) {
        // SDK layout-only rows/columns do not paint their own style. A
        // styled column is contractually a column-layout box, which is the
        // builder's panel primitive; unstyled columns keep the lean node.
        // A styled row gets the same painting panel around its row layout.
        .column => if (hasPaintStyle(retained)) block: {
            const column_options: WidgetUi.ElementOptions = .{
                .gap = retained.gap,
                .grow = 1,
                .cross = options.cross,
                .main = options.main,
                .flex_wrap = retained.flex_wrap,
            };
            options.gap = 0;
            break :block ui.panel(options, .{ui.column(column_options, children)});
        } else ui.column(options, children),
        .row => if (hasPaintStyle(retained)) block: {
            const row_options: WidgetUi.ElementOptions = .{
                .gap = retained.gap,
                .grow = 1,
                .cross = options.cross,
                .main = options.main,
                .flex_wrap = retained.flex_wrap,
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
    return attachEffects(ui, retained, result);
}

fn nativeCornerRadius(retained: f32) f32 {
    return if (retained >= 0) retained else -std.math.inf(f32);
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
    const force_software = if (init.environ_map.get("WEAVER_FORCE_SOFTWARE")) |value|
        std.mem.eql(u8, value, "1")
    else
        false;
    const renderer_backend = declaredGpuBackend(loaded.manifest.renderBackend, force_software);
    if (@import("builtin").os.tag == .macos) {
        backend_status_io = init.io;
        backend_status_path = init.environ_map.get("WEAVER_BACKEND_FILE");
    }
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
    var geometry_store = try geometry_mod.Store.init(init.io, allocator, data_root, loaded.manifest.name);
    // A dragged position outranks the manifest anchor, but only while it
    // still lands on an attached display; a stale record (monitor
    // unplugged) falls back to the anchor. macOS validates in AppKit at
    // creation (constrainFrame), so only Windows pre-checks here.
    const dragged: ?geometry_mod.Saved = if (geometry_store.load(allocator)) |saved|
        (if (draggedOriginVisible(saved, loaded.manifest.size)) saved else null)
    else
        null;
    var frame = manifest_mod.desktopFrame(loaded.manifest);
    if (dragged) |saved| {
        frame.x = saved.x;
        frame.y = saved.y;
        // The Windows host reads a (0,0) origin as "let the system
        // place it"; nudge the exact corner case off the sentinel.
        if (builtin.os.tag == .windows and frame.x == 0 and frame.y == 0) frame.x = 0.01;
    }
    const shell_views = [_]native_sdk.ShellView{.{
        .label = "widget-canvas",
        .kind = .gpu_surface,
        .fill = true,
        .role = "Weaver widget canvas",
        .accessibility_label = loaded.manifest.name,
        .gpu_backend = renderer_backend,
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
        .on_window_frame = onWindowFrame,
    });
    defer app_state.destroy();
    app_state.model.geometry = &geometry_store;
    if (dragged) |saved| app_state.model.frame_origin = .{ saved.x, saved.y };
    try app_state.model.provider.init(init.io, platform.providerEndpoint(
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
    app_state.model.dev_seen_mtime = bundle_stat.mtime.nanoseconds;
    for (loaded.manifest.subscribe) |provider| {
        if (std.mem.eql(u8, provider, "audio")) app_state.model.provider_poll_interval_ms = 33;
    }
    try engine.evaluate(loaded.bundle, "bundle.js");
    try loadLocalImages(init.io, allocator, directory, &app_state.model);

    requested_software_backend = renderer_backend == .software;
    const dev_signal_path = try std.fs.path.join(allocator, &.{ directory, dev_reload.signal_file_name });
    var dev_reload_server: dev_reload.Server = .{};
    if (dev) try dev_reload_server.start(init.io, dev_signal_path, notifyDevReload);
    defer if (dev) {
        dev_reload_server.deinit();
        dev_reload_runtime.store(0, .release);
        dev_reload_pending.store(false, .release);
    };
    var app = app_state.app();
    app.start_fn = startRendererDiagnostics;
    try runner.runWithOptions(app, .{
        .app_name = "weaver-widget",
        .window_title = loaded.manifest.name,
        .bundle_id = "com.weaver.widget",
        .default_frame = frame,
        // A dragged origin places the window explicitly (macOS reads the
        // frame only when restore is set, then clamps it in AppKit); the
        // manifest anchor stays the placement until that first drag.
        .restore_state = dragged != null,
        // Weaver owns placement persistence (debounced, per-widget,
        // atomic). The substrate's bundle-id-keyed store would make
        // every widget process rewrite one shared windows.zon on each
        // move tick.
        .persist_window_state = false,
        .primary_display_anchor = if (builtin.os.tag == .macos and dragged == null) manifest_mod.primaryDisplayAnchor(loaded.manifest) else null,
        .js_window_api = false,
    }, init);
}

/// A persisted origin is only trusted while a grabbable corner of the
/// widget (24 physical px each axis) still intersects the virtual
/// desktop — monitors come and go between sessions. Non-Windows
/// platforms answer true: macOS clamps in AppKit at creation.
fn draggedOriginVisible(saved: geometry_mod.Saved, size: [2]f32) bool {
    if (builtin.os.tag != .windows) return true;
    const bounds = windows_monitor.virtualScreen() orelse return true;
    const left = saved.x * saved.scale;
    const top = saved.y * saved.scale;
    const right = left + size[0] * saved.scale;
    const bottom = top + size[1] * saved.scale;
    const overlap_x = @min(right, @as(f32, @floatFromInt(bounds.right_px))) - @max(left, @as(f32, @floatFromInt(bounds.left_px)));
    const overlap_y = @min(bottom, @as(f32, @floatFromInt(bounds.bottom_px))) - @max(top, @as(f32, @floatFromInt(bounds.top_px)));
    return overlap_x >= 24 and overlap_y >= 24;
}

fn publishBackendStatus(backend: native_sdk.platform.GpuSurfaceBackend) void {
    const io = backend_status_io orelse return;
    const path = backend_status_path orelse return;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = backendStatusLabel(backend) }) catch |err| {
        std.log.warn("widget could not publish renderer status: {s}", .{@errorName(err)});
    };
}

fn backendStatusLabel(backend: native_sdk.platform.GpuSurfaceBackend) []const u8 {
    return switch (backend) {
        .metal, .d3d11 => "gpu",
        .software => "software",
        else => "-",
    };
}

fn declaredGpuBackend(render_backend: []const u8, force_software: bool) native_sdk.app_manifest.GpuSurfaceBackend {
    if (force_software) return .software;
    // ADR 0012: every healthy macOS Widget takes the measured Metal path.
    // `renderBackend` is generated internal metadata, not Widget source; it
    // remains the Windows retained/canvas selector until that lane changes.
    if (@import("builtin").os.tag == .macos) return .metal;
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
    dev_reload_runtime.store(@intFromPtr(runtime), .release);
    if (dev_reload_pending.load(.acquire)) try runtime.options.platform.services.requestFrame();
    if (!requested_software_backend) {
        std.log.info("widget renderer selected={s} presenter=host", .{if (@import("builtin").os.tag == .macos) "metal-composite" else "gpu"});
        return;
    }
    std.log.info("widget renderer selected=software presenter=pixels", .{});
}

fn notifyDevReload() void {
    dev_reload_pending.store(true, .release);
    const runtime_address = dev_reload_runtime.load(.acquire);
    if (runtime_address == 0) return;
    const runtime: *native_sdk.Runtime = @ptrFromInt(runtime_address);
    runtime.options.platform.services.requestFrame() catch |err| {
        std.log.err("dev hot-swap wake failed: {s}", .{@errorName(err)});
    };
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
    _ = @import("dev_reload.zig");
    _ = @import("tree.zig");
    _ = @import("geometry.zig");
    _ = @import("manifest.zig");
    _ = @import("network.zig");
    _ = @import("storage.zig");
    _ = @import("provider.zig");
    _ = @import("widget_log.zig");
    const automatic_software_backend: native_sdk.app_manifest.GpuSurfaceBackend =
        if (@import("builtin").os.tag == .macos) .metal else .software;
    try std.testing.expectEqual(automatic_software_backend, declaredGpuBackend("software", false));
    try std.testing.expectEqual(native_sdk.app_manifest.GpuSurfaceBackend.software, declaredGpuBackend("gpu", true));
    const native_gpu_backend: native_sdk.app_manifest.GpuSurfaceBackend = switch (@import("builtin").os.tag) {
        .windows => .d3d11,
        .macos => .metal,
        else => .none,
    };
    try std.testing.expectEqual(native_gpu_backend, declaredGpuBackend("gpu", false));
}

test "renderer backend status uses the portable public spelling" {
    try std.testing.expectEqualStrings("gpu", backendStatusLabel(.metal));
    try std.testing.expectEqualStrings("software", backendStatusLabel(.software));
    try std.testing.expectEqualStrings("-", backendStatusLabel(.none));
}

test "corner radius projection preserves authored values and maps retained unset in-band" {
    try std.testing.expectEqual(@as(f32, 12.5), nativeCornerRadius(12.5));
    try std.testing.expect(nativeCornerRadius(-1) == -std.math.inf(f32));
}

test "painted row lowering preserves flex wrap on the inner layout node" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var retained_tree: tree_mod.Tree = .{};
    const row = try retained_tree.createNode(.row);
    const child = try retained_tree.createNode(.panel);
    try retained_tree.appendChild(row, child);
    try retained_tree.setBackground(row, native_sdk.canvas.Color.rgb8(20, 30, 40));
    try retained_tree.setFlexWrap(row, true);

    var ui = WidgetUi.init(arena_state.allocator());
    const built = try ui.finalize(buildNode(&ui, &retained_tree, row, true));
    try std.testing.expectEqual(native_sdk.canvas.WidgetKind.panel, built.root.kind);
    try std.testing.expectEqual(@as(usize, 1), built.root.children.len);
    try std.testing.expectEqual(native_sdk.canvas.WidgetKind.row, built.root.children[0].kind);
    try std.testing.expect(built.root.children[0].layout.flex_wrap);
}

test "attached effects preserve builder text metadata" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var retained_tree: tree_mod.Tree = .{};
    const text_node = try retained_tree.createNode(.text);
    try retained_tree.setText(text_node, "styled");
    try retained_tree.setNumberProp(text_node, "fontScale", 2);
    try retained_tree.setTruncate(text_node, true);
    try retained_tree.setTextShadow(text_node, .{
        .offset = .{ .dx = 1, .dy = 2 },
        .blur = 3,
        .color = native_sdk.canvas.Color.rgb8(10, 20, 30),
    });

    var ui = WidgetUi.init(arena_state.allocator());
    const built = try ui.finalize(buildNode(&ui, &retained_tree, text_node, true));
    try std.testing.expectEqual(@as(usize, 2), built.root.immediate_commands.len);
    switch (built.root.immediate_commands[0]) {
        .text_style => |style| try std.testing.expectEqual(@as(f32, 2), style.scale),
        else => return error.TestExpectedEqual,
    }
    switch (built.root.immediate_commands[1]) {
        .text_shadow => |shadow| try std.testing.expectEqual(@as(f32, 3), shadow.blur),
        else => return error.TestExpectedEqual,
    }
}
