const std = @import("std");
const native_sdk = @import("native_sdk");

pub const max_nodes: usize = 128;
pub const max_children: usize = 24;
pub const max_text_bytes: usize = 192;

pub const NodeId = u32;

pub const Kind = enum {
    column,
    row,
    text,
    panel,

    pub fn parse(value: []const u8) ?Kind {
        inline for (@typeInfo(Kind).@"enum".fields) |field| {
            if (std.mem.eql(u8, value, field.name)) return @field(Kind, field.name);
        }
        return null;
    }
};

pub const FontWeight = enum { regular, medium, bold };

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
    gap: f32 = 0,
    radius: f32 = 0,
    opacity: f32 = 1,
    background: ?native_sdk.canvas.Color = null,
    font_scale: f32 = 1,
    font_weight: FontWeight = .regular,

    pub fn textSlice(self: *const Node) []const u8 {
        return self.text[0..self.text_len];
    }
};

pub const Error = error{
    InvalidNode,
    NodeLimit,
    ChildLimit,
    TextTooLong,
    Cycle,
    InvalidProperty,
};

/// JS mutates this tree; the Native SDK view is a pure derivation of it.
/// `generation` advances only for an effective mutation, which gives the app
/// loop one cheap batch boundary for future no-op timer callbacks.
pub const Tree = struct {
    nodes: [max_nodes]Node = [_]Node{.{}} ** max_nodes,
    root: ?NodeId = null,
    generation: u64 = 0,

    pub fn createNode(self: *Tree, kind: Kind) Error!NodeId {
        for (&self.nodes, 0..) |*slot, index| {
            if (slot.alive) continue;
            slot.* = .{ .alive = true, .kind = kind };
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
        const slot: *f32 = if (std.mem.eql(u8, key, "padding")) &target.padding else if (std.mem.eql(u8, key, "gap")) &target.gap else if (std.mem.eql(u8, key, "radius")) &target.radius else if (std.mem.eql(u8, key, "opacity")) &target.opacity else if (std.mem.eql(u8, key, "fontScale")) &target.font_scale else return error.InvalidProperty;
        const normalized = if (std.mem.eql(u8, key, "opacity")) std.math.clamp(value, 0, 1) else @max(value, 0);
        if (slot.* == normalized) return;
        slot.* = normalized;
        self.changed();
    }

    pub fn setFontWeight(self: *Tree, id: NodeId, value: []const u8) Error!void {
        const weight: FontWeight = if (std.mem.eql(u8, value, "regular")) .regular else if (std.mem.eql(u8, value, "medium")) .medium else if (std.mem.eql(u8, value, "bold")) .bold else return error.InvalidProperty;
        const target = try self.node(id);
        if (target.font_weight == weight) return;
        target.font_weight = weight;
        self.changed();
    }

    pub fn setBackground(self: *Tree, id: NodeId, color: native_sdk.canvas.Color) Error!void {
        const target = try self.node(id);
        if (target.background) |current| {
            if (std.meta.eql(current, color)) return;
        }
        target.background = color;
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
        self.generation +%= 1;
    }
};

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
