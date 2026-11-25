//! The randomizer engine: game file formats, the world scan, the logic and the generator.
//! It has no window code, so the command-line tool and the tests use it on every target.

// ---- core helpers
pub const bytes = @import("core/bytes.zig");
pub const hash = @import("core/hash.zig");
pub const fs = @import("core/fs.zig");
pub const rng = @import("core/rng.zig");
pub const threads = @import("core/threads.zig");
pub const host = @import("platform/host.zig");
pub const Progress = @import("core/Progress.zig");
pub const version = @import("version.zig");
pub const seedinfo = @import("core/seedinfo.zig");

// ---- file formats
pub const zstd = @import("formats/zstd.zig");
pub const sarc = @import("formats/sarc.zig");
pub const byml = @import("formats/byml.zig");
pub const evfl = @import("formats/evfl.zig");
pub const evfl_view = @import("formats/evfl_view.zig");
pub const restbl = @import("formats/restbl.zig");
pub const msbt = @import("formats/msbt.zig");
pub const ainb = @import("formats/ainb.zig");
pub const nup = @import("formats/nup.zig");
pub const xlsx = @import("formats/xlsx.zig");
pub const toml = @import("formats/toml.zig");

// ---- the game
pub const gamefiles = @import("game/gamefiles.zig");
pub const gamecheck = @import("game/gamecheck.zig");
pub const world = @import("game/world.zig");

// ---- settings and logic
pub const settings = @import("settings/settings.zig");
pub const usersettings = @import("settings/usersettings.zig");
pub const custompresets = @import("settings/custompresets.zig");
pub const logic = @import("logic/logic.zig");
pub const progressive = @import("logic/progressive.zig");

// ---- the generator
pub const patchset = @import("generator/patchset.zig");
pub const fill = @import("generator/fill.zig");
pub const generator = @import("generator/generator.zig");
pub const filecache = @import("generator/filecache.zig");
pub const compressor = @import("generator/compressor.zig");

// ---- where the seeds go
pub const Env = @import("platform/Env.zig");
pub const longshot = @import("platform/longshot.zig");
pub const saves = @import("platform/saves.zig");
pub const launcher = @import("platform/launcher.zig");

test {
    _ = bytes;
    _ = threads;
    _ = seedinfo;
    _ = host;
    _ = hash;
    _ = fs;
    _ = zstd;
    _ = sarc;
    _ = byml;
    _ = evfl;
    _ = evfl_view;
    _ = restbl;
    _ = msbt;
    _ = ainb;
    _ = nup;
    _ = xlsx;
    _ = toml;
    _ = gamefiles;
    _ = gamecheck;
    _ = world;
    _ = settings;
    _ = usersettings;
    _ = custompresets;
    _ = logic;
    _ = progressive;
    _ = @import("generator/progressive_flows.zig");
    _ = @import("generator/ocarina_handover.zig");
    _ = generator;
    _ = filecache;
    _ = compressor;
    _ = longshot;
    _ = saves;
    _ = launcher;
}
