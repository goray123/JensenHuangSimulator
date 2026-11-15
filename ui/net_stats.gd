## Client-only lag readout, off unless asked for (`-- --netstats`, or `?stats` in the page URL):
## frame rate, how often server snapshots arrive and the worst gap between them, and how long a fresh
## key press takes to show up in the server's position for this player and then on screen.
extends Label

var _arrivals: Array[int] = []
var _press_msec := -1
var _press_server := Vector3.ZERO
var _press_shown := Vector3.ZERO
var _server_seen := false
var _was_idle := true
var _server_ms := -1
var _shown_ms := -1
var _next_update := 0


static func wanted() -> bool:
	if OS.get_cmdline_user_args().has("--netstats"):
		return true
	return OS.has_feature("web") and str(JavaScriptBridge.eval("location.search", true)).contains("stats")


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	position = Vector2(12, 686)
	add_theme_font_size_override("font_size", 18)
	add_theme_color_override("font_outline_color", Color.BLACK)
	add_theme_constant_override("outline_size", 6)


func on_snapshot() -> void:
	_arrivals.append(Time.get_ticks_msec())


## Every physics tick: this client's input, its player's latest server position and the drawn position.
func on_tick(input: Vector2, server_position: Vector3, shown_position: Vector3) -> void:
	var now := Time.get_ticks_msec()
	var idle := input.length() < 0.1
	if _was_idle and not idle:
		_press_msec = now
		_press_server = server_position
		_press_shown = shown_position
		_server_seen = false
	_was_idle = idle
	if _press_msec >= 0:
		if not _server_seen and server_position.distance_to(_press_server) > 0.02:
			_server_ms = now - _press_msec
			_server_seen = true
		if shown_position.distance_to(_press_shown) > 0.05:
			_shown_ms = now - _press_msec
			_press_msec = -1
	while not _arrivals.is_empty() and now - _arrivals[0] > 2000:
		_arrivals.pop_front()
	if now < _next_update:
		return
	_next_update = now + 500
	var gap := 0
	for index in range(1, _arrivals.size()):
		gap = maxi(gap, _arrivals[index] - _arrivals[index - 1])
	text = "FPS %d | 서버 위치 %d/초, 최대 간격 %d ms | 키→서버 %s, 키→화면 %s" % [
		Engine.get_frames_per_second(), _arrivals.size() / 2, gap,
		"%d ms" % _server_ms if _server_ms >= 0 else "-", "%d ms" % _shown_ms if _shown_ms >= 0 else "-"]
	if OS.get_cmdline_user_args().has("--netstats"):
		print(text)
