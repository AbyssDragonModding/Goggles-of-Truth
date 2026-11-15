"""World pickups for items that only exist as get-demo actors.

Items lying in the world (freestanding spots, rupee spots, boss Heart Container spots, Gold Skulltula drops)
must be Obj_Item_Base actors: those are the ones the player can walk up to and collect. Most key items only
have an Item_* actor (Item_EventObject_Base), which is what the item-get cutscene shows in Link's hands; placed
in the world it just lies there.

For each such item this builds a new actor "Obj_Rando_<item>" cloned from Obj_Arrow_Fire (Lake Hylia's
freestanding Fire Arrows, an Obj_Item_Base pickup that gives a key item):
- pack: the template pack + the item's own component files, a new ActorParam whose model / name / animation /
  parameter-table / effect refs come from the item, and a new PouchContentParam ("PouchActor" = the item);
- RSDB: ActorInfo and GameActorInfo rows cloned from Obj_Arrow_Fire with the item's model fields and
  ActorName (so the pickup uses the item's own text), and a PouchActorInfo row cloned from the item;
- RESTBL: entries for the new pack and the new files inside it.
"""
import bisect
import copy
import os
import zlib

from . import formats as F

TEMPLATE = "Obj_Arrow_Fire"
PREFIX = "Obj_Rando_"
COPIED_REFS = ("ActorNameRef", "ModelInfoRef", "AnimationRef", "GameParameterTableRef", "ELinkRef", "SLinkRef",
               "CaptureRef")
ROW_FROM_ITEM = ("FmdbName", "ModelProjectName", "AnimationResources", "ModelAabbMax", "ModelAabbMin",
                 "ELinkUserName", "SLinkUserName")
HEAP_KEYS = ("InstanceHeapSize", "PreActorRenderInfoHeapSize")

# Songs have no model of their own: Item_Melody_* points at the rupee model as a placeholder (the song-get
# scene never shows it), so a song lying in the world looked like a green rupee. Song pickups borrow Sheik's
# harp (Dm_Item_Sheik_Harp, the model her song scenes use) instead. The name and get text stay the song's.
MODEL_OVERRIDES = {"Item_Melody_": "Dm_Item_Sheik_Harp"}
MODEL_ROW_KEYS = ("FmdbName", "ModelProjectName", "ModelAabbMax", "ModelAabbMin")


def _model_source(src):
    return next((m for prefix, m in MODEL_OVERRIDES.items() if src.startswith(prefix)), src)


def patch_song_models(world, read, emit, restbl, progress=print):
    """Give the song items themselves Sheik's harp model, so a song shows as a harp wherever it is found: chests
    (the chest shows the item actor above Link), character gifts, scrubs, shop shelves and Gold Skulltula drops,
    not only the world pickups built above. Each Item_Melody_* pack has its own ModelInfo file naming the rupee
    model; it gets the harp's ModelInfo, and its ActorInfo row the harp's model fields. The song-teaching scenes
    never show the item's model, so they are unaffected. Returns the number of songs changed."""
    harp = MODEL_OVERRIDES["Item_Melody_"]
    harp_files = F.sarc_files(read(_pack(harp))[0])
    harp_ref = F.byml_load(harp_files[_param(harp)]).get("Components", {}).get("ModelInfoRef")
    if not harp_ref or _ref_file(harp_ref) not in harp_files:
        progress("warning: the harp model was not found; songs keep the rupee model in chests and gifts")
        return 0
    harp_info = harp_files[_ref_file(harp_ref)]
    harp_size = restbl.get(_ref_file(harp_ref))
    songs = sorted(n for n in world.actor_packs if n.startswith("Item_Melody_"))
    changed = []
    for song in songs:
        raw, dname = read(_pack(song))
        files = F.sarc_files(raw)
        ref = F.byml_load(files.get(_param(song), b"")).get("Components", {}).get("ModelInfoRef") \
            if _param(song) in files else None
        path = _ref_file(ref) if ref else None
        if not path or path not in files:
            continue
        if files[path] != harp_info:
            data = F.sarc_rebuild(raw, replace={path: harp_info})
            F.sarc_files(data)                                # sanity: must parse
            emit(_pack(song), raw, data, dname)
            old = restbl.get(path)
            if old is not None and harp_size is not None and harp_size > old:
                restbl.set(path, harp_size)
        changed.append(song)
    if not changed:
        return 0
    rel = world._find("RSDB", "ActorInfo")
    data, dname = read(rel)
    rows = F.byml_load(data)
    by_id = {r["__RowId"]: r for r in rows}
    harp_row = by_id.get(harp)
    if harp_row is None:
        progress("warning: no ActorInfo row for %s; song models only partly changed" % harp)
        return len(changed)
    for song in changed:
        row = by_id.get(song)
        if row is not None:
            for k in MODEL_ROW_KEYS:
                if k in harp_row:
                    row[k] = copy.deepcopy(harp_row[k])
    emit(rel, data, F.byml_dump(rows), dname)
    return len(changed)

# Walk-over pickups. Obj_Item_Base (rupees, small keys, the Ocarina of Time, ...) is collected by touching it
# (AttentionSenderParam "AutoPickUpItem"); Obj_Arrow_Fire, and so every Obj_Rando_ clone, overrides that with
# "PickUpItem", which needs A. Every shuffled item lying in the world (freestanding and rupee spots, Gold
# Skulltula drops) gets an "Obj_RandoAuto_" copy of its pickup with the walk-over setting: a Skulltula on a
# wall drops its item in mid-air, where Link climbing the vine can touch it but can't press A. The setting's
# blackboard flag (IsEnableAttention) is raised by the DropItem AI, so only pickups that run that AI can use
# it: Obj_Heart_Piece and Obj_Bottle_Letter have their own AI and still need A, so they are kept off
# Skulltula drops (generator.GS_FORBIDDEN).
# Gold Skulltula drops are built on the token's own pickup (Obj_Token_Gold), as OotrR does: the drop floats where
# the Skulltula died like a token, is collected by touching it, and keeps the token's AI and blackboard. The
# Skulltula writes its own save flag into the drop's GoldTokenGmdHash and the token AI
# (OneShotGoldTokenDeadAfter) sets it when the drop is collected, so a Skulltula only stays dead once its
# item is picked up. The model, name, animations and contents come from the item; the pouch setting only
# names the item (the token's own pouch values, a 100-token stack, would override the item's).
TOKEN_TEMPLATE = "Obj_Token_Gold"
TOKEN_PREFIX = "Obj_RandoGS_"
TOKEN_REFS = COPIED_REFS + ("ASRef",)
TOKEN_LINKS = ("ELinkRef", "SLinkRef")      # the token's golden aura and hum: the item's own, or none

# Shop shelves (Items Shuffled Per Shop), after OotrR's game/item_forms.py: "Shop_Rando_<item>" is the arrow shelf
# Shop_ArrowBundle_01 (its shop AI, physics and put-in-pouch parameters) with the item's model, name and animations,
# a pouch setting that only names the item, the item's game parameters, its own price, and the NoRespawn save
# setting, so it is bought once. The RSDB rows come from the shelf with the item's model fields; its
# PouchActorInfo row is the item's, with the shelf's price.
SHOP_TEMPLATE = "Shop_ArrowBundle_01"
SHOP_PREFIX = "Shop_Rando_"
SHOP_REFS = ("ModelInfoRef", "AnimationRef", "ActorNameRef", "ASRef")
NO_RESPAWN = "?Component/ActorGameDataSetting/NoRespawn.game__component__ActorGameDataSetting.bgyml"

AUTO_PREFIX = "Obj_RandoAuto_"
AUTO_SOURCE = "Obj_Rupee_Green"
AUTO_ATTENTION = "Component/AttentionSenderParam/AutoPickUpItem.game__component__AttentionSenderParam.bgyml"
AUTO_FILES = (AUTO_ATTENTION,
              "Attention/ClientParam/Auto_Item_Catch.game__attention__ClientParam.bgyml",
              "Attention/ClientParam/LookOnly_Middle_Small.game__attention__ClientParam.bgyml")


def _pack(name):
    return "Pack/Actor/%s.pack.zs" % name


def _param(name):
    return "Actor/%s.engine__actor__ActorParam.bgyml" % name


def _ref_file(ref):
    """'?Component/X/Y.bgyml' -> 'Component/X/Y.bgyml'."""
    return ref.lstrip("?")


def _work_path(file_path):
    """'Component/X/Y.game__x.bgyml' -> 'Work/Component/X/Y.game__x.gyml' (the form $parent / PouchActor use)."""
    return "Work/" + file_path[:-len(".bgyml")] + ".gyml" if file_path.endswith(".bgyml") else file_path


class PickupCloner:
    def __init__(self, world, read, emit, restbl, progress=print):
        self.world, self.read, self.emit, self.restbl, self.progress = world, read, emit, restbl, progress
        self.made = {}          # (source actor, False) -> clone name (or None if it could not be built)
        self.rows = []          # (clone, source) for RSDB
        self.model_src = {}     # clone -> actor whose model it borrows (songs)
        self.auto_rows = []     # (walk-over copy, pickup it copies) for RSDB
        self.prices = {}        # shop shelf clone -> its price (PouchActorInfo)

    @staticmethod
    def needs_clone(actor):
        return not actor.startswith("Obj_")

    def world_actor(self, actor, auto=False):
        """Actor to place in the world for `actor` (a world-context actor name from World.actor_for).
        auto: the pickup must be collected by touching it (a Gold Skulltula drop)."""
        base = actor
        if self.needs_clone(actor):
            if (actor, False) not in self.made:
                self.made[(actor, False)] = self._build(actor)
            base = self.made[(actor, False)] or actor
        if not auto or not base.startswith("Obj_"):
            return base
        if (base, True) not in self.made:
            self.made[(base, True)] = self._build_auto(base)
        return self.made[(base, True)] or base

    def token_actor(self, actor):
        """Gold Skulltula drop for `actor` (the item's event actor): a token-based pickup."""
        if actor == "Item_Token_Gold" or actor == TOKEN_TEMPLATE:
            return TOKEN_TEMPLATE
        if (actor, "token") not in self.made:
            self.made[(actor, "token")] = self._build(actor, TOKEN_TEMPLATE, TOKEN_PREFIX)
        return self.made[(actor, "token")] or self.world_actor(actor, auto=True)

    def shop_actor(self, actor, price):
        """A shelf actor that sells `actor` (the item's event actor) once for `price` rupees."""
        key = (actor, "shop", price)
        if key not in self.made:
            self.made[key] = self._build(actor, SHOP_TEMPLATE, SHOP_PREFIX, price=price)
        if self.made[key] is None:
            raise RuntimeError("no shop shelf could be built for %s" % actor)
        return self.made[key]

    def _build_auto(self, src):
        """Copy of pickup `src` that is collected by walking into it, or None if it already is."""
        raw, dname = self.read(_pack(src))
        files = F.sarc_files(raw)
        if _param(src) not in files:
            return None
        param = F.byml_load(files[_param(src)])
        comps = param.setdefault("Components", {})
        ref = comps.get("AttentionSenderRef")
        if ref is None or "AutoPickUpItem" in ref:
            return None                        # Obj_Item_Base's walk-over setting (or the token's)
        if "AIInfoRef" in comps:
            return None                        # own AI (heart pieces): keeps needing A, kept off Skulltulas
        clone = AUTO_PREFIX + src[len(PREFIX):] if src.startswith(PREFIX) else AUTO_PREFIX + src[len("Obj_"):]
        comps["AttentionSenderRef"] = "?" + AUTO_ATTENTION
        auto_files = F.sarc_files(self.read(_pack(AUTO_SOURCE))[0])
        add = {k: auto_files[k] for k in AUTO_FILES if k not in files and k in auto_files}
        new_param = F.byml_dump(param, version=F.BymlReader(files[_param(src)]).ver)
        add[_param(clone)] = new_param
        data = F.sarc_rebuild(raw, add=add)
        F.sarc_files(data)                                    # sanity: must parse
        self.emit(_pack(clone), data, data, dname)

        pack_size = self.restbl.get(_pack(src)[:-3])
        entries = {
            _pack(clone)[:-3]: None if pack_size is None else pack_size + max(0, len(data) - len(raw)),
            _param(clone): self._size(_param(clone), _param(src), len(new_param) - len(files[_param(src)])),
        }
        for k in add:
            if k not in entries and self.restbl.get(k) is None:
                entries[k] = self._size(k, AUTO_ATTENTION, len(add[k]))
        if entries[_pack(clone)[:-3]] is None:
            # a clone's own pack size was added this run: work it out the way _build did
            entries[_pack(clone)[:-3]] = self._size(_pack(clone)[:-3], _pack(TEMPLATE)[:-3],
                                                    len(data) - len(self.read(_pack(TEMPLATE))[0]))
        for path, size in entries.items():
            if size is not None and self.restbl.get(path) is None:
                if zlib.crc32(path.encode()) in self.restbl.crc:
                    self.progress("warning: size-table hash collision for %s; skipped" % path)
                    continue
                self.restbl.set(path, size)
        self.auto_rows.append((clone, src))
        return clone

    def _size(self, path, fallback_path, delta):
        old = self.restbl.get(path)
        if old is not None:
            return None
        base = self.restbl.get(fallback_path)
        return None if base is None else base + max(0, delta)

    def _build(self, src, template=TEMPLATE, prefix=PREFIX, price=None):
        world = self.world
        token = template == TOKEN_TEMPLATE
        shop = template == SHOP_TEMPLATE
        if not world.files.exists(_pack(src)):
            self.progress("warning: no pack for %s; it can't be made into a world pickup" % src)
            return None
        clone = prefix + src.split("_", 1)[1]
        tmpl_raw, dname = self.read(_pack(template))
        tmpl = F.sarc_files(tmpl_raw)
        item = F.sarc_files(self.read(_pack(src))[0])
        if _param(src) not in item or _param(template) not in tmpl:
            self.progress("warning: %s has no ActorParam; it can't be made into a world pickup" % src)
            return None
        src_param = F.byml_load(item[_param(src)])
        src_comps = src_param.get("Components", {})
        param = F.byml_load(tmpl[_param(template)])
        comps = param.setdefault("Components", {})
        for key in (SHOP_REFS if shop else TOKEN_REFS if token else COPIED_REFS):
            if key in src_comps:
                comps[key] = src_comps[key]
            elif token and key in TOKEN_LINKS:
                comps.pop(key, None)
        model_files = {}
        model_src = _model_source(src)
        if model_src != src:
            m_files = F.sarc_files(self.read(_pack(model_src))[0])
            m_comps = F.byml_load(m_files[_param(model_src)]).get("Components", {})
            ref = m_comps.get("ModelInfoRef")
            if ref and _ref_file(ref) in m_files:
                comps["ModelInfoRef"] = ref
                model_files[_ref_file(ref)] = m_files[_ref_file(ref)]
            else:
                model_src = src

        # pouch content: inherit the item's own settings, but give the item itself
        pouch_tmpl_path = _ref_file(comps["PouchContentRef"])
        pouch = {"DefaultAutoGet": True} if token or shop else F.byml_load(tmpl[pouch_tmpl_path])
        src_pouch_ref = src_comps.get("PouchContentRef")
        if src_pouch_ref:
            pouch["$parent"] = _work_path(_ref_file(src_pouch_ref))
        pouch_actor = "Work/Actor/%s.engine__actor__ActorParam.gyml" % src
        if not src.startswith("Item_") and src_pouch_ref and _ref_file(src_pouch_ref) in item:
            # an Obj_ source's own pouch param already names the item it gives
            pouch_actor = F.byml_load(item[_ref_file(src_pouch_ref)]).get("PouchActor") or pouch_actor
        pouch["PouchActor"] = pouch_actor
        for k in ("IsPickedUpEmitXlinkKey", "PickedUpEmitXlinkKey"):
            pouch.pop(k, None)
        pouch_path = "Component/PouchContentParam/%s.game__component__PouchContentParam.bgyml" % clone
        comps["PouchContentRef"] = "?" + pouch_path

        add = {k: v for k, v in item.items() if k not in tmpl and not k.startswith(("Actor/", "AI/"))}
        if token:
            # the item's game parameters (bag sizes, equipment, ...) plus the pickup's own drop/physics ones
            table_path = "GameParameter/GameParameterTable/%s.engine__actor__GameParameterTable.bgyml" % clone
            base = F.byml_load(tmpl["GameParameter/GameParameterTable/Obj_Item_Base.engine__actor__GameParameterTable.bgyml"])
            src_ref = src_comps.get("GameParameterTableRef")
            table = F.byml_load(item[_ref_file(src_ref)]) if src_ref and _ref_file(src_ref) in item else {}
            table.pop("$parent", None)
            table.setdefault("Category", base.get("Category", "GameParameterTableDefault"))
            merged = dict(base.get("Components", {}))
            merged.update(table.get("Components", {}))
            table["Components"] = merged
            add[table_path] = F.byml_dump(table)
            comps["GameParameterTableRef"] = "?" + table_path
        if shop:
            # the shelf's own parameters (put in pouch) with the item's added, a new price, bought once
            tmpl_table_path = _ref_file(comps["GameParameterTableRef"])
            table = F.byml_load(tmpl[tmpl_table_path])
            src_ref = src_comps.get("GameParameterTableRef")
            src_table = F.byml_load(item[_ref_file(src_ref)]) if src_ref and _ref_file(src_ref) in item else {}
            for k, v in (src_table.get("Components") or {}).items():
                table.setdefault("Components", {}).setdefault(k, v)
            price_path = "GameParameter/PriceParam/%s.game__pouchcontent__PriceParam.bgyml" % clone
            add[price_path] = F.byml_dump({"BuyingPrice": int(price), "SellingPrice": 1})
            table["Components"]["PriceParam"] = "?" + price_path
            table_path = "GameParameter/GameParameterTable/%s.engine__actor__GameParameterTable.bgyml" % clone
            add[table_path] = F.byml_dump(table, version=F.BymlReader(tmpl[tmpl_table_path]).ver)
            comps["GameParameterTableRef"] = "?" + table_path
            # bought once: the placement's Presence flag hides it (generator.write_patches). NoRespawn, as OotrR
            # sets it, only acts when a pickup is collected, and a bought shelf stayed (0.5.0 test seed 4)
            self.prices[clone] = int(price)
        add.update({k: v for k, v in model_files.items() if k not in tmpl})
        new_param = F.byml_dump(param, version=F.BymlReader(tmpl[_param(template)]).ver)
        new_pouch = F.byml_dump(pouch, version=F.BymlReader(tmpl[pouch_tmpl_path]).ver)
        add[_param(clone)] = new_param
        add[pouch_path] = new_pouch
        data = F.sarc_rebuild(tmpl_raw, add=add)
        F.sarc_files(data)                                    # sanity: must parse
        self.emit(_pack(clone), data, data, dname)          # new file: its size entry is set below

        # resource size table entries for everything new
        entries = {
            _pack(clone)[:-3]: self._size(_pack(clone)[:-3], _pack(template)[:-3], len(data) - len(tmpl_raw)),
            _param(clone): self._size(_param(clone), _param(template), len(new_param) - len(tmpl[_param(template)])),
            pouch_path: self._size(pouch_path, pouch_tmpl_path, len(new_pouch) - len(tmpl[pouch_tmpl_path])),
        }
        for k in add:
            if k not in entries and self.restbl.get(k) is None:
                entries[k] = self._size(k, pouch_tmpl_path, len(add[k]))
        for path, size in entries.items():
            if size is not None:
                if zlib.crc32(path.encode()) in self.restbl.crc:
                    self.progress("warning: size-table hash collision for %s; skipped" % path)
                    continue
                self.restbl.set(path, size)
        self.rows.append((clone, src, template))
        if model_src != src:
            self.model_src[clone] = model_src
        return clone

    def finish(self):
        if not self.rows and not self.auto_rows:
            return
        tables = {}
        for t in ("ActorInfo", "GameActorInfo", "PouchActorInfo"):
            rel = self.world._find("RSDB", t)
            data, dname = self.read(rel)
            tables[t] = (rel, data, dname, F.byml_load(data))
        for clone, src, template in self.rows:
            for t, (rel, data, dname, rows) in tables.items():
                by_id = {r["__RowId"]: r for r in rows}
                if clone in by_id:
                    continue
                if t == "PouchActorInfo":
                    base = by_id.get(src)
                    if base is None:
                        continue
                    row = copy.deepcopy(base)
                    if clone in self.prices:
                        row["BuyingPrice"] = type(row.get("BuyingPrice", 0))(self.prices[clone])
                        row["SellingPrice"] = type(row.get("SellingPrice", 0))(1)
                else:
                    base = by_id.get(template)
                    if base is None:
                        self.progress("warning: no %s row for %s" % (t, template))
                        continue
                    row = copy.deepcopy(base)
                    if t == "ActorInfo":
                        s = by_id.get(src, {})
                        for k in ROW_FROM_ITEM:
                            if k in s:
                                row[k] = copy.deepcopy(s[k])
                        m = by_id.get(self.model_src.get(clone, src), {})
                        if m is not s:          # borrowed model (songs): its model fields, the item's name
                            for k in MODEL_ROW_KEYS:
                                if k in m:
                                    row[k] = copy.deepcopy(m[k])
                        row["ActorName"] = s.get("ActorName", src)
                        for k in HEAP_KEYS:
                            if k in s:
                                row[k] = type(row.get(k, s[k]))(max(int(row.get(k, 0)), int(s[k])))
                row["__RowId"] = clone
                keys = [r["__RowId"] for r in rows]
                rows.insert(bisect.bisect_left(keys, clone), row)
        for clone, src in self.auto_rows:       # after the clones: a walk-over copy may copy a clone's rows
            for t, (rel, data, dname, rows) in tables.items():
                by_id = {r["__RowId"]: r for r in rows}
                if clone in by_id or src not in by_id:
                    continue
                row = copy.deepcopy(by_id[src])
                row["__RowId"] = clone
                keys = [r["__RowId"] for r in rows]
                rows.insert(bisect.bisect_left(keys, clone), row)
        for t, (rel, data, dname, rows) in tables.items():
            self.emit(rel, data, F.byml_dump(rows), dname)
