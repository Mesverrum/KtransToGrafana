#!/usr/bin/env python3
"""Backward-compatible entry point — use scripts/split-devices.py."""
from pathlib import Path
import runpy

runpy.run_path(str(Path(__file__).with_name("split-devices.py")), run_name="__main__")
