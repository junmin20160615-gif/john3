extends Node2D

const SCREEN := Vector2(1152, 648)
const WATER_Y := 160.0
const FLOOR_Y := 625.0
const GAME_TIME := 60.0

const BOAT_SPEED := 320.0
const HOOK_DOWN_SPEED := 260.0
const HOOK_UP_SPEED := 360.0
const HOOK_REST_Y := WATER_Y + 20.0
const MAX_FISH := 9

const FISH_TYPES := [
	{"name": "송사리", "color": Color("ffa94d"), "size": 16.0, "points": 10, "speed": 110.0, "min_y": 220.0, "max_y": 380.0, "weight": 5},
	{"name": "고등어", "color": Color("4dabf7"), "size": 24.0, "points": 30, "speed": 160.0, "min_y": 340.0, "max_y": 500.0, "weight": 3},
	{"name": "참치", "color": Color("7048e8"), "size": 34.0, "points": 80, "speed": 200.0, "min_y": 460.0, "max_y": 590.0, "weight": 2},
	{"name": "황금붕어", "color": Color("ffd43b"), "size": 20.0, "points": 150, "speed": 290.0, "min_y": 540.0, "max_y": 605.0, "weight": 1},
]

enum State { READY, PLAYING, OVER }
enum Hook { IDLE, DOWN, UP }

var state := State.READY
var hook_state := Hook.IDLE
var boat_x := SCREEN.x / 2
var hook_y := HOOK_REST_Y
var fish: Array[Dictionary] = []  # { type, pos, dir, speed, phase }
var hooked: Dictionary = {}  # 지금 바늘에 걸린 물고기 (없으면 빈 딕셔너리)
var score := 0
var time_left := GAME_TIME
var anim_t := 0.0
var catch_text := ""
var catch_timer := 0.0


func _ready() -> void:
	RenderingServer.set_default_clear_color(Color("87ceeb"))
	for i in MAX_FISH:
		spawn_fish(true)


func new_game() -> void:
	score = 0
	time_left = GAME_TIME
	hook_state = Hook.IDLE
	hook_y = HOOK_REST_Y
	hooked = {}
	catch_timer = 0.0
	state = State.PLAYING


func pick_fish_type() -> Dictionary:
	var total := 0
	for t in FISH_TYPES:
		total += t["weight"]
	var r := randi() % total
	for t in FISH_TYPES:
		r -= t["weight"]
		if r < 0:
			return t
	return FISH_TYPES[0]


# anywhere가 true면 화면 아무 곳에, 아니면 화면 밖 왼쪽/오른쪽에서 등장
func spawn_fish(anywhere: bool) -> void:
	var t := pick_fish_type()
	var dir := 1 if randf() < 0.5 else -1
	var x := randf_range(0, SCREEN.x) if anywhere else (-50.0 if dir == 1 else SCREEN.x + 50.0)
	fish.append({
		"type": t,
		"pos": Vector2(x, randf_range(t["min_y"], t["max_y"])),
		"dir": dir,
		"speed": t["speed"] * randf_range(0.8, 1.2),
		"phase": randf() * TAU,
	})


func _unhandled_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	var clicked := mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT
	if not (clicked or event.is_action_pressed("ui_accept")):
		return

	if state != State.PLAYING:
		new_game()
	elif hook_state == Hook.IDLE:
		hook_state = Hook.DOWN
	elif hook_state == Hook.DOWN:
		hook_state = Hook.UP


func _process(delta: float) -> void:
	anim_t += delta
	update_fish(delta)

	if state == State.PLAYING:
		boat_x += Input.get_axis("ui_left", "ui_right") * BOAT_SPEED * delta
		boat_x = clampf(boat_x, 90, SCREEN.x - 150)
		update_hook(delta)
		time_left -= delta
		if time_left <= 0:
			time_left = 0
			state = State.OVER

	catch_timer = maxf(catch_timer - delta, 0)
	queue_redraw()


func update_fish(delta: float) -> void:
	for i in range(fish.size() - 1, -1, -1):
		var f := fish[i]
		var pos: Vector2 = f["pos"]
		pos.x += f["dir"] * f["speed"] * delta
		pos.y += sin(anim_t * 2 + f["phase"]) * 12 * delta
		f["pos"] = pos
		if pos.x < -80 or pos.x > SCREEN.x + 80:
			fish.remove_at(i)
	while fish.size() < MAX_FISH:
		spawn_fish(false)


func rod_tip() -> Vector2:
	return Vector2(boat_x + 60, WATER_Y - 80)


func hook_pos() -> Vector2:
	return Vector2(rod_tip().x, hook_y)


func update_hook(delta: float) -> void:
	match hook_state:
		Hook.DOWN:
			hook_y += HOOK_DOWN_SPEED * delta
			if hook_y >= FLOOR_Y:
				hook_y = FLOOR_Y
				hook_state = Hook.UP
		Hook.UP:
			# 큰 물고기가 걸리면 천천히 올라옴
			var slow := 1.0
			if not hooked.is_empty():
				slow = 1.0 - hooked["type"]["size"] / 80.0
			hook_y -= HOOK_UP_SPEED * slow * delta
			if hook_y <= HOOK_REST_Y:
				hook_y = HOOK_REST_Y
				hook_state = Hook.IDLE
				land_fish()

	if hook_state != Hook.IDLE and hooked.is_empty():
		for i in fish.size():
			var f := fish[i]
			if hook_pos().distance_to(f["pos"]) < f["type"]["size"] + 6:
				hooked = f
				fish.remove_at(i)
				hook_state = Hook.UP
				break


func land_fish() -> void:
	if hooked.is_empty():
		return
	var t: Dictionary = hooked["type"]
	score += t["points"]
	catch_text = "%s 낚았다! +%d" % [t["name"], t["points"]]
	catch_timer = 1.5
	hooked = {}


func _draw() -> void:
	var font := ThemeDB.fallback_font

	# 하늘과 해
	draw_rect(Rect2(0, 0, SCREEN.x, WATER_Y), Color("87ceeb"))
	draw_circle(Vector2(980, 60), 34, Color("fff3a3"))

	# 물결치는 바다
	var water := PackedVector2Array()
	for x in range(0, int(SCREEN.x) + 24, 24):
		water.append(Vector2(x, WATER_Y + sin(anim_t * 2 + x * 0.03) * 4))
	water.append(Vector2(SCREEN.x, SCREEN.y))
	water.append(Vector2(0, SCREEN.y))
	draw_colored_polygon(water, Color("1e6fa8"))
	draw_rect(Rect2(0, 420, SCREEN.x, SCREEN.y - 420), Color(0, 0, 0.2, 0.25))
	draw_rect(Rect2(0, FLOOR_Y + 8, SCREEN.x, SCREEN.y - FLOOR_Y), Color("d9b77a"))

	for f in fish:
		draw_fish(f["pos"], f["type"], f["dir"], 0.0)

	# 배와 낚시꾼
	var b := boat_x
	draw_colored_polygon(PackedVector2Array([
		Vector2(b - 75, WATER_Y - 15), Vector2(b + 75, WATER_Y - 15),
		Vector2(b + 52, WATER_Y + 15), Vector2(b - 52, WATER_Y + 15),
	]), Color("8b5a2b"))
	draw_rect(Rect2(b - 20, WATER_Y - 55, 22, 40), Color("e03131"))
	draw_circle(Vector2(b - 9, WATER_Y - 66), 12, Color("ffd8a8"))
	draw_line(Vector2(b, WATER_Y - 35), rod_tip(), Color("5c3d1e"), 4)

	# 낚싯줄, 바늘, 걸린 물고기
	var hp := hook_pos()
	draw_line(rod_tip(), hp, Color(1, 1, 1, 0.8), 1.5)
	draw_arc(hp + Vector2(0, 6), 6, 0, PI, 10, Color("dee2e6"), 2)
	if not hooked.is_empty():
		var size: float = hooked["type"]["size"]
		draw_fish(hp + Vector2(0, size + 4), hooked["type"], 1, -PI / 2 + sin(anim_t * 15) * 0.3)

	# 화면 정보
	draw_string(font, Vector2(20, 40), "점수: %d" % score, HORIZONTAL_ALIGNMENT_LEFT, -1, 26, Color.BLACK)
	draw_string(font, Vector2(20, 75), "남은 시간: %d" % ceili(time_left), HORIZONTAL_ALIGNMENT_LEFT, -1, 22, Color.BLACK)
	if catch_timer > 0:
		draw_string(font, Vector2(0, 45), catch_text, HORIZONTAL_ALIGNMENT_CENTER, SCREEN.x, 28, Color("212529"))

	var message := ""
	match state:
		State.READY:
			message = "← → 로 배 이동, 스페이스로 낚싯줄 내리기/올리기\n스페이스 또는 클릭으로 시작"
		State.OVER:
			message = "시간 종료! 최종 점수: %d\n스페이스 또는 클릭으로 다시 시작" % score
	if message != "":
		draw_rect(Rect2(176, 250, 800, 130), Color(0, 0, 0, 0.55))
		draw_multiline_string(font, Vector2(176, 300), message, HORIZONTAL_ALIGNMENT_CENTER, 800, 28)


# dir: 1이면 오른쪽, -1이면 왼쪽을 바라봄
func draw_fish(pos: Vector2, t: Dictionary, dir: int, rot: float) -> void:
	var s: float = t["size"]
	draw_set_transform(pos, rot, Vector2(dir, 1))
	var body := PackedVector2Array()
	for i in 16:
		var a := TAU * i / 16
		body.append(Vector2(cos(a) * s, sin(a) * s * 0.55))
	draw_colored_polygon(PackedVector2Array([
		Vector2(-s * 0.8, 0), Vector2(-s * 1.5, -s * 0.5), Vector2(-s * 1.5, s * 0.5),
	]), t["color"].darkened(0.2))
	draw_colored_polygon(body, t["color"])
	draw_circle(Vector2(s * 0.5, -s * 0.15), s * 0.12, Color.BLACK)
	draw_set_transform(Vector2.ZERO, 0, Vector2.ONE)
