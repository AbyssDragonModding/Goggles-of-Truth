"""Event-flow edits that shorten the start of the game and chest openings.

Each edit checks the native structure it changes, refuses anything it does not recognise, and reads its result back.

- opening_without_movie, complete_deku_meeting: ported from Clawshot (https://github.com/hiKareeem/Clawshot,
  src/clawshot/patch/gamedata.py and patch/mido.py, data/fast_start.toml), MIT License, Copyright (c) 2026 Kareem
  Albaba and the Clawshot contributors.
- quick_chest, quick_small_chest: ported from OotrR (https://github.com/Mozencaz/OotrR,
  src/oot_rando/patching/qol_patches.py), MIT License, Copyright (c) 2026 Mozencaz. Rewritten for rando/evfl.py.

See docs/THIRD_PARTY.md.
"""
import copy
import struct

from . import evfl


class FastStartError(ValueError):
    pass


def _check_readback(document, result, what):
    if evfl.read(result) != document:
        raise FastStartError("%s: the written flow does not read back as the changed flow" % what)
    return result


def _targets(event):
    if isinstance(event, (evfl.SwitchEvent, evfl.SubFlowSwitchEvent)):
        return [t for _, t in event.cases]
    if isinstance(event, evfl.ForkEvent):
        return [*event.forks, event.join]
    if isinstance(event, (evfl.ActionEvent, evfl.JoinEvent, evfl.SubFlowEvent)):
        return [event.next]
    return []


# --- Skip the opening movie ---------------------------------------------------------------------------------
# OpeningEvent:Opening_LoadingKokiriForest plays the movie (EventSystemActor.EventTransition Dm_Kokiri_0000: the
# narrated prologue, the Deku Tree's dream, Navi's flight) while Kokiri Forest loads, then waits on
# GameSystemActor.EventQueryBancChangeIsLoaded, whose only case (1) fades in. The entry now starts at that query
# and the movie's event becomes its case 0: a one-frame wait back to the query, so the flow still waits for the
# load the movie used to cover. Navi waking Link still plays.
OPENING_FLOW = "Event/EventFlow/OpeningEvent.bfevfl.zs"
OPENING_LOADING = "Opening_LoadingKokiriForest"
OPENING_MOVIE = "Dm_Kokiri_0000"


def opening_without_movie(data):
    document = evfl.read(data)
    fc = document.flowchart
    if fc is None or fc.name != "OpeningEvent":
        raise FastStartError("OpeningEvent flowchart not found")
    entries = [e for e in fc.entry_points if e.name == OPENING_LOADING]
    if len(entries) != 1:
        raise FastStartError("expected one %s entry, found %d" % (OPENING_LOADING, len(entries)))
    entry = entries[0]
    movie_index = entry.main_event
    movie = fc.events[movie_index] if movie_index < len(fc.events) else None
    query_index = movie.next if isinstance(movie, evfl.ActionEvent) else evfl.NONE
    query = fc.events[query_index] if query_index < len(fc.events) else None
    if (not isinstance(movie, evfl.ActionEvent)
            or fc.actors[movie.actor].name != "EventSystemActor"
            or fc.actors[movie.actor].actions[movie.action] != "EventTransition"
            or (movie.params or {}).get("EventName") != OPENING_MOVIE
            or not isinstance(query, evfl.SwitchEvent)
            or fc.actors[query.actor].name != "GameSystemActor"
            or fc.actors[query.actor].queries[query.query] != "EventQueryBancChangeIsLoaded"
            or query.params is not None
            or [v for v, _ in query.cases] != [1]
            or "EventWait" not in fc.actors[query.actor].actions):
        raise FastStartError("the opening's start is not the expected movie + load check")
    others = [e.name for e in fc.events if movie_index in _targets(e)]
    others += [e.name for e in fc.entry_points if e is not entry and movie_index in (e.main_event, *e.sub_flow_events)]
    if others or movie_index in entry.sub_flow_events:
        raise FastStartError("the movie's event is also reached from %s" % others)
    action = fc.actors[query.actor].actions.index("EventWait")
    fc.events[movie_index] = evfl.ActionEvent("RandoWaitForKokiriForest", query.actor, action, query_index,
                                              {"Frames": 1, "IsWaitEnd": True})
    query.cases = [(0, movie_index), *query.cases]
    entry.main_event = query_index
    return _check_readback(document, evfl.write(document), "OpeningEvent")


# --- New game starts outside, in front of the Kokiri Shop (every seed) -------------------------------------
# Sequence/Opening runs OpeningEvent:Opening_Introduction once on a new save (Sequence_ReservedBootEventName). It
# fades to black, sets Meet_DekuTree Step01, pins the terrain at the Deku Tree (Event31), points the event camera
# there (Event32), waits 75 frames (Event27) and plays Dm_Kokiri_0030: Navi's flight through the forest to Link's
# bed and Navi waking him, a 12,544-frame timeline (GameAnalyzedEventInfo; it ends on the camera in Link's house).
# Its load was the long black screen after "New Game". As in the N64 randomizer, a new game now starts outside:
# after Step01 the terrain is pinned at the spawn, Link and Navi are warped in front of the shop, the flow waits a
# moment for the area, fades in (the native Event26 fade used after the scene), and continues with the native tail
# (in-game BGM, Navi counted as talked to, the autosave). Saria's wake-up (gamedata.SARIA_INTRO) and the scene
# itself (HavePlayedEvent.Dm_Kokiri_0030, read by the basic-controls tip) count as seen, so the house door is open.
# Spawn: an NPC's standing anchor (AnchorAction2 in KokiriForest_Child_Static) on the ground in front of the shop
# door (Obj_Kokiri_DoorPillar_A_01 at -0.9, 110.1, -18.3), facing the door. YAngle 0 faces +Z, 90 faces +X
# (Dm_Kokiri_0075 warps Link to the Deku Tree with 95).
SHOP_SPAWN = [2.237, 110.754, -11.235]
SHOP_SPAWN_ANGLE = 205.0
NAVI_OFFSET = [0.6, 1.0, 0.4]
WAKE_SCENE = "Dm_Kokiri_0030"


def start_outside(data):
    document = evfl.read(data)
    fc = document.flowchart
    if fc is None or fc.name != "OpeningEvent":
        raise FastStartError("OpeningEvent flowchart not found")
    if any(e.name.startswith("RandoStartOutside") for e in fc.events):
        raise FastStartError("the new-game start was already changed")

    def find(actor, action, **params):
        hits = [i for i, e in enumerate(fc.events) if isinstance(e, evfl.ActionEvent)
                and fc.actors[e.actor].name == actor and fc.actors[e.actor].actions[e.action] == action
                and all((e.params or {}).get(k) == v for k, v in params.items())]
        if len(hits) != 1:
            raise FastStartError("expected one %s.%s %s, found %d" % (actor, action, params or "", len(hits)))
        return hits[0]

    step = find("ChallengeSystemActor", "EventExecuteProgressChallengeStep", ChallengeName="Meet_DekuTree")
    pin = find("TerrainSystemActor", "EventTerrainPinResource")
    scene = find("EventSystemActor", "EventTransition", EventName=WAKE_SCENE)
    fade_in = find("UISystemActor", "EventEventFadeIn", Length=1, IsNoPlayAnime=False)
    bgm_query = [i for i, e in enumerate(fc.events) if isinstance(e, evfl.SwitchEvent)
                 and fc.actors[e.actor].queries[e.query] == "EventQueryIsInGameBgmSuspend"]
    if fc.events[step].next != pin or len(bgm_query) != 1 or fc.events[fade_in].next != bgm_query[0]:
        raise FastStartError("the opening's introduction is not in the expected order")
    # nothing else may lead into the part that is cut out (the camera, the wait and the scene)
    cut, i = set(), fc.events[pin].next
    while i != scene:
        if i in cut or not isinstance(fc.events[i], evfl.ActionEvent):
            raise FastStartError("unexpected events between the terrain pin and %s" % WAKE_SCENE)
        cut.add(i)
        i = fc.events[i].next
    cut.add(scene)
    callers = [e.name for e in fc.events if set(_targets(e)) & cut and e is not fc.events[pin]
               and fc.events.index(e) not in cut]
    callers += [e.name for e in fc.entry_points if {e.main_event, *e.sub_flow_events} & cut]
    if callers:
        raise FastStartError("the wake-up scene is also reached from %s" % callers)

    def add(event):
        fc.events.append(event)
        return len(fc.events) - 1

    def f32(v):                         # the file stores binary32: keep what reads back
        return struct.unpack("<f", struct.pack("<f", v))[0]
    navi_pos = evfl.FloatArray(f32(a + b) for a, b in zip(SHOP_SPAWN, NAVI_OFFSET))
    spawn = evfl.FloatArray(f32(v) for v in SHOP_SPAWN)
    a, act = _action(fc, "EventSystemActor", "EventWait")
    wait = add(evfl.ActionEvent("RandoStartOutside_Wait", a, act, fade_in, {"IsWaitEnd": True, "Frames": 30}))
    a, act = _action(fc, "Npc_Navi", "EventTriggerNaviWarpToTargetPosAndRot")
    navi = add(evfl.ActionEvent("RandoStartOutside_Navi", a, act, wait, {
        "Position": navi_pos, "ClothWarpMode": -1, "YAngle": float(SHOP_SPAWN_ANGLE)}))
    a, act = _action(fc, "Player_Event", "EventPlayerWarpToTargetPosAndRot")
    link = add(evfl.ActionEvent("RandoStartOutside_Link", a, act, navi, {
        "IsWaitEnd": True, "UseDemoWait": True, "YAngle": float(SHOP_SPAWN_ANGLE), "Position": spawn,
        "ASCommand": "EvtWait"}))
    params = dict(fc.events[pin].params or {})
    if not isinstance(params.get("Position"), evfl.FloatArray):
        raise FastStartError("the opening's terrain pin has no position")
    params["Position"] = spawn
    fc.events[pin].params = params
    fc.events[pin].next = link
    # the cut events stay in the file, unreachable; the wake-up scene's own event loses its target
    return _check_readback(document, evfl.write(document), "OpeningEvent (start outside)")


# --- Start items given by the game's own pouch action -------------------------------------------------------
# Most start items (Skip Child Zelda) are save-data defaults: IsGet.<item> and the PouchData count. That isn't
# enough for an ocarina: the pouch action the game's own scenes use (PouchSystemActor
# EventTriggerAddOrRemovePouchContent in Dm_Kokiri_0155 and Dm_MelodyGet_Time) also records which ocarina Link
# holds (PouchActorInfo OcarinaTypeValue: Fairy 1, Time 2). With only the flags, the ocarina was in the menu but
# couldn't be played, and Saria's song scene showed Link with no ocarina (seed 3LETP69LQZ). These items are now
# added by that same action, silently (IsGetEvent false, as in the scenes), at the end of OpeningEvent:
# Opening_Introduction (Navi waking Link, which runs once on every new save, skipped or not), just before its
# autosave.
START_ITEM_FLOW = OPENING_FLOW
START_ITEM_ENTRY = "Opening_Introduction"
START_BY_EVENT = ("Item_Ocarina_Fairy", "Item_Ocarina_Time")


def give_at_start(actors):
    """An edit of OpeningEvent that adds `actors` (one each) to the pouch just before the opening's autosave."""
    actors = list(actors)

    def edit(data):
        document = evfl.read(data)
        fc = document.flowchart
        if fc is None or fc.name != "OpeningEvent":
            raise FastStartError("OpeningEvent flowchart not found")
        if any(e.name.startswith("RandoStartItem") for e in fc.events):
            raise FastStartError("start items already added")
        if not any(e.name == START_ITEM_ENTRY for e in fc.entry_points):
            raise FastStartError("%s entry not found" % START_ITEM_ENTRY)
        saves = [i for i, e in enumerate(fc.events) if isinstance(e, evfl.ActionEvent)
                 and fc.actors[e.actor].name == "GameSystemActor"
                 and fc.actors[e.actor].actions[e.action] == "EventTriggerRequestAutoSave"]
        if len(saves) != 1:
            raise FastStartError("expected one autosave in the opening, found %d" % len(saves))
        save = saves[0]
        before = [e for e in fc.events if save in _targets(e)]
        if len(before) != 1 or not isinstance(before[0], evfl.ActionEvent) \
                or any(save in (e.main_event, *e.sub_flow_events) for e in fc.entry_points):
            raise FastStartError("the opening's autosave is not reached by one event")
        base = next(a for a in fc.actors if a.name == "GameSystemActor" and not a.secondary_name)
        _new_actor(fc, "PouchSystemActor", copy.deepcopy(base.params or {}))
        pouch = next(i for i, a in enumerate(fc.actors) if a.name == "PouchSystemActor" and not a.secondary_name)
        if "EventTriggerAddOrRemovePouchContent" not in fc.actors[pouch].actions:
            fc.actors[pouch].actions.append("EventTriggerAddOrRemovePouchContent")
        action = fc.actors[pouch].actions.index("EventTriggerAddOrRemovePouchContent")
        nxt = save
        for n, actor in reversed(list(enumerate(actors))):
            fc.events.append(evfl.ActionEvent("RandoStartItem%d" % n, pouch, action, nxt, {
                "Num": 1, "IsEquipDIrect": False, "IsSetMessageTargetActorName": False, "Actor": actor,
                "IsGetEvent": False}))
            nxt = len(fc.events) - 1
        before[0].next = nxt
        return _check_readback(document, evfl.write(document), "OpeningEvent (start items)")
    return edit


# --- Skip the Great Deku Tree's arrival talk, Mido kept ----------------------------------------------------
# With Mido still blocking, the talk's state (Dm_Kokiri_0070 seen, Meet_DekuTree Complete, Get_StoneOfForest
# GoInside, the mouth open) is set at the end of Mido's own sword-and-shield clear, after his native steps.
# Setting it on a new save instead picks the wrong Mido schedule (Clawshot round 13). With Mido gone (Open
# Forest), the same values are plain new-save values (gamedata.DEKU_TREE_TALK).
MIDO_FLOW = "Event/EventFlow/Npc_Kokiri_Mido_Child.bfevfl.zs"
MIDO_BLOCKER = "KokiriForest_Npc_Kokiri_Mido_Child_Blocker"
SEEN_TREE = "HavePlayedEvent.Dm_Kokiri_0070"
MOUTH_OPEN = "KokiriForest_Meet_DekuTree_OpenDekuTreeMouth"


def complete_deku_meeting(data):
    document = evfl.read(data)
    fc = document.flowchart
    if fc is None or fc.name != "Npc_Kokiri_Mido_Child":
        raise FastStartError("child Mido flowchart not found")
    events = {e.name: (i, e) for i, e in enumerate(fc.events)}
    if any(n not in events for n in ("Event26", "Event32", "Event33", "Event48", "Event0")):
        raise FastStartError("Mido's clear steps not found")
    _, clear = events["Event26"]
    end_index, end = events["Event32"]
    talk1_index, talk1 = events["Event33"]
    talk2_index, talk2 = events["Event48"]
    step_index, step = events["Event0"]
    if (not all(isinstance(e, evfl.ActionEvent) for e in (clear, end, talk1, talk2, step))
            or clear.params != {"Index": -1, "GameDataName": MIDO_BLOCKER, "Value": False}
            or clear.next != end_index
            or fc.actors[clear.actor].name != "GameDataActor"
            or fc.actors[clear.actor].actions[clear.action] != "EventTriggerSetGameDataBool"
            or fc.actors[end.actor].name != "Npc_Kokiri_Mido_Child"
            or fc.actors[end.actor].actions[end.action] != "EventNpcBlockerEndBlockerAI"
            or end.next != talk1_index
            or (talk1.actor, talk1.action) != (clear.actor, clear.action) or talk1.next != talk2_index
            or (talk2.actor, talk2.action) != (clear.actor, clear.action) or talk2.next != step_index
            or fc.actors[step.actor].name != "ChallengeSystemActor"
            or fc.actors[step.actor].actions[step.action] != "EventExecuteProgressChallengeStep"
            or step.params != {"ChallengeName": "Meet_DekuTree", "IsWaitEnd": True,
                               "IsIgnoreChallengeProgressUI": False, "StepName": "Step03",
                               "IsIgnoreCompletedChallenge": False}
            or step.next != evfl.NONE):
        raise FastStartError("Mido's clear steps are not the expected ones")
    first = len(fc.events)
    fc.events.extend([
        evfl.ActionEvent("RandoDekuSeen", clear.actor, clear.action, step_index,
                         {"GameDataName": SEEN_TREE, "Index": -1, "Value": True}),
        evfl.ActionEvent("RandoDekuGoInside", step.actor, step.action, first + 2,
                         {**step.params, "ChallengeName": "Get_StoneOfForest", "StepName": "GoInside"}),
        evfl.ActionEvent("RandoDekuMouth", clear.actor, clear.action, evfl.NONE,
                         {"GameDataName": MOUTH_OPEN, "Index": -1, "Value": True}),
    ])
    talk2.next = first
    step.params = {**step.params, "StepName": "Complete"}
    step.next = first + 1
    return _check_readback(document, evfl.write(document), "Npc_Kokiri_Mido_Child")


# --- Chests without cutscene -----------------------------------------------------------------------------
# Big chests (Dm_SY_Treasurebox, also used by the scripted chests): Success_ plays the fanfare ->
# /Success_PlayerPerform (camera, Link's kick, item shown rotating, a 473-frame wait) -> a 90-frame wait ->
# /Success_AddContent (item added, get window) -> /Success_Leave (opened flag, auto-save). The quick version calls
# the chest's own /Open (lid only, not awaited) instead, then Link holds the item up (the vanilla item-get pose of
# Dm_SY_GetInEvent/GetInEvent_NotTurn_NotNpc) while it is added, and the fanfare starts without its intro.
CHEST_FLOW = "Event/EventFlow/Dm_SY_Treasurebox.bfevfl.zs"
CHEST_LID_ANIMATIONS = ("FrontOpen", "FrontOpen_Adult")
CHEST_SHOW_ITEM = (
    ("Player_Event", "EventCreateShowItemFromActorFileName", {"IsWaitEnd": True, "Actor": evfl.Argument("ContentName")}),
    ("Player_Event", "EventPlayerPlayASForFlowchart", {
        "UseAnmDriven": False, "KeepOneTimeAnm": False, "IsWaitEnd": False, "ASCommand": "DemoGet",
        "IsAllSlot": True, "ForceFadeFrame": 0.0, "ClothWarpMode": -1}),
    ("Player_Event", "EventIgnitionShowItem", {
        "IsWaitEnd": True, "ItemPos": evfl.FloatArray((0.0, 0.0, 0.0)), "IsScale": False, "CreateTime": 0.0,
        "IsInvalidateShadow": True, "IsAsPlay": True, "ASCommand": "Rotate_GetDemo"}),
    ("EventSystemActor", "EventWait", {"IsWaitEnd": True, "Frames": 40}),
)
CHEST_HIDE_ITEM = ("Player_Event", "EventDeleteShowItem", {
    "IsWaitEnd": True, "IsFadeOut": False, "IsScaleOut": False, "ChangeVisibleOffWithRequestDelete": False})


def _action(fc, actor_name, action):
    idx = next((i for i, a in enumerate(fc.actors) if a.name == actor_name and not a.secondary_name), None)
    if idx is None:
        raise FastStartError("actor %s not in %s" % (actor_name, fc.name))
    actor = fc.actors[idx]
    if action not in actor.actions:
        actor.actions.append(action)
    return idx, actor.actions.index(action)


def quick_chest(data):
    document = evfl.read(data)
    fc = document.flowchart
    if any(e.name.startswith("RandoQuickChest") for e in fc.events):
        raise FastStartError("big chest flow already changed")
    entry = fc.entry_point("Success_")
    switch = fc.events[entry.main_event]
    if not isinstance(switch, evfl.SwitchEvent) or not switch.cases or switch.cases[0][0] != 0:
        raise FastStartError("unexpected big chest start")
    fanfare_i = switch.cases[0][1]
    fanfare = fc.events[fanfare_i]
    perform = fc.events[fanfare.next] if isinstance(fanfare, evfl.ActionEvent) else None
    wait = fc.events[perform.next] if isinstance(perform, evfl.SubFlowEvent) else None
    add_i = wait.next if isinstance(wait, evfl.ActionEvent) else evfl.NONE
    add = fc.events[add_i] if add_i < len(fc.events) else None
    leave_i = add.next if isinstance(add, evfl.SubFlowEvent) else evfl.NONE
    leave = fc.events[leave_i] if leave_i < len(fc.events) else None
    if (not isinstance(perform, evfl.SubFlowEvent) or perform.entry_point != "Success_PlayerPerform"
            or perform.flowchart or fc.actors[wait.actor].actions[wait.action] != "EventWait"
            or not isinstance(add, evfl.SubFlowEvent) or add.entry_point != "Success_AddContent"
            or not isinstance(leave, evfl.SubFlowEvent) or leave.entry_point != "Success_Leave"
            or (perform.params or {}).get("ContentName") != "ContentName"
            or not any(e.name == "Open" for e in fc.entry_points)):
        raise FastStartError("unexpected big chest steps")
    if (fc.actors[fanfare.actor].actions[fanfare.action] != "EventTriggerSoundStartFanfare"
            or (fanfare.params or {}).get("IsEnableIntro") is not True):
        raise FastStartError("unexpected big chest fanfare")
    fanfare.params["IsEnableIntro"] = False
    first = len(fc.events)
    steps = list(CHEST_SHOW_ITEM) + [CHEST_HIDE_ITEM]
    for k, (actor_name, action, params) in enumerate(steps):
        a, act = _action(fc, actor_name, action)
        fc.events.append(evfl.ActionEvent("RandoQuickChestShow_%d" % k if k < len(CHEST_SHOW_ITEM)
                                          else "RandoQuickChestHide", a, act, evfl.NONE, dict(params)))
    pose = list(range(first, first + len(CHEST_SHOW_ITEM)))
    hide = first + len(CHEST_SHOW_ITEM)
    for i, j in zip(pose, pose[1:]):
        fc.events[i].next = j
    fc.events[pose[-1]].next = add_i
    add.next = hide
    fc.events[hide].next = leave_i
    perform.entry_point = "Open"
    perform.params = None
    perform.next = pose[0]
    # the lid animation is timed on the whole performance; /Open waits for it, so Link would stand frozen
    lids = [e for e in fc.events if isinstance(e, evfl.ActionEvent)
            and fc.actors[e.actor].actions[e.action] == "EventPlayAS"
            and (e.params or {}).get("ASName") in CHEST_LID_ANIMATIONS]
    if sorted(e.params["ASName"] for e in lids) != sorted(CHEST_LID_ANIMATIONS) or \
            any(e.params.get("IsWaitEnd") is not True for e in lids):
        raise FastStartError("unexpected chest lid animations")
    for e in lids:
        e.params["IsWaitEnd"] = False
    return _check_readback(document, evfl.write(document), "Dm_SY_Treasurebox")


# Small chests (Dm_SY_TreasureboxSmall): Success_ calls /Open (space and camera checks, Link's opening or kicking
# animation, event cameras, Navi, the lid, then /Pack_ItemDisplay). The quick version runs the lid's own actions
# (not awaited) and Link's get pose (/GetAnimationAction), then /Pack_ItemDisplay directly.
SMALL_CHEST_FLOW = "Event/EventFlow/Dm_SY_TreasureboxSmall.bfevfl.zs"
SMALL_CHEST_LID = "FrontOpenSmall"


def quick_small_chest(data):
    document = evfl.read(data)
    fc = document.flowchart
    if any(e.name.startswith("RandoQuickChest") for e in fc.events):
        raise FastStartError("small chest flow already changed")
    entry = fc.entry_point("Success_")
    opened = fc.events[entry.main_event]
    if (not isinstance(opened, evfl.SubFlowEvent) or opened.entry_point != "Open" or opened.flowchart
            or (opened.params or {}).get("ContentName") != "ContentName" or "IsMiniGame" not in opened.params):
        raise FastStartError("unexpected small chest start")
    names = {e.name for e in fc.entry_points}
    if not {"Pack_ItemDisplay", "GetAnimationAction", "TresureboxSmall_Animation"} <= names:
        raise FastStartError("small chest entries missing")

    def actions(action):
        return [e for e in fc.events if isinstance(e, evfl.ActionEvent)
                and fc.actors[e.actor].actions[e.action] == action]
    push = actions("EventTriggerTBoxPushPoseMask")
    lids = [e for e in actions("EventPlayAS") if (e.params or {}).get("ASName") == SMALL_CHEST_LID]
    lights = actions("EventTreasureBoxSetRigLightIntensityScale")
    poses = [e for e in fc.events if isinstance(e, evfl.SubFlowEvent)
             and e.entry_point == "GetAnimationAction" and not e.flowchart]
    if len(push) != 1 or len(lids) != 1 or len(lights) != 1 or not poses:
        raise FastStartError("unexpected small chest lid")

    def clone(name, src, **changes):
        e = copy.deepcopy(src)
        e.name = name
        if e.params is not None:
            e.params.update(changes)
        fc.events.append(e)
        return len(fc.events) - 1
    steps = [clone("RandoQuickChestPose", push[0]),
             clone("RandoQuickChestLid", lids[0], IsWaitEnd=False),
             clone("RandoQuickChestLight", lights[0], IsWaitEnd=False),
             clone("RandoQuickChestGetPose", poses[0])]
    for i, j in zip(steps, steps[1:]):
        fc.events[i].next = j
    fc.events[steps[-1]].next = entry.main_event
    opened.entry_point = "Pack_ItemDisplay"
    entry.main_event = steps[0]
    # an entry point lists the sub flow calls it reaches; a missing one hung the game (Clawshot round 13)
    entry.sub_flow_events.append(steps[-1])
    return _check_readback(document, evfl.write(document), "Dm_SY_TreasureboxSmall")


# --- Skip Epona Race --------------------------------------------------------------------------------------
# Epona comes to Epona's Song only once she is your horse. The game registers her (Get_Epona's
# Sub_Get_Epona_EscapeRanch_*_Warp: Animal_Epona_Adult.EventCopyAndRegisterOwnedHorse, then the challenge's Complete)
# when you ride her out over a ranch fence or through the main gate while the quest is at exactly AfterWonGambleRace
# (LonLonRanch_AfterWonGambleRace; the fences' and gate's PlayEventName starts it).
# Dm_SY_Ocarina_EponaSong:EponaSong asks EventQueryHasOwnedHorse; without a horse, an adult inside the Lon Lon Ranch
# fence (LonLonRanch_GambleRace_IsInsideFence) calls the ranch horses over (EponaSong_CallHorseAround). That branch
# now first moves Get_Epona to AfterWonGambleRace (as if Ingo's race was won), then calls the horses as usual: ride
# Epona out of the ranch and the game makes her yours. Only once Malon's song scene has played (the quest is then past
# ReadyForGetEponaSong, which child Malon's scene needs: moving it on earlier would lose that check), not while
# riding a rented horse or racing, and not when the quest is already that far. Switch cases: 0 = true.
# (0.5.0 - 0.6.1 registered the ranch's Epona inside this flow instead; in-game she never came.)
EPONA_SONG_FLOW = "Event/EventFlow/Dm_SY_Ocarina_EponaSong.bfevfl.zs"
EPONA_FENCE_FLAG = "LonLonRanch_GambleRace_IsInsideFence"
EPONA_MALON_SCENE = "Get_Epona_IsAfter_ReadyForGetEponaSong_Exp"   # child Malon's song scene moves the quest past it
EPONA_STEP = "AfterWonGambleRace"


def _query(fc, actor_name, query):
    idx = next((i for i, a in enumerate(fc.actors) if a.name == actor_name and not a.secondary_name), None)
    if idx is None:
        raise FastStartError("actor %s not in %s" % (actor_name, fc.name))
    actor = fc.actors[idx]
    if query not in actor.queries:
        actor.queries.append(query)
    return idx, actor.queries.index(query)


def _new_actor(fc, name, params):
    if any(a.name == name and not a.secondary_name for a in fc.actors):
        return
    fc.actors.append(evfl.Actor(name=name, params=params))


def epona_without_race(data):
    document = evfl.read(data)
    fc = document.flowchart
    if any(e.name.startswith("RandoEpona") for e in fc.events):
        raise FastStartError("Epona's Song flow already changed")

    def is_query(e, actor, query):
        return (isinstance(e, evfl.SwitchEvent) and fc.actors[e.actor].name == actor
                and fc.actors[e.actor].queries[e.query] == query)

    fences = [i for i, e in enumerate(fc.events) if is_query(e, "GameDataActor", "EventQueryIsGameDataBool")
              and (e.params or {}).get("GameDataName") == EPONA_FENCE_FLAG]
    owned = [e for e in fc.events if is_query(e, "GameSystemActor", "EventQueryHasOwnedHorse")
             and dict(e.cases).get(1) in fences]
    if len(fences) != 1 or len(owned) != 1:
        raise FastStartError("the no-horse branch of Epona's Song is not as expected")
    fence = fc.events[fences[0]]
    around = dict(fence.cases).get(0)
    if (around is None or not isinstance(fc.events[around], evfl.SubFlowEvent)
            or fc.events[around].entry_point != "EponaSong_CallHorseAround"):
        raise FastStartError("Epona's Song calls are not as expected")

    data_actor = next(a for a in fc.actors if a.name == "GameDataActor" and not a.secondary_name)
    _new_actor(fc, "ChallengeSystemActor", copy.deepcopy(data_actor.params or {}))

    def add(event):
        fc.events.append(event)
        return len(fc.events) - 1

    a, act = _action(fc, "ChallengeSystemActor", "EventExecuteProgressChallengeStep")
    won = add(evfl.ActionEvent("RandoEpona_RaceWon", a, act, around, {
        "ChallengeName": "Get_Epona", "StepName": EPONA_STEP, "IsWaitEnd": True,
        "IsIgnoreCompletedChallenge": False, "IsIgnoreChallengeProgressUI": True}))
    a, q = _query(fc, "GameDataActor", "EventQueryIsGameDataBoolExp")
    malon = add(evfl.SwitchEvent("RandoEpona_MalonSceneSeen", a, q, [(0, won), (1, around)],
                                 {"GameDataName": EPONA_MALON_SCENE}))
    a, q = _query(fc, "GameDataActor", "EventQueryIsGameDataBoolExp")
    far = add(evfl.SwitchEvent("RandoEpona_AlreadyWon", a, q, [(0, around), (1, malon)],
                               {"GameDataName": "Get_Epona_IsAfter_GambleRacePlaying_Exp"}))
    a, q = _query(fc, "GameDataActor", "EventQueryIsGameDataBool")
    racing = add(evfl.SwitchEvent("RandoEpona_IsRacing", a, q, [(0, around), (1, far)],
                                  {"GameDataName": "LonLonRanch_PlayingGambleRace", "Index": -1}))
    a, q = _query(fc, "GameDataActor", "EventQueryIsGameDataBoolExp")
    riding = add(evfl.SwitchEvent("RandoEpona_IsRiding", a, q, [(0, around), (1, racing)],
                                  {"GameDataName": "LonLonRanch_PlayingHorseRiding"}))
    fence.cases = [(v, riding if v == 0 else t) for v, t in fence.cases]
    return _check_readback(document, evfl.write(document), "Dm_SY_Ocarina_EponaSong")
