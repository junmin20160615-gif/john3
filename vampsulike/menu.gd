extends Node2D

# 시작 메뉴: 할 게임을 고름

const SCREEN := Vector2(1152, 648)

const GAMES := [
	{"name": "초원 먹이사슬", "desc": "회색 도마뱀\n개미부터 매까지 8종", "scene": "res://foodchain.tscn", "color": Color("4c8c3a")},
	{"name": "바다 먹이사슬", "desc": "새우에서 시작해 진화!\n바다 생물 16종", "scene": "res://ocean.tscn", "color": Color("1971c2")},
	{"name": "뱀서라이크", "desc": "몰려오는 괴물을 피해\n5분 동안 살아남기", "scene": "res://main.tscn", "color": Color("5f3dc4")},
	{"name": "드래곤 판타지", "desc": "불을 뿜는 용이 되어\n기사단과 용사를 물리치기", "scene": "res://dragon.tscn", "color": Color("c2410c")},
]

var anim_t := 0.0


func _ready() -> void:
	RenderingServer.set_default_clear_color(Color("1b1b2a"))


func card_rect(i: int) -> Rect2:
	return Rect2(56 + i * 264, 230, 248, 300)


func _unhandled_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo:
		var idx := key.keycode - KEY_1
		if idx >= 0 and idx < GAMES.size():
			start(idx)
	var mb := event as InputEventMouseButton
	if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
		for i in GAMES.size():
			if card_rect(i).has_point(get_global_mouse_position()):
				start(i)


func start(i: int) -> void:
	get_tree().change_scene_to_file(GAMES[i]["scene"])


func _process(delta: float) -> void:
	anim_t += delta
	queue_redraw()


func outlined(text: String, pos: Vector2, align: HorizontalAlignment, width: float, size: int, color := Color.WHITE) -> void:
	var font := ThemeDB.fallback_font
	draw_string_outline(font, pos, text, align, width, size, 6, Color(0, 0, 0, 0.8))
	draw_string(font, pos, text, align, width, size, color)


func _draw() -> void:
	var font := ThemeDB.fallback_font
	var mouse := get_global_mouse_position()
	outlined("어떤 게임을 할까요?", Vector2(0, 130), HORIZONTAL_ALIGNMENT_CENTER, SCREEN.x, 44, Color("ffd43b"))
	outlined("1 / 2 / 3 / 4 키 또는 클릭", Vector2(0, 175), HORIZONTAL_ALIGNMENT_CENTER, SCREEN.x, 20, Color(1, 1, 1, 0.7))
	for i in GAMES.size():
		var g: Dictionary = GAMES[i]
		var rect := card_rect(i)
		var hovered := rect.has_point(mouse)
		if hovered:
			rect = rect.grow(8)
		var col: Color = g["color"]
		draw_rect(Rect2(rect.position + Vector2(0, 8), rect.size), Color(0, 0, 0, 0.5))
		draw_rect(rect, col.lightened(0.1) if hovered else col)
		# 카드 안에 떠다니는 거품/점 장식
		for k in 8:
			var t := fmod(anim_t * 0.2 + k * 0.125, 1.0)
			var p := rect.position + Vector2(30 + k * 34, rect.size.y * (1 - t))
			draw_circle(p, 3 + k % 3, Color(1, 1, 1, 0.12))
		draw_rect(rect, Color("ffe066") if hovered else Color(1, 1, 1, 0.5), false, 3 if hovered else 2)
		outlined("[%d]" % (i + 1), rect.position + Vector2(0, 70), HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, 28, Color("ffd43b"))
		outlined(g["name"], rect.position + Vector2(0, 130), HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, 30)
		draw_multiline_string(font, rect.position + Vector2(0, 190), g["desc"], HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, 18, -1, Color(1, 1, 1, 0.85))
