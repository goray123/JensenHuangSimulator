extends TextureRect
## Plays the supplied 60-frame, 20 fps upper-body PNG animations and gameplay reactions.

## Reaction priority, lowest first: fallen > sad > angry > proud > idle.
const STATES: Array[StringName] = [&"idle", &"proud", &"angry", &"sad", &"fallen"]
## How long each reaction is shown when the event gives no duration of its own.
const REACTION_SECONDS: Dictionary[StringName, float] = {&"proud": 3.0, &"angry": 3.0, &"sad": 3.0, &"fallen": 2.0}
const FRAME_COUNT := 60
const FPS := 20.0
const TILE_SIZE := 256
const COLUMNS := 8

@export_enum("woman", "man") var character := "woman"

var current_state: StringName = &"idle"
var current_frame := 0
var _elapsed := 0.0
var _remaining: Dictionary[StringName, float] = {}
var _atlases: Dictionary[StringName, Texture2D] = {}
var _frame_texture := AtlasTexture.new()


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	# Loaded up front so a reaction never waits on a 2048x2048 texture decode mid-game.
	for state in STATES:
		_atlases[state] = load("res://assets/ui/portraits/%s_%s.png" % [character, state]) as Texture2D
	_frame_texture.filter_clip = true
	texture = _frame_texture
	_set_animation(&"idle")


## Shows `state` for `seconds` (or its REACTION_SECONDS default). Repeating an event
## extends the timer without restarting the clip; a higher-priority reaction wins.
func play_reaction(state: StringName, seconds := 0.0) -> void:
	if state not in REACTION_SECONDS or not is_finite(seconds):
		return
	if seconds <= 0.0:
		seconds = REACTION_SECONDS[state]
	_remaining[state] = maxf(_remaining.get(state, 0.0), seconds)
	_select_animation()


func clear_reactions() -> void:
	_remaining.clear()
	_set_animation(&"idle")


func _process(delta: float) -> void:
	advance(delta)


func advance(delta: float) -> void:
	if not is_finite(delta) or delta < 0.0:
		return
	for state: StringName in _remaining.keys():
		_remaining[state] -= delta
		if _remaining[state] <= 0.0:
			_remaining.erase(state)
	var previous := current_state
	_select_animation()
	if current_state == previous:
		_elapsed = fmod(_elapsed + delta, FRAME_COUNT / FPS)
	current_frame = mini(floori(_elapsed * FPS), FRAME_COUNT - 1)
	_frame_texture.region = Rect2((current_frame % COLUMNS) * TILE_SIZE, (current_frame / COLUMNS) * TILE_SIZE, TILE_SIZE, TILE_SIZE)


func _select_animation() -> void:
	# Highest priority wins; all reaction clocks keep running underneath it.
	for index in range(STATES.size() - 1, 0, -1):
		if _remaining.has(STATES[index]):
			if current_state != STATES[index]:
				_set_animation(STATES[index])
			return
	if current_state != &"idle":
		_set_animation(&"idle")


func _set_animation(state: StringName) -> void:
	current_state = state
	current_frame = 0
	_elapsed = 0.0
	_frame_texture.atlas = _atlases[state]
	_frame_texture.region = Rect2(0, 0, TILE_SIZE, TILE_SIZE)
