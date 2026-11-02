#!/usr/bin/env python3
"""Draws the FreeFlow Web DFDs and BPM as SVG and checks the DFD rules from the data they are drawn from.

Run from anywhere: scripts/build-system-diagrams.py
Writes docs/system/diagrams/*.svg. Exits non-zero if a balancing or flow rule fails.
"""
import sys
from html import escape
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "docs" / "system" / "diagrams"
INK, MAROON, TAN, PALE, GREY = "#222222", "#782F40", "#F3ECDD", "#FAF7F0", "#777777"
FONT = "Helvetica, Arial, sans-serif"


def text_lines(x, y, s, size, anchor="middle", weight="normal", fill=INK, halo=False):
    rows = s.split("\n")
    y0 = y - (len(rows) - 1) * (size + 2) / 2
    halo_attr = ' stroke="#fff" stroke-width="4" paint-order="stroke"' if halo else ""
    out = []
    for i, row in enumerate(rows):
        out.append(
            f'<text x="{x}" y="{y0 + i * (size + 2):.1f}" font-size="{size}" text-anchor="{anchor}" '
            f'dominant-baseline="middle" font-weight="{weight}" fill="{fill}"{halo_attr}>{escape(row)}</text>'
        )
    return "".join(out)


class Diagram:
    def __init__(self, name, title, width, height):
        self.name, self.title, self.w, self.h = name, title, width, height
        self.body, self.nodes, self.flows = [], {}, []

    def entity(self, key, label, x, y, w, h, ghost=False):
        self.nodes[key] = "entity"
        fill = "#fff" if ghost else TAN
        dash = ' stroke-dasharray="6 4"' if ghost else ""
        self.body.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" fill="{fill}" stroke="{MAROON}" stroke-width="1.5"{dash}/>')
        self.body.append(text_lines(x + w / 2, y + h / 2, label, 14, weight="bold"))

    def process(self, key, num, label, x, y, w, h, note=None, ghost=False):
        self.nodes[key] = "ghost-process" if ghost else "process"
        dash = ' stroke-dasharray="6 4"' if ghost else ""
        self.body.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="12" fill="#fff" stroke="{MAROON}" stroke-width="1.5"{dash}/>')
        self.body.append(f'<line x1="{x}" y1="{y + 24}" x2="{x + w}" y2="{y + 24}" stroke="{MAROON}" stroke-width="1.2"{dash}/>')
        self.body.append(text_lines(x + w / 2, y + 13, num, 13, weight="bold", fill=MAROON))
        center = y + 24 + (h - 24) / 2 - (9 if note else 0)
        self.body.append(text_lines(x + w / 2, center, label, 14, weight="bold"))
        if note:
            self.body.append(text_lines(x + w / 2, y + h - 13, note, 12, fill=MAROON))

    def store(self, key, code, label, x, y, w, h=45):
        self.nodes[key] = "store"
        self.body.append(f'<rect x="{x}" y="{y}" width="46" height="{h}" fill="{TAN}" stroke="{MAROON}" stroke-width="1.5"/>')
        self.body.append(f'<path d="M{x + 46} {y} H{x + w} M{x + 46} {y + h} H{x + w}" stroke="{MAROON}" stroke-width="1.5" fill="none"/>')
        self.body.append(text_lines(x + 23, y + h / 2, code, 13, weight="bold", fill=MAROON))
        self.body.append(text_lines(x + 46 + (w - 46) / 2, y + h / 2, label, 14, weight="bold"))

    def flow(self, src, dst, label, pts, at, both=False, anchor="middle"):
        """pts run from src to dst. both=True is a read-before-update flow between a process and a store."""
        self.flows.append((src, dst, label.replace("\n", " "), both))
        path = "M" + " L".join(f"{x} {y}" for x, y in pts)
        start = ' marker-start="url(#tail)"' if both else ""
        self.body.append(f'<path d="{path}" fill="none" stroke="{INK}" stroke-width="1.3" marker-end="url(#head)"{start}/>')
        self.labels = getattr(self, "labels", [])
        self.labels.append(text_lines(at[0], at[1], label, 13, anchor=anchor, halo=True))

    def svg(self):
        labels = "".join(getattr(self, "labels", []))
        return (
            f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {self.w} {self.h}" width="{self.w}" height="{self.h}" '
            f'role="img" aria-label="{escape(self.title)}" font-family="{FONT}">'
            f'<title>{escape(self.title)}</title>'
            f'<defs><marker id="head" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" orient="auto">'
            f'<path d="M0 0 L10 5 L0 10 z" fill="{INK}"/></marker>'
            f'<marker id="tail" viewBox="0 0 10 10" refX="1" refY="5" markerWidth="8" markerHeight="8" orient="auto">'
            f'<path d="M10 0 L0 5 L10 10 z" fill="{INK}"/></marker></defs>'
            f'<rect width="{self.w}" height="{self.h}" fill="#fff"/>' + "".join(self.body) + labels + "</svg>"
        )


# ----- Context diagram -----
ctx = Diagram("context", "Context diagram for FreeFlow Web", 1120, 620)
ctx.entity("Student", "Student", 30, 100, 130, 480)
ctx.entity("Coordinator", "Study Group\nCoordinator", 960, 190, 130, 280)
ctx.entity("Speech", "Browser Speech\nService", 455, 12, 190, 55)
ctx.process("0", "0", "FreeFlow Web\nSystem", 420, 110, 260, 470)
for i, (label, inbound) in enumerate([
    ("Spoken Audio", True), ("Typed Text", True), ("Cleanup Choices", True), ("Lecture Details", True), ("History Request", True),
    ("Rule Error Message", False), ("Finished Text", False), ("Lecture Status", False), ("Study Notes", False),
    ("History Results", False), ("Usage Report", False),
]):
    y = 130 + i * 42
    if inbound:
        ctx.flow("Student", "0", label, [(160, y), (420, y)], (290, y - 12))
    else:
        ctx.flow("0", "Student", label, [(420, y), (160, y)], (290, y - 12))
ctx.flow("0", "Speech", "Audio Stream", [(510, 110), (510, 67)], (500, 88), anchor="end")
ctx.flow("Speech", "0", "Recognized Text", [(590, 67), (590, 110)], (600, 88), anchor="start")
for y, label, inbound in [(230, "Dictionary Change", True), (290, "Dictionary Result", False),
                          (350, "Settings Command", True), (410, "Settings and Purge Report", False)]:
    if inbound:
        ctx.flow("Coordinator", "0", label, [(960, y), (680, y)], (820, y - 12))
    else:
        ctx.flow("0", "Coordinator", label, [(680, y), (960, y)], (820, y - 12))

# ----- Level-0 DFD -----
l0 = Diagram("level0", "Level-0 DFD for FreeFlow Web", 1620, 680)
l0.entity("Student", "Student", 30, 90, 120, 570)
l0.entity("Speech", "Browser Speech\nService", 330, 12, 180, 56)
l0.entity("Coordinator", "Study Group\nCoordinator", 1480, 150, 120, 420)
l0.process("1.0", "1.0", "Capture\nDictation", 330, 130, 180, 100, note="BR-01, BR-02")
l0.process("2.0", "2.0", "Clean and\nStore Text", 680, 130, 180, 100, note="BR-03, 04, 05, 06")
l0.process("3.0", "3.0", "Maintain Course\nDictionary", 1000, 480, 180, 90, note="BR-07, BR-08")
l0.process("4.0", "4.0", "Run Lecture\nSession", 330, 320, 180, 90, note="BR-09")
l0.process("5.0", "5.0", "Review and\nReport History", 330, 540, 180, 90)
l0.process("6.0", "6.0", "Maintain Settings\nand Retention", 1170, 150, 170, 90, note="BR-08, BR-10")
l0.store("D1", "D1", "ff_dictations", 960, 300, 200)
l0.store("D2", "D2", "ff_dictionary", 680, 320, 180)
l0.store("D3", "D3", "ff_lectures", 530, 450, 180)
l0.store("D4", "D4", "ff_settings", 1160, 30, 190)

l0.flow("Student", "1.0", "Spoken Audio", [(150, 150), (330, 150)], (240, 139))
l0.flow("Student", "1.0", "Typed Text", [(150, 180), (330, 180)], (240, 169))
l0.flow("1.0", "Student", "Rule Error Message", [(330, 212), (150, 212)], (240, 201))
l0.flow("1.0", "Speech", "Audio Stream", [(390, 130), (390, 68)], (382, 99), anchor="end")
l0.flow("Speech", "1.0", "Recognized Text", [(450, 68), (450, 130)], (458, 99), anchor="start")
l0.flow("1.0", "2.0", "Validated\nTranscript", [(510, 180), (680, 180)], (595, 160))
l0.flow("1.0", "4.0", "Lecture Segment", [(420, 230), (420, 320)], (430, 303), anchor="start")
l0.flow("Student", "2.0", "Cleanup Choices", [(150, 255), (705, 255), (705, 230)], (250, 244))
l0.flow("2.0", "Student", "Finished Text", [(735, 230), (735, 283), (150, 283)], (250, 272))
l0.flow("D2", "2.0", "Dictionary\nEntries", [(760, 320), (760, 230)], (752, 278), anchor="end")
l0.flow("2.0", "D2", "Term Usage\nCount", [(825, 230), (825, 320)], (833, 278), anchor="start")
l0.flow("D4", "2.0", "Style Defaults", [(1160, 52), (770, 52), (770, 130)], (960, 41))
l0.flow("2.0", "D1", "New Dictation\nRecord", [(860, 205), (1010, 205), (1010, 300)], (940, 184))
l0.flow("Student", "4.0", "Lecture Details", [(150, 340), (330, 340)], (240, 329))
l0.flow("4.0", "Student", "Lecture Status", [(330, 365), (150, 365)], (240, 354))
l0.flow("4.0", "Student", "Study Notes", [(330, 392), (150, 392)], (240, 381))
l0.flow("D2", "4.0", "Dictionary Entries", [(680, 342), (510, 342)], (595, 331))
l0.flow("4.0", "D3", "Lecture Records", [(510, 392), (620, 392), (620, 450)], (628, 420), both=True, anchor="start")
l0.flow("D3", "5.0", "Lecture Records", [(600, 495), (600, 565), (510, 565)], (610, 530), anchor="start")
l0.flow("Student", "5.0", "History Request", [(150, 560), (330, 560)], (240, 549))
l0.flow("5.0", "Student", "History Results", [(330, 586), (150, 586)], (240, 575))
l0.flow("5.0", "Student", "Usage Report", [(330, 612), (150, 612)], (240, 601))
l0.flow("5.0", "D1", "Dictation Records", [(510, 608), (900, 608), (900, 322), (960, 322)], (700, 597), both=True)
l0.flow("6.0", "D4", "Settings", [(1255, 150), (1255, 75)], (1263, 112), both=True, anchor="start")
l0.flow("6.0", "D1", "Dictation Records", [(1230, 240), (1230, 322), (1160, 322)], (1238, 281), both=True, anchor="start")
l0.flow("Coordinator", "6.0", "Settings Command", [(1480, 175), (1340, 175)], (1410, 164))
l0.flow("6.0", "Coordinator", "Settings and\nPurge Report", [(1340, 215), (1480, 215)], (1410, 240))
l0.flow("3.0", "D2", "Dictionary Entries", [(1000, 525), (770, 525), (770, 365)], (850, 514), both=True)
l0.flow("Coordinator", "3.0", "Dictionary Change", [(1480, 505), (1180, 505)], (1330, 494))
l0.flow("3.0", "Coordinator", "Dictionary Result", [(1180, 545), (1480, 545)], (1330, 534))

# ----- Level-1 for 1.0 -----
l1a = Diagram("level1-1", "Level-1 DFD exploding process 1.0 Capture Dictation", 1400, 450)
l1a.entity("Student", "Student", 30, 100, 130, 300)
l1a.entity("Speech", "Browser Speech\nService", 320, 12, 190, 55)
l1a.process("1.1", "1.1", "Receive Speech\nor Text", 320, 130, 190, 100)
l1a.process("1.2", "1.2", "Validate Word\nLimits", 650, 130, 190, 100, note="BR-01, BR-02")
l1a.process("1.3", "1.3", "Route\nTranscript", 980, 130, 170, 100)
l1a.process("2.0", "2.0", "Clean and\nStore Text", 1240, 40, 140, 90, ghost=True)
l1a.process("4.0", "4.0", "Run Lecture\nSession", 1240, 240, 140, 90, ghost=True)
l1a.flow("Student", "1.1", "Spoken Audio", [(160, 155), (320, 155)], (240, 144))
l1a.flow("Student", "1.1", "Typed Text", [(160, 205), (320, 205)], (240, 194))
l1a.flow("1.1", "Speech", "Audio Stream", [(380, 130), (380, 67)], (372, 98), anchor="end")
l1a.flow("Speech", "1.1", "Recognized Text", [(450, 67), (450, 130)], (458, 98), anchor="start")
l1a.flow("1.1", "1.2", "Captured Text", [(510, 180), (650, 180)], (580, 169))
l1a.flow("1.2", "1.3", "Checked Text", [(840, 180), (980, 180)], (910, 169))
l1a.flow("1.2", "Student", "Rule Error Message", [(745, 230), (745, 350), (160, 350)], (450, 339))
l1a.flow("1.3", "2.0", "Validated\nTranscript", [(1150, 160), (1195, 160), (1195, 85), (1240, 85)], (1195, 60))
l1a.flow("1.3", "4.0", "Lecture\nSegment", [(1150, 200), (1195, 200), (1195, 285), (1240, 285)], (1195, 310))

# ----- Level-1 for 2.0 -----
l1b = Diagram("level1-2", "Level-1 DFD exploding process 2.0 Clean and Store Text", 1360, 500)
l1b.process("1.0", "1.0", "Capture\nDictation", 30, 60, 130, 90, ghost=True)
l1b.entity("Student", "Student", 30, 270, 130, 190)
l1b.process("2.1", "2.1", "Apply Course\nDictionary", 230, 215, 170, 100, note="BR-05")
l1b.process("2.2", "2.2", "Remove Fillers and\nCheck Meaning", 530, 215, 180, 100, note="BR-04")
l1b.process("2.3", "2.3", "Apply Destination\nStyle", 840, 215, 170, 100, note="BR-06")
l1b.process("2.4", "2.4", "Save and\nReturn Text", 1130, 215, 170, 100, note="BR-03")
l1b.store("D2", "D2", "ff_dictionary", 225, 60, 180)
l1b.store("D4", "D4", "ff_settings", 835, 60, 180)
l1b.store("D1", "D1", "ff_dictations", 1115, 60, 200)
l1b.flow("1.0", "2.1", "Validated Transcript", [(160, 105), (195, 105), (195, 245), (230, 245)], (190, 170), anchor="middle")
l1b.flow("Student", "2.1", "Cleanup Choices", [(160, 295), (230, 295)], (195, 330))
l1b.flow("D2", "2.1", "Dictionary\nEntries", [(285, 105), (285, 215)], (277, 160), anchor="end")
l1b.flow("2.1", "D2", "Term Usage\nCount", [(345, 215), (345, 105)], (353, 160), anchor="start")
l1b.flow("2.1", "2.2", "Spelled Transcript\nand Choices", [(400, 265), (530, 265)], (465, 240))
l1b.flow("2.2", "2.3", "Cleaned Draft\nand Choices", [(710, 265), (840, 265)], (775, 240))
l1b.flow("D4", "2.3", "Style Defaults", [(925, 105), (925, 215)], (933, 160), anchor="start")
l1b.flow("2.3", "2.4", "Styled Text", [(1010, 265), (1130, 265)], (1070, 254))
l1b.flow("2.4", "D1", "New Dictation Record", [(1215, 215), (1215, 105)], (1223, 160), anchor="start")
l1b.flow("2.4", "Student", "Finished Text", [(1215, 315), (1215, 420), (160, 420)], (690, 409))


# ----- Rule checks -----
def endpoints(flows):
    out = set()
    for src, dst, label, both in flows:
        out.add((src, dst, label))
        if both:
            out.add((dst, src, label))
    return out


def check():
    errors = []
    for d in (ctx, l0, l1a, l1b):
        kinds = d.nodes
        for src, dst, label, both in d.flows:
            pair = {kinds[src], kinds[dst]}
            if kinds[src] == kinds[dst] and kinds[src] in ("entity", "store"):
                errors.append(f"{d.name}: {label} runs {kinds[src]} to {kinds[dst]}")
            if pair == {"entity", "store"}:
                errors.append(f"{d.name}: {label} runs entity to store")
            if not label.strip():
                errors.append(f"{d.name}: unnamed flow {src}->{dst}")
        flows = endpoints(d.flows)
        for key, kind in kinds.items():
            if kind == "process":
                if not any(s == key for s, _, _ in flows):
                    errors.append(f"{d.name}: {key} is a black hole")
                if not any(t == key for _, t, _ in flows):
                    errors.append(f"{d.name}: {key} is a miracle")

    # Context stays free of data stores.
    if any(k == "store" for k in ctx.nodes.values()):
        errors.append("context: has a data store")

    # Level-0 must balance with the context diagram at the system boundary.
    externals = {"Student", "Speech", "Coordinator"}
    context_io = {(("0" if s == "0" else s), ("0" if t == "0" else t), l) for s, t, l in endpoints(ctx.flows)}
    level0_io = {("0" if s not in externals else s, "0" if t not in externals else t, l)
                 for s, t, l in endpoints(l0.flows) if (s in externals) != (t in externals)}
    if context_io != level0_io:
        errors.append(f"Level-0 and context differ: {sorted(context_io ^ level0_io, key=str)}")

    # Every Level-1 must balance with its parent's flows on Level-0.
    for parent, child in (("1.0", l1a), ("2.0", l1b)):
        own = {k for k, v in child.nodes.items() if v == "process"}
        l1_io = {(parent if s in own else s, parent if t in own else t, l)
                 for s, t, l in endpoints(child.flows) if (s in own) != (t in own)}
        parent_io = {(s, t, l) for s, t, l in endpoints(l0.flows) if parent in (s, t)}
        if l1_io != parent_io:
            errors.append(f"Level-1 of {parent} differs from its parent: {sorted(l1_io ^ parent_io, key=str)}")

    # Every store is read and written by a process.
    flows = endpoints(l0.flows)
    for key, kind in l0.nodes.items():
        if kind == "store":
            if not any(s == key for s, _, _ in flows):
                errors.append(f"{key} is never read")
            if not any(t == key for _, t, _ in flows):
                errors.append(f"{key} is never written")
    return errors


# ----- BPM -----
def bpm_svg():
    w, h = 1600, 520
    b = []
    labels = []

    def arrow(pts, dashed=False):
        path = "M" + " L".join(f"{x} {y}" for x, y in pts)
        dash = ' stroke-dasharray="7 5"' if dashed else ""
        color = MAROON if dashed else INK
        marker = "headx" if dashed else "head"
        b.append(f'<path d="{path}" fill="none" stroke="{color}" stroke-width="1.5"{dash} marker-end="url(#{marker})"/>')

    def task(x, y, label, tag):
        system = tag != "manual"
        fill = "#fff" if system else TAN
        b.append(f'<rect x="{x}" y="{y}" width="160" height="72" rx="10" fill="{fill}" stroke="{MAROON}" stroke-width="1.5"/>')
        b.append(text_lines(x + 80, y + 27, label, 14, weight="bold"))
        b.append(text_lines(x + 80, y + 61, tag, 12, fill=MAROON))

    # Lanes
    for y, lh, name in [(40, 180, "Student"), (220, 280, "FreeFlow Web")]:
        b.append(f'<rect x="20" y="{y}" width="{w - 40}" height="{lh}" fill="{PALE}" stroke="{GREY}"/>')
        b.append(f'<rect x="20" y="{y}" width="36" height="{lh}" fill="{MAROON}"/>')
        cx, cy = 38, y + lh / 2
        b.append(f'<text x="{cx}" y="{cy}" fill="#fff" font-size="14" font-weight="bold" text-anchor="middle" '
                 f'dominant-baseline="middle" transform="rotate(-90 {cx} {cy})">{name}</text>')

    # Flows first, so the shapes sit on top.
    arrow([(112, 130), (130, 130)])
    arrow([(290, 130), (330, 130)])
    arrow([(410, 166), (410, 280)])
    arrow([(490, 316), (530, 316)])
    arrow([(690, 316), (735, 316)])
    arrow([(785, 316), (850, 316)])
    arrow([(1010, 316), (1060, 316)])
    arrow([(1140, 280), (1140, 166)])
    arrow([(1220, 130), (1260, 130)])
    arrow([(1420, 130), (1478, 130)])
    arrow([(760, 341), (760, 418)], dashed=True)
    arrow([(778, 436), (850, 436)], dashed=True)
    arrow([(1010, 436), (1035, 436), (1035, 130), (880, 130)], dashed=True)
    arrow([(720, 130), (490, 130)], dashed=True)

    # Start and end events
    b.append(f'<circle cx="94" cy="130" r="18" fill="#fff" stroke="{INK}" stroke-width="1.5"/>')
    labels.append(text_lines(94, 165, "Start", 12))
    b.append(f'<circle cx="1496" cy="130" r="18" fill="#fff" stroke="{INK}" stroke-width="4"/>')
    labels.append(text_lines(1496, 165, "Text in use", 12))

    task(130, 94, "Choose destination\nand mode", "manual")
    task(330, 94, "Speak or\ntype text", "manual")
    task(720, 94, "Fix the\ninput", "manual")
    task(1060, 94, "Paste into\ndestination app", "manual")
    task(1260, 94, "Proofread and\ncorrect", "manual")
    task(330, 280, "Capture\ntranscript", "system-supported: DFD 1.0")
    task(530, 280, "Validate\nword limits", "system-supported: DFD 1.0")
    task(850, 280, "Clean and\nstyle text", "system-supported: DFD 2.0")
    task(1060, 280, "Save dictation\nrecord", "system-supported: DFD 2.0")
    task(850, 400, "Show error\nciting rule ID", "system-supported: DFD 1.0")

    # Exclusive decision
    b.append(f'<path d="M760 291 L785 316 L760 341 L735 316 z" fill="#fff" stroke="{MAROON}" stroke-width="1.8"/>')
    labels.append(text_lines(760, 316, "X", 14, weight="bold", fill=MAROON))
    labels.append(text_lines(760, 268, "Within limits?\n(BR-01, BR-02)", 13, weight="bold"))
    labels.append(text_lines(818, 305, "Yes", 13, halo=True))
    labels.append(text_lines(772, 376, "No", 13, anchor="start", halo=True))

    # Exception event
    b.append(f'<circle cx="760" cy="436" r="18" fill="#fff" stroke="{MAROON}" stroke-width="1.5"/>')
    b.append(f'<circle cx="760" cy="436" r="14" fill="none" stroke="{MAROON}" stroke-width="1.5"/>')
    labels.append(text_lines(760, 436, "!", 15, weight="bold", fill=MAROON))
    labels.append(text_lines(745, 470, "Exception: rule violated", 13, anchor="middle", fill=MAROON, weight="bold", halo=True))
    labels.append(text_lines(605, 119, "Retry", 13, fill=MAROON, halo=True))

    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" width="{w}" height="{h}" role="img" '
        f'aria-label="BPM for one dictation from start to finish" font-family="{FONT}">'
        f'<title>BPM for one dictation from start to finish</title><defs>'
        f'<marker id="head" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" orient="auto"><path d="M0 0 L10 5 L0 10 z" fill="{INK}"/></marker>'
        f'<marker id="headx" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" orient="auto"><path d="M0 0 L10 5 L0 10 z" fill="{MAROON}"/></marker>'
        f'</defs><rect width="{w}" height="{h}" fill="#fff"/>' + "".join(b) + "".join(labels) + "</svg>"
    )


def main():
    errors = check()
    OUT.mkdir(parents=True, exist_ok=True)
    for d in (ctx, l0, l1a, l1b):
        (OUT / f"{d.name}.svg").write_text(d.svg())
    (OUT / "bpm.svg").write_text(bpm_svg())
    if errors:
        print("DFD rule check FAILED:")
        for e in errors:
            print(" -", e)
        sys.exit(1)
    print("DFD rule check passed: flows, balancing and data stores are consistent.")


if __name__ == "__main__":
    main()
