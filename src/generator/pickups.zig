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
//! Adapted from OotrR (https://github.com/Mozencaz/OotrR, src/oot_rando/game/item_forms.py and
//! patching/soul_adapter.py; MIT License, Copyright (c) 2026 Mozencaz): the token-based Gold Skulltula drops, the
//! shop shelves, reading an item through its $parent chain (resolvedComponents), the game parameter merge, and the
//! new key items (keyItem). See THIRD_PARTY.md.
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
const ainb = @import("../formats/ainb.zig");
const progressive = @import("../logic/progressive.zig");
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

/// World pickups take the rupee's physics instead of the Fire Arrows': Obj_Arrow_Fire's body is a solid object
/// that blocks the player (LayerEntity Object, contact HitToBlockable), so an item under water (Kokiri Forest's
/// rupees by Mido) had a box Link stood on above it and couldn't swim down to (test report: the Ocarina in the
/// Kokiri Forest water; only the Boomerang got it). A rupee's body (DropItem_0: SmallObject, HitOnlyGroundAndObject)
/// only rests on the ground; its pickup area (Rupee_Tgt_0) is a little larger than the arrows'.
const world_physics_source = "Obj_Rupee_Green";
const world_physics_ref = "?Component/Physics/Rupee.engine__component__PhysicsParam.bgyml";
const world_physics_files = [_][]const u8{
    "Component/Physics/Rupee.engine__component__PhysicsParam.bgyml",
    "Phive/ControllerSetParam/Rupee.phive__ControllerSetParam.bgyml",
    "Phive/RigidBodyEntityParam/DropItem_0.phive__RigidBodyEntityParam.bgyml",
    "Phive/ShapeParam/Rupee_Body_0.phive__ShapeParam.bgyml",
    "Phive/ShapeParam/Rupee_Tgt_0.phive__ShapeParam.bgyml",
    "Phive/ContactCollectionEntityParam/HitOnlyGroundAndObject.phive__ContactCollectionEntityParam.bgyml",
};

/// The game's own pickups whose body is a solid block instead of a rupee's. Why: the Ocarina of Time's pickup (the
/// one Zelda throws into the Hyrule Castle moat) is a 2 x 2 x 2 m stone box (Physics/ObjectDefault -> ControllerSet
/// Box: LayerEntity GroundObject, Mass 2000, contact HitAll), so lying at a randomized spot it was an invisible wall
/// Link couldn't walk into to collect it (test report: the Ocarina in Kokiri Forest). It was used as it is, so the
/// rupee physics every built pickup gets (world_physics_source) never reached it. These are built like any other world
/// pickup (keeping their own model, name and pouch settings), which gives them the rupee's body. Dump check: no other
/// Obj_ pickup with pouch settings has the Box / HitAll body.
const native_pickups_with_solid_body = [_][]const u8{"Obj_Ocarina_Time"};

fn isNativePickupWithSolidBody(actor: []const u8) bool {
    for (native_pickups_with_solid_body) |name| if (std.mem.eql(u8, name, actor)) return true;
    return false;
}

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

/// The inverse of workPath: a reference -> the file inside the pack ("?X.bgyml" -> "X.bgyml", "Work/X.gyml" ->
/// "X.bgyml"), or null for anything else.
fn packPathOfWork(allocator: Allocator, ref: []const u8) error{OutOfMemory}!?[]const u8 {
    if (std.mem.startsWith(u8, ref, "?")) return ref[1..];
    if (std.mem.startsWith(u8, ref, "Work/") and std.mem.endsWith(u8, ref, ".gyml")) {
        return try std.fmt.allocPrint(allocator, "{s}.bgyml", .{ref["Work/".len .. ref.len - ".gyml".len]});
    }
    return null;
}

/// The "Components" of a pack file and of every file it inherits from through `$parent` (inside the same pack), the
/// child's own entries winning. Why: many items only inherit what makes them an item. The bigger bags, quivers and
/// wallets take their PouchContentRef from the smaller one's ActorParam (Item_StickBag_Medium from
/// Item_StickBag_Small), so reading only the item's own file made a Gold Skulltula drop of a Bigger Deku Stick Bag with
/// no pouch settings at all: its pickup played and gave nothing (OotrR resolves the chain the same way,
/// item_forms.resolve_components). Allocated with `allocator`; the file itself must be in the pack.
fn resolvedComponents(allocator: Allocator, files: Files, path: []const u8) PatchError!*byml.Dict {
    const out = try byml.Dict.create(allocator);
    var current: ?[]const u8 = path;
    var depth: usize = 0;
    // a chain is a handful of files long (Item_Quiver_Large > _Medium > _Small > Item_EventObject_Base); the limit only
    // guards against a loop
    while (current) |p| : (depth += 1) {
        if (depth >= 16) break;
        const bytes = files.get(p) orelse break;
        const doc = try byml.loadDict(allocator, bytes);
        if (doc.getDict("Components")) |c| {
            for (c.entries.items) |e| {
                if (!out.contains(e.key)) try out.put(allocator, e.key, e.value);
            }
        }
        const parent = doc.getString("$parent") orelse break;
        current = try packPathOfWork(allocator, parent);
    }
    return out;
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

const RowClone = struct {
    clone: []const u8,
    src: []const u8,
    template: []const u8,
    /// a new key item (keyItem): its own ActorName, `src` only lends the model, the pouch row is the template's
    key_item: bool = false,
    /// a chest display actor (buildChestDisplay): `src` lends the model fields, `display_item` the ActorName and the
    /// pouch row; the animations' row field comes from `src` too only when its animations were taken
    display: bool = false,
    display_item: []const u8 = "",
    display_animation_from_model: bool = false,
    /// a world pickup of an item with no animations of its own: its row keeps the template's AnimationResources,
    /// as its ActorParam keeps the template's AnimationRef (build says why)
    animation_from_template: bool = false,
};

/// The animation list `animation_ref` (an AnimationRef, "?Component/AnimationParam/X.bgyml") names in `files` is
/// empty (the Dummy one the medallions and stones use); false when the file isn't in the pack.
fn animationListIsEmpty(allocator: Allocator, files: Files, animation_ref: []const u8) PatchError!bool {
    const data = files.get(refFile(animation_ref)) orelse return false;
    const param = try byml.loadDict(allocator, data);
    const resources = param.getArray("AnimationResources") orelse return true;
    return resources.items.items.len == 0;
}

/// New key items (key rings, dungeon boss keys) are built like OotrR's: the Forest Medallion's pack (a key item that
/// is shown and held up like any other), with the model of the item they stand for (soul_adapter.build_item_files).
const key_item_template = "Item_Medal_Forest";
/// ActorInfo fields a key item takes from the actor lending its model (OotrR's list).
const key_item_model_keys = [_][]const u8{ "FmdbName", "ModelProjectName", "ModelAabbMax", "ModelAabbMin", "ModelVariationFmabName", "AnimationResources", "ASInfoAutoPlayMaterials" };
/// What a key item takes from the actor lending its model so it is posed and turns like that item (keyItem).
const key_item_animation_refs = [_][]const u8{ "ASRef", "ASInfoRef", "AnimationRef" };
/// Generated actor names stay within the length OotrR saw working in the game: an item get of a 30- or 33-character
/// generated actor crashed (null read, Link holding nothing), 25 characters worked.
pub const max_key_item_name = 25;

/// The game's small chest that checks what the player owns (world.conditionalChestActor).
const small_tier_chest = "Obj_TBox_A_06";
/// "Obj_TBox_A_02" -> "Obj_TBox_A_02_Tier": the big chest that checks what the player owns (bigTierChest)
pub const big_tier_chest_suffix = "_Tier";
/// The refs of Obj_TBox_A_06's ActorParam besides its AIInfoRef: what makes it check (dump: Obj_TBox_A_06.pack)
const tier_check_refs = [_][]const u8{ "ActorHolderRef", "DropRef", "AffiliationRef" };

/// A file of Obj_TBox_A_06's that its check parts read: the holder, the drop logic and its blackboard table.
fn isTierCheckFile(name: []const u8) bool {
    const tier_files = [_][]const u8{
        "Component/ActorHolderParam/Obj_TBox_A_06.game__component__ActorHolderParam.bgyml",
        "Component/DropParam/Obj_TBox_A_06.game__component__DropParam.bgyml",
        "Component/Blackboard/BlackboardParamTable/Drop_TreasureBox_A_06.engine__component__BlackboardParamTable.bgyml",
        "Component/ActorHolderParam/Obj_TBox.game__component__ActorHolderParam.bgyml",
        "Component/DropParam/Obj_TBox.game__component__DropParam.bgyml",
        "Component/DropParam/Default.game__component__DropParam.bgyml",
        "Component/Blackboard/BlackboardParamTable/Drop_TreasureBox.engine__component__BlackboardParamTable.bgyml",
    };
    for (tier_files) |t| if (std.mem.eql(u8, t, name)) return true;
    return false;
}
const AutoRow = struct {
    clone: []const u8,
    src: []const u8,
    /// an actor whose memory the copy needs at least too (the big tier chest runs the small tier chest's AI)
    memory_from: ?[]const u8 = null,
};
/// An existing actor (`actor`) given the model of `model_actor`.
const Restyled = struct { actor: []const u8, model_actor: []const u8 };
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
    /// existing actors given another actor's model (dressInModelOf)
    restyled: std.ArrayList(Restyled) = .empty,
    /// key item -> the item actor its pickups and shelves rest, scale and are boxed like (restLike)
    shown_models: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// shop shelf clone -> its price
    prices: std.StringHashMap(i64),
    /// actor -> the lowest point of its model above its origin (ActorInfo's ModelAabbMin.Y), read once (modelBottom)
    model_bottoms: ?std.StringHashMap(f32) = null,
    /// actor -> the longest side of its model box (ActorInfo ModelAabbMax - ModelAabbMin), read with model_bottoms
    model_sizes: std.StringHashMap(f32) = undefined,
    /// placements raised or lowered by patches.restOnOriginalModelBottom, and the largest move (for the log)
    heights_moved: usize = 0,
    largest_height_move: f64 = 0,

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

    /// Gives the game's own actor `target` the model of `item_actor` (a world-context actor; songs show Sheik's harp),
    /// keeping everything else it has: its AI, its own animations and how other actors know it. For an actor that must
    /// stay itself (Dampé's dig prize, which only he can bring up and which plays its own rise out of the hole).
    /// The pack gets the model's ModelInfo; its ActorInfo row the model's fields and at least its memory (finish).
    /// False (with a warning) when the model can't be read.
    pub fn dressInModelOf(self: *Self, target: []const u8, item_actor: []const u8) PatchError!bool {
        const a = self.patches.allocator;
        const model_actor = if (std.mem.startsWith(u8, item_actor, "Item_Melody_")) harp else item_actor;
        const model_pack = try packOf(a, model_actor);
        if (!self.world.files.exists(model_pack) and !self.patches.current.contains(model_pack)) {
            self.progress.log("warning: no pack for {s}; {s} keeps its model", .{ model_actor, target });
            return false;
        }
        const model_files = try listFiles(a, (try self.patches.read(model_pack)).data);
        const model_param_path = try paramOf(a, model_actor);
        if (!model_files.has(model_param_path)) {
            self.progress.log("warning: {s} has no ActorParam; {s} keeps its model", .{ model_actor, target });
            return false;
        }
        const model_comps = try resolvedComponents(a, model_files, model_param_path);
        const model_info_ref = model_comps.getString("ModelInfoRef") orelse {
            self.progress.log("warning: {s} has no model; {s} keeps its model", .{ model_actor, target });
            return false;
        };

        const target_pack = try packOf(a, target);
        const target_raw = try self.patches.read(target_pack);
        const target_files = try listFiles(a, target_raw.data);
        const target_param_path = try paramOf(a, target);
        const target_param_bytes = target_files.get(target_param_path) orelse return self.progress.fail(error.NotAsExpected, "{s} has no ActorParam", .{target});
        const target_param = try byml.loadDict(a, target_param_bytes);
        const comps = try target_param.ensureDict(a, "Components");
        try comps.put(a, "ModelInfoRef", .{ .string = model_info_ref });
        // the model's ModelInfo files (one, or a chain of $parents) that the pack lacks
        var add: std.ArrayList(sarc.NewFile) = .empty;
        for (model_files.entries) |e| {
            if (!std.mem.startsWith(u8, e.name, "Component/ModelInfo/") or target_files.has(e.name)) continue;
            add.append(a, .{ .name = e.name, .data = e.data }) catch return error.OutOfMemory;
        }
        const new_param = try byml.dump(a, .{ .dict = target_param }, versionOf(target_param_bytes), false);
        const new_pack = try rebuildWith(a, target_raw.data, &.{.{ .name = target_param_path, .data = new_param }}, add.items);
        try self.patches.emitZs(target_pack, target_raw, new_pack);
        // The size table has an entry for each file inside a pack too, which the game reserves to load it. The
        // ActorParam grew (504 to 604 bytes for Dampé's prize), and with its entry left at the old size the game
        // overran it creating the actor (test reports, DIGREWARD1 and DIGTEST2: the Graveyard crashed whatever model
        // it was given, more memory in ActorInfo made no difference). Its entry grows by as much; an added file
        // without an entry of its own gets one.
        if (self.restbl.get(target_param_path)) |old_size| {
            // the file's own entry, updated in place (setSizes is for new paths: it skips a path whose hash is taken)
            const growth: u32 = @intCast(@max(0, @as(i64, @intCast(new_param.len)) - @as(i64, @intCast(target_param_bytes.len))));
            self.restbl.set(target_param_path, old_size + growth) catch return error.OutOfMemory;
        }
        var entries: std.ArrayList(SizeEntry) = .empty;
        for (add.items) |f| {
            if (self.restbl.get(f.name) != null) continue;
            entries.append(a, .{ .path = f.name, .size = self.newSize(f.name, target_param_path, @intCast(f.data.len)) }) catch return error.OutOfMemory;
        }
        try self.setSizes(entries.items, false);
        self.restyled.append(self.allocator, .{
            .actor = try self.keepText(target),
            .model_actor = try self.keepText(model_actor),
        }) catch return error.OutOfMemory;
        return true;
    }

    /// The actor to place in the world for `actor` (a world-context actor). `auto`: the pickup must be collected by
    /// touching it.
    pub fn worldActor(self: *Self, actor: []const u8, auto: bool) PatchError![]const u8 {
        var base = actor;
        if (!std.mem.startsWith(u8, actor, "Obj_") or isNativePickupWithSolidBody(actor)) {
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

    /// Makes key item `actor` (e.g. Item_KeyRing_ForestTemple) with the model of `model` (Item_Dungeon_SmallKey or
    /// Item_Dungeon_BossKey): its pack, size table entries and (in finish) its RSDB rows. Its save flags, texts and
    /// what it does when got are keyitems.zig's.
    pub fn keyItem(self: *Self, actor: []const u8, model: []const u8) PatchError!void {
        if (actor.len > max_key_item_name) return self.progress.fail(error.NotAsExpected, "key item name too long for the game: {s}", .{actor});
        const a = self.patches.allocator;
        const tmpl_raw = try self.patches.read(try packOf(a, key_item_template));
        const tmpl = try listFiles(a, tmpl_raw.data);
        const model_files = try listFiles(a, (try self.patches.read(try packOf(a, model))).data);
        const tmpl_param_path = try paramOf(a, key_item_template);
        const tmpl_param_bytes = tmpl.get(tmpl_param_path) orelse return self.progress.fail(error.NotAsExpected, "{s} has no ActorParam", .{key_item_template});
        // the model's ModelInfo: the file named after it, or else the one its ActorParam names. Why: the Fairy
        // Ocarina's display actor (Pouch_Ocarina_Fairy, a progressive pickup's model) uses Item_Ocarina_Fairy's
        const named_model_path = std.fmt.allocPrint(a, "Component/ModelInfo/{s}.engine__component__ModelInfo.bgyml", .{model}) catch return error.OutOfMemory;
        const model_path = if (model_files.has(named_model_path)) named_model_path else blk: {
            const comps = try resolvedComponents(a, model_files, try paramOf(a, model));
            const ref = comps.getString("ModelInfoRef") orelse return self.progress.fail(error.NotAsExpected, "{s} has no ModelInfo", .{model});
            break :blk refFile(ref);
        };
        const model_bytes = model_files.get(model_path) orelse return self.progress.fail(error.NotAsExpected, "{s} has no ModelInfo", .{model});

        const param = try byml.loadDict(a, tmpl_param_bytes);
        const comps = try param.ensureDict(a, "Components");
        const new_model_path = std.fmt.allocPrint(a, "Component/ModelInfo/{s}.engine__component__ModelInfo.bgyml", .{actor}) catch return error.OutOfMemory;
        try comps.put(a, "ModelInfoRef", .{ .string = std.fmt.allocPrint(a, "?{s}", .{new_model_path}) catch return error.OutOfMemory });
        // Why its own name: the game tells pouch items apart by their ActorName; with the template's, every new item
        // counted as the Forest Medallion and its IsGet flag was never set (OotrR, in-game test of the souls).
        if (!comps.contains("ActorNameRef")) return self.progress.fail(error.NotAsExpected, "{s} has no ActorNameRef", .{key_item_template});
        try comps.put(a, "ActorNameRef", .{ .string = std.fmt.allocPrint(a, "?ActorSystem/ActorName/{s}.engine__actor__ActorName.bgyml", .{actor}) catch return error.OutOfMemory });
        var add: std.ArrayList(sarc.NewFile) = .empty;
        // Why the model's animation set: held up in Link's hands, the small key is posed by its own animations
        // (Pose_GetDemo, played through the common item AS). With the Forest Medallion's demo-only AS and empty
        // animation list, a key ring stood on its tip at the hand point and reached 0.56 m above Link's head (test
        // report). The RSDB row already takes the model's AnimationResources and memory sizes (finish).
        const model_param = model_files.get(try paramOf(a, model)) orelse return self.progress.fail(error.NotAsExpected, "{s} has no ActorParam", .{model});
        const model_comps = (try byml.loadDict(a, model_param)).getDict("Components") orelse return self.progress.fail(error.NotAsExpected, "{s} has no components", .{model});
        for (key_item_animation_refs) |ref_key| {
            const ref = model_comps.getString(ref_key) orelse continue;
            try comps.put(a, ref_key, .{ .string = ref });
            const file = refFile(ref);
            if (tmpl.has(file)) continue;
            const data = model_files.get(file) orelse continue; // found by the game elsewhere, as for the model itself
            var already = false;
            for (add.items) |f| if (std.mem.eql(u8, f.name, file)) {
                already = true;
            };
            if (!already) add.append(a, .{ .name = file, .data = data }) catch return error.OutOfMemory;
        }
        const new_param = try byml.dump(a, .{ .dict = param }, versionOf(tmpl_param_bytes), false);
        const new_param_path = try paramOf(a, actor);

        add.append(a, .{ .name = new_param_path, .data = new_param }) catch return error.OutOfMemory;
        add.append(a, .{ .name = new_model_path, .data = model_bytes }) catch return error.OutOfMemory;
        // the template's own ActorParam and ModelInfo stay in the pack unused (the archive writer only replaces or
        // adds files); the game loads the actor by its own name
        const data = try rebuildWith(a, tmpl_raw.data, &.{}, add.items);
        try self.patches.emit(try packOf(a, actor), data, data, tmpl_raw.dictionary, true);

        const clone_key = try packKey(a, actor);
        var entries: std.ArrayList(SizeEntry) = .empty;
        entries.append(a, .{ .path = clone_key, .size = self.newSize(clone_key, try packKey(a, key_item_template), @as(i64, @intCast(data.len)) - @as(i64, @intCast(tmpl_raw.data.len))) }) catch return error.OutOfMemory;
        entries.append(a, .{ .path = new_param_path, .size = self.newSize(new_param_path, tmpl_param_path, @as(i64, @intCast(new_param.len)) - @as(i64, @intCast(tmpl_param_bytes.len))) }) catch return error.OutOfMemory;
        entries.append(a, .{ .path = new_model_path, .size = self.newSize(new_model_path, model_path, 0) }) catch return error.OutOfMemory;
        try self.setSizes(entries.items, false);
        self.rows.append(self.allocator, .{ .clone = try self.keepText(actor), .src = try self.keepText(model), .template = key_item_template, .key_item = true }) catch return error.OutOfMemory;
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
        if (!self.world.files.exists(src_pack) and !self.patches.current.contains(src_pack)) {
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
        if (!item.has(src_param_path)) {
            self.progress.log("warning: {s} has no ActorParam; it can't be made into a world pickup", .{src});
            return null;
        }
        const tmpl_param_bytes = tmpl.get(tmpl_param_path) orelse {
            self.progress.log("warning: {s} has no ActorParam; it can't be made into a world pickup", .{src});
            return null;
        };
        // with what the item inherits through $parent (resolvedComponents says why)
        const src_comps = try resolvedComponents(a, item, src_param_path);
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
        // An item with no animations of its own (the medallions and Spiritual Stones, whose scenes animate them, and
        // the key rings and boss keys built on the Forest Medallion) keeps the template's: those hold the common
        // item animations, the turn included, and their models have its Root bone. With the item's empty list the
        // pickup lay still (test report: key rings, medallions, stones on the ground).
        var animation_from_template = false;
        if (!shop) if (src_comps.getString("AnimationRef")) |item_animation_ref| {
            if (try animationListIsEmpty(a, item, item_animation_ref)) {
                const template_comps = (try byml.loadDict(a, tmpl_param_bytes)).getDict("Components");
                if (template_comps) |tc| if (tc.get("AnimationRef")) |template_animation_ref| {
                    try comps.put(a, "AnimationRef", template_animation_ref);
                    animation_from_template = true;
                };
            }
        };

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
        // a progressive item lying in the world: its item get must play for every copy, as it is what hands over the
        // next tier (progressive_pickups.zig); a key item's plays once otherwise
        if (progressive.chainOfGroundPickupItem(src) != null) try pouch.put(a, "PlayGetEventManyTimes", .{ .bool = true });
        if (token) {
            try pouch.put(a, "PlayGetEventManyTimes", .{ .bool = true });
            try pouch.put(a, "IsPlayGetEventPouchMax", .{ .bool = true });
        }
        _ = pouch.remove("IsPickedUpEmitXlinkKey");
        _ = pouch.remove("PickedUpEmitXlinkKey");
        const pouch_path = std.fmt.allocPrint(a, "Component/PouchContentParam/{s}.game__component__PouchContentParam.bgyml", .{clone}) catch return error.OutOfMemory;
        try comps.put(a, "PouchContentRef", .{ .string = std.fmt.allocPrint(a, "?{s}", .{pouch_path}) catch return error.OutOfMemory });

        var add: std.ArrayList(sarc.NewFile) = .empty;
        if (!token and !shop) {
            // a world pickup: the rupee's physics (world_physics_source says why)
            const physics_pack = try listFiles(a, (try self.patches.read(try packOf(a, world_physics_source))).data);
            for (world_physics_files) |name| {
                if (tmpl.has(name)) continue;
                const d = physics_pack.get(name) orelse return self.progress.fail(error.NotAsExpected, "{s} has no {s}", .{ world_physics_source, name });
                add.append(a, .{ .name = name, .data = d }) catch return error.OutOfMemory;
            }
            try comps.put(a, "PhysicsRef", .{ .string = world_physics_ref });
        }
        for (item.entries) |e| {
            if (tmpl.has(e.name) or std.mem.startsWith(u8, e.name, "Actor/") or std.mem.startsWith(u8, e.name, "AI/")) continue;
            var already_added = false;
            for (add.items) |f| if (std.mem.eql(u8, f.name, e.name)) {
                already_added = true;
            };
            if (already_added) continue;
            add.append(a, .{ .name = e.name, .data = e.data }) catch return error.OutOfMemory;
        }
        const table_path = std.fmt.allocPrint(a, "GameParameter/GameParameterTable/{s}.engine__actor__GameParameterTable.bgyml", .{clone}) catch return error.OutOfMemory;
        if (token) {
            // the item's game parameters (bag sizes, equipment, ...) plus the pickup's own drop/physics ones
            const base_bytes = tmpl.get("GameParameter/GameParameterTable/Obj_Item_Base.engine__actor__GameParameterTable.bgyml") orelse
                return self.progress.fail(error.NotAsExpected, "the token pack has no item parameter table", .{});
            const base = try byml.loadDict(a, base_bytes);
            const src_ref = src_comps.getString("GameParameterTableRef");
            const src_table_path = if (src_ref) |r| try packPathOfWork(a, r) else null;
            const has_table = src_table_path != null and item.has(src_table_path.?);
            const table = if (has_table) try byml.loadDict(a, item.get(src_table_path.?).?) else try byml.Dict.create(a);
            _ = table.remove("$parent");
            if (!table.contains("Category")) try table.put(a, "Category", base.get("Category") orelse byml.Value{ .string = "GameParameterTableDefault" });
            // the pickup's own parameters (drop, physics, menu) stay; the item adds what it has beyond them (bag
            // capacity, equipment, ...), its inherited ones included. As OotrR merges them
            // (item_forms._merge_game_parameters).
            const merged = if (base.getDict("Components")) |bc| (try (byml.Value{ .dict = bc }).clone(a)).dict else try byml.Dict.create(a);
            if (has_table) {
                const item_table = try resolvedComponents(a, item, src_table_path.?);
                for (item_table.entries.items) |e| {
                    if (!merged.contains(e.key)) try merged.put(a, e.key, e.value);
                }
            }
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
        self.rows.append(self.allocator, .{ .clone = clone, .src = try self.keepText(src), .template = template, .animation_from_template = animation_from_template }) catch return error.OutOfMemory;
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

    /// How far below (negative) or above its origin `actor`'s model starts: ActorInfo's ModelAabbMin.Y. A clone made
    /// here answers with the model it borrows (the item's, or the harp for songs), a walk-over copy with its source's.
    /// Null when the game has no model box for it.
    ///
    /// Why: the game's world pickups (Obj_*) have their origin at the model's bottom, the item-get models (Item_*) at
    /// its middle, the arrow shelf below it; an item put in another one's place floated or sank by the difference
    /// (a heart high above a Goron Shop shelf, an item half inside a Lost Woods stump). patches.zig moves the placement
    /// by it, so the new model's bottom rests where the old one's did.
    pub fn modelBottom(self: *Self, actor: []const u8) PatchError!?f32 {
        const bottoms = try self.loadModelBottoms();
        const model_actor = self.modelActorOf(actor);
        return bottoms.get(displayBoxActorOf(model_actor) orelse model_actor);
    }

    /// Items whose own ActorInfo row has the model box of how Link wears them, not how the item is shown: the
    /// Gauntlets' box is the pair on his arms, 1.17 m up and 1.6 m wide, while the same model and animations are
    /// drawn around the origin (their Pouch_ actor's box, -0.21 to +0.22). A pickup with the worn box rested a metre
    /// off and wasn't drawn at all (the game culls a model by its box; HEIGHTTEST1). Pickups take the display box.
    const display_box_actors = [_]struct { item: []const u8, box_from: []const u8 }{
        .{ .item = "Item_Gauntlet_Silver", .box_from = "Pouch_Gauntlet_Silver" },
        .{ .item = "Item_Gauntlet_Gold", .box_from = "Pouch_Gauntlet_Gold" },
        // The Goron Bracelet's own box is only its middle (-0.03 to +0.04 m); its Pouch_ actor, the same model and
        // animations, has the box of the whole bracelet as drawn (-0.12 to +0.13), so it rests like the Gauntlets.
        .{ .item = "Item_Gauntlet_Goron", .box_from = "Pouch_Gauntlet_Goron" },
    };

    /// Items whose own row has their worn box and no Pouch_ actor to lend a display box: the Lens of Truth's box is
    /// where it sits on Link's eye, 0.92 to 1.04 m above its origin, while as a pickup it is drawn around the origin
    /// (Item_Common_Animation, as the Gauntlets are). Rested on that box, it was put 0.25 m into the ground and not
    /// seen: test report, seed BWNKNDCCY3, the Lens on Kokiri Forest's rupee spot 7 by the shop could be picked up
    /// but wasn't there (and HEIGHTTEST1 "barely seen in the stream"). Their box is moved down onto the origin, the
    /// same size: for the resting height (modelBottom) and for the pickup's ActorInfo row (the game culls by it).
    const recentred_box_actors = [_][]const u8{"Item_GlassTruth"};

    fn isRecentred(model_actor: []const u8) bool {
        for (recentred_box_actors) |name| if (std.mem.eql(u8, name, model_actor)) return true;
        return false;
    }

    fn displayBoxActorOf(item: []const u8) ?[]const u8 {
        for (display_box_actors) |entry| if (std.mem.eql(u8, entry.item, item)) return entry.box_from;
        return null;
    }

    /// The shop shelves' shelf tops: for each shuffleable shelf, how far above its origin the shelf it stands on is
    /// (metres, up). An item put on the shelf rests there (patches.zig restOnOriginalModelBottom), instead of where
    /// the shelf item's model box says its bottom is, which many shelf models get wrong: the Deku Stick's box is
    /// the stick lying down (from -0.38 m), the arrows' and Deku Seeds' boxes reach 0.13 to 0.16 m below them, the
    /// pots stand lower than their shelf.
    ///
    /// Each shop row (the shelves at one height, both cabinets) has one shelf top: the average of the tops its
    /// trusted shelves give (row height + their own offset), which agree within 2 cm where measured, except the
    /// Potion Shops' upper row (4 cm between jars and pots: both are now 2 cm off). Trusted: measured in-game, the
    /// Deku Stick 0.045 and Deku Seed bundles 0.06 (Kokiri Shop against the nut bundles and recovery heart,
    /// HEIGHTTEST1) and the Potion Shops' pots 0.04 (SHELFTEST1); model box confirmed in-game, the recovery heart
    /// (0.034), the Deku Nut bundles and the jars (a Heart Container on the Poe jar shelf sat right, SHELFTEST1).
    /// A row with no trusted shelf (the Zora Shop's upper one: pots and arrows) takes the average offset its shelf
    /// models get in the rows that have one. The Bombchu Shop's shelves are in no measured row: their model box
    /// stays (not in the table). Each shop's copies in the child, adult and alternative stage files stand alike
    /// (one Kokiri Shop shelf differs by 1 cm between child and adult). Worked out from the shelves' heights in the
    /// stage files (the first copy of each shop); before this table, each shelf model had a guess of its own.
    const shelf_tops = [_]struct { location: []const u8, top: f32 }{
        .{ .location = "Goron Shop Item 1", .top = 0.034 },
        .{ .location = "Goron Shop Item 2", .top = 0.090 },
        .{ .location = "Goron Shop Item 3", .top = -0.002 },
        .{ .location = "Goron Shop Item 4", .top = 0.003 },
        .{ .location = "Goron Shop Item 5", .top = 0.095 },
        .{ .location = "Goron Shop Item 6", .top = 0.095 },
        .{ .location = "Goron Shop Item 7", .top = 0.007 },
        .{ .location = "Goron Shop Item 8", .top = 0.007 },

        .{ .location = "Kakariko Bazaar Item 1", .top = 0.024 },
        .{ .location = "Kakariko Bazaar Item 2", .top = -0.001 },
        .{ .location = "Kakariko Bazaar Item 3", .top = 0.057 },
        .{ .location = "Kakariko Bazaar Item 4", .top = 0.043 },
        .{ .location = "Kakariko Bazaar Item 5", .top = 0.007 },
        .{ .location = "Kakariko Bazaar Item 6", .top = 0.007 },
        .{ .location = "Kakariko Bazaar Item 7", .top = 0.048 },
        .{ .location = "Kakariko Bazaar Item 8", .top = 0.048 },

        .{ .location = "Kakariko Potion Shop Item 1", .top = 0.019 },
        .{ .location = "Kakariko Potion Shop Item 2", .top = 0.019 },
        .{ .location = "Kakariko Potion Shop Item 3", .top = -0.001 },
        .{ .location = "Kakariko Potion Shop Item 4", .top = -0.002 },
        .{ .location = "Kakariko Potion Shop Item 5", .top = 0.020 },
        .{ .location = "Kakariko Potion Shop Item 6", .top = 0.018 },
        .{ .location = "Kakariko Potion Shop Item 7", .top = -0.002 },
        .{ .location = "Kakariko Potion Shop Item 8", .top = -0.002 },

        .{ .location = "Kokiri Shop Item 1", .top = 0.038 },
        .{ .location = "Kokiri Shop Item 2", .top = 0.063 },
        .{ .location = "Kokiri Shop Item 3", .top = -0.007 },
        .{ .location = "Kokiri Shop Item 4", .top = 0.005 },
        .{ .location = "Kokiri Shop Item 5", .top = 0.053 },
        .{ .location = "Kokiri Shop Item 6", .top = 0.059 },
        .{ .location = "Kokiri Shop Item 7", .top = 0.004 },
        .{ .location = "Kokiri Shop Item 8", .top = 0.042 },

        .{ .location = "Market Bazaar Item 1", .top = 0.024 },
        .{ .location = "Market Bazaar Item 2", .top = -0.001 },
        .{ .location = "Market Bazaar Item 3", .top = 0.057 },
        .{ .location = "Market Bazaar Item 4", .top = 0.043 },
        .{ .location = "Market Bazaar Item 5", .top = 0.007 },
        .{ .location = "Market Bazaar Item 6", .top = 0.007 },
        .{ .location = "Market Bazaar Item 7", .top = 0.048 },
        .{ .location = "Market Bazaar Item 8", .top = 0.048 },

        .{ .location = "Market Potion Shop Item 1", .top = 0.019 },
        .{ .location = "Market Potion Shop Item 2", .top = 0.019 },
        .{ .location = "Market Potion Shop Item 3", .top = -0.001 },
        .{ .location = "Market Potion Shop Item 4", .top = -0.002 },
        .{ .location = "Market Potion Shop Item 5", .top = 0.020 },
        .{ .location = "Market Potion Shop Item 6", .top = 0.018 },
        .{ .location = "Market Potion Shop Item 7", .top = -0.002 },
        .{ .location = "Market Potion Shop Item 8", .top = -0.002 },

        .{ .location = "Zora Shop Item 1", .top = 0.043 },
        .{ .location = "Zora Shop Item 2", .top = 0.043 },
        .{ .location = "Zora Shop Item 3", .top = -0.001 },
        .{ .location = "Zora Shop Item 4", .top = 0.027 },
        .{ .location = "Zora Shop Item 5", .top = 0.019 },
        .{ .location = "Zora Shop Item 6", .top = 0.019 },
        .{ .location = "Zora Shop Item 7", .top = -0.002 },
        .{ .location = "Zora Shop Item 8", .top = -0.020 },
    };

    /// How far above its origin shop shelf `location` (its check's name) has its shelf top, or null for a shelf the
    /// table doesn't know (its model box gives it then).
    pub fn shelfTopAboveOrigin(location: []const u8) ?f32 {
        for (shelf_tops) |entry| if (std.mem.eql(u8, entry.location, location)) return entry.top;
        return null;
    }

    /// Height corrections for shop shelves only (metres at full size, up; scaled with the item), by the actor whose
    /// model is shown. The magic arrows' boxes reach 0.37 m below the arrow drawn on a shelf: with the true shelf
    /// tops above, every arrow test (Fire and Ice on the seed shelf, Light on the stick and heart shelves; HEIGHTTEST1,
    /// HEIGHTTEST2, TEST075) comes within 1 cm of where it looked right. Sheik's harp rests with its origin on the
    /// shelf (SONGSHOP1, TEST075), though its box is centred on it. Ground pickups don't use these: the arrows there
    /// replace items of their own kind of box.
    const shelf_measured_lift = [_]struct { model_actor: []const u8, lift: f64 }{
        .{ .model_actor = "Item_Arrow_Fire", .lift = -0.37 },
        .{ .model_actor = "Item_Arrow_Ice", .lift = -0.37 },
        .{ .model_actor = "Item_Arrow_Light", .lift = -0.37 },
        .{ .model_actor = harp, .lift = -0.25 },
        // The scales are drawn about 0.22 m below their box on a shelf: a Silver Scale on the Market Potion Shop's
        // Half Milk shelf sank 0.04 m low by its box, then its top stood 0.15 m below where its box puts it next to
        // the seated jars (test reports, seeds FBRZU9NLY4 and SHELFMALON1; measured from the screenshots, to confirm
        // with SHELFTEST1). The Golden Scale is the same kind of model.
        .{ .model_actor = "Item_Scale_Silver", .lift = 0.22 },
        .{ .model_actor = "Item_Scale_Gold", .lift = 0.22 },
        // The Bomb Bag's cushion is drawn about 0.05 m below its box: on the Market Bazaar's Deku Stick shelf it dipped
        // into the shelf (about 20 px of its 112 px height; test report, SHELFTEST1), while Farore's Wind sat right on
        // the same shelf. The bigger bags are the same model.
        .{ .model_actor = "Item_BombBag_Small", .lift = 0.05 },
        .{ .model_actor = "Item_BombBag_Medium", .lift = 0.05 },
        .{ .model_actor = "Item_BombBag_Large", .lift = 0.05 },
        // Estimated from screenshots, to confirm in-game (test report, seed PROGFINAL01). The Quiver is drawn far below
        // its box (0 to 0.55 m) on a shelf: on the Market Bazaar's arrow shelf (Item 4) only its feather tips showed
        // above the shelf's "x 10" board, about 0.25 m too low by the shield and nuts next to it. The bigger one is the
        // same model.
        .{ .model_actor = "Item_Quiver_Medium", .lift = 0.25 },
        .{ .model_actor = "Item_Quiver_Large", .lift = 0.25 },
        // Slightly sunk into the Market Potion Shop's shelves, about 3 cm by the jars next to them: the Fairy Ocarina
        // lying on the lower left shelf (Item 3), the Deku Seed Bag on the upper one (Item 2), the Stone of Agony on
        // the upper right (Item 6). The Ocarina of Time and the bigger bag are the same models.
        .{ .model_actor = "Item_Ocarina_Fairy", .lift = 0.03 },
        .{ .model_actor = "Item_Ocarina_Time", .lift = 0.03 },
        .{ .model_actor = "Item_BulletBag_Medium", .lift = 0.03 },
        .{ .model_actor = "Item_BulletBag_Large", .lift = 0.03 },
        .{ .model_actor = "Item_AgonyStone", .lift = 0.03 },
    };

    /// The shelf-only correction for `actor`'s model (0 when there is none).
    pub fn shelfMeasuredLift(self: *const Self, actor: []const u8) f64 {
        const model_actor = self.modelActorOf(actor);
        for (shelf_measured_lift) |entry| if (std.mem.eql(u8, entry.model_actor, model_actor)) return entry.lift;
        return 0;
    }

    /// The actor whose model `actor` shows: a walk-over copy's source, a clone's item (or borrowed model).
    fn modelActorOf(self: *const Self, actor: []const u8) []const u8 {
        var model_actor = actor;
        for (self.auto_rows.items) |r| if (std.mem.eql(u8, r.clone, model_actor)) {
            model_actor = r.src;
        };
        for (self.rows.items) |r| if (std.mem.eql(u8, r.clone, model_actor)) {
            model_actor = self.model_src.get(r.clone) orelse r.src;
        };
        // a progressive item's stand-in (progressive_pickups.zig) shows the model its key item borrows (the first
        // tier's): it rests and is boxed like that item. Only these: the key rings' pickups keep resting as they
        // were tested in-game
        if (self.shown_models.get(model_actor)) |shown| return shown;
        return model_actor;
    }

    /// The pickups and shelves made from key item `item` rest, scale and are boxed exactly as those of item actor
    /// `old_actor` always have (modelActorOf): the height, shelf and box corrections are all keyed by it.
    pub fn restLike(self: *Self, item: []const u8, old_actor: []const u8) PatchError!void {
        self.shown_models.put(self.allocator, try self.keepText(item), try self.keepText(old_actor)) catch return error.OutOfMemory;
    }

    /// Height corrections measured in the game, for models the model box gets wrong (metres, up), by the actor
    /// whose model is shown. Add a line when a test seed shows an item still floating or sinking.
    const measured_extra_lift = [_]struct { model_actor: []const u8, lift: f64 }{
        // HEIGHTTEST1: the Iron Boots sank about a quarter of their height into the ground (their box starts at
        // 0); the Hover Boots are the same kind of worn model
        .{ .model_actor = "Item_HeavyBoot", .lift = 0.10 },
        .{ .model_actor = "Item_HoverBoot", .lift = 0.10 },
        // (the Lens of Truth's 0.10 m here made up for resting it on its worn box: recentred_box_actors now)
    };

    /// A shop shelf's item shown at this scale: big models (Heart Containers, the Hammer, the Gauntlets: a model box
    /// side over shop_big_item_size) at half size, so they fit the shelf (test request, HEIGHTTEST1); 1 otherwise.
    pub fn shopShelfScale(self: *Self, shelf_actor: []const u8) PatchError!f64 {
        _ = try self.loadModelBottoms();
        const model_actor = self.modelActorOf(shelf_actor);
        if (std.mem.eql(u8, model_actor, harp)) return song_shelf_harp_scale;
        // the size as drawn (display_box_actors): the Gauntlets' own box is the worn pair, 1.6 m wide
        const longest = self.model_sizes.get(displayBoxActorOf(model_actor) orelse model_actor) orelse return 1.0;
        return if (longest > shop_big_item_size) shop_big_item_scale else 1.0;
    }
    const shop_big_item_size: f32 = 0.5;
    const shop_big_item_scale: f64 = 0.5;

    /// A song's shelf (Songs Anywhere) shows Sheik's harp. It is a flat frame (0.59 m wide, 0.5 m tall, 0.12 m
    /// thick): halved like the other big items, and seen edge-on, it was a thin sliver on the shelf (SONGSHOP1).
    /// At 0.75 it was still a little small (TEST075); at 0.9 it is 0.53 m wide, like the shelf's half-size arrows.
    const song_shelf_harp_scale: f64 = 0.9;

    /// The turn (radians, about the vertical axis) added to a shelf's own so its item faces the shop: the harp's
    /// flat side faces along its model's Z axis, a quarter turn from how the shelves show their items; 0 for
    /// every other item (they already face the front).
    pub fn shopShelfTurn(self: *const Self, shelf_actor: []const u8) f64 {
        return if (std.mem.eql(u8, self.modelActorOf(shelf_actor), harp)) std.math.pi / 2.0 else 0.0;
    }

    /// The measured correction for `actor`'s model (0 when there is none).
    pub fn measuredExtraLift(self: *const Self, actor: []const u8) f64 {
        const model_actor = self.modelActorOf(actor);
        for (measured_extra_lift) |entry| if (std.mem.eql(u8, entry.model_actor, model_actor)) return entry.lift;
        return 0;
    }

    fn loadModelBottoms(self: *Self) PatchError!*std.StringHashMap(f32) {
        if (self.model_bottoms) |*loaded| return loaded;
        var bottoms = std.StringHashMap(f32).init(self.allocator);
        self.model_sizes = std.StringHashMap(f32).init(self.allocator);
        const scratch = self.patches.allocator;
        const rel = try self.world.find(scratch, "RSDB", "ActorInfo");
        const original = try self.patches.read(rel);
        const doc = try byml.load(scratch, original.data);
        const rows = (doc.root orelse return error.InvalidData).asArray() orelse return error.InvalidData;
        for (rows.items.items) |r| {
            const row = r.asDict() orelse continue;
            const name = row.getString("__RowId") orelse row.getString("ActorName") orelse continue;
            const box_min = row.getDict("ModelAabbMin") orelse continue;
            const bottom = (box_min.get("Y") orelse continue).asFloat() orelse continue;
            const kept_name = try self.keepText(name);
            bottoms.put(kept_name, @floatCast(bottom)) catch return error.OutOfMemory;
            if (row.getDict("ModelAabbMax")) |box_max| {
                var longest: f64 = 0;
                for ([_][]const u8{ "X", "Y", "Z" }) |axis| {
                    const low = (box_min.get(axis) orelse continue).asFloat() orelse continue;
                    const high = (box_max.get(axis) orelse continue).asFloat() orelse continue;
                    longest = @max(longest, high - low);
                }
                self.model_sizes.put(kept_name, @floatCast(longest)) catch return error.OutOfMemory;
                // a worn box moved onto the origin (recentred_box_actors): its bottom is half its height down
                if (isRecentred(name)) {
                    const top = (box_max.get("Y") orelse continue).asFloat() orelse continue;
                    bottoms.put(kept_name, @floatCast(-(top - bottom) / 2.0)) catch return error.OutOfMemory;
                }
            }
        }
        self.model_bottoms = bottoms;
        return &self.model_bottoms.?;
    }

    /// The actor a chest holds for an item whose Item_ actor isn't drawn held up (the Ocarinas: equipment Link
    /// wears), built from its Pouch_ actor: "Item_Rando_<item>".
    ///
    /// Why: in a chest, the Ocarina's Item_ actor (equipment) and then its Pouch_ actor (a pouch display, Pouch_Item_Base)
    /// were both invisible held up (HEIGHTTEST1, ITEMTEST01). The items that do show are Item_EventObject_Base actors
    /// with the item-get animation set (the Hookshot, the Stone of Agony). So the display actor is the Stone of Agony's
    /// actor (template) with the Pouch_ actor's model, animations, pouch settings and ActorName: the game gives the
    /// item the ActorName names (the real Ocarina), as it does for the Pouch_ actor itself. The Stone of Agony's own
    /// parts (its capture icon and game parameters) are left out. Returns null if it can't be built.
    pub fn chestDisplayActor(self: *Self, item_base: []const u8) PatchError!?[]const u8 {
        const a = self.patches.allocator;
        const k = try self.key("chest_display", item_base, null);
        if (self.made.get(k)) |made| return made;
        const clone = std.fmt.allocPrint(self.allocator, "Item_Rando_{s}", .{item_base}) catch return error.OutOfMemory;
        const pouch_actor = try self.keepText(std.fmt.allocPrint(a, "Pouch_{s}", .{item_base}) catch return error.OutOfMemory);
        const built = try self.buildChestDisplay(clone, .{
            .model = pouch_actor,
            .animation = pouch_actor,
            .item = pouch_actor,
        });
        self.made.put(k, built) catch return error.OutOfMemory;
        return built;
    }

    /// Songs Anywhere: the actor a chest holds for a song, "Item_RSong_<song>" (Item_Melody_ZeldaLullaby ->
    /// Item_RSong_ZeldaLullaby), so the harp turns in Link's hands like any item.
    ///
    /// Why a display actor: three tries (0.7.5) that gave the song items (Item_Melody_*) the item-get animation set
    /// themselves all crashed Longshot creating the song item when a chest holding it loaded. The Ocarinas' chest
    /// display actor, the whole Stone of Agony actor with another item's parts, loads and spins (HEIGHTTEST1). This is
    /// the same: the Stone of Agony with Sheik's harp model, the song's ActorName (so the song is given) and pouch
    /// settings, and the Stone of Agony's own spin animations (Item_Common_Animation's turn, its skeleton-only pose,
    /// on Root and Skl_Root, which the harp has). Off with song_chest_spin_enabled if it crashes. Null if not built.
    pub fn songChestActor(self: *Self, song_actor: []const u8) PatchError!?[]const u8 {
        if (!song_chest_spin_enabled) return null;
        if (!std.mem.startsWith(u8, song_actor, "Item_Melody_")) return null;
        const k = try self.key("song_chest", song_actor, null);
        if (self.made.get(k)) |made| return made;
        const clone = std.fmt.allocPrint(self.allocator, "Item_RSong_{s}", .{song_actor["Item_Melody_".len..]}) catch return error.OutOfMemory;
        const built = try self.buildChestDisplay(clone, .{
            .model = harp,
            .animation = null,
            .item = try self.keepText(song_actor),
            .model_scale = song_chest_harp_scale,
        });
        self.made.put(k, built) catch return error.OutOfMemory;
        return built;
    }
    pub const song_chest_spin_enabled = true;
    /// Sheik's harp is sized for Sheik: held up by Link it was far too big, and at 0.5 still touched his head (HEIGHTTEST1)
    const song_chest_harp_scale: f32 = 0.35;

    /// Where a chest display actor's parts come from: the model (ModelInfoRef), the animations (AnimationRef; null:
    /// the template's own), and the item (ActorNameRef and PouchContentRef, and the ActorInfo ActorName and pouch row).
    /// `model_scale`: the model shown at this size (a copy of its ModelInfo with DebugModelScale, the scale field the
    /// game's own ModelInfo files use, e.g. the pigeons' 0.6), null for its own size.
    const DisplayParts = struct { model: []const u8, animation: ?[]const u8, item: []const u8, model_scale: ?f32 = null };

    const display_template = "Item_AgonyStone";
    const display_refs_dropped = [_][]const u8{ "CaptureRef", "GameParameterTableRef" };

    fn buildChestDisplay(self: *Self, clone: []const u8, parts: DisplayParts) PatchError!?[]const u8 {
        if (clone.len > max_key_item_name) {
            self.progress.log("warning: {s} is too long an actor name for the game; the chest keeps the item's own actor", .{clone});
            return null;
        }
        const a = self.patches.allocator;
        if (!self.world.files.exists(try packOf(a, display_template))) return null;
        const tmpl_raw = try self.patches.read(try packOf(a, display_template));
        const tmpl = try listFiles(a, tmpl_raw.data);
        const tmpl_param_path = try paramOf(a, display_template);
        const tmpl_param_bytes = tmpl.get(tmpl_param_path) orelse return null;

        const param = try byml.loadDict(a, tmpl_param_bytes);
        const comps = try param.ensureDict(a, "Components");
        var add: std.ArrayList(sarc.NewFile) = .empty;
        const RefSource = struct { key: []const u8, actor: ?[]const u8 };
        const ref_sources = [_]RefSource{
            .{ .key = "ModelInfoRef", .actor = parts.model },
            .{ .key = "AnimationRef", .actor = parts.animation },
            .{ .key = "ActorNameRef", .actor = parts.item },
            .{ .key = "PouchContentRef", .actor = parts.item },
        };
        for (ref_sources) |source| {
            const source_actor = source.actor orelse continue; // keep the template's
            if (!self.world.files.exists(try packOf(a, source_actor))) return null;
            const files = try listFiles(a, (try self.patches.read(try packOf(a, source_actor))).data);
            const source_param = files.get(try paramOf(a, source_actor)) orelse return null;
            const source_comps = (try byml.loadDict(a, source_param)).getDict("Components") orelse return null;
            const ref = source_comps.getString(source.key) orelse {
                self.progress.log("warning: {s} has no {s}; the chest keeps the item's own actor", .{ source_actor, source.key });
                return null;
            };
            try comps.put(a, source.key, .{ .string = ref });
            const file = refFile(ref);
            // a file the template doesn't have: copied unchanged (its size entry is listed); a file neither pack holds
            // is found by the game elsewhere, as for the source actor itself
            if (!tmpl.has(file)) {
                var already = false;
                for (add.items) |f| if (std.mem.eql(u8, f.name, file)) {
                    already = true;
                };
                if (!already) if (files.get(file)) |data| add.append(a, .{ .name = file, .data = data }) catch return error.OutOfMemory;
            }
        }
        for (display_refs_dropped) |ref_key| _ = comps.remove(ref_key);
        var entries: std.ArrayList(SizeEntry) = .empty;
        if (parts.model_scale) |model_scale| {
            // a ModelInfo of the clone's own: the model's, with DebugModelScale
            const model_ref = comps.getString("ModelInfoRef") orelse return null;
            const model_file = refFile(model_ref);
            var model_bytes: ?[]const u8 = null;
            for (add.items) |f| if (std.mem.eql(u8, f.name, model_file)) {
                model_bytes = f.data;
            };
            if (model_bytes == null) model_bytes = tmpl.get(model_file);
            const original_info = model_bytes orelse return null;
            const info = try byml.loadDict(a, original_info);
            const scale = try byml.Dict.create(a);
            for ([_][]const u8{ "X", "Y", "Z" }) |axis| try scale.put(a, axis, .{ .float = model_scale });
            try info.put(a, "DebugModelScale", .{ .dict = scale });
            const new_info = try byml.dump(a, .{ .dict = info }, versionOf(original_info), false);
            const new_info_path = std.fmt.allocPrint(a, "Component/ModelInfo/{s}.engine__component__ModelInfo.bgyml", .{clone}) catch return error.OutOfMemory;
            add.append(a, .{ .name = new_info_path, .data = new_info }) catch return error.OutOfMemory;
            try comps.put(a, "ModelInfoRef", .{ .string = std.fmt.allocPrint(a, "?{s}", .{new_info_path}) catch return error.OutOfMemory });
            entries.append(a, .{ .path = new_info_path, .size = self.newSize(new_info_path, model_file, @as(i64, @intCast(new_info.len)) - @as(i64, @intCast(original_info.len))) }) catch return error.OutOfMemory;
        }
        const new_param = try byml.dump(a, .{ .dict = param }, versionOf(tmpl_param_bytes), false);
        const new_param_path = try paramOf(a, clone);
        add.append(a, .{ .name = new_param_path, .data = new_param }) catch return error.OutOfMemory;
        const data = try rebuildWith(a, tmpl_raw.data, &.{}, add.items);
        try self.patches.emit(try packOf(a, clone), data, data, tmpl_raw.dictionary, true);

        const clone_key = try packKey(a, clone);
        entries.append(a, .{ .path = clone_key, .size = self.newSize(clone_key, try packKey(a, display_template), @as(i64, @intCast(data.len)) - @as(i64, @intCast(tmpl_raw.data.len))) }) catch return error.OutOfMemory;
        entries.append(a, .{ .path = new_param_path, .size = self.newSize(new_param_path, tmpl_param_path, @as(i64, @intCast(new_param.len)) - @as(i64, @intCast(tmpl_param_bytes.len))) }) catch return error.OutOfMemory;
        try self.setSizes(entries.items, false);
        self.rows.append(self.allocator, .{
            .clone = clone,
            .src = try self.keepText(parts.model),
            .template = display_template,
            .display = true,
            .display_item = try self.keepText(parts.item),
            .display_animation_from_model = parts.animation != null,
        }) catch return error.OutOfMemory;
        return clone;
    }

    /// Chest Size Matches Contents: the big chest (`big_chest`, Obj_TBox_A_02 or its _NoBake) that checks what the
    /// player owns, as the small Obj_TBox_A_06 does: owns Drop__CheckActor -> Drop__DropActor_Substitute, else
    /// Drop__DropActor (world.conditionalChestActor). The game has no big one, and a progressive item in a big chest
    /// needs it. Null when it can't be built (the chest then stays small).
    ///
    /// How: both chests are the small chest with parts of their own ($parent Obj_TBox_A_01). The big chest's own parts
    /// make its size (model, body, animations); Obj_TBox_A_06's four make the check (its AI, the holder of the second
    /// item, the drop logic reading Drop__CheckActor, its affiliation). So the new chest is the big chest's pack with
    /// an ActorParam whose $parent is the big chest and whose AIInfo, ActorHolder, Drop and Affiliation refs are
    /// Obj_TBox_A_06's, and Obj_TBox_A_06's files beside them. Its AI is a copy of Obj_TBox_A_06's with one body name
    /// changed: the small chest's touch sensor is GeneralSensor/Sensor, the big chest's GeneralSensor/EnemyCheck (dump:
    /// Obj_TBox_A_02 ControllerSetParam and its own AI). Its RSDB rows are the big chest's, with at least
    /// Obj_TBox_A_06's memory.
    pub fn bigTierChest(self: *Self, big_chest: []const u8) PatchError!?[]const u8 {
        const k = try self.key("big_tier_chest", big_chest, null);
        if (self.made.get(k)) |made| return made;
        const built = try self.buildBigTierChest(big_chest);
        self.made.put(k, built) catch return error.OutOfMemory;
        if (built) |clone| self.progress.log("Chest Size Matches Contents: made {s}, a big chest that checks what you own", .{clone});
        return built;
    }

    fn buildBigTierChest(self: *Self, big_chest: []const u8) PatchError!?[]const u8 {
        const a = self.patches.allocator;
        const tier_chest = small_tier_chest;
        const clone = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ big_chest, big_tier_chest_suffix }) catch return error.OutOfMemory;
        if (clone.len > max_key_item_name) {
            self.progress.log("warning: {s} is too long an actor name for the game; big chests that check what you own stay small", .{clone});
            return null;
        }
        if (!self.world.files.exists(try packOf(a, big_chest)) or !self.world.files.exists(try packOf(a, tier_chest))) return null;
        const big_raw = try self.patches.read(try packOf(a, big_chest));
        const big_files = try listFiles(a, big_raw.data);
        const tier_files = try listFiles(a, (try self.patches.read(try packOf(a, tier_chest))).data);
        const big_param_path = try paramOf(a, big_chest);
        const tier_param_path = try paramOf(a, tier_chest);
        const big_param_bytes = big_files.get(big_param_path) orelse return self.missing(big_chest, big_param_path);
        const tier_param_bytes = tier_files.get(tier_param_path) orelse return self.missing(tier_chest, tier_param_path);
        const tier_param = try byml.loadDict(a, tier_param_bytes);
        const tier_comps = tier_param.getDict("Components") orelse return self.missing(tier_chest, "Components");

        var add: std.ArrayList(sarc.NewFile) = .empty;
        var entries: std.ArrayList(SizeEntry) = .empty;

        // the AI: Obj_TBox_A_06's, with the big chest's sensor name
        const tier_ai_path = std.fmt.allocPrint(a, "AI/{s}.root.ainb", .{tier_chest}) catch return error.OutOfMemory;
        const tier_ai = tier_files.get(tier_ai_path) orelse return self.missing(tier_chest, tier_ai_path);
        const ai = try ainb.repointStringConst(a, tier_ai, "RigidBodyName", "Sensor", "EnemyCheck");
        if (ai.count != 1) {
            self.progress.log("warning: {s}'s AI names its sensor {d} times, not once; big chests that check what you own stay small", .{ tier_chest, ai.count });
            return null;
        }
        const ai_path = std.fmt.allocPrint(a, "AI/{s}.root.ainb", .{clone}) catch return error.OutOfMemory;
        add.append(a, .{ .name = ai_path, .data = ai.data }) catch return error.OutOfMemory;
        entries.append(a, .{ .path = ai_path, .size = self.newSize(ai_path, tier_ai_path, @as(i64, @intCast(ai.data.len)) - @as(i64, @intCast(tier_ai.len))) }) catch return error.OutOfMemory;

        // its AIInfo, naming that AI
        const tier_info_path = std.fmt.allocPrint(a, "AI/AIInfo/{s}.engine__actor__AIInfo.bgyml", .{tier_chest}) catch return error.OutOfMemory;
        const tier_info_bytes = tier_files.get(tier_info_path) orelse return self.missing(tier_chest, tier_info_path);
        const info = try byml.loadDict(a, tier_info_bytes);
        try info.put(a, "RootAIRef", .{ .string = std.fmt.allocPrint(a, "Work/AI/Root/{s}.root.ain", .{clone}) catch return error.OutOfMemory });
        const info_bytes = try byml.dump(a, .{ .dict = info }, versionOf(tier_info_bytes), false);
        const info_path = std.fmt.allocPrint(a, "AI/AIInfo/{s}.engine__actor__AIInfo.bgyml", .{clone}) catch return error.OutOfMemory;
        add.append(a, .{ .name = info_path, .data = info_bytes }) catch return error.OutOfMemory;
        entries.append(a, .{ .path = info_path, .size = self.newSize(info_path, tier_info_path, @as(i64, @intCast(info_bytes.len)) - @as(i64, @intCast(tier_info_bytes.len))) }) catch return error.OutOfMemory;

        // the ActorParam: the big chest's, with Obj_TBox_A_06's check parts
        const param = try byml.Dict.create(a);
        try param.put(a, "$parent", .{ .string = try workPath(a, big_param_path) });
        const comps = try byml.Dict.create(a);
        try comps.put(a, "AIInfoRef", .{ .string = std.fmt.allocPrint(a, "?{s}", .{info_path}) catch return error.OutOfMemory });
        for (tier_check_refs) |ref_key| {
            const ref = tier_comps.getString(ref_key) orelse return self.missing(tier_chest, ref_key);
            try comps.put(a, ref_key, .{ .string = ref });
        }
        try param.put(a, "Components", .{ .dict = comps });
        const new_param = try byml.dump(a, .{ .dict = param }, versionOf(big_param_bytes), false);
        const new_param_path = try paramOf(a, clone);
        add.append(a, .{ .name = new_param_path, .data = new_param }) catch return error.OutOfMemory;
        entries.append(a, .{ .path = new_param_path, .size = self.newSize(new_param_path, tier_param_path, @as(i64, @intCast(new_param.len)) - @as(i64, @intCast(tier_param_bytes.len))) }) catch return error.OutOfMemory;

        // Obj_TBox_A_06's own files the big chest's pack lacks (its drop logic's blackboard table included). They keep
        // their names, which already have size entries (Obj_TBox_A_06 ships them)
        for (tier_files.entries) |f| {
            if (big_files.has(f.name)) continue;
            if (std.mem.eql(u8, f.name, tier_param_path) or std.mem.eql(u8, f.name, tier_ai_path) or std.mem.eql(u8, f.name, tier_info_path)) continue;
            if (!isTierCheckFile(f.name)) continue;
            add.append(a, .{ .name = f.name, .data = f.data }) catch return error.OutOfMemory;
        }

        const data = try rebuildWith(a, big_raw.data, &.{}, add.items);
        try self.patches.emit(try packOf(a, clone), data, data, big_raw.dictionary, true);
        const clone_key = try packKey(a, clone);
        entries.append(a, .{ .path = clone_key, .size = self.newSize(clone_key, try packKey(a, big_chest), @as(i64, @intCast(data.len)) - @as(i64, @intCast(big_raw.data.len))) }) catch return error.OutOfMemory;
        try self.setSizes(entries.items, false);
        // `big_chest` may point into the stage file being patched, freed after its step: the row keeps a copy
        self.auto_rows.append(self.allocator, .{ .clone = clone, .src = try self.keepText(big_chest), .memory_from = tier_chest }) catch return error.OutOfMemory;
        return clone;
    }

    fn missing(self: *Self, actor: []const u8, what: []const u8) ?[]const u8 {
        self.progress.log("warning: {s} has no {s}; big chests that check what you own stay small", .{ actor, what });
        return null;
    }

    /// The RSDB rows of every clone (ActorInfo, GameActorInfo, PouchActorInfo).
    pub fn finish(self: *Self) PatchError!void {
        if (self.rows.items.len == 0 and self.auto_rows.items.len == 0 and self.restyled.items.len == 0) return;
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
                if (r.display) {
                    // a chest display actor: the template's ActorInfo row with the model actor's model fields (its
                    // animations' too when they were taken), the item's ActorName, and at least each one's memory;
                    // the item's pouch row
                    if (std.mem.eql(u8, t.name, "PouchActorInfo")) {
                        const base = findRow(t.rows, r.display_item) orelse continue;
                        row = (try (byml.Value{ .dict = base }).clone(a)).dict;
                    } else {
                        const base = findRow(t.rows, r.template) orelse continue;
                        row = (try (byml.Value{ .dict = base }).clone(a)).dict;
                        if (std.mem.eql(u8, t.name, "ActorInfo")) {
                            if (findRow(t.rows, r.src)) |m| {
                                for (key_item_model_keys) |mk| {
                                    if (std.mem.eql(u8, mk, "AnimationResources") and !r.display_animation_from_model) continue;
                                    if (m.get(mk)) |v| try row.put(a, mk, try v.clone(a));
                                }
                                try raiseMemoryToFit(a, row, m);
                            }
                            if (findRow(t.rows, r.display_item)) |item_row| {
                                if (item_row.get("ActorName")) |n| try row.put(a, "ActorName", try n.clone(a)) else try row.put(a, "ActorName", .{ .string = r.display_item });
                                try raiseMemoryToFit(a, row, item_row);
                            }
                        }
                    }
                } else if (r.key_item) {
                    // a new key item: the template's rows, with the model's fields and its own ActorName
                    const base = findRow(t.rows, r.template) orelse {
                        self.progress.log("warning: no {s} row for {s}", .{ t.name, r.template });
                        continue;
                    };
                    row = (try (byml.Value{ .dict = base }).clone(a)).dict;
                    if (std.mem.eql(u8, t.name, "ActorInfo")) {
                        const m = findRow(t.rows, r.src);
                        if (m) |md| for (key_item_model_keys) |k| if (md.get(k)) |v| try row.put(a, k, try v.clone(a));
                        try row.put(a, "ActorName", .{ .string = r.clone });
                        if (m) |md| for (heap_keys) |k| {
                            const sv = md.get(k) orelse continue;
                            const current = row.get(k) orelse sv;
                            try row.put(a, k, current.sameIntType(@max(current.asInt() orelse 0, sv.asInt() orelse 0)));
                        };
                    }
                } else if (std.mem.eql(u8, t.name, "PouchActorInfo")) {
                    // the row describes the item; an item without one falls back on the template's (as OotrR does),
                    // so the pickup is still a pouch item
                    const base = findRow(t.rows, r.src) orelse findRow(t.rows, r.template) orelse continue;
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
                        if (s) |sd| for (row_from_item) |k| {
                            if (r.animation_from_template and std.mem.eql(u8, k, "AnimationResources")) continue;
                            if (sd.get(k)) |v| try row.put(a, k, try v.clone(a));
                        };
                        // a borrowed model (songs): its model fields, the item's name
                        if (self.model_src.get(r.clone)) |m_name| {
                            if (findRow(t.rows, m_name)) |m| for (model_row_keys) |k| if (m.get(k)) |v| try row.put(a, k, try v.clone(a));
                        }
                        // a model whose item row has its worn box (the Gauntlets): the display actor's box. By the
                        // model shown (modelActorOf), so a progressive stand-in's pickup or shelf with the Goron
                        // Bracelet's model gets the box the Goron Bracelet's own pickup gets
                        if (displayBoxActorOf(self.modelActorOf(r.clone))) |box_actor| if (findRow(t.rows, box_actor)) |b| {
                            for ([_][]const u8{ "ModelAabbMin", "ModelAabbMax" }) |k| if (b.get(k)) |v| try row.put(a, k, try v.clone(a));
                        };
                        // a worn box with no display actor (the Lens of Truth): moved down onto the origin
                        if (isRecentred(self.modelActorOf(r.clone))) try recentreBox(a, row);
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
                if (r.memory_from) |donor_name| {
                    if (std.mem.eql(u8, t.name, "ActorInfo")) if (findRow(t.rows, donor_name)) |donor| try raiseMemoryToFit(a, row, donor);
                }
                try row.put(a, "__RowId", .{ .string = r.clone });
                try insertSorted(a, t.rows, row, r.clone);
            }
        }
        // actors given another's model: its model fields and at least its memory, everything else their own
        for (self.restyled.items) |r| {
            const t = &tables[0]; // ActorInfo
            const row = findRow(t.rows, r.actor) orelse continue;
            const m = findRow(t.rows, r.model_actor) orelse continue;
            for (model_row_keys) |k| if (m.get(k)) |v| try row.put(a, k, try v.clone(a));
            if (m.get("ModelVariationFmabName")) |v| try row.put(a, "ModelVariationFmabName", try v.clone(a));
            // the actor's own animation files stay (its own moves, such as the dig prize's rise out of the hole), and
            // the model's are added: a model can name a pose in them (the Hookshot's ModelInfo poses it with
            // Weapon_Pose_Hook from Item_Hookshot_Animation)
            try addMissingAnimationResources(a, row, m);
            // at least the model actor's memory (the Hookshot's render memory is larger than the Piece of Heart's).
            // The Graveyard crash in testing was the size table, not this (dressInModelOf)
            try raiseMemoryToFit(a, row, m);
        }
        for (tables) |t| try self.patches.emitZs(t.rel, t.original, try byml.dumpDefault(a, .{ .array = t.rows }));
    }
};

/// Moves `row`'s model box (ModelAabbMin / Max) down so it is centred on the origin, keeping its size
/// (PickupCloner.recentred_box_actors says why).
fn recentreBox(allocator: Allocator, row: *byml.Dict) PatchError!void {
    const box_min = row.getDict("ModelAabbMin") orelse return;
    const box_max = row.getDict("ModelAabbMax") orelse return;
    const low = (box_min.get("Y") orelse return).asFloat() orelse return;
    const high = (box_max.get("Y") orelse return).asFloat() orelse return;
    const centre = (low + high) / 2.0;
    const new_min = (try (byml.Value{ .dict = box_min }).clone(allocator)).dict;
    const new_max = (try (byml.Value{ .dict = box_max }).clone(allocator)).dict;
    try new_min.put(allocator, "Y", sameFloat(box_min.get("Y").?, low - centre));
    try new_max.put(allocator, "Y", sameFloat(box_max.get("Y").?, high - centre));
    try row.put(allocator, "ModelAabbMin", .{ .dict = new_min });
    try row.put(allocator, "ModelAabbMax", .{ .dict = new_max });
}

/// `x` as the same kind of float as `like` (a box keeps the game's own number type).
fn sameFloat(like: byml.Value, x: f64) byml.Value {
    return if (like == .double) .{ .double = x } else .{ .float = @floatCast(x) };
}

/// Appends to `row`'s AnimationResources each entry of `donor`'s it lacks (an entry names an animation file,
/// {ModelProjectName: ...}), keeping `row`'s own first.
fn addMissingAnimationResources(allocator: Allocator, row: *byml.Dict, donor: *const byml.Dict) PatchError!void {
    const donor_list = (donor.get("AnimationResources") orelse return).asArray() orelse return;
    if (row.get("AnimationResources") == null) {
        try row.put(allocator, "AnimationResources", try (byml.Value{ .array = donor_list }).clone(allocator));
        return;
    }
    const own = row.get("AnimationResources").?.asArray() orelse return;
    for (donor_list.items.items) |entry| {
        const name = (entry.asDict() orelse continue).getString("ModelProjectName") orelse continue;
        var present = false;
        for (own.items.items) |mine| {
            const mine_name = (mine.asDict() orelse continue).getString("ModelProjectName") orelse continue;
            if (std.mem.eql(u8, mine_name, name)) present = true;
        }
        if (!present) own.items.append(allocator, try entry.clone(allocator)) catch return error.OutOfMemory;
    }
}

/// Raises `row`'s memory sizes (InstanceHeapSize, PreActorRenderInfoHeapSize) to at least `donor`'s: an actor given
/// another actor's components needs the memory that actor has, or the game overruns it creating the actor.
fn raiseMemoryToFit(allocator: Allocator, row: *byml.Dict, donor: *const byml.Dict) PatchError!void {
    for (heap_keys) |k| {
        const needed = donor.get(k) orelse continue;
        const current = row.get(k) orelse needed;
        try row.put(allocator, k, current.sameIntType(@max(current.asInt() orelse 0, needed.asInt() orelse 0)));
    }
}

/// For a patch that gives `actor` the components of `donor` after the RSDB rows are written (the Dodongo boulder):
/// raises `actor`'s ActorInfo memory sizes to at least `donor`'s (raiseMemoryToFit). False when either has no row.
pub fn raiseActorMemoryToFit(world: *World, patches: *patchset.PatchSet, actor: []const u8, donor: []const u8) PatchError!bool {
    const a = patches.allocator;
    const rel = try world.find(a, "RSDB", "ActorInfo");
    const original = try patches.read(rel);
    const doc = try byml.load(a, original.data);
    const rows = (doc.root orelse return error.InvalidData).asArray() orelse return error.InvalidData;
    const row = PickupCloner.findRow(rows, actor) orelse return false;
    const donor_row = PickupCloner.findRow(rows, donor) orelse return false;
    try raiseMemoryToFit(a, row, donor_row);
    try patches.emitZs(rel, original, try byml.dumpDefault(a, .{ .array = rows }));
    return true;
}

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
