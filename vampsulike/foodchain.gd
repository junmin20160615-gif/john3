extends Node2D

# 먹이사슬 게임: 나보다 작은 동물은 먹고 큰 동물은 피하면서 자라서 먹이사슬 꼭대기에 오르기

const SCREEN := Vector2(1152, 648)
const START_RADIUS := 12.0
const WIN_RADIUS := 64.0
const MAX_HEARTS := 3
const MAX_CREATURES := 45
const MAX_PARTICLES := 300
const GROW_RATE := 0.35  # 먹은 동물 넓이의 이만큼이 내 몸에 더해짐

# 작은 동물부터 큰 동물 순서
const SPECIES := [
	{"name": "개미", "shape": "ant", "r": 5.0, "speed": 45.0, "color": Color("343a40")},
	{"name": "파리", "shape": "fly", "r": 7.0, "speed": 100.0, "color": Color("495057")},
	{"name": "메뚜기", "shape": "grasshopper", "r": 10.0, "speed": 110.0, "color": Color("c0eb75")},
	{"name": "개구리", "shape": "frog", "r": 15.0, "speed": 120.0, "color": Color("69db7c")},
	{"name": "쥐", "shape": "mouse", "r": 20.0, "speed": 140.0, "color": Color("a68b6d")},
	{"name": "뱀", "shape": "snake", "r": 28.0, "speed": 150.0, "color": Color("e8a838")},
	{"name": "여우", "shape": "fox", "r": 38.0, "speed": 190.0, "color": Color("f76707")},
	{"name": "매", "shape": "hawk", "r": 52.0, "speed": 230.0, "color": Color("8d5b3a")},
]

enum State { READY, PLAYING, OVER, WON, PAUSED }

var state := State.READY
var anim_t := 0.0
var elapsed := 0.0
var eaten := 0

var player_pos := Vector2.ZERO
var player_r := START_RADIUS
var hearts := MAX_HEARTS
var facing := Vector2.RIGHT
var moving := false
var invuln := 0.0
var knock := Vector2.ZERO

# 도마뱀이 커질수록 화면을 멀리 봄
var zoom := 1.0
var cam := Vector2.ZERO

var creatures: Array[Dictionary] = []  # { sp, pos, dir, turn, phase, mood }
var particles: Array[Dictionary] = []  # { pos, vel, life, max_life, color, size }
var texts: Array[Dictionary] = []  # 떠오르는 글자 { pos, text, life, color }

# 연출용
var shake := 0.0
var hurt_flash := 0.0
var grow_flash := 0.0


func _ready() -> void:
	RenderingServer.set_default_clear_color(Color("4c8c3a"))
	new_game()
	state = State.READY


func new_game() -> void:
	anim_t = 0.0
	elapsed = 0.0
	eaten = 0
	player_pos = Vector2.ZERO
	player_r = START_RADIUS
	hearts = MAX_HEARTS
	facing = Vector2.RIGHT
	invuln = 0.0
	knock = Vector2.ZERO
	zoom = target_zoom()
	creatures.clear()
	particles.clear()
	texts.clear()
	shake = 0.0
	hurt_flash = 0.0
	grow_flash = 0.0
	for i in 30:
		spawn_creature(true)
	state = State.PLAYING


func target_zoom() -> float:
	return clampf(18.0 / player_r, 0.3, 1.3)


# 화면 가운데에서 모서리까지의 월드 거리
func view_radius() -> float:
	return (SCREEN / 2 / zoom).length()


# 1: 먹을 수 있음, 0: 비슷한 크기, -1: 위험
func relation(sp: Dictionary) -> int:
	var r: float = sp["r"]
	if r < player_r * 0.9:
		return 1
	if r > player_r * 1.1:
		return -1
	return 0


func _unhandled_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	var clicked := mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT
	var key := event as InputEventKey
	if key != null and key.pressed and key.keycode == KEY_M:
		get_tree().change_scene_to_file("res://menu.tscn")
		return

	match state:
		State.READY, State.OVER, State.WON:
			if clicked or event.is_action_pressed("ui_accept"):
				new_game()
		State.PLAYING:
			if event.is_action_pressed("ui_cancel"):
				state = State.PAUSED
		State.PAUSED:
			if event.is_action_pressed("ui_cancel") or event.is_action_pressed("ui_accept") or clicked:
				state = State.PLAYING


func _process(delta: float) -> void:
	anim_t += delta
	if state == State.PLAYING:
		update_game(delta)
	queue_redraw()


func update_game(delta: float) -> void:
	elapsed += delta
	shake = move_toward(shake, 0, 40 * delta)
	hurt_flash = maxf(hurt_flash - delta, 0)
	grow_flash = maxf(grow_flash - delta, 0)
	zoom = lerpf(zoom, target_zoom(), 1.0 - exp(-2.0 * delta))
	move_player(delta)
	update_creatures(delta)
	update_effects(delta)
	while creatures.size() < MAX_CREATURES:
		spawn_creature(false)


func move_player(delta: float) -> void:
	var dir := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	var wasd := Vector2(
		float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A)),
		float(Input.is_physical_key_pressed(KEY_S)) - float(Input.is_physical_key_pressed(KEY_W))
	)
	dir = (dir + wasd).limit_length(1.0)
	moving = dir != Vector2.ZERO
	if moving:
		facing = dir.normalized()
	var speed := 150.0 + player_r * 2.2
	player_pos += dir * speed * delta + knock * delta
	knock = knock.move_toward(Vector2.ZERO, 900 * delta)
	invuln = maxf(invuln - delta, 0)


# 내 크기 근처의 동물이 주로 나옴. 먹을 수 있는 동물이 더 자주 나옴
func pick_species() -> Dictionary:
	var pool: Array[Dictionary] = []
	var weights: Array[float] = []
	var total := 0.0
	for sp in SPECIES:
		var r: float = sp["r"]
		if r >= player_r * 0.3 and r <= player_r * 2.2:
			var w: float = [1.0, 1.5, 3.0][relation(sp) + 1]
			pool.append(sp)
			weights.append(w)
			total += w
	var roll := randf() * total
	for i in pool.size():
		roll -= weights[i]
		if roll <= 0:
			return pool[i]
	return pool.back()


# anywhere가 참이면 화면 안에도 놓음 (위험한 동물은 항상 화면 밖에서 나옴)
func spawn_creature(anywhere: bool) -> void:
	var sp := pick_species()
	var vr := view_radius()
	var dist := randf_range(vr + 60, vr + 300)
	if anywhere and relation(sp) >= 0:
		dist = randf_range(150, vr)
	creatures.append({
		"sp": sp, "pos": player_pos + Vector2.RIGHT.rotated(randf() * TAU) * dist,
		"dir": Vector2.RIGHT.rotated(randf() * TAU), "turn": randf_range(0.5, 2.0),
		"phase": randf() * TAU, "mood": 0,
	})


func update_creatures(delta: float) -> void:
	var vr := view_radius()
	for i in range(creatures.size() - 1, -1, -1):
		var c := creatures[i]
		var sp: Dictionary = c["sp"]
		var r: float = sp["r"]
		var pos: Vector2 = c["pos"]
		var to_player := player_pos - pos
		var dist := to_player.length()
		if dist > vr * 2.5:
			creatures.remove_at(i)
			continue

		# 작은 동물은 도망가고, 큰 동물은 쫓아옴 (내가 맞은 직후에는 봐줌)
		var rel := relation(sp)
		var mood := 0
		if rel == 1 and dist < 110 + player_r * 3:
			mood = 1
		elif rel == -1 and dist < 200 + r * 3 and invuln <= 0:
			mood = -1
		c["mood"] = mood

		var dir: Vector2 = c["dir"]
		var speed: float = sp["speed"]
		var away := -to_player / maxf(dist, 0.001)
		if mood == 1:
			dir = dir.slerp(away, 1.0 - exp(-6.0 * delta))
		elif mood == -1:
			dir = dir.slerp(-away, 1.0 - exp(-5.0 * delta))
		else:
			c["turn"] -= delta
			if c["turn"] <= 0:
				dir = dir.rotated(randf_range(-1.5, 1.5))
				c["turn"] = randf_range(0.6, 2.2)
			speed *= 0.4

		match sp["shape"]:
			"fly":
				dir = dir.rotated(sin(anim_t * 9 + c["phase"]) * 3 * delta)
			"grasshopper", "frog":
				# 폴짝폴짝 뛰어다님
				speed *= maxf(0, sin(anim_t * 5 + c["phase"])) * 2.2
		dir = dir.normalized()
		pos += dir * speed * delta
		c["dir"] = dir
		c["pos"] = pos

		var touch := r * 0.8 + player_r * 0.8
		if dist < touch:
			match rel:
				1:
					eat(i)
				-1:
					if invuln <= 0:
						hurt_player(pos)
				0:
					var push := away * (touch - dist) * 0.5
					c["pos"] = pos + push
					player_pos -= push


func eat(i: int) -> void:
	var c := creatures[i]
	var sp: Dictionary = c["sp"]
	var r: float = sp["r"]
	var old_r := player_r
	player_r = sqrt(player_r * player_r + GROW_RATE * r * r)
	eaten += 1
	grow_flash = 0.3
	burst(c["pos"], sp["color"], 10, 60 + r * 4, 2 + r * 0.2)
	add_text(c["pos"], "냠! %s" % sp["name"], Color("ffe066"))
	creatures.remove_at(i)

	# 새로 먹을 수 있게 된 동물을 알려줌
	for s in SPECIES:
		var sr: float = s["r"]
		if sr >= old_r * 0.9 and sr < player_r * 0.9:
			add_text(player_pos + Vector2(0, -player_r * 3), "이제 %s도 먹을 수 있어!" % s["name"], Color("69db7c"))

	if player_r >= WIN_RADIUS:
		burst(player_pos, Color("ffd43b"), 40, 400, 8)
		state = State.WON


func hurt_player(from: Vector2) -> void:
	hearts -= 1
	invuln = 1.5
	hurt_flash = 0.3
	shake = 10
	knock = from.direction_to(player_pos) * 500
	add_text(player_pos + Vector2(0, -player_r * 2), "아야!", Color("ff6b6b"))
	burst(player_pos, Color("ff6b6b"), 12, 200, 4)
	if hearts <= 0:
		state = State.OVER


func add_text(pos: Vector2, text: String, color: Color) -> void:
	texts.append({"pos": pos, "text": text, "life": 1.2, "color": color})


func burst(pos: Vector2, color: Color, count: int, speed: float, size: float) -> void:
	for i in count:
		if particles.size() >= MAX_PARTICLES:
			return
		var life := randf_range(0.3, 0.6)
		particles.append({
			"pos": pos, "vel": Vector2.RIGHT.rotated(randf() * TAU) * randf_range(0.3, 1.0) * speed,
			"life": life, "max_life": life, "color": color, "size": size,
		})


func update_effects(delta: float) -> void:
	for i in range(particles.size() - 1, -1, -1):
		var p := particles[i]
		p["pos"] += p["vel"] * delta
		p["vel"] *= exp(-4.0 * delta)
		p["life"] -= delta
		if p["life"] <= 0:
			particles.remove_at(i)
	for i in range(texts.size() - 1, -1, -1):
		var t := texts[i]
		t["pos"] += Vector2(0, -40 / zoom) * delta
		t["life"] -= delta
		if t["life"] <= 0:
			texts.remove_at(i)


func fmt_time(t: float) -> String:
	return "%d:%02d" % [int(t) / 60, int(t) % 60]


# ---------- 그리기 ----------

func world_to_screen(p: Vector2) -> Vector2:
	return SCREEN / 2 + (p - cam) * zoom


# pos를 원점으로, rot만큼 돌리고 scl배 키운 좌표계로 그림
func use_local(pos: Vector2, rot: float, scl: float) -> void:
	draw_set_transform(world_to_screen(pos), rot, Vector2(scl, scl) * zoom)


func use_world() -> void:
	draw_set_transform(SCREEN / 2 - cam * zoom, 0, Vector2(zoom, zoom))


func oval(center: Vector2, length: float, width: float, color: Color, rot := 0.0) -> void:
	var pts := PackedVector2Array()
	for i in 16:
		var a := TAU * i / 16
		pts.append(center + Vector2(cos(a) * length, sin(a) * width).rotated(rot))
	draw_colored_polygon(pts, color)


func is_flying(c: Dictionary) -> bool:
	return c["sp"]["shape"] in ["fly", "hawk"]


func _draw() -> void:
	# 플레이어가 화면 가운데 오도록 (맞으면 화면이 흔들림)
	cam = player_pos + Vector2(randf_range(-1, 1), randf_range(-1, 1)) * shake / zoom
	use_world()
	draw_ground()

	# 땅에 있는 동물 → 도마뱀 → 날아다니는 동물 순서로 그림
	for c in creatures:
		if not is_flying(c):
			draw_creature(c)
	draw_player()
	for c in creatures:
		if is_flying(c):
			draw_creature(c)

	use_world()
	for p in particles:
		var a: float = p["life"] / p["max_life"]
		draw_circle(p["pos"], p["size"] * a, Color(p["color"], a))

	draw_set_transform(Vector2.ZERO)
	var font := ThemeDB.fallback_font
	for t in texts:
		var a: float = clampf(t["life"] / 0.3, 0, 1)
		var p := world_to_screen(t["pos"]) - Vector2(150, 0)
		draw_string_outline(font, p, t["text"], HORIZONTAL_ALIGNMENT_CENTER, 300, 18, 4, Color(0, 0, 0, a))
		draw_string(font, p, t["text"], HORIZONTAL_ALIGNMENT_CENTER, 300, 18, Color(t["color"], a))

	draw_vignette()
	if hurt_flash > 0:
		draw_rect(Rect2(Vector2.ZERO, SCREEN), Color(1, 0, 0, 0.25 * hurt_flash / 0.3))
	draw_hud()


# 바닥: 푸른 초원. 칸마다 정해진 풀 무늬/풀숲/꽃/돌 장식
func draw_ground() -> void:
	const STEP := 64.0
	var half := SCREEN / 2 / zoom
	var x0 := floori((cam.x - half.x) / STEP) - 1
	var y0 := floori((cam.y - half.y) / STEP) - 1
	var x1 := x0 + int(half.x * 2 / STEP) + 3
	var y1 := y0 + int(half.y * 2 / STEP) + 3
	var flowers := [Color("fff9db"), Color("ffe066"), Color("faa2c1"), Color("d0bfff")]

	# 밝고 어두운 풀 얼룩 (칸 경계를 넘어 퍼져서 타일이 안 보임)
	for cx in range(x0, x1):
		for cy in range(y0, y1):
			var origin := Vector2(cx, cy) * STEP
			var h := hash(Vector2i(cx, cy))
			if posmod(h >> 4, 3) == 0:
				draw_circle(origin + Vector2(32, 32), 40 + posmod(h >> 12, 16), Color("57983f", 0.35))
			elif posmod(h >> 4, 5) == 1:
				draw_circle(origin + Vector2(32, 32), 34 + posmod(h >> 12, 12), Color("437f33", 0.35))

	for cx in range(x0, x1):
		for cy in range(y0, y1):
			var h := hash(Vector2i(cx, cy))
			var spot := Vector2(cx, cy) * STEP + Vector2(posmod(h, 48) + 8, posmod(h >> 8, 48) + 8)
			match posmod(h, 6):
				0, 1:
					# 바람에 살짝 흔들리는 풀숲
					var sway := sin(anim_t * 2 + cx * 0.7 + cy * 0.3) * 1.5
					for k in [-1, 0, 1]:
						var base: Vector2 = spot + Vector2(k * 4, 0)
						draw_line(base, base + Vector2(k * 4 + sway, -9 + absi(k) * 2), Color("2f6b24"), 2)
						draw_line(base + Vector2(1, 0), base + Vector2(k * 3 + sway + 1, -7), Color("7bc25a"), 1.5)
				2:
					var col: Color = flowers[posmod(h >> 16, flowers.size())]
					for k in 5:
						draw_circle(spot + Vector2.RIGHT.rotated(TAU * k / 5) * 3, 2.5, col)
					draw_circle(spot, 2, Color("f59f00"))
				3:
					if posmod(h >> 20, 4) == 0:
						oval(spot + Vector2(0, 3), 7, 2.5, Color(0, 0, 0, 0.2))
						draw_circle(spot, 5, Color("8a9199"))
						draw_circle(spot + Vector2(-1.5, -1.5), 3, Color("adb5bd"))


func draw_creature(c: Dictionary) -> void:
	var sp: Dictionary = c["sp"]
	var r: float = sp["r"]
	var pos: Vector2 = c["pos"]
	var dir: Vector2 = c["dir"]
	var col: Color = sp["color"]
	var rel := relation(sp)

	# 그림자 (날아다니는 동물은 그림자가 멀리 떨어짐)
	use_local(pos, 0, r)
	oval(Vector2(0, 1.6 if is_flying(c) else 0.6), 0.9, 0.3, Color(0, 0, 0, 0.25))

	# 먹을 수 있으면 초록 고리, 위험하면 빨간 고리
	if rel != 0:
		use_local(pos, 0, 1)
		var ring := Color("8ce99a") if rel == 1 else Color("ff6b6b")
		var a := 0.55 + 0.3 * sin(anim_t * 6 + c["phase"])
		draw_arc(Vector2.ZERO, r * 1.45, 0, TAU, 32, Color(ring, a), 2.5 / zoom)

	use_local(pos, dir.angle(), r)
	match sp["shape"]:
		"ant": draw_ant(c, col)
		"fly": draw_fly(c, col)
		"grasshopper": draw_grasshopper(c, col)
		"frog": draw_frog(c, col)
		"mouse": draw_mouse(c, col)
		"snake": draw_snake(c, col)
		"fox": draw_fox(c, col)
		"hawk": draw_hawk(c, col)

	# 쫓아오는 동물 머리 위에 느낌표
	if c["mood"] == -1:
		draw_set_transform(Vector2.ZERO)
		var p := world_to_screen(pos + Vector2(0, -r * 1.6)) - Vector2(20, 0)
		outlined("!", p, HORIZONTAL_ALIGNMENT_CENTER, 40, 26, Color("ff6b6b"))


# 아래 동물 그림들은 모두 크기 1, 오른쪽(+X)을 바라보는 좌표로 그림

func draw_ant(c: Dictionary, col: Color) -> void:
	var wig := sin(anim_t * 20 + c["phase"]) * 0.15
	for s in [-1.0, 1.0]:
		for k in [-1.0, 0.0, 1.0]:
			draw_line(Vector2(k * 0.3, 0), Vector2(k * 0.45 + wig * s, s * 0.8), col, 0.12)
		draw_line(Vector2(0.8, s * 0.1), Vector2(1.2, s * 0.45), col, 0.08)
	draw_circle(Vector2(-0.75, 0), 0.38, col)
	draw_circle(Vector2.ZERO, 0.25, col)
	draw_circle(Vector2(0.6, 0), 0.3, col)


func draw_fly(c: Dictionary, col: Color) -> void:
	var flap := absf(sin(anim_t * 40 + c["phase"]))
	for s in [-1.0, 1.0]:
		oval(Vector2(-0.2, s * 0.55), 0.6, 0.3 * (0.4 + 0.6 * flap), Color(0.9, 0.95, 1, 0.55), s * 0.4)
	oval(Vector2.ZERO, 0.8, 0.45, col)
	for s in [-1.0, 1.0]:
		draw_circle(Vector2(0.55, s * 0.25), 0.22, Color("c92a2a"))


func draw_grasshopper(c: Dictionary, col: Color) -> void:
	var dark := col.darkened(0.35)
	for s in [-1.0, 1.0]:
		draw_polyline(PackedVector2Array([Vector2(0, s * 0.25), Vector2(0.35, s * 0.75), Vector2(-0.8, s * 0.55)]), dark, 0.14)
		draw_line(Vector2(0.5, s * 0.2), Vector2(0.8, s * 0.55), dark, 0.1)
		draw_line(Vector2(1.05, s * 0.1), Vector2(1.6, s * 0.5), dark, 0.06)
	oval(Vector2(-0.1, 0), 1.0, 0.32, col)
	draw_circle(Vector2(0.85, 0), 0.3, col)
	for s in [-1.0, 1.0]:
		draw_circle(Vector2(0.95, s * 0.18), 0.09, Color("212529"))


func draw_frog(c: Dictionary, col: Color) -> void:
	var dark := col.darkened(0.35)
	var light := col.lightened(0.4)
	for s in [-1.0, 1.0]:
		oval(Vector2(-0.6, s * 0.6), 0.5, 0.25, dark, s * 0.6)
		oval(Vector2(0.5, s * 0.6), 0.3, 0.15, dark, -s * 0.5)
	draw_circle(Vector2.ZERO, 0.85, col)
	draw_circle(Vector2(-0.3, 0.2), 0.15, dark)
	draw_circle(Vector2(-0.1, -0.3), 0.12, dark)
	for s in [-1.0, 1.0]:
		draw_circle(Vector2(0.45, s * 0.45), 0.25, light)
		draw_circle(Vector2(0.5, s * 0.45), 0.13, Color("212529"))


func draw_mouse(c: Dictionary, col: Color) -> void:
	var pink := Color("f3a6b5")
	var tail := PackedVector2Array()
	for k in 6:
		tail.append(Vector2(-0.9 - k * 0.25, sin(anim_t * 6 + c["phase"] + k * 0.8) * 0.12 * k))
	draw_polyline(tail, pink, 0.08)
	oval(Vector2(-0.1, 0), 0.9, 0.55, col)
	oval(Vector2(0.75, 0), 0.45, 0.35, col)
	for s in [-1.0, 1.0]:
		draw_circle(Vector2(0.55, s * 0.38), 0.22, col.darkened(0.15))
		draw_circle(Vector2(0.55, s * 0.38), 0.13, pink)
		draw_circle(Vector2(0.9, s * 0.17), 0.07, Color("212529"))
		draw_line(Vector2(1.1, s * 0.05), Vector2(1.35, s * 0.3), Color(1, 1, 1, 0.6), 0.03)
	draw_circle(Vector2(1.18, 0), 0.08, Color("e64980"))


func draw_snake(c: Dictionary, col: Color) -> void:
	const N := 11
	var dark := col.darkened(0.4)
	var pts: Array[Vector2] = []
	for k in N:
		pts.append(Vector2(0.8 - k * 0.32, sin(anim_t * 7 + c["phase"] - k * 0.7) * 0.35 * minf(1, k / 2.0)))
	for k in range(N - 1, 0, -1):
		var w := lerpf(0.5, 0.12, float(k) / N)
		draw_line(pts[k - 1], pts[k], col, w)
		draw_circle(pts[k], w / 2, col)
		if k % 2 == 0:
			draw_circle(pts[k], w * 0.28, dark)
	oval(Vector2(0.95, 0), 0.35, 0.28, col)
	for s in [-1.0, 1.0]:
		draw_circle(Vector2(1.05, s * 0.15), 0.06, Color("212529"))
	if sin(anim_t * 4 + c["phase"]) > 0.6:
		var red := Color("e03131")
		draw_line(Vector2(1.25, 0), Vector2(1.6, 0), red, 0.05)
		draw_line(Vector2(1.6, 0), Vector2(1.72, 0.08), red, 0.04)
		draw_line(Vector2(1.6, 0), Vector2(1.72, -0.08), red, 0.04)


func draw_fox(c: Dictionary, col: Color) -> void:
	var white := Color("f8f9fa")
	var dark := Color("212529")
	var sw := sin(anim_t * 4 + c["phase"]) * 0.25
	var step := sin(anim_t * 14 + c["phase"]) * 0.15
	for f in [-1.0, 1.0]:
		for s in [-1.0, 1.0]:
			draw_circle(Vector2(f * 0.45 + step * f * s, s * 0.4), 0.12, col.darkened(0.4))
	oval(Vector2(-1.15, sw), 0.6, 0.28, col, sw * 0.5)
	draw_circle(Vector2(-1.65, sw * 1.3), 0.17, white)
	oval(Vector2(-0.1, 0), 0.8, 0.42, col)
	for s in [-1.0, 1.0]:
		draw_colored_polygon(PackedVector2Array([Vector2(0.55, s * 0.15), Vector2(0.8, s * 0.2), Vector2(0.5, s * 0.55)]), col.darkened(0.2))
	oval(Vector2(0.75, 0), 0.38, 0.33, col)
	draw_colored_polygon(PackedVector2Array([Vector2(0.9, -0.2), Vector2(1.38, 0), Vector2(0.9, 0.2)]), white)
	draw_circle(Vector2(1.36, 0), 0.06, dark)
	for s in [-1.0, 1.0]:
		draw_circle(Vector2(0.85, s * 0.15), 0.06, dark)


func draw_hawk(c: Dictionary, col: Color) -> void:
	var span := 1.6 * (0.85 + 0.15 * sin(anim_t * 6 + c["phase"]))
	var dark := col.darkened(0.35)
	draw_colored_polygon(PackedVector2Array([Vector2(-0.4, -0.15), Vector2(-1.0, -0.3), Vector2(-1.0, 0.3), Vector2(-0.4, 0.15)]), dark)
	for s in [-1.0, 1.0]:
		draw_colored_polygon(PackedVector2Array([
			Vector2(0.25, s * 0.15), Vector2(0.0, s * span), Vector2(-0.35, s * span * 0.95), Vector2(-0.35, s * 0.2),
		]), col)
		draw_colored_polygon(PackedVector2Array([
			Vector2(0.0, s * span), Vector2(-0.35, s * span * 0.95), Vector2(-0.2, s * span * 0.7),
		]), dark)
	oval(Vector2.ZERO, 0.6, 0.25, col)
	draw_circle(Vector2(0.6, 0), 0.22, Color("e9d8c4"))
	draw_colored_polygon(PackedVector2Array([Vector2(0.75, -0.08), Vector2(0.95, 0), Vector2(0.75, 0.08)]), Color("fab005"))
	for s in [-1.0, 1.0]:
		draw_circle(Vector2(0.65, s * 0.1), 0.05, Color("212529"))


# 회색 도마뱀 (몸길이 기준 크기 14로 그린 뒤 player_r에 맞춰 키움)
func draw_player() -> void:
	var scl := player_r / 14.0
	use_local(player_pos, 0, scl)
	oval(Vector2(0, 12), 16, 5, Color(0, 0, 0, 0.35))

	# 커질 때 반짝
	if grow_flash > 0:
		var t := 1.0 - grow_flash / 0.3
		draw_arc(Vector2.ZERO, 20 + t * 20, 0, TAU, 32, Color(1, 0.9, 0.4, 1.0 - t), 3)

	# 맞은 직후에는 깜빡임
	if invuln > 0 and int(anim_t * 20) % 2 == 0:
		return

	use_local(player_pos, facing.angle(), scl)
	var f := Vector2.RIGHT
	var side := f.orthogonal()
	var skin := Color("adb5bd")
	var dark := Color("495057")

	# 꼬리: 뒤로 갈수록 가늘어지고 살랑거림
	var prev := -f * 8
	for k in range(1, 8):
		var pt := -f * (8 + k * 4) + side * sin(anim_t * 8 - k * 0.8) * k * 0.9
		draw_line(prev, pt, skin, 8 - k)
		prev = pt

	# 다리: 움직일 때만 번갈아 걸음
	var step := sin(anim_t * 16) * 4 if moving else 0.0
	for fb in [-1.0, 1.0]:
		for s in [-1.0, 1.0]:
			var hip: Vector2 = f * fb * 6 + side * s * 5
			var foot: Vector2 = hip + side * s * 7 + f * (fb * 3 + step * fb * s)
			draw_line(hip, foot, dark, 3)
			draw_circle(foot, 2.5, dark)

	# 몸통과 등 무늬
	oval(Vector2.ZERO, 12, 8, skin)
	for k in [-1.0, 0.0, 1.0]:
		draw_circle(f * k * 5, 2, dark)

	# 머리
	var head := f * 13
	oval(head, 7, 6, skin)
	for s in [-1.0, 1.0]:
		var eye: Vector2 = head + f * 1 + side * s * 4.5
		draw_circle(eye, 2.5, Color("212529"))
		draw_circle(eye + f * 0.8 - side * s * 0.6, 0.9, Color.WHITE)

	# 가끔 혀를 날름
	if sin(anim_t * 3) > 0.85:
		var tip := head + f * 13
		draw_line(head + f * 6, tip, Color("e03131"), 2)
		draw_line(tip, tip + f * 3 + side * 2, Color("e03131"), 1.5)
		draw_line(tip, tip + f * 3 - side * 2, Color("e03131"), 1.5)


# 화면 가장자리를 어둡게
func draw_vignette() -> void:
	const W := 140.0
	var dark := Color(0, 0, 0, 0.4)
	var clear := Color(0, 0, 0, 0)
	var s := SCREEN
	draw_polygon(PackedVector2Array([Vector2(0, 0), Vector2(s.x, 0), Vector2(s.x, W), Vector2(0, W)]), PackedColorArray([dark, dark, clear, clear]))
	draw_polygon(PackedVector2Array([Vector2(0, s.y - W), Vector2(s.x, s.y - W), Vector2(s.x, s.y), Vector2(0, s.y)]), PackedColorArray([clear, clear, dark, dark]))
	draw_polygon(PackedVector2Array([Vector2(0, 0), Vector2(W, 0), Vector2(W, s.y), Vector2(0, s.y)]), PackedColorArray([dark, clear, clear, dark]))
	draw_polygon(PackedVector2Array([Vector2(s.x - W, 0), Vector2(s.x, 0), Vector2(s.x, s.y), Vector2(s.x - W, s.y)]), PackedColorArray([clear, dark, dark, clear]))


func outlined(text: String, pos: Vector2, align: HorizontalAlignment, width: float, size: int, color := Color.WHITE) -> void:
	var font := ThemeDB.fallback_font
	draw_string_outline(font, pos, text, align, width, size, 6, Color(0, 0, 0, 0.8))
	draw_string(font, pos, text, align, width, size, color)


func draw_heart(center: Vector2, filled: bool) -> void:
	var col := Color("ff6b6b") if filled else Color(0, 0, 0, 0.45)
	draw_circle(center + Vector2(-6, -4), 7, col)
	draw_circle(center + Vector2(6, -4), 7, col)
	draw_colored_polygon(PackedVector2Array([center + Vector2(-12.6, -1), center + Vector2(12.6, -1), center + Vector2(0, 13)]), col)


func draw_hud() -> void:
	for i in MAX_HEARTS:
		draw_heart(Vector2(32 + i * 36, 34), i < hearts)

	# 크기 바: 꼭대기(WIN_RADIUS)까지 얼마나 컸는지
	var bar := Rect2(16, 62, 220, 16)
	var progress := clampf((player_r - START_RADIUS) / (WIN_RADIUS - START_RADIUS), 0, 1)
	draw_rect(bar.grow(2), Color(0, 0, 0, 0.6))
	draw_rect(bar, Color("343a40"))
	draw_rect(Rect2(bar.position, Vector2(bar.size.x * progress, bar.size.y)), Color("ffd43b"))
	outlined("크기 %d%%" % roundi(progress * 100), bar.position + Vector2(0, 13), HORIZONTAL_ALIGNMENT_CENTER, bar.size.x, 14)

	outlined(fmt_time(elapsed), Vector2(0, 46), HORIZONTAL_ALIGNMENT_CENTER, SCREEN.x, 30)
	outlined("먹은 수 %d" % eaten, Vector2(0, 74), HORIZONTAL_ALIGNMENT_CENTER, SCREEN.x, 18, Color("ffe066"))
	draw_ladder()
	outlined("ESC 일시정지  /  M 메뉴", Vector2(SCREEN.x - 316, SCREEN.y - 16), HORIZONTAL_ALIGNMENT_RIGHT, 300, 14, Color(1, 1, 1, 0.5))

	match state:
		State.READY:
			draw_panel("도마뱀 먹이사슬", "WASD 또는 방향키로 이동\n나보다 작은 동물(초록 고리)은 먹고\n큰 동물(빨간 고리)은 피하세요!\n먹을수록 커져서 먹이사슬 꼭대기에 오르세요\n\n스페이스 또는 클릭으로 시작")
		State.PAUSED:
			draw_panel("일시정지", "ESC, 스페이스 또는 클릭으로 계속")
		State.OVER:
			draw_panel("잡아먹혔다...", "크기 %d%%  /  먹은 수 %d  /  %s\n\n스페이스 또는 클릭으로 다시 시작" % [roundi(progress * 100), eaten, fmt_time(elapsed)])
		State.WON:
			draw_panel("먹이사슬의 왕!", "회색 도마뱀이 매보다 커졌어요!\n먹은 수 %d  /  %s\n\n스페이스 또는 클릭으로 다시 시작" % [eaten, fmt_time(elapsed)])


# 오른쪽 위 먹이사슬 표: 큰 동물이 위, 내 자리도 표시
func draw_ladder() -> void:
	const ROW := 24.0
	var rows: Array[Dictionary] = []
	var placed := false
	for i in range(SPECIES.size() - 1, -1, -1):
		var sp: Dictionary = SPECIES[i]
		var r: float = sp["r"]
		if not placed and r < player_r:
			rows.append({"name": "도마뱀 (나)", "color": Color("ffd43b")})
			placed = true
		var rel := relation(sp)
		var col := Color("8ce99a") if rel == 1 else (Color("ff8787") if rel == -1 else Color.WHITE)
		rows.append({"name": sp["name"], "color": col})
	if not placed:
		rows.append({"name": "도마뱀 (나)", "color": Color("ffd43b")})

	var rect := Rect2(SCREEN.x - 176, 20, 160, 40 + rows.size() * ROW)
	draw_rect(rect, Color(0, 0, 0, 0.45))
	outlined("먹이사슬", rect.position + Vector2(0, 26), HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, 18, Color("ffd43b"))
	for i in rows.size():
		var y := rect.position.y + 52 + i * ROW
		var col: Color = rows[i]["color"]
		draw_circle(Vector2(rect.position.x + 20, y - 5), 5, col)
		outlined(rows[i]["name"], Vector2(rect.position.x + 34, y), HORIZONTAL_ALIGNMENT_LEFT, -1, 16, col)


func draw_panel(title: String, body: String) -> void:
	var rect := Rect2(226, 140, 700, 360)
	draw_rect(Rect2(Vector2.ZERO, SCREEN), Color(0, 0, 0, 0.35))
	draw_rect(Rect2(rect.position + Vector2(0, 8), rect.size), Color(0, 0, 0, 0.5))
	draw_rect(rect, Color("1b1b2a", 0.95))
	draw_rect(rect, Color("ffd43b", 0.6), false, 2)
	outlined(title, rect.position + Vector2(0, 75), HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, 40, Color("ffd43b"))
	draw_multiline_string(ThemeDB.fallback_font, rect.position + Vector2(0, 140), body, HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, 22)
