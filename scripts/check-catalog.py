#!/usr/bin/env python3
"""Validate the small shared device catalog with Python's standard library."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LEVELS = {"documented", "synthetic-tested", "hardware-verified"}
STAGES = {"awake", "light", "deep", "rem"}


def check_catalog():
    seen = set()
    profiles = sorted((ROOT / "devices").glob("*/firmware/*.json"))
    if not profiles:
        raise ValueError("No device profiles found")
    for path in profiles:
        p = json.loads(path.read_text())
        label = str(path.relative_to(ROOT))
        def require(condition, message):
            if not condition:
                raise ValueError(f"{label}: {message}")
        require(p["formatVersion"] == 1, "unknown formatVersion")
        require(p["deviceID"] == path.parent.parent.name, "deviceID differs from directory")
        require(p["firmware"] == path.stem, "firmware differs from exact version filename")
        require(isinstance(p["id"], str) and p["id"] and p["id"] not in seen, "invalid/duplicate profile ID")
        seen.add(p["id"])
        require(p["status"] in LEVELS, "unknown evidence level")
        require((ROOT / "protocols" / p["protocolID"] / "README.md").is_file(), "missing protocol")
        evidence = (path.parent / p["evidence"]).resolve()
        require(evidence.is_relative_to(ROOT / "devices") and evidence.is_file(), "missing/outside evidence")
        require(isinstance(p["implementations"], dict) and p["implementations"], "missing implementation evidence")
        for platform, level in p["implementations"].items():
            require((ROOT / "platforms" / platform / "README.md").is_file(), "missing platform")
            require(level in LEVELS, "unknown platform evidence level")
        commands = p["historyCommands"]
        require(isinstance(commands, list) and len(commands) == len(set(commands)), "duplicate commands")
        require(all(type(c) is int and 0 <= c <= 255 for c in commands), "invalid command byte")
        stages = p["sleepStages"]
        require(all(k.isdecimal() and 0 <= int(k) <= 255 and v in STAGES for k, v in stages.items()), "invalid sleep mapping")
        unknown = p["unknownSleepCodes"]
        require(all(type(c) is int and 0 <= c <= 255 for c in unknown), "invalid unknown sleep code")
        require(not {int(k) for k in stages}.intersection(unknown), "mapped code also marked unknown")
        require(isinstance(p["limitations"], list) and all(isinstance(x, str) and x for x in p["limitations"]) and p["limitations"], "missing limitations")
    print(f"Catalog: {len(profiles)} exact firmware profile(s) valid")


if __name__ == "__main__":
    check_catalog()
