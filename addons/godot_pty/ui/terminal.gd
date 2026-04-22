## Unified, high-performance terminal implementation.
class_name GodotTerminal
extends Control

# ── Constants ────────────────────────────────────────────────────────────────
const DEFAULT_FG := Color(0.85, 0.85, 0.85)
const DEFAULT_BG := Color(0.08, 0.08, 0.08)
const FLAG_BOLD := 1 << 0; const FLAG_ITALIC := 1 << 1; const FLAG_UNDERLINE := 1 << 2; const FLAG_INVERSE := 1 << 3

# ── Configuration ─────────────────────────────────────────────────────────────
var cols: int = 80; var rows: int = 24
var history: Array[PackedInt32Array] = []
var scroll_offset: int = 0 # 0 = bottom

# ── PTY State ─────────────────────────────────────────────────────────────────
var grid: Array[PackedInt32Array] = []
var cursor_col: int = 0; var cursor_row: int = 0
var saved_cursor := Vector2i(0, 0)
var scroll_top: int = 0; var scroll_bot: int = 23

const PALETTE := [
	0x000000FF, 0xCD0000FF, 0x00CD00FF, 0xCDCD00FF, 0x0000EEFF, 0xCD00CDFF, 0x00CDCDFF, 0xE5E5E5FF,
	0x7F7F7FFF, 0xFF0000FF, 0x00FF00FF, 0xFFFF00FF, 0x5C5CFFFF, 0xFF00FFFF, 0x00FFFFFF, 0xFFFFFFFF
]

# ── SGR State ─────────────────────────────────────────────────────────────────
var cur_fg: int = DEFAULT_FG.to_rgba32(); var cur_bg: int = DEFAULT_BG.to_rgba32(); var cur_flags: int = 0
var color_cache := {}; var default_bg_rgba := DEFAULT_BG.to_rgba32()

# ── UI State ──────────────────────────────────────────────────────────────────
var font: Font; var font_size: int = 15
var cell_w: float; var cell_h: float; var baseline: float
var blink_visible: bool = true; var blink_timer: float = 0.0

# ── ANSI Parser State ─────────────────────────────────────────────────────────
enum State { NORMAL, ESCAPE, CSI, OSC }
var parser_state: State = State.NORMAL; var parser_params: String = ""; var parser_interm: String = ""
var utf8_buf: PackedByteArray = []; var utf8_left: int = 0

@onready var pty = $PTYNode

# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _ready() -> void:
	focus_mode = Control.FOCUS_ALL
	_setup_font()
	_init_grid()
	
	if pty:
		pty.data_received.connect(feed)
		pty.exited.connect(func(code): get_tree().quit(code))
		var shell := OS.get_environment("SHELL"); if shell == "": shell = "/bin/bash"
		pty.open(cols, rows, shell)
	
	resized.connect(_on_resized)

func _setup_font() -> void:
	var sf := SystemFont.new(); sf.font_names = ["JetBrains Mono", "Fira Code", "monospace"]; sf.allow_system_fallback = true
	font = sf; font_size = 15; cell_w = font.get_char_size(65, font_size).x; cell_h = font.get_height(font_size); baseline = font.get_ascent(font_size)

func _init_grid() -> void:
	grid.clear()
	for r in rows:
		grid.append(_blank_line(cols))

func _blank_line(c_count: int) -> PackedInt32Array:
	var l := PackedInt32Array()
	l.resize(c_count * 4)
	for c in c_count:
		_set_cell(l, c, 32, DEFAULT_FG.to_rgba32(), DEFAULT_BG.to_rgba32(), 0)
	return l

func _set_cell(l: PackedInt32Array, c: int, ch: int, fg: int, bg: int, f: int) -> void:
	var b := c * 4
	l[b] = ch
	l[b+1] = fg
	l[b+2] = bg
	l[b+3] = f

# ── Parsing ───────────────────────────────────────────────────────────────────

func feed(data: PackedByteArray) -> void:
	var i := 0; var n := data.size()
	while i < n:
		var b := data[i]
		if parser_state == State.NORMAL:
			if b >= 0x20 and b <= 0x7E: # Fast ASCII path
				var start := i; i += 1
				while i < n and data[i] >= 0x20 and data[i] <= 0x7E: i += 1
				_put_string(data.slice(start, i).get_string_from_ascii()); continue
			elif b == 0x1B: parser_state = State.ESCAPE
			elif b == 0x0D: cursor_col = 0
			elif b == 0x0A: _line_feed()
			elif b == 0x08: cursor_col = maxi(0, cursor_col - 1)
			elif b == 0x09: cursor_col = mini((cursor_col / 8 + 1) * 8, cols - 1)
		elif parser_state == State.ESCAPE:
			match char(b):
				"[": parser_state = State.CSI; parser_params = ""; parser_interm = ""
				"c": _full_reset(); parser_state = State.NORMAL
				"M": _reverse_index(); parser_state = State.NORMAL
				"7": saved_cursor = Vector2i(cursor_col, cursor_row); parser_state = State.NORMAL
				"8": cursor_col = saved_cursor.x; cursor_row = saved_cursor.y; parser_state = State.NORMAL
				_: parser_state = State.NORMAL
		elif parser_state == State.CSI:
			if b >= 0x30 and b <= 0x3F: parser_params += char(b)
			elif b >= 0x20 and b <= 0x2F: parser_interm += char(b)
			else: _handle_csi(char(b)); parser_state = State.NORMAL
		i += 1
	queue_redraw()

func _put_string(s: String) -> void:
	for i in s.length():
		if cursor_row < rows and cursor_col < cols:
			_set_cell(grid[cursor_row], cursor_col, s.unicode_at(i), cur_fg, cur_bg, cur_flags)
		cursor_col += 1
		if cursor_col >= cols: cursor_col = 0; _line_feed()

func _line_feed() -> void:
	if cursor_row == scroll_bot:
		var removed := grid[scroll_top]; grid.remove_at(scroll_top); grid.insert(scroll_bot, _blank_line(cols))
		if scroll_top == 0 and scroll_bot == rows - 1: history.append(removed)
	else: cursor_row = mini(rows - 1, cursor_row + 1)

func _reverse_index() -> void:
	if cursor_row == scroll_top:
		grid.remove_at(scroll_bot); grid.insert(scroll_top, _blank_line(cols))
	else: cursor_row = maxi(0, cursor_row - 1)

func _handle_csi(cmd: String) -> void:
	var ps := parser_params.split(";"); var p0 := ps[0].to_int() if ps[0] != "" else 1
	match cmd:
		"A": cursor_row = maxi(scroll_top, cursor_row - p0)
		"B": cursor_row = mini(scroll_bot, cursor_row + p0)
		"C": cursor_col = mini(cols - 1, cursor_col + p0)
		"D": cursor_col = maxi(0, cursor_col - p0)
		"H", "f": cursor_row = clampi(p0 - 1, 0, rows - 1); cursor_col = clampi((ps[1].to_int() if ps.size() > 1 else 1) - 1, 0, cols - 1)
		"J": _erase_display(ps[0].to_int())
		"K": _erase_line(ps[0].to_int())
		"m": _apply_sgr(ps)
		"r": scroll_top = clampi(p0 - 1, 0, rows - 1); scroll_bot = clampi((ps[1].to_int() if ps.size() > 1 else rows) - 1, scroll_top, rows - 1)

func _erase_display(m: int) -> void:
	if m == 2: for r in rows: grid[r] = _blank_line(cols)

func _erase_line(m: int) -> void:
	var r := grid[cursor_row]; if m == 2: for c in cols: _set_blank_cell(r, c)

func _set_blank_cell(l: PackedInt32Array, c: int) -> void:
	_set_cell(l, c, 32, DEFAULT_FG.to_rgba32(), DEFAULT_BG.to_rgba32(), 0)

func _apply_sgr(ps: PackedStringArray) -> void:
	for p in ps:
		var v := p.to_int()
		if v == 0: cur_fg = DEFAULT_FG.to_rgba32(); cur_bg = DEFAULT_BG.to_rgba32(); cur_flags = 0
		elif v >= 30 and v <= 37: cur_fg = PALETTE[v - 30]
		elif v >= 40 and v <= 47: cur_bg = PALETTE[v - 40]
		elif v >= 90 and v <= 97: cur_fg = PALETTE[v - 90 + 8]
		elif v >= 100 and v <= 107: cur_bg = PALETTE[v - 100 + 8]
		elif v == 39: cur_fg = DEFAULT_FG.to_rgba32()
		elif v == 49: cur_bg = DEFAULT_BG.to_rgba32()

# ── Rendering ─────────────────────────────────────────────────────────────────

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), DEFAULT_BG)
	var visible: Array[PackedInt32Array] = []
	var total := history.size() + rows; var start := total - scroll_offset - rows
	for i in rows:
		var idx := start + i
		if idx < history.size(): visible.append(history[idx])
		elif idx < total: visible.append(grid[idx - history.size()])
		else: visible.append(_blank_line(cols))
	
	for r in rows:
		var l := visible[r]; var y := r * cell_h; var c := 0
		var line_cols := l.size() / 4
		while c < line_cols and c < cols:
			var b := c * 4; var fg := l[b+1]; var bg := l[b+2]; var fl := l[b+3]; var start_c := c; c += 1
			while c < line_cols and c < cols and l[c*4+1] == fg and l[c*4+2] == bg and l[c*4+3] == fl: c += 1
			var x := start_c * cell_w; var w := (c - start_c) * cell_w
			if bg != default_bg_rgba: draw_rect(Rect2(x, y, w, cell_h), _get_color(bg))
			var span := ""; var has_txt := false
			for i in range(start_c, c):
				var ch := l[i*4]; span += char(ch); if ch != 32: has_txt = true
			if has_txt: draw_string(font, Vector2(x, y + baseline), span, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, _get_color(fg))

func _get_color(rgba: int) -> Color:
	if not color_cache.has(rgba): color_cache[rgba] = Color.hex(rgba)
	return color_cache[rgba]

func _on_resized() -> void:
	if cell_w <= 0 or cell_h <= 0: return
	
	var new_cols := int(size.x / cell_w)
	var new_rows := int(size.y / cell_h)
	if new_cols < 2: new_cols = 2
	if new_rows < 2: new_rows = 2
	
	if new_cols == cols and new_rows == rows: return
	
	# 1. Adjust Columns for existing rows
	if new_cols != cols:
		for i in grid.size():
			var old_line := grid[i]
			var new_line := _blank_line(new_cols)
			# Copy as much as fits
			var to_copy := mini(cols, new_cols)
			for c in to_copy:
				var b_old := c * 4
				var b_new := c * 4
				new_line[b_new] = old_line[b_old]
				new_line[b_new+1] = old_line[b_old+1]
				new_line[b_new+2] = old_line[b_old+2]
				new_line[b_new+3] = old_line[b_old+3]
			grid[i] = new_line
		
		# Also resize history to match (optional but good for consistency)
		for i in history.size():
			var old_h := history[i]
			var new_h := _blank_line(new_cols)
			var to_copy := mini(old_h.size() / 4, new_cols)
			for c in to_copy:
				var b_old := c * 4
				var b_new := c * 4
				new_h[b_new] = old_h[b_old]
				new_h[b_new+1] = old_h[b_old+1]
				new_h[b_new+2] = old_h[b_old+2]
				new_h[b_new+3] = old_h[b_old+3]
			history[i] = new_h

	# 2. Adjust Rows
	if new_rows > rows:
		# Add more lines at the bottom
		for i in range(new_rows - rows):
			grid.append(_blank_line(new_cols))
	elif new_rows < rows:
		# Remove lines from the top, pushing them to history if needed
		# or just dropping them for simplicity in this basic version.
		# Standard PTY behavior is to keep the bottom visible.
		var diff := rows - new_rows
		for i in range(diff):
			# If we drop from the top of the grid, we could push to history
			history.append(grid[0])
			grid.remove_at(0)

	# 3. Update state
	cols = new_cols
	rows = new_rows
	scroll_bot = rows - 1
	scroll_top = 0
	cursor_col = clampi(cursor_col, 0, cols - 1)
	cursor_row = clampi(cursor_row, 0, rows - 1)
	
	if pty:
		pty.resize(cols, rows)
	
	queue_redraw()

func _full_reset() -> void:
	cursor_col = 0; cursor_row = 0; _init_grid(); history.clear(); scroll_offset = 0

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP: scroll_offset = mini(scroll_offset + 3, history.size()); queue_redraw()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN: scroll_offset = maxi(scroll_offset - 3, 0); queue_redraw()
	elif event is InputEventKey and event.pressed:
		if event.shift_pressed and event.keycode == KEY_PAGEUP: scroll_offset = mini(scroll_offset + rows, history.size()); queue_redraw(); accept_event()
		elif event.shift_pressed and event.keycode == KEY_PAGEDOWN: scroll_offset = maxi(scroll_offset - rows, 0); queue_redraw(); accept_event()
		else:
			if scroll_offset > 0: scroll_offset = 0; queue_redraw()
			_send_key(event); accept_event()

func _send_key(event: InputEventKey) -> void:
	if not pty: return
	var b := PackedByteArray()
	match event.keycode:
		KEY_ENTER: b.append(0x0D)
		KEY_BACKSPACE: b.append(0x7F)
		KEY_TAB: b.append(0x09)
		KEY_ESCAPE: b.append(0x1B)
		KEY_UP: b.append_array([0x1B, 0x5B, 0x41])
		KEY_DOWN: b.append_array([0x1B, 0x5B, 0x42])
		KEY_RIGHT: b.append_array([0x1B, 0x5B, 0x43])
		KEY_LEFT: b.append_array([0x1B, 0x5B, 0x44])
		_:
			if event.unicode != 0:
				b = String.chr(event.unicode).to_utf8_buffer()
	if b.size() > 0: pty.write(b)
