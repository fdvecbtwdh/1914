#!/usr/bin/env python3
"""1914 数据/资源一致性检查：卡牌 JSON 可解析、字段完整、ID 唯一、卡组引用有效。
退出码 = 错误数。"""

import json
import sys
from pathlib import Path

cards = {}

ROOT = Path(__file__).resolve().parent.parent
UNITS_DIR = ROOT / "data" / "cards" / "units"
DECKS_DIR = ROOT / "data" / "decks"

REQUIRED_FIELDS = {
    "id": str,
    "name": str,
    "type": str,
    "unit_class": str,
    "cost_g": int,
    "cost_z": int,
    "attack": int,
    "defense": int,
    "abilities": list,
    "rarity": str,
}
RARITIES = {"common", "silver", "gold"}
errors = []


def err(path, msg):
    errors.append(f"{path}: {msg}")


def main():
    if not UNITS_DIR.is_dir():
        errors.append(f"missing directory: {UNITS_DIR}")
        return finish()

    for f in sorted(UNITS_DIR.glob("*.json")):
        try:
            data = json.loads(f.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, UnicodeDecodeError) as e:
            err(f, f"invalid JSON: {e}")
            continue
        for field, expected in REQUIRED_FIELDS.items():
            if field not in data:
                err(f, f"missing field '{field}'")
            elif not isinstance(data[field], expected) or isinstance(data[field], bool):
                err(f, f"field '{field}' has wrong type (expected {expected.__name__})")
        if "id" in data:
            cid = data["id"]
            if cid in cards:
                err(f, f"duplicate card id '{cid}' (also in {cards[cid]})")
            cards[cid] = f
        if data.get("rarity") not in RARITIES:
            err(f, f"invalid rarity '{data.get('rarity')}'")
        for field in ("cost_g", "cost_z", "attack", "defense"):
            v = data.get(field)
            if isinstance(v, int) and not isinstance(v, bool) and v < 0:
                err(f, f"'{field}' must be >= 0")
        # 视野/射程必须是引擎认识的取值
        known_ranges = {
            "adjacent_4", "adjacent_8", "adjacent_8_forward",
            "front_3x2", "front_3x3", "frontline_only", "column_and_neighbors", "global", "none",
        }
        for field in ("vision_range", "attack_range"):
            if field in data and data[field] not in known_ranges:
                err(f, f"unknown {field} '{data[field]}'")

    for f in sorted(DECKS_DIR.glob("*.json")):
        try:
            deck = json.loads(f.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, UnicodeDecodeError) as e:
            err(f, f"invalid JSON: {e}")
            continue
        for cid in deck.get("cards", []):
            if cid not in cards:
                err(f, f"deck references unknown card '{cid}'")
        starter = deck.get("starter")
        if starter and starter not in cards:
            err(f, f"deck starter references unknown card '{starter}'")

    return finish()


def finish():
    if errors:
        print(f"[validate_data] {len(errors)} ERROR(S):")
        for e in errors:
            print("  ERROR:", e)
    else:
        print(f"[validate_data] OK — {len(cards)} cards, all decks valid")
    sys.exit(min(len(errors), 255))


if __name__ == "__main__":
    main()
