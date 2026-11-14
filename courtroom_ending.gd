extends CanvasLayer
## Courtroom result screen. Plays each actor's 6-second clip once and holds the last pose.
## The 3D stage lives in its own World3D, so the house never shows through it.

enum Outcome { DRAW, WIFE_WINS, HUSBAND_WINS }

const WIN_CLIP := &"celebrate_jump"
const LOSE_CLIP := &"defeat_kneel"
const TITLES := { Outcome.DRAW: "무승부", Outcome.WIFE_WINS: "아내 승리!", Outcome.HUSBAND_WINS: "남편 승리!" }

## Played when this scene is run on its own (F6 in the editor).
@export var preview_outcome := Outcome.WIFE_WINS

var outcome := Outcome.DRAW

@onready var wife_animation: AnimationPlayer = _find_player($View/World/Wife)
@onready var husband_animation: AnimationPlayer = _find_player($View/World/Husband)
@onready var _result: Label = $Result


static func outcome_for(husband_gold: int, wife_gold: int) -> Outcome:
	if wife_gold == husband_gold:
		return Outcome.DRAW
	return Outcome.WIFE_WINS if wife_gold > husband_gold else Outcome.HUSBAND_WINS


func _ready() -> void:
	# Manifest camera: horizontal FOV, kept when the window aspect changes.
	$View/World/Camera3D.look_at_from_position(Vector3(0, 6, 24), Vector3(0, 1.77, -1.8))
	if get_tree().current_scene == self:
		play(preview_outcome)
	else:
		play(Outcome.DRAW)


## Shows the result for the final bag totals (player0 host = husband, player1 guest = wife).
func show_scores(husband_gold: int, wife_gold: int) -> Outcome:
	play(outcome_for(husband_gold, wife_gold))
	_result.text += "\n아내 %d G   ·   남편 %d G" % [wife_gold, husband_gold]
	return outcome


func play(result: Outcome) -> void:
	outcome = result
	_result.text = TITLES[result]
	if result == Outcome.DRAW:
		# Neutral: both stand in the clips' shared opening pose; nobody celebrates.
		_hold_start(wife_animation)
		_hold_start(husband_animation)
		return
	var wife_wins := result == Outcome.WIFE_WINS
	_play_once(wife_animation, WIN_CLIP if wife_wins else LOSE_CLIP)
	_play_once(husband_animation, LOSE_CLIP if wife_wins else WIN_CLIP)


func _play_once(player: AnimationPlayer, clip: StringName) -> void:
	player.get_animation(clip).loop_mode = Animation.LOOP_NONE
	player.stop()
	player.play(clip)


func _hold_start(player: AnimationPlayer) -> void:
	player.play(WIN_CLIP)
	player.seek(0.0, true)
	player.pause()


func _find_player(actor: Node) -> AnimationPlayer:
	return actor.find_children("*", "AnimationPlayer", true, false)[0] as AnimationPlayer
