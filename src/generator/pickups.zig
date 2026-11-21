//! World pickups for items that only exist as get-demo actors.
//!
//! Items lying in the world (freestanding spots, rupee spots, boss Heart Container spots, Gold Skulltula drops) must
//! be Obj_Item_Base actors: those are the ones the player can walk up to and collect. Most key items only have an
//! Item_* actor (what the item-get cutscene shows in Link's hands); placed in the world it just lies there.
//!
//! For each such item this builds a new actor "Obj_Rando_<item>" cloned from Obj_Arrow_Fire (Lake Hylia's freestanding
//! Fire Arrows, an Obj_Item_Base pickup that gives a key item):
//! - pack: the template pack + the item's own component files, a new ActorParam whose model / name / animation /
//!   parameter-table / effect refs come from the item, and a new PouchContentParam ("PouchActor" = the item);
//! - RSDB: ActorInfo and GameActorInfo rows cloned from the template with the item's model fields and ActorName, and a
//!   PouchActorInfo row cloned from the item;
//! - RESTBL: entries for the new pack and the new files inside it.
//!
//! Walk-over pickups ("Obj_RandoAuto_"): Obj_Arrow_Fire, and so every clone, needs A; every shuffled item lying in the
//! world gets a copy of its pickup with the walk-over attention setting of Obj_Rupee_Green (a Skulltula on a wall drops
//! its item in mid-air, where Link climbing can touch it but can't press A). Pickups with their own AI (heart pieces)
//! keep needing A.
//!
//! Gold Skulltula drops ("Obj_RandoGS_") are built on the token's own pickup, as OotrR does: the drop floats like a
//! token, is collected by touching it, and keeps the token's AI, which sets the Skulltula's save flag when the drop's
//! get event ends; so the event plays on every pickup (TOKEN_POUCH_FLAGS), even for items without an IsGet flag.
//!
//! Shop shelves ("Shop_Rando_", Items Shuffled Per Shop), after OotrR's item forms: the arrow shelf with the item's
//! model, name and animations, a pouch setting that only names the item, the item's game parameters and its own price.

const std = @import("std");
const byml = @import("../formats/byml.zig");
const sarc = @import("../formats/sarc.zig");
const restbl_mod = @import("../formats/restbl.zig");
const world_mod = @import("../game/world.zig");
const patchset = @import("patchset.zig");
const flows = @import("flows.zig");
const Progress = @import("../core/Progress.zig");
const Allocator = std.mem.Allocator;
const PatchError = patchset.PatchError;
const World = world_mod.World;
const Restbl = restbl_mod.Restbl;

const template_actor = "Obj_Arrow_Fire";
const prefix = "Obj_Rando_";
const copied_refs = [_][]const u8{ "ActorNameRef", "ModelInfoRef", "AnimationRef", "GameParameterTableRef", "ELinkRef", "SLinkRef", "CaptureRef" };
const row_from_item = [_][]const u8{ "FmdbName", "ModelProjectName", "AnimationResources", "ModelAabbMax", "ModelAabbMin", "ELinkUserName", "SLinkUserName" };
const heap_keys = [_][]const u8{ "InstanceHeapSize", "PreActorRenderInfoHeapSize" };

/// Songs have no model of their own (Item_Melody_* points at the rupee model as a placeholder), so song pickups
/// borrow Sheik's harp, the model her song scenes use. The name and get text stay the song's.
const harp = "Dm_Item_Sheik_Harp";
const model_row_keys = [_][]const u8{ "FmdbName", "ModelProjectName", "ModelAabbMax", "ModelAabbMin" };

const token_template = "Obj_Token_Gold";
const token_prefix = "Obj_RandoGS_";
const token_refs = copied_refs ++ [_][]const u8{"ASRef"};
/// the token's golden aura and hum: the item's own, or none
const token_links = [_][]const u8{ "ELinkRef", "SLinkRef" };

const shop_template = "Shop_ArrowBundle_01";
const shop_prefix = "Shop_Rando_";
const shop_refs = [_][]const u8{ "ModelInfoRef", "AnimationRef", "ActorNameRef", "ASRef" };

const auto_prefix = "Obj_RandoAuto_";
const auto_source = "Obj_Rupee_Green";
const auto_attention = "Component/AttentionSenderParam/AutoPickUpItem.game__component__AttentionSenderParam.bgyml";
const auto_files = [_][]const u8{
    auto_attention,
    "Attention/ClientParam/Auto_Item_Catch.game__attention__ClientParam.bgyml",
    "Attention/ClientParam/LookOnly_Middle_Small.game__attention__ClientParam.bgyml",
};

fn packOf(allocator: Allocator, name: []const u8) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(allocator, "Pack/Actor/{s}.pack.zs", .{name});
}

/// The size-table key of a pack (the path without ".zs").
fn packKey(allocator: Allocator, name: []const u8) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(allocator, "Pack/Actor/{s}.pack", .{name});
}

fn paramOf(allocator: Allocator, name: []const u8) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(allocator, "Actor/{s}.engine__actor__ActorParam.bgyml", .{name});
}

/// "?Component/X/Y.bgyml" -> "Component/X/Y.bgyml"
fn refFile(ref: []const u8) []const u8 {
    return std.mem.trimStart(u8, ref, "?");
}

/// "Component/X/Y.game__x.bgyml" -> "Work/Component/X/Y.game__x.gyml" (the form $parent / PouchActor use)
fn workPath(allocator: Allocator, file_path: []const u8) error{OutOfMemory}![]const u8 {
    if (!std.mem.endsWith(u8, file_path, ".bgyml")) return file_path;
    return std.fmt.allocPrint(allocator, "Work/{s}.gyml", .{file_path[0 .. file_path.len - ".bgyml".len]});
}

/// A pack's files by name.
const Files = struct {
    entries: []const sarc.Entry,

    fn get(self: Files, name: []const u8) ?[]const u8 {
        for (self.entries) |e| if (std.mem.eql(u8, e.name, name)) return e.data;
        return null;
    }

    fn has(self: Files, name: []const u8) bool {
        return self.get(name) != null;
    }
};

fn listFiles(allocator: Allocator, data: []const u8) PatchError!Files {
    const list = sarc.list(allocator, data) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidData,
    };
    return Files{ .entries = list.items };
}

fn rebuildWith(allocator: Allocator, data: []const u8, replace: []const sarc.NewFile, add: []const sarc.NewFile) PatchError![]u8 {
    const out = sarc.rebuild(allocator, data, replace, add) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidData,
    };
    _ = try listFiles(allocator, out); // sanity: must parse
    return out;
}

fn versionOf(data: []const u8) u16 {
    if (data.len < 4) return 7;
    return std.mem.readInt(u16, data[2..4], if (data[0] == 'B') .big else .little);
}

const RowClone = struct { clone: []const u8, src: []const u8, template: []const u8 };
const AutoRow = struct { clone: []const u8, src: []const u8 };
const SizeEntry = struct { path: []const u8, size: ?u32 };

pub const PickupCloner = struct {
    allocator: Allocator,
    world: *World,
    patches: *patchset.PatchSet,
    restbl: *Restbl,
    progress: *Progress,
    /// "<kind>|<actor>[|price]" -> clone name (null: it could not be built)
    made: std.StringHashMap(?[]const u8),
    rows: std.ArrayList(RowClone),
    /// clone -> the actor whose model it borrows (songs)
    model_src: std.StringHashMap([]const u8),
    auto_rows: std.ArrayList(AutoRow),
    /// shop shelf clone -> its price
    prices: std.StringHashMap(i64),

    const Self = @This();

    pub fn init(world: *World, patches: *patchset.PatchSet, restbl: *Restbl, progress: *Progress) Self {
        const a = patches.keep; // the cloner's state spans every patch step
        return Self{
            .allocator = a,
            .world = world,
            .patches = patches,
            .restbl = restbl,
            .progress = progress,
            .made = std.StringHashMap(?[]const u8).init(a),
            .rows = .empty,
            .model_src = std.StringHashMap([]const u8).init(a),
            .auto_rows = .empty,
            .prices = std.StringHashMap(i64).init(a),
        };
    }

    fn key(self: *Self, kind: []const u8, actor: []const u8, price: ?i64) error{OutOfMemory}![]const u8 {
        if (price) |p| return std.fmt.allocPrint(self.allocator, "{s}|{s}|{d}", .{ kind, actor, p });
        return std.fmt.allocPrint(self.allocator, "{s}|{s}", .{ kind, actor });
    }

    /// A copy of `text` that outlives the patch step (the caller's string may be in the step's scratch memory).
    fn keepText(self: *Self, text: []const u8) error{OutOfMemory}![]const u8 {
        return self.allocator.dupe(u8, text);
    }

    /// The actor to place in the world for `actor` (a world-context actor). `auto`: the pickup must be collected by
    /// touching it.
    pub fn worldActor(self: *Self, actor: []const u8, auto: bool) PatchError![]const u8 {
        var base = actor;
        if (!std.mem.startsWith(u8, actor, "Obj_")) {
            const k = try self.key("world", actor, null);
            if (!self.made.contains(k)) self.made.put(k, try self.build(actor, template_actor, prefix, null)) catch return error.OutOfMemory;
            base = self.made.get(k).? orelse actor;
        }
        if (!auto or !std.mem.startsWith(u8, base, "Obj_")) return base;
        const k = try self.key("auto", base, null);
        if (!self.made.contains(k)) self.made.put(k, try self.buildAuto(base)) catch return error.OutOfMemory;
        return self.made.get(k).? orelse base;
    }

    /// The Gold Skulltula drop for `actor` (the item's event actor): a token-based pickup.
    pub fn tokenActor(self: *Self, actor: []const u8) PatchError![]const u8 {
        if (std.mem.eql(u8, actor, "Item_Token_Gold") or std.mem.eql(u8, actor, token_template)) return token_template;
        const k = try self.key("token", actor, null);
        if (!self.made.contains(k)) self.made.put(k, try self.build(actor, token_template, token_prefix, null)) catch return error.OutOfMemory;
        if (self.made.get(k).?) |clone| return clone;
        return self.worldActor(actor, true);
    }

    /// A shelf actor that sells `actor` (the item's event actor) once for `price` rupees.
    pub fn shopActor(self: *Self, actor: []const u8, price: i64) PatchError![]const u8 {
        const k = try self.key("shop", actor, price);
        if (!self.made.contains(k)) self.made.put(k, try self.build(actor, shop_template, shop_prefix, price)) catch return error.OutOfMemory;
        return self.made.get(k).? orelse self.progress.fail(error.NotAsExpected, "no shop shelf could be built for {s}", .{actor});
    }

    /// The size for a new path: the fallback path's entry plus `delta` (never less), or null when `path` already has
    /// one (or the fallback has none).
    fn newSize(self: *Self, path: []const u8, fallback: []const u8, delta: i64) ?u32 {
        if (self.restbl.get(path) != null) return null;
        const base = self.restbl.get(fallback) orelse return null;
        return base + @as(u32, @intCast(@max(0, delta)));
    }

    fn setSizes(self: *Self, entries: []const SizeEntry, only_new: bool) PatchError!void {
        for (entries) |e| {
            const size = e.size orelse continue;
            if (only_new and self.restbl.get(e.path) != null) continue;
            if (self.restbl.crcTaken(e.path)) {
                self.progress.log("warning: size-table hash collision for {s}; skipped", .{e.path});
                continue;
            }
            self.restbl.set(e.path, size) catch return error.OutOfMemory;
        }
    }

    /// A copy of pickup `src` that is collected by walking into it, or null if it already is (or has its own AI).
    fn buildAuto(self: *Self, src: []const u8) PatchError!?[]const u8 {
        const a = self.patches.allocator; // the step's scratch: only `clone` and the rows are kept
        const raw = try self.patches.read(try packOf(a, src));
        const files = try listFiles(a, raw.data);
        const src_param_path = try paramOf(a, src);
        const src_param_bytes = files.get(src_param_path) orelse return null;
        const param = try byml.loadDict(a, src_param_bytes);
        const comps = try param.ensureDict(a, "Components");
        const ref = comps.getString("AttentionSenderRef") orelse return null;
        if (std.mem.indexOf(u8, ref, "AutoPickUpItem") != null) return null; // Obj_Item_Base's walk-over setting
        if (comps.contains("AIInfoRef")) return null; // own AI (heart pieces): keeps needing A

        const tail = if (std.mem.startsWith(u8, src, prefix)) src[prefix.len..] else src["Obj_".len..];
        const clone = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ auto_prefix, tail }) catch return error.OutOfMemory;
        try comps.put(a, "AttentionSenderRef", .{ .string = "?" ++ auto_attention });

        const source = try self.patches.read(try packOf(a, auto_source));
        const source_files = try listFiles(a, source.data);
        var add: std.ArrayList(sarc.NewFile) = .empty;
        for (auto_files) |k| {
            if (files.has(k)) continue;
            const d = source_files.get(k) orelse continue;
            add.append(a, .{ .name = k, .data = d }) catch return error.OutOfMemory;
        }
        const new_param = try byml.dump(a, .{ .dict = param }, versionOf(src_param_bytes), false);
        const clone_param_path = try paramOf(a, clone);
        add.append(a, .{ .name = clone_param_path, .data = new_param }) catch return error.OutOfMemory;
        const data = try rebuildWith(a, raw.data, &.{}, add.items);
        const clone_pack = try packOf(a, clone);
        try self.patches.emit(clone_pack, data, data, raw.dictionary, true);

        const clone_key = try packKey(a, clone);
        var entries: std.ArrayList(SizeEntry) = .empty;
        const pack_size = self.restbl.get(try packKey(a, src));
        entries.append(a, .{ .path = clone_key, .size = if (pack_size) |ps| ps + @as(u32, @intCast(@max(0, @as(i64, @intCast(data.len)) - @as(i64, @intCast(raw.data.len))))) else null }) catch return error.OutOfMemory;
        entries.append(a, .{ .path = clone_param_path, .size = self.newSize(clone_param_path, src_param_path, @as(i64, @intCast(new_param.len)) - @as(i64, @intCast(src_param_bytes.len))) }) catch return error.OutOfMemory;
        for (add.items) |f| {
            var listed = false;
            for (entries.items) |e| if (std.mem.eql(u8, e.path, f.name)) {
                listed = true;
            };
            if (listed or self.restbl.get(f.name) != null) continue;
            entries.append(a, .{ .path = f.name, .size = self.newSize(f.name, auto_attention, @intCast(f.data.len)) }) catch return error.OutOfMemory;
        }
        if (entries.items[0].size == null) {
            // a clone's own pack size was added this run: work it out the way build did
            const tmpl = try self.patches.read(try packOf(a, template_actor));
            entries.items[0].size = self.newSize(clone_key, try packKey(a, template_actor), @as(i64, @intCast(data.len)) - @as(i64, @intCast(tmpl.data.len)));
        }
        try self.setSizes(entries.items, true);
        self.auto_rows.append(self.allocator, .{ .clone = clone, .src = try self.keepText(src) }) catch return error.OutOfMemory;
        return clone;
    }

    fn build(self: *Self, src: []const u8, template: []const u8, clone_prefix: []const u8, price: ?i64) PatchError!?[]const u8 {
        const a = self.patches.allocator; // the step's scratch: only `clone` and the rows are kept
        const token = std.mem.eql(u8, template, token_template);
        const shop = std.mem.eql(u8, template, shop_template);
        const src_pack = try packOf(a, src);
        if (!self.world.files.exists(src_pack)) {
            self.progress.log("warning: no pack for {s}; it can't be made into a world pickup", .{src});
            return null;
        }
        const underscore = std.mem.indexOfScalar(u8, src, '_') orelse return null;
        const clone = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ clone_prefix, src[underscore + 1 ..] }) catch return error.OutOfMemory;
        const tmpl_raw = try self.patches.read(try packOf(a, template));
        const tmpl = try listFiles(a, tmpl_raw.data);
        const item = try listFiles(a, (try self.patches.read(src_pack)).data);
        const src_param_path = try paramOf(a, src);
        const tmpl_param_path = try paramOf(a, template);
        const src_param_bytes = item.get(src_param_path) orelse {
            self.progress.log("warning: {s} has no ActorParam; it can't be made into a world pickup", .{src});
            return null;
        };
        const tmpl_param_bytes = tmpl.get(tmpl_param_path) orelse {
            self.progress.log("warning: {s} has no ActorParam; it can't be made into a world pickup", .{src});
            return null;
        };
        const src_param = try byml.loadDict(a, src_param_bytes);
        const src_comps = src_param.getDict("Components") orelse try byml.Dict.create(a);
        const param = try byml.loadDict(a, tmpl_param_bytes);
        const comps = try param.ensureDict(a, "Components");
        const refs: []const []const u8 = if (shop) &shop_refs else if (token) &token_refs else &copied_refs;
        for (refs) |k| {
            if (src_comps.get(k)) |v| {
                try comps.put(a, k, v);
            } else if (token and flows.contains(&token_links, k)) {
                _ = comps.remove(k);
            }
        }

        var model_files: std.ArrayList(sarc.NewFile) = .empty;
        var model_src: []const u8 = if (std.mem.startsWith(u8, src, "Item_Melody_")) harp else src;
        if (!std.mem.eql(u8, model_src, src)) {
            const m_files = try listFiles(a, (try self.patches.read(try packOf(a, model_src))).data);
            const m_param = m_files.get(try paramOf(a, model_src)) orelse return error.NotAsExpected;
            const m_comps = (try byml.loadDict(a, m_param)).getDict("Components");
            const ref = if (m_comps) |mc| mc.getString("ModelInfoRef") else null;
            if (ref != null and m_files.has(refFile(ref.?))) {
                try comps.put(a, "ModelInfoRef", .{ .string = ref.? });
                model_files.append(a, .{ .name = refFile(ref.?), .data = m_files.get(refFile(ref.?)).? }) catch return error.OutOfMemory;
            } else {
                model_src = src;
            }
        }

        // pouch content: inherit the item's own settings, but give the item itself
        const pouch_tmpl_ref = comps.getString("PouchContentRef") orelse return self.progress.fail(error.NotAsExpected, "{s} has no PouchContentRef", .{template});
        const pouch_tmpl_path = refFile(pouch_tmpl_ref);
        const pouch_tmpl_bytes = tmpl.get(pouch_tmpl_path) orelse return self.progress.fail(error.NotAsExpected, "{s} has no pouch parameters", .{template});
        const pouch = if (token or shop) blk: {
            const d = try byml.Dict.create(a);
            try d.put(a, "DefaultAutoGet", .{ .bool = true });
            break :blk d;
        } else try byml.loadDict(a, pouch_tmpl_bytes);
        const src_pouch_ref = src_comps.getString("PouchContentRef");
        if (src_pouch_ref) |r| try pouch.put(a, "$parent", .{ .string = try workPath(a, refFile(r)) });
        var pouch_actor: []const u8 = std.fmt.allocPrint(a, "Work/Actor/{s}.engine__actor__ActorParam.gyml", .{src}) catch return error.OutOfMemory;
        if (!std.mem.startsWith(u8, src, "Item_") and src_pouch_ref != null) {
            // an Obj_ source's own pouch parameters already name the item it gives
            if (item.get(refFile(src_pouch_ref.?))) |pb| {
                if ((try byml.loadDict(a, pb)).getString("PouchActor")) |pa| {
                    if (pa.len > 0) pouch_actor = pa;
                }
            }
        }
        try pouch.put(a, "PouchActor", .{ .string = pouch_actor });
        if (token) {
            try pouch.put(a, "PlayGetEventManyTimes", .{ .bool = true });
            try pouch.put(a, "IsPlayGetEventPouchMax", .{ .bool = true });
        }
        _ = pouch.remove("IsPickedUpEmitXlinkKey");
        _ = pouch.remove("PickedUpEmitXlinkKey");
        const pouch_path = std.fmt.allocPrint(a, "Component/PouchContentParam/{s}.game__component__PouchContentParam.bgyml", .{clone}) catch return error.OutOfMemory;
        try comps.put(a, "PouchContentRef", .{ .string = std.fmt.allocPrint(a, "?{s}", .{pouch_path}) catch return error.OutOfMemory });

        var add: std.ArrayList(sarc.NewFile) = .empty;
        for (item.entries) |e| {
            if (tmpl.has(e.name) or std.mem.startsWith(u8, e.name, "Actor/") or std.mem.startsWith(u8, e.name, "AI/")) continue;
            add.append(a, .{ .name = e.name, .data = e.data }) catch return error.OutOfMemory;
        }
        const table_path = std.fmt.allocPrint(a, "GameParameter/GameParameterTable/{s}.engine__actor__GameParameterTable.bgyml", .{clone}) catch return error.OutOfMemory;
        if (token) {
            // the item's game parameters (bag sizes, equipment, ...) plus the pickup's own drop/physics ones
            const base_bytes = tmpl.get("GameParameter/GameParameterTable/Obj_Item_Base.engine__actor__GameParameterTable.bgyml") orelse
                return self.progress.fail(error.NotAsExpected, "the token pack has no item parameter table", .{});
            const base = try byml.loadDict(a, base_bytes);
            const src_ref = src_comps.getString("GameParameterTableRef");
            const table = if (src_ref != null and item.has(refFile(src_ref.?))) try byml.loadDict(a, item.get(refFile(src_ref.?)).?) else try byml.Dict.create(a);
            _ = table.remove("$parent");
            if (!table.contains("Category")) try table.put(a, "Category", base.get("Category") orelse byml.Value{ .string = "GameParameterTableDefault" });
            const merged = if (base.getDict("Components")) |bc| (try (byml.Value{ .dict = bc }).clone(a)).dict else try byml.Dict.create(a);
            if (table.getDict("Components")) |tc| for (tc.entries.items) |e| try merged.put(a, e.key, e.value);
            try table.put(a, "Components", .{ .dict = merged });
            add.append(a, .{ .name = table_path, .data = try byml.dumpDefault(a, .{ .dict = table }) }) catch return error.OutOfMemory;
            try comps.put(a, "GameParameterTableRef", .{ .string = std.fmt.allocPrint(a, "?{s}", .{table_path}) catch return error.OutOfMemory });
        }
        if (shop) {
            // the shelf's own parameters (put in pouch) with the item's added, a new price, bought once
            const tmpl_table_ref = comps.getString("GameParameterTableRef") orelse return self.progress.fail(error.NotAsExpected, "the shelf pack has no parameter table", .{});
            const tmpl_table_bytes = tmpl.get(refFile(tmpl_table_ref)) orelse return self.progress.fail(error.NotAsExpected, "the shelf pack has no parameter table", .{});
            const table = try byml.loadDict(a, tmpl_table_bytes);
            const src_ref = src_comps.getString("GameParameterTableRef");
            const src_table = if (src_ref != null and item.has(refFile(src_ref.?))) try byml.loadDict(a, item.get(refFile(src_ref.?)).?) else try byml.Dict.create(a);
            const table_comps = try table.ensureDict(a, "Components");
            if (src_table.getDict("Components")) |sc| for (sc.entries.items) |e| {
                if (!table_comps.contains(e.key)) try table_comps.put(a, e.key, e.value);
            };
            const price_path = std.fmt.allocPrint(a, "GameParameter/PriceParam/{s}.game__pouchcontent__PriceParam.bgyml", .{clone}) catch return error.OutOfMemory;
            const price_dict = try byml.Dict.create(a);
            try price_dict.put(a, "BuyingPrice", .{ .int = @intCast(price.?) });
            try price_dict.put(a, "SellingPrice", .{ .int = 1 });
            add.append(a, .{ .name = price_path, .data = try byml.dumpDefault(a, .{ .dict = price_dict }) }) catch return error.OutOfMemory;
            try table_comps.put(a, "PriceParam", .{ .string = std.fmt.allocPrint(a, "?{s}", .{price_path}) catch return error.OutOfMemory });
            add.append(a, .{ .name = table_path, .data = try byml.dump(a, .{ .dict = table }, versionOf(tmpl_table_bytes), false) }) catch return error.OutOfMemory;
            try comps.put(a, "GameParameterTableRef", .{ .string = std.fmt.allocPrint(a, "?{s}", .{table_path}) catch return error.OutOfMemory });
            // bought once: the placement's Presence flag hides it (patches.zig). NoRespawn, as OotrR sets it, only
            // acts when a pickup is collected, and a bought shelf stayed (0.5.0 test seed 4)
            self.prices.put(clone, price.?) catch return error.OutOfMemory;
        }
        for (model_files.items) |m| {
            if (!tmpl.has(m.name)) add.append(a, m) catch return error.OutOfMemory;
        }
        const new_param = try byml.dump(a, .{ .dict = param }, versionOf(tmpl_param_bytes), false);
        const new_pouch = try byml.dump(a, .{ .dict = pouch }, versionOf(pouch_tmpl_bytes), false);
        const clone_param_path = try paramOf(a, clone);
        add.append(a, .{ .name = clone_param_path, .data = new_param }) catch return error.OutOfMemory;
        add.append(a, .{ .name = pouch_path, .data = new_pouch }) catch return error.OutOfMemory;
        const data = try rebuildWith(a, tmpl_raw.data, &.{}, add.items);
        // a new file: its size entry is set below
        try self.patches.emit(try packOf(a, clone), data, data, tmpl_raw.dictionary, true);

        // resource size table entries for everything new
        var entries: std.ArrayList(SizeEntry) = .empty;
        const clone_key = try packKey(a, clone);
        entries.append(a, .{ .path = clone_key, .size = self.newSize(clone_key, try packKey(a, template), @as(i64, @intCast(data.len)) - @as(i64, @intCast(tmpl_raw.data.len))) }) catch return error.OutOfMemory;
        entries.append(a, .{ .path = clone_param_path, .size = self.newSize(clone_param_path, tmpl_param_path, @as(i64, @intCast(new_param.len)) - @as(i64, @intCast(tmpl_param_bytes.len))) }) catch return error.OutOfMemory;
        entries.append(a, .{ .path = pouch_path, .size = self.newSize(pouch_path, pouch_tmpl_path, @as(i64, @intCast(new_pouch.len)) - @as(i64, @intCast(pouch_tmpl_bytes.len))) }) catch return error.OutOfMemory;
        for (add.items) |f| {
            var listed = false;
            for (entries.items) |e| if (std.mem.eql(u8, e.path, f.name)) {
                listed = true;
            };
            if (listed or self.restbl.get(f.name) != null) continue;
            entries.append(a, .{ .path = f.name, .size = self.newSize(f.name, pouch_tmpl_path, @intCast(f.data.len)) }) catch return error.OutOfMemory;
        }
        try self.setSizes(entries.items, false);
        self.rows.append(self.allocator, .{ .clone = clone, .src = try self.keepText(src), .template = template }) catch return error.OutOfMemory;
        if (!std.mem.eql(u8, model_src, src)) self.model_src.put(clone, try self.keepText(model_src)) catch return error.OutOfMemory;
        return clone;
    }

    const RsdbTable = struct {
        name: []const u8,
        rel: []const u8,
        original: patchset.Latest,
        rows: *byml.Array,
    };

    fn findRow(rows: *byml.Array, id: []const u8) ?*byml.Dict {
        for (rows.items.items) |r| {
            const d = r.asDict() orelse continue;
            if (std.mem.eql(u8, d.getString("__RowId") orelse "", id)) return d;
        }
        return null;
    }

    /// Inserts `row` keeping the rows sorted by __RowId (bisect_left over the ids).
    fn insertSorted(allocator: Allocator, rows: *byml.Array, row: *byml.Dict, id: []const u8) PatchError!void {
        var at: usize = rows.items.items.len;
        for (rows.items.items, 0..) |r, i| {
            const rid = if (r.asDict()) |d| d.getString("__RowId") orelse "" else "";
            if (std.mem.order(u8, rid, id) != .lt) {
                at = i;
                break;
            }
        }
        rows.items.insert(allocator, at, .{ .dict = row }) catch return error.OutOfMemory;
    }

    /// The RSDB rows of every clone (ActorInfo, GameActorInfo, PouchActorInfo).
    pub fn finish(self: *Self) PatchError!void {
        if (self.rows.items.len == 0 and self.auto_rows.items.len == 0) return;
        const a = self.patches.allocator;
        var tables: [3]RsdbTable = undefined;
        for ([_][]const u8{ "ActorInfo", "GameActorInfo", "PouchActorInfo" }, 0..) |t, i| {
            const rel = try self.world.find(a, "RSDB", t);
            const original = try self.patches.read(rel);
            const doc = try byml.load(a, original.data);
            const rows = (doc.root orelse return error.InvalidData).asArray() orelse return error.InvalidData;
            tables[i] = .{ .name = t, .rel = rel, .original = original, .rows = rows };
        }
        for (self.rows.items) |r| {
            for (&tables) |*t| {
                if (findRow(t.rows, r.clone) != null) continue;
                var row: *byml.Dict = undefined;
                if (std.mem.eql(u8, t.name, "PouchActorInfo")) {
                    const base = findRow(t.rows, r.src) orelse continue;
                    row = (try (byml.Value{ .dict = base }).clone(a)).dict;
                    if (self.prices.get(r.clone)) |p| {
                        const buying = row.get("BuyingPrice") orelse byml.Value{ .int = 0 };
                        const selling = row.get("SellingPrice") orelse byml.Value{ .int = 0 };
                        try row.put(a, "BuyingPrice", buying.sameIntType(p));
                        try row.put(a, "SellingPrice", selling.sameIntType(1));
                    }
                } else {
                    const base = findRow(t.rows, r.template) orelse {
                        self.progress.log("warning: no {s} row for {s}", .{ t.name, r.template });
                        continue;
                    };
                    row = (try (byml.Value{ .dict = base }).clone(a)).dict;
                    if (std.mem.eql(u8, t.name, "ActorInfo")) {
                        const s = findRow(t.rows, r.src);
                        if (s) |sd| for (row_from_item) |k| if (sd.get(k)) |v| try row.put(a, k, try v.clone(a));
                        // a borrowed model (songs): its model fields, the item's name
                        if (self.model_src.get(r.clone)) |m_name| {
                            if (findRow(t.rows, m_name)) |m| for (model_row_keys) |k| if (m.get(k)) |v| try row.put(a, k, try v.clone(a));
                        }
                        const actor_name = if (s) |sd| sd.get("ActorName") orelse byml.Value{ .string = r.src } else byml.Value{ .string = r.src };
                        try row.put(a, "ActorName", actor_name);
                        if (s) |sd| for (heap_keys) |k| {
                            const sv = sd.get(k) orelse continue;
                            const current = row.get(k) orelse sv;
                            const larger = @max(current.asInt() orelse 0, sv.asInt() orelse 0);
                            try row.put(a, k, current.sameIntType(larger));
                        };
                    }
                }
                try row.put(a, "__RowId", .{ .string = r.clone });
                try insertSorted(a, t.rows, row, r.clone);
            }
        }
        // after the clones: a walk-over copy may copy a clone's rows
        for (self.auto_rows.items) |r| {
            for (&tables) |*t| {
                if (findRow(t.rows, r.clone) != null) continue;
                const src = findRow(t.rows, r.src) orelse continue;
                const row = (try (byml.Value{ .dict = src }).clone(a)).dict;
                try row.put(a, "__RowId", .{ .string = r.clone });
                try insertSorted(a, t.rows, row, r.clone);
            }
        }
        for (tables) |t| try self.patches.emitZs(t.rel, t.original, try byml.dumpDefault(a, .{ .array = t.rows }));
    }
};

/// Gives the song items themselves Sheik's harp model, so a song shows as a harp wherever it is found (chests,
/// character gifts, scrubs, shop shelves, Gold Skulltula drops). Each Item_Melody_* pack has its own ModelInfo file
/// naming the rupee model; it gets the harp's ModelInfo, and its ActorInfo row the harp's model fields. The
/// song-teaching scenes never show the item's model. Returns the number of songs changed.
pub fn patchSongModels(world: *World, patches: *patchset.PatchSet, restbl: *Restbl, progress: *Progress) PatchError!usize {
    const a = patches.allocator;
    const harp_files = try listFiles(a, (try patches.read(try packOf(a, harp))).data);
    const harp_param = harp_files.get(try paramOf(a, harp)) orelse return warnNoHarp(progress);
    const harp_comps = (try byml.loadDict(a, harp_param)).getDict("Components") orelse return warnNoHarp(progress);
    const harp_ref = harp_comps.getString("ModelInfoRef") orelse return warnNoHarp(progress);
    const harp_info = harp_files.get(refFile(harp_ref)) orelse return warnNoHarp(progress);
    const harp_size = restbl.get(refFile(harp_ref));

    var songs: std.ArrayList([]const u8) = .empty;
    var it = world.actor_packs.keyIterator();
    while (it.next()) |k| if (std.mem.startsWith(u8, k.*, "Item_Melody_")) songs.append(a, k.*) catch return error.OutOfMemory;
    std.mem.sort([]const u8, songs.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.less);

    var changed: std.ArrayList([]const u8) = .empty;
    for (songs.items) |song| {
        const pack = try packOf(a, song);
        const raw = try patches.read(pack);
        const files = try listFiles(a, raw.data);
        const p = files.get(try paramOf(a, song)) orelse continue;
        const comps = (try byml.loadDict(a, p)).getDict("Components") orelse continue;
        const ref = comps.getString("ModelInfoRef") orelse continue;
        const path = refFile(ref);
        const current = files.get(path) orelse continue;
        if (!std.mem.eql(u8, current, harp_info)) {
            const data = try rebuildWith(a, raw.data, &.{.{ .name = path, .data = harp_info }}, &.{});
            try patches.emitZs(pack, raw, data);
            if (restbl.get(path)) |old| {
                if (harp_size != null and harp_size.? > old) restbl.set(path, harp_size.?) catch return error.OutOfMemory;
            }
        }
        changed.append(a, song) catch return error.OutOfMemory;
    }
    if (changed.items.len == 0) return 0;

    const rel = try world.find(a, "RSDB", "ActorInfo");
    const original = try patches.read(rel);
    const doc = try byml.load(a, original.data);
    const rows = (doc.root orelse return error.InvalidData).asArray() orelse return error.InvalidData;
    const harp_row = PickupCloner.findRow(rows, harp) orelse {
        progress.log("warning: no ActorInfo row for {s}; song models only partly changed", .{harp});
        return changed.items.len;
    };
    for (changed.items) |song| {
        const row = PickupCloner.findRow(rows, song) orelse continue;
        for (model_row_keys) |k| if (harp_row.get(k)) |v| try row.put(a, k, try v.clone(a));
    }
    try patches.emitZs(rel, original, try byml.dumpDefault(a, .{ .array = rows }));
    return changed.items.len;
}

fn warnNoHarp(progress: *Progress) usize {
    progress.log("warning: the harp model was not found; songs keep the rupee model in chests and gifts", .{});
    return 0;
}
