extends Node3D
var entries: Array=[]
var index: int=0
var shown: Node3D
var camera: Camera3D
var title: Label
var spin: CheckButton
var selector: OptionButton

func _ready() -> void:
    entries=JSON.parse_string(FileAccess.get_file_as_string("res://assets/household_items/data/item_manifest.json"))["items"]
    var world := WorldEnvironment.new()
    world.environment=Environment.new()
    world.environment.background_mode=Environment.BG_COLOR
    world.environment.background_color=Color(1,.969,.91)
    world.environment.tonemap_mode=Environment.TONE_MAPPER_LINEAR
    add_child(world)
    camera=Camera3D.new();camera.projection=Camera3D.PROJECTION_ORTHOGONAL
    camera.size=1.60;camera.near=.01;camera.far=100;add_child(camera);camera.current=true
    var canvas := CanvasLayer.new();add_child(canvas)
    var toolbar := HBoxContainer.new();toolbar.position=Vector2(24,20);toolbar.add_theme_constant_override("separation",14)
    canvas.add_child(toolbar)
    var previous := Button.new();previous.text="Previous";previous.pressed.connect(func(): _show(index-1));toolbar.add_child(previous)
    selector=OptionButton.new()
    for entry: Dictionary in entries: selector.add_item(str(entry["name_en"]))
    selector.item_selected.connect(_show);toolbar.add_child(selector)
    var next := Button.new();next.text="Next";next.pressed.connect(func(): _show(index+1));toolbar.add_child(next)
    spin=CheckButton.new();spin.text="Rotate";toolbar.add_child(spin)
    spin.add_theme_color_override("font_color",Color(.15,.12,.10))
    spin.add_theme_color_override("font_hover_color",Color(.15,.12,.10))
    title=Label.new();title.position=Vector2(24,74);title.add_theme_color_override("font_color",Color(.15,.12,.10))
    title.add_theme_font_size_override("font_size",24);canvas.add_child(title)
    var help := Label.new();help.text="Drag to turn  |  Wheel to zoom  |  Left / Right: item  |  Space: rotate  |  R: reset"
    help.anchor_top=1.0;help.anchor_bottom=1.0
    help.offset_left=24;help.offset_top=-40;help.offset_right=1100;help.offset_bottom=-14
    help.add_theme_color_override("font_color",Color(.25,.20,.16));canvas.add_child(help)
    _show(0)

func _show(requested: int) -> void:
    if shown!=null:
        remove_child(shown);shown.queue_free()
    index=posmod(requested,entries.size());selector.select(index)
    var entry: Dictionary=entries[index]
    shown=(load("res://assets/household_items/scenes/"+str(entry["id"])+".tscn") as PackedScene).instantiate() as Node3D
    add_child(shown)
    var size: Array=entry["size_m"]
    var factor: float=1.0/maxf(float(size[0]),maxf(float(size[1]),float(size[2])))
    shown.scale=Vector3.ONE*factor
    var target := Vector3(0,float(size[2])*factor*.5,0)
    camera.position=target+Vector3(2.4,1.6,3.4);camera.look_at(target);camera.size=1.6
    title.text="%02d / %02d   %s"%[index+1,entries.size(),str(entry["name_en"])]

func _process(delta: float) -> void:
    if spin.button_pressed and shown!=null: shown.rotation.y+=delta*.7

func _unhandled_input(event: InputEvent) -> void:
    if event is InputEventMouseMotion and (event.button_mask&MOUSE_BUTTON_MASK_LEFT)!=0 and shown!=null:
        shown.rotation.y+=event.relative.x*.012
    if event is InputEventMouseButton and event.pressed:
        if event.button_index==MOUSE_BUTTON_WHEEL_UP: camera.size=maxf(.5,camera.size*.9)
        if event.button_index==MOUSE_BUTTON_WHEEL_DOWN: camera.size=minf(4,camera.size*1.1)
    if event is InputEventKey and event.pressed and not event.echo:
        if event.keycode==KEY_LEFT: _show(index-1)
        if event.keycode==KEY_RIGHT: _show(index+1)
        if event.keycode==KEY_SPACE: spin.button_pressed=not spin.button_pressed
        if event.keycode==KEY_R: _show(index)
