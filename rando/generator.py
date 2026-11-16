"""Item placement (assumed fill), validation, patch writing and spoiler log."""
import hashlib
import json
import os
import random
import time
from collections import Counter, defaultdict

from . import formats as F
from . import faststart
from . import gamedata
from . import hints as H
from . import longshot
from . import logic as L
from . import settings as S
from .pickups import PickupCloner, patch_song_models
from .qol import (patch_anju, patch_dodongo_bag_bombs, patch_egg_hatch_guard, 
                  patch_ocarina_bridge, patch_open_forest_mido, patch_saria_song, patch_song_teaching,
                  patch_small_chest_dungeon_items, patch_kokiri_schedules, patch_big_poe_one, patch_open_zora_arrival,
                  patch_gs_any_time, patch_ganon_trials)
from .world import World, JUNK, EVENT_LOCATIONS
from . import scrubtext
from . import storyskip
from .door import patch_open_door

VERSION = "0.6.0"
NAME = "Goggles of Truth Randomizer"   # an OoT (2026 remake) randomizer mod
BOMB_LIFT_PARAM = "Component/LiftableParam/Item_Bomb.game__component__LiftableParam.bgyml"
BOMB_PACKS = ["Pack/Actor/Item_Bomb.pack.zs", "Pack/Actor/Npc_Hylia_ImperialSoldier_Bomb.pack.zs",
              "Pack/Actor/Obj_BombFlower_A_01.pack.zs", "Pack/Actor/Obj_BombFlower_A_04.pack.zs",
              "Pack/Actor/Obj_BombFlower_Fruit_For_Break_Obj_DeathMtTrail_BrokenRock_A_01.pack.zs"]
BRACELET_GRADE = 3655598229      # LiftableGrade granted by the Goron Bracelet
DEFAULT_GRADE = 3069107721       # grade of pots, small rocks, Bombchus (no bracelet needed)
SKIP_SETTING = "Event/EventSetting/EventSettingComponent/SkipSetting/DisableSkip.engine__event__SkipSetting.bgyml"
# Items a shuffled shelf may not sell. Shop_Rando_ shelves are bought once (rando/pickups.py), as in OotrR;
# the token and the capacity upgrades (handed out as "Bigger, else Biggest" elsewhere) stay off shelves.
SHOP_FORBIDDEN = {"Token_Gold", "BombBag_Medium", "BulletBag_Medium", "Quiver_Medium", "Wallet_Medium", "Wallet_Large"}
SHOP_PRICE = 10                 # OotrR: every shuffled shelf costs 10 rupees
# Shelves whose purchase the game needs: at least one copy of each stays on sale (OotrR keeps one copy of every
# purchase the logic uses). The Deku Shield and the tunics are sold in one shop only, so they never move.
SHOP_KEEP_ONE = {"Shop_Weapon_Shield_Deku", "Shop_Weapon_Shield_Hylian", "Shop_Armor_Goron", "Shop_Armor_Zora",
                 "Shop_Bottle_BlueFire", "Shop_Bottle_Bug", "Shop_Bottle_Fish", "Shop_Bottle_Fairy"}
# Business Scrubs: "low" 10 rupees, "regular" the game's own price (40 or 100), "random" 10 to 99 (child wallet)
SCRUB_LOW_PRICE, CHILD_WALLET, ADULT_WALLET = 10, 99, 200
UPGRADES = {"Wallet_Medium", "Wallet_Large", "BombBag_Medium", "BombBag_Large"}
REWARDS = {"Stone_Forest", "Stone_Fire", "Stone_Water", "Medal_Forest", "Medal_Fire", "Medal_Water",
           "Medal_Shadow", "Medal_Spirit", "Medal_Light"}
SHOP_FORBIDDEN |= REWARDS

# Skip Child Zelda: the checks whose items a new save already owns (gamedata.grant_start_items)
START_LOCATIONS = ("event:HC Zeldas Letter", "event:HC Malon Egg", "event:Song from Impa")
# Items the save can't simply be given (they need ammo, capacity, hearts, magic or a bottle slot set up too)
START_DENY_PREFIXES = ("Heart_", "Token_Gold", "Bottle", "BombBag_", "Quiver_", "BulletBag_", "Wallet_", "NutBag_",
                       "StickBag_", "Range_", "FairyBless_", "Arrow_", "Bombchu", "Bomb", "Deku", "Rupee_",
                       "MagicJar_", "ArrowBundle", "ScrubBusinessSeed")


class GenerationError(Exception):
    pass


# Refills that are useless without their container: the item a chest checks for before giving them.
# Bombchus count against the Bomb Bag (Item_Bombchu's PouchContentParam: MaxNumGameData "Bomb"), so without a
# bag they are lost: the get message says "5 Bombchus" but the count stays at 0.
# Deku Nuts and Sticks have no item of their own, only a bag: a single nut or stick picked up (Item_DekuNut,
# Item_DekuStick, Obj_DekuStick: IsAbleToGetBagIfGet, SmallBagActor Item_NutBag_Small / Item_StickBag_Small) gives
# that bag, and only then do they have a slot. A bundle doesn't (no IsAbleToGetBagIfGet: TBox_DekuNutBundle,
# Item_DekuStickBundle_Small), so one found first was lost.
REFILL_CONTAINERS = (("ArrowBundle", "Item_Range_Bow"), ("BombBundle", "Item_BombBag_Small"),
                     ("BombchuBundle", "Item_BombBag_Small"), ("DekuSeedBundle", "Item_Range_SlingShot"),
                     ("DekuNutBundle", "Item_NutBag_Small"), ("DekuStickBundle", "Item_StickBag_Small"))
REFILL_FALLBACK = "Rupee_Blue"

# Maps & Compasses "Start With": what their checks hold instead (item, weight). Never progression.
START_WITH_BONUS = [("Rupee_Blue", 3), ("Rupee_Red", 5), ("Rupee_Purple", 4), ("Rupee_Gold", 2),
                    ("BombchuBundle_Medium", 2), ("ArrowBundle_Large", 2), ("DekuNutBundle", 1),
                    ("Heart_Piece", 1)]


# Capacity upgrades that several locations hand out as "Bigger". In a chest they become progressive with the
# game's conditional-chest check: own the Bigger one (CheckActor) -> the Biggest (Substitute), else Bigger.
PROGRESSIVE_UPGRADES = {"BombBag_Medium": ("Item_BombBag_Medium", "Item_BombBag_Large"),
                        "BulletBag_Medium": ("Item_BulletBag_Medium", "Item_BulletBag_Large"),
                        "Quiver_Medium": ("Item_Quiver_Medium", "Item_Quiver_Large"),
                        "Wallet_Medium": ("Item_Wallet_Medium", "Item_Wallet_Large")}
# The Skulltula House wallets go into the pool as two Adult's Wallets that only chests may hold: a chest's
# conditional check gives the Giant's Wallet if you already own the Adult's one. Handed out by an event, a
# Giant's Wallet found first could later be "downgraded" by the Adult's Wallet.
PROGRESSIVE_WALLET = "Wallet_Medium"

# Never shuffled. The Gerudo Membership Card does nothing by itself: the guards, the wasteland gate, the
# Training Ground and horseback archery check the Spirit quest step (SageOfSpirit_IsAfter_Step03_Exp), which only
# the captain's scene after the carpenters sets; the card itself only stops the jail in the sneak areas
# (Logic/GerudoFortress_Common_35d7). A card found anywhere else left the guards hostile.
ALWAYS_VANILLA = {"Token_Gerudo"}

# Items a Gold Skulltula may not drop. Since 0.5.0 every drop is a token-based pickup (rando/pickups.py), so the
# Piece of Heart and Ruto's Letter (whose own pickups need A) are allowed again.
GS_FORBIDDEN = set()

# Junk on a Gold Skulltula. A token-based drop only disappears when collected if its item is owned once (an IsGet
# flag): a token-based rupee stayed on the ground after it was collected and its Skulltula came back (test seed 4),
# and so did token-based copies of the chest forms (TBox_Rupee_*, the ammo bundles; test seed 6). Consumables
# (rupees, ammo, hearts, magic, the Business Scrub Seed) drop as the game's own pickup instead, as in OotrR: it
# falls to the ground, but is collected and stays gone (test seed 5). Shields are equipment and float like the
# other items. Junk with neither (the bigger Bombchu bundles) is kept off Skulltulas.
GS_FLOATING_JUNK = {"Shield_Deku", "Shield_Hylian"}
NATIVE_DROPS = {"BombBundle_Small": "Obj_Bomb", "DekuStickBundle_Small": "Obj_DekuStick", "DekuNutBundle": "Obj_DekuNut",
                "DekuSeedBundle": "Obj_DekuSeed", "BombchuBundle_Small": "Obj_Bombchu"}


def native_drop(world, item):
    """The game's own world pickup for consumable `item` (it falls when dropped), or None."""
    actor = NATIVE_DROPS.get(item)
    if actor is None:
        try:
            actor = world.actor_for(item, "world")
        except KeyError:
            return None
    return actor if actor.startswith("Obj_") and world.actor_exists(actor) else None


def gs_refuses(world, item):
    """Junk a Gold Skulltula can't drop (no floating form, no pickup of its own)."""
    return item in JUNK and item not in GS_FLOATING_JUNK and not native_drop(world, item)


# Chest "get" events that act out the vanilla item. Get_StoneOfForest_GetSword (the Kokiri Sword chest) plays
# Dm_Kokiri_0063, where Link swings the sword: he ends up holding a Kokiri Sword that isn't in the save, so
# it is gone after reloading. A randomized chest uses the normal chest event instead.
ITEM_GET_EVENTS = {"Get_StoneOfForest_GetSword"}



def refill_container(item):
    """Pouch actor a refill needs (e.g. arrows -> Bow), or None for anything else."""
    return next((c for prefix, c in REFILL_CONTAINERS if item.startswith(prefix)), None)


def _is_song(item):
    return item.startswith("Melody_")


def _dungeon_item_type(item):
    if item.startswith("Dungeon_SmallKey"):
        return "small_keys"
    if item.startswith("Dungeon_BossKey"):
        return "boss_keys"
    if item.startswith(("Dungeon_Map", "Dungeon_Compass")):
        return "maps_compasses"
    return None


class Plan:
    """Which locations are shuffled and which items go into the pool."""

    def __init__(self, world, st, seed_key=""):
        self.world, self.st, self.seed_key = world, st, seed_key
        self.rules = {l.id: L.location_rule(l) for l in world.locations}
        self._choose_shop_slots(seed_key)
        self._choose_scrub_prices(seed_key)
        self.fixed, self.shuffled = {}, []
        self.forced = {}      # unshuffled locations that still get a different item (patched like placements)
        excluded = set(st["excluded_locations"])
        for loc in world.locations:
            if self._is_shuffled(loc):
                self.shuffled.append(loc)
            else:
                self.fixed[loc.id] = loc.vanilla
                if loc.vanilla == "Bottle_Letter" and st["open_zora"] == "open":
                    # King Zora is already moved: the letter would be a dead item, give an empty bottle
                    self.fixed[loc.id] = self.forced[loc.id] = "Bottle"
        self.excluded = {l.id for l in self.shuffled if l.id in excluded or l.name in excluded}
        self.start_locs = set(START_LOCATIONS) if st["skip_child_zelda"] else set()
        self._grantable = {}
        self.pool = [l.vanilla for l in self.shuffled]
        self._adjust_pool()

    def _choose_shop_slots(self, seed_key):
        """Items Shuffled Per Shop (OotrR): N shelves per shop (1 to 4 at random with "random"), 10 rupees each,
        keeping one copy on sale of every shelf in SHOP_KEEP_ONE."""
        self.shop_chosen, self.shop_prices = set(), {}
        mode = self.st["shopsanity"]
        if mode == "off":
            return
        rng = random.Random(hashlib.sha256(("shops|" + seed_key).encode()).digest())
        by_shop = defaultdict(list)
        for loc in self.world.locations:
            if loc.kind == "shop":
                by_shop[loc.shop].append(loc)
        copies = Counter(l.vanilla_actor for slots in by_shop.values() for l in slots)
        for shop in sorted(by_shop):
            wanted = rng.randint(1, 4) if mode == "random" else int(mode)
            slots = sorted(by_shop[shop], key=lambda l: l.id)
            rng.shuffle(slots)
            for loc in slots:
                if wanted <= 0:
                    break
                if loc.id in getattr(self.world, "shop_conditional", ()):
                    continue                  # its own story condition (Presence) would clash with sold-out
                if loc.vanilla_actor in SHOP_KEEP_ONE and copies[loc.vanilla_actor] <= 1:
                    continue
                copies[loc.vanilla_actor] -= 1
                self.shop_chosen.add(loc.id)
                self.shop_prices[loc.id] = self._price(self.st.get("shop_prices", "low"), "shop", seed_key, loc,
                                                       SHOP_PRICE, step=5)
                wanted -= 1
        for lid, price in self.shop_prices.items():
            self._needs_wallet(lid, price)

    @staticmethod
    def _price(mode, what, seed_key, loc, low, step=1, regular=None):
        """A price for `mode`: low, regular (the game's), random (10-99) or random_wallet (10-200)."""
        if mode == "regular" and regular is not None:
            return regular
        if mode in ("random", "random_wallet"):
            top = CHILD_WALLET if mode == "random" else ADULT_WALLET
            digest = hashlib.sha256(("%s-price|%s|%s" % (what, seed_key, loc.id)).encode()).digest()
            n = int.from_bytes(digest[:8], "big")
            if step > 1:
                return low + step * (n % ((top - low) // step + 1))
            return low + n % (top - low + 1)
        return low

    def _needs_wallet(self, lid, price):
        """A price above 99 rupees needs the Adult's Wallet (or the Giant's)."""
        if price > CHILD_WALLET:
            base = self.rules[lid]
            self.rules[lid] = lambda s, b=base: b(s) and (s.has("Wallet_Medium") or s.has("Wallet_Large"))

    def _choose_scrub_prices(self, seed_key):
        """Business Scrubs: each shuffled scrub's price, and the wallet it needs when that is above 99."""
        self.scrub_prices = {}
        if not self.st.get("shuffle_scrubs"):
            return
        mode = self.st.get("scrub_prices", "low")
        for loc in self.world.locations:
            if loc.category != "scrub":
                continue
            game = max((pr for _, _, pr in loc.price_refs), default=SCRUB_LOW_PRICE)
            price = self._price(mode, "scrub", seed_key, loc, SCRUB_LOW_PRICE, regular=game)
            self.scrub_prices[loc.id] = price
            self._needs_wallet(loc.id, price)

    def _is_shuffled(self, loc):
        st, item = self.st, loc.vanilla
        if loc.kind == "shop":
            return loc.id in self.shop_chosen
        dtype = _dungeon_item_type(item)
        if dtype:
            if st[dtype] == "vanilla":
                return False
            if loc.kind == "freestanding" and not st["shuffle_freestanding"] and st[dtype] == "vanilla":
                return False
            return True
        if item == "Sword_Kokiri" and not st["shuffle_kokiri_sword"]:
            return False
        if item in UPGRADES and not loc.upgrade_ok:
            return False
        if item == "WeirdEgg" and not st["shuffle_weird_egg"]:
            return False
        if item in ALWAYS_VANILLA:
            return False
        if loc.category == "ocarina":
            return st["shuffle_ocarinas"]
        cat = loc.category
        if cat == "song":
            return st["shuffle_songs"] != "vanilla"
        if cat == "reward":
            return st["shuffle_rewards"] != "vanilla"
        if cat == "npc":
            return st["shuffle_npc"]
        if cat == "quest":
            return st["shuffle_quest"]
        if cat == "scrub":
            return bool(st["shuffle_scrubs"])
        if cat == "egg":
            return True                      # Shuffle Weird Egg (checked above)
        if cat == "fairy":
            return st["shuffle_fairies"]
        if cat == "house":
            return st["shuffle_house"]
        if cat == "gs":
            t = st["tokensanity"]
            return t == "all" or (t == "dungeons" and loc.dungeon) or (t == "overworld" and not loc.dungeon)
        if cat == "freestanding":
            return st["shuffle_freestanding"]
        if cat == "rupee":
            return st["shuffle_rupees"]
        if cat == "heart_container":
            return st["shuffle_heart_containers"]
        return cat == "chest"

    def _adjust_pool(self):
        st = self.st
        if st["open_zora"] == "open":
            # Ruto's Letter can't be delivered with an open Fountain; an empty bottle takes its place
            self.pool = ["Bottle" if i == "Bottle_Letter" else i for i in self.pool]
        if st["shuffle_house"]:
            self.pool = [PROGRESSIVE_WALLET if i == "Wallet_Large" else i for i in self.pool]
        if st["shuffle_ocarinas"]:
            # Saria's bridge gift is switched off (gamedata.planned_changes); her Fairy Ocarina replaces junk
            rng = random.Random(hashlib.sha256(("ocarina|" + self.seed_key).encode()).digest())
            junk = sorted(i for i, x in enumerate(self.pool) if x in JUNK)
            if junk:
                self.pool[rng.choice(junk)] = "Ocarina_Fairy"
            else:
                self.pool.append("Ocarina_Fairy")
        if st["maps_compasses"] == "remove":
            self.pool = ["Rupee_Blue" if _dungeon_item_type(i) == "maps_compasses" else i for i in self.pool]
        elif st["maps_compasses"] == "start_with":
            # the save already has them (gamedata.planned_changes); their checks get a random bonus
            rng = random.Random(hashlib.sha256(("start_maps|" + self.seed_key).encode()).digest())
            items, weights = zip(*START_WITH_BONUS)
            self.pool = [rng.choices(items, weights)[0] if _dungeon_item_type(i) == "maps_compasses" else i
                         for i in self.pool]
        if st["item_pool"] in ("scarce", "minimal"):
            seen = Counter()
            new = []
            for i in self.pool:
                if i in ("Heart_Piece", "Heart_Container"):
                    seen[i] += 1
                    if st["item_pool"] == "minimal" or seen[i] % 2 == 0:
                        i = "Rupee_Red"
                new.append(i)
            self.pool = new

    def grantable(self, item):
        """Skip Child Zelda: can a new save simply own `item` (its 'obtained' flag plus a pouch count of 1)?"""
        if item not in self._grantable:
            ok = "@" not in item and item not in REWARDS and not item.startswith(START_DENY_PREFIXES)
            if ok and not _is_song(item):
                from . import gamedata
                try:
                    ok = gamedata.pouch_entry_exists(self.world, self.world.actor_for(item, "event"))
                except KeyError:
                    ok = False
            self._grantable[item] = ok
        return self._grantable[item]

    def sold_once(self, item):
        """Can a shelf sell `item` once? A bought shelf is hidden by its item's IsGet flag (write_patches), so the
        item must exist once in the seed (a second Piece of Heart found elsewhere would hide an unbought shelf)
        and have that flag."""
        cache = self.__dict__.setdefault("_sold_once", {})
        if item not in cache:
            copies = self.__dict__.get("_copies")
            if copies is None:
                copies = self._copies = Counter(self.pool) + Counter(self.fixed.values())
            try:
                actor = self.world.actor_for(item, "event")
                # bottles: filling an empty bottle (milk, fish, ...) may set the same flag and hide an unbought shelf
                cache[item] = (copies[item] <= 1 and not item.startswith("Bottle") and self.world.actor_exists(actor)
                               and gamedata.isget_exists(self.world, actor))
            except KeyError:
                cache[item] = False
        return cache[item]

    # which shuffled locations may receive `item`
    def allowed(self, loc, item):
        st = self.st
        if loc.id in self.excluded and (item in L.PROGRESSION or _dungeon_item_type(item) or item in REWARDS):
            return False
        if loc.id in self.start_locs and not self.grantable(item):
            return False
        if item == PROGRESSIVE_WALLET and loc.kind != "chest":
            return False
        if loc.kind == "gs" and (item in GS_FORBIDDEN or gs_refuses(self.world, item)):
            return False
        is_reward_loc, is_song_loc = loc.category == "reward", loc.category == "song"
        if st["shuffle_rewards"] != "anywhere":
            if item in REWARDS:
                return is_reward_loc
            if is_reward_loc:
                return False
        if _is_song(item):
            if st["shuffle_songs"] == "song":
                return is_song_loc
        elif is_song_loc and st["shuffle_songs"] == "song":
            return False
        if item == "Range_SlingShot" and st["open_forest"] == "closed":
            # the Deku Tree needs it and a closed forest cannot be left before the Deku Tree is done
            if not L.is_deku_slingshot_chest(loc) and (loc.dungeon or loc.region not in L.FOREST_REGIONS):
                return False
        if "@" in item:                       # dungeon items stay in their own dungeon
            if loc.dungeon != item.split("@")[1]:
                return False
            # Boss keys, maps and compasses only count for the dungeon when a chest's opening gives them (its
            # EventGetDungeonBossKey / Map / Compass, rando/qol.py patch_small_chest_dungeon_items); a pickup
            # only puts them in the pouch. The boss Heart Container is also behind the boss door.
            if _dungeon_item_type(item) in ("boss_keys", "maps_compasses"):
                return loc.kind == "chest"
            return True
        if loc.kind == "shop":                # a shelf needs a pouch actor with its own pack
            if item in JUNK:
                return True                   # the shelf keeps its normal goods
            if item in SHOP_FORBIDDEN or item in REWARDS:
                return False
            return self.sold_once(item)
        return True


class Filler:
    def __init__(self, plan, rng):
        self.plan, self.rng = plan, rng
        self.locs = {l.id: l for l in plan.world.locations}
        self.placed = {}
        self.no_logic = plan.st["logic_rules"] == "none"

    def contents(self):
        out = dict(self.plan.fixed)
        out.update(self.placed)
        return out

    def sweep(self, base_items, contents=None):
        """Collect everything reachable starting from base_items. Returns (state, collected_ids, spheres)."""
        contents = self.contents() if contents is None else contents
        s = L.State(base_items)
        got, spheres = set(), []
        pending = [lid for lid in contents]
        while True:
            new = [lid for lid in pending if lid not in got and self.plan.rules[lid](s)]
            if not new:
                break
            spheres.append(new)
            for lid in new:
                got.add(lid)
                s.items[contents[lid]] += 1
            s._c.clear()
            pending = [lid for lid in pending if lid not in got]
        return s, got, spheres

    def place_group(self, items, unplaced_rest, tries=25):
        """Assumed fill for `items`, retried locally (a fresh order each time) before giving up."""
        snapshot = dict(self.placed)
        for t in range(tries):
            try:
                return self._place_group(items, unplaced_rest)
            except GenerationError:
                self.placed = dict(snapshot)
                if t == tries - 1:
                    raise

    def _place_group(self, items, unplaced_rest):
        items = list(items)
        self.rng.shuffle(items)
        # most constrained first: higher-tier items, then other progression, then the rest
        items.sort(key=lambda i: 0 if i in L.LOWER_TIER else (1 if i in L.PROGRESSION else 2))
        remaining = list(items)
        for item in items:
            remaining.remove(item)
            empty = [l for l in self.plan.shuffled if l.id not in self.placed and self.plan.allowed(l, item)]
            if not empty:
                raise GenerationError("no free location can hold %s" % item)
            if self.no_logic or item not in L.PROGRESSION:
                cands = empty
            else:
                base = [i for i in remaining + unplaced_rest if i in L.PROGRESSION]
                state, got, _ = self.sweep(base)
                cands = [l for l in empty if self.plan.rules[l.id](state)]
                lower = L.LOWER_TIER.get(item)
                if lower and cands:
                    # without the lower tier and without other copies of this item (e.g. two Bigger Bomb Bags)
                    without = L.State(i for i in state.items.elements() if i not in (lower, item))
                    tiered = [l for l in cands if not self.plan.rules[l.id](without)]
                    if not tiered:
                        raise GenerationError("no location for %s that requires %s" % (item, lower))
                    cands = tiered
                if not cands:
                    raise GenerationError("no reachable location for %s" % item)
            loc = self.rng.choice(cands)
            self.placed[loc.id] = item

    def run(self):
        plan = self.plan
        pool = list(plan.pool)
        anywhere = plan.st["shuffle_rewards"] == "anywhere"
        groups = [
            [i for i in pool if "@" in i],
            [] if anywhere else [i for i in pool if i in REWARDS],
            [i for i in pool if _is_song(i)],
        ]
        used = Counter()
        for g in groups:
            used.update(g)
        rest = list((Counter(pool) - used).elements())
        prog_rest = [i for i in rest if i in L.PROGRESSION]
        junk_rest = [i for i in rest if i not in L.PROGRESSION]
        later = groups[1] + groups[2] + prog_rest
        # dungeon items first (they are the most constrained), then rewards, songs, other progression
        self.place_group(groups[0], [i for i in later if i in L.PROGRESSION])
        self.place_group(groups[1], [i for i in groups[2] + prog_rest if i in L.PROGRESSION])
        self.place_group(groups[2], [i for i in prog_rest if i in L.PROGRESSION])
        self.place_group(prog_rest, [])
        self.rng.shuffle(junk_rest)
        for lid in sorted(plan.start_locs):
            # Skip Child Zelda: fill an empty start check with junk the save can grant (a shield, Farore's Wind...)
            loc = self.locs[lid]
            if lid in self.placed or loc not in plan.shuffled:
                continue
            item = next((i for i in junk_rest if plan.allowed(loc, i)), None)
            if item is not None:
                junk_rest.remove(item)
                self.placed[lid] = item
                continue
            # No grantable junk left (e.g. Shopsanity took the shields): move a grantable item placed elsewhere
            # here and give its spot a junk item. A start item is owned from the beginning, so moving even a
            # progression item here only makes it available earlier and the seed stays beatable.
            for other_id in sorted(self.placed, key=lambda _: self.rng.random()):
                other = self.locs[other_id]
                moved = self.placed[other_id]
                if other_id in plan.start_locs or moved in L.LOWER_TIER or not plan.allowed(loc, moved):
                    continue
                junk = next((i for i in junk_rest if plan.allowed(other, i)), None)
                if junk is None:
                    continue
                junk_rest.remove(junk)
                self.placed[lid], self.placed[other_id] = moved, junk
                break
            else:
                raise GenerationError("no item the save can grant for %s" % loc.name)
        empty = [l for l in plan.shuffled if l.id not in self.placed]
        junk_rest.sort(key=lambda i: 0 if i in SHOP_FORBIDDEN else 1)   # restricted junk first
        self.rng.shuffle(empty)
        refills = plan.st.get("refill_needs_item")
        # some junk can't go on a Gold Skulltula (gs_refuses): keep enough other spots free for it
        junk_left = sum(1 for i in junk_rest if gs_refuses(plan.world, i))
        for item in junk_rest:
            spot = None
            if gs_refuses(plan.world, item):
                junk_left -= 1
            else:
                free = sum(1 for l in empty if l.id not in self.placed and l.kind != "gs")
                if free <= junk_left:
                    spot = next((l for l in empty if l.id not in self.placed and l.kind == "gs"
                                 and plan.allowed(l, item)), None)
            if spot is None and item in PROGRESSIVE_UPGRADES:
                # chests make repeat copies progressive (see write_patches); prefer them
                spot = next((l for l in empty if l.id not in self.placed and l.kind == "chest"
                             and plan.allowed(l, item)), None)
            elif spot is None and refills and refill_container(item):
                # only chests can check for the container; elsewhere the refill becomes a blue rupee
                spot = next((l for l in empty if l.id not in self.placed and l.kind == "chest"
                             and plan.allowed(l, item)), None)
                if spot is None:
                    item = REFILL_FALLBACK
            if spot is None:
                spot = next((l for l in empty if l.id not in self.placed and plan.allowed(l, item)), None)
            if spot is None and gs_refuses(plan.world, item):
                # only Skulltula spots are left: move a placed item that unlocks nothing (a Piece of Heart, ...)
                # onto one, and put the junk where it was; moving such an item can't change the logic
                gs_free = [l for l in empty if l.id not in self.placed and l.kind == "gs"]
                for other_id in sorted(self.placed, key=lambda _: self.rng.random()):
                    other, moved = self.locs[other_id], self.placed[other_id]
                    if (other.kind == "gs" or other_id in plan.start_locs or moved in L.PROGRESSION
                            or moved in JUNK or not plan.allowed(other, item)):
                        continue
                    g = next((l for l in gs_free if plan.allowed(l, moved)), None)
                    if g is not None:
                        self.placed[g.id] = moved
                        spot = other
                        break
                else:
                    # more junk than other spots (a scarce item pool, maps in their own dungeon, ...): the Skulltula
                    # keeps its own token instead; an extra token only makes the Skulltula House easier
                    g = next((l for l in gs_free if plan.allowed(l, "Token_Gold")), None)
                    if g is not None:
                        spot, item = g, "Token_Gold"
            if spot is None:
                left = Counter(l.kind for l in empty if l.id not in self.placed)
                raise GenerationError("no location left for %s (empty: %s)" % (
                    item, ", ".join("%d %s" % (n, k) for k, n in sorted(left.items())) or "none"))
            self.placed[spot.id] = item


def _seed_rng(seed, settings_string):
    h = hashlib.sha256(("%s|%s|%s" % (VERSION, seed, settings_string)).encode()).digest()
    return random.Random(int.from_bytes(h[:8], "little"))


def generate(romfs, out_dir, settings, seed=None, mod_name=None, progress=print, world=None, exefs=None):
    from .gamecheck import check as check_game
    game = check_game(exefs, romfs)
    if not game.ok:
        raise GenerationError(game.message)
    progress(game.message)
    st = S.normalize(settings)
    L.set_options(st)
    sstr = S.to_string(st)
    if not seed:
        seed = "".join(random.choice("ABCDEFGHJKLMNPQRSTUVWXYZ23456789") for _ in range(10))
    seed = str(seed)
    t0 = time.time()
    world = world or World(romfs, progress)
    progress("Building item pool...")
    plan = Plan(world, st, seed_key="%s|%s|%s" % (VERSION, seed, sstr))

    # locations no item set can reach are treated as excluded (they only get junk)
    filler = Filler(plan, random.Random(0))
    everything = [i for i in plan.pool if i in L.PROGRESSION] + list(plan.fixed.values())
    full_state, _, _ = filler.sweep(everything, contents={})
    unreachable = [l for l in plan.shuffled if not plan.rules[l.id](full_state)]
    if unreachable and st["logic_rules"] != "none":
        progress("note: %d location(s) are out of logic and will only hold junk" % len(unreachable))
        plan.excluded |= {l.id for l in unreachable}

    rng = _seed_rng(seed, sstr)
    last_err = None
    for attempt in range(1, 41):
        progress("Placing items (attempt %d)..." % attempt)
        filler = Filler(plan, random.Random(rng.random()))
        try:
            filler.run()
        except GenerationError as e:
            last_err = e
            continue
        if st["logic_rules"] == "none":
            break
        state, got, spheres = filler.sweep([])
        if not state.win:
            last_err = GenerationError("seed not beatable")
            continue
        if st["reachable_locations"] == "all":
            missing = [l for l in plan.shuffled if l.id not in got and l.id not in plan.excluded]
            if missing:
                last_err = GenerationError("%d locations unreachable" % len(missing))
                continue
        break
    else:
        raise GenerationError("could not place items after 40 attempts: %s" % last_err)

    plan.hints = []
    if st["hint_distribution"] != "none":
        progress("Choosing hints...")
        plan.hints = H.choose(world, plan, filler, seed, world.zs.read, st["hint_distribution"],
                              mask=st["gossip_stones"] == "mask")

    mod_name = mod_name or longshot.MOD_PREFIX + seed
    mod_root = os.path.join(out_dir, mod_name)
    # The game files are only ever read: every patched file is written to the mod folder. Refuse an output
    # folder inside a romfs folder (the GUI checks this too), so a mistake can never write into the game files.
    # A .nup is a single file opened read-only, so there is nothing to protect there.
    if world.files.kind == "folder":
        game, mod = os.path.realpath(world.files.romfs), os.path.realpath(mod_root)
        if os.path.splitdrive(game)[0].lower() == os.path.splitdrive(mod)[0].lower() and \
                os.path.commonpath([game, mod]).lower() == game.lower():
            raise GenerationError("The output folder must not be inside the romfs folder.")
    progress("Writing mod files...")
    written = write_patches(world, plan, dict(plan.forced, **filler.placed), os.path.join(mod_root, "romfs"), progress)
    if st["create_spoiler"]:
        write_spoiler(world, plan, filler, seed, sstr, mod_root)
        from .checklist import write_checklist      # contains every placement, so only with the spoiler
        try:
            write_checklist(world, plan, filler, mod_root, VERSION, seed, sstr)
        except ImportError:
            progress("note: checklist.xlsx skipped (openpyxl missing; run Setup (Windows).bat or setup_linux.sh)")
    with open(os.path.join(mod_root, "settings.txt"), "w", encoding="utf-8") as fh:
        fh.write(NAME + " %s\nSeed: %s\nSettings string: %s\n" % (VERSION, seed, sstr))
    if longshot.is_mods_folder(out_dir):
        # Longshot loads every mod in its mods folder; two seeds at once would mix, so switch the others off
        for old, new in longshot.switch_off_other_seeds(out_dir, mod_name):
            progress("Longshot: switched off the older seed %s (renamed to %s)" % (old, new))
        left = longshot.active_seeds(out_dir, mod_name)
        if left:
            progress("WARNING: Longshot would load these seeds too, and they couldn't be renamed (close the game "
                     "first, then put _ in front of their names): %s" % ", ".join(left))
    progress("Done in %.1fs: %d files written to %s" % (time.time() - t0, len(written), mod_root))
    return {"seed": seed, "settings_string": sstr, "mod_root": mod_root, "files": written,
            "placements": filler.placed}


# --------------------------------------------------------------------------- patching
def write_patches(world, plan, placed, out_romfs, progress=print):
    zs = world.zs
    locs = {l.id: l for l in world.locations}
    stage_edits = defaultdict(list)   # rel -> [(hash, loc, item)]
    event_edits = defaultdict(list)   # rel -> [(offset, actor)]
    refills = plan.st.get("refill_needs_item")
    for lid, item in placed.items():
        loc = locs[lid]
        needs = refill_container(item) if refills and loc.kind == "chest" else None
        if item == loc.vanilla and not loc.conditional and not needs:
            continue
        if loc.kind == "shop" and item in JUNK:
            continue                          # junk on a shelf: the shelf keeps its normal goods
        for rel, h in loc.stage_refs:
            stage_edits[rel].append((h, loc, item))
        for rel, off in loc.event_refs:
            event_edits[rel].append((off, world.actor_for(item, "event")))

    rt_rel = world._find("System/Resource", "ResourceSizeTable")
    rt_raw, rt_dict = zs.read(rt_rel)
    restbl = F.Restbl(rt_raw)
    current = {}      # rel -> [latest bytes, zstd dict name, compressed?]
    orig_len = {}     # rel -> size of the untouched original (for the size table)

    def read(rel):
        """Latest version of a file: an earlier patch's output if any, else the romfs original."""
        if rel in current:
            return current[rel][0], current[rel][1]
        if rel.endswith(".zs"):
            return zs.read(rel)
        return world.files.read(rel), None

    def emit(rel, orig, new, dict_name, compressed=True):
        if rel not in orig_len:
            orig_len[rel] = len(orig) if rel not in current else len(read(rel)[0])
        current[rel] = [new, dict_name, compressed]

    # items lying in the world need a real pickup actor (see rando/pickups.py)
    pickups = PickupCloner(world, read, emit, restbl, progress)

    for rel, edits in sorted(stage_edits.items()):
        orig, dname = read(rel)
        root = F.byml_load(orig)
        by_hash = defaultdict(list)
        for h, loc, item in edits:
            by_hash[h].append((loc, item))
        hits = 0
        for a in root.get("Actors", []):
            for loc, item in by_hash.get(int(a["Hash"]), []):
                hits += 1
                if loc.kind == "chest":
                    dyn = a.setdefault("Dynamic", {})
                    if dyn.get("GetEventName") in ITEM_GET_EVENTS and item != loc.vanilla:
                        # the chest's own event hands out its vanilla item again (unsaved), so drop it
                        del dyn["GetEventName"]
                    if item in PROGRESSIVE_UPGRADES:
                        bigger, biggest = PROGRESSIVE_UPGRADES[item]
                        if world.actor_exists(bigger) and world.actor_exists(biggest):
                            dyn["Drop__DropActor"] = bigger
                            dyn["Drop__CheckActor"] = bigger
                            dyn["Drop__DropActor_Substitute"] = biggest
                            continue
                    needs = refill_container(item) if refills else None
                    if needs and world.actor_exists(needs):
                        # the game's own conditional chest: owns CheckActor -> Substitute, else DropActor
                        dyn["Drop__DropActor"] = world.actor_for(REFILL_FALLBACK, "chest")
                        dyn["Drop__CheckActor"] = needs
                        dyn["Drop__DropActor_Substitute"] = world.actor_for(item, "chest")
                        continue
                    dyn["Drop__DropActor"] = world.actor_for(item, "chest")
                    dyn.pop("Drop__CheckActor", None)
                    dyn.pop("Drop__DropActor_Substitute", None)
                elif loc.kind == "shop":
                    # a new shelf actor that sells the item once, at its price (rando/pickups.py, OotrR)
                    actor = world.actor_for(item, "event")
                    a["Gyaml"] = pickups.shop_actor(actor, plan.shop_prices[loc.id])
                    # sold once: the shelf is gone once the item is owned (its IsGet flag; Plan.sold_once)
                    a["Presence"] = {"FlagName": "IsGet." + actor, "IsCheckLazy": False, "IsNegation": True}
                elif loc.kind == "gs":
                    # a token-based pickup: floats like a token, is collected by touch, and sets the Skulltula's
                    # save flag when collected (rando/pickups.py, TOKEN_TEMPLATE). Consumables are the game's own
                    # pickup, which falls (GS_FLOATING_JUNK above)
                    drop = None
                    if item in JUNK and item not in GS_FLOATING_JUNK:
                        drop = native_drop(world, item)
                    a.setdefault("Dynamic", {})["Drop__DropActor"] = drop or pickups.token_actor(
                        world.actor_for(item, "event"))
                else:
                    # an unchanged vanilla pickup keeps its own actor (and its own A/walk-over behaviour)
                    a["Gyaml"] = pickups.world_actor(world.actor_for(item, "world"), auto=item != loc.vanilla)
        if hits != len(edits):
            raise GenerationError("%s: expected %d actors, patched %d" % (rel, len(edits), hits))
        emit(rel, orig, F.byml_dump(root), dname)

    if plan.st.get("gs_any_time"):
        # after the item edits: a Skulltula copied for child Link carries its shuffled drop
        patch_gs_any_time(world, emit, progress, read)

    if plan.st["maps_compasses"] == "own" or plan.st["boss_keys"] == "own":
        # a map, compass or boss key can end up in a small chest, whose opening didn't credit the dungeon
        patch_small_chest_dungeon_items(world, emit, progress, read)

    # Business Scrubs: the price of each shuffled scrub's purchase calls
    for loc in plan.shuffled:
        price = getattr(plan, "scrub_prices", {}).get(loc.id)
        if price is not None:
            for rel, off, _vanilla in loc.price_refs:
                event_edits[rel].append((off, int(price)))
    for rel, edits in sorted(event_edits.items()):
        orig, dname = read(rel)
        ev = F.EvflFile(orig)
        for off, actor in edits:
            if isinstance(actor, int):
                ev.set_int_param(off, actor)
            else:
                ev.set_string_param(off, actor)
        F.EvflFile(ev.data())          # sanity: must still parse
        emit(rel, orig, ev.data(), dname)

    if getattr(plan, "hints", None):
        H.write_text(world, plan.hints, read, emit, progress)

    # Business Scrubs: a sale line of its own for each shuffled scrub, naming the item it sells
    scrub_events = {spec["name"]: [ev for ev, *_ in spec["events"]] for spec in EVENT_LOCATIONS
                    if spec.get("category") == "scrub"}
    scrubs = [(scrub_events[loc.name], world.item_name(placed[loc.id])) for loc in plan.shuffled
              if loc.category == "scrub" and loc.id in placed and loc.name in scrub_events]
    if scrubs:
        try:
            scrubtext.write(world, scrubs, read, emit, progress)
        except scrubtext.ScrubTextError as e:
            progress("warning: Business Scrub text not changed (%s); the scrubs still sell their random items" % e)

    # flow edits that add events (rando/faststart.py); after the item edits above, on the latest version
    flow_edits = []
    if plan.st.get("gossip_stones") == "no_mask":
        flow_edits.append(("Gossip Stones: No Mask of Truth", H.GOSSIP_FLOW, H.stones_without_mask))
    if plan.st.get("skip_opening"):
        flow_edits.append(("Skip Opening Movie", faststart.OPENING_FLOW, faststart.opening_without_movie))
    # every seed: a new game starts outside the Kokiri Shop, without Navi's flight and wake-up scene
    flow_edits.append(("New game start", faststart.OPENING_FLOW, faststart.start_outside))
    if plan.st.get("skip_deku_talk") and plan.st["open_forest"] != "open":
        flow_edits.append(("Skip the Great Deku Tree's Talk", faststart.MIDO_FLOW, faststart.complete_deku_meeting))
    if plan.st.get("quick_chests"):
        flow_edits.append(("Chests Without Cutscene", faststart.CHEST_FLOW, faststart.quick_chest))
    if plan.st.get("skip_epona_race"):
        flow_edits.append(("Skip Epona Race", faststart.EPONA_SONG_FLOW, faststart.epona_without_race))
    for what, rel, edit in flow_edits:
        orig, dname = read(rel)
        try:
            new = edit(orig)
        except (ValueError, KeyError, IndexError) as e:
            raise GenerationError("%s: %s is not as expected in this romfs (%s); turn the setting off" % (what, rel, e))
        emit(rel, orig, new, dname)
        progress("%s: %s changed" % (what, rel.rsplit("/", 1)[1]))

    if plan.st.get("skip_story_scenes"):
        # after the item edits: a skipped scene's item (read from the patched scene) is the randomized one
        storyskip.patch_story_scenes(world, read, emit, progress, lambda f: gamedata.bool_exists(world, f))
    if plan.st.get("skip_area_intros"):
        # the intros whose arrival also advances a quest (the others count as played in the save data)
        storyskip.patch_area_intros(world, read, emit, progress, lambda f: gamedata.bool_exists(world, f))
    if plan.st.get("skip_ganon_trials"):
        # after the story / area skips, which change the same flow
        try:
            patch_ganon_trials(world, emit, progress, read)
        except (ValueError, KeyError, IndexError) as e:
            raise GenerationError("Skip Ganon's Trials: Defeat_Ganon is not as expected (%s); turn the setting off" % e)

    if plan.st["shuffle_songs"] == "anywhere":
        n = patch_song_models(world, read, emit, restbl, progress)
        progress("Songs Anywhere: %d songs show Sheik's harp in chests, gifts and shops" % n)
    pickups.finish()          # world pickups and shelves: RSDB rows and size-table entries

    if plan.st.get("bag_bombs_no_bracelet"):
        # Bag bombs share one LiftableParam resource path; every pack that carries a copy must agree,
        # otherwise whichever pack loads first decides. Bomb flowers keep their own (bracelet) grade.
        for rel in BOMB_PACKS:
            if not world.files.exists(rel):
                continue
            orig, dname = read(rel)
            r0, r1 = F.sarc_file_ranges(orig)[BOMB_LIFT_PARAM]
            sub = orig[r0:r1]
            if F.byml_load(sub).get("LiftGrade") != BRACELET_GRADE:
                continue
            new_sub = F.byml_patch_root_u32(sub, "LiftGrade", DEFAULT_GRADE)
            emit(rel, orig, orig[:r0] + new_sub + orig[r1:], dname)

    bridge_ok = bool(plan.st["shuffle_ocarinas"]) and patch_ocarina_bridge(world, emit, progress, read)
    start_items = [world.actor_for(placed.get(lid, plan.fixed.get(lid)), "event")
                   for lid in sorted(plan.start_locs) if placed.get(lid, plan.fixed.get(lid))]
    # ocarinas need the game's own pouch action (it records which ocarina Link holds): added in the opening
    # (faststart.give_at_start) instead of as save-data defaults
    start_by_event = [a for a in start_items if a in faststart.START_BY_EVENT]
    start_items = [a for a in start_items if a not in faststart.START_BY_EVENT]
    gd_ok = gamedata.apply(world, plan.st, read, emit, progress, ocarina_bridge_patched=bridge_ok,
                           start_items=start_items)
    if start_by_event:
        rel = faststart.START_ITEM_FLOW
        orig, dname = read(rel)            # after Skip Opening Movie's edit of the same flow, if any
        try:
            new = faststart.give_at_start(start_by_event)(orig)
        except (ValueError, KeyError, IndexError) as e:
            raise GenerationError("Starting ocarina: %s is not as expected in this romfs (%s)" % (rel, e))
        emit(rel, orig, new, dname)
        progress("Starting ocarina: %s added when a new game starts" % ", ".join(start_by_event))

    if plan.st.get("saria_song_ocarina"):
        if gd_ok:
            patch_saria_song(world, emit, progress, read, gamedata.SARIA_GATE_OLD, gamedata.SARIA_GATE_NEW)
        else:
            progress("warning: could not add the ocarina save flag; Saria's Song still needs Zelda")

    if plan.st["open_forest"] == "open":
        patch_open_forest_mido(world, emit, progress, read)
    if plan.st["skip_child_zelda"]:
        patch_kokiri_schedules(world, emit, progress, read)
    if plan.st["open_zora"] == "open":
        patch_open_zora_arrival(world, emit, progress, read, gamedata.ZORA_OPEN_QUEST[1])
    if plan.st["open_door"] == "open" and not patch_open_door(world, emit, progress, read):
        raise GenerationError("Door of Time: Open could not be applied to this romfs; set the Door of Time to Closed")
    if plan.st["shuffle_songs"] != "vanilla":
        patch_song_teaching(world, emit, progress, read)
    if plan.st["shuffle_weird_egg"]:
        patch_egg_hatch_guard(world, emit, progress, read)


    if plan.st.get("dodongo_bag_bombs") and not patch_dodongo_bag_bombs(world, emit, progress, read):
        # the logic already counted bag bombs for the entrance, so the seed would not be safe
        raise GenerationError("Dodongo's Cavern boulder logic not recognised in this romfs; "
                              "turn off 'Bag Bombs Open Dodongo's Cavern'")

    if plan.st.get("anju_one_cucco"):
        patch_anju(world, emit, progress, read)
    if plan.st.get("big_poe_one"):
        patch_big_poe_one(world, emit, progress, read)

    if plan.st.get("skip_cutscenes"):
        # One shared component blocks skipping (opening, credits, title demos); switch it off.
        rel = SKIP_SETTING
        if world.files.exists(rel):
            orig = read(rel)[0]
            root = F.byml_load(orig)
            if root.get("IsDisableSkip"):
                root["IsDisableSkip"] = False
                emit(rel, orig, F.byml_dump(root), None, compressed=False)
        else:
            progress("warning: cutscene skip setting not found in this romfs; skipped")

    written = []
    for rel, (data, dname, compressed) in sorted(current.items()):
        path = os.path.join(out_romfs, *rel.split("/"))
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as fh:
            fh.write(zs.compress(data, dname) if compressed else data)
        key = rel[:-3] if rel.endswith(".zs") else rel
        old = restbl.get(key)
        if old is not None and len(data) > orig_len[rel]:
            restbl.set(key, old + (len(data) - orig_len[rel]))
        written.append(rel)

    path = os.path.join(out_romfs, *rt_rel.split("/"))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as fh:
        fh.write(zs.compress(restbl.data(), rt_dict))
    written.append(rt_rel)
    return written


# --------------------------------------------------------------------------- spoiler
def write_spoiler(world, plan, filler, seed, sstr, mod_root):
    os.makedirs(mod_root, exist_ok=True)
    contents = filler.contents()
    locs = {l.id: l for l in world.locations}
    _, _, spheres = filler.sweep([])
    playthrough = []
    for i, sph in enumerate(spheres):
        prog = [(locs[l].name, world.item_name(contents[l])) for l in sph
                if contents[l] in L.PROGRESSION and l in filler.placed]
        if prog:
            playthrough.append(sorted(prog))
    by_region = defaultdict(list)
    for loc in plan.shuffled:
        region = world.region_name(loc.region) if loc.region else "Events"
        name = world.item_name(contents[loc.id])
        if loc.kind == "shop":
            if contents[loc.id] == loc.vanilla or contents[loc.id] in JUNK:
                name = "(normal shop goods)"
            else:
                name += "  [%d rupees]" % plan.shop_prices[loc.id]
        elif loc.id in getattr(plan, "scrub_prices", {}):
            name += "  [%d rupees]" % plan.scrub_prices[loc.id]
        by_region[region].append((loc.name, name))
    lines = ["%s %s" % (NAME, VERSION), "Seed: %s" % seed, "Settings string: %s" % sstr, "",
             "Settings:"]
    for k, v in S.normalize(plan.st).items():
        lines.append("  %-28s %s" % (S.SPEC[k][3] + ":", v))
    lines += ["", "Playthrough:"]
    for i, sph in enumerate(playthrough, 1):
        lines.append("  Sphere %d" % i)
        lines += ["    %-55s %s" % x for x in sph]
    hint_list = getattr(plan, "hints", None) or []
    if hint_list:
        lines += ["", "Hints (%s):" % plan.st["hint_distribution"]]
        lines += ["  %-34s %-9s %s" % (h.label, h.kind, H.text(world, h)) for h in hint_list]
    lines += ["", "Locations:"]
    for region in sorted(by_region):
        lines.append("  %s" % region)
        lines += ["    %-55s %s" % x for x in sorted(by_region[region])]
    with open(os.path.join(mod_root, "spoiler.txt"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")
    with open(os.path.join(mod_root, "spoiler.json"), "w", encoding="utf-8") as fh:
        json.dump({"version": VERSION, "seed": seed, "settings_string": sstr, "settings": S.normalize(plan.st),
                   "playthrough": playthrough,
                   "hints": {h.label: {"kind": h.kind, "text": H.text(world, h)} for h in hint_list},
                   "locations": {locs[l].name: world.item_name(i) for l, i in sorted(contents.items(),
                                                                                      key=lambda x: locs[x[0]].name)}},
                  fh, indent=1, ensure_ascii=False)
