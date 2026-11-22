class_name ShopData
extends RefCounted

## Boards & strikers (design doc 6.4). Boards are cosmetic only.
## Striker stat differences are SMALL and capped at +15% (doc 6.4).

const BOARDS := [
	{"id": "classic", "name": "Classic Wood", "desc": "Warm honey teak, the original.", "price": 0, "level": 1,
		"surface": Color(0.78, 0.58, 0.32), "surface2": Color(0.72, 0.51, 0.27),
		"frame": Color(0.42, 0.22, 0.12), "line": Color(0.96, 0.94, 0.88), "accent": Color(0.85, 0.16, 0.16)},
	{"id": "mahogany", "name": "Royal Mahogany", "desc": "Dark red-brown wood, gold lines.", "price": 1500, "level": 3,
		"surface": Color(0.55, 0.25, 0.18), "surface2": Color(0.49, 0.21, 0.15),
		"frame": Color(0.32, 0.12, 0.10), "line": Color(0.85, 0.68, 0.25), "accent": Color(0.85, 0.68, 0.25)},
	{"id": "midnight", "name": "Midnight Blue", "desc": "Deep navy board, silver lines.", "price": 3000, "level": 5,
		"surface": Color(0.13, 0.20, 0.38), "surface2": Color(0.10, 0.16, 0.32),
		"frame": Color(0.08, 0.10, 0.22), "line": Color(0.85, 0.87, 0.92), "accent": Color(0.85, 0.87, 0.92)},
	{"id": "emerald", "name": "Emerald Club", "desc": "Dark green felt-style, gold lines.", "price": 6000, "level": 8,
		"surface": Color(0.10, 0.38, 0.24), "surface2": Color(0.08, 0.32, 0.20),
		"frame": Color(0.06, 0.20, 0.13), "line": Color(0.85, 0.68, 0.25), "accent": Color(0.85, 0.68, 0.25)},
	{"id": "palace", "name": "Golden Palace", "desc": "Black + gold luxury.", "price": 15000, "level": 12,
		"surface": Color(0.10, 0.09, 0.10), "surface2": Color(0.14, 0.12, 0.12),
		"frame": Color(0.05, 0.04, 0.05), "line": Color(0.85, 0.68, 0.25), "accent": Color(0.85, 0.68, 0.25)},
	{"id": "signature", "name": "BMS Signature", "desc": "Black + gold, big gold BMS in the centre.", "price": 25000, "level": 15,
		"surface": Color(0.08, 0.07, 0.09), "surface2": Color(0.12, 0.10, 0.11),
		"frame": Color(0.04, 0.03, 0.04), "line": Color(0.85, 0.68, 0.25), "accent": Color(0.85, 0.68, 0.25)},
]

const STRIKERS := [
	{"id": "classic", "name": "Classic White", "desc": "The standard striker.", "price": 0, "level": 1,
		"force": 100, "aim": 100, "time": 20, "color": Color(0.94, 0.92, 0.86), "ring": Color(0.85, 0.68, 0.25)},
	{"id": "ivory", "name": "Ivory Pearl", "desc": "Smooth pearl finish.", "price": 800, "level": 1,
		"force": 102, "aim": 105, "time": 20, "color": Color(0.98, 0.96, 0.92), "ring": Color(0.75, 0.75, 0.78)},
	{"id": "crimson", "name": "Crimson King", "desc": "Deep red, hits harder.", "price": 2000, "level": 3,
		"force": 108, "aim": 100, "time": 20, "color": Color(0.62, 0.10, 0.14), "ring": Color(0.95, 0.85, 0.55)},
	{"id": "golden", "name": "Golden Striker", "desc": "Gold sheen, longer aim line.", "price": 5000, "level": 5,
		"force": 105, "aim": 110, "time": 22, "color": Color(0.85, 0.68, 0.25), "ring": Color(0.98, 0.90, 0.55)},
	{"id": "shadow", "name": "Shadow Black", "desc": "Dark, heavy, fast.", "price": 8000, "level": 8,
		"force": 110, "aim": 105, "time": 20, "color": Color(0.12, 0.12, 0.14), "ring": Color(0.85, 0.68, 0.25)},
	{"id": "bms_gold", "name": "BMS Gold", "desc": "Gold striker, BMS engraved.", "price": 20000, "level": 12,
		"force": 112, "aim": 112, "time": 24, "color": Color(0.95, 0.78, 0.30), "ring": Color(0.55, 0.42, 0.10)},
	{"id": "diamond", "name": "Diamond Elite", "desc": "The best. Small edge, big shine.", "price": 50000, "level": 15,
		"force": 115, "aim": 115, "time": 25, "color": Color(0.85, 0.93, 0.98), "ring": Color(0.65, 0.85, 1.0)},
]

static func board_by_id(id: String) -> Dictionary:
	for b in BOARDS:
		if b["id"] == id:
			return b
	return BOARDS[0]

static func striker_by_id(id: String) -> Dictionary:
	for s in STRIKERS:
		if s["id"] == id:
			return s
	return STRIKERS[0]

## Aim guideline length factor from the Aim stat (100 = 1.0x, 115 = 1.15x).
static func aim_length_factor(striker_id: String) -> float:
	return float(striker_by_id(striker_id)["aim"]) / 100.0

static func max_speed(striker_id: String) -> float:
	return CarromPhysics.MAX_SPEED * float(striker_by_id(striker_id)["force"]) / 100.0

static func shot_time(striker_id: String) -> float:
	return float(striker_by_id(striker_id)["time"])
