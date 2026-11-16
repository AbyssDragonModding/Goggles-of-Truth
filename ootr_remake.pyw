#!/usr/bin/env python3
"""Old start file, kept so shortcuts and pre-0.6.0 updates still work: opens goggles_of_truth_rando.pyw.

Since 0.6.0 the randomizer starts from goggles_of_truth_rando.pyw. A 0.5.x copy restarts itself from this file
after updating, and some people have shortcuts to it.
"""
import os
import runpy
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
NEW = os.path.join(HERE, "goggles_of_truth_rando.pyw")

if __name__ == "__main__":
    sys.argv[0] = NEW
    runpy.run_path(NEW, run_name="__main__")
