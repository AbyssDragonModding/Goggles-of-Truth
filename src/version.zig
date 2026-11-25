//! The randomizer's name and versions.
//!
//! `version` is the release (shown in the window, settings.txt, the spoiler log and the checklist).
//!
//! `placement_version` is what goes into every seed's random stream instead (with the seed number and the settings
//! string): the same three always place every item, price, hint and starting item the same way. It only changes when
//! a release changes where items go for the same seed and settings string: the fill, the logic, the item pool, the
//! hints, the settings string's format, or anything else that reads the seed's random stream. A release that only
//! fixes how the mod is patched (a cutscene, a softlock, a text) keeps it, so a seed made with an earlier release can
//! be made again with the fix (the window's "Rebuild Seed") and its saves still fit.
//!
//! Keep it equal to the release that last changed placements. To check a change, make a few seeds with
//! `goggles_cli generate ... --dump-placement <file.json>` before and after it: the files must be the same, or
//! `placement_version` must become the new release.

pub const version = "0.8.0";
/// The release whose placements this one makes (see above).
pub const placement_version = "0.8.0";
/// an OoT (2026 remake) randomizer mod
pub const name = "Goggles of Truth Randomizer";

comptime {
    // why: a placement version is always a release that already exists, so it can't be newer than this one
    if (std.SemanticVersion.order(
        std.SemanticVersion.parse(placement_version) catch @compileError("placement_version must be Major.Minor.Patch"),
        std.SemanticVersion.parse(version) catch @compileError("version must be Major.Minor.Patch"),
    ) == .gt) @compileError("placement_version is newer than version");
}

const std = @import("std");
