//! Glitchless logic for the remake, modelled on the classic randomizer's region rules.
//!
//! It is deliberately conservative: every location inside a dungeon requires all the items needed to *finish* that
//! dungeon, and overworld grottos/hidden spots assume explosives etc. That keeps seeds beatable even where the
//! remake's exact layout is unknown, at the cost of making some items appear a little later than strictly needed.
//!
//! Items are canonical keys (see world.canon), e.g. "Hookshot", "Melody_SariaSong". The ones the logic reads are
//! the `Item` enum; their ids are the enum values (the world's item table starts with them in this order).

const std = @import("std");
const settings = @import("../settings/settings.zig");
const Allocator = std.mem.Allocator;

/// Index into the world's item table.
pub const ItemId = u16;

/// The items the logic looks at, named exactly as the game's canonical item keys. Everything except the
/// medallions is progression (`isProgression`); anything not listed here is never required (junk for the fill).
pub const Item = enum(ItemId) {
    Sword_Kokiri,
    Range_SlingShot,
    Boomerang,
    BombBag_Small,
    BombBag_Medium,
    BombBag_Large,
    Hookshot,
    Longshot,
    Range_Bow,
    Hammer,
    HeavyBoot,
    HoverBoot,
    Gauntlet_Goron,
    Gauntlet_Silver,
    Gauntlet_Gold,
    Scale_Silver,
    Scale_Gold,
    Arrow_Fire,
    Arrow_Light,
    DinFire,
    GlassTruth,
    Shield_Mirror,
    Bottle,
    Bottle_Milk,
    Bottle_Letter,
    WeirdEgg,
    ZeldaLetter,
    Token_Gerudo,
    Wallet_Medium,
    Wallet_Large,
    Token_Gold,
    Melody_ZeldaLullaby,
    Melody_EponaSong,
    Melody_SariaSong,
    Melody_SunSong,
    Melody_TimeSong,
    Melody_StormSong,
    Melody_ForestMinuet,
    Melody_FireBolero,
    Melody_WaterSerenade,
    Melody_ShadowNocturne,
    Melody_SpiritRequiem,
    Melody_LightPrelude,
    Ocarina_Fairy,
    Ocarina_Time,
    // Door of Time: Closed holds them before going adult
    Stone_Forest,
    Stone_Fire,
    Stone_Water,
    // not progression: only the rainbow bridge setting reads them
    Medal_Forest,
    Medal_Fire,
    Medal_Water,
    Medal_Shadow,
    Medal_Spirit,
    Medal_Light,

    pub fn id(self: Item) ItemId {
        return @intFromEnum(self);
    }
};

pub const item_count = @typeInfo(Item).@"enum".field_names.len;
const first_medallion: ItemId = @intFromEnum(Item.Medal_Forest);

/// True for the items the logic needs (an id outside the enum is never progression).
pub fn isProgression(item: ItemId) bool {
    return item < first_medallion;
}

pub const medallions = [_]Item{ .Medal_Forest, .Medal_Fire, .Medal_Water, .Medal_Shadow, .Medal_Spirit, .Medal_Light };
pub const child_stones = [_]Item{ .Stone_Forest, .Stone_Fire, .Stone_Water };

/// Two-tier items: the higher tier may only be placed where the lower tier is required, so the player can never
/// pick the stronger version up first. Returns the lower tier of `item`, or null.
pub fn lowerTier(item: ItemId) ?ItemId {
    const pairs = [_][2]Item{
        .{ .Hookshot, .Longshot },          .{ .Gauntlet_Silver, .Gauntlet_Gold }, .{ .Scale_Silver, .Scale_Gold },
        .{ .BombBag_Small, .BombBag_Medium }, .{ .BombBag_Medium, .BombBag_Large }, .{ .Wallet_Medium, .Wallet_Large },
    };
    for (pairs) |p| {
        if (p[1].id() == item) return p[0].id();
    }
    return null;
}

/// Regions a child can reach before leaving a closed Kokiri Forest (the Deku Tree itself excluded).
pub const forest_regions = [_][]const u8{ "KokiriForest", "LostWood", "SacredForestMeadow" };

pub fn isForestRegion(region: []const u8) bool {
    for (forest_regions) |r| if (std.mem.eql(u8, r, region)) return true;
    return false;
}

/// Generation options the rules depend on (set from the seed's settings before filling).
pub const Options = struct {
    bag_bombs_no_bracelet: bool = true,
    open_forest: OpenForest = .closed,
    open_zora: bool = false,
    open_door: bool = false,
    saria_song_ocarina: bool = true,
    dodongo_bag_bombs: bool = false,
    shuffle_ocarinas: bool = false,
    open_dmt: bool = false,
    skip_child_zelda: bool = false,
    skip_ganon_trials: bool = false,
    rainbow_bridge: Bridge = .vanilla,
    bridge_medallions: i64 = 6,
    bridge_tokens: i64 = 100,
    skip_epona_race: bool = false,

    pub const OpenForest = enum { closed, closed_deku, open };
    pub const Bridge = enum { vanilla, medallions, stones, tokens };

    pub fn fromSettings(st: *const settings.Settings) Options {
        return Options{
            .bag_bombs_no_bracelet = st.flag(.bag_bombs_no_bracelet),
            .open_forest = std.meta.stringToEnum(OpenForest, st.choice(.open_forest)) orelse .closed,
            .open_zora = st.is(.open_zora, "open"),
            .open_door = st.is(.open_door, "open"),
            .saria_song_ocarina = st.flag(.saria_song_ocarina),
            .dodongo_bag_bombs = st.flag(.dodongo_bag_bombs),
            .shuffle_ocarinas = st.flag(.shuffle_ocarinas),
            .open_dmt = st.flag(.open_dmt),
            .skip_child_zelda = st.flag(.skip_child_zelda),
            .skip_ganon_trials = st.flag(.skip_ganon_trials),
            .rainbow_bridge = std.meta.stringToEnum(Bridge, st.choice(.rainbow_bridge)) orelse .vanilla,
            .bridge_medallions = st.int(.bridge_medallions),
            .bridge_tokens = st.int(.bridge_tokens),
            .skip_epona_race = st.flag(.skip_epona_race),
        };
    }
};

/// The derived predicates, cached per State (Python's @rule functions).
pub const Derived = enum {
    deku_done,
    child_out,
    adult,
    epona,
    hf_child,
    zelda_met,
    dmt_child,
    dmc_child,
    dmc_adult,
    zr_child,
    zd_child,
    zd_adult,
    zf_child,
    zf_adult,
    gv_adult,
    gf_adult,
    card,
    wasteland,
    colossus_child,
    colossus_adult,
    goron_tunic,
    zora_tunic,
    dodongo_done,
    jabu_done,
    botw_done,
    forest_done,
    fire_done,
    water_done,
    shadow_done,
    spirit_done,
    ice_done,
    gtg_done,
    bridge,
    ganon_done,
    ganon_tower,
    win,
};
const derived_count = @typeInfo(Derived).@"enum".field_names.len;

/// The items the player has, with the derived predicates cached.
pub const State = struct {
    counts: []u16,
    options: *const Options,
    known: [derived_count]bool = @splat(false),
    value: [derived_count]bool = @splat(false),

    const Self = @This();

    /// An empty state for an item table of `item_total` items.
    pub fn init(allocator: Allocator, item_total: usize, options: *const Options) error{OutOfMemory}!Self {
        const counts = try allocator.alloc(u16, item_total);
        @memset(counts, 0);
        return Self{ .counts = counts, .options = options };
    }

    pub fn deinit(self: *Self, allocator: Allocator) void {
        allocator.free(self.counts);
    }

    pub fn clone(self: *const Self, allocator: Allocator) error{OutOfMemory}!Self {
        return Self{ .counts = try allocator.dupe(u16, self.counts), .options = self.options };
    }

    /// Adds one item; the cached predicates are cleared.
    pub fn add(self: *Self, item: ItemId) void {
        if (item < self.counts.len) self.counts[item] += 1;
        self.clearCache();
    }

    /// Adds one item without clearing the cache (a sweep adds a whole sphere, then clears once).
    pub fn addKeepingCache(self: *Self, item: ItemId) void {
        if (item < self.counts.len) self.counts[item] += 1;
    }

    pub fn clearCache(self: *Self) void {
        self.known = @splat(false);
    }

    pub fn count(self: *const Self, item: ItemId) u16 {
        return if (item < self.counts.len) self.counts[item] else 0;
    }

    pub fn has(self: *const Self, item: Item) bool {
        return self.count(item.id()) >= 1;
    }

    pub fn hasN(self: *const Self, item: Item, n: i64) bool {
        return @as(i64, self.count(item.id())) >= n;
    }

    /// A derived predicate, computed once per state (the cache is cleared when items are added).
    pub fn is(self: *Self, d: Derived) bool {
        const i = @intFromEnum(d);
        if (self.known[i]) return self.value[i];
        // guards against accidental recursion: a rule that reaches itself reads false
        self.known[i] = true;
        self.value[i] = false;
        const result = evalDerived(self, d);
        self.value[i] = result;
        return result;
    }
};

// ------------------------------------------------------------------------------------------------ primitives

pub fn bombs(s: *State) bool {
    const bag = s.has(.BombBag_Small) or s.has(.BombBag_Medium) or s.has(.BombBag_Large);
    // Bag bombs are lifted objects in the remake: without the bomb patch they need the Goron Bracelet.
    return bag and (s.options.bag_bombs_no_bracelet or s.has(.Gauntlet_Goron) or str2(s));
}
pub fn hookshot(s: *State) bool {
    return s.has(.Hookshot) or s.has(.Longshot);
}
pub fn longshot(s: *State) bool {
    return s.has(.Longshot);
}
pub fn bow(s: *State) bool {
    return s.has(.Range_Bow);
}
pub fn lens(s: *State) bool {
    return s.has(.GlassTruth);
}
pub fn dins(s: *State) bool {
    return s.has(.DinFire);
}
pub fn scale(s: *State) bool {
    return s.has(.Scale_Silver) or s.has(.Scale_Gold);
}
pub fn str2(s: *State) bool {
    return s.has(.Gauntlet_Silver) or s.has(.Gauntlet_Gold);
}
pub fn str3(s: *State) bool {
    return s.has(.Gauntlet_Gold);
}
pub fn bottle(s: *State) bool {
    // Ruto's Letter becomes an empty bottle only when it is delivered (impossible if King Zora starts moved)
    const letter = s.has(.Bottle_Letter) and s.is(.zd_child) and !s.options.open_zora;
    return s.has(.Bottle) or s.has(.Bottle_Milk) or letter;
}
pub fn ocarina(s: *State) bool {
    // vanilla: Saria hands over the Fairy Ocarina when you leave the forest after the Deku Tree
    if (s.has(.Ocarina_Fairy) or s.has(.Ocarina_Time)) return true;
    return !s.options.shuffle_ocarinas and s.is(.deku_done);
}
pub fn song(s: *State, melody: Item) bool {
    return s.has(melody) and ocarina(s);
}
/// The remake never checks which Spiritual Stones / Medallions you hold: the Door of Time quest counts the three
/// child dungeon quests (Get_StoneOf*_IsCompleted_Exp), and the later story follows the sage quests. So the logic
/// follows the dungeons too, which keeps shuffled rewards honest.
pub fn stones(s: *State) bool {
    return s.is(.deku_done) and s.is(.dodongo_done) and s.is(.jabu_done);
}
/// The Ocarina of Time scene at the castle moat (DoorOfTime Step03 -> Step05). Zelda teaches the Song of Time with
/// an ocarina in hand.
pub fn moat(s: *State) bool {
    return s.is(.hf_child) and stones(s) and s.is(.zelda_met) and ocarina(s);
}
pub fn tokens(s: *State, n: i64) bool {
    return s.hasN(.Token_Gold, n);
}
/// The Happy Mask Shop's masks read Npc_Hylia_Soldier_003_GateOpen: Zelda's Letter shown at the gate, or Open DMT.
pub fn maskShop(s: *State) bool {
    return s.options.open_dmt or s.has(.ZeldaLetter);
}
/// 2 progressive wallets, or the Giant's Wallet itself.
pub fn giantWallet(s: *State) bool {
    return s.has(.Wallet_Large) or s.hasN(.Wallet_Medium, 2);
}

// --------------------------------------------------------------------------------------- the derived rules

fn evalDerived(s: *State, d: Derived) bool {
    const o = s.options;
    return switch (d) {
        // the shield is bought in the forest shop
        .deku_done => s.has(.Sword_Kokiri) and s.has(.Range_SlingShot),
        // the exit blocker stays until Gohma
        .child_out => o.open_forest != .closed or s.is(.deku_done),
        .adult => blk: {
            // Door of Time starts open
            if (o.open_door) break :blk s.is(.hf_child);
            // The altar reacts to the Song of Time once the moat scene is done; nothing checks which ocarina plays
            // it. The game doesn't read the stone items; the logic still puts all three within child reach so they
            // are in hand before the door, as in the original.
            for (child_stones) |stone| if (!s.has(stone)) break :blk false;
            break :blk moat(s) and song(s, .Melody_TimeSong);
        },
        // Ingo's race needs the Get_Epona quest past ReadyForGetEponaSong, which only child Malon's song scene does;
        // then Epona's Song as adult. Skip Epona Race: the song alone.
        .epona => s.is(.adult) and song(s, .Melody_EponaSong) and (o.skip_epona_race or (s.is(.hf_child) and ocarina(s))),
        .hf_child => s.is(.child_out),
        .zelda_met => o.skip_child_zelda or (s.is(.hf_child) and s.has(.WeirdEgg)),
        // the Kakariko gate
        .dmt_child => s.is(.hf_child) and (o.open_dmt or s.has(.ZeldaLetter)),
        .dmc_child => s.is(.dmt_child) and bombs(s),
        .dmc_adult => s.is(.adult) and (bombs(s) or s.has(.Hammer)),
        .zr_child => s.is(.hf_child) and bombs(s),
        .zd_child => s.is(.zr_child) and song(s, .Melody_ZeldaLullaby),
        .zd_adult => s.is(.adult) and song(s, .Melody_ZeldaLullaby),
        .zf_child => s.is(.zd_child) and (o.open_zora or s.has(.Bottle_Letter)),
        // King Zora moved
        .zf_adult => s.is(.zd_adult) and (o.open_zora or s.is(.zf_child)),
        .gv_adult => s.is(.adult) and (longshot(s) or s.is(.epona)),
        .gf_adult => s.is(.gv_adult),
        .card => s.has(.Token_Gerudo),
        .wasteland => s.is(.gf_adult) and s.is(.card) and lens(s) and (s.has(.HoverBoot) or longshot(s)),
        .colossus_child => song(s, .Melody_SpiritRequiem),
        .colossus_adult => s.is(.adult) and (s.is(.wasteland) or song(s, .Melody_SpiritRequiem)),
        .goron_tunic => s.is(.adult) and (bombs(s) or bow(s) or s.has(.Wallet_Medium)),
        .zora_tunic => s.is(.zd_adult) and ((s.is(.zf_adult) and bottle(s)) or giantWallet(s)),

        // ---- dungeons ("done" = the whole dungeon)
        .dodongo_done => blk: {
            // The entrance boulder only reacts to the special bomb flower next to it (Goron Bracelet), unless the
            // bag-bomb patch is on; inside, bombs or bomb flowers both work.
            const entry = s.has(.Gauntlet_Goron) or (o.dodongo_bag_bombs and bombs(s));
            break :blk s.is(.dmt_child) and entry;
        },
        .jabu_done => s.is(.zf_child) and bottle(s) and s.has(.Boomerang),
        .botw_done => s.is(.hf_child) and song(s, .Melody_StormSong) and lens(s) and bombs(s),
        .forest_done => s.is(.adult) and hookshot(s) and bow(s),
        .fire_done => s.is(.dmc_adult) and s.is(.goron_tunic) and s.has(.Hammer) and bombs(s) and hookshot(s) and
            bow(s) and song(s, .Melody_TimeSong),
        .water_done => s.is(.adult) and s.has(.HeavyBoot) and s.is(.zora_tunic) and song(s, .Melody_ZeldaLullaby) and
            longshot(s) and bow(s) and song(s, .Melody_TimeSong),
        .shadow_done => s.is(.adult) and song(s, .Melody_ShadowNocturne) and dins(s) and lens(s) and s.has(.HoverBoot) and
            hookshot(s) and bombs(s) and song(s, .Melody_ZeldaLullaby),
        .spirit_done => s.is(.colossus_adult) and song(s, .Melody_SpiritRequiem) and str2(s) and hookshot(s) and bombs(s) and
            lens(s) and s.has(.Shield_Mirror) and bow(s) and s.has(.Boomerang),
        .ice_done => s.is(.zf_adult) and bottle(s),
        .gtg_done => s.is(.gf_adult) and s.is(.card) and bow(s) and hookshot(s) and lens(s) and s.has(.HeavyBoot) and
            s.has(.Hammer) and str2(s) and song(s, .Melody_TimeSong) and bombs(s),

        // The rainbow bridge (Rainbow Bridge Requirement). Every option also needs the Bow and the Light Arrows: the
        // bridge checks them in the game too (gamedata.rainbowBridge), and Ganon needs them.
        .bridge => blk: {
            const need = switch (o.rainbow_bridge) {
                .medallions => medal: {
                    var n: i64 = 0;
                    for (medallions) |m| {
                        if (s.has(m)) n += 1;
                    }
                    break :medal n >= o.bridge_medallions;
                },
                // the items themselves (IsGet), not the dungeon quests
                .stones => s.has(.Stone_Forest) and s.has(.Stone_Fire) and s.has(.Stone_Water),
                .tokens => tokens(s, o.bridge_tokens),
                // vanilla: Zelda's Light Arrows scene (the two sage quests)
                .vanilla => s.is(.shadow_done) and s.is(.spirit_done),
            };
            break :blk s.is(.adult) and need and bow(s) and s.has(.Arrow_Light);
        },
        .ganon_done => s.is(.bridge) and hookshot(s) and lens(s) and s.has(.Hammer) and str3(s) and s.has(.HoverBoot) and
            bombs(s) and s.has(.Arrow_Fire) and s.has(.Arrow_Light) and bow(s) and bottle(s) and s.has(.Shield_Mirror) and
            song(s, .Melody_ZeldaLullaby) and song(s, .Melody_TimeSong),
        // Skip Ganon's Trials: the tower is open; Ganondorf needs the Light Arrows (the Master Sword comes with adult)
        .ganon_tower => if (o.skip_ganon_trials) s.is(.bridge) and bow(s) and s.has(.Arrow_Light) else s.is(.ganon_done),
        .win => s.is(.ganon_tower),
    };
}

// -------------------------------------------------------------------------------- overworld regions

/// Overworld regions (stage folders) with their own access rules.
pub const Region = enum {
    KokiriForest,
    LostWood,
    SacredForestMeadow,
    HyruleField,
    Market,
    HyruleCastle,
    KakarikoVillage,
    Graveyard,
    DeathMountainTrail,
    DeathMountainCrater,
    GoronCity,
    ZoraRiver,
    ZoraDomain,
    ZoraFountain,
    GerudoValley,
    GerudoFortress,
    HountedWasteland,
    DesertColossus,
};

pub const Age = enum { child, adult };

pub fn regionByName(name: []const u8) ?Region {
    return std.meta.stringToEnum(Region, name);
}

/// Can Link reach `region` at `age`?
pub fn regionAccess(s: *State, region: Region, age: Age) bool {
    if (age == .adult) {
        return switch (region) {
            .DeathMountainCrater => s.is(.dmc_adult),
            .ZoraDomain => s.is(.zd_adult),
            .ZoraFountain => s.is(.zf_adult),
            .GerudoValley => s.is(.gv_adult),
            .GerudoFortress => s.is(.gf_adult),
            .HountedWasteland => s.is(.wasteland),
            .DesertColossus => s.is(.colossus_adult),
            else => s.is(.adult),
        };
    }
    return switch (region) {
        .KokiriForest, .LostWood => true,
        .SacredForestMeadow => s.has(.Sword_Kokiri),
        .HyruleField, .Market, .HyruleCastle, .KakarikoVillage, .Graveyard, .GerudoValley, .GerudoFortress => s.is(.hf_child),
        .DeathMountainTrail, .GoronCity => s.is(.dmt_child),
        .DeathMountainCrater => s.is(.dmc_child),
        .ZoraRiver => s.is(.zr_child),
        .ZoraDomain => s.is(.zd_child),
        .ZoraFountain => s.is(.zf_child),
        .HountedWasteland => false,
        .DesertColossus => s.is(.colossus_child),
    };
}

/// The extra requirement of a region's grottos and hidden spots at `age`.
pub fn regionExtra(s: *State, region: Region, age: Age) bool {
    const child = age == .child;
    return switch (region) {
        .KokiriForest => bombs(s) and song(s, .Melody_StormSong),
        .LostWood, .SacredForestMeadow, .HyruleCastle, .DeathMountainTrail => bombs(s),
        .HyruleField => bombs(s) and scale(s) and (child or hookshot(s)),
        .Market, .ZoraDomain, .HountedWasteland => true,
        .KakarikoVillage => bombs(s) and (child or hookshot(s)),
        .Graveyard => bombs(s) and song(s, .Melody_SunSong) and song(s, .Melody_ZeldaLullaby),
        .DeathMountainCrater => bombs(s) and (child or (s.is(.goron_tunic) and hookshot(s))),
        .GoronCity => bombs(s) and (child or str2(s)),
        .ZoraRiver => bombs(s) and (child or s.has(.HoverBoot)),
        .ZoraFountain => if (child) scale(s) else s.has(.HeavyBoot),
        .GerudoValley => bombs(s) and (if (child) scale(s) else (s.has(.Hammer) and hookshot(s))),
        .GerudoFortress => hookshot(s) and s.is(.card),
        .DesertColossus => bombs(s) and (child or longshot(s)),
    };
}

// ---------------------------------------------------------------------------- locations with their own rule

/// Locations with their own rule (events and special freestanding items): the curated rule keys.
pub const Special = enum {
    // Skip Child Zelda: Impa's song, Zelda's and Malon's items are owned from the start (zelda_met is true)
    song_impa,
    song_malon,
    song_saria,
    song_tomb,
    song_windmill,
    song_oot,
    oot_gift,
    song_minuet,
    song_bolero,
    song_serenade,
    song_nocturne,
    song_requiem,
    song_prelude,
    adult,
    fairy_dmt,
    fairy_dmc,
    fairy_ogc,
    fairy_hc,
    fairy_zf,
    fairy_colossus,
    hc_child,
    zelda,
    darunia,
    zd_child,
    rolling_goron,
    lw_target,
    market_gallery,
    kak_gallery,
    bowling,
    gerudo_card,
    light_arrows,
    kak_child,
    llr_child,
    biggoron,
    big_poes,
    fishing_child,
    fishing_adult,
    lab_dive,
    frogs,
    graveyard_child,
    graveyard_adult,
    skull_kid,
    memory_game,
    kak_adult_hook,
    market_child,
    hba,
    tokens10,
    tokens20,
    tokens30,
    tokens40,
    tokens50,
    fire_arrows,
    shop_kokiri,
    shop_goron,
    shop_zora,
    shop_bombchu,
    shop_market,
    shop_kakariko,
    theater_skull,
    theater_truth,
    scrub_lw_bridge,
    scrub_lw_nuts,
    scrub_hf,
    scrub_dmc,
    rutos_letter,
    // rule keys that name a derived rule directly (the dungeon rewards)
    deku_done,
    dodongo_done,
    jabu_done,
    forest_done,
    fire_done,
    water_done,
    shadow_done,
    spirit_done,
};

pub fn special(s: *State, key: Special) bool {
    return switch (key) {
        .song_impa => s.is(.zelda_met),
        .song_malon => s.is(.hf_child) and ocarina(s),
        // Sacred Forest Meadow (child, needs the sword) with an ocarina; meeting Zelda only without the setting
        .song_saria => s.has(.Sword_Kokiri) and ocarina(s) and (s.options.saria_song_ocarina or s.is(.zelda_met)),
        .song_tomb => s.is(.hf_child) and song(s, .Melody_ZeldaLullaby),
        .song_windmill => s.is(.adult) and ocarina(s),
        // the Ocarina of Time is thrown at the moat in the same scene as the song
        .song_oot, .oot_gift => moat(s),
        .song_minuet => s.is(.adult),
        .song_bolero => s.is(.dmc_adult),
        .song_serenade => s.is(.ice_done),
        .song_nocturne => s.is(.adult) and s.is(.forest_done) and s.is(.fire_done) and s.is(.water_done),
        .song_requiem => s.is(.adult) and s.is(.wasteland),
        .song_prelude => s.is(.adult) and s.is(.forest_done),
        .adult => s.is(.adult),
        .fairy_dmt => (s.is(.dmt_child) or s.is(.adult)) and bombs(s) and song(s, .Melody_ZeldaLullaby),
        .fairy_dmc => s.is(.dmc_adult) and s.has(.Hammer) and song(s, .Melody_ZeldaLullaby),
        .fairy_ogc => s.is(.adult) and str3(s) and song(s, .Melody_ZeldaLullaby),
        .fairy_hc => s.is(.hf_child) and bombs(s) and song(s, .Melody_ZeldaLullaby),
        .fairy_zf => s.is(.zf_child) and bombs(s) and song(s, .Melody_ZeldaLullaby),
        .fairy_colossus => s.is(.colossus_child) and bombs(s) and song(s, .Melody_ZeldaLullaby),
        .hc_child => s.options.skip_child_zelda or s.is(.hf_child),
        .zelda => s.is(.zelda_met),
        .darunia => s.is(.dmt_child) and song(s, .Melody_ZeldaLullaby) and song(s, .Melody_SariaSong),
        .zd_child => s.is(.zd_child),
        // stop him with a bomb as child
        .rolling_goron => s.is(.dmt_child) and bombs(s),
        // Deku Scrub targets in the Lost Woods (child)
        .lw_target => s.has(.Range_SlingShot),
        .market_gallery => s.is(.hf_child) and s.has(.Range_SlingShot),
        .kak_gallery => s.is(.adult) and bow(s),
        .bowling => s.is(.hf_child) and bombs(s),
        .gerudo_card => s.is(.gf_adult) and hookshot(s),
        .light_arrows => s.is(.adult) and s.is(.shadow_done) and s.is(.spirit_done),
        .kak_child, .llr_child, .fishing_child, .graveyard_child, .market_child => s.is(.hf_child),
        // the whole adult trade sequence: Kakariko, Lost Woods, Kokiri Forest, the Gerudo Valley carpenter, the Death
        // Mountain summit, King Zora and the Lake Hylia lab (its timers can be done on foot)
        .biggoron => s.is(.adult) and s.is(.gv_adult) and s.is(.zd_adult),
        // ten Big Poes in Hyrule Field, on horseback
        .big_poes => s.is(.epona) and bow(s) and bottle(s),
        .fishing_adult, .graveyard_adult => s.is(.adult),
        .lab_dive => s.is(.hf_child) and s.has(.Scale_Gold),
        .frogs => s.is(.zr_child) and song(s, .Melody_ZeldaLullaby) and song(s, .Melody_EponaSong) and
            song(s, .Melody_SariaSong) and song(s, .Melody_SunSong) and song(s, .Melody_TimeSong) and song(s, .Melody_StormSong),
        .skull_kid => song(s, .Melody_SariaSong),
        .memory_game => ocarina(s),
        .kak_adult_hook => s.is(.adult) and hookshot(s),
        .hba => s.is(.gf_adult) and s.is(.card) and s.is(.epona) and bow(s),
        .tokens10 => s.is(.hf_child) and tokens(s, 10),
        .tokens20 => s.is(.hf_child) and tokens(s, 20),
        .tokens30 => s.is(.hf_child) and tokens(s, 30),
        .tokens40 => s.is(.hf_child) and tokens(s, 40),
        .tokens50 => s.is(.hf_child) and tokens(s, 50),
        .fire_arrows => s.is(.adult) and bow(s) and s.is(.water_done),
        .shop_kokiri => true,
        .shop_goron => s.is(.dmt_child) or s.is(.adult),
        .shop_zora => s.is(.zd_child) or s.is(.zd_adult),
        .shop_bombchu => s.is(.hf_child),
        // the Market shops are in the child Market only
        .shop_market => s.is(.hf_child),
        // Kakariko's bazaar and potion shop are in the adult files only
        .shop_kakariko => s.is(.adult),
        // Deku Theater: showing the Skull Mask / the Mask of Truth. The logic doesn't model the mask quest; the masks
        // need Zelda's Letter at the Kakariko gate (Happy Mask Shop), the Mask of Truth also the Skull Kid (Saria's
        // Song) and the Graveyard. With Open Death Mountain the gate flag is already set, so no letter is needed.
        .theater_skull => s.is(.hf_child) and maskShop(s),
        .theater_truth => s.is(.hf_child) and maskShop(s) and song(s, .Melody_SariaSong),
        // one-time Business Scrubs (the generator adds the wallet when the price is above the child wallet)
        .scrub_lw_bridge => true,
        .scrub_lw_nuts => bombs(s) or s.has(.Hammer),
        .scrub_hf => (s.is(.hf_child) or s.is(.adult)) and (bombs(s) or s.has(.Hammer)),
        // child crater only
        .scrub_dmc => s.is(.dmc_child),
        .rutos_letter => s.is(.hf_child) and scale(s),
        .deku_done => s.is(.deku_done),
        .dodongo_done => s.is(.dodongo_done),
        .jabu_done => s.is(.jabu_done),
        .forest_done => s.is(.forest_done),
        .fire_done => s.is(.fire_done),
        .water_done => s.is(.water_done),
        .shadow_done => s.is(.shadow_done),
        .spirit_done => s.is(.spirit_done),
    };
}

/// The rule each dungeon's locations follow (the whole dungeon).
pub fn dungeonRule(dungeon: []const u8) ?Derived {
    const table = [_]struct { name: []const u8, rule: Derived }{
        .{ .name = "InsideTheDekuTree", .rule = .deku_done },       .{ .name = "DodongoCavern", .rule = .dodongo_done },
        .{ .name = "InsideJabuJabuBelly", .rule = .jabu_done },     .{ .name = "BottomOfTheWell", .rule = .botw_done },
        .{ .name = "ForestTemple", .rule = .forest_done },          .{ .name = "FireTemple", .rule = .fire_done },
        .{ .name = "WaterTemple", .rule = .water_done },            .{ .name = "ShadowTemple", .rule = .shadow_done },
        .{ .name = "SpiritTemple", .rule = .spirit_done },          .{ .name = "IceCavern", .rule = .ice_done },
        .{ .name = "GerudoTrainingGround", .rule = .gtg_done },     .{ .name = "InsideGanonCastle", .rule = .ganon_done },
        .{ .name = "GanonCastle", .rule = .ganon_done },
    };
    for (table) |t| if (std.mem.eql(u8, t.name, dungeon)) return t.rule;
    return null;
}

/// A location's rule, worked out once from what it is (world.Location fields).
pub const LocationRule = union(enum) {
    /// a curated rule key (events and special freestanding items)
    special: Special,
    /// the six blue rupees at the bottom of the Zora's Domain pool
    zora_domain_pool,
    /// the Deku Tree's own Slingshot chest (room 2), opened before the Slingshot is ever needed
    deku_slingshot_chest,
    /// The castle grounds' Gold Skulltula is on the Castle Town side of the rainbow bridge, by the Great Fairy, as in
    /// the original game: adult Link only. (Before 0.6.1 it needed all of Ganon's Castle, so 100 tokens could
    /// never open a token bridge.)
    adult_only,
    /// inside a dungeon: the whole dungeon, and for a Gold Skulltula the Boomerang (child dungeon) or a hookshot
    dungeon: struct { done: Derived, gs: GsTool },
    /// in the overworld: reach the region at one of the location's ages, then its spot's requirement
    overworld: Overworld,
    /// a region the logic doesn't know: never reachable
    never,

    pub const GsTool = enum { none, boomerang, hookshot };

    pub const Overworld = struct {
        region: Region,
        child: bool,
        adult: bool,
        /// the Kokiri Sword chest and the Navi tutorial chest: free once the region is reached
        kf_free: bool,
        is_gs: bool,
        /// a Gold Skulltula in magic bean soil (child needs a bottle of bugs)
        bean_gs: bool,
    };
};

fn overworldCheck(s: *State, o: LocationRule.Overworld, age: Age) bool {
    if (!regionAccess(s, o.region, age)) return false;
    if (o.kf_free) return true;
    if (o.is_gs) {
        if (age == .child and !(s.has(.Boomerang) and bombs(s) and (!o.bean_gs or bottle(s)))) return false;
        if (age == .adult and !(hookshot(s) and bombs(s))) return false;
    }
    return regionExtra(s, o.region, age);
}

/// Can a location with rule `rule` be reached in state `s`?
pub fn check(s: *State, rule: LocationRule) bool {
    return switch (rule) {
        .special => |key| special(s, key),
        .zora_domain_pool => (s.is(.zd_child) and scale(s)) or (s.is(.zd_adult) and s.has(.HeavyBoot)),
        .deku_slingshot_chest => s.has(.Sword_Kokiri),
        .adult_only => s.is(.adult),
        .dungeon => |d| s.is(d.done) and switch (d.gs) {
            .none => true,
            .boomerang => s.has(.Boomerang),
            .hookshot => hookshot(s),
        },
        // ages are checked in sorted order ("adult" before "child"), as the Python version did
        .overworld => |o| (o.adult and overworldCheck(s, o, .adult)) or (o.child and overworldCheck(s, o, .child)),
        .never => false,
    };
}

test "an empty state can't win, the derived cache works" {
    var options = Options{};
    var s = try State.init(std.testing.allocator, item_count, &options);
    defer s.deinit(std.testing.allocator);
    try std.testing.expect(!s.is(.win));
    try std.testing.expect(!s.is(.deku_done));
    s.add(Item.Sword_Kokiri.id());
    s.add(Item.Range_SlingShot.id());
    try std.testing.expect(s.is(.deku_done));
    try std.testing.expect(s.is(.hf_child));
}
