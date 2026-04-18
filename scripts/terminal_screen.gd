## Grid-based terminal screen: parses ANSI sequences and custom-draws each cell.
## Attach to a Control node.  Call feed() with raw PTY bytes.
class_name TerminalScreen
extends Control

# ── Colours ──────────────────────────────────────────────────────────────────
const DEFAULT_FG := Color(0.85, 0.85, 0.85)
const DEFAULT_BG := Color(0.08, 0.08, 0.08)

const ANSI_NORMAL: Array[Color] = [
	Color(0.00, 0.00, 0.00),  # 0  black
	Color(0.80, 0.10, 0.10),  # 1  red
	Color(0.10, 0.70, 0.10),  # 2  green
	Color(0.80, 0.70, 0.10),  # 3  yellow
	Color(0.20, 0.30, 0.80),  # 4  blue
	Color(0.70, 0.10, 0.70),  # 5  magenta
	Color(0.10, 0.70, 0.70),  # 6  cyan
	Color(0.75, 0.75, 0.75),  # 7  white
]
const ANSI_BRIGHT: Array[Color] = [
	Color(0.40, 0.40, 0.40),  # 8  bright black / gray
	Color(1.00, 0.30, 0.30),  # 9  bright red
	Color(0.30, 1.00, 0.30),  # 10 bright green
	Color(1.00, 1.00, 0.30),  # 11 bright yellow
	Color(0.30, 0.50, 1.00),  # 12 bright blue
	Color(1.00, 0.30, 1.00),  # 13 bright magenta
	Color(0.30, 1.00, 1.00),  # 14 bright cyan
	Color(1.00, 1.00, 1.00),  # 15 bright white
]

# ── Cell ─────────────────────────────────────────────────────────────────────
class Cell:
	var ch:        String = " "
	var fg:        Color  = DEFAULT_FG
	var bg:        Color  = DEFAULT_BG
	var bold:      bool   = false
	var italic:    bool   = false
	var underline: bool   = false
	var inverse:   bool   = false

# ── State ─────────────────────────────────────────────────────────────────────
var cols: int = 80
var rows: int = 24

var grid: Array = []          # Array[Array[Cell]]
var cursor_col: int = 0
var cursor_row: int = 0
var saved_cursor := Vector2i(0, 0)

var scroll_top: int = 0
var scroll_bot: int = 23

# Current SGR attributes
var _cur_fg: Color = DEFAULT_FG
var _cur_bg: Color = DEFAULT_BG
var _attr_bold:      bool = false
var _attr_italic:    bool = false
var _attr_underline: bool = false
var _attr_inverse:   bool = false

var _show_cursor: bool = true
var _cursor_blink: bool = true  # visible phase
var _blink_timer: float = 0.0

var _parser: ANSIParser = ANSIParser.new()

# ── Font metrics (set via set_font_metrics) ───────────────────────────────────
var _font:        Font  = null
var _font_size:   int   = 16
var _cell_w:      float = 9.0
var _cell_h:      float = 20.0
var _baseline:    float = 16.0   # ascent offset within the cell

signal cursor_position_changed(row: int, col: int)

# ── Public API ────────────────────────────────────────────────────────────────

func _init(c: int = 80, r: int = 24) -> void:
	cols = c
	rows = r
	scroll_bot = r - 1
	_init_grid()


func _ready() -> void:
	focus_mode = Control.FOCUS_ALL
	_setup_font()


func set_font_metrics(font: Font, size: int) -> void:
	_font = font
	_font_size = size
	var test_size := font.get_string_size("M", HORIZONTAL_ALIGNMENT_LEFT, -1, size)
	_cell_w  = test_size.x
	_cell_h  = font.get_height(size)
	_baseline = font.get_ascent(size)
	custom_minimum_size = Vector2(cols * _cell_w, rows * _cell_h)
	queue_redraw()


func feed(data: PackedByteArray) -> void:
	for action in _parser.feed(data):
		_handle(action)
	queue_redraw()


# ── Input ─────────────────────────────────────────────────────────────────────

func _process(delta: float) -> void:
	_blink_timer += delta
	if _blink_timer >= 0.5:
		_blink_timer = 0.0
		_cursor_blink = !_cursor_blink
		queue_redraw()


# ── Drawing ───────────────────────────────────────────────────────────────────

func _draw() -> void:
	if _font == null:
		return

	draw_rect(Rect2(Vector2.ZERO, size), DEFAULT_BG)

	for row in rows:
		if row >= grid.size():
			break
		for col in cols:
			if col >= grid[row].size():
				break
			var cell: Cell = grid[row][col]

			var fg: Color = cell.fg
			var bg: Color = cell.bg
			if cell.inverse or _attr_inverse:
				var tmp := fg; fg = bg; bg = tmp

			var x := col * _cell_w
			var y := row * _cell_h

			if bg != DEFAULT_BG:
				draw_rect(Rect2(x, y, _cell_w, _cell_h), bg)

			if cell.ch != " ":
				draw_string(_font, Vector2(x, y + _baseline),
					cell.ch, HORIZONTAL_ALIGNMENT_LEFT, -1, _font_size, fg)

			if cell.underline:
				draw_line(Vector2(x, y + _cell_h - 2.0),
					Vector2(x + _cell_w, y + _cell_h - 2.0), fg, 1.0)

	# Cursor
	if _show_cursor and _cursor_blink and cursor_row < rows and cursor_col < cols:
		var cx := cursor_col * _cell_w
		var cy := cursor_row * _cell_h
		draw_rect(Rect2(cx, cy, _cell_w, _cell_h), Color(1, 1, 1, 0.5))


# ── Grid helpers ──────────────────────────────────────────────────────────────

func _init_grid() -> void:
	grid.clear()
	for _r in rows:
		grid.append(_blank_line())


func _blank_line() -> Array:
	var line: Array = []
	for _c in cols:
		line.append(Cell.new())
	return line


func _make_cell() -> Cell:
	var c := Cell.new()
	c.fg        = _cur_fg
	c.bg        = _cur_bg
	c.bold      = _attr_bold
	c.italic    = _attr_italic
	c.underline = _attr_underline
	c.inverse   = _attr_inverse
	return c


func _blank_cell() -> Cell:
	return Cell.new()


# ── Action dispatcher ─────────────────────────────────────────────────────────

func _handle(a: Dictionary) -> void:
	match a["type"]:
		"print":   _put_char(a["char"])
		"cr":      cursor_col = 0
		"lf":      _line_feed()
		"bs":      if cursor_col > 0: cursor_col -= 1
		"tab":     cursor_col = mini((cursor_col / 8 + 1) * 8, cols - 1)
		"bel":     pass  # TODO: visual bell
		"cuu":     cursor_row = maxi(scroll_top, cursor_row - a["n"])
		"cud":     cursor_row = mini(scroll_bot, cursor_row + a["n"])
		"cuf":     cursor_col = mini(cols - 1,   cursor_col + a["n"])
		"cub":     cursor_col = maxi(0,           cursor_col - a["n"])
		"cnl":     cursor_row = mini(rows - 1, cursor_row + a["n"]); cursor_col = 0
		"cpl":     cursor_row = maxi(0,           cursor_row - a["n"]); cursor_col = 0
		"cha":     cursor_col = clampi(a["col"] - 1, 0, cols - 1)
		"cup":
			cursor_row = clampi(a["row"] - 1, 0, rows - 1)
			cursor_col = clampi(a["col"] - 1, 0, cols - 1)
		"ed":      _erase_display(a["n"])
		"el":      _erase_line(a["n"])
		"il":      _insert_lines(a["n"])
		"dl":      _delete_lines(a["n"])
		"dch":     _delete_chars(a["n"])
		"ich":     _insert_chars(a["n"])
		"ech":     _erase_chars(a["n"])
		"su":      _scroll_up(a["n"])
		"sd":      _scroll_down(a["n"])
		"sgr":     _apply_sgr(a["params"])
		"sc":
			saved_cursor = Vector2i(cursor_col, cursor_row)
		"rc":
			cursor_col = saved_cursor.x
			cursor_row = saved_cursor.y
		"stbm":
			scroll_top = clampi(a["top"] - 1, 0, rows - 1)
			scroll_bot = a["bot"] if a["bot"] > 0 else rows - 1
			scroll_bot = clampi(scroll_bot, scroll_top, rows - 1)
			cursor_col = 0; cursor_row = 0
		"ri":      _reverse_index()
		"reset":   _full_reset()
		"dsr":     pass  # cursor position report handled by terminal.gd
		"sm":      _set_mode(a["params"], a["private"], true)
		"rm":      _set_mode(a["params"], a["private"], false)

	cursor_position_changed.emit(cursor_row, cursor_col)


# ── Screen operations ─────────────────────────────────────────────────────────

func _put_char(ch: String) -> void:
	if cursor_row < rows and cursor_col < cols:
		var cell := _make_cell()
		cell.ch = ch
		grid[cursor_row][cursor_col] = cell
	cursor_col += 1
	if cursor_col >= cols:
		cursor_col = 0
		_line_feed()


func _line_feed() -> void:
	if cursor_row == scroll_bot:
		_scroll_up(1)
	else:
		cursor_row = mini(rows - 1, cursor_row + 1)


func _reverse_index() -> void:
	if cursor_row == scroll_top:
		_scroll_down(1)
	else:
		cursor_row = maxi(0, cursor_row - 1)


func _scroll_up(n: int) -> void:
	for _i in n:
		grid.remove_at(scroll_top)
		grid.insert(scroll_bot, _blank_line())


func _scroll_down(n: int) -> void:
	for _i in n:
		if scroll_bot < grid.size():
			grid.remove_at(scroll_bot)
		grid.insert(scroll_top, _blank_line())


func _erase_display(mode: int) -> void:
	match mode:
		0:  # from cursor to end
			_erase_region(cursor_row, cursor_col, rows - 1, cols - 1)
		1:  # from start to cursor
			_erase_region(0, 0, cursor_row, cursor_col)
		2, 3:  # entire screen
			_erase_region(0, 0, rows - 1, cols - 1)


func _erase_line(mode: int) -> void:
	match mode:
		0:
			for c in range(cursor_col, cols):
				grid[cursor_row][c] = _blank_cell()
		1:
			for c in range(cursor_col + 1):
				grid[cursor_row][c] = _blank_cell()
		2:
			for c in cols:
				grid[cursor_row][c] = _blank_cell()


func _erase_chars(n: int) -> void:
	for c in range(cursor_col, mini(cursor_col + n, cols)):
		grid[cursor_row][c] = _blank_cell()


func _erase_region(r1: int, c1: int, r2: int, c2: int) -> void:
	for r in range(r1, r2 + 1):
		var col_start := c1 if r == r1 else 0
		var col_end   := c2 if r == r2 else cols - 1
		for c in range(col_start, col_end + 1):
			if r < grid.size() and c < grid[r].size():
				grid[r][c] = _blank_cell()


func _insert_lines(n: int) -> void:
	for _i in n:
		if grid.size() > scroll_bot:
			grid.remove_at(scroll_bot)
		grid.insert(cursor_row, _blank_line())


func _delete_lines(n: int) -> void:
	for _i in n:
		if cursor_row < grid.size():
			grid.remove_at(cursor_row)
		grid.insert(scroll_bot, _blank_line())


func _insert_chars(n: int) -> void:
	var row: Array = grid[cursor_row]
	for _i in n:
		row.insert(cursor_col, _blank_cell())
	while row.size() > cols:
		row.resize(cols)


func _delete_chars(n: int) -> void:
	var row: Array = grid[cursor_row]
	for _i in n:
		if cursor_col < row.size():
			row.remove_at(cursor_col)
			row.append(_blank_cell())


# ── SGR (colours / attributes) ────────────────────────────────────────────────

func _apply_sgr(params: Array) -> void:
	var i := 0
	while i < params.size():
		var p: int = params[i]
		match p:
			0:
				_cur_fg = DEFAULT_FG; _cur_bg = DEFAULT_BG
				_attr_bold = false; _attr_italic = false
				_attr_underline = false; _attr_inverse = false
			1: _attr_bold      = true
			3: _attr_italic    = true
			4: _attr_underline = true
			7: _attr_inverse   = true
			22: _attr_bold      = false
			23: _attr_italic    = false
			24: _attr_underline = false
			27: _attr_inverse   = false
			30, 31, 32, 33, 34, 35, 36, 37:
				_cur_fg = ANSI_NORMAL[p - 30]
				if _attr_bold:
					_cur_fg = ANSI_BRIGHT[p - 30]
			38:
				if i + 2 < params.size() and params[i + 1] == 5:
					_cur_fg = _color256(params[i + 2]); i += 2
				elif i + 4 < params.size() and params[i + 1] == 2:
					_cur_fg = Color(params[i+2]/255.0, params[i+3]/255.0, params[i+4]/255.0)
					i += 4
			39: _cur_fg = DEFAULT_FG
			40, 41, 42, 43, 44, 45, 46, 47:
				_cur_bg = ANSI_NORMAL[p - 40]
			48:
				if i + 2 < params.size() and params[i + 1] == 5:
					_cur_bg = _color256(params[i + 2]); i += 2
				elif i + 4 < params.size() and params[i + 1] == 2:
					_cur_bg = Color(params[i+2]/255.0, params[i+3]/255.0, params[i+4]/255.0)
					i += 4
			49: _cur_bg = DEFAULT_BG
			90, 91, 92, 93, 94, 95, 96, 97:
				_cur_fg = ANSI_BRIGHT[p - 90]
			100, 101, 102, 103, 104, 105, 106, 107:
				_cur_bg = ANSI_BRIGHT[p - 100]
		i += 1


func _color256(idx: int) -> Color:
	if idx < 8:
		return ANSI_NORMAL[idx]
	if idx < 16:
		return ANSI_BRIGHT[idx - 8]
	if idx < 232:
		var i := idx - 16
		return Color((i / 36) * 51.0 / 255.0, ((i / 6) % 6) * 51.0 / 255.0, (i % 6) * 51.0 / 255.0)
	var v := (idx - 232) * 10 + 8
	return Color(v / 255.0, v / 255.0, v / 255.0)


# ── Mode flags ────────────────────────────────────────────────────────────────

func _set_mode(params: Array, private_mode: bool, enable: bool) -> void:
	for p: int in params:
		if private_mode:
			match p:
				25: _show_cursor = enable  # DECTCEM


# ── Reset ─────────────────────────────────────────────────────────────────────

func _full_reset() -> void:
	cursor_col = 0; cursor_row = 0
	scroll_top = 0; scroll_bot = rows - 1
	_cur_fg = DEFAULT_FG; _cur_bg = DEFAULT_BG
	_attr_bold = false; _attr_italic = false
	_attr_underline = false; _attr_inverse = false
	_init_grid()


# ── Font setup ────────────────────────────────────────────────────────────────

func _setup_font() -> void:
	var sf := SystemFont.new()
	# Try common monospace fonts; fall back to whatever the system provides
	sf.font_names = PackedStringArray([
		"JetBrains Mono", "Fira Code", "Cascadia Code",
		"Cascadia Mono", "Hack", "Source Code Pro",
		"Consolas", "Courier New", "monospace",
	])
	sf.allow_system_fallback = true
	set_font_metrics(sf, 15)
