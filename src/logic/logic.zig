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
    // one key for every copy of an upgrade line (progressive.zig): each hands out the next tier the player doesn't
    // own yet. The logic counts them together with the line's own tiers (tiersOwned)
    Progressive_Ocarina,
    Progressive_Hookshot,
    Progressive_Strength,
    Progressive_Scale,
    Progressive_Wallet,
    Progressive_BombBag,
    // Door of Time: Closed holds them before going adult
    Stone_Forest,
    Stone_Fire,
    Stone_Water,
    // Small Keys as key rings / Boss Keys outside their temple (key_dungeons): items of their own, made by the
    // generator (keyitems.zig); the actor is "Item_" + the name
    KeyRing_ForestTemple,
    KeyRing_FireTemple,
    KeyRing_WaterTemple,
    KeyRing_ShadowTemple,
    KeyRing_SpiritTemple,
    KeyRing_Well,
    KeyRing_GTG,
    KeyRing_Ganon,
    BossKey_ForestTemple,
    BossKey_FireTemple,
    BossKey_WaterTemple,
    BossKey_ShadowTemple,
    BossKey_SpiritTemple,
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


/// Regions a child can reach before leaving a closed Kokiri Forest (the Deku Tree itself excluded).
pub const forest_regions = [_][]const u8{ "KokiriForest", "LostWood", "SacredForestMeadow" };

pub fn isForestRegion(region: []const u8) bool {
    for (forest_regions) |r| if (std.mem.eql(u8, r, region)) return true;
    return false;
}

/// A dungeon with small keys: its key ring (every small key at once, wherever it is found) and, for the five temples,
/// a boss key of its own. `keys`: how many small keys a key ring gives, the Archipelago counts OotrR uses (never fewer
/// than the remake's locked doors; an extra key is harmless). Ganon's Castle's boss key always stays in its chest.
pub const KeyDungeon = struct { folder: []const u8, name: []const u8, ring: Item, keys: u8, boss: ?Item };

pub const key_dungeons = [_]KeyDungeon{
    .{ .folder = "ForestTemple", .name = "Forest Temple", .ring = .KeyRing_ForestTemple, .keys = 5, .boss = .BossKey_ForestTemple },
    .{ .folder = "FireTemple", .name = "Fire Temple", .ring = .KeyRing_FireTemple, .keys = 8, .boss = .BossKey_FireTemple },
    .{ .folder = "WaterTemple", .name = "Water Temple", .ring = .KeyRing_WaterTemple, .keys = 6, .boss = .BossKey_WaterTemple },
    .{ .folder = "ShadowTemple", .name = "Shadow Temple", .ring = .KeyRing_ShadowTemple, .keys = 5, .boss = .BossKey_ShadowTemple },
    .{ .folder = "SpiritTemple", .name = "Spirit Temple", .ring = .KeyRing_SpiritTemple, .keys = 5, .boss = .BossKey_SpiritTemple },
    .{ .folder = "BottomOfTheWell", .name = "Bottom of the Well", .ring = .KeyRing_Well, .keys = 3, .boss = null },
    .{ .folder = "GerudoTrainingGround", .name = "Gerudo Training Ground", .ring = .KeyRing_GTG, .keys = 9, .boss = null },
    .{ .folder = "InsideGanonCastle", .name = "Ganon's Castle", .ring = .KeyRing_Ganon, .keys = 2, .boss = null },
};

/// A key ring or dungeon boss key item, by its item key ("KeyRing_ForestTemple").
pub const KeyItem = struct { dungeon: usize, ring: bool };

pub fn keyItemOf(name: []const u8) ?KeyItem {
    for (key_dungeons, 0..) |d, i| {
        if (std.mem.eql(u8, name, @tagName(d.ring))) return .{ .dungeon = i, .ring = true };
        if (d.boss) |b| if (std.mem.eql(u8, name, @tagName(b))) return .{ .dungeon = i, .ring = false };
    }
    return null;
}

/// The index of dungeon `folder` in key_dungeons, or null.
pub fn keyDungeonIndex(folder: []const u8) ?usize {
    for (key_dungeons, 0..) |d, i| if (std.mem.eql(u8, d.folder, folder)) return i;
    return null;
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
    /// Starting Age: Adult (or Random that chose adult; the Plan sets it). Adult Link is there from the start, and
    /// child Link is one trip to the Temple of Time away: putting the Master Sword back, he walks out of the
    /// Temple of Time into Castle Town (and the Kokiri boy at the forest exit is gone, gamedata.zig).
    start_adult: bool = false,
    /// per key_dungeons entry: the dungeon's small keys are its key ring (the Plan sets these: Random Dungeons
    /// depends on the seed)
    key_ring: [key_dungeons.len]bool = @splat(false),
    /// per key_dungeons entry: its boss key is an item of its own (Boss Keys: Any Dungeon / Anywhere)
    boss_key_item: [key_dungeons.len]bool = @splat(false),

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

/// How many tiers of an upgrade line the player owns: the copies of its progressive item plus its tiers owned as
/// items of their own (an unshuffled line keeps its vanilla items). Owning n of them counts as owning the line's first
/// n tiers: that is what progressive copies hand out, and an unshuffled line is found in the game's own order.
fn tiersOwned(s: *const State, progressive_item: Item, tiers: []const Item) i64 {
    var owned: i64 = s.count(progressive_item.id());
    for (tiers) |tier| owned += s.count(tier.id());
    return owned;
}
pub fn bombBagTiers(s: *const State) i64 {
    return tiersOwned(s, .Progressive_BombBag, &.{ .BombBag_Small, .BombBag_Medium, .BombBag_Large });
}
pub fn hookshotTiers(s: *const State) i64 {
    return tiersOwned(s, .Progressive_Hookshot, &.{ .Hookshot, .Longshot });
}
pub fn strengthTiers(s: *const State) i64 {
    return tiersOwned(s, .Progressive_Strength, &.{ .Gauntlet_Goron, .Gauntlet_Silver, .Gauntlet_Gold });
}
pub fn scaleTiers(s: *const State) i64 {
    return tiersOwned(s, .Progressive_Scale, &.{ .Scale_Silver, .Scale_Gold });
}
pub fn walletTiers(s: *const State) i64 {
    return tiersOwned(s, .Progressive_Wallet, &.{ .Wallet_Medium, .Wallet_Large });
}
pub fn ocarinaTiers(s: *const State) i64 {
    return tiersOwned(s, .Progressive_Ocarina, &.{ .Ocarina_Fairy, .Ocarina_Time });
}

pub fn bombs(s: *State) bool {
    const bag = bombBagTiers(s) >= 1;
    // Bag bombs are lifted objects in the remake: without the bomb patch they need the Goron Bracelet.
    return bag and (s.options.bag_bombs_no_bracelet or str1(s));
}
/// Bombs in child Link's hands: a bag, and with bag bombs lifted, the Goron Bracelet itself (childStr1).
pub fn childBombs(s: *State) bool {
    const bag = bombBagTiers(s) >= 1;
    return bag and (s.options.bag_bombs_no_bracelet or childStr1(s));
}
/// Bombs at `age` (childBombs for child Link).
pub fn bombsAt(s: *State, age: Age) bool {
    return if (age == .child) childBombs(s) else bombs(s);
}
pub fn hookshot(s: *State) bool {
    return hookshotTiers(s) >= 1;
}
pub fn longshot(s: *State) bool {
    return hookshotTiers(s) >= 2;
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
    return scaleTiers(s) >= 1;
}
pub fn goldenScale(s: *State) bool {
    return scaleTiers(s) >= 2;
}
/// The Goron Bracelet, or better (a progressive line's first copy is always the bracelet).
pub fn str1(s: *State) bool {
    return strengthTiers(s) >= 1;
}
/// Child Link's strength: the Goron Bracelet itself, or a Progressive Strength copy (the first one is always the
/// bracelet). Why not any tier: the Silver and Golden Gauntlets are adult Link's equipment
/// (Armor_Adult_Gauntlet_*), so a child holding only those lifts nothing, and with Progressive Items off (or a
/// Gauntlet kept in a big chest) they can be found before the bracelet. str1 counting them for a child spot could
/// put the only way to bombs behind a bomb flower he can't lift, as the Lost Woods rock once did.
pub fn childStr1(s: *State) bool {
    return s.has(.Gauntlet_Goron) or s.count(Item.Progressive_Strength.id()) >= 1;
}
pub fn str2(s: *State) bool {
    return strengthTiers(s) >= 2;
}
pub fn str3(s: *State) bool {
    return strengthTiers(s) >= 3;
}
/// The Adult's Wallet or better: prices above 99 rupees.
pub fn adultWallet(s: *const State) bool {
    return walletTiers(s) >= 1;
}
pub fn bottle(s: *State) bool {
    // Ruto's Letter becomes an empty bottle only when it is delivered (impossible if King Zora starts moved)
    const letter = s.has(.Bottle_Letter) and s.is(.zd_child) and !s.options.open_zora;
    return s.has(.Bottle) or s.has(.Bottle_Milk) or letter;
}
pub fn ocarina(s: *State) bool {
    // vanilla: Saria hands over the Fairy Ocarina when you leave the forest after the Deku Tree
    if (ocarinaTiers(s) >= 1) return true;
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
/// The Giant's Wallet: two tiers of the wallet line.
pub fn giantWallet(s: *State) bool {
    return walletTiers(s) >= 2;
}
/// The keys of key_dungeons[`index`] when they are items of their own: its key ring and its boss key. Why the whole
/// dungeon needs them: the logic has no door-by-door model, so like every other item a dungeon needs, they are
/// expected before anything in it (a key ring or boss key is never placed inside its own dungeon then).
pub fn dungeonKeys(s: *State, index: usize) bool {
    const d = key_dungeons[index];
    if (s.options.key_ring[index] and !s.has(d.ring)) return false;
    if (s.options.boss_key_item[index]) {
        if (d.boss) |b| if (!s.has(b)) return false;
    }
    return true;
}

// --------------------------------------------------------------------------------------- the derived rules

fn evalDerived(s: *State, d: Derived) bool {
    const o = s.options;
    return switch (d) {
        // the shield is bought in the forest shop
        .deku_done => s.has(.Sword_Kokiri) and s.has(.Range_SlingShot),
        // the exit blocker stays until Gohma
        .child_out => o.open_forest != .closed or o.start_adult or s.is(.deku_done),
        .adult => blk: {
            // Starting Age: Adult
            if (o.start_adult) break :blk true;
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
        .dmc_child => s.is(.dmt_child) and childBombs(s),
        .dmc_adult => s.is(.adult) and (bombs(s) or s.has(.Hammer)),
        .zr_child => s.is(.hf_child) and childBombs(s),
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
        .goron_tunic => s.is(.adult) and (bombs(s) or bow(s) or adultWallet(s)),
        .zora_tunic => s.is(.zd_adult) and ((s.is(.zf_adult) and bottle(s)) or giantWallet(s)),

        // ---- dungeons ("done" = the whole dungeon)
        .dodongo_done => blk: {
            // The entrance boulder only reacts to the special bomb flower next to it (Goron Bracelet), unless the
            // bag-bomb patch is on; inside, bombs or bomb flowers both work.
            // a child dungeon in the logic: child Link's bracelet and bombs
            const entry = childStr1(s) or (o.dodongo_bag_bombs and childBombs(s));
            break :blk s.is(.dmt_child) and entry;
        },
        .jabu_done => s.is(.zf_child) and bottle(s) and s.has(.Boomerang),
        .botw_done => s.is(.hf_child) and song(s, .Melody_StormSong) and lens(s) and childBombs(s) and dungeonKeys(s, 5),
        .forest_done => s.is(.adult) and hookshot(s) and bow(s) and dungeonKeys(s, 0),
        .fire_done => s.is(.dmc_adult) and s.is(.goron_tunic) and s.has(.Hammer) and bombs(s) and hookshot(s) and
            bow(s) and song(s, .Melody_TimeSong) and dungeonKeys(s, 1),
        .water_done => s.is(.adult) and s.has(.HeavyBoot) and s.is(.zora_tunic) and song(s, .Melody_ZeldaLullaby) and
            longshot(s) and bow(s) and song(s, .Melody_TimeSong) and dungeonKeys(s, 2),
        .shadow_done => s.is(.adult) and song(s, .Melody_ShadowNocturne) and dins(s) and lens(s) and s.has(.HoverBoot) and
            hookshot(s) and bombs(s) and song(s, .Melody_ZeldaLullaby) and dungeonKeys(s, 3),
        .spirit_done => s.is(.colossus_adult) and song(s, .Melody_SpiritRequiem) and str2(s) and hookshot(s) and bombs(s) and
            lens(s) and s.has(.Shield_Mirror) and bow(s) and s.has(.Boomerang) and dungeonKeys(s, 4),
        .ice_done => s.is(.zf_adult) and bottle(s),
        .gtg_done => s.is(.gf_adult) and s.is(.card) and bow(s) and hookshot(s) and lens(s) and s.has(.HeavyBoot) and
            s.has(.Hammer) and str2(s) and song(s, .Melody_TimeSong) and bombs(s) and dungeonKeys(s, 6),

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
            song(s, .Melody_ZeldaLullaby) and song(s, .Melody_TimeSong) and dungeonKeys(s, 7),
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
        .KokiriForest => bombsAt(s, age) and song(s, .Melody_StormSong),
        .LostWood, .SacredForestMeadow, .HyruleCastle, .DeathMountainTrail => bombsAt(s, age),
        .HyruleField => bombsAt(s, age) and scale(s) and (child or hookshot(s)),
        .Market, .ZoraDomain, .HountedWasteland => true,
        .KakarikoVillage => bombsAt(s, age) and (child or hookshot(s)),
        .Graveyard => bombsAt(s, age) and song(s, .Melody_SunSong) and song(s, .Melody_ZeldaLullaby),
        .DeathMountainCrater => bombsAt(s, age) and (child or (s.is(.goron_tunic) and hookshot(s))),
        .GoronCity => bombsAt(s, age) and (child or str2(s)),
        .ZoraRiver => bombsAt(s, age) and (child or s.has(.HoverBoot)),
        .ZoraFountain => if (child) scale(s) else s.has(.HeavyBoot),
        .GerudoValley => bombsAt(s, age) and (if (child) scale(s) else (s.has(.Hammer) and hookshot(s))),
        // the fortress's spots are adult Link's (the Hookshot); child Link has none there
        .GerudoFortress => !child and hookshot(s) and s.is(.card),
        .DesertColossus => bombsAt(s, age) and (child or longshot(s)),
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
        .fairy_dmt => ((s.is(.dmt_child) and childBombs(s)) or (s.is(.adult) and bombs(s))) and song(s, .Melody_ZeldaLullaby),
        .fairy_dmc => s.is(.dmc_adult) and s.has(.Hammer) and song(s, .Melody_ZeldaLullaby),
        .fairy_ogc => s.is(.adult) and str3(s) and song(s, .Melody_ZeldaLullaby),
        .fairy_hc => s.is(.hf_child) and childBombs(s) and song(s, .Melody_ZeldaLullaby),
        .fairy_zf => s.is(.zf_child) and childBombs(s) and song(s, .Melody_ZeldaLullaby),
        .fairy_colossus => s.is(.colossus_child) and childBombs(s) and song(s, .Melody_ZeldaLullaby),
        .hc_child => s.options.skip_child_zelda or s.is(.hf_child),
        .zelda => s.is(.zelda_met),
        .darunia => s.is(.dmt_child) and song(s, .Melody_ZeldaLullaby) and song(s, .Melody_SariaSong),
        .zd_child => s.is(.zd_child),
        // stop him with a bomb as child
        .rolling_goron => s.is(.dmt_child) and childBombs(s),
        // Deku Scrub targets in the Lost Woods (child)
        .lw_target => s.has(.Range_SlingShot),
        .market_gallery => s.is(.hf_child) and s.has(.Range_SlingShot),
        .kak_gallery => s.is(.adult) and bow(s),
        .bowling => s.is(.hf_child) and childBombs(s),
        .gerudo_card => s.is(.gf_adult) and hookshot(s),
        .light_arrows => s.is(.adult) and s.is(.shadow_done) and s.is(.spirit_done),
        .kak_child, .llr_child, .fishing_child, .graveyard_child, .market_child => s.is(.hf_child),
        // the whole adult trade sequence: Kakariko, Lost Woods, Kokiri Forest, the Gerudo Valley carpenter, the Death
        // Mountain summit, King Zora and the Lake Hylia lab (its timers can be done on foot)
        .biggoron => s.is(.adult) and s.is(.gv_adult) and s.is(.zd_adult),
        // ten Big Poes in Hyrule Field, on horseback
        .big_poes => s.is(.epona) and bow(s) and bottle(s),
        .fishing_adult, .graveyard_adult => s.is(.adult),
        .lab_dive => s.is(.hf_child) and goldenScale(s),
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
        // Both grottos are under a cracked rock: bombs, or the Megaton Hammer, which only adult Link can swing (a
        // child-reachable Hammer once let a seed hide its only Bomb Bag under the Lost Woods rock)
        .scrub_lw_nuts => childBombs(s) or (s.is(.adult) and (bombs(s) or s.has(.Hammer))),
        // The remake's Hyrule Field scrub only sells for a password (Enemy_Scrub_Business_Common: HaveReadHrlField_Note07,
        // Enemy_Scrub_Business_Secret_*), written on a Fairy Thought outside that adult Link reads; then child Link
        // buys it (guides). Not confirmed which ages can buy, so the rule asks for both, which works either way.
        .scrub_hf => s.is(.adult) and s.is(.hf_child) and childBombs(s),
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
        if (age == .child and !(s.has(.Boomerang) and childBombs(s) and (!o.bean_gs or bottle(s)))) return false;
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

test "a dungeon with a key ring or boss key item needs them" {
    var options = Options{};
    var s = try State.init(std.testing.allocator, item_count, &options);
    defer s.deinit(std.testing.allocator);
    // the Bottom of the Well (index 5): Song of Storms, Lens, bombs, from Hyrule Field as child
    for ([_]Item{ .Sword_Kokiri, .Range_SlingShot, .Ocarina_Fairy, .Melody_StormSong, .GlassTruth, .BombBag_Small }) |it| s.add(it.id());
    try std.testing.expect(s.is(.botw_done));
    options.key_ring[5] = true;
    s.clearCache();
    try std.testing.expect(!s.is(.botw_done));
    s.add(Item.KeyRing_Well.id());
    try std.testing.expect(s.is(.botw_done));
    // every key dungeon's ring and boss key name a real dungeon folder of keyDungeonIndex
    for (key_dungeons, 0..) |d, i| {
        try std.testing.expectEqual(@as(?usize, i), keyDungeonIndex(d.folder));
        try std.testing.expectEqual(@as(?KeyItem, .{ .dungeon = i, .ring = true }), keyItemOf(@tagName(d.ring)));
        try std.testing.expect(@tagName(d.ring).len + "Item_".len <= 25);
    }
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

test "the Megaton Hammer only breaks the scrub grottos' rocks as adult" {
    var options = Options{};
    var s = try State.init(std.testing.allocator, item_count, &options);
    defer s.deinit(std.testing.allocator);
    // softlock report: a child-reachable Hammer let a seed hide its only Bomb Bag under the Lost Woods rock
    s.add(Item.Sword_Kokiri.id());
    s.add(Item.Range_SlingShot.id());
    s.add(Item.Hammer.id());
    try std.testing.expect(!s.is(.adult));
    try std.testing.expect(!special(&s, .scrub_lw_nuts));
    try std.testing.expect(!special(&s, .scrub_hf));
    options.start_adult = true;
    s.clearCache();
    try std.testing.expect(special(&s, .scrub_lw_nuts));
    // the Hyrule Field scrub's password: adult reads it, child (with bombs for the rock) buys
    try std.testing.expect(!special(&s, .scrub_hf));
    s.add(Item.BombBag_Small.id());
    s.clearCache();
    try std.testing.expect(special(&s, .scrub_hf));
}

/// Items only adult Link can use, and only child Link (for the age tests below).
const adult_only_items = [_]Item{
    .Hookshot,     .Longshot,       .Progressive_Hookshot, .Range_Bow,    .Hammer,      .HeavyBoot,      .HoverBoot,
    .Gauntlet_Silver, .Gauntlet_Gold, .Arrow_Fire,          .Arrow_Light,  .Shield_Mirror,
};
const child_only_items = [_]Item{ .Range_SlingShot, .Boomerang, .Sword_Kokiri };

/// A state with every item (enough copies for every tier and count) except those in `left_out`. The Strength line is
/// given as the Goron Bracelet alone when the Gauntlets are left out (child Link wears the bracelet).
fn stateWithout(allocator: std.mem.Allocator, options: *const Options, left_out: []const Item) !State {
    var s = try State.init(allocator, item_count, options);
    for (0..item_count) |index| {
        const item: Item = @enumFromInt(index);
        if (std.mem.indexOfScalar(Item, left_out, item) != null) continue;
        if (item == .Progressive_Strength and std.mem.indexOfScalar(Item, left_out, .Gauntlet_Silver) != null) continue;
        const copies: usize = if (item == .Token_Gold) 100 else 3;
        for (0..copies) |_| s.addKeepingCache(item.id());
    }
    s.clearCache();
    return s;
}

test "child spots never need an adult item, adult spots never a child item" {
    const allocator = std.testing.allocator;
    var options = Options{};
    var everything = try stateWithout(allocator, &options, &.{});
    defer everything.deinit(allocator);
    var no_adult_items = try stateWithout(allocator, &options, &adult_only_items);
    defer no_adult_items.deinit(allocator);
    // the adult side starts as adult: going adult otherwise needs the Deku Tree, which needs the child items
    var adult_start = Options{ .start_adult = true };
    var adult_everything = try stateWithout(allocator, &adult_start, &.{});
    defer adult_everything.deinit(allocator);
    var no_child_items = try stateWithout(allocator, &adult_start, &child_only_items);
    defer no_child_items.deinit(allocator);

    // every region's grottos and hidden spots, at each age
    for (std.meta.tags(Region)) |region| {
        if (regionExtra(&everything, region, .child) != regionExtra(&no_adult_items, region, .child)) {
            std.debug.print("child Link needs an adult item for {s}'s spots\n", .{@tagName(region)});
            return error.TestUnexpectedResult;
        }
        if (regionExtra(&adult_everything, region, .adult) != regionExtra(&no_child_items, region, .adult)) {
            std.debug.print("adult Link needs a child item for {s}'s spots\n", .{@tagName(region)});
            return error.TestUnexpectedResult;
        }
    }
    // the checks only child Link can get
    const child_checks = [_]Special{
        .song_malon,     .song_saria,     .song_tomb,     .fairy_hc,       .fairy_zf,    .fairy_colossus, .hc_child,
        .darunia,        .zd_child,       .rolling_goron, .lw_target,      .market_gallery, .bowling,     .kak_child,
        .llr_child,      .fishing_child,  .graveyard_child, .skull_kid,    .memory_game, .market_child,   .tokens10,
        .tokens50,       .shop_bombchu,   .shop_market,   .theater_skull,  .theater_truth, .scrub_dmc,   .rutos_letter,
        .lab_dive,       .frogs,
    };
    for (child_checks) |key| {
        if (special(&everything, key) != special(&no_adult_items, key)) {
            std.debug.print("the child-only check {s} needs an adult item\n", .{@tagName(key)});
            return error.TestUnexpectedResult;
        }
    }
    // the checks only adult Link can get (not the Light Arrows: they need the Spirit Temple, whose child half needs
    // the Boomerang)
    const adult_checks = [_]Special{
        .song_windmill, .song_bolero, .fairy_dmc, .fairy_ogc, .kak_gallery, .gerudo_card, .biggoron, .big_poes,
        .fishing_adult, .graveyard_adult, .kak_adult_hook, .hba, .fire_arrows, .shop_kakariko,
    };
    for (adult_checks) |key| {
        if (special(&adult_everything, key) != special(&no_child_items, key)) {
            std.debug.print("the adult-only check {s} needs a child item\n", .{@tagName(key)});
            return error.TestUnexpectedResult;
        }
    }
}

test "child Link's strength and bombs need the Goron Bracelet, not the Gauntlets" {
    const allocator = std.testing.allocator;
    // bag bombs lifted (the bomb patch off): they need the bracelet
    var options = Options{ .bag_bombs_no_bracelet = false };
    // everything, but the strength line only as the adult Gauntlets (found first with Progressive Items off)
    var gauntlets_only = try stateWithout(allocator, &options, &.{ .Gauntlet_Goron, .Progressive_Strength });
    defer gauntlets_only.deinit(allocator);
    try std.testing.expect(str1(&gauntlets_only) and !childStr1(&gauntlets_only));
    try std.testing.expect(bombs(&gauntlets_only) and !childBombs(&gauntlets_only));
    // child spots that need bombs: not with the Gauntlets alone
    try std.testing.expect(!regionExtra(&gauntlets_only, .LostWood, .child));
    try std.testing.expect(regionExtra(&gauntlets_only, .LostWood, .adult));
    try std.testing.expect(!special(&gauntlets_only, .rolling_goron));
    try std.testing.expect(!evalDerived(&gauntlets_only, .dodongo_done));
    // the bracelet, or a progressive copy (the first is the bracelet), is enough
    gauntlets_only.add(Item.Progressive_Strength.id());
    gauntlets_only.clearCache();
    try std.testing.expect(childStr1(&gauntlets_only) and childBombs(&gauntlets_only));
    try std.testing.expect(regionExtra(&gauntlets_only, .LostWood, .child));
}

test "progressive copies count as the line's first tiers" {
    var options = Options{};
    var s = try State.init(std.testing.allocator, item_count, &options);
    defer s.deinit(std.testing.allocator);
    try std.testing.expect(!hookshot(&s));
    s.add(Item.Progressive_Hookshot.id());
    try std.testing.expect(hookshot(&s) and !longshot(&s));
    s.add(Item.Progressive_Hookshot.id());
    try std.testing.expect(longshot(&s));
    // an unshuffled tier counts with the copies
    s.add(Item.Gauntlet_Goron.id());
    s.add(Item.Progressive_Strength.id());
    try std.testing.expect(str1(&s) and str2(&s) and !str3(&s));
    s.add(Item.Progressive_Strength.id());
    try std.testing.expect(str3(&s));
    s.add(Item.Progressive_Wallet.id());
    try std.testing.expect(adultWallet(&s) and !giantWallet(&s));
}
