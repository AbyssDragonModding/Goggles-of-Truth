//! goggles_cli: the randomizer without a window.
//!
//!   goggles_cli generate --game <.nup or romfs> --out <folder> [--seed S] [--name N] [--settings STRING]
//!                        [--from-user-settings] [--exefs <folder>] [--dump-placement <file.json>]
//!   goggles_cli check <.nup, romfs or exefs>          game version check (prints the exefs/main SHA-256)
//!   goggles_cli scan <.nup or romfs>                  scan the game and list a sample of the locations
//!   goggles_cli vanilla-test <.nup or romfs>          is the vanilla placement beatable under the logic?
//!   goggles_cli dump-world <game> <out.jsonl>         every location as JSON lines (for comparing builds)
//!   goggles_cli dump-plan <game> <settings> <out.txt> the shuffled locations and the item pool
//!   goggles_cli selftest <game>                       read and write back every event flow (byte check)
//!
//! Without --settings, generate uses user_settings.toml next to the program with --from-user-settings, else the
//! defaults.

const std = @import("std");
const engine = @import("engine");
const Allocator = std.mem.Allocator;

const usage =
    \\usage:
    \\  goggles_cli generate --game <.nup or romfs> --out <folder> [--seed S] [--name N] [--settings STRING]
    \\                       [--from-user-settings] [--exefs <folder>]
    \\  goggles_cli check <.nup, romfs or exefs>
    \\  goggles_cli scan <.nup or romfs>
    \\  goggles_cli vanilla-test <.nup or romfs>
    \\  goggles_cli dump-world <game> <out.jsonl>
    \\  goggles_cli dump-plan <game> <settings string> <out.txt>
    \\  goggles_cli selftest <game>
    \\
;

const CliError = error{ BadArguments, Failed };

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const fs = engine.fs.Fs.init(io);
    const app_dir = std.process.executableDirPathAlloc(io, init.arena.allocator()) catch ".";
    const env = engine.Env{ .environ = init.environ_map, .fs = fs, .app_dir = app_dir };

    if (args.len < 2) {
        std.debug.print("{s}", .{usage});
        return 2;
    }
    const command = args[1];
    const rest = args[2..];
    const result = if (std.mem.eql(u8, command, "generate"))
        cmdGenerate(gpa, &env, rest)
    else if (std.mem.eql(u8, command, "check"))
        cmdCheck(gpa, fs, rest)
    else if (std.mem.eql(u8, command, "scan"))
        cmdScan(gpa, fs, rest)
    else if (std.mem.eql(u8, command, "vanilla-test"))
        cmdVanillaTest(gpa, fs, rest)
    else if (std.mem.eql(u8, command, "dump-world"))
        cmdDumpWorld(gpa, fs, rest)
    else if (std.mem.eql(u8, command, "dump-plan"))
        cmdDumpPlan(gpa, fs, rest)
    else if (std.mem.eql(u8, command, "selftest"))
        cmdSelftest(gpa, fs, rest)
    else
        error.BadArguments;
    result catch |err| switch (err) {
        error.BadArguments => {
            std.debug.print("{s}", .{usage});
            return 2;
        },
        else => {
            std.debug.print("error: {s}\n", .{@errorName(err)});
            return 1;
        },
    };
    return 0;
}

fn optionValue(args: []const [:0]const u8, i: *usize) CliError![]const u8 {
    i.* += 1;
    if (i.* >= args.len) return error.BadArguments;
    return args[i.*];
}

fn cmdGenerate(gpa: Allocator, env: *const engine.Env, args: []const [:0]const u8) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var game: []const u8 = "";
    var out: []const u8 = "";
    var seed: ?[]const u8 = null;
    var name: ?[]const u8 = null;
    var settings_string: ?[]const u8 = null;
    var exefs: []const u8 = "";
    var from_user = false;
    var dump_placement: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--game")) game = try optionValue(args, &i)
        else if (std.mem.eql(u8, arg, "--out")) out = try optionValue(args, &i)
        else if (std.mem.eql(u8, arg, "--seed")) seed = try optionValue(args, &i)
        else if (std.mem.eql(u8, arg, "--name")) name = try optionValue(args, &i)
        else if (std.mem.eql(u8, arg, "--settings")) settings_string = try optionValue(args, &i)
        else if (std.mem.eql(u8, arg, "--exefs")) exefs = try optionValue(args, &i)
        else if (std.mem.eql(u8, arg, "--from-user-settings")) from_user = true
        else if (std.mem.eql(u8, arg, "--dump-placement")) dump_placement = try optionValue(args, &i)
        else return error.BadArguments;
    }
    if (game.len == 0 or out.len == 0) return error.BadArguments;

    var st = engine.settings.Settings.defaults();
    if (settings_string) |s| {
        st = engine.settings.fromString(a, s) catch {
            std.debug.print("error: invalid settings string\n", .{});
            return error.Failed;
        };
        // the settings string leaves out where things are written: keep the file's choice
        if (from_user) st.set(.per_seed_saves, (try engine.usersettings.load(a, env)).settings.get(.per_seed_saves));
    } else if (from_user) {
        const loaded = try engine.usersettings.load(a, env);
        for (loaded.messages) |m| std.debug.print("{s}\n", .{m});
        st = loaded.settings;
    }

    var progress = engine.Progress.stderrPrinter();
    const result = engine.generator.generate(gpa, a, env, .{
        .game_path = game,
        .out_dir = out,
        .settings = st,
        .seed = seed,
        .mod_name = name,
        .exefs = exefs,
    }, null, &progress) catch |err| {
        std.debug.print("Generation failed: {s}\n", .{if (progress.failureMessage().len > 0) progress.failureMessage() else @errorName(err)});
        return error.Failed;
    };
    std.debug.print("Seed {s} written to {s}\nSettings string: {s}\n", .{ result.seed, result.mod_root, result.settings_string });
    if (dump_placement) |file| {
        var json: std.ArrayList(u8) = .empty;
        try json.print(a, "{f}", .{std.json.fmt(.{ .placement = result.placement, .hints = result.hints }, .{})});
        try env.fs.writeAll(file, json.items);
    }
}

fn cmdCheck(gpa: Allocator, fs: engine.fs.Fs, args: []const [:0]const u8) !void {
    if (args.len != 1) return error.BadArguments;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    // an exefs folder (holding main) is checked as it is; anything else as a game
    const main_file = try std.fs.path.join(a, &.{ args[0], "main" });
    const res = if (fs.isFile(main_file))
        try engine.gamecheck.check(a, fs, args[0], "")
    else
        try engine.gamecheck.check(a, fs, "", args[0]);
    std.debug.print("{s}\n", .{res.message});
    if (res.sha256.len > 0) std.debug.print("sha256: {s}\n", .{res.sha256});
    if (!res.ok) return error.Failed;
}

fn openWorld(gpa: Allocator, fs: engine.fs.Fs, game: []const u8, quiet: bool) !*engine.world.World {
    var progress = if (quiet) engine.Progress.silent() else engine.Progress.stderrPrinter();
    return engine.world.World.init(gpa, fs, game, &progress) catch |err| {
        std.debug.print("error: {s}\n", .{if (progress.failureMessage().len > 0) progress.failureMessage() else @errorName(err)});
        return error.Failed;
    };
}

fn cmdScan(gpa: Allocator, fs: engine.fs.Fs, args: []const [:0]const u8) !void {
    if (args.len != 1) return error.BadArguments;
    const w = try openWorld(gpa, fs, args[0], false);
    defer w.deinit();
    var counts: [7]usize = @splat(0);
    for (w.locations.items) |l| counts[@intFromEnum(l.kind)] += 1;
    std.debug.print("{d} locations ({d} items known):\n", .{ w.locations.items.len, w.items.count() });
    for (std.meta.tags(engine.world.Kind)) |k| std.debug.print("  {s}: {d}\n", .{ @tagName(k), counts[@intFromEnum(k)] });
}

fn cmdVanillaTest(gpa: Allocator, fs: engine.fs.Fs, args: []const [:0]const u8) !void {
    if (args.len != 1) return error.BadArguments;
    const w = try openWorld(gpa, fs, args[0], true);
    defer w.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const st = engine.settings.Settings.defaults();
    var progress = engine.Progress.stderrPrinter();
    const plan = try engine.fill.Plan.init(a, w, &st, "test");
    var filler = try engine.fill.Filler.init(a, plan, 0, &progress);
    const vanilla = try a.alloc(?engine.logic.ItemId, w.locations.items.len);
    for (w.locations.items, 0..) |l, i| vanilla[i] = l.vanilla;
    var result = try filler.sweep(&.{}, vanilla);
    var got: usize = 0;
    for (result.got) |g| if (g) {
        got += 1;
    };
    std.debug.print("vanilla beatable: {} spheres {d} reached {d} / {d}\n", .{ result.state.is(.win), result.spheres.items.len, got, vanilla.len });
    for (std.meta.tags(engine.logic.Derived)) |d| std.debug.print("  {s:<14} {}\n", .{ @tagName(d), result.state.is(d) });
}

fn cmdDumpWorld(gpa: Allocator, fs: engine.fs.Fs, args: []const [:0]const u8) !void {
    if (args.len != 2) return error.BadArguments;
    const w = try openWorld(gpa, fs, args[0], true);
    defer w.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.ArrayList(u8) = .empty;
    for (w.locations.items) |l| {
        const Ref = struct { []const u8, u64 };
        const ERef = struct { []const u8, usize };
        const PRef = struct { []const u8, usize, i64 };
        var srefs: std.ArrayList(Ref) = .empty;
        for (l.stage_refs) |r| try srefs.append(a, .{ r.rel, r.hash });
        var erefs: std.ArrayList(ERef) = .empty;
        for (l.event_refs) |r| try erefs.append(a, .{ r.rel, r.offset });
        var prefs: std.ArrayList(PRef) = .empty;
        for (l.price_refs) |r| try prefs.append(a, .{ r.rel, r.offset, r.price });
        var ages: std.ArrayList([]const u8) = .empty;
        if (l.ages.adult) try ages.append(a, "adult");
        if (l.ages.child) try ages.append(a, "child");
        const rec = .{
            .id = l.id,                       .name = l.name,
            .region = l.region,               .dungeon = l.dungeon,
            .kind = @tagName(l.kind),         .category = @tagName(l.category),
            .ages = ages.items,               .vanilla = w.items.name(l.vanilla),
            .vanilla_actor = l.vanilla_actor, .stage_refs = srefs.items,
            .event_refs = erefs.items,        .presence = l.presence,
            .get_event = l.get_event,         .conditional = l.conditional,
            .room = l.room,                   .rule_key = if (l.rule_key) |k| @tagName(k) else null,
            .upgrade_ok = l.upgrade_ok,       .price_refs = prefs.items,
            .shop = l.shop,
        };
        try out.print(a, "{f}\n", .{std.json.fmt(rec, .{})});
    }
    try fs.writeAll(args[1], out.items);
}

fn cmdDumpPlan(gpa: Allocator, fs: engine.fs.Fs, args: []const [:0]const u8) !void {
    if (args.len != 3) return error.BadArguments;
    const w = try openWorld(gpa, fs, args[0], true);
    defer w.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const st = try engine.settings.fromString(a, args[1]);
    const plan = try engine.fill.Plan.init(a, w, &st, "test");
    var out: std.ArrayList(u8) = .empty;
    for (plan.shuffled.items) |i| try out.print(a, "S {s}\n", .{w.locations.items[i].id});
    for (plan.pool.items) |p| try out.print(a, "P {s}\n", .{w.items.name(p)});
    for (plan.fixed, 0..) |f, i| if (f) |x| try out.print(a, "F {s} {s}\n", .{ w.locations.items[i].id, w.items.name(x) });
    for (plan.excluded, 0..) |e, i| if (e) try out.print(a, "X {s}\n", .{w.locations.items[i].id});
    for (plan.scrub_prices, 0..) |p, i| if (p) |v| try out.print(a, "$ {s} {d}\n", .{ w.locations.items[i].id, v });
    try fs.writeAll(args[2], out.items);
}

fn cmdSelftest(gpa: Allocator, fs: engine.fs.Fs, args: []const [:0]const u8) !void {
    if (args.len != 1) return error.BadArguments;
    const w = try openWorld(gpa, fs, args[0], true);
    defer w.deinit();
    var keep = std.heap.ArenaAllocator.init(gpa);
    defer keep.deinit();
    var tmp = std.heap.ArenaAllocator.init(gpa);
    defer tmp.deinit();
    const names = try w.files.listDir(keep.allocator(), "Event/EventFlow");
    var same: usize = 0;
    var different: usize = 0;
    for (names) |n| {
        if (!std.mem.endsWith(u8, n, ".bfevfl.zs")) continue;
        _ = tmp.reset(.retain_capacity);
        const a = tmp.allocator();
        const rel = try std.fmt.allocPrint(a, "Event/EventFlow/{s}", .{n});
        const d = try w.readZs(a, rel);
        const doc = engine.evfl.read(a, d.data) catch {
            different += 1;
            std.debug.print("  can't read {s}\n", .{n});
            continue;
        };
        const back = try engine.evfl.write(a, &doc);
        if (std.mem.eql(u8, back, d.data)) same += 1 else {
            different += 1;
            std.debug.print("  writes back differently: {s}\n", .{n});
        }
    }
    std.debug.print("event flows: {d} write back byte-identical, {d} not\n", .{ same, different });
    if (different > 0) return error.Failed;
}
