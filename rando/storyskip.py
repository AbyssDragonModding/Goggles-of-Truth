"""Skip Story Scenes: the Temple of Time, Chamber of Sages and sage-awakening scenes don't play.

Story scenes are not started by the place you are in but by a quest flow (DoorOfTime, AllSage, and the shared
boss-reward flow Dm_SY_BancChange_EscapeDungeon), which plays them one after another with
EventSystemActor.EventTransition and then moves Link on (EventReserveBancChange). Each listed transition is
replaced in that quest flow by what the scene leaves behind, so the quest carries on as if it had played:

- a timeline-only scene (a pre-recorded cinematic: camera, voices, actors; no flowchart, so nothing it does
  changes the save) is marked as seen (HavePlayedEvent.<scene>, which the quest flows and stage logic read, e.g.
  AllSage checks HavePlayedEvent.Dm_Awake_Spirit / _Shadow);
- a flowchart scene (Rauru's talk Dm_SageRoom_0005, the medallion scenes Dm_Awake_*_Get, the Light Arrows, the
  child stones) is checked to do nothing but talk, animate, and hand over one item through
  GetPouchContent:GetPouchContentByActorName (plus plain save flags, which are copied). Its item, the randomized
  one (read from the already-patched scene), is handed over directly with that same call, the way NPC flows do it
  (Npc_Bonooru, SubEvent_GetSwordBigGoron), after the screen fades in.

A scene that adds an item itself (PouchSystemActor.EventTriggerAddOrRemovePouchContent, then its item window:
Saria's Fairy Ocarina on the forest bridge) has those two steps copied instead.

Fades: most of these scenes start on a faded screen and fade it in themselves, often from white (the move to the
Chamber of Sages fades out to white; Rauru's Dm_SageRoom_0000 and every Dm_Awake_* scene start with a white
fade-in). A skipped scene that would open with a fade-in gets that fade-in (its colour); an item scene fades in
before its window in its own fade colour (test seed 9: Rauru's medallion was given behind a white screen, with a
black fade-in, so no window was seen). A scene that directly follows another skipped scene adds no fade, so a
run of skipped scenes doesn't flash.

Event info: every event (an RSDB/EventSetting row: the flow file and entry it runs) that has a row in
RSDB/GameAnalyzedEventInfo lists there every other flow its entry calls (SubFlowList); true of all 2037 such events
in the game. A call to a flow that isn't listed stops the event: in test seed 7 Rauru's boot event in the Chamber of
Sages stopped at the new GetPouchContent call (a white screen), and in test seed 8 the Master Sword's pull event
and Saria's bridge event didn't start at all. So the rows of every changed event get the flows it now calls
(update_event_info). ChildEventList (the scenes it plays) may list more than it plays (169 events in the game do),
so the skipped scenes are left in it.

Anything not exactly as expected is refused (StorySkipError) and that scene keeps playing. The song lessons
(Dm_MelodyGet_*), boss intros and the ending are not touched.
"""
import re

from . import evfl
from .gamedata import mm3

GIFT_FLOW, GIFT_ENTRY = "GetPouchContent", "GetPouchContentByActorName"

# quest flow -> scenes it plays that are skipped
SKIPS = {
    # Temple of Time: the door opening (closed Door of Time), Ganondorf, the Master Sword, Rauru and the Light
    # Medallion in the Chamber of Sages
    "DoorOfTime": ["Dm_TimeTemple_0010", "Dm_TimeTemple_0020", "Dm_TimeTemple_0040", "Dm_TimeTemple_0030",
                   "Dm_SageRoom_0000", "Dm_SageRoom_0005"],
    # leaving Kokiri Forest after the Deku Tree: Saria's goodbye on the bridge and her Fairy Ocarina
    "Goto_HyruleCastle": ["Dm_Kokiri_0150", "Dm_Kokiri_0155"],
    # adult Temple of Time: Sheik's first talk, the sages' talks, Zelda's reveal and the Light Arrows
    "AllSage": ["Dm_TimeTemple_0050", "Dm_TimeTemple_0055", "Dm_SageRoom_0010", "Dm_TimeTemple_0090",
                "Dm_TimeTemple_0095", "Dm_TimeTemple_0110", "Dm_TimeTemple_0115", "Dm_TimeTemple_0125",
                "Dm_TimeTemple_0130", "Dm_TimeTemple_0135"],
    # after a boss: the sage awakens and hands over the medallion; the Deku Tree, Darunia and Ruto hand over the stones
    "Dm_SY_BancChange_EscapeDungeon": [
        "Dm_Awake_Forest", "Dm_Awake_Forest_Get", "Dm_Awake_Fire", "Dm_Awake_Fire_Get",
        "Dm_Awake_Water", "Dm_Awake_Water_Get", "Dm_Awake_Shadow", "Dm_Awake_Shadow_Get",
        "Dm_Awake_Spirit", "Dm_Awake_Spirit_Get",
        "Dm_Kokiri_0130", "Dm_DeathMtTrail_0025", "Dm_ZoraFountain_0030"],
}


def flow_rel(name):
    return "Event/EventFlow/%s.bfevfl.zs" % name


# What a skipped flowchart scene may do besides talking and animating. Anything else refuses the skip.
PRESENTATION = re.compile(
    r"PlayAS|Talk|Warp|XLink|Sound|Bgm|BGM|Comment|Camera|Fade|LookAt|Lod|Model|Particip|Wait|PostProc|Dialog|Navi|"
    r"Palette|DoF|Rumble|Caustic|Reflection|Visible|Show|Hide|Ducking|Effect|Light|Rendering|Nickname|Move|Turn|"
    r"Rotate|Scale|Emit|Shake|Anime|Face|Eye|Mouth|Blink|Weather|Wind|Letterbox|DemoProduct|Telop|Subtitle|Cloth|Bone|"
    r"Bind|Attach|Shadow|Fog|Voice|Emotion|GoOffstage|DoNothing|NorifyCut|ScreenShot|DoCommand|TerrainCalc|Culling|"
    r"EquipmentUserRequestChangeState|BootsChange|PerformanceImportantMenu|DisplayGet|Chemical|Time$|SetTime|"
    r"Shading")
DROPPED_SUBFLOWS = {"Common_Camera_Pln", "NaviEventCommon"}


class StorySkipError(ValueError):
    pass


def scene_effects(doc):
    """(items, [save flags it sets to True]) for a skippable scene; StorySkipError otherwise.

    items: ("gift", actor) for a GetPouchContentByActorName call, ("add", params) for a pouch add the scene makes
    itself (then its DisplayGetByActorName window is shown too)."""
    fc = doc.flowchart
    if fc is None:
        return [], []
    gifts, adds, shown, flags = [], [], [], []
    for e in fc.events:
        if isinstance(e, evfl.SubFlowEvent):
            if not e.flowchart:
                continue
            if (e.flowchart, e.entry_point) == (GIFT_FLOW, GIFT_ENTRY):
                gifts.append((e.params or {}).get("ActorName"))
            elif e.flowchart == GIFT_FLOW and e.entry_point == "DisplayGetByActorName":
                shown.append((e.params or {}).get("ActorName"))     # the window for an item already added
            elif e.flowchart not in DROPPED_SUBFLOWS:
                raise StorySkipError("%s calls %s:%s" % (fc.name, e.flowchart, e.entry_point))
        elif isinstance(e, (evfl.SubFlowSwitchEvent, evfl.ReturnEvent)):
            raise StorySkipError("%s has a sub flow branch" % fc.name)
        elif isinstance(e, (evfl.ActionEvent, evfl.SwitchEvent)):
            actor = fc.actors[e.actor]
            what = actor.actions[e.action] if isinstance(e, evfl.ActionEvent) else actor.queries[e.query]
            if isinstance(e, evfl.SwitchEvent):
                # a branch on owning an item only picks a line (Darunia: IsGet.Item_DinFire)
                owns = (what == "EventQueryIsGameDataBool"
                        and str((e.params or {}).get("GameDataName", "")).startswith("IsGet."))
                if (actor.name == "GameDataActor" and not owns) or "Challenge" in what:
                    raise StorySkipError("%s branches on %s" % (fc.name, what))
                continue
            if actor.name == "GameDataActor":
                p = e.params or {}
                if what != "EventTriggerSetGameDataBool" or p.get("Value") is not True or p.get("Index", -1) != -1:
                    raise StorySkipError("%s: %s %s" % (fc.name, what, p))
                flags.append(p["GameDataName"])
            elif (actor.name == "PouchSystemActor" and what == "EventTriggerAddOrRemovePouchContent"
                  and isinstance((e.params or {}).get("Num"), int) and e.params["Num"] > 0):
                adds.append(dict(e.params))                 # Saria hands over the Fairy Ocarina herself
            elif ("Pouch" in what or "Challenge" in what or "Banc" in what or what == "EventTransition"
                  or actor.name in ("PouchSystemActor", "ChallengeSystemActor")):
                raise StorySkipError("%s: %s.%s" % (fc.name, actor.name, what))
            elif not PRESENTATION.search(what):
                raise StorySkipError("%s: %s.%s is not presentation" % (fc.name, actor.name, what))
    if len(gifts) > 1 or (gifts and not gifts[0]) or (gifts and adds):
        raise StorySkipError("%s hands over %s %s" % (fc.name, gifts, adds))
    if any(a.get("Actor") not in shown for a in adds):
        raise StorySkipError("%s adds %s without its item window" % (fc.name, adds))
    # an item window without a pouch add only shows something added before (the Master Sword): nothing to copy
    return [("gift", g) for g in gifts] + [("add", a) for a in adds], flags


def first_fade(doc):
    """("in" | "out", colour) of the scene's first UISystemActor fade, or None. Timelines by start time; flowcharts
    in breadth-first order from their first entry, following calls to their own entries."""
    if doc.flowchart is None:
        t = doc.timeline
        clips = sorted((c for c in t.clips if t.actors[c.actor].name == "UISystemActor"
                        and "Fade" in t.actors[c.actor].actions[c.action]), key=lambda c: c.start)
        if not clips:
            return None
        what = t.actors[clips[0].actor].actions[clips[0].action]
        return ("in" if "FadeIn" in what else "out"), (clips[0].params or {}).get("Color", 0)
    fc = doc.flowchart
    seen, queue = set(), [fc.entry_points[0].main_event] if fc.entry_points else []
    while queue:
        i = queue.pop(0)
        if not isinstance(i, int) or i >= len(fc.events) or i in seen:
            continue
        seen.add(i)
        e = fc.events[i]
        if isinstance(e, evfl.ActionEvent):
            a = fc.actors[e.actor]
            if a.name == "UISystemActor" and "Fade" in a.actions[e.action]:
                return ("in" if "FadeIn" in a.actions[e.action] else "out"), (e.params or {}).get("Color", 0)
        if isinstance(e, evfl.SubFlowEvent) and not e.flowchart:
            try:
                queue.append(fc.entry_point(e.entry_point).main_event)
            except KeyError:
                pass
        queue.extend(_targets(e))
    return None


def _targets(e):
    if isinstance(e, (evfl.SwitchEvent, evfl.SubFlowSwitchEvent)):
        return [t for _, t in e.cases]
    if isinstance(e, evfl.ForkEvent):
        return [*e.forks, e.join]
    if isinstance(e, (evfl.ActionEvent, evfl.JoinEvent, evfl.SubFlowEvent)):
        return [e.next]
    return []


def _reach(fc, start):
    seen, stack = set(), [start]
    while stack:
        i = stack.pop()
        if i in seen or not isinstance(i, int) or i >= len(fc.events):
            continue
        seen.add(i)
        stack.extend(_targets(fc.events[i]))
    return seen


def _action(fc, actor_name, action):
    idx = next((i for i, a in enumerate(fc.actors) if a.name == actor_name and not a.secondary_name), None)
    if idx is None:
        raise StorySkipError("actor %s not in %s" % (actor_name, fc.name))
    actor = fc.actors[idx]
    if action not in actor.actions:
        actor.actions.append(action)
    return idx, actor.actions.index(action)


def skip_scenes(data, scenes, read_scene, flag_exists):
    """Quest flow `data` with each transition to one of `scenes` replaced by its effects.

    read_scene(name) -> the scene's latest bytes; flag_exists(name) -> is it a save flag.
    Returns (new bytes, {scene: "seen" | "item <actor>" | "kept: <reason>"})."""
    document = evfl.read(data)
    fc = document.flowchart
    if fc is None:
        raise StorySkipError("no flowchart")
    report = {}
    changed = False
    plans = []
    for scene in scenes:
        hits = [i for i, e in enumerate(fc.events) if isinstance(e, evfl.ActionEvent)
                and fc.actors[e.actor].name == "EventSystemActor"
                and fc.actors[e.actor].actions[e.action] == "EventTransition"
                and (e.params or {}).get("EventName") == scene]
        if not hits:
            report[scene] = "kept: not played by %s" % fc.name
            continue
        try:
            items, flags = scene_effects(evfl.read(read_scene(scene)))
        except StorySkipError as ex:
            report[scene] = "kept: %s" % ex
            continue
        seen = "HavePlayedEvent." + scene
        flags = [f for f in dict.fromkeys(flags + [seen]) if flag_exists(f)]
        plans.append((scene, hits, items, flags, first_fade(evfl.read(read_scene(scene)))))
        report[scene] = ("items %s" % ", ".join(w if k == "gift" else w["Actor"] for k, w in items)) if items else "seen"
        changed = True
    skipped = {t for _, hits, *_ in plans for t in hits}
    preds = {}
    for j, e in enumerate(fc.events):
        for t in _targets(e):
            preds.setdefault(t, []).append(j)
    for scene, hits, items, flags, fade in plans:
        for t in hits:
            old = fc.events[t]
            # fade in where the scene would have (its colour), unless a skipped scene comes right before it
            after_skip = bool(preds.get(t)) and all(j in skipped for j in preds[t])
            fade_colour = None
            if not after_skip and fade and (fade[0] == "in" or items):
                fade_colour = fade[1]
            elif not after_skip and items:
                fade_colour = 0
            steps = []
            for f in flags:
                a, act = _action(fc, "GameDataActor", "EventTriggerSetGameDataBool")
                steps.append(evfl.ActionEvent("RandoSkip_%s_%d" % (scene, len(steps)), a, act, evfl.NONE,
                                              {"GameDataName": f, "Index": -1, "Value": True}))
            if fade_colour is not None:
                a, act = _action(fc, "UISystemActor", "EventEventFadeIn")
                steps.append(evfl.ActionEvent("RandoSkip_%s_Fade" % scene, a, act, evfl.NONE,
                                              {"Color": fade_colour, "IsNoPlayAnime": False, "Length": 1,
                                               "IsWaitEnd": True}))
            for k, (kind, what) in enumerate(items):
                if kind == "gift":
                    steps.append(evfl.SubFlowEvent("RandoSkip_%s_Item%d" % (scene, k), GIFT_FLOW, GIFT_ENTRY,
                                                   evfl.NONE, {"ActorName": what}))
                else:
                    a, act = _action(fc, "PouchSystemActor", "EventTriggerAddOrRemovePouchContent")
                    steps.append(evfl.ActionEvent("RandoSkip_%s_Add%d" % (scene, k), a, act, evfl.NONE, dict(what)))
                    steps.append(evfl.SubFlowEvent("RandoSkip_%s_Show%d" % (scene, k), GIFT_FLOW,
                                                   "DisplayGetByActorName", evfl.NONE, {"ActorName": what["Actor"]}))
            if not steps:
                a, act = _action(fc, "EventSystemActor", "EventWait")
                steps.append(evfl.ActionEvent("RandoSkip_%s" % scene, a, act, evfl.NONE,
                                              {"Frames": 1, "IsWaitEnd": True}))
            # the first step takes the transition's place (everything pointing at it now reaches the skip)
            index = [t] + list(range(len(fc.events), len(fc.events) + len(steps) - 1))
            fc.events[t] = steps[0]
            fc.events.extend(steps[1:])
            for k, i in enumerate(index):
                fc.events[i].next = index[k + 1] if k + 1 < len(index) else old.next
    if not changed:
        return data, report
    # an entry point lists the sub flow calls it reaches; a missing one hung the game (Clawshot round 13)
    for entry in fc.entry_points:
        for i in sorted(_reach(fc, entry.main_event)):
            if isinstance(fc.events[i], (evfl.SubFlowEvent, evfl.SubFlowSwitchEvent)) and i not in entry.sub_flow_events:
                entry.sub_flow_events.append(i)
    new = evfl.write(document)
    if evfl.read(new) != document:
        raise StorySkipError("%s: the written flow does not read back as the changed flow" % fc.name)
    return new, report


def _table(world, read, prefix):
    """(relpath, original bytes, zstd dict, root, rows) of an RSDB table, or None."""
    from . import formats as F
    rel = next(("RSDB/" + n for n in world.files.listdir("RSDB") if n.startswith(prefix + ".")), None)
    if rel is None:
        return None
    data, dname = read(rel)
    root = F.byml_load(data)
    rows = root if isinstance(root, list) else next((v for v in root.values() if isinstance(v, list)), [])
    return rel, data, dname, root, rows


def external_calls(fc, entry):
    """Other flows the entry calls (sub flow calls it reaches)."""
    out = []
    for i in sorted(_reach(fc, entry.main_event)):
        e = fc.events[i]
        if isinstance(e, (evfl.SubFlowEvent, evfl.SubFlowSwitchEvent)) and e.flowchart and e.flowchart != fc.name:
            out.append(e.flowchart)
    return list(dict.fromkeys(out))


def update_event_info(world, read, emit, flows):
    """Add the flows each changed event now calls to its GameAnalyzedEventInfo SubFlowList.

    flows: {flow name: changed flowchart}. Returns the events changed."""
    from . import formats as F
    setting = _table(world, read, "EventSetting")
    info = _table(world, read, "GameAnalyzedEventInfo")
    if setting is None or info is None:
        raise StorySkipError("event tables not found")
    rel, data, dname, root, rows = info
    by_id = {r.get("__RowId"): r for r in rows}
    changed = []
    for r in setting[4]:
        flow = str(r.get("FlowchartFileName", "")).rsplit("/", 1)[-1].split(".", 1)[0]
        fc, row = flows.get(flow), by_id.get(r.get("__RowId"))
        if fc is None or row is None:
            continue                                # an event without a row may call anything (1997 in the game)
        try:
            entry = fc.entry_point(r.get("EntryPointName"))
        except KeyError:
            continue
        listed = list(row.get("SubFlowList", []))
        missing = [f for f in external_calls(fc, entry) if f not in listed]
        if missing:
            row["SubFlowList"] = listed + missing
            changed.append(r["__RowId"])
    if changed:
        ver = F.BymlReader(data).ver
        emit(rel, data, F.byml_dump(root, version=ver, big_endian=data[:2] == b"BY"), dname)
    return changed


def patch_story_scenes(world, read, emit, progress, flag_exists):
    """Apply SKIPS; returns {flow: report}. Run after the item edits, so gifts are the randomized items."""
    out, docs = {}, {}
    for flow, scenes in SKIPS.items():
        rel = flow_rel(flow)
        if not world.files.exists(rel):
            progress("warning: Skip Story Scenes: %s not found; its scenes still play" % flow)
            continue
        orig, dname = read(rel)
        try:
            new, report = skip_scenes(orig, scenes, lambda s: read(flow_rel(s))[0], flag_exists)
        except (StorySkipError, KeyError, IndexError) as ex:
            progress("warning: Skip Story Scenes: %s not changed (%s); its scenes still play" % (flow, ex))
            continue
        if new != orig:
            emit(rel, orig, new, dname)
            docs[flow] = evfl.read(new).flowchart
        kept = {s: r for s, r in report.items() if r.startswith("kept")}
        progress("Skip Story Scenes: %s: %d scenes skipped%s" % (
            flow, len(report) - len(kept), "".join("; %s %s" % kv for kv in kept.items())))
        out[flow] = report
    if docs:
        events = update_event_info(world, read, emit, docs)
        progress("Skip Story Scenes: event info updated for %d events (%s)" % (len(events), ", ".join(events)))
    return out
