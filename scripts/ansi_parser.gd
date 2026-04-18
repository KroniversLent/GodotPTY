## Streaming VT100 / ANSI escape-sequence parser.
## Feed raw bytes from the PTY; get back an Array of action Dictionaries.
##
## Supported sequences:
##   C0 controls: CR, LF, BS, BEL, HT
##   ESC sequences: RIS (c), RI (M), DECSC (7), DECRC (8)
##   CSI sequences: cursor movement, erase, insert/delete, SGR (colours),
##                  DECSTBM, DECTCEM (show/hide cursor), SM/RM
##   OSC sequences: consumed silently (title etc.)
class_name ANSIParser
extends RefCounted

enum _State { NORMAL, ESCAPE, CSI, OSC }

var _state: _State = _State.NORMAL
var _params: String = ""
var _intermediate: String = ""


func feed(data: PackedByteArray) -> Array:
	var actions: Array = []
	for i in range(data.size()):
		_process_byte(data[i], actions)
	return actions


func _process_byte(b: int, actions: Array) -> void:
	var ch := char(b)

	match _state:
		_State.NORMAL:
			match b:
				0x1B: _state = _State.ESCAPE
				0x0D: actions.append({"type": "cr"})
				0x0A: actions.append({"type": "lf"})
				0x08: actions.append({"type": "bs"})
				0x07: actions.append({"type": "bel"})
				0x09: actions.append({"type": "tab"})
				_:
					if b >= 0x20:
						actions.append({"type": "print", "char": ch})

		_State.ESCAPE:
			match ch:
				"[":
					_state = _State.CSI
					_params = ""
					_intermediate = ""
				"]":
					_state = _State.OSC
					_params = ""
				"c":
					_state = _State.NORMAL
					actions.append({"type": "reset"})
				"M":
					_state = _State.NORMAL
					actions.append({"type": "ri"})
				"7":
					_state = _State.NORMAL
					actions.append({"type": "sc"})
				"8":
					_state = _State.NORMAL
					actions.append({"type": "rc"})
				_:
					_state = _State.NORMAL

		_State.CSI:
			if (b >= 0x30 and b <= 0x3F):  # param bytes: 0-9 ; < = > ?
				_params += ch
			elif (b >= 0x20 and b <= 0x2F):  # intermediate bytes
				_intermediate += ch
			else:  # final byte
				_handle_csi(ch, _params, _intermediate, actions)
				_state = _State.NORMAL
				_params = ""
				_intermediate = ""

		_State.OSC:
			# BEL (0x07) or ST (ESC \) terminates OSC — we discard the payload
			if b == 0x07 or b == 0x1B:
				_state = _State.NORMAL


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _parse_params(raw: String, default_val: int = 0) -> Array:
	var stripped := raw.trim_prefix("?").trim_prefix(">").trim_prefix("=")
	if stripped == "":
		return [default_val]
	var parts := stripped.split(";")
	var result: Array = []
	for p in parts:
		result.append(int(p) if p != "" else default_val)
	return result


func _p(ps: Array, idx: int, default_val: int = 0) -> int:
	if idx < ps.size() and ps[idx] != 0:
		return ps[idx]
	return default_val


func _handle_csi(final_ch: String, raw: String, _interm: String, actions: Array) -> void:
	var ps := _parse_params(raw)
	var private_mode := raw.begins_with("?")

	match final_ch:
		"A": actions.append({"type": "cuu", "n": max(1, _p(ps, 0, 1))})
		"B": actions.append({"type": "cud", "n": max(1, _p(ps, 0, 1))})
		"C": actions.append({"type": "cuf", "n": max(1, _p(ps, 0, 1))})
		"D": actions.append({"type": "cub", "n": max(1, _p(ps, 0, 1))})
		"E": actions.append({"type": "cnl", "n": max(1, _p(ps, 0, 1))})
		"F": actions.append({"type": "cpl", "n": max(1, _p(ps, 0, 1))})
		"G": actions.append({"type": "cha", "col": max(1, _p(ps, 0, 1))})
		"H", "f":
			actions.append({
				"type": "cup",
				"row": max(1, _p(ps, 0, 1)),
				"col": max(1, _p(ps, 1, 1)),
			})
		"J": actions.append({"type": "ed",  "n": _p(ps, 0, 0)})
		"K": actions.append({"type": "el",  "n": _p(ps, 0, 0)})
		"L": actions.append({"type": "il",  "n": max(1, _p(ps, 0, 1))})
		"M": actions.append({"type": "dl",  "n": max(1, _p(ps, 0, 1))})
		"P": actions.append({"type": "dch", "n": max(1, _p(ps, 0, 1))})
		"S": actions.append({"type": "su",  "n": max(1, _p(ps, 0, 1))})
		"T": actions.append({"type": "sd",  "n": max(1, _p(ps, 0, 1))})
		"X": actions.append({"type": "ech", "n": max(1, _p(ps, 0, 1))})
		"@": actions.append({"type": "ich", "n": max(1, _p(ps, 0, 1))})
		"m": actions.append({"type": "sgr", "params": ps})
		"n":
			if ps[0] == 6:
				actions.append({"type": "dsr"})  # report cursor position
		"r":
			actions.append({
				"type":  "stbm",
				"top":   max(1, _p(ps, 0, 1)),
				"bot":   _p(ps, 1, 0),   # 0 means "use terminal height"
			})
		"s": actions.append({"type": "sc"})
		"u": actions.append({"type": "rc"})
		"h": actions.append({"type": "sm", "params": ps, "private": private_mode})
		"l": actions.append({"type": "rm", "params": ps, "private": private_mode})
