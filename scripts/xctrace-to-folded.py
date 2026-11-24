#!/usr/bin/env python3
"""Convert an `xctrace export` of the time-profile table to folded stacks for speedscope.

usage: xctrace-to-folded.py <time-profile.xml> <out-prefix> [focus-regex]

Writes:
  <out-prefix>.all.folded      every sample, one root per thread
  <out-prefix>.focus.folded    only samples whose stack matches focus-regex
                               (default: queryLoop|FileIndex\\.search)

Folded format is "root;...;leaf <weight-in-microseconds>", which speedscope imports directly.
"""
import re
import sys
import collections
import xml.etree.ElementTree as ET

src, prefix = sys.argv[1], sys.argv[2]
focus = re.compile(sys.argv[3] if len(sys.argv) > 3 else r"queryLoop|FileIndex\.search")

frame_names = {}   # frame id -> name
threads = {}       # thread id -> label
backtraces = {}    # backtrace id -> [names, leaf first]
weights = {}       # weight id -> microseconds


def frame_name(el):
    if "ref" in el.attrib:
        return frame_names[el.attrib["ref"]]
    name = el.attrib.get("name", "?")
    # keep libs apart from app frames when the name is only an address
    binary = el.find("binary")
    if name.startswith("0x") and binary is not None and "name" in binary.attrib:
        name = f"{binary.attrib['name']}+{name}"
    frame_names[el.attrib["id"]] = name
    return name


all_stacks = collections.Counter()
focus_stacks = collections.Counter()
rows = 0

for _, el in ET.iterparse(src, events=("end",)):
    if el.tag != "row":
        continue
    rows += 1

    th = el.find("thread")
    if th is not None:
        if "ref" in th.attrib:
            label = threads[th.attrib["ref"]]
        else:
            label = th.attrib.get("fmt", "thread").split(" (")[0]
            tid = th.find("tid")
            if tid is not None:
                label = f"{label} [{tid.text}]"
            threads[th.attrib["id"]] = label
    else:
        label = "?"

    w = el.find("weight")
    if w is not None:
        if "ref" in w.attrib:
            us = weights[w.attrib["ref"]]
        else:
            us = int(w.text) // 1000
            weights[w.attrib["id"]] = us
    else:
        us = 1000

    bt = el.find("tagged-backtrace")
    if bt is None:
        el.clear()
        continue
    if "ref" in bt.attrib:
        names = backtraces[bt.attrib["ref"]]
    else:
        names = [frame_name(f).replace(";", ":") for f in bt.findall("frame")]
        backtraces[bt.attrib["id"]] = names

    stack = ";".join([label] + names[::-1])  # leaf is first in the export
    all_stacks[stack] += us
    if focus.search(stack):
        focus_stacks[stack] += us
    el.clear()


def write(path, counter):
    with open(path, "w") as f:
        for stack, us in counter.items():
            f.write(f"{stack} {us}\n")


write(prefix + ".all.folded", all_stacks)
write(prefix + ".focus.folded", focus_stacks)
tot = sum(all_stacks.values()) / 1000
ftot = sum(focus_stacks.values()) / 1000
print(f"{rows} samples: {tot:.0f} ms total, {ftot:.0f} ms in stacks matching /{focus.pattern}/")
