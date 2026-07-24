const std = @import("std");
const native_sdk = @import("native_sdk");

pub const max_nodes: usize = 128;
pub const max_children: usize = 24;
pub const max_text_bytes: usize = 192;
pub const max_source_bytes: usize = 260;
pub const max_icon_path_bytes: usize = 8 * 1024;
pub const max_font_family_bytes: usize = 63;
pub const max_canvases: usize = 8;
pub const max_canvas_commands: usize = 256;
pub const max_canvas_points: usize = 1024;
pub const max_canvas_wire_values: usize = 4096;

pub const NodeId = u32;

pub const Kind = enum {
    column,
    row,
    stack,
    text,
    icon,
    panel,
    button,
    slider,
    image,
    canvas,

    pub fn parse(value: []const u8) ?Kind {
        inline for (@typeInfo(Kind).@"enum".fields) |field| {
            if (std.mem.eql(u8, value, field.name)) return @field(Kind, field.name);
        }
        return null;
    }
};

pub const FontWeight = enum { light, regular, medium, semibold, bold };
pub const TextAlign = enum { start, center, end };
pub const CrossAlign = enum { start, center, end, baseline, stretch };
pub const MainAlign = enum { start, center, end, between, around, evenly };
pub const SelfAlign = enum { auto, start, center, end, stretch };

pub const BoxShadow = struct {
    offset: native_sdk.geometry.OffsetF = .{},
    blur: f32 = 0,
    spread: f32 = 0,
    color: native_sdk.canvas.Color,
};

/// One bounded retained node. M0 deliberately keeps ownership simple: JS ids
/// index this table, strings and child lists live inline, and a whole widget
/// cannot silently turn bridge traffic into an unbounded native heap.
pub const Node = struct {
    alive: bool = false,
    kind: Kind = .column,
    parent: ?NodeId = null,
    children: [max_children]NodeId = @splat(0),
    child_count: usize = 0,
    text: [max_text_bytes]u8 = @splat(0),
    text_len: usize = 0,
    padding: f32 = 0,
    padding_top: f32 = -1,
    padding_right: f32 = -1,
    padding_bottom: f32 = -1,
    padding_left: f32 = -1,
    margin_top: f32 = 0,
    margin_right: f32 = 0,
    margin_bottom: f32 = 0,
    margin_left: f32 = 0,
    gap: f32 = 0,
    radius: f32 = 0,
    radius_top_left: f32 = -1,
    radius_top_right: f32 = -1,
    radius_bottom_right: f32 = -1,
    radius_bottom_left: f32 = -1,
    border_width: f32 = 0,
    opacity: f32 = 1,
    background: ?native_sdk.canvas.Color = null,
    border_color: ?native_sdk.canvas.Color = null,
    text_color: ?native_sdk.canvas.Color = null,
    shadow: ?BoxShadow = null,
    shadow_inset: bool = false,
    text_shadow: ?native_sdk.canvas.TextShadow = null,
    font_scale: f32 = 1,
    font_weight: FontWeight = .regular,
    font_family: [max_font_family_bytes]u8 = @splat(0),
    font_family_len: usize = 0,
    text_align: TextAlign = .start,
    line_height: f32 = 0,
    letter_spacing: f32 = 0,
    line_clamp: f32 = 0,
    tabular_nums: bool = false,
    cross_align: CrossAlign = .stretch,
    main_align: MainAlign = .start,
    grow: f32 = 0,
    shrink: f32 = 1,
    align_self: SelfAlign = .auto,
    flex_wrap: bool = false,
    /// -1 is unset; zero is an authored preferred size.
    width: f32 = -1,
    height: f32 = -1,
    min_width: f32 = 0,
    min_height: f32 = 0,
    /// -1 is unbounded; zero is an authored clamp.
    max_width: f32 = -1,
    max_height: f32 = -1,
    width_percent: f32 = 0,
    height_percent: f32 = 0,
    aspect_ratio: f32 = 0,
    truncate: bool = false,
    overflow_hidden: bool = false,
    handles_press: bool = false,
    handles_change: bool = false,
    value: f32 = 0,
    max: f32 = 1,
    source: [max_source_bytes]u8 = @splat(0),
    source_len: usize = 0,
    /// Rare, independently-budgeted icon geometry. Keeping this heap-owned
    /// avoids adding 8 KiB to every one of the 128 retained nodes.
    icon_path: []u8 = &.{},
    icon_view_box: native_sdk.geometry.RectF = native_sdk.geometry.RectF.init(0, 0, 24, 24),
    icon_stroke: f32 = 0,
    canvas_slot: u8 = 0,

    pub fn textSlice(self: *const Node) []const u8 {
        return self.text[0..self.text_len];
    }

    pub fn sourceSlice(self: *const Node) []const u8 {
        return self.source[0..self.source_len];
    }

    pub fn iconPathSlice(self: *const Node) []const u8 {
        return self.icon_path;
    }

    pub fn fontFamilySlice(self: *const Node) []const u8 {
        return self.font_family[0..self.font_family_len];
    }
};

pub const Error = error{
    OutOfMemory,
    InvalidNode,
    NodeLimit,
    ChildLimit,
    TextTooLong,
    IconPathTooLong,
    Cycle,
    InvalidProperty,
    CanvasLimit,
    CanvasCommandLimit,
    CanvasPointLimit,
    InvalidCanvasBatch,
};

pub const CanvasState = struct {
    owner: NodeId = 0,
    commands: [max_canvas_commands]native_sdk.canvas.ImmediateCanvasCommand = undefined,
    command_count: usize = 0,
    points: [max_canvas_points]native_sdk.geometry.PointF = undefined,
    point_count: usize = 0,
    fingerprint: u64 = 0,

    pub fn slice(self: *const CanvasState) []const native_sdk.canvas.ImmediateCanvasCommand {
        return self.commands[0..self.command_count];
    }
};

/// JS mutates this tree; the Native SDK view is a pure derivation of it.
/// `generation` advances only for an effective mutation, which gives the app
/// loop one cheap batch boundary for future no-op timer callbacks.
pub const Tree = struct {
    allocator: std.mem.Allocator = std.heap.page_allocator,
    nodes: [max_nodes]Node = [_]Node{.{}} ** max_nodes,
    canvases: [max_canvases]CanvasState = [_]CanvasState{.{}} ** max_canvases,
    root: ?NodeId = null,
    generation: u64 = 0,
    batch_depth: u8 = 0,
    batch_changed: bool = false,

    pub fn deinit(self: *Tree) void {
        const allocator = self.allocator;
        for (&self.nodes) |*entry| {
            if (entry.icon_path.len > 0) allocator.free(entry.icon_path);
            entry.icon_path = &.{};
        }
    }

    pub fn beginBatch(self: *Tree) void {
        self.batch_depth +|= 1;
    }

    pub fn endBatch(self: *Tree) void {
        if (self.batch_depth == 0) return;
        self.batch_depth -= 1;
        if (self.batch_depth == 0 and self.batch_changed) {
            self.batch_changed = false;
            self.generation +%= 1;
        }
    }

    pub fn createNode(self: *Tree, kind: Kind) Error!NodeId {
        for (&self.nodes, 0..) |*slot, index| {
            if (slot.alive) continue;
            var canvas_index: ?usize = null;
            if (kind == .canvas) {
                canvas_index = for (&self.canvases, 0..) |*canvas, candidate| {
                    if (canvas.owner == 0) break candidate;
                } else return error.CanvasLimit;
            }
            slot.* = .{ .alive = true, .kind = kind };
            if (canvas_index) |canvas_slot| {
                const id: NodeId = @intCast(index + 1);
                self.canvases[canvas_slot] = .{ .owner = id };
                slot.canvas_slot = @intCast(canvas_slot + 1);
            }
            self.changed();
            return @intCast(index + 1);
        }
        return error.NodeLimit;
    }

    pub fn node(self: *Tree, id: NodeId) Error!*Node {
        if (id == 0 or id > max_nodes) return error.InvalidNode;
        const result = &self.nodes[id - 1];
        if (!result.alive) return error.InvalidNode;
        return result;
    }

    pub fn nodeConst(self: *const Tree, id: NodeId) Error!*const Node {
        if (id == 0 or id > max_nodes) return error.InvalidNode;
        const result = &self.nodes[id - 1];
        if (!result.alive) return error.InvalidNode;
        return result;
    }

    pub fn setText(self: *Tree, id: NodeId, value: []const u8) Error!void {
        if (value.len > max_text_bytes) return error.TextTooLong;
        const target = try self.node(id);
        if (std.mem.eql(u8, target.textSlice(), value)) return;
        @memcpy(target.text[0..value.len], value);
        target.text_len = value.len;
        self.changed();
    }

    pub fn setNumberProp(self: *Tree, id: NodeId, key: []const u8, value: f32) Error!void {
        const target = try self.node(id);
        const slot: *f32 = if (std.mem.eql(u8, key, "padding"))
            &target.padding
        else if (std.mem.eql(u8, key, "paddingTop"))
            &target.padding_top
        else if (std.mem.eql(u8, key, "paddingRight"))
            &target.padding_right
        else if (std.mem.eql(u8, key, "paddingBottom"))
            &target.padding_bottom
        else if (std.mem.eql(u8, key, "paddingLeft"))
            &target.padding_left
        else if (std.mem.eql(u8, key, "marginTop"))
            &target.margin_top
        else if (std.mem.eql(u8, key, "marginRight"))
            &target.margin_right
        else if (std.mem.eql(u8, key, "marginBottom"))
            &target.margin_bottom
        else if (std.mem.eql(u8, key, "marginLeft"))
            &target.margin_left
        else if (std.mem.eql(u8, key, "gap"))
            &target.gap
        else if (std.mem.eql(u8, key, "radius"))
            &target.radius
        else if (std.mem.eql(u8, key, "radiusTopLeft"))
            &target.radius_top_left
        else if (std.mem.eql(u8, key, "radiusTopRight"))
            &target.radius_top_right
        else if (std.mem.eql(u8, key, "radiusBottomRight"))
            &target.radius_bottom_right
        else if (std.mem.eql(u8, key, "radiusBottomLeft"))
            &target.radius_bottom_left
        else if (std.mem.eql(u8, key, "borderWidth"))
            &target.border_width
        else if (std.mem.eql(u8, key, "opacity"))
            &target.opacity
        else if (std.mem.eql(u8, key, "fontScale"))
            &target.font_scale
        else if (std.mem.eql(u8, key, "lineHeight"))
            &target.line_height
        else if (std.mem.eql(u8, key, "letterSpacing"))
            &target.letter_spacing
        else if (std.mem.eql(u8, key, "lineClamp"))
            &target.line_clamp
        else if (std.mem.eql(u8, key, "grow"))
            &target.grow
        else if (std.mem.eql(u8, key, "shrink"))
            &target.shrink
        else if (std.mem.eql(u8, key, "width"))
            &target.width
        else if (std.mem.eql(u8, key, "height"))
            &target.height
        else if (std.mem.eql(u8, key, "minWidth"))
            &target.min_width
        else if (std.mem.eql(u8, key, "minHeight"))
            &target.min_height
        else if (std.mem.eql(u8, key, "maxWidth"))
            &target.max_width
        else if (std.mem.eql(u8, key, "maxHeight"))
            &target.max_height
        else if (std.mem.eql(u8, key, "widthPercent"))
            &target.width_percent
        else if (std.mem.eql(u8, key, "heightPercent"))
            &target.height_percent
        else if (std.mem.eql(u8, key, "aspectRatio"))
            &target.aspect_ratio
        else if (std.mem.eql(u8, key, "iconStroke"))
            &target.icon_stroke
        else
            return error.InvalidProperty;
        const normalized = if (std.mem.eql(u8, key, "opacity"))
            std.math.clamp(value, 0, 1)
        else if (std.mem.startsWith(u8, key, "margin"))
            value
        else if (std.mem.eql(u8, key, "letterSpacing"))
            value
        else if ((std.mem.startsWith(u8, key, "padding") and !std.mem.eql(u8, key, "padding")) or std.mem.startsWith(u8, key, "radius"))
            @max(value, -1)
        else if (std.mem.eql(u8, key, "width") or std.mem.eql(u8, key, "height") or
            std.mem.eql(u8, key, "maxWidth") or std.mem.eql(u8, key, "maxHeight"))
            @max(value, -1)
        else
            @max(value, 0);
        if (slot.* == normalized) return;
        slot.* = normalized;
        self.changed();
    }

    pub fn setFontWeight(self: *Tree, id: NodeId, value: []const u8) Error!void {
        const weight: FontWeight = if (std.mem.eql(u8, value, "light")) .light else if (std.mem.eql(u8, value, "normal") or std.mem.eql(u8, value, "regular")) .regular else if (std.mem.eql(u8, value, "medium")) .medium else if (std.mem.eql(u8, value, "semibold")) .semibold else if (std.mem.eql(u8, value, "bold")) .bold else return error.InvalidProperty;
        const target = try self.node(id);
        if (target.font_weight == weight) return;
        target.font_weight = weight;
        self.changed();
    }

    pub fn setFontFamily(self: *Tree, id: NodeId, value: []const u8) Error!void {
        if (value.len > max_font_family_bytes) return error.TextTooLong;
        const target = try self.node(id);
        if (std.mem.eql(u8, target.fontFamilySlice(), value)) return;
        @memcpy(target.font_family[0..value.len], value);
        target.font_family_len = value.len;
        self.changed();
    }

    pub fn setTextAlign(self: *Tree, id: NodeId, value: []const u8) Error!void {
        const alignment: TextAlign = if (std.mem.eql(u8, value, "start")) .start else if (std.mem.eql(u8, value, "center")) .center else if (std.mem.eql(u8, value, "end")) .end else return error.InvalidProperty;
        const target = try self.node(id);
        if (target.text_align == alignment) return;
        target.text_align = alignment;
        self.changed();
    }

    pub fn setBackground(self: *Tree, id: NodeId, color: ?native_sdk.canvas.Color) Error!void {
        const target = try self.node(id);
        if (std.meta.eql(target.background, color)) return;
        target.background = color;
        self.changed();
    }

    pub fn setTextColor(self: *Tree, id: NodeId, color: ?native_sdk.canvas.Color) Error!void {
        const target = try self.node(id);
        if (std.meta.eql(target.text_color, color)) return;
        target.text_color = color;
        self.changed();
    }

    pub fn setBorderColor(self: *Tree, id: NodeId, color: ?native_sdk.canvas.Color) Error!void {
        const target = try self.node(id);
        if (std.meta.eql(target.border_color, color)) return;
        target.border_color = color;
        self.changed();
    }

    pub fn setShadow(self: *Tree, id: NodeId, value: ?BoxShadow) Error!void {
        const target = try self.node(id);
        if (std.meta.eql(target.shadow, value)) return;
        target.shadow = value;
        self.changed();
    }

    pub fn setShadowInset(self: *Tree, id: NodeId, value: bool) Error!void {
        const target = try self.node(id);
        if (target.shadow_inset == value) return;
        target.shadow_inset = value;
        self.changed();
    }

    pub fn setTextShadow(self: *Tree, id: NodeId, value: ?native_sdk.canvas.TextShadow) Error!void {
        const target = try self.node(id);
        if (std.meta.eql(target.text_shadow, value)) return;
        target.text_shadow = value;
        self.changed();
    }

    pub fn setCrossAlign(self: *Tree, id: NodeId, value: []const u8) Error!void {
        const alignment: CrossAlign = if (std.mem.eql(u8, value, "start")) .start else if (std.mem.eql(u8, value, "center")) .center else if (std.mem.eql(u8, value, "end")) .end else if (std.mem.eql(u8, value, "baseline")) .baseline else if (std.mem.eql(u8, value, "stretch")) .stretch else return error.InvalidProperty;
        const target = try self.node(id);
        if (target.cross_align == alignment) return;
        target.cross_align = alignment;
        self.changed();
    }

    pub fn setMainAlign(self: *Tree, id: NodeId, value: []const u8) Error!void {
        const alignment: MainAlign = if (std.mem.eql(u8, value, "start")) .start else if (std.mem.eql(u8, value, "center")) .center else if (std.mem.eql(u8, value, "end")) .end else if (std.mem.eql(u8, value, "between")) .between else if (std.mem.eql(u8, value, "around")) .around else if (std.mem.eql(u8, value, "evenly")) .evenly else return error.InvalidProperty;
        const target = try self.node(id);
        if (target.main_align == alignment) return;
        target.main_align = alignment;
        self.changed();
    }

    pub fn setAlignSelf(self: *Tree, id: NodeId, value: []const u8) Error!void {
        const alignment: SelfAlign = if (std.mem.eql(u8, value, "auto")) .auto else if (std.mem.eql(u8, value, "start")) .start else if (std.mem.eql(u8, value, "center")) .center else if (std.mem.eql(u8, value, "end")) .end else if (std.mem.eql(u8, value, "stretch")) .stretch else return error.InvalidProperty;
        const target = try self.node(id);
        if (target.align_self == alignment) return;
        target.align_self = alignment;
        self.changed();
    }

    pub fn setFlexWrap(self: *Tree, id: NodeId, value: bool) Error!void {
        const target = try self.node(id);
        if (target.flex_wrap == value) return;
        target.flex_wrap = value;
        self.changed();
    }

    pub fn setTabularNums(self: *Tree, id: NodeId, value: bool) Error!void {
        const target = try self.node(id);
        if (target.tabular_nums == value) return;
        target.tabular_nums = value;
        self.changed();
    }

    pub fn setTruncate(self: *Tree, id: NodeId, value: bool) Error!void {
        const target = try self.node(id);
        if (target.truncate == value) return;
        target.truncate = value;
        self.changed();
    }

    pub fn setOverflowHidden(self: *Tree, id: NodeId, value: bool) Error!void {
        const target = try self.node(id);
        if (target.overflow_hidden == value) return;
        target.overflow_hidden = value;
        self.changed();
    }

    pub fn setHandler(self: *Tree, id: NodeId, kind: []const u8, enabled: bool) Error!void {
        const target = try self.node(id);
        const slot: *bool = if (std.mem.eql(u8, kind, "press")) &target.handles_press else if (std.mem.eql(u8, kind, "change")) &target.handles_change else return error.InvalidProperty;
        if (slot.* == enabled) return;
        slot.* = enabled;
        self.changed();
    }

    pub fn setControlValue(self: *Tree, id: NodeId, key: []const u8, value: f32) Error!void {
        const target = try self.node(id);
        const slot: *f32 = if (std.mem.eql(u8, key, "value")) &target.value else if (std.mem.eql(u8, key, "max")) &target.max else return error.InvalidProperty;
        const normalized = if (std.mem.eql(u8, key, "max")) @max(value, 0.000001) else @max(value, 0);
        if (slot.* == normalized) return;
        slot.* = normalized;
        self.changed();
    }

    pub fn setSource(self: *Tree, id: NodeId, value: []const u8) Error!void {
        if (value.len > max_source_bytes) return error.TextTooLong;
        const target = try self.node(id);
        if (std.mem.eql(u8, target.sourceSlice(), value)) return;
        @memcpy(target.source[0..value.len], value);
        target.source_len = value.len;
        self.changed();
    }

    pub fn setIconPath(self: *Tree, id: NodeId, value: []const u8) Error!void {
        if (value.len > max_icon_path_bytes) return error.IconPathTooLong;
        const target = try self.node(id);
        if (std.mem.eql(u8, target.iconPathSlice(), value)) return;
        const replacement = try self.allocator.dupe(u8, value);
        if (target.icon_path.len > 0) self.allocator.free(target.icon_path);
        target.icon_path = replacement;
        self.changed();
    }

    pub fn setIconViewBox(self: *Tree, id: NodeId, value: []const u8) Error!void {
        var values: [4]f32 = undefined;
        var tokens = std.mem.tokenizeAny(u8, value, " ,\t\r\n");
        for (&values) |*slot| {
            const token = tokens.next() orelse return error.InvalidProperty;
            slot.* = std.fmt.parseFloat(f32, token) catch return error.InvalidProperty;
            if (!std.math.isFinite(slot.*)) return error.InvalidProperty;
        }
        if (tokens.next() != null or values[2] <= 0 or values[3] <= 0) return error.InvalidProperty;
        const next = native_sdk.geometry.RectF.init(values[0], values[1], values[2], values[3]);
        const target = try self.node(id);
        if (std.meta.eql(target.icon_view_box, next)) return;
        target.icon_view_box = next;
        self.changed();
    }

    pub fn canvasState(self: *Tree, id: NodeId) Error!*CanvasState {
        const target = try self.node(id);
        if (target.kind != .canvas or target.canvas_slot == 0) return error.InvalidNode;
        return &self.canvases[target.canvas_slot - 1];
    }

    pub fn canvasStateConst(self: *const Tree, id: NodeId) Error!*const CanvasState {
        const target = try self.nodeConst(id);
        if (target.kind != .canvas or target.canvas_slot == 0) return error.InvalidNode;
        return &self.canvases[target.canvas_slot - 1];
    }

    /// Decode the SDK's bounded Float64 wire batch into fork-native drawing
    /// commands. Colors arrive as exact packed RGBA integers; geometry is
    /// narrowed once here, so the frame renderer never parses JS values.
    pub fn setCanvasCommands(self: *Tree, id: NodeId, wire: []const f64) Error!void {
        if (wire.len > max_canvas_wire_values) return error.InvalidCanvasBatch;
        const fingerprint = std.hash.Wyhash.hash(0x6361_6e76_6173, std.mem.sliceAsBytes(wire));
        const canvas = try self.canvasState(id);
        if (canvas.fingerprint == fingerprint and canvas.command_count > 0) return;
        canvas.command_count = 0;
        canvas.point_count = 0;
        var cursor: usize = 0;
        while (cursor < wire.len) {
            const opcode = finiteInt(wire[cursor]) orelse return error.InvalidCanvasBatch;
            cursor += 1;
            switch (opcode) {
                0 => {
                    const color = try wireColor(wire, &cursor);
                    if (color.a > 0) {
                        const node_value = try self.nodeConst(id);
                        try appendCanvasCommand(canvas, .{ .fill_rect = .{
                            .rect = native_sdk.geometry.RectF.init(0, 0, node_value.width, node_value.height),
                            .color = color,
                        } });
                    }
                },
                1 => try appendCanvasCommand(canvas, .{ .fill_rect = .{
                    .rect = native_sdk.geometry.RectF.init(try wireFloat(wire, &cursor), try wireFloat(wire, &cursor), try wireFloat(wire, &cursor), try wireFloat(wire, &cursor)),
                    .color = try wireColor(wire, &cursor),
                } }),
                2 => try appendCanvasCommand(canvas, .{ .fill_rounded_rect = .{
                    .rect = native_sdk.geometry.RectF.init(try wireFloat(wire, &cursor), try wireFloat(wire, &cursor), try wireFloat(wire, &cursor), try wireFloat(wire, &cursor)),
                    .radius = try wireFloat(wire, &cursor),
                    .color = try wireColor(wire, &cursor),
                } }),
                3 => try appendCanvasCommand(canvas, .{ .fill_circle = .{
                    .center = native_sdk.geometry.PointF.init(try wireFloat(wire, &cursor), try wireFloat(wire, &cursor)),
                    .radius = try wireFloat(wire, &cursor),
                    .color = try wireColor(wire, &cursor),
                } }),
                4 => try appendCanvasCommand(canvas, .{ .line = .{
                    .from = native_sdk.geometry.PointF.init(try wireFloat(wire, &cursor), try wireFloat(wire, &cursor)),
                    .to = native_sdk.geometry.PointF.init(try wireFloat(wire, &cursor), try wireFloat(wire, &cursor)),
                    .width = try wireFloat(wire, &cursor),
                    .color = try wireColor(wire, &cursor),
                } }),
                5 => {
                    const width = try wireFloat(wire, &cursor);
                    const color = try wireColor(wire, &cursor);
                    const count = finiteInt(if (cursor < wire.len) wire[cursor] else return error.InvalidCanvasBatch) orelse return error.InvalidCanvasBatch;
                    cursor += 1;
                    if (count < 2 or canvas.point_count + count > max_canvas_points) return error.CanvasPointLimit;
                    const start = canvas.point_count;
                    for (0..count) |_| {
                        canvas.points[canvas.point_count] = native_sdk.geometry.PointF.init(try wireFloat(wire, &cursor), try wireFloat(wire, &cursor));
                        canvas.point_count += 1;
                    }
                    try appendCanvasCommand(canvas, .{ .polyline = .{ .points = canvas.points[start..canvas.point_count], .width = width, .color = color } });
                },
                else => return error.InvalidCanvasBatch,
            }
        }
        canvas.fingerprint = fingerprint;
        self.changed();
    }

    pub fn appendChild(self: *Tree, parent_id: NodeId, child_id: NodeId) Error!void {
        if (parent_id == child_id or try self.isAncestor(child_id, parent_id)) return error.Cycle;
        const parent = try self.node(parent_id);
        _ = try self.node(child_id);
        for (parent.children[0..parent.child_count]) |existing| {
            if (existing == child_id) return;
        }
        if (parent.child_count == max_children) return error.ChildLimit;
        try self.detach(child_id);
        const live_parent = try self.node(parent_id);
        live_parent.children[live_parent.child_count] = child_id;
        live_parent.child_count += 1;
        (try self.node(child_id)).parent = parent_id;
        self.changed();
    }

    /// Move or attach `child_id` immediately before `before_id`. A zero
    /// `before_id` means append, matching the reconciler's end sentinel.
    pub fn insertBefore(self: *Tree, parent_id: NodeId, child_id: NodeId, before_id: NodeId) Error!void {
        if (parent_id == child_id or try self.isAncestor(child_id, parent_id)) return error.Cycle;
        _ = try self.node(parent_id);
        _ = try self.node(child_id);
        if (before_id != 0) {
            const before = try self.node(before_id);
            if (before.parent != parent_id or before_id == child_id) return error.InvalidNode;
        }
        const original_parent = (try self.node(child_id)).parent;
        const parent = try self.node(parent_id);
        var original_index: ?usize = null;
        if (original_parent == parent_id) {
            for (parent.children[0..parent.child_count], 0..) |candidate, index| {
                if (candidate == child_id) original_index = index;
            }
        }
        var target_index: usize = parent.child_count;
        if (before_id != 0) {
            for (parent.children[0..parent.child_count], 0..) |candidate, index| {
                if (candidate == before_id) target_index = index;
            }
        }
        if (original_index) |index| {
            const adjusted = if (index < target_index) target_index - 1 else target_index;
            if (index == adjusted) return;
        } else if (parent.child_count == max_children) return error.ChildLimit;
        try self.detach(child_id);
        const live_parent = try self.node(parent_id);
        target_index = live_parent.child_count;
        if (before_id != 0) {
            for (live_parent.children[0..live_parent.child_count], 0..) |candidate, index| {
                if (candidate == before_id) target_index = index;
            }
        }
        std.mem.copyBackwards(NodeId, live_parent.children[target_index + 1 .. live_parent.child_count + 1], live_parent.children[target_index..live_parent.child_count]);
        live_parent.children[target_index] = child_id;
        live_parent.child_count += 1;
        (try self.node(child_id)).parent = parent_id;
        self.changed();
    }

    pub fn removeNode(self: *Tree, id: NodeId) Error!void {
        _ = try self.node(id);
        try self.detach(id);
        self.removeSubtree(id);
        if (self.root == id) self.root = null;
        self.changed();
    }

    pub fn setRoot(self: *Tree, id: NodeId) Error!void {
        _ = try self.node(id);
        if (self.root == id) return;
        self.root = id;
        self.changed();
    }

    fn detach(self: *Tree, id: NodeId) Error!void {
        const child = try self.node(id);
        const parent_id = child.parent orelse return;
        const parent = try self.node(parent_id);
        for (parent.children[0..parent.child_count], 0..) |candidate, index| {
            if (candidate != id) continue;
            std.mem.copyForwards(NodeId, parent.children[index .. parent.child_count - 1], parent.children[index + 1 .. parent.child_count]);
            parent.child_count -= 1;
            child.parent = null;
            return;
        }
    }

    fn removeSubtree(self: *Tree, id: NodeId) void {
        const target = self.node(id) catch return;
        const count = target.child_count;
        var children: [max_children]NodeId = undefined;
        @memcpy(children[0..count], target.children[0..count]);
        for (children[0..count]) |child_id| self.removeSubtree(child_id);
        if (target.canvas_slot > 0) self.canvases[target.canvas_slot - 1] = .{};
        if (target.icon_path.len > 0) self.allocator.free(target.icon_path);
        target.* = .{};
    }

    fn isAncestor(self: *Tree, ancestor: NodeId, descendant: NodeId) Error!bool {
        var cursor: ?NodeId = descendant;
        while (cursor) |id| {
            if (id == ancestor) return true;
            cursor = (try self.node(id)).parent;
        }
        return false;
    }

    fn changed(self: *Tree) void {
        if (self.batch_depth > 0) {
            self.batch_changed = true;
        } else {
            self.generation +%= 1;
        }
    }
};

fn appendCanvasCommand(canvas: *CanvasState, command: native_sdk.canvas.ImmediateCanvasCommand) Error!void {
    if (canvas.command_count == max_canvas_commands) return error.CanvasCommandLimit;
    canvas.commands[canvas.command_count] = command;
    canvas.command_count += 1;
}

fn wireFloat(wire: []const f64, cursor: *usize) Error!f32 {
    if (cursor.* >= wire.len or !std.math.isFinite(wire[cursor.*])) return error.InvalidCanvasBatch;
    const value: f32 = @floatCast(wire[cursor.*]);
    cursor.* += 1;
    return value;
}

fn wireColor(wire: []const f64, cursor: *usize) Error!native_sdk.canvas.Color {
    if (cursor.* >= wire.len) return error.InvalidCanvasBatch;
    const packed_value = finiteInt(wire[cursor.*]) orelse return error.InvalidCanvasBatch;
    cursor.* += 1;
    if (packed_value > std.math.maxInt(u32)) return error.InvalidCanvasBatch;
    const rgba: u32 = @intCast(packed_value);
    return native_sdk.canvas.Color.rgba8(@truncate(rgba >> 24), @truncate(rgba >> 16), @truncate(rgba >> 8), @truncate(rgba));
}

fn finiteInt(value: f64) ?usize {
    if (!std.math.isFinite(value) or value < 0 or @floor(value) != value or value > @as(f64, @floatFromInt(std.math.maxInt(u32)))) return null;
    return @intFromFloat(value);
}

test "tree owns a bounded hierarchy" {
    var tree: Tree = .{};
    const root = try tree.createNode(.column);
    const label = try tree.createNode(.text);
    try tree.setText(label, "clock");
    try tree.appendChild(root, label);
    try tree.setRoot(root);
    try std.testing.expectEqualStrings("clock", (try tree.nodeConst(label)).textSlice());
    try std.testing.expectError(error.Cycle, tree.appendChild(label, root));
    try tree.removeNode(label);
    try std.testing.expectError(error.InvalidNode, tree.node(label));
}

test "tree stores styling breadth layout wire properties" {
    var tree: Tree = .{};
    const id = try tree.createNode(.stack);
    try std.testing.expectEqual(CrossAlign.stretch, (try tree.nodeConst(id)).cross_align);
    try tree.setNumberProp(id, "paddingTop", 0);
    try tree.setNumberProp(id, "paddingRight", 12);
    try tree.setNumberProp(id, "marginLeft", -8);
    try tree.setNumberProp(id, "minWidth", 40);
    try tree.setNumberProp(id, "maxHeight", 120);
    try tree.setNumberProp(id, "widthPercent", 50);
    try tree.setNumberProp(id, "aspectRatio", 4.0 / 3.0);
    try tree.setNumberProp(id, "width", 0);
    try tree.setNumberProp(id, "maxWidth", 0);
    try tree.setNumberProp(id, "shrink", 0);
    try tree.setNumberProp(id, "radiusTopLeft", 14);
    try tree.setNumberProp(id, "radiusBottomRight", 2);
    try tree.setNumberProp(id, "borderWidth", 1);
    try tree.setNumberProp(id, "lineHeight", 1.25);
    try tree.setNumberProp(id, "letterSpacing", -0.5);
    try tree.setNumberProp(id, "lineClamp", 3);
    const border = native_sdk.canvas.Color.rgba8(229, 231, 235, 255);
    try tree.setBorderColor(id, border);
    try tree.setMainAlign(id, "evenly");
    try tree.setAlignSelf(id, "stretch");
    try tree.setFlexWrap(id, true);
    try tree.setTextAlign(id, "center");
    try tree.setFontFamily(id, "CozetteVector");
    try tree.setTabularNums(id, true);
    const shadow_color = native_sdk.canvas.Color.rgba8(1, 2, 3, 64);
    try tree.setShadow(id, .{ .offset = .{ .dx = 2, .dy = 3 }, .blur = 8, .spread = -1, .color = shadow_color });
    try tree.setShadowInset(id, true);
    try tree.setTextShadow(id, .{ .offset = .{ .dx = 1, .dy = 2 }, .blur = 4, .color = shadow_color });
    try tree.setOverflowHidden(id, true);
    const node = try tree.nodeConst(id);
    try std.testing.expectEqual(Kind.stack, node.kind);
    try std.testing.expectEqual(@as(f32, 0), node.padding_top);
    try std.testing.expectEqual(@as(f32, 12), node.padding_right);
    try std.testing.expectEqual(@as(f32, -8), node.margin_left);
    try std.testing.expectEqual(@as(f32, 40), node.min_width);
    try std.testing.expectEqual(@as(f32, 120), node.max_height);
    try std.testing.expectEqual(@as(f32, 50), node.width_percent);
    try std.testing.expectApproxEqAbs(@as(f32, 4.0 / 3.0), node.aspect_ratio, 0.0001);
    try std.testing.expectEqual(@as(f32, 0), node.width);
    try std.testing.expectEqual(@as(f32, 0), node.max_width);
    try std.testing.expectEqual(@as(f32, 0), node.shrink);
    try std.testing.expectEqual(@as(f32, 14), node.radius_top_left);
    try std.testing.expectEqual(@as(f32, 2), node.radius_bottom_right);
    try std.testing.expectEqual(@as(f32, 1), node.border_width);
    try std.testing.expectEqual(@as(f32, 1.25), node.line_height);
    try std.testing.expectEqual(@as(f32, -0.5), node.letter_spacing);
    try std.testing.expectEqual(@as(f32, 3), node.line_clamp);
    try std.testing.expectEqualDeep(border, node.border_color.?);
    try std.testing.expectEqual(MainAlign.evenly, node.main_align);
    try std.testing.expectEqual(SelfAlign.stretch, node.align_self);
    try std.testing.expect(node.flex_wrap);
    try std.testing.expectEqual(TextAlign.center, node.text_align);
    try std.testing.expectEqualStrings("CozetteVector", node.fontFamilySlice());
    try std.testing.expect(node.tabular_nums);
    try std.testing.expectEqual(@as(f32, 2), node.shadow.?.offset.dx);
    try std.testing.expectEqual(@as(f32, -1), node.shadow.?.spread);
    try std.testing.expect(node.shadow_inset);
    try std.testing.expectEqual(@as(f32, 4), node.text_shadow.?.blur);
    try std.testing.expect(node.overflow_hidden);
    try tree.setNumberProp(id, "paddingTop", -1);
    try std.testing.expectEqual(@as(f32, -1), (try tree.nodeConst(id)).padding_top);
}

test "icon path has an independent 8192-byte budget and parsed viewBox" {
    var tree: Tree = .{ .allocator = std.testing.allocator };
    defer tree.deinit();
    const id = try tree.createNode(.icon);
    const at_limit = [_]u8{'M'} ** max_icon_path_bytes;
    try tree.setIconPath(id, &at_limit);
    try std.testing.expectEqual(max_icon_path_bytes, (try tree.nodeConst(id)).iconPathSlice().len);
    const over_limit = [_]u8{'M'} ** (max_icon_path_bytes + 1);
    try std.testing.expectError(error.IconPathTooLong, tree.setIconPath(id, &over_limit));
    try tree.setIconViewBox(id, "-2.5 1 32 16");
    try std.testing.expectEqual(native_sdk.geometry.RectF.init(-2.5, 1, 32, 16), (try tree.nodeConst(id)).icon_view_box);
    try std.testing.expectError(error.InvalidProperty, tree.setIconViewBox(id, "0 0 24 0"));
}

test "rare icon paths do not grow every retained node" {
    // Later styling layers may add compact common fields, but restoring the
    // 8 KiB inline path buffer must always trip this bound.
    try std.testing.expect(@sizeOf(Node) < max_icon_path_bytes / 2);

    var tree: Tree = .{ .allocator = std.testing.allocator };
    defer tree.deinit();
    const first = try tree.createNode(.icon);
    const second = try tree.createNode(.icon);
    try tree.setIconPath(first, "M 0 0 L 24 24");
    try tree.setIconPath(second, "M 24 0 L 0 24");
    try tree.removeNode(first);
    try std.testing.expectEqualStrings("M 24 0 L 0 24", (try tree.nodeConst(second)).iconPathSlice());
}

test "canvas wire decodes packed colors and polyline points" {
    var tree: Tree = .{};
    const id = try tree.createNode(.canvas);
    try tree.setNumberProp(id, "width", 64);
    try tree.setNumberProp(id, "height", 32);
    try tree.setCanvasCommands(id, &.{
        0,          0x11223344,
        1,          1,
        2,          3,
        4,          0xff00ffff,
        5,          2,
        0xffffffff, 3,
        0,          0,
        4,          8,
        9,          3,
    });
    const canvas = try tree.canvasStateConst(id);
    try std.testing.expectEqual(@as(usize, 3), canvas.command_count);
    try std.testing.expectEqual(@as(usize, 3), canvas.point_count);
    try std.testing.expectEqual(@as(f32, 64), canvas.commands[0].fill_rect.rect.width);
    try std.testing.expectApproxEqAbs(@as(f32, 0x11) / 255, canvas.commands[0].fill_rect.color.r, 0.0001);
    try std.testing.expectEqual(@as(usize, 3), canvas.commands[2].polyline.points.len);
}
