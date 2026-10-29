extends Node2D

# 바다 먹이사슬 게임: 새우에서 시작해 작은 생물은 먹고 큰 생물은 피하면서
# 점점 진화해서 고래보다 커지기

const SCREEN := Vector2(1152, 648)
const START_RADIUS := 5.0  # 새우 크기. 처음부터 플랑크톤을 먹을 수 있음
const WIN_RADIUS := 98.0
const MAX_HEARTS := 3
const MAX_CREATURES := 60
const MAX_PARTICLES := 400
const GROW_RATE := 0.45  # 먹은 생물 넓이의 이만큼이 내 몸에 더해짐
const SPEED_PER_RADIUS := 13.0  # 크기에 비례해서 빨라짐 (화면에서 보이는 속도는 비슷하게 유지)

# 작은 생물부터 큰 생물 순서. agility는 같은 크기의 나와 비교한 빠르기,
# calm이면 나보다 커도 공격하지 않음
const SPECIES := [
	{"name": "플랑크톤", "shape": "plankton", "r": 3.0, "agility": 0.3, "color": Color("b2f2bb"), "calm": true},
	{"name": "새우", "shape": "shrimp", "r": 5.0, "agility": 0.9, "color": Color("ffa8a8")},
	{"name": "해파리", "shape": "jelly", "r": 7.0, "agility": 0.5, "color": Color("eebefa")},
	{"name": "흰동가리", "shape": "clownfish", "r": 9.0, "agility": 0.9, "color": Color("ff922b")},
	{"name": "게", "shape": "crab", "r": 11.0, "agility": 0.6, "color": Color("e03131")},
	{"name": "불가사리", "shape": "starfish", "r": 13.0, "agility": 0.1, "color": Color("ff8787"), "calm": true},
	{"name": "오징어", "shape": "squid", "r": 16.0, "agility": 0.9, "color": Color("ffd8a8")},
	{"name": "복어", "shape": "puffer", "r": 19.0, "agility": 0.6, "color": Color("e9c46a")},
	{"name": "문어", "shape": "octopus", "r": 24.0, "agility": 0.7, "color": Color("c2255c")},
	{"name": "바다거북", "shape": "turtle", "r": 30.0, "agility": 0.5, "color": Color("74b816"), "calm": true},
	{"name": "가오리", "shape": "ray", "r": 36.0, "agility": 0.6, "color": Color("5f6f94")},
	{"name": "참치", "shape": "tuna", "r": 42.0, "agility": 0.8, "color": Color("4c6ef5")},
	{"name": "돌고래", "shape": "dolphin", "r": 50.0, "agility": 0.7, "color": Color("91a7c2")},
	{"name": "상어", "shape": "shark", "r": 60.0, "agility": 0.65, "color": Color("868e96")},
	{"name": "범고래", "shape": "orca", "r": 72.0, "agility": 0.6, "color": Color("212529")},
	{"name": "고래", "shape": "whale", "r": 88.0, "agility": 0.2, "color": Color("364fc7"), "calm": true},
]

# 내가 진화하는 순서 (SPECIES 번호). 그 생물 크기만큼 자라면 그 모습으로 진화
const EVOLUTION := [1, 3, 6, 8, 10, 11, 12, 13, 14]

enum State { READY, PLAYING, OVER, WON, PAUSED }

var state := State.READY
var anim_t := 0.0
var elapsed := 0.0
var eaten := 0

var player_pos := Vector2.ZERO
var player_r := START_RADIUS
var stage := 0  # EVOLUTION 안에서 지금 내 모습
var hearts := MAX_HEARTS
var facing := Vector2.RIGHT
var moving := false
var invuln := 0.0
var knock := Vector2.ZERO
var bubble_t := 0.0

# 이구아나가 커질수록 화면을 멀리 봄
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
	RenderingServer.set_default_clear_color(Color("1971c2"))
	new_game()
	state = State.READY


func new_game() -> void:
	anim_t = 0.0
	elapsed = 0.0
	eaten = 0
	player_pos = Vector2.ZERO
	player_r = START_RADIUS
	stage = 0
	hearts = MAX_HEARTS
	facing = Vector2.RIGHT
	invuln = 0.0
	knock = Vector2.ZERO
	bubble_t = 0.0
	zoom = target_zoom()
	creatures.clear()
	particles.clear()
	texts.clear()
	shake = 0.0
	hurt_flash = 0.0
	grow_flash = 0.0
	for i in 40:
		spawn_creature(true)
	state = State.PLAYING


func target_zoom() -> float:
	return clampf(18.0 / player_r, 0.15, 5.0)


func form() -> Dictionary:
	return SPECIES[EVOLUTION[stage]]


# 지금 크기로 갈 수 있는 가장 높은 진화 단계
func stage_for_size() -> int:
	var s := 0
	for i in EVOLUTION.size():
		if player_r >= SPECIES[EVOLUTION[i]]["r"]:
			s = i
	return s


# 화면 가운데에서 모서리까지의 월드 거리
func view_radius() -> float:
	return (SCREEN / 2 / zoom).length()


# 1: 먹을 수 있음, 0: 비슷한 크기, -1: 나보다 큼
func relation(sp: Dictionary) -> int:
	var r: float = sp["r"]
	if r < player_r * 0.9:
		return 1
	if r > player_r * 1.1:
		return -1
	return 0


# 나보다 크고 공격적인 생물
func is_hostile(sp: Dictionary) -> bool:
	return relation(sp) == -1 and not sp.get("calm", false)


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

	# 입에서 보글보글 거품
	bubble_t -= delta
	if bubble_t <= 0:
		bubble_t = randf_range(0.6, 1.4)
		for i in 3:
			add_bubble(player_pos + facing * player_r * 1.1 + Vector2(randf_range(-1, 1), randf_range(-1, 1)) * player_r * 0.15, player_r * 0.1)


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
	player_pos += dir * player_r * SPEED_PER_RADIUS * delta + knock * delta
	knock = knock.move_toward(Vector2.ZERO, player_r * 70 * delta)
	invuln = maxf(invuln - delta, 0)


# 내 크기 근처의 생물이 주로 나옴. 먹을 수 있는 생물이 더 자주 나옴
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


# anywhere가 참이면 화면 안에도 놓음 (위험한 생물은 항상 화면 밖에서 나옴)
func spawn_creature(anywhere: bool) -> void:
	var sp := pick_species()
	var vr := view_radius()
	var dist := randf_range(vr + 60, vr + 300)
	if anywhere and not is_hostile(sp):
		dist = randf_range(player_r * 8, vr)
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

		# 작은 생물은 도망가고, 크고 사나운 생물은 쫓아옴 (내가 맞은 직후에는 봐줌)
		var rel := relation(sp)
		var hostile := is_hostile(sp)
		var mood := 0
		if rel == 1 and dist < player_r * 12 and not sp.get("calm", false):
			mood = 1
		elif hostile and dist < r * 6 + player_r * 6 and invuln <= 0:
			mood = -1
		c["mood"] = mood

		var dir: Vector2 = c["dir"]
		var speed: float = sp["agility"] * r * SPEED_PER_RADIUS
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
			"jelly", "squid":
				# 몸을 오므렸다 펴면서 쭉쭉 나아감
				speed *= maxf(0, sin(anim_t * 4 + c["phase"])) * 2.2
			"plankton":
				dir = dir.rotated(sin(anim_t * 2 + c["phase"]) * delta)
		dir = dir.normalized()
		pos += dir * speed * delta
		c["dir"] = dir
		c["pos"] = pos

		var touch := r * 0.8 + player_r * 0.8
		if dist < touch:
			if rel == 1:
				eat(i)
			elif hostile:
				if invuln <= 0:
					hurt_player(pos)
			else:
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
	burst(c["pos"], sp["color"], 10, r * 20, r * 0.25)
	for k in 4:
		add_bubble(c["pos"] + Vector2(randf_range(-r, r), randf_range(-r, r)) * 0.5, 1 + r * 0.12)
	add_text(c["pos"], "냠! %s" % sp["name"], Color("ffe066"))
	creatures.remove_at(i)

	# 새로 먹을 수 있게 된 생물을 알려줌
	for s in SPECIES:
		var sr: float = s["r"]
		if sr >= old_r * 0.9 and sr < player_r * 0.9:
			add_text(player_pos + Vector2(0, -player_r * 3), "이제 %s도 먹을 수 있어!" % s["name"], Color("8ce99a"))

	# 충분히 자라면 다음 모습으로 진화
	var new_stage := stage_for_size()
	if new_stage > stage:
		stage = new_stage
		grow_flash = 0.8
		shake = 6
		burst(player_pos, Color("ffd43b"), 30, player_r * 25, player_r * 0.35)
		for k in 8:
			add_bubble(player_pos + Vector2.RIGHT.rotated(TAU * k / 8) * player_r, player_r * 0.15)
		add_text(player_pos + Vector2(0, -player_r * 1.8), "진화! %s" % form()["name"], Color("ffd43b"))

	if player_r >= WIN_RADIUS:
		burst(player_pos, Color("ffd43b"), 40, 600, 12)
		state = State.WON


func hurt_player(from: Vector2) -> void:
	hearts -= 1
	invuln = 1.5
	hurt_flash = 0.3
	shake = 10
	knock = from.direction_to(player_pos) * player_r * 40
	add_text(player_pos + Vector2(0, -player_r * 2), "아야!", Color("ff6b6b"))
	burst(player_pos, Color("ff6b6b"), 12, player_r * 15, player_r * 0.3)
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
			"life": life, "max_life": life, "color": color, "size": size, "bubble": false,
		})


# 위로 떠오르는 거품
func add_bubble(pos: Vector2, size: float) -> void:
	if particles.size() >= MAX_PARTICLES:
		return
	var life := randf_range(0.8, 1.4)
	particles.append({
		"pos": pos, "vel": Vector2(randf_range(-10, 10), -randf_range(30, 60)) * size,
		"life": life, "max_life": life, "color": Color("e7f5ff"), "size": size, "bubble": true,
	})


func update_effects(delta: float) -> void:
	for i in range(particles.size() - 1, -1, -1):
		var p := particles[i]
		p["pos"] += p["vel"] * delta
		if not p["bubble"]:
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


func poly(points: Array, color: Color) -> void:
	draw_colored_polygon(PackedVector2Array(points), color)


func _draw() -> void:
	# 플레이어가 화면 가운데 오도록 (맞으면 화면이 흔들림)
	cam = player_pos + Vector2(randf_range(-1, 1), randf_range(-1, 1)) * shake / zoom
	use_world()
	draw_seabed()

	# 작은 생물부터 그려서 큰 생물이 위에 오게 함
	var order := creatures.duplicate()
	order.sort_custom(func(a, b): return a["sp"]["r"] < b["sp"]["r"])
	var player_drawn := false
	for c in order:
		if not player_drawn and c["sp"]["r"] > player_r:
			draw_player()
			player_drawn = true
		draw_creature(c)
	if not player_drawn:
		draw_player()

	use_world()
	for p in particles:
		var a: float = p["life"] / p["max_life"]
		if p["bubble"]:
			draw_arc(p["pos"], p["size"] * 2, 0, TAU, 12, Color(p["color"], 0.7 * a), p["size"] * 0.6)
			draw_circle(p["pos"] + Vector2(-0.6, -0.6) * p["size"], p["size"] * 0.5, Color(1, 1, 1, 0.6 * a))
		else:
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


# 바다 밑: 일렁이는 빛, 해초, 산호, 바위, 모래와 조개, 올라오는 거품
func draw_seabed() -> void:
	const STEP := 128.0
	var half := SCREEN / 2 / zoom
	var x0 := floori((cam.x - half.x) / STEP) - 1
	var y0 := floori((cam.y - half.y) / STEP) - 1
	var x1 := x0 + int(half.x * 2 / STEP) + 3
	var y1 := y0 + int(half.y * 2 / STEP) + 3
	var corals := [Color("f783ac"), Color("ff922b"), Color("9775fa"), Color("ffd43b")]

	# 밝고 어두운 물빛 얼룩과 물결 빛
	for cx in range(x0, x1):
		for cy in range(y0, y1):
			var center := Vector2(cx, cy) * STEP + Vector2(64, 64)
			var h := hash(Vector2i(cx, cy))
			if posmod(h >> 4, 3) == 0:
				draw_circle(center, 80 + posmod(h >> 12, 30), Color("228be6", 0.35))
			elif posmod(h >> 4, 4) == 1:
				draw_circle(center, 70 + posmod(h >> 12, 24), Color("1864ab", 0.35))
			var drift := Vector2(sin(anim_t * 0.7 + cx), cos(anim_t * 0.5 + cy)) * 14
			draw_arc(center + drift, 26 + posmod(h, 20), 0.3, 2.6, 12, Color(1, 1, 1, 0.07), 4)

	for cx in range(x0, x1):
		for cy in range(y0, y1):
			var h := hash(Vector2i(cx, cy))
			var spot := Vector2(cx, cy) * STEP + Vector2(posmod(h, 96) + 16, posmod(h >> 8, 96) + 16)
			match posmod(h, 7):
				0:
					# 흔들리는 해초
					for k in 3:
						var pts := PackedVector2Array()
						for j in 6:
							var sway := sin(anim_t * 1.5 + j * 0.6 + k + cx) * j * 1.6
							pts.append(spot + Vector2(k * 7 - 7 + sway, -j * 7))
						draw_polyline(pts, Color("2b8a3e") if k != 1 else Color("40c057"), 4)
				1:
					# 산호: 동그라미 뭉치
					var col: Color = corals[posmod(h >> 16, corals.size())]
					for k in 6:
						var a := TAU * k / 6 + h
						draw_circle(spot + Vector2(cos(a), sin(a)) * (6 + k % 3 * 3), 5 - k % 2, col)
					draw_circle(spot, 6, col.lightened(0.25))
				2:
					oval(spot + Vector2(0, 4), 16, 5, Color(0, 0, 0, 0.2))
					oval(spot, 14, 9, Color("495a6e"))
					oval(spot + Vector2(-3, -3), 7, 4, Color("5f7187"))
				3:
					# 모래와 조개
					oval(spot, 22, 12, Color("e9d8a6", 0.45))
					draw_circle(spot + Vector2(4, 1), 4, Color("fff4e6"))
					for k in 3:
						draw_line(spot + Vector2(4, 4), spot + Vector2(1 + k * 3, -2), Color("e8c39e"), 1)
				4:
					# 바닥에서 올라오는 거품
					for k in 3:
						var t := fmod(anim_t * 0.5 + k * 0.33 + h % 7 * 0.1, 1.0)
						var bp := spot + Vector2(sin(t * 8 + k) * 3, -t * 60)
						draw_arc(bp, 2.5 + k, 0, TAU, 10, Color(1, 1, 1, 0.5 * (1 - t)), 1)


func draw_creature(c: Dictionary) -> void:
	var sp: Dictionary = c["sp"]
	var r: float = sp["r"]
	var pos: Vector2 = c["pos"]
	var dir: Vector2 = c["dir"]
	var col: Color = sp["color"]
	var rel := relation(sp)

	# 바닥에 비치는 그림자
	use_local(pos, dir.angle(), r)
	oval(Vector2(0.3, 0.9).rotated(-dir.angle()), 0.95, 0.5, Color(0, 0, 0.15, 0.2))

	# 먹을 수 있으면 초록 고리, 사나우면 빨간 고리
	if rel == 1 or is_hostile(sp):
		use_local(pos, 0, 1)
		var ring := Color("8ce99a") if rel == 1 else Color("ff6b6b")
		var a := 0.55 + 0.3 * sin(anim_t * 6 + c["phase"])
		draw_arc(Vector2.ZERO, r * 1.45, 0, TAU, 32, Color(ring, a), 2.5 / zoom)

	use_local(pos, dir.angle(), r)
	draw_shape(sp["shape"], c, col)

	# 쫓아오는 생물 머리 위에 느낌표
	if c["mood"] == -1:
		draw_set_transform(Vector2.ZERO)
		var p := world_to_screen(pos + Vector2(0, -r * 1.6)) - Vector2(20, 0)
		outlined("!", p, HORIZONTAL_ALIGNMENT_CENTER, 40, 26, Color("ff6b6b"))


func draw_shape(shape: String, c: Dictionary, col: Color) -> void:
	match shape:
		"plankton": draw_plankton(c, col)
		"shrimp": draw_shrimp(c, col)
		"jelly": draw_jelly(c, col)
		"clownfish": draw_clownfish(c, col)
		"crab": draw_crab(c, col)
		"starfish": draw_starfish(c, col)
		"squid": draw_squid(c, col)
		"puffer": draw_puffer(c, col)
		"octopus": draw_octopus(c, col)
		"turtle": draw_turtle(c, col)
		"ray": draw_ray(c, col)
		"tuna": draw_tuna(c, col)
		"dolphin": draw_dolphin(c, col)
		"shark": draw_shark(c, col)
		"orca": draw_orca(c, col)
		"whale": draw_whale(c, col)


# 아래 생물 그림들은 모두 크기 1, 오른쪽(+X)을 바라보는 좌표로 그림

func wag(c: Dictionary, speed := 8.0, amount := 0.35) -> float:
	return sin(anim_t * speed + c["phase"]) * amount


func eye(p: Vector2, size: float) -> void:
	draw_circle(p, size, Color("212529"))
	draw_circle(p + Vector2(0.3, -0.3) * size, size * 0.35, Color.WHITE)


# 물고기 몸통 + 흔들리는 꼬리지느러미
func fish(c: Dictionary, col: Color, length: float, width: float, tail: float, tail_col: Color, speed := 10.0) -> void:
	var w := wag(c, speed, 0.4)
	var base := Vector2(-length * 0.85, 0)
	var t1 := base + Vector2(-tail, -tail * 0.9).rotated(w)
	var t2 := base + Vector2(-tail, tail * 0.9).rotated(w)
	poly([base + Vector2(0.15, 0), t1, base + Vector2(-tail * 0.6, 0).rotated(w), t2], tail_col)
	oval(Vector2.ZERO, length, width, col)


func draw_plankton(c: Dictionary, col: Color) -> void:
	var glow := 0.6 + 0.3 * sin(anim_t * 3 + c["phase"])
	for k in 3:
		var a := TAU * k / 3 + anim_t * 0.5
		draw_circle(Vector2(cos(a), sin(a)) * 0.45, 0.5, Color(col, 0.25 * glow))
		draw_circle(Vector2(cos(a), sin(a)) * 0.45, 0.25, Color(col, glow))


func draw_shrimp(c: Dictionary, col: Color) -> void:
	var dark := col.darkened(0.3)
	var w := wag(c, 12, 0.15)
	draw_line(Vector2(0.7, 0.1), Vector2(1.8, 0.6 + w), dark, 0.05)
	draw_line(Vector2(0.7, -0.1), Vector2(1.8, -0.6 - w), dark, 0.05)
	for k in 4:
		draw_line(Vector2(0.4 - k * 0.3, 0), Vector2(0.4 - k * 0.3 + w, 0.45), dark, 0.06)
		draw_line(Vector2(0.4 - k * 0.3, 0), Vector2(0.4 - k * 0.3 - w, -0.45), dark, 0.06)
	poly([Vector2(-1.0, 0), Vector2(-1.45, -0.4), Vector2(-1.45, 0.4)], dark)
	for k in 5:
		draw_circle(Vector2(0.5 - k * 0.32, sin(k * 0.6) * 0.06), 0.36 - k * 0.04, col)
	eye(Vector2(0.75, 0.2), 0.08)
	eye(Vector2(0.75, -0.2), 0.08)


func draw_jelly(c: Dictionary, col: Color) -> void:
	var pulse := 0.85 + 0.15 * sin(anim_t * 4 + c["phase"])
	for k in 6:
		var pts := PackedVector2Array()
		var y := (k - 2.5) * 0.25
		for j in 6:
			pts.append(Vector2(-0.5 - j * 0.3, y + sin(anim_t * 5 + c["phase"] + j * 0.9 + k) * 0.1 * j))
		draw_polyline(pts, Color(col, 0.6), 0.06)
	draw_circle(Vector2.ZERO, 0.95 * pulse, Color(col, 0.45))
	draw_circle(Vector2.ZERO, 0.75 * pulse, Color(col.lightened(0.3), 0.4))
	for k in 4:
		var a := TAU * k / 4 + 0.785
		draw_arc(Vector2(cos(a), sin(a)) * 0.3 * pulse, 0.17, 0, TAU, 10, Color(col.darkened(0.2), 0.8), 0.06)


func draw_clownfish(c: Dictionary, col: Color) -> void:
	fish(c, col, 0.9, 0.5, 0.5, col, 14)
	for x in [0.35, -0.3]:
		draw_line(Vector2(x, -0.48), Vector2(x, 0.48), Color.WHITE, 0.2)
	eye(Vector2(0.6, 0.18), 0.1)
	eye(Vector2(0.6, -0.18), 0.1)


func draw_crab(c: Dictionary, col: Color) -> void:
	# 게는 옆으로 걸음: +X로 움직이지만 집게는 -Y 쪽
	var dark := col.darkened(0.3)
	var walk := wag(c, 18, 0.15)
	for s in [-1.0, 1.0]:
		for k in 3:
			var y := -0.2 + k * 0.3
			draw_line(Vector2(s * 0.5, y), Vector2(s * 1.05, y + 0.15 + walk * s * (1 if k % 2 == 0 else -1)), dark, 0.1)
		draw_line(Vector2(s * 0.35, -0.4), Vector2(s * 0.55, -0.8), col, 0.14)
		oval(Vector2(s * 0.6, -0.95), 0.28, 0.2, col, s * 0.4)
		draw_line(Vector2(s * 0.6, -1.05), Vector2(s * 0.75 + walk, -1.2), dark, 0.08)
	oval(Vector2.ZERO, 0.75, 0.55, col)
	for s in [-1.0, 1.0]:
		draw_line(Vector2(s * 0.2, -0.4), Vector2(s * 0.25, -0.65), dark, 0.06)
		eye(Vector2(s * 0.25, -0.68), 0.09)


func draw_starfish(c: Dictionary, col: Color) -> void:
	var spin: float = anim_t * 0.2 + c["phase"]
	var pts: Array[Vector2] = []
	for k in 10:
		var a := spin + TAU * k / 10
		pts.append(Vector2(cos(a), sin(a)) * (1.0 if k % 2 == 0 else 0.4))
	poly(pts, col)
	for k in 5:
		var a := spin + TAU * k / 5
		for j in [0.35, 0.6, 0.82]:
			draw_circle(Vector2(cos(a), sin(a)) * j, 0.06, col.lightened(0.4))
	draw_circle(Vector2.ZERO, 0.12, col.darkened(0.2))


func draw_squid(c: Dictionary, col: Color) -> void:
	var squeeze := 0.85 + 0.15 * sin(anim_t * 4 + c["phase"])
	for k in 8:
		var y := (k - 3.5) * 0.12 * squeeze
		var pts := PackedVector2Array()
		for j in 5:
			pts.append(Vector2(-0.3 - j * 0.28, y * (1 + j * 0.4) + sin(anim_t * 6 + j + k) * 0.05 * j))
		draw_polyline(pts, col.darkened(0.1), 0.08)
	poly([Vector2(0.75, 0), Vector2(1.15, -0.4 * squeeze), Vector2(1.25, 0), Vector2(1.15, 0.4 * squeeze)], col.darkened(0.15))
	oval(Vector2(0.35, 0), 0.8, 0.32 * squeeze, col)
	for k in 4:
		draw_circle(Vector2(0.6 - k * 0.25, sin(k * 2.0) * 0.12), 0.05, Color("e8590c"))
	eye(Vector2(-0.3, 0.25), 0.1)
	eye(Vector2(-0.3, -0.25), 0.1)


func draw_puffer(c: Dictionary, col: Color) -> void:
	# 쫓기면 몸을 빵빵하게 부풀림
	var puffed: bool = c["mood"] == 1
	var size := 1.0 if puffed else 0.75
	var w := wag(c, 12, 0.4)
	poly([Vector2(-size * 0.9, 0), Vector2(-size - 0.4, -0.3).rotated(w), Vector2(-size - 0.4, 0.3).rotated(w)], col.darkened(0.2))
	if puffed:
		for k in 16:
			var a := TAU * k / 16
			draw_line(Vector2(cos(a), sin(a)) * 0.9, Vector2(cos(a), sin(a)) * 1.2, col.darkened(0.3), 0.06)
	oval(Vector2.ZERO, size, size * (1.0 if puffed else 0.8), col)
	oval(Vector2(0.1, 0), size * 0.6, size * 0.45, col.lightened(0.35))
	for k in 5:
		draw_circle(Vector2(-0.4 + k * 0.2, (k % 2 - 0.5) * size), 0.07, col.darkened(0.4))
	eye(Vector2(size * 0.55, 0.3), 0.14)
	eye(Vector2(size * 0.55, -0.3), 0.14)


func draw_octopus(c: Dictionary, col: Color) -> void:
	for k in 8:
		var base_a := PI + (k - 3.5) * 0.32
		var pts := PackedVector2Array()
		for j in 6:
			var curl := sin(anim_t * 4 + c["phase"] + k * 0.8 + j * 0.5) * 0.25 * j / 5.0
			pts.append(Vector2.RIGHT.rotated(base_a + curl) * (0.3 + j * 0.25))
		draw_polyline(pts, col, lerpf(0.22, 0.14, k % 2))
		draw_circle(pts[5], 0.06, col)
	draw_circle(Vector2(0.15, 0), 0.6, col)
	oval(Vector2(0.45, 0), 0.45, 0.4, col.lightened(0.1))
	for k in 3:
		draw_circle(Vector2(0.5 - k * 0.2, -0.15 + k * 0.15), 0.05, col.lightened(0.35))
	eye(Vector2(0.1, 0.3), 0.12)
	eye(Vector2(0.1, -0.3), 0.12)


func draw_turtle(c: Dictionary, col: Color) -> void:
	var paddle := wag(c, 3, 0.6)
	var skin := Color("8ce99a").darkened(0.2)
	for s in [-1.0, 1.0]:
		oval(Vector2(0.4, s * 0.75), 0.55, 0.18, skin, s * (0.5 + paddle))
		oval(Vector2(-0.6, s * 0.5), 0.3, 0.12, skin, s * (-0.4 - paddle * 0.5))
	oval(Vector2(1.0, 0), 0.3, 0.24, skin)
	eye(Vector2(1.1, 0.13), 0.05)
	eye(Vector2(1.1, -0.13), 0.05)
	oval(Vector2.ZERO, 0.85, 0.7, col.darkened(0.3))
	oval(Vector2.ZERO, 0.75, 0.6, col)
	draw_circle(Vector2.ZERO, 0.2, col.darkened(0.25))
	for k in 6:
		var a := TAU * k / 6
		draw_circle(Vector2(cos(a) * 0.45, sin(a) * 0.36), 0.15, col.darkened(0.2))


func draw_ray(c: Dictionary, col: Color) -> void:
	var flap := wag(c, 4, 0.15)
	var tail := PackedVector2Array()
	for k in 6:
		tail.append(Vector2(-0.4 - k * 0.3, sin(anim_t * 3 + c["phase"] + k) * 0.04 * k))
	draw_polyline(tail, col.darkened(0.3), 0.07)
	poly([Vector2(0.8, 0), Vector2(0.1, -1.3 - flap), Vector2(-0.3, -1.1 - flap), Vector2(-0.6, 0),
		Vector2(-0.3, 1.1 + flap), Vector2(0.1, 1.3 + flap)], col)
	oval(Vector2(0.05, 0), 0.5, 0.32, col.lightened(0.15))
	for k in 6:
		draw_circle(Vector2(-0.2 + (k % 3) * 0.3, (k / 3 - 0.5) * 0.9), 0.06, Color(1, 1, 1, 0.5))
	eye(Vector2(0.55, 0.2), 0.06)
	eye(Vector2(0.55, -0.2), 0.06)


func draw_tuna(c: Dictionary, col: Color) -> void:
	var silver := Color("dee2e6")
	fish(c, silver, 1.0, 0.36, 0.55, col, 14)
	oval(Vector2(0, 0), 0.95, 0.16, col)
	for k in 5:
		poly([Vector2(-0.3 - k * 0.12, 0.25), Vector2(-0.36 - k * 0.12, 0.33), Vector2(-0.42 - k * 0.12, 0.24)], Color("ffd43b"))
	eye(Vector2(0.7, 0.15), 0.07)
	eye(Vector2(0.7, -0.15), 0.07)


func draw_dolphin(c: Dictionary, col: Color) -> void:
	var w := wag(c, 6, 0.3)
	for s in [-1.0, 1.0]:
		oval(Vector2(0.25, s * 0.38), 0.3, 0.1, col.darkened(0.15), s * 0.7)
	poly([Vector2(-0.95, 0), Vector2(-1.3, -0.45).rotated(w), Vector2(-1.15, 0).rotated(w), Vector2(-1.3, 0.45).rotated(w)], col.darkened(0.15))
	oval(Vector2(0, 0), 1.0, 0.3, col)
	oval(Vector2(1.05, 0), 0.25, 0.09, col)
	oval(Vector2(-0.1, 0), 0.6, 0.06, col.darkened(0.25))
	eye(Vector2(0.75, 0.15), 0.05)
	eye(Vector2(0.75, -0.15), 0.05)


func draw_shark(c: Dictionary, col: Color) -> void:
	var w := wag(c, 7, 0.35)
	var dark := col.darkened(0.25)
	for s in [-1.0, 1.0]:
		poly([Vector2(0.35, s * 0.2), Vector2(-0.15, s * 0.85), Vector2(-0.05, s * 0.2)], dark)
	poly([Vector2(-0.9, 0), Vector2(-1.35, -0.5).rotated(w), Vector2(-1.15, 0).rotated(w), Vector2(-1.3, 0.35).rotated(w)], dark)
	poly([Vector2(1.25, 0), Vector2(0.6, -0.27), Vector2(-0.95, -0.08), Vector2(-0.95, 0.08), Vector2(0.6, 0.27)], col)
	poly([Vector2(0.15, 0), Vector2(-0.3, -0.05), Vector2(-0.3, 0.05)], dark)
	draw_line(Vector2(0.05, 0), Vector2(-0.35, 0), dark, 0.07)
	for s in [-1.0, 1.0]:
		for k in 3:
			draw_line(Vector2(0.45 - k * 0.07, s * 0.15), Vector2(0.4 - k * 0.07, s * 0.24), dark, 0.025)
		eye(Vector2(0.8, s * 0.13), 0.045)


func draw_orca(c: Dictionary, col: Color) -> void:
	var w := wag(c, 5, 0.3)
	var white := Color("f8f9fa")
	for s in [-1.0, 1.0]:
		oval(Vector2(0.3, s * 0.45), 0.35, 0.13, col, s * 0.6)
	poly([Vector2(-0.9, 0), Vector2(-1.3, -0.5).rotated(w), Vector2(-1.15, 0).rotated(w), Vector2(-1.3, 0.5).rotated(w)], col)
	oval(Vector2.ZERO, 1.0, 0.38, col)
	oval(Vector2(-0.45, 0), 0.25, 0.2, Color("adb5bd"))
	for s in [-1.0, 1.0]:
		oval(Vector2(0.55, s * 0.22), 0.16, 0.07, white, s * 0.3)
		oval(Vector2(-0.15, s * 0.3), 0.3, 0.06, white)
	poly([Vector2(0.1, 0), Vector2(-0.4, -0.06), Vector2(-0.4, 0.06)], Color("495057"))


func draw_whale(c: Dictionary, col: Color) -> void:
	var w := wag(c, 2.5, 0.25)
	for s in [-1.0, 1.0]:
		oval(Vector2(0.2, s * 0.5), 0.45, 0.12, col.darkened(0.15), s * 0.5)
	poly([Vector2(-0.95, 0), Vector2(-1.3, -0.55).rotated(w), Vector2(-1.15, 0).rotated(w), Vector2(-1.3, 0.55).rotated(w)], col.darkened(0.15))
	oval(Vector2.ZERO, 1.05, 0.4, col)
	oval(Vector2(0.15, 0), 0.8, 0.15, col.lightened(0.15))
	for k in 6:
		draw_circle(Vector2(-0.5 + k * 0.18, (k % 2 - 0.5) * 0.4), 0.04, Color(1, 1, 1, 0.5))
	eye(Vector2(0.75, 0.3), 0.04)
	eye(Vector2(0.75, -0.3), 0.04)
	# 숨구멍에서 물 뿜기
	var t := fmod(anim_t * 0.4 + c["phase"], 1.0)
	if t < 0.3:
		for k in 5:
			var a := (k - 2) * 0.35
			draw_circle(Vector2(0.45, 0) + Vector2.LEFT.rotated(a) * t * 1.5, 0.08 + t * 0.2, Color(1, 1, 1, 0.6 * (1 - t / 0.3)))


# 나: 지금 진화한 생물 모습 + 노란 빛과 고리로 표시
func draw_player() -> void:
	var sp := form()
	use_local(player_pos, 0, player_r)
	draw_circle(Vector2.ZERO, 1.7, Color(1, 0.9, 0.4, 0.12 + 0.05 * sin(anim_t * 4)))

	# 진화하거나 커질 때 반짝
	if grow_flash > 0:
		var t := 1.0 - grow_flash / 0.8
		draw_arc(Vector2.ZERO, 1.4 + t * 2.0, 0, TAU, 32, Color(1, 0.9, 0.4, 1.0 - t), 0.15)

	# 맞은 직후에는 깜빡임
	if invuln > 0 and int(anim_t * 20) % 2 == 0:
		return

	use_local(player_pos, facing.angle(), player_r)
	oval(Vector2(0.3, 0.9).rotated(-facing.angle()), 0.95, 0.5, Color(0, 0, 0.15, 0.2))
	draw_shape(sp["shape"], {"phase": 0.0, "mood": 0}, sp["color"])

	use_local(player_pos, 0, player_r)
	draw_arc(Vector2.ZERO, 1.5, 0, TAU, 32, Color("ffd43b", 0.8), 2.5 / zoom / player_r)


# 화면 가장자리를 짙은 바닷빛으로
func draw_vignette() -> void:
	const W := 160.0
	var dark := Color(0, 0.05, 0.2, 0.5)
	var clear := Color(0, 0.05, 0.2, 0)
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

	# 지금 모습과 다음 진화
	outlined("지금: %s" % form()["name"], Vector2(16, 104), HORIZONTAL_ALIGNMENT_LEFT, -1, 20, Color("ffd43b"))
	var next_text := "다음: 고래를 먹으면 승리!"
	if stage + 1 < EVOLUTION.size():
		var nxt: Dictionary = SPECIES[EVOLUTION[stage + 1]]
		var need: float = nxt["r"]
		var part := clampf((player_r - form()["r"]) / (need - form()["r"]), 0, 1)
		next_text = "다음 진화: %s (%d%%)" % [nxt["name"], roundi(part * 100)]
	outlined(next_text, Vector2(16, 128), HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(1, 1, 1, 0.85))
	for i in EVOLUTION.size():
		var dot := Vector2(22 + i * 22, 146)
		var col: Color = SPECIES[EVOLUTION[i]]["color"] if i <= stage else Color(0, 0, 0, 0.45)
		draw_circle(dot, 7 if i == stage else 5, col)
		if i == stage:
			draw_arc(dot, 9, 0, TAU, 16, Color("ffd43b"), 2)

	outlined(fmt_time(elapsed), Vector2(0, 46), HORIZONTAL_ALIGNMENT_CENTER, SCREEN.x, 30)
	outlined("먹은 수 %d" % eaten, Vector2(0, 74), HORIZONTAL_ALIGNMENT_CENTER, SCREEN.x, 18, Color("ffe066"))
	draw_ladder()
	outlined("ESC 일시정지  /  M 메뉴", Vector2(SCREEN.x - 316, SCREEN.y - 16), HORIZONTAL_ALIGNMENT_RIGHT, 300, 14, Color(1, 1, 1, 0.5))

	match state:
		State.READY:
			draw_panel("바다 먹이사슬", "작은 새우에서 시작해요! WASD 또는 방향키로 헤엄치기\n나보다 작은 생물(초록 고리)은 먹고\n사나운 큰 생물(빨간 고리)은 피하세요!\n먹고 자랄수록 물고기, 오징어, 상어, 범고래로 진화해요\n고래를 먹으면 바다의 왕!\n\n스페이스 또는 클릭으로 시작")
		State.PAUSED:
			draw_panel("일시정지", "ESC, 스페이스 또는 클릭으로 계속")
		State.OVER:
			draw_panel("잡아먹혔다...", "크기 %d%%  /  먹은 수 %d  /  %s\n\n스페이스 또는 클릭으로 다시 시작" % [roundi(progress * 100), eaten, fmt_time(elapsed)])
		State.WON:
			draw_panel("바다의 왕!", "작은 새우가 고래보다 커졌어요!\n먹은 수 %d  /  %s\n\n스페이스 또는 클릭으로 다시 시작" % [eaten, fmt_time(elapsed)])


# 오른쪽 위 먹이사슬 표: 큰 생물이 위, 내 자리도 표시
func draw_ladder() -> void:
	const ROW := 19.0
	var rows: Array[Dictionary] = []
	var placed := false
	for i in range(SPECIES.size() - 1, -1, -1):
		var sp: Dictionary = SPECIES[i]
		var r: float = sp["r"]
		if not placed and r < player_r:
			rows.append({"name": "나 (%s)" % form()["name"], "color": Color("ffd43b")})
			placed = true
		var col := Color.WHITE
		if relation(sp) == 1:
			col = Color("8ce99a")
		elif is_hostile(sp):
			col = Color("ff8787")
		elif relation(sp) == -1:
			col = Color("74c0fc")
		rows.append({"name": sp["name"], "color": col})
	if not placed:
		rows.append({"name": "나 (%s)" % form()["name"], "color": Color("ffd43b")})

	var rect := Rect2(SCREEN.x - 186, 16, 170, 36 + rows.size() * ROW)
	draw_rect(rect, Color(0, 0, 0, 0.45))
	outlined("먹이사슬", rect.position + Vector2(0, 24), HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, 17, Color("ffd43b"))
	for i in rows.size():
		var y := rect.position.y + 48 + i * ROW
		var col: Color = rows[i]["color"]
		draw_circle(Vector2(rect.position.x + 18, y - 5), 4.5, col)
		outlined(rows[i]["name"], Vector2(rect.position.x + 30, y), HORIZONTAL_ALIGNMENT_LEFT, -1, 14, col)


func draw_panel(title: String, body: String) -> void:
	var rect := Rect2(226, 130, 700, 380)
	draw_rect(Rect2(Vector2.ZERO, SCREEN), Color(0, 0, 0, 0.35))
	draw_rect(Rect2(rect.position + Vector2(0, 8), rect.size), Color(0, 0, 0, 0.5))
	draw_rect(rect, Color("0b2545", 0.95))
	draw_rect(rect, Color("74c0fc", 0.7), false, 2)
	outlined(title, rect.position + Vector2(0, 75), HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, 40, Color("74c0fc"))
	draw_multiline_string(ThemeDB.fallback_font, rect.position + Vector2(0, 135), body, HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, 22)
