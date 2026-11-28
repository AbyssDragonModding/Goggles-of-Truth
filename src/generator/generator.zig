//! Making a seed: check the game, plan and place the items (with retries), choose hints, write the mod folder, the
//! spoiler log and the checklist, then switch the output folder's other seeds off and the saves over.
//! (rando/generator.py generate and write_spoiler.)

const std = @import("std");
const settings_mod = @import("../settings/settings.zig");
const world_mod = @import("../game/world.zig");
const gamecheck = @import("../game/gamecheck.zig");
const logic = @import("../logic/logic.zig");
const fill = @import("fill.zig");
const hints = @import("hints.zig");
const patches = @import("patches.zig");
const checklist = @import("checklist.zig");
const filecache = @import("filecache.zig");
const fsmod = @import("../core/fs.zig");
const hash = @import("../core/hash.zig");
const Rng = @import("../core/rng.zig").Rng;
const Progress = @import("../core/Progress.zig");
const Env = @import("../platform/Env.zig");
const longshot = @import("../platform/longshot.zig");
const saves = @import("../platform/saves.zig");
const version_mod = @import("../version.zig");
const seedinfo = @import("../core/seedinfo.zig");
const testplan = @import("../core/testplan.zig");
const teststart = @import("teststart.zig");
const Allocator = std.mem.Allocator;
const Settings = settings_mod.Settings;
const World = world_mod.World;
const ItemId = logic.ItemId;

pub const GenerateError = error{
    /// the seed couldn't be made; the Progress failure message says why
    GenerationFailed,
    OutOfMemory,
};

pub const Request = struct {
    /// the .nup or the romfs folder
    game_path: []const u8,
    out_dir: []const u8,
    settings: Settings,
    /// null or "": a random seed
    seed: ?[]const u8 = null,
    /// null or "": GogglesOfTruth_<seed>
    mod_name: ?[]const u8 = null,
    /// the exefs folder ("": next to the romfs folder)
    exefs: []const u8 = "",
    /// Reuse compressed files from the cache folder (filecache.zig). Always on in the window: it costs next to
    /// nothing when no file can be reused and saves a lot when many can. Only `goggles_cli --no-cache` turns it
    /// off, to measure a seed without the cache; the mod is byte for byte the same either way.
    use_file_cache: bool = true,
    /// Test seeds only (`goggles_cli generate --place`): items put at chosen locations before the fill. Written to
    /// settings.txt, so a rebuild places them again.
    test_placements: []const seedinfo.TestPlacement = &.{},
    /// Test seeds only (`goggles_cli test`): the test plan's text (core/testplan.zig), for its start: spawn, age, time,
    /// start items, quests, flags, cutscenes. Kept in the seed folder as test_plan.toml; a rebuild without one here
    /// uses the folder's. Its placements come in `test_placements`.
    test_plan_text: ?[]const u8 = null,
    /// Rebuild Seed / `--rebuild`: the same seed made again into its own folder. Its saves stay with it
    /// (saves.keepSavesForRebuild): the game's slots are never emptied or switched away for it.
    rebuild: bool = false,
};

pub const Result = struct {
    seed: []const u8,
    settings_string: []const u8,
    mod_root: []const u8,
    file_count: usize,
    /// every shuffled location's id and the item key placed there (for tools that compare builds)
    placement: []const Placement,
    /// the hints on the stones (label, kind and the location / area / item / joke line they name)
    hints: []const HintRecord,
};

pub const HintRecord = struct {
    label: []const u8,
    kind: []const u8,
    area: ?[]const u8,
    location: ?[]const u8,
    item: ?[]const u8,
    line: usize,
};

pub const Placement = struct {
    location: []const u8,
    item: []const u8,
};

const seed_alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

/// A random 10-character seed name (from the OS's random source).
pub fn randomSeed(io: std.Io, buffer: *[10]u8) []const u8 {
    var raw: [10]u8 = undefined;
    io.random(&raw);
    for (buffer, raw) |*c, r| c.* = seed_alphabet[r % seed_alphabet.len];
    return buffer;
}

/// Makes one seed. `world`: the scanned game when the caller keeps one (the window), else null (it is scanned here).
/// Strings in the result are allocated with `result_allocator`; everything else lives in a generation arena.
/// `gpa` must be thread-safe (the program's gpa is): the mod's files are compressed on several threads.
pub fn generate(gpa: Allocator, result_allocator: Allocator, env: *const Env, request: Request, world_in: ?*World, progress: *Progress) GenerateError!Result {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit(); // the whole generation run is freed at once
    const a = arena_state.allocator();
    const fs = env.fs;
    const t0 = std.Io.Timestamp.now(fs.io, .awake);

    const game = gamecheck.check(a, fs, request.exefs, request.game_path) catch return error.OutOfMemory;
    if (!game.ok) return progress.fail(error.GenerationFailed, "{s}", .{game.message});
    progress.log("{s}", .{game.message});

    const st = &request.settings;
    const sstr = settings_mod.toString(a, st) catch return error.OutOfMemory;
    var seed_buf: [10]u8 = undefined;
    const seed: []const u8 = if (request.seed) |s| (if (s.len > 0) s else randomSeed(fs.io, &seed_buf)) else randomSeed(fs.io, &seed_buf);
    const mod_name = if (request.mod_name) |m| (if (m.len > 0) m else null) else null;
    const name = mod_name orelse (std.fmt.allocPrint(a, "{s}{s}", .{ longshot.mod_prefix, seed }) catch return error.OutOfMemory);
    try refuseWhileGameHoldsOtherSeeds(a, env, request.out_dir, name, progress);

    var own_world: ?*World = null;
    defer if (own_world) |w| w.deinit();
    const world = world_in orelse blk: {
        own_world = World.init(gpa, fs, request.game_path, progress) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.GenerationFailed,
        };
        break :blk own_world.?;
    };

    // a test plan's start (teststart.zig): the request's, or when rebuilding, the plan the seed folder keeps. Checked
    // against the game before the fill, so a wrong name stops the test at once (and before the earlier build's files,
    // the kept plan among them, are removed).
    const plan_folder = fsmod.join(a, &.{ request.out_dir, name }) catch return error.OutOfMemory;
    const test_plan_text: ?[]const u8 = request.test_plan_text orelse if (request.rebuild)
        (testplan.readFromSeedFolder(a, fs, plan_folder) catch return error.OutOfMemory)
    else
        null;
    var test_start: ?teststart.Resolved = null;
    if (test_plan_text) |text| {
        var problem = testplan.Problem{};
        const test_plan = testplan.parse(a, text, &problem) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidPlan => return progress.fail(error.GenerationFailed, "test plan: {s}", .{problem.message}),
        };
        switch (teststart.resolve(a, world, &test_plan.start) catch |err| return patchError(err, progress)) {
            .problem => |message| return progress.fail(error.GenerationFailed, "test plan: {s}", .{message}),
            .ready => |resolved| {
                for (resolved.summary) |line| progress.log("Test start: {s}", .{line});
                test_start = resolved;
            },
        }
    }

    progress.log("Building item pool...", .{});
    // why: the placement version, not the release, so a release that only fixes patches places a seed the same way
    // (version.zig); the text is "<placement version>|<seed>|<settings string>" as before 0.7.4, so seeds made with
    // 0.7.3 come out the same
    const seed_key = std.fmt.allocPrint(a, "{s}|{s}|{s}", .{ version_mod.placement_version, seed, sstr }) catch return error.OutOfMemory;
    // the Random options (open areas, the bridge and its counts, random starting items), rolled from the seed into
    // the settings the fill and every patch read; the settings string keeps "Random" (settings/randomize.zig)
    const rolled = settings_mod.randomize.rollRandomChoices(a, st, seed_key) catch return error.OutOfMemory;
    const rolled_st = a.create(settings_mod.Settings) catch return error.OutOfMemory;
    rolled_st.* = rolled.settings;
    for (rolled.rolls) |roll| progress.log("Random: {s} is {s}", .{ roll.label, roll.value });
    const plan = fill.Plan.init(a, world, rolled_st, seed_key) catch |err| return planError(err, progress);
    plan.chosen_settings = st;
    plan.random_rolls = rolled.rolls;
    if (request.test_placements.len > 0) {
        if (plan.applyTestPlacements(request.test_placements) catch return error.OutOfMemory) |problem| {
            return progress.fail(error.GenerationFailed, "test placement: {s}", .{problem});
        }
        plan.test_placements_text = seedinfo.formatTestPlacements(a, request.test_placements) catch return error.OutOfMemory;
        for (request.test_placements) |placement| progress.log("Test placement: {s} holds {s}", .{ placement.location, placement.item });
    }
    if (plan.exclusion_ignored.items.len > 0) {
        progress.log("note: {d} excluded location(s) can only hold a song or a boss reward with these settings, so they aren't excluded: {s}", .{
            plan.exclusion_ignored.items.len, std.mem.join(a, ", ", plan.exclusion_ignored.items) catch return error.OutOfMemory,
        });
    }
    if (plan.start_inventory.len > 0) {
        var names: std.ArrayList([]const u8) = .empty;
        for (plan.start_inventory) |item| names.append(a, world.itemNameById(a, item) catch return error.OutOfMemory) catch return error.OutOfMemory;
        progress.log("Starting Inventory: {s}", .{std.mem.join(a, ", ", names.items) catch return error.OutOfMemory});
    }
    if (plan.start_inventory_unknown.len > 0) {
        progress.log("warning: Starting Inventory: not items of this game, left out: {s}", .{std.mem.join(a, ", ", plan.start_inventory_unknown) catch return error.OutOfMemory});
    }
    if (st.itemRestrictions().len > 0) {
        progress.log("Item Restrictions: {d} of {d} entries apply", .{ st.itemRestrictions().len - plan.restriction_problems.items.len, st.itemRestrictions().len });
        for (plan.restriction_problems.items) |problem| progress.log("warning: Item Restrictions: {s} (ignored)", .{problem});
    }
    {
        var behind_rocks: usize = 0;
        for (plan.behind_bomb_rock) |behind| {
            if (behind) behind_rocks += 1;
        }
        progress.log("Bomb Bag rule: {d} spots behind bombable rocks never get the first Bomb Bag", .{behind_rocks});
    }
    const user_excluded = plan.countUserExcluded();
    if (user_excluded > 0) progress.log("Excluded locations: {d} of the shuffled locations only get junk", .{user_excluded});

    // locations no item set can reach are treated as excluded (they only get junk)
    {
        var probe = fill.Filler.init(a, plan, 0, progress) catch return error.OutOfMemory;
        var everything: std.ArrayList(ItemId) = .empty;
        for (plan.pool.items) |i| if (logic.isProgression(i)) everything.append(a, i) catch return error.OutOfMemory;
        for (plan.fixed) |f| if (f) |i| everything.append(a, i) catch return error.OutOfMemory;
        const none = a.alloc(?ItemId, plan.fixed.len) catch return error.OutOfMemory;
        @memset(none, null);
        var full = probe.sweep(everything.items, none) catch |err| return planError(err, progress);
        var unreachable_count: usize = 0;
        for (plan.shuffled.items) |i| {
            if (!plan.reachable(i, &full.state)) {
                unreachable_count += 1;
                if (!st.is(.logic_rules, "none")) plan.excluded[i] = true;
            }
        }
        if (unreachable_count > 0 and !st.is(.logic_rules, "none")) {
            progress.log("note: {d} location(s) are out of logic and will only hold junk", .{unreachable_count});
        }
    }

    // every attempt gets its own stream from the seed's stream, so a seed always comes out the same
    const seed_text = std.fmt.allocPrint(a, "{s}|{s}|{s}", .{ version_mod.placement_version, seed, sstr }) catch return error.OutOfMemory;
    var rng = Rng.fromText(seed_text);
    var filler: ?*fill.Filler = null;
    var last_error: []const u8 = "";
    var attempt: usize = 1;
    while (attempt <= 40) : (attempt += 1) {
        progress.log("Placing items (attempt {d})...", .{attempt});
        const f = a.create(fill.Filler) catch return error.OutOfMemory;
        f.* = fill.Filler.init(a, plan, rng.next(), progress) catch return error.OutOfMemory;
        f.run() catch |err| switch (err) {
            error.PlacementFailed => {
                last_error = a.dupe(u8, progress.failureMessage()) catch return error.OutOfMemory;
                continue;
            },
            else => return planError(err, progress),
        };
        if (st.is(.logic_rules, "none")) {
            filler = f;
            break;
        }
        var result = f.sweep(&.{}, f.contents() catch return error.OutOfMemory) catch |err| return planError(err, progress);
        if (!result.state.is(.win)) {
            last_error = "seed not beatable";
            continue;
        }
        if (st.is(.reachable_locations, "all")) {
            var missing: usize = 0;
            for (plan.shuffled.items) |i| if (!result.got[i] and !plan.excluded[i]) {
                missing += 1;
            };
            if (missing > 0) {
                last_error = std.fmt.allocPrint(a, "{d} locations unreachable", .{missing}) catch return error.OutOfMemory;
                continue;
            }
        }
        filler = f;
        break;
    }
    const placed_filler = filler orelse {
        if (request.test_placements.len > 0) {
            return progress.fail(error.GenerationFailed, "could not place items after 40 attempts: {s} - a test placement may be behind what its own item opens (Kokiri Forest's grotto chests need bombs and the Song of Storms, for example); choose a location that is open sooner.", .{last_error});
        }
        if (user_excluded > 0) {
            return progress.fail(error.GenerationFailed, "could not place items after 40 attempts: {s} - {d} locations are excluded; the items that have to be placed (progression, dungeon items) may not fit in the rest, or not where they can be reached in time. Exclude fewer locations.", .{ last_error, user_excluded });
        }
        return progress.fail(error.GenerationFailed, "could not place items after 40 attempts: {s}", .{last_error});
    };

    var hint_list: []const hints.Hint = &.{};
    if (!st.is(.hint_distribution, "none")) {
        progress.log("Choosing hints...", .{});
        hint_list = hints.choose(a, world, plan, placed_filler, seed, st.choice(.hint_distribution), st.is(.gossip_stones, "mask")) catch |err| return patchError(err, progress);
    }

    const mod_root = fsmod.join(a, &.{ request.out_dir, name }) catch return error.OutOfMemory;
    // The game files are only ever read: every patched file is written to the mod folder. Refuse an output folder
    // inside a romfs folder (the window checks this too), so a mistake can never write into the game files. A .nup
    // is a single file opened read-only, so there is nothing to protect there.
    if (world.files.kind == .folder) {
        const game_abs = fs.absolute(a, world.files.romfs) catch return error.OutOfMemory;
        const mod_abs = fs.absolute(a, mod_root) catch return error.OutOfMemory;
        if (fsmod.isInside(game_abs, mod_abs)) return progress.fail(error.GenerationFailed, "The output folder must not be inside the romfs folder.", .{});
    }

    if (request.rebuild) {
        // why checked again here (the window and the command line check before starting): nothing may rebuild a seed
        // over one with other placements, whichever way the request came; nothing has been written yet
        switch (try checkRebuild(a, fs, mod_root)) {
            .other_placements => |info| return progress.fail(error.GenerationFailed, "{s}", .{try placementMismatchMessage(a, name, info)}),
            .ready, .not_a_seed => {},
        }
        // why: the game would keep running on the old mod files and could save over the slots being kept
        if (saves.targetFor(a, env, request.out_dir) catch return error.OutOfMemory) |target| {
            if (saves.gameRunning(a, env, target)) |running| {
                if (running.len > 0) return progress.fail(error.GenerationFailed, "{s} is running: close it first, then rebuild the seed (its saves are kept)", .{running});
            }
        }
    }
    try clearEarlierBuild(a, fs, mod_root, name, progress);
    progress.log("Writing mod files...", .{});
    const placed = placed_filler.contents() catch return error.OutOfMemory;
    // what gets patched: the shuffled placements and the forced items, not the vanilla fixed ones
    const to_patch = a.alloc(?ItemId, placed.len) catch return error.OutOfMemory;
    for (to_patch, 0..) |*p, i| p.* = placed_filler.placed[i] orelse plan.forced[i];
    const out_romfs = fsmod.join(a, &.{ mod_root, "romfs" }) catch return error.OutOfMemory;
    // the file cache: compressing the patched files is most of a seed's time, and many come out the same from seed
    // to seed (filecache.zig)
    var cache_state: ?filecache.FileCache = null;
    if (request.use_file_cache) cache_state = filecache.FileCache.init(a, fs, env.app_dir) catch return error.OutOfMemory;
    const cache: ?*filecache.FileCache = if (cache_state) |*c| c else null;
    const written = patches.writePatches(gpa, a, .{
        .world = world,
        .plan = plan,
        .placed = to_patch,
        .hint_list = hint_list,
        .out_romfs = out_romfs,
        .cache = cache,
        .test_start = if (test_start) |*resolved| resolved else null,
    }, progress) catch |err| return patchError(err, progress);
    if (cache) |c| {
        progress.log("File cache: {d} of {d} large files reused, {d} compressed and stored", .{ c.hits, c.hits + c.misses, c.misses });
        if (c.replaced > 0) progress.log("File cache: {d} damaged file(s) made again", .{c.replaced});
        if (c.warning) |w| progress.log("warning: the file cache is off for this seed: {s}", .{w});
        if (c.misses > 0 and c.warning == null) c.trim(gpa);
    }

    if (st.flag(.create_spoiler)) {
        writeSpoiler(a, world, plan, placed_filler, hint_list, seed, sstr, mod_root, fs) catch |err| return patchError(err, progress);
        // it holds every placement, so only with the spoiler
        checklist.write(a, world, plan, placed_filler, mod_root, seed, sstr, fs) catch |err| {
            progress.log("warning: checklist.xlsx not written ({s})", .{@errorName(err)});
        };
    }
    const settings_txt = settingsText(a, seed, sstr, plan.test_placements_text) catch return error.OutOfMemory;
    fs.writeAll(fsmod.join(a, &.{ mod_root, "settings.txt" }) catch return error.OutOfMemory, settings_txt) catch |err|
        return progress.fail(error.GenerationFailed, "couldn't write settings.txt ({s})", .{@errorName(err)});
    if (test_plan_text) |text| {
        // kept with the seed, so a rebuild makes the same start (testplan.readFromSeedFolder)
        fs.writeAll(fsmod.join(a, &.{ mod_root, testplan.file_name_in_seed_folder }) catch return error.OutOfMemory, text) catch |err|
            return progress.fail(error.GenerationFailed, "couldn't write {s} ({s})", .{ testplan.file_name_in_seed_folder, @errorName(err) });
    }

    try switchOtherSeeds(a, env, request.out_dir, name, st, request.rebuild, progress);

    const t1 = std.Io.Timestamp.now(fs.io, .awake);
    const ms = @divTrunc(t1.nanoseconds - t0.nanoseconds, std.time.ns_per_ms);
    progress.log("Done in {d}.{d}s: {d} files written to {s}", .{ @divTrunc(ms, 1000), @divTrunc(@mod(ms, 1000), 100), written.len, mod_root });
    return Result{
        .seed = result_allocator.dupe(u8, seed) catch return error.OutOfMemory,
        .settings_string = result_allocator.dupe(u8, sstr) catch return error.OutOfMemory,
        .mod_root = result_allocator.dupe(u8, mod_root) catch return error.OutOfMemory,
        .file_count = written.len,
        .placement = try placementList(result_allocator, world, placed_filler),
        .hints = try hintRecords(result_allocator, world, hint_list),
    };
}

fn placementList(allocator: Allocator, world: *World, filler: *fill.Filler) GenerateError![]const Placement {
    var out: std.ArrayList(Placement) = .empty;
    for (filler.placed, 0..) |p, i| {
        const item = p orelse continue;
        out.append(allocator, .{
            .location = allocator.dupe(u8, world.locations.items[i].id) catch return error.OutOfMemory,
            .item = allocator.dupe(u8, world.items.name(item)) catch return error.OutOfMemory,
        }) catch return error.OutOfMemory;
    }
    return out.items;
}

fn hintRecords(allocator: Allocator, world: *World, list: []const hints.Hint) GenerateError![]const HintRecord {
    const out = allocator.alloc(HintRecord, list.len) catch return error.OutOfMemory;
    for (list, 0..) |h, i| {
        out[i] = .{
            .label = allocator.dupe(u8, h.label) catch return error.OutOfMemory,
            .kind = @tagName(h.kind),
            .area = if (h.area) |x| allocator.dupe(u8, x) catch return error.OutOfMemory else null,
            .location = if (h.location) |l| allocator.dupe(u8, world.locations.items[l].id) catch return error.OutOfMemory else null,
            .item = if (h.item) |it| allocator.dupe(u8, world.items.name(it)) catch return error.OutOfMemory else null,
            .line = h.line,
        };
    }
    return out;
}

fn planError(err: fill.FillError, progress: *Progress) GenerateError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.PlacementFailed, error.NotAsExpected => progress.fail(error.GenerationFailed, "{s}", .{progress.failureMessage()}),
        error.GameFiles => progress.fail(error.GenerationFailed, "a game file couldn't be read", .{}),
        error.InvalidData => progress.fail(error.GenerationFailed, "a game file isn't as expected", .{}),
    };
}

fn patchError(err: anytype, progress: *Progress) GenerateError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.GameFiles => progress.fail(error.GenerationFailed, "a game file couldn't be read", .{}),
        error.InvalidData => progress.fail(error.GenerationFailed, "a game file isn't as expected", .{}),
        else => blk: {
            // the step already said why (NotAsExpected, SettingFailed, WriteFailed)
            if (progress.failureMessage().len == 0) progress.setFailure("{s}", .{@errorName(err)});
            break :blk error.GenerationFailed;
        },
    };
}

/// Longshot and emulators load every mod folder: the other seeds are switched off, and with Per-Seed Saves the saves
/// follow the new seed.
/// Stops before anything is made when the game is running and other seeds in the output folder are switched on.
/// Why: the running game keeps every switched-on seed's files open, so they can't be switched off (renamed or moved),
/// and the game would load them together with the new seed (test report: older test seeds stayed on). Rebuilding a
/// seed is refused while the game runs anyway (generate).
fn refuseWhileGameHoldsOtherSeeds(a: Allocator, env: *const Env, out_dir: []const u8, name: []const u8, progress: *Progress) GenerateError!void {
    const target = (saves.targetFor(a, env, out_dir) catch return error.OutOfMemory) orelse return;
    const running = saves.gameRunning(a, env, target) orelse return;
    if (running.len == 0) return;
    var other_active_seeds: std.ArrayList([]const u8) = .empty;
    if (longshot.isModsFolder(a, env, out_dir)) {
        for (longshot.activeSeeds(a, env, out_dir, name) catch return error.OutOfMemory) |seed_name| other_active_seeds.append(a, seed_name) catch return error.OutOfMemory;
    }
    if (target.kind == .emulator) {
        for (saves.seeds(a, env, target) catch return error.OutOfMemory) |seed_entry| {
            if (seed_entry.on and !std.mem.eql(u8, seed_entry.name, name)) other_active_seeds.append(a, seed_entry.name) catch return error.OutOfMemory;
        }
    }
    if (other_active_seeds.items.len == 0) return;
    const listed = std.mem.join(a, ", ", other_active_seeds.items) catch return error.OutOfMemory;
    return progress.fail(error.GenerationFailed, "{s} is running and these seeds are switched on: {s}. While the game runs it keeps their files open, so they can't be switched off, and it would load them together with the new seed. Close {s} first, then make the seed again (nothing was written).", .{ running, listed, running });
}

fn switchOtherSeeds(a: Allocator, env: *const Env, out_dir: []const u8, name: []const u8, st: *const Settings, rebuild: bool, progress: *Progress) GenerateError!void {
    if (longshot.isModsFolder(a, env, out_dir)) {
        // two seeds at once would mix, so the others are switched off
        for (longshot.switchOffOtherSeeds(a, env, out_dir, name) catch return error.OutOfMemory) |r| {
            progress.log("Longshot: switched off the older seed {s} (renamed to {s})", .{ r.old, r.new });
        }
        const left = longshot.activeSeeds(a, env, out_dir, name) catch return error.OutOfMemory;
        if (left.len > 0) {
            progress.log("WARNING: Longshot would load these seeds too, and they couldn't be renamed (close the game first, then put _ in front of their names): {s}", .{std.mem.join(a, ", ", left) catch return error.OutOfMemory});
        }
        // the player's other mods are left switched on, but one that replaces the seed's files is named
        for (longshot.modsReplacingSeedFiles(a, env, out_dir, name) catch return error.OutOfMemory) |clash| {
            if (clash.replaces_texts) {
                progress.log("WARNING: the mod {s} is switched on and replaces this seed's game texts (files in common: {d}). New item names show as \"MsgNotFound\" and their item windows can softlock. Switch it off while playing this seed (close the game, then put _ in front of its folder name).", .{ clash.mod, clash.shared_files });
            } else {
                progress.log("WARNING: the mod {s} is switched on and replaces some of this seed's game files (files in common: {d}), so parts of the seed may not work. Switch it off while playing this seed (close the game, then put _ in front of its folder name).", .{ clash.mod, clash.shared_files });
            }
        }
    }
    const target = (saves.targetFor(a, env, out_dir) catch return error.OutOfMemory) orelse return;
    if (target.note.len > 0) progress.log("WARNING: {s}", .{target.note});
    if (target.kind == .emulator) {
        // the emulator loads every mod folder in load/<title id>: move the other seeds out
        var before: std.ArrayList([]const u8) = .empty;
        for (saves.seeds(a, env, target) catch return error.OutOfMemory) |s| {
            if (s.on and !std.mem.eql(u8, s.name, name)) before.append(a, s.name) catch return error.OutOfMemory;
        }
        const failed = saves.switchOffEmulatorSeeds(a, env, target, name) catch return error.OutOfMemory;
        std.mem.sort([]const u8, before.items, {}, struct {
            fn less(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.order(u8, x, y) == .lt;
            }
        }.less);
        for (before.items) |n| {
            var did_fail = false;
            for (failed) |f| if (std.mem.eql(u8, f, n)) {
                did_fail = true;
            };
            if (!did_fail) progress.log("Emulator: switched off the older seed {s} (moved to {s})", .{ n, target.off });
        }
        if (failed.len > 0) {
            progress.log("WARNING: the emulator would load these seeds too, and they couldn't be moved (close the emulator first): {s}", .{std.mem.join(a, ", ", failed) catch return error.OutOfMemory});
        }
    }
    if (st.flag(.per_seed_saves)) {
        var msg = saves.Messages{ .allocator = a };
        const switched = if (rebuild) saves.keepSavesForRebuild(a, env, target, name, &msg) else saves.switchSaves(a, env, target, name, &msg);
        switched catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.SaveFailed => progress.log("WARNING: per-seed saves not switched ({s}). Your saves weren't changed; once the game is closed, use Play This Seed on the General Settings tab.", .{msg.failure}),
        };
        for (msg.lines.items) |line| progress.log("Per-seed saves: {s}", .{line});
    }
}

// ------------------------------------------------------------------------------------------------ seed folders

/// settings.txt (also the top of spoiler.txt): the release, the placement version, the seed and the settings string.
/// Rebuilding a seed reads it back (core/seedinfo.zig), and per-seed saves compare it to know a seed folder's saves fit.
/// A test seed adds its chosen placements ("Test placements: ..."); they are only listed there, not in the spoiler's
/// regions (they aren't shuffled).
pub fn settingsText(allocator: Allocator, seed: []const u8, settings_string: []const u8, test_placements_text: []const u8) error{OutOfMemory}![]const u8 {
    const base = try std.fmt.allocPrint(allocator, "{s} {s}\nPlacement version: {s}\nSeed: {s}\nSettings string: {s}\n", .{
        version_mod.name, version_mod.version, version_mod.placement_version, seed, settings_string,
    });
    if (test_placements_text.len == 0) return base;
    return std.fmt.allocPrint(allocator, "{s}Test placements: {s}\n", .{ base, test_placements_text });
}

pub const RebuildCheck = union(enum) {
    /// the folder can be made again with this release: the same seed, settings string and placements
    ready: seedinfo.SeedInfo,
    /// no readable settings.txt in the folder
    not_a_seed,
    /// made by a release whose placements differ: a rebuild would put items elsewhere, and its saves wouldn't fit
    other_placements: seedinfo.SeedInfo,
};

/// Can the seed in `seed_folder` be rebuilt with this release? Strings point into memory from `allocator`.
pub fn checkRebuild(allocator: Allocator, fs: fsmod.Fs, seed_folder: []const u8) error{OutOfMemory}!RebuildCheck {
    const path = try fsmod.join(allocator, &.{ seed_folder, "settings.txt" });
    const text = fs.readAll(allocator, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .not_a_seed,
    };
    const info = seedinfo.parseSettingsText(text) orelse return .not_a_seed;
    if (!std.mem.eql(u8, info.placement_version, version_mod.placement_version)) return .{ .other_placements = info };
    return .{ .ready = info };
}

/// Why a seed with other placements can't be rebuilt, for the window and the command line alike: the reason, and
/// that the seed and its saves are untouched and still playable. Why refuse at all: the placement version goes into
/// the seed's random stream (version.zig), so rebuilt with another one, the same seed number would put items
/// elsewhere and the saves (which record what was collected where) would no longer fit.
pub fn placementMismatchMessage(allocator: Allocator, seed_name: []const u8, info: seedinfo.SeedInfo) error{OutOfMemory}![]const u8 {
    // (this release's placement version always parses: version.zig checks it at compile time, hence unreachable;
    // a seed's unreadable one counts as older)
    const made_by_newer = if (std.SemanticVersion.parse(info.placement_version)) |seed_placements|
        std.SemanticVersion.order(seed_placements, std.SemanticVersion.parse(version_mod.placement_version) catch unreachable) == .gt
    else |_|
        false;
    const reason = if (made_by_newer)
        "it was made by a newer version that places items differently"
    else
        "this version places items differently than the one that made it";
    return std.fmt.allocPrint(allocator,
        "{s} can't be rebuilt with {s}: {s} (seed made by {s}, placement version {s}; this version's placement version " ++
        "is {s}), so a rebuild would be a different seed.\n\nYour seed and its saves are safe and nothing was changed: keep " ++
        "playing it as it is. It just won't get the fixes and features of {s}; start a new seed for those.",
        .{ seed_name, version_mod.version, reason, info.release, info.placement_version, version_mod.placement_version, version_mod.version },
    );
}

/// What every build writes at the top of a mod folder. Everything else there (the stored per-seed saves in saves/)
/// is kept when a seed is made again into its own folder.
const generated_entries = [_][]const u8{ "romfs", "exefs", "settings.txt", "spoiler.txt", "spoiler.json", "checklist.xlsx", testplan.file_name_in_seed_folder };

/// Rebuilding a seed into its folder: the earlier build's files go first, so a file the new build no longer changes
/// doesn't stay behind. Only the entries a build writes are removed.
fn clearEarlierBuild(a: Allocator, fs: fsmod.Fs, mod_root: []const u8, name: []const u8, progress: *Progress) GenerateError!void {
    if (!fs.isDir(mod_root)) return;
    var removed_any = false;
    for (generated_entries) |entry| {
        const path = fsmod.join(a, &.{ mod_root, entry }) catch return error.OutOfMemory;
        if (fs.isDir(path)) {
            fs.deleteTree(path) catch |err| return progress.fail(error.GenerationFailed, "couldn't remove the earlier build's {s} ({s}); close the game and try again", .{ path, @errorName(err) });
            removed_any = true;
        } else if (fs.exists(path)) {
            fs.deleteFile(path) catch |err| return progress.fail(error.GenerationFailed, "couldn't remove the earlier build's {s} ({s}); close the game and try again", .{ path, @errorName(err) });
            removed_any = true;
        }
    }
    if (removed_any) progress.log("{s} already exists: its earlier mod files are replaced (its stored saves are kept)", .{name});
}

// ------------------------------------------------------------------------------------------------------- spoiler

const Pair = struct { location: []const u8, item: []const u8 };

fn lessPair(_: void, x: Pair, y: Pair) bool {
    switch (std.mem.order(u8, x.location, y.location)) {
        .lt => return true,
        .gt => return false,
        .eq => return std.mem.order(u8, x.item, y.item) == .lt,
    }
}

/// "name:" padded to `width` (Python's "%-28s").
fn padded(out: *std.ArrayList(u8), a: Allocator, text: []const u8, width: usize) error{OutOfMemory}!void {
    try out.appendSlice(a, text);
    var n = text.len;
    while (n < width) : (n += 1) try out.append(a, ' ');
}

fn valueText(a: Allocator, v: settings_mod.Value) error{OutOfMemory}![]const u8 {
    return switch (v) {
        .boolean => |b| if (b) "True" else "False",
        .int => |n| std.fmt.allocPrint(a, "{d}", .{n}),
        .choice => |c| c,
        .list => |l| blk: {
            // Python's repr of a list of strings
            var out: std.ArrayList(u8) = .empty;
            try out.append(a, '[');
            for (l, 0..) |s, i| {
                if (i > 0) try out.appendSlice(a, ", ");
                try out.print(a, "'{s}'", .{s});
            }
            try out.append(a, ']');
            break :blk out.items;
        },
    };
}

fn jsonValue(out: *std.ArrayList(u8), a: Allocator, v: settings_mod.Value) error{OutOfMemory}!void {
    switch (v) {
        .boolean => |b| try out.appendSlice(a, if (b) "true" else "false"),
        .int => |n| try out.print(a, "{d}", .{n}),
        .choice => |c| try out.print(a, "{f}", .{std.json.fmt(c, .{})}),
        .list => |l| try out.print(a, "{f}", .{std.json.fmt(l, .{})}),
    }
}

/// spoiler.txt and spoiler.json next to the mod: where every item is, the hints and the settings.
fn writeSpoiler(a: Allocator, world: *World, plan: *fill.Plan, filler: *fill.Filler, hint_list: []const hints.Hint, seed: []const u8, sstr: []const u8, mod_root: []const u8, fs: fsmod.Fs) patches.WriteError!void {
    fs.makePath(mod_root) catch return error.WriteFailed;
    const contents = filler.contents() catch return error.OutOfMemory;
    const locs = world.locations.items;

    // the playthrough: the progression items each sphere collects (placed ones only)
    var playthrough: std.ArrayList([]Pair) = .empty;
    const sweep = filler.sweep(&.{}, contents) catch return error.OutOfMemory;
    for (sweep.spheres.items) |sphere| {
        var prog: std.ArrayList(Pair) = .empty;
        for (sphere.items) |l| {
            const item = contents[l].?;
            if (logic.isProgression(item) and filler.placed[l] != null) prog.append(a, .{ .location = locs[l].name, .item = try world.itemNameById(a, item) }) catch return error.OutOfMemory;
        }
        if (prog.items.len > 0) {
            std.mem.sort(Pair, prog.items, {}, lessPair);
            playthrough.append(a, prog.items) catch return error.OutOfMemory;
        }
    }

    // every shuffled location, by region
    const Region = struct { name: []const u8, rows: std.ArrayList(Pair) };
    var regions: std.ArrayList(Region) = .empty;
    for (plan.shuffled.items) |i| {
        const loc = &locs[i];
        const region = if (loc.region) |r| world.regionName(r) else "Events";
        const item = contents[i].?;
        var item_text = try world.itemNameById(a, item);
        if (loc.kind == .shop) {
            if (item == loc.vanilla or world.items.isJunk(item)) {
                item_text = "(normal shop goods)";
            } else {
                item_text = std.fmt.allocPrint(a, "{s}  [{d} rupees]", .{ item_text, plan.shop_prices[i].? }) catch return error.OutOfMemory;
            }
        } else if (plan.scrub_prices[i]) |p| {
            item_text = std.fmt.allocPrint(a, "{s}  [{d} rupees]", .{ item_text, p }) catch return error.OutOfMemory;
        }
        var slot: ?*Region = null;
        for (regions.items) |*r| if (std.mem.eql(u8, r.name, region)) {
            slot = r;
        };
        if (slot == null) {
            regions.append(a, .{ .name = region, .rows = .empty }) catch return error.OutOfMemory;
            slot = &regions.items[regions.items.len - 1];
        }
        slot.?.rows.append(a, .{ .location = loc.name, .item = item_text }) catch return error.OutOfMemory;
    }
    std.mem.sort(Region, regions.items, {}, struct {
        fn less(_: void, x: Region, y: Region) bool {
            return std.mem.order(u8, x.name, y.name) == .lt;
        }
    }.less);

    var txt: std.ArrayList(u8) = .empty;
    try txt.appendSlice(a, settingsText(a, seed, sstr, plan.test_placements_text) catch return error.OutOfMemory);
    try txt.appendSlice(a, "\nSettings:\n");
    for (settings_mod.specs) |s| {
        try txt.appendSlice(a, "  ");
        try padded(&txt, a, std.fmt.allocPrint(a, "{s}:", .{s.label}) catch return error.OutOfMemory, 28);
        txt.print(a, " {s}\n", .{try valueText(a, (plan.chosen_settings orelse plan.st).get(s.key))}) catch return error.OutOfMemory;
    }
    // what the seed chose for Starting Age: Random and Barren Dungeons
    try txt.appendSlice(a, "\nThis seed:\n");
    txt.print(a, "  Starting age:               {s}\n", .{if (plan.options.start_adult) "Adult" else "Child"}) catch return error.OutOfMemory;
    for (plan.random_rolls) |roll| {
        try txt.appendSlice(a, "  ");
        try padded(&txt, a, std.fmt.allocPrint(a, "{s}:", .{roll.label}) catch return error.OutOfMemory, 28);
        txt.print(a, " {s}\n", .{roll.value}) catch return error.OutOfMemory;
    }
    if (plan.barren_dungeons.len > 0) {
        const names = a.alloc([]const u8, plan.barren_dungeons.len) catch return error.OutOfMemory;
        for (plan.barren_dungeons, 0..) |folder, k| names[k] = world.regionName(folder);
        txt.print(a, "  Barren dungeons:            {s}\n", .{std.mem.join(a, ", ", names) catch return error.OutOfMemory}) catch return error.OutOfMemory;
    }
    if (plan.start_inventory.len > 0) {
        const names = a.alloc([]const u8, plan.start_inventory.len) catch return error.OutOfMemory;
        for (plan.start_inventory, 0..) |item, k| names[k] = world.itemNameById(a, item) catch return error.OutOfMemory;
        txt.print(a, "  Starting inventory:         {s}\n", .{std.mem.join(a, ", ", names) catch return error.OutOfMemory}) catch return error.OutOfMemory;
    }
    try txt.appendSlice(a, "\nPlaythrough:\n");
    for (playthrough.items, 1..) |sphere, n| {
        txt.print(a, "  Sphere {d}\n", .{n}) catch return error.OutOfMemory;
        for (sphere) |p| {
            try txt.appendSlice(a, "    ");
            try padded(&txt, a, p.location, 55);
            txt.print(a, " {s}\n", .{p.item}) catch return error.OutOfMemory;
        }
    }
    if (hint_list.len > 0) {
        txt.print(a, "\nHints ({s}):\n", .{plan.st.choice(.hint_distribution)}) catch return error.OutOfMemory;
        for (hint_list) |h| {
            try txt.appendSlice(a, "  ");
            try padded(&txt, a, h.label, 34);
            try txt.append(a, ' ');
            try padded(&txt, a, @tagName(h.kind), 9);
            txt.print(a, " {s}\n", .{try hints.text(a, world, h, false)}) catch return error.OutOfMemory;
        }
    }
    try txt.appendSlice(a, "\nLocations:\n");
    for (regions.items) |r| {
        txt.print(a, "  {s}\n", .{r.name}) catch return error.OutOfMemory;
        std.mem.sort(Pair, r.rows.items, {}, lessPair);
        for (r.rows.items) |p| {
            try txt.appendSlice(a, "    ");
            try padded(&txt, a, p.location, 55);
            txt.print(a, " {s}\n", .{p.item}) catch return error.OutOfMemory;
        }
    }
    fs.writeAll(fsmod.join(a, &.{ mod_root, "spoiler.txt" }) catch return error.OutOfMemory, txt.items) catch return error.WriteFailed;

    // spoiler.json
    var js: std.ArrayList(u8) = .empty;
    js.print(a, "{{\n \"version\": {f},\n \"placement_version\": {f},\n \"seed\": {f},\n \"settings_string\": {f},\n \"settings\": {{", .{
        std.json.fmt(version_mod.version, .{}), std.json.fmt(version_mod.placement_version, .{}), std.json.fmt(seed, .{}), std.json.fmt(sstr, .{}),
    }) catch return error.OutOfMemory;
    for (settings_mod.specs, 0..) |s, i| {
        js.print(a, "{s}\n  {f}: ", .{ if (i > 0) "," else "", std.json.fmt(@tagName(s.key), .{}) }) catch return error.OutOfMemory;
        try jsonValue(&js, a, plan.st.get(s.key));
    }
    try js.appendSlice(a, "\n },\n \"playthrough\": [");
    for (playthrough.items, 0..) |sphere, i| {
        js.print(a, "{s}\n  [", .{if (i > 0) "," else ""}) catch return error.OutOfMemory;
        for (sphere, 0..) |p, k| {
            js.print(a, "{s}\n   [{f}, {f}]", .{ if (k > 0) "," else "", std.json.fmt(p.location, .{}), std.json.fmt(p.item, .{}) }) catch return error.OutOfMemory;
        }
        try js.appendSlice(a, "\n  ]");
    }
    try js.appendSlice(a, "\n ],\n \"hints\": {");
    for (hint_list, 0..) |h, i| {
        js.print(a, "{s}\n  {f}: {{\"kind\": {f}, \"text\": {f}}}", .{
            if (i > 0) "," else "", std.json.fmt(h.label, .{}), std.json.fmt(@tagName(h.kind), .{}), std.json.fmt(try hints.text(a, world, h, false), .{}),
        }) catch return error.OutOfMemory;
    }
    try js.appendSlice(a, "\n },\n \"locations\": {");
    // every location that holds something, by name
    var all: std.ArrayList(Pair) = .empty;
    for (contents, 0..) |c, i| {
        const item = c orelse continue;
        all.append(a, .{ .location = locs[i].name, .item = try world.itemNameById(a, item) }) catch return error.OutOfMemory;
    }
    std.mem.sort(Pair, all.items, {}, lessPair);
    for (all.items, 0..) |p, i| {
        js.print(a, "{s}\n  {f}: {f}", .{ if (i > 0) "," else "", std.json.fmt(p.location, .{}), std.json.fmt(p.item, .{}) }) catch return error.OutOfMemory;
    }
    try js.appendSlice(a, "\n }\n}");
    fs.writeAll(fsmod.join(a, &.{ mod_root, "spoiler.json" }) catch return error.OutOfMemory, js.items) catch return error.WriteFailed;
}

test "a seed with other placements is refused with a message that its saves are safe" {
    const allocator = std.testing.allocator;
    const older_seed = seedinfo.SeedInfo{ .release = "0.7.5", .placement_version = "0.7.3", .seed = "OLDSEED", .settings_string = "eNqX" };
    const older_message = try placementMismatchMessage(allocator, "GogglesOfTruth_OLDSEED", older_seed);
    defer allocator.free(older_message);
    try std.testing.expect(std.mem.indexOf(u8, older_message, "this version places items differently") != null);
    try std.testing.expect(std.mem.indexOf(u8, older_message, "saves are safe") != null);
    try std.testing.expect(std.mem.indexOf(u8, older_message, "placement version 0.7.3") != null);

    const newer_seed = seedinfo.SeedInfo{ .release = "99.0.0", .placement_version = "99.0.0", .seed = "NEWSEED", .settings_string = "eNqX" };
    const newer_message = try placementMismatchMessage(allocator, "GogglesOfTruth_NEWSEED", newer_seed);
    defer allocator.free(newer_message);
    try std.testing.expect(std.mem.indexOf(u8, newer_message, "made by a newer version") != null);
}
