#!/usr/bin/env python3
"""Parse macOS `sample` tool call-tree output into self-time per symbol.

`sample <pid> <seconds> -f out.txt` (or Instruments' Time Profiler exported as
text) prints an inclusive call tree, not a flat self-time table. This walks
the tree — depth is derived from indentation width, not from the `+!:|`
tree-drawing characters, which are sparse and undercount depth — and derives
each symbol's self time as (its own count) - (sum of its direct children's
counts), aggregated across every call site that symbol appears at.

Usage: python3 scripts/parse_sample_profile.py <sample-output.txt>

See docs/develop/RELEASE_PERFORMANCE.md for how this was used.
"""
import re
import sys
from collections import defaultdict

path = sys.argv[1]

# A tree line looks like:
#   <indent><count> <symbol desc>
# indent consists of spaces plus tree-drawing chars: + ! : | (and trailing spaces)
line_re = re.compile(r'^([ +!:|]*)(\d+)\s+(.*)$')

def depth_of(prefix: str) -> int:
    # Each tree level is a fixed 2-character column (either "  " or a
    # connector like "+ "/"! "/": "/"| "). Depth is prefix length / 2.
    return len(prefix) // 2

nodes = []  # list of [depth, count, symbol]
with open(path, encoding='utf-8', errors='replace') as f:
    started = False
    for raw in f:
        line = raw.rstrip('\n')
        if 'Call graph:' in line:
            started = True
            continue
        if not started:
            continue
        if line.strip().startswith('Total number in stack'):
            break
        m = line_re.match(line)
        if not m:
            continue
        prefix, count, symbol = m.groups()
        d = depth_of(prefix)
        nodes.append([d, int(count), symbol.strip()])

# Self time = count - sum(direct children's counts). Children are the
# immediately following nodes at depth+1, until a node at depth <= d.
child_sum = [0] * len(nodes)
stack = []  # indices whose children we're accumulating into
for i, (d, c, s) in enumerate(nodes):
    while stack and nodes[stack[-1]][0] >= d:
        stack.pop()
    if stack:
        child_sum[stack[-1]] += c
    stack.append(i)

self_by_symbol = defaultdict(int)
incl_by_symbol = defaultdict(int)
for i, (d, c, s) in enumerate(nodes):
    sym_name = re.split(r'\s+\(in ', s)[0]  # drop "(in Module) + offset [addr]"
    self_by_symbol[sym_name] += c - child_sum[i]
    incl_by_symbol[sym_name] += c

print("=== Top self-time (own cost, samples) ===")
for sym, t in sorted(self_by_symbol.items(), key=lambda kv: -kv[1])[:30]:
    print(f"{t:8d}  {sym}")

print()
print("=== Top inclusive-time (cumulative, samples) ===")
for sym, t in sorted(incl_by_symbol.items(), key=lambda kv: -kv[1])[:20]:
    print(f"{t:8d}  {sym}")

total_root = nodes[0][1] if nodes else 0
print(f"\nRoot sample count: {total_root}")
