"""
Visual check for `fade.nvim`.

Everything marked DIM below should fade; everything marked KEEP should stay at full
brightness. The point of the per-token blend is that faded code still shows its own
colors -- a faded keyword, string and number should still differ from each other,
rather than all collapsing to one gray.
"""


# ─── Imports ────────────────────────────────────────────────

import json.decoder  # DIM  dotted: both `json` and `decoder` fade, as separate tokens
import os  # DIM  `os` only -- the `import` keyword stays bright
import sys  # KEEP  used at the bottom
from collections import OrderedDict  # KEEP  used below
from pathlib import Path  # DIM  `Path` only
from typing import Any as Anything  # DIM  the alias `Anything`, not `Any`


# ─── Locals ─────────────────────────────────────────────────
def locals_demo(width, height):
    """Both basedpyright and ruff flag `area`; it must get ONE extmark, not two."""
    area = width * height  # DIM  `area` fades, `width * height` stays bright
    perimeter = 2 * (width + height)  # KEEP  returned
    return perimeter


def partial_line():
    """Shows the range boundary: the name fades, the call it is assigned does not."""
    result = locals_demo(3, 4)  # DIM  `result` only -- `locals_demo(3, 4)` stays bright
    return 42


# ─── Unreachable Code ───────────────────────────────────────
def unreachable_demo(flag):
    """The clearest per-token test: a whole faded block that keeps its syntax colors."""
    total = 0
    for index in range(10):
        total += index * 2
    print(f"unreachable {total}")

    if flag:
        return "early"
    return "late"

    # DIM  everything below -- keyword, string, number and call should each stay
    # distinguishable from one another while faded
    total = 0
    for index in range(10):
        total += index * 2
    print(f"unreachable {total}")
    raise RuntimeError("never runs")


# ─── Unused Definitions ─────────────────────────────────────
def _unused_helper(value):  # DIM  `_unused_helper` -- private and never called
    return value * 2


class _UnusedClass:  # DIM  `_UnusedClass`
    """Private, never instantiated."""

    def method(self):
        return None


class UsedClass:  # KEEP  instantiated below
    def __init__(self):
        self.cache = OrderedDict()

    def store(self, key, value):
        unused_temp = key.upper()  # DIM  `unused_temp`
        self.cache[key] = value
        return len(self.cache)


# ─── Live Code (all KEEP) ───────────────────────────────────
def main():
    holder = UsedClass()
    holder.store("alpha", 1)
    holder.store("beta", 2)
    print(locals_demo(2, 3), partial_line(), unreachable_demo(True))
    print(sys.version_info.major)
    return 0


if __name__ == "__main__":
    main()
