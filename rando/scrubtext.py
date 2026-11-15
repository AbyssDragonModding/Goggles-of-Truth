"""Business Scrub sale lines that name the item the scrub really sells.

Each one-time scrub's purchase call (SimpleShopSub_Scrub_Business_OneTime in Enemy_Scrub_Business_Common) has a
SellerMessageId naming its sale line in EventFlowMsg/Enemy_Event.msbt, e.g. "This bag will allow you to carry
more Deku sticks. It's <price> rupees. Wanna buy it?". The Hyrule Field and Death Mountain Crater scrubs share one
line (Enemy_Scrub_Business_Heart_01), so each shuffled scrub gets a line of its own: a new label
"Rando_Scrub_<event>" in every language's Enemy_Event.msbt, and its purchase calls point at it.

The line is the game's English Piece of Heart line with the item swapped in: "Ohhh, <item>! Shimmery glimmery!
It's <price> rupees. Wanna buy it?". It keeps the game's own colour tags and price tag (the price tag shows the
call's Price, so changed prices read right). Like the hint stones, every language gets the English line.
"""
import struct

from . import evfl
from . import formats as F

FLOW = "Event/EventFlow/Enemy_Scrub_Business_Common.bfevfl.zs"
MESSAGES = "EventFlowMsg/Enemy_Event.msbt"
MESSAGE_FILE = "EventFlowMsg/Enemy_Event"
TEMPLATE_LANGUAGE = "USen"
TEMPLATE_LABEL = "Enemy_Scrub_Business_Heart_01"
COLOR_ON = b"\x0e\x00\x00\x03\x00\x02\x00\x00\x00"
COLOR_OFF = b"\x0e\x00\x00\x03\x00\x02\x00\xff\xff"
TEMPLATE_ITEM = b"a " + COLOR_ON + b"Piece of Heart" + COLOR_OFF + b"."
LABEL_PREFIX = "Rando_Scrub_"


class ScrubTextError(Exception):
    pass


def sale_line(template, name):
    """The English sale line for item `name`, from the game's raw Piece of Heart line."""
    if template.count(TEMPLATE_ITEM) != 1:
        raise ScrubTextError("the Piece of Heart sale line is not as expected")
    name = name.replace("\x00", "").encode("utf-8")
    return template.replace(TEMPLATE_ITEM, COLOR_ON + name + COLOR_OFF + b"!")


# ----------------------------------------------------------------------------- MSBT labels

def _label_hash(label, buckets):
    h = 0
    for c in label.encode("utf-8"):
        h = (h * 0x492 + c) & 0xFFFFFFFF
    return h % buckets


def _lbl1(d, o, size):
    """[[(label, text index)] per bucket] of an LBL1 section at offset o."""
    b = o + 0x10
    n = struct.unpack_from("<I", d, b)[0]
    buckets = []
    for i in range(n):
        cnt, off = struct.unpack_from("<II", d, b + 4 + i * 8)
        p, entries = b + off, []
        for _ in range(cnt):
            ln = d[p]
            entries.append((d[p + 1:p + 1 + ln].decode("utf-8"), struct.unpack_from("<I", d, p + 1 + ln)[0]))
            p += 5 + ln
        buckets.append(entries)
    return buckets


def _lbl1_body(buckets):
    n = len(buckets)
    head, names = bytearray(struct.pack("<I", n)), bytearray()
    off = 4 + 8 * n
    for entries in buckets:
        head += struct.pack("<II", len(entries), off + len(names))
        for label, index in entries:
            raw = label.encode("utf-8")
            names += bytes([len(raw)]) + raw + struct.pack("<I", index)
    return bytes(head + names)


def msbt_add(d, new):
    """MSBT `d` with labels added ({label: raw text incl. terminator}); existing labels are replaced in place.
    Only files whose sections are LBL1 and TXT2 are supported (all EventFlowMsg files of the remake)."""
    sections = F._msbt_sections(d)
    if sorted(m for m, _, _ in sections) != [b"LBL1", b"TXT2"]:
        raise ScrubTextError("unexpected MSBT sections %s" % [m for m, _, _ in sections])
    labels, texts = F.msbt_raw(d)
    texts = list(texts)
    lbl = next((o, s) for m, o, s in sections if m == b"LBL1")
    buckets = _lbl1(d, *lbl)
    if _lbl1_body(buckets) != d[lbl[0] + 0x10:lbl[0] + 0x10 + lbl[1]]:
        raise ScrubTextError("label table does not rebuild byte for byte")
    for label, raw in new.items():
        if label in labels:
            texts[labels[label]] = raw
            continue
        labels[label] = len(texts)
        texts.append(raw)
        buckets[_label_hash(label, len(buckets))].append((label, labels[label]))
    out = bytearray(d[:0x20])
    for magic, o, size in sections:
        if magic == b"LBL1":
            body = _lbl1_body(buckets)
        else:
            body = bytearray(struct.pack("<I", len(texts)))
            off = 4 + 4 * len(texts)
            for t in texts:
                body += struct.pack("<I", off)
                off += len(t)
            for t in texts:
                body += t
        out += magic + struct.pack("<I", len(body)) + d[o + 8:o + 0x10] + body
        while len(out) % 16:
            out.append(0xAB)
    struct.pack_into("<I", out, 0x12, len(out))
    return bytes(out)


# ----------------------------------------------------------------------------- patch

def write(world, scrubs, read, emit, progress=print):
    """scrubs: [(event names, item name)] for the shuffled scrubs. Adds each scrub's sale line in every language
    and points its purchase calls at it. Returns the number of scrubs changed."""
    if not scrubs:
        return 0
    mals = sorted(fn for fn in world.files.listdir("Mals") if fn.endswith(".sarc.zs"))
    template_fn = next((fn for fn in mals if fn.startswith(TEMPLATE_LANGUAGE)), None)
    if template_fn is None:
        raise ScrubTextError("no %s message archive" % TEMPLATE_LANGUAGE)
    labels, texts = F.msbt_raw(F.sarc_files(read("Mals/" + template_fn)[0])[MESSAGES])
    if TEMPLATE_LABEL not in labels:
        raise ScrubTextError("no %s line" % TEMPLATE_LABEL)
    template = texts[labels[TEMPLATE_LABEL]]
    lines = {LABEL_PREFIX + events[0]: sale_line(template, name) for events, name in scrubs}

    # the flow first: if its events are not as expected, no text is written
    orig, dname = read(FLOW)
    doc = evfl.read(orig)
    by_name = {e.name: e for e in doc.flowchart.events}
    for events, _ in scrubs:
        for ev in events:
            e = by_name.get(ev)
            if e is None or "SellerMessageId" not in (getattr(e, "params", None) or {}):
                raise ScrubTextError("%s has no sale line in %s" % (ev, FLOW))
            e.params["SellerMessageId"] = "%s:%s%s" % (MESSAGE_FILE, LABEL_PREFIX, events[0])
    new_flow = evfl.write(doc)
    if evfl.read(new_flow) != doc:
        raise ScrubTextError("the scrub flow does not read back")

    done = 0
    for fn in mals:
        rel = "Mals/" + fn
        arc, adict = read(rel)
        files = F.sarc_files(arc)
        msbt = files.get(MESSAGES)
        if msbt is None:
            continue
        if msbt[0xC] != 0:
            progress("warning: %s scrub text is not UTF-8; skipped for it" % fn)
            continue
        emit(rel, arc, F.sarc_rebuild(arc, replace={MESSAGES: msbt_add(msbt, lines)}), adict)
        done += 1
    if not done:
        raise ScrubTextError("no message archive holds %s" % MESSAGES)
    emit(FLOW, orig, new_flow, dname)
    progress("Business Scrubs: %d sale lines name their item (%d languages)" % (len(scrubs), done))
    return len(scrubs)
