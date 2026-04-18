## Pure-GDScript PTY backend — no GDExtension required.
##
## Spawns addons/godot_pty/pty_bridge.py as a subprocess, then communicates
## with it over a loopback TCP socket using Godot's built-in StreamPeerTCP.
##
## Exposes the same open() / write() / resize() / close_pty() / is_open()
## surface as the C++ PTYNode so terminal.gd works with either backend.
class_name PTYSocket
extends Node

const _HOST        := "127.0.0.1"
const _CONNECT_TRIES := 40    # × 75 ms = 3 s timeout
const _POLL_INTERVAL := 0.016 # seconds (~60 fps)

signal data_received(data: PackedByteArray)
signal exited(exit_code: int)

var _client      : StreamPeerTCP = StreamPeerTCP.new()
var _bridge_pid  : int  = -1
var _port        : int  = 0
var _connected   : bool = false
var _tries_left  : int  = 0

var _poll_timer  : Timer = null


# ── Public API ────────────────────────────────────────────────────────────────

## Launches the bridge and opens the PTY.  Returns the bridge PID, or -1.
func open(cols: int = 80, rows: int = 24, shell: String = "") -> int:
	if shell == "":
		shell = OS.get_environment("SHELL")
		if shell == "":
			shell = "/bin/bash"

	_port = _pick_port()

	var bridge := ProjectSettings.globalize_path(
		"res://addons/godot_pty/pty_bridge.py")

	_bridge_pid = OS.create_process(
		"python3",
		[bridge, str(_port), str(cols), str(rows), shell])

	if _bridge_pid < 0:
		push_error("PTYSocket: failed to start pty_bridge.py")
		return -1

	# Give the bridge ~75 ms to bind its socket, then start retrying
	_tries_left = _CONNECT_TRIES
	_start_timer(0.075, _try_connect)
	return _bridge_pid


## Sends raw bytes to the PTY master (keyboard input).
func write(data: PackedByteArray) -> void:
	if _connected:
		_client.put_data(data)


## Sends a resize command to the bridge (cols × rows).
## Protocol: \x00 R <cols_hi> <cols_lo> <rows_hi> <rows_lo>
func resize(cols: int, rows: int) -> void:
	if not _connected:
		return
	var msg := PackedByteArray([0x00, 0x52])
	msg.append((cols >> 8) & 0xFF)
	msg.append(cols & 0xFF)
	msg.append((rows >> 8) & 0xFF)
	msg.append(rows & 0xFF)
	_client.put_data(msg)


func close_pty() -> void:
	_stop_timer()
	if _connected:
		_client.disconnect_from_host()
		_connected = false
	if _bridge_pid > 0:
		OS.kill(_bridge_pid)
		_bridge_pid = -1


func is_open() -> bool:
	return _connected


# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _exit_tree() -> void:
	close_pty()


# ── Connection helpers ────────────────────────────────────────────────────────

func _try_connect() -> void:
	_stop_timer()
	var err := _client.connect_to_host(_HOST, _port)
	if err != OK:
		_schedule_retry()
		return
	# Connection is in progress; wait for STATUS_CONNECTED
	_start_timer(0.02, _check_connecting)


func _check_connecting() -> void:
	_stop_timer()
	_client.poll()
	match _client.get_status():
		StreamPeerTCP.STATUS_CONNECTED:
			_connected = true
			_start_timer(_POLL_INTERVAL, _poll_data)
		StreamPeerTCP.STATUS_CONNECTING:
			_start_timer(0.02, _check_connecting)
		_:
			# Failed — reset and retry
			_client.disconnect_from_host()
			_client = StreamPeerTCP.new()
			_schedule_retry()


func _schedule_retry() -> void:
	_tries_left -= 1
	if _tries_left <= 0:
		push_error("PTYSocket: timed out waiting for pty_bridge.py to accept")
		return
	_start_timer(0.075, _try_connect)


# ── Data polling ──────────────────────────────────────────────────────────────

func _poll_data() -> void:
	_stop_timer()
	_client.poll()

	match _client.get_status():
		StreamPeerTCP.STATUS_CONNECTED:
			var n := _client.get_available_bytes()
			if n > 0:
				var result := _client.get_data(n)
				if result[0] == OK:
					data_received.emit(result[1] as PackedByteArray)
			_start_timer(_POLL_INTERVAL, _poll_data)

		_:
			# Bridge disconnected → shell exited
			_connected = false
			exited.emit(0)


# ── Timer utility ─────────────────────────────────────────────────────────────

func _start_timer(delay: float, callback: Callable) -> void:
	_stop_timer()
	_poll_timer = Timer.new()
	_poll_timer.one_shot = true
	_poll_timer.wait_time = delay
	_poll_timer.timeout.connect(callback)
	add_child(_poll_timer)
	_poll_timer.start()


func _stop_timer() -> void:
	if _poll_timer != null and is_instance_valid(_poll_timer):
		_poll_timer.stop()
		_poll_timer.queue_free()
		_poll_timer = null


# ── Port selection ────────────────────────────────────────────────────────────

static func _pick_port() -> int:
	# Use a random port in the ephemeral range to avoid collisions when
	# multiple instances run simultaneously.
	return 49152 + (randi() % 16383)
