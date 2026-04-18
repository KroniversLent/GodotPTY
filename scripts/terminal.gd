## Root controller: wires the PTYNode (GDExtension) to the TerminalScreen.
## Handles keyboard input translation and window resize.
extends Control

const COLS := 80
const ROWS := 24

@onready var screen: TerminalScreen = $TerminalScreen
@onready var pty: PTYNode           = $PTYNode


func _ready() -> void:
	# Let the screen fill the window while keeping terminal proportions
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	pty.data_received.connect(_on_data)
	pty.exited.connect(_on_exited)
	screen.cursor_position_changed.connect(_on_cursor_moved)

	# Report cursor position reply goes back to the PTY
	var shell := OS.get_environment("SHELL")
	if shell == "":
		shell = "/bin/bash"
	var pid := pty.open(COLS, ROWS, shell)
	if pid < 0:
		push_error("PTYNode.open() failed — is the GDExtension compiled?")
		return

	screen.grab_focus()


func _on_data(data: PackedByteArray) -> void:
	screen.feed(data)


func _on_exited(exit_code: int) -> void:
	print("Shell exited with code ", exit_code)
	get_tree().quit(exit_code)


func _on_cursor_moved(_row: int, _col: int) -> void:
	pass  # extend here for status-bar cursor display


# ── Keyboard input ────────────────────────────────────────────────────────────

func _unhandled_key_input(event: InputEventKey) -> void:
	if not event.pressed:
		return
	var bytes := _key_to_bytes(event)
	if bytes.size() > 0:
		pty.write(bytes)
		get_viewport().set_input_as_handled()


func _key_to_bytes(event: InputEventKey) -> PackedByteArray:
	var data := PackedByteArray()

	# Ctrl+letter → send control character (0x01–0x1A)
	if event.ctrl_pressed and not event.alt_pressed:
		var k := event.keycode
		if k >= KEY_A and k <= KEY_Z:
			data.append(k - KEY_A + 1)
			return data
		match k:
			KEY_BRACKETLEFT:  data.append(0x1B); return data  # Ctrl+[ = ESC
			KEY_BACKSLASH:    data.append(0x1C); return data
			KEY_BRACKETRIGHT: data.append(0x1D); return data
			KEY_MINUS:        data.append(0x1F); return data

	# Special keys → VT/xterm escape sequences
	match event.keycode:
		KEY_ENTER, KEY_KP_ENTER: data.append(13)
		KEY_BACKSPACE:           data.append(127)
		KEY_TAB:
			if event.shift_pressed:
				data.append_array([0x1B, 0x5B, 0x5A])  # Shift+Tab = CSI Z
			else:
				data.append(9)
		KEY_ESCAPE:   data.append(0x1B)
		KEY_UP:       data.append_array([0x1B, 0x5B, 0x41])
		KEY_DOWN:     data.append_array([0x1B, 0x5B, 0x42])
		KEY_RIGHT:    data.append_array([0x1B, 0x5B, 0x43])
		KEY_LEFT:     data.append_array([0x1B, 0x5B, 0x44])
		KEY_HOME:     data.append_array([0x1B, 0x5B, 0x48])
		KEY_END:      data.append_array([0x1B, 0x5B, 0x46])
		KEY_INSERT:   data.append_array([0x1B, 0x5B, 0x32, 0x7E])
		KEY_DELETE:   data.append_array([0x1B, 0x5B, 0x33, 0x7E])
		KEY_PAGEUP:   data.append_array([0x1B, 0x5B, 0x35, 0x7E])
		KEY_PAGEDOWN: data.append_array([0x1B, 0x5B, 0x36, 0x7E])
		KEY_F1:       data.append_array([0x1B, 0x4F, 0x50])
		KEY_F2:       data.append_array([0x1B, 0x4F, 0x51])
		KEY_F3:       data.append_array([0x1B, 0x4F, 0x52])
		KEY_F4:       data.append_array([0x1B, 0x4F, 0x53])
		KEY_F5:       data.append_array([0x1B, 0x5B, 0x31, 0x35, 0x7E])
		KEY_F6:       data.append_array([0x1B, 0x5B, 0x31, 0x37, 0x7E])
		KEY_F7:       data.append_array([0x1B, 0x5B, 0x31, 0x38, 0x7E])
		KEY_F8:       data.append_array([0x1B, 0x5B, 0x31, 0x39, 0x7E])
		KEY_F9:       data.append_array([0x1B, 0x5B, 0x32, 0x30, 0x7E])
		KEY_F10:      data.append_array([0x1B, 0x5B, 0x32, 0x31, 0x7E])
		KEY_F11:      data.append_array([0x1B, 0x5B, 0x32, 0x33, 0x7E])
		KEY_F12:      data.append_array([0x1B, 0x5B, 0x32, 0x34, 0x7E])
		_:
			if event.unicode > 0:
				data = char(event.unicode).to_utf8_buffer()

	return data
