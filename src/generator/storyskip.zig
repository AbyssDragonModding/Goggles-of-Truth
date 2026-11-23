//! Skip Cutscenes (setting key skip_story_scenes; called Skip Story Scenes before 0.7.4): the Temple of Time,
//! Chamber of Sages, sage-awakening and Royal Family's Tomb scenes don't play (and Skip Area Intros
//! for the intros whose arrival also advances a quest).
//!
//! Story scenes are not started by the place you are in but by a quest flow (DoorOfTime, AllSage, and the shared
//! boss-reward flow Dm_SY_BancChange_EscapeDungeon), which plays them one after another with
//! EventSystemActor.EventTransition and then moves Link on. Each listed transition is replaced in that quest flow by
//! what the scene leaves behind, so the quest carries on as if it had played:
//!
//! - a timeline-only scene (a pre-recorded cinematic; nothing it does changes the save) is marked as seen
//!   (HavePlayedEvent.<scene>, which the quest flows and stage logic read);
//! - a flowchart scene (Rauru's talk, the medallion scenes, the Light Arrows, the child stones) is checked to do
//!   nothing but talk, animate, and hand over one item through GetPouchContent:GetPouchContentByActorName (plus plain
//!   save flags, which are copied). Its item, the randomized one (read from the already-patched scene), is handed over
//!   directly with that same call, after the screen fades in.
//!
//! A scene that adds an item itself (PouchSystemActor.EventTriggerAddOrRemovePouchContent, then its item window:
//! Saria's Fairy Ocarina on the forest bridge) has those two steps copied instead.
//!
//! Fades: a skipped scene that would open with a fade-in gets that fade-in (its colour); an item scene fades in before
//! its window in its own fade colour (test seed 9: Rauru's medallion was given behind a white screen). A scene that
//! directly follows another skipped scene adds no fade, so a run of skipped scenes doesn't flash.
//!
//! Event info: every event that has a row in RSDB/GameAnalyzedEventInfo lists there every other flow its entry calls
//! (SubFlowList). A call to a flow that isn't listed stops the event (test seeds 7 and 8), so the rows of every
//! changed event get the flows it now calls (updateEventInfo).
//!
//! Anything not exactly as expected is refused and that scene keeps playing.

const std = @import("std");
const evfl = @import("../formats/evfl.zig");
const byml = @import("../formats/byml.zig");
const world_mod = @import("../game/world.zig");
const patchset = @import("patchset.zig");
const flows = @import("flows.zig");
const gamedata = @import("gamedata.zig");
const Progress = @import("../core/Progress.zig");
const Allocator = std.mem.Allocator;
const PatchError = patchset.PatchError;
const PatchSet = patchset.PatchSet;
const World = world_mod.World;
const Container = evfl.Container;
const NONE = evfl.NONE;

const gift_flow = "GetPouchContent";
const gift_entry = "GetPouchContentByActorName";

pub const SkipList = struct {
    flow: []const u8,
    scenes: []const []const u8,
    /// Its scenes may play an ocarina lesson (Dm_SY_Ocarina's Learning... entries: the song played for you, then
    /// played along). A lesson's only gift is the vanilla song, which patchSongTeaching already takes out when songs
    /// are shuffled, and the song spot's item comes from the scene after it, so skipping the lesson loses nothing.
    song_lessons: bool = false,
};

/// The ocarina lessons a song scene may call when its list allows them (SkipList.song_lessons).
const song_lesson_flow = "Dm_SY_Ocarina";
const song_lesson_entry_prefix = "LearningOcarina";

/// quest flow -> scenes it plays that are skipped
pub const skips = [_]SkipList{
    // Temple of Time: the door opening, Ganondorf, the Master Sword, Rauru and the Light Medallion
    .{ .flow = "DoorOfTime", .scenes = &.{ "Dm_TimeTemple_0010", "Dm_TimeTemple_0020", "Dm_TimeTemple_0040", "Dm_TimeTemple_0030", "Dm_SageRoom_0000", "Dm_SageRoom_0005" } },
    // leaving Kokiri Forest after the Deku Tree: Saria's goodbye on the bridge and her Fairy Ocarina
    .{ .flow = "Goto_HyruleCastle", .scenes = &.{ "Dm_Kokiri_0150", "Dm_Kokiri_0155" } },
    // adult Temple of Time: Sheik's first talk, the sages' talks, Zelda's reveal and the Light Arrows
    .{ .flow = "AllSage", .scenes = &.{
        "Dm_TimeTemple_0050", "Dm_TimeTemple_0055", "Dm_SageRoom_0010", "Dm_TimeTemple_0090", "Dm_TimeTemple_0095",
        "Dm_TimeTemple_0110", "Dm_TimeTemple_0115", "Dm_TimeTemple_0125", "Dm_TimeTemple_0130", "Dm_TimeTemple_0135",
    } },
    // after a boss: the sage awakens and hands over the medallion; the Deku Tree, Darunia and Ruto hand over the
    // stones; and the rest of each post-boss chain (each one a timeline or a talk-only flowchart)
    .{ .flow = "Dm_SY_BancChange_EscapeDungeon", .scenes = &.{
        "Dm_Awake_Forest",        "Dm_Awake_Forest_Get",    "Dm_Awake_Fire",          "Dm_Awake_Fire_Get",
        "Dm_Awake_Water",         "Dm_Awake_Water_Get",     "Dm_Awake_Shadow",        "Dm_Awake_Shadow_Get",
        "Dm_Awake_Spirit",        "Dm_Awake_Spirit_Get",    "Dm_Kokiri_0130",         "Dm_DeathMtTrail_0025",
        "Dm_ZoraFountain_0030",   "Dm_Deku_0010",           "Dm_Kokiri_0080",         "Dm_Kokiri_0090",
        "Dm_Kokiri_0095",         "Dm_Kokiri_0140",         "Dm_Kokiri_0158",         "Dm_Kokiri_0160",
        "Dm_Kokiri_0162",         "Dm_DodongoCave_0030",    "Dm_DeathMtTrail_0020",   "Dm_DeathMtTrail_0027",
        "Dm_DeathMtCrater_0010",  "Dm_InsideJabu_Jabu_0060", "Dm_ZoraFountain_0020",  "Dm_ForestTemple_0020",
        "Dm_FireTemple_0030",     "Dm_WaterTemple_0040",    "Dm_LakeHrl_0020",        "Dm_ShadowTemple_0020",
        "Dm_Graveyard_0030",      "Dm_Kakariko_0025",       "Dm_SpiritTemple_0040",   "Dm_DesertColossus_0040",
    } },
    // before each adult temple: Sheik, Mido, Ruto and Nabooru (the Forest Temple elevator and the Shadow Temple boat,
    // which move the dungeon itself, keep playing)
    .{ .flow = "SageOfForest", .scenes = &.{ "Dm_LostWood_0021", "Dm_LostWood_0025" } },
    .{ .flow = "SageOfFire", .scenes = &.{"Dm_FireTemple_0000"} },
    .{ .flow = "SageOfWater", .scenes = &.{ "Dm_WaterTemple_0010", "Dm_WaterTemple_0015" } },
    .{ .flow = "SageOfSpirit", .scenes = &.{
        "Dm_DesertColossus_0020", "Dm_DesertColossus_0025", "Dm_DesertColossus_0030", "Dm_SpiritTemple_0010",
        "Dm_SpiritTemple_0020",   "Dm_SpiritTemple_0030",   "Dm_TimeTemple_0086",     "Dm_TimeTemple_0087",
    } },
    // Ganon's Castle: the first visit, each trial's barrier and its sage, the tower's barrier (Ganondorf, Ganon and
    // the ending still play)
    .{ .flow = "Defeat_Ganon", .scenes = &.{
        "Dm_InsideGanonCastle_0000", "Dm_InsideGanonCastle_0006", "Dm_InsideGanonCastle_0010", "Dm_InsideGanonCastle_0015",
        "Dm_InsideGanonCastle_0020", "Dm_InsideGanonCastle_0025", "Dm_InsideGanonCastle_0030", "Dm_InsideGanonCastle_0032",
        "Dm_InsideGanonCastle_0050", "Dm_InsideGanonCastle_0055", "Dm_InsideGanonCastle_0070", "Dm_InsideGanonCastle_0075",
        "Dm_InsideGanonCastle_0080", "Dm_InsideGanonCastle_0085", "Dm_InsideGanonCastle_0090", "Dm_InsideGanonCastle_0110",
    } },
    .{ .flow = "InsideGanonCastle_CommonGimmick", .scenes = &.{"Dm_InsideGanonCastle_0005"} },
    // Kakariko Graveyard, the Royal Family's Tomb: Zelda's Lullaby at the gravestone (the tomb opening), and the
    // Sun's Song stone inside (its lesson, the day / night versions for each age, and the song's own scene)
    .{
        .flow = "GimmickFlow_RoyalFamilyTomb",
        .scenes = &.{
            "Dm_Graveyard_0010",   "Dm_MelodyGet_Sun",    "Dm_MelodyGet_Sun_01", "Dm_MelodyGet_Sun_03",
            "Dm_MelodyGet_Sun_04", "Dm_MelodyGet_Sun_05", "Dm_MelodyGet_Sun_06", "Dm_MelodyGet_Sun_07",
            "Dm_MelodyGet_Sun_08", "Dm_MelodyGet_Sun_09", "Dm_MelodyGet_Sun_10",
        },
        .song_lessons = true,
    },
};

/// Skip Area Intros, for the intros whose arrival entry also advances a quest or sets flags: the intro's transition
/// is replaced in its arrival flow like a story scene, so what follows it still runs; the area's name banner, which
/// marks it visited, becomes its IsVisitLocation flag.
pub const area_skips = [_]SkipList{
    .{ .flow = "Dm_SY_BancChangeArrive", .scenes = &.{
        "Dm_Deku_0000", // inside the Deku Tree (Get_StoneOfForest MeetBoss)
        "Dm_DeathMtTrail_0000", // Death Mountain Trail from Kakariko (Get_StoneOfFire)
        "Dm_Goron_0000", // Goron City from the trail (Get_StoneOfFire)
        "Dm_Zora_0000", // Zora's Domain from the river (Get_StoneOfWater Step03)
        "Dm_DesertColossus_0000", // Desert Colossus from the wasteland (SageOfSpirit Step04)
        "Dm_HrlCastle_0005", // Castle Town (Goto_HyruleCastle EntryMarket)
        "Dm_DeathMtCrater_0000", // Death Mountain Crater from Goron City (SageOfFire)
        "Goto_SacredForest", // Sacred Forest Meadow
        "Goto_IceCave", // Ice Cavern (SageOfWater Step03)
        "Goto_ShadowTemple", // Shadow Temple entrance (SageOfShadow MeetBoss)
        "Goto_GerudoTrainingGround", // Gerudo Training Ground (SubEvent_GetIceArrow)
    } },
    // Lon Lon Ranch: the entry also sets Malon's whereabouts flags
    .{ .flow = "Entry_LonLonRanch", .scenes = &.{"Dm_LonLon_0010"} },
    // inside Ganon's Castle, the first visit (the castle's LocationArea only exists once it has played)
    .{ .flow = "Defeat_Ganon", .scenes = &.{"Dm_InsideGanonCastle_0003"} },
};

/// Intros that are events of their own (no arrival flow): their first entry is cut down to the area's visit flag.
pub const area_standalone = [_][]const u8{ "Dm_DodongoCave_0000", "Goto_WaterTemple", "Dm_TimeTemple_0000", "Dm_TimeTemple_0065" };

pub fn flowRel(allocator: Allocator, name: []const u8) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(allocator, "Event/EventFlow/{s}.bfevfl.zs", .{name});
}

/// What a skipped flowchart scene may do besides talking and animating (rando/storyskip.py PRESENTATION): any of
/// these words in the action's name, or a name ending in "Time".
const presentation_words = [_][]const u8{
    "PlayAS",     "Talk",       "Warp",       "XLink",        "Sound",     "Bgm",            "BGM",       "Comment",
    "Camera",     "Fade",       "LookAt",     "Lod",          "Model",     "Particip",       "Wait",      "PostProc",
    "Dialog",     "Navi",       "Palette",    "DoF",          "Rumble",    "Caustic",        "Reflection", "Visible",
    "Show",       "Hide",       "Ducking",    "Effect",       "Light",     "Rendering",      "Nickname",  "Move",
    "Turn",       "Rotate",     "Scale",      "Emit",         "Shake",     "Anime",          "Face",      "Eye",
    "Mouth",      "Blink",      "Weather",    "Wind",         "Letterbox", "DemoProduct",    "Telop",     "Subtitle",
    "Cloth",      "Bone",       "Bind",       "Attach",       "Shadow",    "Fog",            "Voice",     "Emotion",
    "GoOffstage", "DoNothing",  "NorifyCut",  "ScreenShot",   "DoCommand", "TerrainCalc",    "Culling",   "EquipmentUserRequestChangeState",
    "BootsChange", "PerformanceImportantMenu", "DisplayGet", "Chemical", "SetTime",  "Shading",        "PlayerEventStartWith", "CloseDemoScreen",
    "Occlusion",  "SetPerformerSystem",
};

fn isPresentation(action: []const u8) bool {
    for (presentation_words) |w| if (std.mem.indexOf(u8, action, w) != null) return true;
    return std.mem.endsWith(u8, action, "Time");
}

const dropped_subflows = [_][]const u8{ "Common_Camera_Pln", "NaviEventCommon" };

const SceneItem = union(enum) {
    /// a GetPouchContentByActorName call: the actor
    gift: []const u8,
    /// a pouch add the scene makes itself (then its item window is shown too): its parameters
    add: *Container,
};

const SceneEffects = struct {
    items: []SceneItem,
    /// save flags the scene sets to True
    flags: [][]const u8,
};

/// "IsVisitLocation.LakeHylia" for "Work/Location/LakeHylia.game__location__Location.gyml".
fn locationFlag(allocator: Allocator, path: []const u8) error{OutOfMemory}![]const u8 {
    const base = if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| path[i + 1 ..] else path;
    const name = if (std.mem.indexOfScalar(u8, base, '.')) |i| base[0..i] else base;
    return std.fmt.allocPrint(allocator, "IsVisitLocation.{s}", .{name});
}

/// The items and flags of a skippable scene, or error.NotAsExpected (with the reason). `area_intro`: the scene may
/// open its area's name banner, which marks the area as visited; that visit flag is added to the flags.
fn sceneEffects(allocator: Allocator, doc: *evfl.Document, area_intro: bool, song_lessons: bool, progress: *Progress) PatchError!SceneEffects {
    var items: std.ArrayList(SceneItem) = .empty;
    var flags: std.ArrayList([]const u8) = .empty;
    const fc = doc.flowchart orelse return SceneEffects{ .items = items.items, .flags = flags.items };
    var gifts: std.ArrayList(?[]const u8) = .empty;
    var adds: std.ArrayList(*Container) = .empty;
    var shown: std.ArrayList([]const u8) = .empty;
    for (fc.events.items) |*e| {
        switch (e.kind) {
            .sub_flow => |s| {
                if (s.flowchart.len == 0) continue;
                const actor_name = if (s.params) |p| p.getString("ActorName") else null;
                if (std.mem.eql(u8, s.flowchart, gift_flow) and std.mem.eql(u8, s.entry_point, gift_entry)) {
                    gifts.append(allocator, actor_name) catch return error.OutOfMemory;
                } else if (std.mem.eql(u8, s.flowchart, gift_flow) and std.mem.eql(u8, s.entry_point, "DisplayGetByActorName")) {
                    // the window for an item already added
                    if (actor_name) |n| shown.append(allocator, n) catch return error.OutOfMemory;
                } else if (song_lessons and std.mem.eql(u8, s.flowchart, song_lesson_flow) and std.mem.startsWith(u8, s.entry_point, song_lesson_entry_prefix)) {
                    // the lesson only plays the song (SkipList.song_lessons)
                } else if (!flows.contains(&dropped_subflows, s.flowchart)) {
                    return progress.fail(error.NotAsExpected, "{s} calls {s}:{s}", .{ fc.name, s.flowchart, s.entry_point });
                }
            },
            .sub_flow_switch, .return_ => return progress.fail(error.NotAsExpected, "{s} has a sub flow branch", .{fc.name}),
            .switch_ => |s| {
                const actor = fc.actors.items[s.actor];
                const what = actor.queries.items[s.query];
                // a branch on owning an item only picks a line (Darunia: IsGet.Item_DinFire)
                const name = if (s.params) |p| p.getString("GameDataName") orelse "" else "";
                const owns = std.mem.eql(u8, what, "EventQueryIsGameDataBool") and std.mem.startsWith(u8, name, "IsGet.");
                if ((std.mem.eql(u8, actor.name, "GameDataActor") and !owns) or std.mem.indexOf(u8, what, "Challenge") != null) {
                    return progress.fail(error.NotAsExpected, "{s} branches on {s}", .{ fc.name, what });
                }
            },
            .action => |x| {
                const actor = fc.actors.items[x.actor];
                const what = actor.actions.items[x.action];
                if (std.mem.eql(u8, actor.name, "GameDataActor")) {
                    const p = x.params orelse return progress.fail(error.NotAsExpected, "{s}: {s} without parameters", .{ fc.name, what });
                    const value_true = if (p.get("Value")) |v| v == .bool and v.bool else false;
                    const index_ok = if (p.get("Index")) |v| Param.looseEql(v, .{ .int = -1 }) else true;
                    if (!std.mem.eql(u8, what, "EventTriggerSetGameDataBool") or !value_true or !index_ok) {
                        return progress.fail(error.NotAsExpected, "{s}: {s} sets something other than a flag", .{ fc.name, what });
                    }
                    const flag = p.getString("GameDataName") orelse return progress.fail(error.NotAsExpected, "{s}: a flag without a name", .{fc.name});
                    flags.append(allocator, flag) catch return error.OutOfMemory;
                } else if (std.mem.eql(u8, actor.name, "PouchSystemActor") and std.mem.eql(u8, what, "EventTriggerAddOrRemovePouchContent") and
                    x.params != null and isPositiveInt(x.params.?.get("Num")))
                {
                    // Saria hands over the Fairy Ocarina herself
                    adds.append(allocator, try x.params.?.clone(allocator)) catch return error.OutOfMemory;
                } else if (area_intro and std.mem.eql(u8, actor.name, "UISystemActor") and std.mem.eql(u8, what, "EventTriggerOpenLocationUI") and
                    x.params != null and if (x.params.?.getString("LocationName")) |n| n.len > 0 else false)
                {
                    flags.append(allocator, try locationFlag(allocator, x.params.?.getString("LocationName").?)) catch return error.OutOfMemory;
                } else if (std.mem.indexOf(u8, what, "Pouch") != null or std.mem.indexOf(u8, what, "Challenge") != null or
                    std.mem.indexOf(u8, what, "Banc") != null or std.mem.eql(u8, what, "EventTransition") or
                    std.mem.eql(u8, actor.name, "PouchSystemActor") or std.mem.eql(u8, actor.name, "ChallengeSystemActor"))
                {
                    return progress.fail(error.NotAsExpected, "{s}: {s}.{s}", .{ fc.name, actor.name, what });
                } else if (!isPresentation(what)) {
                    return progress.fail(error.NotAsExpected, "{s}: {s}.{s} is not presentation", .{ fc.name, actor.name, what });
                }
            },
            .fork, .join => {},
        }
    }
    if (gifts.items.len > 1 or (gifts.items.len == 1 and (gifts.items[0] == null or gifts.items[0].?.len == 0)) or (gifts.items.len > 0 and adds.items.len > 0)) {
        return progress.fail(error.NotAsExpected, "{s} hands over more than one item", .{fc.name});
    }
    for (adds.items) |p| {
        const actor = p.getString("Actor") orelse "";
        if (!flows.contains(shown.items, actor)) return progress.fail(error.NotAsExpected, "{s} adds {s} without its item window", .{ fc.name, actor });
    }
    // an item window without a pouch add only shows something added before (the Master Sword): nothing to copy
    for (gifts.items) |g| items.append(allocator, .{ .gift = g.? }) catch return error.OutOfMemory;
    for (adds.items) |p| items.append(allocator, .{ .add = p }) catch return error.OutOfMemory;
    return SceneEffects{ .items = items.items, .flags = flags.items };
}

const Param = evfl.Param;

fn isPositiveInt(v: ?Param) bool {
    const p = v orelse return false;
    return switch (p) {
        .int => |n| n > 0,
        .bool => |b| b, // Python's isinstance(True, int)
        else => false,
    };
}

const Fade = struct {
    fade_in: bool,
    colour: Param,
};

/// The scene's first UISystemActor fade, or null. Timelines by start time; flowcharts in breadth-first order from
/// their first entry, following calls to their own entries.
fn firstFade(allocator: Allocator, doc: *evfl.Document) PatchError!?Fade {
    if (doc.flowchart == null) {
        const t = doc.timeline orelse return null;
        var best: ?*const evfl.Clip = null;
        for (t.clips.items) |*c| {
            const actor = t.actors.items[c.actor];
            if (!std.mem.eql(u8, actor.name, "UISystemActor")) continue;
            if (std.mem.indexOf(u8, actor.actions.items[c.action], "Fade") == null) continue;
            if (best == null or c.start < best.?.start) best = c;
        }
        const c = best orelse return null;
        const what = t.actors.items[c.actor].actions.items[c.action];
        const colour = if (c.params) |p| p.get("Color") orelse Param{ .int = 0 } else Param{ .int = 0 };
        return Fade{ .fade_in = std.mem.indexOf(u8, what, "FadeIn") != null, .colour = colour };
    }
    const fc = doc.flowchart.?;
    if (fc.entry_points.items.len == 0) return null;
    const seen = allocator.alloc(bool, fc.events.items.len) catch return error.OutOfMemory;
    @memset(seen, false);
    var queue: std.ArrayList(u16) = .empty;
    queue.append(allocator, fc.entry_points.items[0].main_event) catch return error.OutOfMemory;
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const i = queue.items[head];
        if (i >= fc.events.items.len or seen[i]) continue;
        seen[i] = true;
        const e = &fc.events.items[i];
        if (e.kind == .action) {
            const a = fc.actors.items[e.kind.action.actor];
            const what = a.actions.items[e.kind.action.action];
            if (std.mem.eql(u8, a.name, "UISystemActor") and std.mem.indexOf(u8, what, "Fade") != null) {
                const colour = if (e.kind.action.params) |p| p.get("Color") orelse Param{ .int = 0 } else Param{ .int = 0 };
                return Fade{ .fade_in = std.mem.indexOf(u8, what, "FadeIn") != null, .colour = colour };
            }
        }
        if (e.kind == .sub_flow and e.kind.sub_flow.flowchart.len == 0) {
            if (fc.entryPoint(e.kind.sub_flow.entry_point)) |ep| queue.append(allocator, ep.main_event) catch return error.OutOfMemory;
        }
        try e.targets(&queue, allocator);
    }
    return null;
}

/// (actor, action) of a system actor's action; a system actor the flow doesn't use yet is added with another system
/// actor's parameters (they all have the same member settings).
const system_actors = [_][]const u8{ "GameDataActor", "EventSystemActor", "GameSystemActor", "UISystemActor", "SoundSystemActor" };

fn systemAction(fc: *evfl.Flowchart, allocator: Allocator, actor_name: []const u8, action: []const u8, progress: *Progress) PatchError![2]u16 {
    if (fc.findActor(actor_name) == null and flows.contains(&system_actors, actor_name)) {
        for (fc.actors.items) |a| {
            if (flows.contains(&system_actors, a.name) and a.secondary_name.len == 0) {
                fc.actors.append(allocator, evfl.Actor{ .name = actor_name, .params = try evfl.cloneParams(allocator, a.params) }) catch return error.OutOfMemory;
                break;
            }
        }
    }
    return flows.requireAction(fc, allocator, actor_name, action, progress);
}

const Report = struct {
    scene: []const u8,
    /// "seen", "items ..." or "kept: <reason>"
    text: []const u8,
};

const Plan = struct {
    scene: []const u8,
    hits: []u16,
    items: []SceneItem,
    flags: [][]const u8,
    fade: ?Fade,
};

const SkipResult = struct {
    data: []const u8,
    changed: bool,
    reports: []Report,
};

fn setFlagParams(allocator: Allocator, flag: []const u8) PatchError!*Container {
    return Container.from(allocator, &.{
        .{ .name = "GameDataName", .value = .{ .string = flag } },
        .{ .name = "Index", .value = .{ .int = -1 } },
        .{ .name = "Value", .value = .{ .bool = true } },
    });
}

/// Quest flow `data` with each transition to one of `scenes` replaced by its effects.
fn skipScenes(allocator: Allocator, world: *World, patches: *PatchSet, data: []const u8, scenes: []const []const u8, area_intro: bool, song_lessons: bool, progress: *Progress) PatchError!SkipResult {
    var doc = try flows.readFlow(allocator, data, "quest flow", progress);
    const fc = doc.flowchart orelse return progress.fail(error.NotAsExpected, "no flowchart", .{});
    var reports: std.ArrayList(Report) = .empty;
    var plans: std.ArrayList(Plan) = .empty;

    for (scenes) |scene| {
        var hits: std.ArrayList(u16) = .empty;
        for (fc.events.items, 0..) |*e, i| {
            if (!fc.isAction(e, "EventSystemActor", "EventTransition")) continue;
            const p = e.kind.action.params orelse continue;
            if (p.isString("EventName", scene)) hits.append(allocator, @intCast(i)) catch return error.OutOfMemory;
        }
        if (hits.items.len == 0) {
            const text = std.fmt.allocPrint(allocator, "kept: not played by {s}", .{fc.name}) catch return error.OutOfMemory;
            reports.append(allocator, .{ .scene = scene, .text = text }) catch return error.OutOfMemory;
            continue;
        }
        const scene_rel = try flowRel(allocator, scene);
        if (!world.files.exists(scene_rel)) {
            // why: a scene with no event flow of its own is a timeline played by name (Dm_MelodyGet_Sun_01: the
            // Sun's Song lesson at night), which can't change the save; only its own played flag is set
            var timeline_flags: std.ArrayList([]const u8) = .empty;
            const timeline_seen = std.fmt.allocPrint(allocator, "HavePlayedEvent.{s}", .{scene}) catch return error.OutOfMemory;
            if (try gamedata.boolExists(world, timeline_seen)) timeline_flags.append(allocator, timeline_seen) catch return error.OutOfMemory;
            plans.append(allocator, .{ .scene = scene, .hits = hits.items, .items = allocator.alloc(SceneItem, 0) catch return error.OutOfMemory, .flags = timeline_flags.items, .fade = null }) catch return error.OutOfMemory;
            reports.append(allocator, .{ .scene = scene, .text = "seen (a timeline, no flow of its own)" }) catch return error.OutOfMemory;
            continue;
        }
        const scene_data = (try patches.read(scene_rel)).data;
        var scene_doc = flows.readFlow(allocator, scene_data, scene, progress) catch |err| switch (err) {
            error.NotAsExpected => {
                const text = std.fmt.allocPrint(allocator, "kept: {s}", .{progress.failureMessage()}) catch return error.OutOfMemory;
                reports.append(allocator, .{ .scene = scene, .text = text }) catch return error.OutOfMemory;
                continue;
            },
            else => return err,
        };
        const effects = sceneEffects(allocator, &scene_doc, area_intro, song_lessons, progress) catch |err| switch (err) {
            error.NotAsExpected => {
                const text = std.fmt.allocPrint(allocator, "kept: {s}", .{progress.failureMessage()}) catch return error.OutOfMemory;
                reports.append(allocator, .{ .scene = scene, .text = text }) catch return error.OutOfMemory;
                continue;
            },
            else => return err,
        };
        // its flags (each once, in order) and its own played flag, if they are save flags
        var flags: std.ArrayList([]const u8) = .empty;
        const seen = std.fmt.allocPrint(allocator, "HavePlayedEvent.{s}", .{scene}) catch return error.OutOfMemory;
        for (effects.flags) |f| {
            if (!flows.contains(flags.items, f) and try gamedata.boolExists(world, f)) flags.append(allocator, f) catch return error.OutOfMemory;
        }
        if (!flows.contains(flags.items, seen) and try gamedata.boolExists(world, seen)) flags.append(allocator, seen) catch return error.OutOfMemory;
        plans.append(allocator, .{ .scene = scene, .hits = hits.items, .items = effects.items, .flags = flags.items, .fade = try firstFade(allocator, &scene_doc) }) catch return error.OutOfMemory;

        var text: std.ArrayList(u8) = .empty;
        if (effects.items.len > 0) {
            text.appendSlice(allocator, "items ") catch return error.OutOfMemory;
            for (effects.items, 0..) |it, k| {
                if (k > 0) text.appendSlice(allocator, ", ") catch return error.OutOfMemory;
                text.appendSlice(allocator, switch (it) {
                    .gift => |g| g,
                    .add => |p| p.getString("Actor") orelse "",
                }) catch return error.OutOfMemory;
            }
        } else {
            text.appendSlice(allocator, "seen") catch return error.OutOfMemory;
        }
        reports.append(allocator, .{ .scene = scene, .text = text.items }) catch return error.OutOfMemory;
    }
    if (plans.items.len == 0) return SkipResult{ .data = data, .changed = false, .reports = reports.items };

    // what leads to each event, before anything changes
    const event_count = fc.events.items.len;
    const preds = allocator.alloc(std.ArrayList(u16), event_count) catch return error.OutOfMemory;
    for (preds) |*p| p.* = .empty;
    var targets: std.ArrayList(u16) = .empty;
    for (fc.events.items, 0..) |*e, j| {
        targets.clearRetainingCapacity();
        try e.targets(&targets, allocator);
        for (targets.items) |t| {
            if (t < event_count) preds[t].append(allocator, @intCast(j)) catch return error.OutOfMemory;
        }
    }
    const skipped = allocator.alloc(bool, event_count) catch return error.OutOfMemory;
    @memset(skipped, false);
    for (plans.items) |p| for (p.hits) |t| {
        skipped[t] = true;
    };

    for (plans.items) |p| {
        for (p.hits) |t| {
            const old_next = fc.events.items[t].kind.action.next;
            // fade in where the scene would have (its colour), unless a skipped scene comes right before it
            var after_skip = preds[t].items.len > 0;
            for (preds[t].items) |j| if (!skipped[j]) {
                after_skip = false;
            };
            var fade_colour: ?Param = null;
            if (!after_skip and p.fade != null and (p.fade.?.fade_in or p.items.len > 0)) {
                fade_colour = p.fade.?.colour;
            } else if (!after_skip and p.items.len > 0) {
                fade_colour = .{ .int = 0 };
            }
            var steps: std.ArrayList(evfl.Event) = .empty;
            for (p.flags) |f| {
                const aa = try systemAction(fc, allocator, "GameDataActor", "EventTriggerSetGameDataBool", progress);
                const name = std.fmt.allocPrint(allocator, "RandoSkip_{s}_{d}", .{ p.scene, steps.items.len }) catch return error.OutOfMemory;
                steps.append(allocator, evfl.makeAction(name, aa, NONE, try setFlagParams(allocator, f))) catch return error.OutOfMemory;
            }
            if (area_intro and fade_colour == null and !after_skip and (p.fade == null or p.fade.?.fade_in)) {
                // an arrival intro may be what ends the loading screen's fade: always fade in (black)
                fade_colour = if (p.fade) |f| f.colour else Param{ .int = 0 };
            }
            if (fade_colour) |colour| {
                const aa = try systemAction(fc, allocator, "UISystemActor", "EventEventFadeIn", progress);
                const name = std.fmt.allocPrint(allocator, "RandoSkip_{s}_Fade", .{p.scene}) catch return error.OutOfMemory;
                steps.append(allocator, evfl.makeAction(name, aa, NONE, try Container.from(allocator, &.{
                    .{ .name = "Color", .value = colour },
                    .{ .name = "IsNoPlayAnime", .value = .{ .bool = false } },
                    .{ .name = "Length", .value = .{ .int = 1 } },
                    .{ .name = "IsWaitEnd", .value = .{ .bool = true } },
                }))) catch return error.OutOfMemory;
            }
            for (p.items, 0..) |it, k| {
                switch (it) {
                    .gift => |actor| {
                        const name = std.fmt.allocPrint(allocator, "RandoSkip_{s}_Item{d}", .{ p.scene, k }) catch return error.OutOfMemory;
                        steps.append(allocator, evfl.makeSubFlow(name, gift_flow, gift_entry, NONE, try Container.from(allocator, &.{
                            .{ .name = "ActorName", .value = .{ .string = actor } },
                        }))) catch return error.OutOfMemory;
                    },
                    .add => |params| {
                        const aa = try flows.requireAction(fc, allocator, "PouchSystemActor", "EventTriggerAddOrRemovePouchContent", progress);
                        const add_name = std.fmt.allocPrint(allocator, "RandoSkip_{s}_Add{d}", .{ p.scene, k }) catch return error.OutOfMemory;
                        steps.append(allocator, evfl.makeAction(add_name, aa, NONE, try params.clone(allocator))) catch return error.OutOfMemory;
                        const show_name = std.fmt.allocPrint(allocator, "RandoSkip_{s}_Show{d}", .{ p.scene, k }) catch return error.OutOfMemory;
                        steps.append(allocator, evfl.makeSubFlow(show_name, gift_flow, "DisplayGetByActorName", NONE, try Container.from(allocator, &.{
                            .{ .name = "ActorName", .value = .{ .string = params.getString("Actor") orelse "" } },
                        }))) catch return error.OutOfMemory;
                    },
                }
            }
            if (steps.items.len == 0) {
                const aa = try systemAction(fc, allocator, "EventSystemActor", "EventWait", progress);
                const name = std.fmt.allocPrint(allocator, "RandoSkip_{s}", .{p.scene}) catch return error.OutOfMemory;
                steps.append(allocator, evfl.makeAction(name, aa, NONE, try Container.from(allocator, &.{
                    .{ .name = "Frames", .value = .{ .int = 1 } },
                    .{ .name = "IsWaitEnd", .value = .{ .bool = true } },
                }))) catch return error.OutOfMemory;
            }
            // the first step takes the transition's place (everything pointing at it now reaches the skip)
            const base: u16 = @intCast(fc.events.items.len);
            fc.events.items[t] = steps.items[0];
            for (steps.items[1..]) |s| _ = try fc.addEvent(allocator, s);
            const count = steps.items.len;
            for (0..count) |k| {
                const index: u16 = if (k == 0) t else base + @as(u16, @intCast(k - 1));
                const next: u16 = if (k + 1 < count) base + @as(u16, @intCast(k)) else old_next;
                fc.events.items[index].nextPtr().?.* = next;
            }
        }
    }
    // an entry point lists the sub flow calls it reaches; a missing one hung the game (Clawshot round 13)
    try flows.listAllReachedCalls(allocator, fc);
    const out = try flows.writeBack(allocator, &doc, fc.name, progress);
    return SkipResult{ .data = out, .changed = true, .reports = reports.items };
}

// ------------------------------------------------------------------------------------------------ event info

const Table = struct {
    rel: []const u8,
    original: patchset.Latest,
    version: u16,
    big_endian: bool,
    root: byml.Value,
    rows: *byml.Array,
};

/// An RSDB table (its rows), or null.
fn readTable(allocator: Allocator, world: *World, patches: *PatchSet, prefix: []const u8) PatchError!?Table {
    const names = world.files.listDir(allocator, "RSDB") catch return error.GameFiles;
    var rel: ?[]const u8 = null;
    for (names) |n| {
        if (std.mem.startsWith(u8, n, prefix) and n.len > prefix.len and n[prefix.len] == '.') {
            rel = std.fmt.allocPrint(allocator, "RSDB/{s}", .{n}) catch return error.OutOfMemory;
            break;
        }
    }
    const r = rel orelse return null;
    const original = try patches.read(r);
    const doc = try byml.load(allocator, original.data);
    const root = doc.root orelse return error.InvalidData;
    const rows: *byml.Array = switch (root) {
        .array => |a| a,
        .dict => |d| blk: {
            for (d.entries.items) |e| if (e.value == .array) break :blk e.value.array;
            break :blk try byml.Array.create(allocator);
        },
        else => return error.InvalidData,
    };
    return Table{ .rel = r, .original = original, .version = doc.version, .big_endian = doc.big_endian, .root = root, .rows = rows };
}

/// Other flows an entry calls (sub flow calls it reaches), each once, in event order.
fn externalCalls(allocator: Allocator, fc: *evfl.Flowchart, entry: *const evfl.EntryPoint) PatchError![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    // why: an event also runs the entry points of its own flow that it calls (GimmickFlow_RoyalFamilyTomb's stone
    // event calls its CheckStone_To_MelodyGet_Sun, where the skipped Sun's Song scene now hands over the item):
    // their calls to other flows count too, or the new GetPouchContent call would be missing from the event's row
    var entries_to_visit: std.ArrayList(*const evfl.EntryPoint) = .empty;
    var visited_entries: std.ArrayList([]const u8) = .empty;
    entries_to_visit.append(allocator, entry) catch return error.OutOfMemory;
    while (entries_to_visit.pop()) |current| {
        const reached = try fc.reach(allocator, current.main_event);
        for (reached, 0..) |r, i| {
            if (!r) continue;
            const call: struct { flowchart: []const u8, entry_point: []const u8 } = switch (fc.events.items[i].kind) {
                .sub_flow => |s| .{ .flowchart = s.flowchart, .entry_point = s.entry_point },
                .sub_flow_switch => |s| .{ .flowchart = s.flowchart, .entry_point = s.entry_point },
                else => continue,
            };
            const is_own_flow = call.flowchart.len == 0 or std.mem.eql(u8, call.flowchart, fc.name);
            if (is_own_flow) {
                if (flows.contains(visited_entries.items, call.entry_point)) continue;
                visited_entries.append(allocator, call.entry_point) catch return error.OutOfMemory;
                if (fc.entryPoint(call.entry_point)) |called| entries_to_visit.append(allocator, called) catch return error.OutOfMemory;
                continue;
            }
            if (flows.contains(out.items, call.flowchart)) continue;
            out.append(allocator, call.flowchart) catch return error.OutOfMemory;
        }
    }
    return out.items;
}

pub const ChangedFlow = struct {
    name: []const u8,
    flowchart: *evfl.Flowchart,
};

/// Adds the flows each changed event now calls to its GameAnalyzedEventInfo SubFlowList. Returns the events changed.
pub fn updateEventInfo(allocator: Allocator, world: *World, patches: *PatchSet, changed_flows: []const ChangedFlow, progress: *Progress) PatchError![]const []const u8 {
    const setting = (try readTable(allocator, world, patches, "EventSetting")) orelse return progress.fail(error.NotAsExpected, "event tables not found", .{});
    const info = (try readTable(allocator, world, patches, "GameAnalyzedEventInfo")) orelse return progress.fail(error.NotAsExpected, "event tables not found", .{});
    var by_id = std.StringHashMap(*byml.Dict).init(allocator);
    for (info.rows.items.items) |r| {
        const d = r.asDict() orelse continue;
        by_id.put(d.getString("__RowId") orelse continue, d) catch return error.OutOfMemory;
    }
    var changed: std.ArrayList([]const u8) = .empty;
    for (setting.rows.items.items) |r| {
        const d = r.asDict() orelse continue;
        const file = d.getString("FlowchartFileName") orelse "";
        const base = if (std.mem.lastIndexOfScalar(u8, file, '/')) |i| file[i + 1 ..] else file;
        const flow = if (std.mem.indexOfScalar(u8, base, '.')) |i| base[0..i] else base;
        var fc: ?*evfl.Flowchart = null;
        for (changed_flows) |cf| if (std.mem.eql(u8, cf.name, flow)) {
            fc = cf.flowchart;
        };
        const row_id = d.getString("__RowId") orelse continue;
        const row = by_id.get(row_id) orelse continue; // an event without a row may call anything
        const f = fc orelse continue;
        const entry = f.entryPoint(d.getString("EntryPointName") orelse continue) orelse continue;
        var added = false;
        for (try externalCalls(allocator, f, entry)) |call| {
            var present = false;
            if (row.getArray("SubFlowList")) |listed| {
                for (listed.items.items) |v| if (v.asString()) |s| if (std.mem.eql(u8, s, call)) {
                    present = true;
                };
            }
            if (!present) {
                const listed = try row.ensureArray(allocator, "SubFlowList");
                try listed.append(allocator, .{ .string = call });
                added = true;
            }
        }
        if (added) changed.append(allocator, row_id) catch return error.OutOfMemory;
    }
    if (changed.items.len > 0) {
        const out = try byml.dump(allocator, info.root, info.version, info.big_endian);
        try patches.emitZs(info.rel, info.original, out);
    }
    return changed.items;
}

/// Applies a list of skips. Run after the item edits, so gifts are the randomized items.
pub fn patchStoryScenes(world: *World, patches: *PatchSet, progress: *Progress, list: []const SkipList, label: []const u8, area_intro: bool) PatchError!void {
    const a = patches.allocator;
    var docs: std.ArrayList(ChangedFlow) = .empty;
    for (list) |item| {
        const rel = try flowRel(a, item.flow);
        if (!world.files.exists(rel)) {
            progress.log("warning: {s}: {s} not found; its scenes still play", .{ label, item.flow });
            continue;
        }
        const orig = try patches.read(rel);
        const result = skipScenes(a, world, patches, orig.data, item.scenes, area_intro, item.song_lessons, progress) catch |err| switch (err) {
            error.NotAsExpected, error.InvalidData => {
                progress.log("warning: {s}: {s} not changed ({s}); its scenes still play", .{ label, item.flow, progress.failureMessage() });
                continue;
            },
            else => return err,
        };
        if (result.changed and !std.mem.eql(u8, result.data, orig.data)) {
            try patches.emitZs(rel, orig, result.data);
            const doc = try evfl.read(a, result.data);
            docs.append(a, .{ .name = item.flow, .flowchart = doc.flowchart.? }) catch return error.OutOfMemory;
        }
        var kept_text: std.ArrayList(u8) = .empty;
        var kept: usize = 0;
        for (result.reports) |r| {
            if (!std.mem.startsWith(u8, r.text, "kept")) continue;
            kept += 1;
            kept_text.print(a, "; {s} {s}", .{ r.scene, r.text }) catch return error.OutOfMemory;
        }
        progress.log("{s}: {s}: {d} scenes skipped{s}", .{ label, item.flow, result.reports.len - kept, kept_text.items });
    }
    if (docs.items.len > 0) {
        const events = try updateEventInfo(a, world, patches, docs.items, progress);
        const joined = std.mem.join(a, ", ", events) catch return error.OutOfMemory;
        progress.log("{s}: event info updated for {d} events ({s})", .{ label, events.len, joined });
    }
}

/// Standalone intro scene `data` with its first entry doing nothing but setting its flags.
fn emptyIntro(allocator: Allocator, world: *World, data: []const u8, progress: *Progress) PatchError!struct { data: []u8, flags: [][]const u8 } {
    var doc = try flows.readFlow(allocator, data, "intro", progress);
    const fc = doc.flowchart orelse return progress.fail(error.NotAsExpected, "no flowchart", .{});
    if (fc.entry_points.items.len == 0) return progress.fail(error.NotAsExpected, "no flowchart", .{});
    const effects = try sceneEffects(allocator, &doc, true, false, progress);
    // its played flag too (Dodongo's Cavern's location area only exists once Dm_DodongoCave_0000 has played)
    var flags: std.ArrayList([]const u8) = .empty;
    const seen = std.fmt.allocPrint(allocator, "HavePlayedEvent.{s}", .{fc.name}) catch return error.OutOfMemory;
    for (effects.flags) |f| {
        if (!flows.contains(flags.items, f) and try gamedata.boolExists(world, f)) flags.append(allocator, f) catch return error.OutOfMemory;
    }
    if (!flows.contains(flags.items, seen) and try gamedata.boolExists(world, seen)) flags.append(allocator, seen) catch return error.OutOfMemory;

    const first: u16 = @intCast(fc.events.items.len);
    for (flags.items, 0..) |f, k| {
        const aa = try systemAction(fc, allocator, "GameDataActor", "EventTriggerSetGameDataBool", progress);
        const name = std.fmt.allocPrint(allocator, "RandoIntro_{d}", .{k}) catch return error.OutOfMemory;
        _ = try fc.addEvent(allocator, evfl.makeAction(name, aa, NONE, try setFlagParams(allocator, f)));
    }
    if (flags.items.len == 0) {
        const aa = try systemAction(fc, allocator, "EventSystemActor", "EventWait", progress);
        _ = try fc.addEvent(allocator, evfl.makeAction("RandoIntro_Wait", aa, NONE, try Container.from(allocator, &.{
            .{ .name = "Frames", .value = .{ .int = 1 } },
            .{ .name = "IsWaitEnd", .value = .{ .bool = true } },
        })));
    }
    const count: u16 = @intCast(fc.events.items.len - first);
    for (0..count) |k| {
        fc.events.items[first + k].kind.action.next = if (k + 1 < count) first + @as(u16, @intCast(k)) + 1 else NONE;
    }
    const entry = &fc.entry_points.items[0];
    entry.main_event = first;
    const reached = try fc.reach(allocator, first);
    var keep: std.ArrayList(u16) = .empty;
    for (entry.sub_flow_events.items) |i| if (i < reached.len and reached[i]) keep.append(allocator, i) catch return error.OutOfMemory;
    entry.sub_flow_events = keep;
    const out = try flows.writeBack(allocator, &doc, fc.name, progress);
    return .{ .data = out, .flags = flags.items };
}

/// Skip Area Intros for the intros area_skips and area_standalone list.
pub fn patchAreaIntros(world: *World, patches: *PatchSet, progress: *Progress) PatchError!void {
    try patchStoryScenes(world, patches, progress, &area_skips, "Skip Area Intros", true);
    const a = patches.allocator;
    for (area_standalone) |scene| {
        const rel = try flowRel(a, scene);
        if (!world.files.exists(rel)) {
            progress.log("warning: Skip Area Intros: {s} not found; it still plays", .{scene});
            continue;
        }
        const orig = try patches.read(rel);
        const result = emptyIntro(a, world, orig.data, progress) catch |err| switch (err) {
            error.NotAsExpected, error.InvalidData => {
                progress.log("warning: Skip Area Intros: {s} not changed ({s}); it still plays", .{ scene, progress.failureMessage() });
                continue;
            },
            else => return err,
        };
        try patches.emitZs(rel, orig, result.data);
        const joined = std.mem.join(a, ", ", result.flags) catch return error.OutOfMemory;
        progress.log("Skip Area Intros: {s} emptied (sets {s})", .{ scene, if (joined.len > 0) joined else "nothing" });
    }
}
