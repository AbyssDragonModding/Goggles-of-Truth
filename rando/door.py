"""Door of Time: Open.

Ported from Clawshot (https://github.com/hiKareeem/Clawshot, src/clawshot/patch/door.py and patch/age.py), MIT
License, Copyright (c) 2026 Kareem Albaba and the Clawshot contributors; see docs/THIRD_PARTY.md. Clawshot's notes
say its Open mode passed a first in-game check.

Setting Market_Child_TimeTempleDoor_Opened alone (0.2.x to 0.5.0) left the door shut (0.5.0 test seed 4): the door
follows the Door of Time quest, not that flag. Two edits open it:
- the door's logic module (Logic/Market_Common_f252.logic.module.ainb) opens it from quest step Step06 on (after
  the stones and the Song of Time); its one "Step06" literal becomes "Ready", the quest's first step, so the door
  is open from the start. Same size, so its resource-size entry is unchanged;
- the child Master Sword pedestal's AI group (Market_Child_Static) used a module gated on that quest; it gets the
  ungated module Clawshot uses (from the Spirit Temple prefab), keeping the first-pull request and the sword.
Nothing is written to the save data.
"""
import hashlib

from . import formats as F

DOOR_LOGIC = "Logic/Market_Common_f252.logic.module.ainb"
DOOR_LOGIC_SHA256 = "5b4152c4e56bf51b7f2400fbdd6a39e4b506f3104cee49a24f6f49e72eb4d6a4"
PLACEMENT = "Banc/Market/Market_Child_Static.bcett.byml.zs"
DRAW_GROUP = 11738513547087641325
DRAW_LOGIC = "Logic/Module/Market_Child_Prefab/Market_Child_Prefab_e700.logic.module.ain"
UNGATED_LOGIC = "Logic/Module/SpiritTemple_Prefab/SpiritTemple_Prefab_5299.logic.module.ain"
DRAW_BINDINGS = {
    "EventRequestActor_7fe2": (17385100471140562353, "EventRequestActor"),
    "EventRequestActor_0b2e": (2548516804884289836, "EventRequestActor"),
    "Obj_TimeTemple_MasterSword_A_01_e482": (1016238122178870176, "Obj_TimeTemple_MasterSword_A_01"),
}


class DoorError(ValueError):
    pass


def door_logic(data):
    if hashlib.sha256(data).hexdigest() != DOOR_LOGIC_SHA256 or data.count(b"Step06\0") != 1:
        raise DoorError("the door's logic module is not the expected one")
    return data.replace(b"Step06\0", b"Ready\0\0")


def open_pedestal(data):
    root = F.byml_load(data)
    found = [g for g in root.get("AiGroups", []) if g.get("Hash") == DRAW_GROUP]
    if len(found) != 1 or found[0].get("Logic") != DRAW_LOGIC:
        raise DoorError("the child pedestal group is not as expected")
    group = found[0]
    refs = group.get("References", [])
    if len(refs) != len(DRAW_BINDINGS) or {r.get("Id") for r in refs} != DRAW_BINDINGS.keys():
        raise DoorError("the child pedestal references are not as expected")
    for ref in refs:
        actor_hash, actor_type = DRAW_BINDINGS[ref["Id"]]
        actors = [a for a in root["Actors"] if int(a.get("Hash", 0)) == actor_hash]
        if ref.get("Path") != ref["Id"] or ref.get("Reference") != actor_hash or len(actors) != 1 \
                or actors[0].get("Gyaml") != actor_type:
            raise DoorError("the child pedestal actor %s is not as expected" % ref["Id"])
        if ref["Id"] == "EventRequestActor_7fe2" and \
                (actors[0].get("Dynamic") or {}).get("RequestEventName") != "Market_Child_DoorOfTime_Draw":
            raise DoorError("the first-pull request is not as expected")
    group["Logic"] = UNGATED_LOGIC
    group["References"] = [
        dict(ref, Id="EventRequestActor_7a32" if ref["Id"] == "EventRequestActor_7fe2" else "CheckAttentionActor_8348")
        for ref in refs if ref["Id"] != "EventRequestActor_0b2e"]
    return F.byml_dump(root)


def patch_open_door(world, emit, progress, read):
    """True when both edits were made."""
    try:
        logic = read(DOOR_LOGIC)[0]
        new_logic = door_logic(logic)
        orig, dname = read(PLACEMENT)
        new_placement = open_pedestal(orig)
    except (DoorError, KeyError, OSError) as e:
        progress("warning: Door of Time not opened (%s)" % e)
        return False
    emit(DOOR_LOGIC, logic, new_logic, None, compressed=False)
    emit(PLACEMENT, orig, new_placement, dname)
    progress("Door of Time: Open (door logic and Master Sword pedestal changed)")
    return True
