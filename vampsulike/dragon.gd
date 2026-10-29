extends Node2D

# 드래곤 판타지: 용이 되어 불덩이와 화염 숨결로 기사단을 물리치고 마지막 용사를 쓰러뜨리기

const SCREEN := Vector2(1152, 648)
const SHEET_PATH := "res://assets/dragon.png"
const FIRE_SFX_PATH := "res://assets/sfx/fire_breath.mp3"
const FIREBALL_SFX_LENGTH := 0.45  # 불덩이는 소리 앞부분만 짧게
const MUSIC_PATH := "res://assets/music/dragon_theme.mp3"
const MUSIC_VOLUME := -10.0  # 공격 소리가 묻히지 않게 배경음악은 작게
const CELL := 256.0  # 스프라이트 시트 한 칸 크기 (윗줄 idle, 아랫줄 walk)
const DRAW_SCALE := 0.5  # 화면에 그릴 때 배율
const BODY_Y := 158.0  # 칸 안에서 몸 중심 높이 (발바닥은 232)
const FOOT_Y := 232.0

const PLAYER_RADIUS := 26.0
const PLAYER_MAX_HP := 100.0
const PLAYER_SPEED := 210.0
const FIRE_MAX := 100.0
const BREATH_COST := 35.0  # 초당 화염 게이지 소모
const FIRE_REGEN := 22.0
const FIREBALL_COOLDOWN := 0.4
const FIREBALL_DAMAGE := 25.0
const FIREBALL_RADIUS := 60.0
const BREATH_DPS := 70.0
const MAGNET_RADIUS := 90.0
const LAST_WAVE := 5

const ENEMY_TYPES := {
	"knight": {"name": "기사", "hp": 40.0, "speed": 85.0, "radius": 14.0, "damage": 10.0, "gold": 1},
	"archer": {"name": "궁수", "hp": 25.0, "speed": 70.0, "radius": 13.0, "damage": 8.0, "gold": 2, "range": 230.0, "cooldown": 2.0},
	"wizard": {"name": "마법사", "hp": 35.0, "speed": 55.0, "radius": 14.0, "damage": 14.0, "gold": 3, "range": 270.0, "cooldown": 3.0},
	"hero": {"name": "용사", "hp": 900.0, "speed": 95.0, "radius": 24.0, "damage": 20.0, "gold": 30, "cooldown": 4.0},
}

enum State { READY, PLAYING, OVER, WON, PAUSED }

var state := State.READY
var anim_t := 0.0
var elapsed := 0.0
var sheet: Texture2D

# 공격 소리: 화염 숨결용 하나, 불덩이는 겹쳐 들리게 여러 개를 돌려 씀
var breath_sfx: AudioStreamPlayer
var shot_sfx: Array[AudioStreamPlayer] = []
var next_shot_sfx := 0
var music: AudioStreamPlayer

var player_pos := Vector2.ZERO
var player_hp := PLAYER_MAX_HP
var fire := FIRE_MAX
var facing := Vector2.DOWN
var aim := Vector2.DOWN
var moving := false
var breathing := false
var invuln := 0.0
var fireball_timer := 0.0
var gold := 0
var kills := 0

var wave := 0
var spawn_queue: Array[String] = []
var spawn_timer := 0.0
var wave_break := 0.0  # 다음 웨이브까지 남은 시간
var banner := ""
var banner_t := 0.0

var cam := Vector2.ZERO
var enemies: Array[Dictionary] = []  # { type, kind, pos, hp, max_hp, timer, flash, dash, dash_dir }
var fireballs: Array[Dictionary] = []  # { pos, vel, life }
var flames: Array[Dictionary] = []  # 화염 숨결 불꽃 { pos, vel, life, max_life, size }
var shots: Array[Dictionary] = []  # 적 화살/마법구 { kind, pos, vel, life, damage }
var coins: Array[Dictionary] = []  # { pos, value }
var particles: Array[Dictionary] = []  # { pos, vel, life, max_life, color, size }
var texts: Array[Dictionary] = []  # { pos, text, life, color }

# 연출용
var shake := 0.0
var hurt_flash := 0.0


func _ready() -> void:
	RenderingServer.set_default_clear_color(Color("4f7d3a"))
	sheet = load_sheet()
	setup_sounds()
	new_game()
	state = State.READY


# 에디터가 가져오기(import)한 텍스처를 쓰고, 아직 없으면 PNG를 직접 읽음
func load_sheet() -> Texture2D:
	if ResourceLoader.exists(SHEET_PATH):
		return load(SHEET_PATH)
	var img := Image.load_from_file(ProjectSettings.globalize_path(SHEET_PATH))
	return ImageTexture.create_from_image(img)


# 텍스처와 같은 방식: 가져오기된 소리가 없으면 MP3를 직접 읽음
func load_sound(path: String) -> AudioStream:
	if ResourceLoader.exists(path):
		return load(path)
	return AudioStreamMP3.load_from_file(ProjectSettings.globalize_path(path))


func setup_sounds() -> void:
	var stream := load_sound(FIRE_SFX_PATH)
	breath_sfx = AudioStreamPlayer.new()
	breath_sfx.stream = stream
	add_child(breath_sfx)
	for i in 4:
		var p := AudioStreamPlayer.new()
		p.stream = stream
		p.volume_db = -4
		add_child(p)
		shot_sfx.append(p)

	# 배경음악: 끝나면 처음부터 반복, 다시 시작해도 끊기지 않고 이어짐
	var theme := load_sound(MUSIC_PATH)
	if theme is AudioStreamMP3:
		theme.loop = true
	music = AudioStreamPlayer.new()
	music.stream = theme
	music.volume_db = MUSIC_VOLUME
	add_child(music)
	music.play()


func play_fireball_sfx() -> void:
	var p := shot_sfx[next_shot_sfx]
	next_shot_sfx = (next_shot_sfx + 1) % shot_sfx.size()
	p.pitch_scale = randf_range(1.15, 1.4)
	p.volume_db = -4
	p.play()
	var tw := create_tween()
	tw.tween_property(p, "volume_db", -40.0, FIREBALL_SFX_LENGTH)
	tw.tween_callback(p.stop)


# 숨결을 뿜는 동안 계속 재생하고, 멈추면 빠르게 줄여서 끔
func update_breath_sfx(on: bool) -> void:
	if on:
		breath_sfx.volume_db = 0
		if not breath_sfx.playing:
			breath_sfx.play()
	elif breath_sfx.playing and breath_sfx.volume_db > -39:
		breath_sfx.volume_db = move_toward(breath_sfx.volume_db, -40, 160 * get_process_delta_time())
		if breath_sfx.volume_db <= -39:
			breath_sfx.stop()


func new_game() -> void:
	anim_t = 0.0
	elapsed = 0.0
	player_pos = Vector2.ZERO
	player_hp = PLAYER_MAX_HP
	fire = FIRE_MAX
	facing = Vector2.DOWN
	aim = Vector2.DOWN
	invuln = 0.0
	fireball_timer = 0.0
	gold = 0
	kills = 0
	wave = 0
	spawn_queue.clear()
	enemies.clear()
	fireballs.clear()
	flames.clear()
	shots.clear()
	coins.clear()
	particles.clear()
	texts.clear()
	shake = 0.0
	hurt_flash = 0.0
	banner_t = 0.0
	wave_break = 1.5
	state = State.PLAYING


func world_mouse() -> Vector2:
	return get_global_mouse_position() + cam


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
	update_breath_sfx(state == State.PLAYING and breathing)
	# 일시정지 중에는 배경음악을 더 작게
	var music_target := MUSIC_VOLUME - (12.0 if state == State.PAUSED else 0.0)
	music.volume_db = move_toward(music.volume_db, music_target, 30 * delta)
	queue_redraw()


func update_game(delta: float) -> void:
	elapsed += delta
	shake = move_toward(shake, 0, 40 * delta)
	hurt_flash = maxf(hurt_flash - delta, 0)
	banner_t = maxf(banner_t - delta, 0)
	move_player(delta)
	update_attacks(delta)
	update_waves(delta)
	update_enemies(delta)
	update_projectiles(delta)
	update_pickups(delta)
	update_effects(delta)


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
	player_pos += dir * PLAYER_SPEED * delta
	invuln = maxf(invuln - delta, 0)


# 입 위치: 몸 중심에서 바라보는 쪽으로, 머리 높이만큼 위
func mouth_pos() -> Vector2:
	return player_pos + aim * 22 + Vector2(0, -30)


func update_attacks(delta: float) -> void:
	var to_mouse := world_mouse() - player_pos
	if to_mouse.length() > 4:
		aim = to_mouse.normalized()
	fireball_timer = maxf(fireball_timer - delta, 0)

	# 왼쪽 클릭: 마우스 쪽으로 불덩이
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) and fireball_timer <= 0:
		fireball_timer = FIREBALL_COOLDOWN
		fireballs.append({"pos": mouth_pos(), "vel": aim * 520, "life": 1.4})
		play_fireball_sfx()

	# 스페이스 또는 오른쪽 클릭: 화염 숨결 (게이지 소모)
	var want_breath := Input.is_physical_key_pressed(KEY_SPACE) or Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)
	breathing = want_breath and fire > 0
	if breathing:
		fire = maxf(fire - BREATH_COST * delta, 0)
		for i in 3:
			var life := randf_range(0.35, 0.55)
			flames.append({
				"pos": mouth_pos(), "vel": aim.rotated(randf_range(-0.28, 0.28)) * randf_range(260, 360),
				"life": life, "max_life": life, "size": randf_range(6, 10),
			})
	else:
		fire = minf(fire + FIRE_REGEN * delta, FIRE_MAX)


func update_waves(delta: float) -> void:
	if spawn_queue.is_empty() and enemies.is_empty():
		if wave >= LAST_WAVE:
			state = State.WON
			return
		wave_break -= delta
		if wave_break <= 0:
			start_wave(wave + 1)
		return
	spawn_timer -= delta
	if spawn_timer <= 0 and not spawn_queue.is_empty():
		spawn_timer = maxf(0.25, 0.9 - wave * 0.1)
		spawn_enemy(spawn_queue.pop_front())


func start_wave(n: int) -> void:
	wave = n
	wave_break = 3.0
	for i in 4 + n * 2:
		spawn_queue.append("knight")
	for i in n:
		spawn_queue.append("archer")
	for i in maxi(0, n - 2) * 2:
		spawn_queue.append("wizard")
	spawn_queue.shuffle()
	if n == LAST_WAVE:
		spawn_queue.push_front("hero")
		banner = "마지막 웨이브! 용사가 나타났다!"
	else:
		banner = "웨이브 %d" % n
	banner_t = 2.5


func spawn_enemy(kind: String) -> void:
	var t: Dictionary = ENEMY_TYPES[kind]
	var pos := player_pos + Vector2.RIGHT.rotated(randf() * TAU) * (SCREEN.length() / 2 + 40)
	enemies.append({
		"type": t, "kind": kind, "pos": pos, "hp": t["hp"], "max_hp": t["hp"],
		"timer": randf_range(0.5, t.get("cooldown", 1.0)), "flash": 0.0,
		"dash": 0.0, "dash_dir": Vector2.ZERO, "phase": randf() * TAU,
	})


func update_enemies(delta: float) -> void:
	for e in enemies:
		var t: Dictionary = e["type"]
		var pos: Vector2 = e["pos"]
		var to_player := player_pos - pos
		var dist := to_player.length()
		var dir := to_player / maxf(dist, 0.001)
		var speed: float = t["speed"]
		e["flash"] = maxf(e["flash"] - delta, 0)
		e["timer"] -= delta

		match e["kind"]:
			"knight":
				pos += dir * speed * delta
			"archer", "wizard":
				# 일정 거리를 두고 원거리 공격
				var keep: float = t["range"]
				if dist > keep + 30:
					pos += dir * speed * delta
				elif dist < keep - 60:
					pos -= dir * speed * delta
				if e["timer"] <= 0 and dist < keep + 120:
					e["timer"] = t["cooldown"]
					if e["kind"] == "archer":
						shots.append({"kind": "arrow", "pos": pos, "vel": dir * 320, "life": 2.0, "damage": t["damage"]})
					else:
						shots.append({"kind": "orb", "pos": pos, "vel": dir * 150, "life": 4.0, "damage": t["damage"]})
			"hero":
				# 용사: 다가오다가 가끔 빠르게 돌진
				if e["dash"] > 0:
					e["dash"] -= delta
					pos += e["dash_dir"] * 400 * delta
				else:
					pos += dir * speed * delta
					if e["timer"] <= 0 and dist < 420:
						e["timer"] = t["cooldown"]
						e["dash"] = 0.6
						e["dash_dir"] = dir
						add_text(pos + Vector2(0, -40), "돌진!", Color("ffd43b"))
		e["pos"] = pos

		var r: float = t["radius"]
		if invuln <= 0 and dist < r + PLAYER_RADIUS:
			hurt_player(t["damage"], pos)

	# 적끼리 겹치지 않게 밀어냄
	for i in enemies.size():
		for j in range(i + 1, enemies.size()):
			var a := enemies[i]
			var b := enemies[j]
			var d: Vector2 = b["pos"] - a["pos"]
			var min_d: float = a["type"]["radius"] + b["type"]["radius"]
			var gap := d.length()
			if gap < min_d and gap > 0.01:
				var push := d / gap * (min_d - gap) * 0.5
				a["pos"] -= push
				b["pos"] += push


func hurt_enemy(e: Dictionary, amount: float) -> void:
	e["hp"] -= amount
	e["flash"] = 0.1


func hurt_player(amount: float, from: Vector2) -> void:
	player_hp -= amount
	invuln = 0.8
	hurt_flash = 0.3
	shake = 8
	player_pos += from.direction_to(player_pos) * 30
	add_text(player_pos + Vector2(0, -70), "-%d" % amount, Color("ff6b6b"))
	if player_hp <= 0:
		player_hp = 0
		state = State.OVER


func update_projectiles(delta: float) -> void:
	# 불덩이: 적에 닿으면 폭발해서 주변까지 피해
	for i in range(fireballs.size() - 1, -1, -1):
		var f := fireballs[i]
		f["pos"] += f["vel"] * delta
		f["life"] -= delta
		var hit: bool = f["life"] <= 0
		for e in enemies:
			if f["pos"].distance_to(e["pos"]) < e["type"]["radius"] + 8:
				hit = true
				break
		if hit:
			explode(f["pos"])
			fireballs.remove_at(i)

	# 화염 숨결: 불꽃에 닿은 적은 초당 피해
	for i in range(flames.size() - 1, -1, -1):
		var fl := flames[i]
		fl["pos"] += fl["vel"] * delta
		fl["vel"] *= exp(-2.5 * delta)
		fl["life"] -= delta
		if fl["life"] <= 0:
			flames.remove_at(i)
	for e in enemies:
		var r: float = e["type"]["radius"]
		for fl in flames:
			if fl["pos"].distance_to(e["pos"]) < r + fl["size"]:
				hurt_enemy(e, BREATH_DPS * delta)
				break

	# 적 화살/마법구
	for i in range(shots.size() - 1, -1, -1):
		var s := shots[i]
		if s["kind"] == "orb":
			# 마법구는 천천히 용을 따라옴
			var want: Vector2 = s["pos"].direction_to(player_pos) * 150
			s["vel"] = s["vel"].lerp(want, 1.0 - exp(-1.5 * delta))
		s["pos"] += s["vel"] * delta
		s["life"] -= delta
		if s["life"] <= 0:
			shots.remove_at(i)
		elif invuln <= 0 and s["pos"].distance_to(player_pos) < PLAYER_RADIUS:
			hurt_player(s["damage"], s["pos"])
			shots.remove_at(i)

	remove_dead()


func explode(pos: Vector2) -> void:
	for e in enemies:
		var d: float = pos.distance_to(e["pos"])
		if d < FIREBALL_RADIUS + e["type"]["radius"]:
			hurt_enemy(e, FIREBALL_DAMAGE * (1.0 if d < 30 else 0.6))
	burst(pos, Color("ff922b"), 14, 220, 5)
	burst(pos, Color("ffe066"), 8, 140, 4)
	shake = maxf(shake, 3)


func remove_dead() -> void:
	for i in range(enemies.size() - 1, -1, -1):
		var e := enemies[i]
		if e["hp"] > 0:
			continue
		var pos: Vector2 = e["pos"]
		var value: int = e["type"]["gold"]
		kills += 1
		burst(pos, Color("adb5bd"), 10, 160, 4)
		for k in mini(value, 8):
			coins.append({"pos": pos + Vector2(randf_range(-14, 14), randf_range(-14, 14)), "value": maxi(1, value / mini(value, 8))})
		if e["kind"] == "hero":
			banner = "용사를 쓰러뜨렸다!"
			banner_t = 3.0
			burst(pos, Color("ffd43b"), 40, 400, 7)
		enemies.remove_at(i)


func update_pickups(delta: float) -> void:
	for i in range(coins.size() - 1, -1, -1):
		var c := coins[i]
		var pos: Vector2 = c["pos"]
		var d := pos.distance_to(player_pos)
		if d < PLAYER_RADIUS:
			gold += c["value"]
			coins.remove_at(i)
		elif d < MAGNET_RADIUS:
			c["pos"] = pos.move_toward(player_pos, 380 * delta)


func add_text(pos: Vector2, text: String, color: Color) -> void:
	texts.append({"pos": pos, "text": text, "life": 1.0, "color": color})


func burst(pos: Vector2, color: Color, count: int, speed: float, size: float) -> void:
	for i in count:
		if particles.size() >= 300:
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
		t["pos"] += Vector2(0, -40) * delta
		t["life"] -= delta
		if t["life"] <= 0:
			texts.remove_at(i)


func fmt_time(t: float) -> String:
	return "%d:%02d" % [int(t) / 60, int(t) % 60]


# ---------- 그리기 ----------

func _draw() -> void:
	cam = player_pos - SCREEN / 2 + Vector2(randf_range(-1, 1), randf_range(-1, 1)) * shake
	draw_set_transform(-cam)
	draw_ground()

	for c in coins:
		var p: Vector2 = c["pos"] + Vector2(0, sin(anim_t * 5 + c["pos"].x) * 2)
		draw_circle(p, 9, Color(1, 0.85, 0.2, 0.2))
		draw_circle(p, 6, Color("fab005"))
		draw_circle(p, 4, Color("ffd43b"))
		draw_line(p + Vector2(-1, -3), p + Vector2(-1, 3), Color("e67700"), 1.5)

	# 위에 있는 것부터 그려서 아래에 있는 것이 앞에 보이게 함
	var order := enemies.duplicate()
	order.sort_custom(func(a, b): return a["pos"].y < b["pos"].y)
	var player_drawn := false
	for e in order:
		if not player_drawn and e["pos"].y > player_pos.y:
			draw_dragon()
			player_drawn = true
		draw_enemy(e)
	if not player_drawn:
		draw_dragon()

	for s in shots:
		var p: Vector2 = s["pos"]
		if s["kind"] == "arrow":
			var d: Vector2 = s["vel"].normalized()
			draw_line(p - d * 14, p, Color("8b5a2b"), 2)
			draw_colored_polygon(PackedVector2Array([p + d * 5, p - d.orthogonal() * 3, p + d.orthogonal() * 3]), Color("ced4da"))
			draw_line(p - d * 14, p - d * 10 + d.orthogonal() * 3, Color.WHITE, 1.5)
		else:
			draw_circle(p, 12, Color(0.7, 0.4, 1, 0.25))
			draw_circle(p, 7, Color("b197fc"))
			draw_circle(p + Vector2(-2, -2), 3, Color("f3f0ff"))

	for fl in flames:
		var a: float = fl["life"] / fl["max_life"]
		var col := Color("fff3bf").lerp(Color("ff6b00"), 1.0 - a)
		draw_circle(fl["pos"], fl["size"] * (1.4 - a * 0.6), Color(col, a * 0.85))

	for f in fireballs:
		var p: Vector2 = f["pos"]
		var tail: Vector2 = f["vel"].normalized() * 16
		draw_line(p - tail, p, Color(1, 0.5, 0.1, 0.4), 8)
		draw_circle(p, 11, Color(1, 0.5, 0.1, 0.35))
		draw_circle(p, 7, Color("ff922b"))
		draw_circle(p, 4, Color("fff3bf"))

	for p in particles:
		var a: float = p["life"] / p["max_life"]
		draw_circle(p["pos"], p["size"] * a, Color(p["color"], a))

	var font := ThemeDB.fallback_font
	for t in texts:
		var a: float = clampf(t["life"] / 0.3, 0, 1)
		var p: Vector2 = t["pos"] - Vector2(60, 0)
		draw_string_outline(font, p, t["text"], HORIZONTAL_ALIGNMENT_CENTER, 120, 18, 4, Color(0, 0, 0, a))
		draw_string(font, p, t["text"], HORIZONTAL_ALIGNMENT_CENTER, 120, 18, Color(t["color"], a))

	# 조준선
	if state == State.PLAYING:
		var m := world_mouse()
		draw_arc(m, 10, 0, TAU, 20, Color(1, 0.9, 0.6, 0.7), 2)
		draw_line(m + Vector2(-14, 0), m + Vector2(-6, 0), Color(1, 0.9, 0.6, 0.7), 2)
		draw_line(m + Vector2(6, 0), m + Vector2(14, 0), Color(1, 0.9, 0.6, 0.7), 2)

	draw_set_transform(Vector2.ZERO)
	draw_vignette()
	if hurt_flash > 0:
		draw_rect(Rect2(Vector2.ZERO, SCREEN), Color(1, 0, 0, 0.25 * hurt_flash / 0.3))
	draw_hud()


# 판타지 들판: 풀 얼룩, 나무, 돌, 무너진 성벽 기둥, 꽃
func draw_ground() -> void:
	const STEP := 96.0
	var x0 := floori(cam.x / STEP) - 1
	var y0 := floori(cam.y / STEP) - 1
	var x1 := x0 + int(SCREEN.x / STEP) + 3
	var y1 := y0 + int(SCREEN.y / STEP) + 3

	for cx in range(x0, x1):
		for cy in range(y0, y1):
			var h := hash(Vector2i(cx, cy))
			var center := Vector2(cx, cy) * STEP + Vector2(48, 48)
			if posmod(h >> 4, 3) == 0:
				draw_circle(center, 60 + posmod(h >> 12, 20), Color("5a8a43", 0.4))
			elif posmod(h >> 4, 4) == 1:
				draw_circle(center, 50 + posmod(h >> 12, 16), Color("446b30", 0.4))

	for cx in range(x0, x1):
		for cy in range(y0, y1):
			var h := hash(Vector2i(cx, cy))
			var spot := Vector2(cx, cy) * STEP + Vector2(posmod(h, 72) + 12, posmod(h >> 8, 72) + 12)
			match posmod(h, 11):
				0:
					# 나무
					draw_circle(spot + Vector2(4, 22), 20, Color(0, 0, 0, 0.2))
					draw_rect(Rect2(spot + Vector2(-4, 4), Vector2(8, 18)), Color("6b4423"))
					draw_circle(spot + Vector2(0, -6), 20, Color("2b5e22"))
					draw_circle(spot + Vector2(-8, -12), 12, Color("3a7a2d"))
					draw_circle(spot + Vector2(7, -14), 10, Color("4a9139"))
				1:
					# 무너진 성벽 기둥
					draw_rect(Rect2(spot + Vector2(-12, 10), Vector2(30, 8)), Color(0, 0, 0, 0.2))
					draw_rect(Rect2(spot + Vector2(-12, -22), Vector2(24, 34)), Color("868e96"))
					draw_rect(Rect2(spot + Vector2(-12, -22), Vector2(24, 6)), Color("adb5bd"))
					draw_line(spot + Vector2(-12, -6), spot + Vector2(12, -6), Color("495057"), 1)
					draw_line(spot + Vector2(0, -16), spot + Vector2(0, -6), Color("495057"), 1)
					draw_line(spot + Vector2(-6, -6), spot + Vector2(-6, 12), Color("495057"), 1)
				2:
					draw_circle(spot + Vector2(2, 4), 9, Color(0, 0, 0, 0.2))
					draw_circle(spot, 8, Color("7d8590"))
					draw_circle(spot + Vector2(-2, -2), 5, Color("9aa3ad"))
				3, 4:
					var sway := sin(anim_t * 2 + cx * 0.7 + cy * 0.3) * 1.5
					for k in [-1, 0, 1]:
						var base: Vector2 = spot + Vector2(k * 4, 0)
						draw_line(base, base + Vector2(k * 4 + sway, -9 + absi(k) * 2), Color("2f5e24"), 2)
				5:
					var col: Color = [Color("ffe066"), Color("faa2c1"), Color("fff9db")][posmod(h >> 16, 3)]
					for k in 5:
						draw_circle(spot + Vector2.RIGHT.rotated(TAU * k / 5) * 3, 2.5, col)
					draw_circle(spot, 2, Color("f59f00"))


# 용 스프라이트: 방향에 맞는 칸을 골라 그림 (옆모습은 왼쪽을 보고 있어서 오른쪽은 뒤집음)
func draw_dragon() -> void:
	var look := aim if breathing or Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) or not moving else facing
	var col := 0
	var flip := false
	if absf(look.x) > absf(look.y) * 0.8:
		col = 1
		flip = look.x > 0
	elif look.y < 0:
		col = 3

	# 걸을 때는 idle 칸과 walk 칸을 번갈아 보여주고 살짝 통통 튐
	var row := 0
	var bob := 0.0
	if moving:
		var step := int(anim_t * 7) % 4
		row = step % 2
		if col == 1 and row == 0 and step == 2:
			col = 2
		bob = -absf(sin(anim_t * 14)) * 4
	if breathing and col == 1:
		row = 1  # 옆모습 walk 칸은 입을 벌리고 있음

	var s := DRAW_SCALE
	draw_ellipse_shadow(player_pos + Vector2(0, (FOOT_Y - BODY_Y) * s), Vector2(34, 10))
	if invuln > 0 and int(anim_t * 20) % 2 == 0:
		return
	var src := Rect2(col * CELL, row * CELL, CELL, CELL)
	var tint := Color(1, 0.6, 0.6) if invuln > 0.6 else Color.WHITE
	draw_set_transform(player_pos - cam + Vector2(0, bob), 0, Vector2(-s if flip else s, s))
	draw_texture_rect_region(sheet, Rect2(-CELL / 2, -BODY_Y, CELL, CELL), src, tint)
	draw_set_transform(-cam)


func draw_ellipse_shadow(center: Vector2, radii: Vector2) -> void:
	var pts := PackedVector2Array()
	for i in 16:
		var a := TAU * i / 16
		pts.append(center + Vector2(cos(a) * radii.x, sin(a) * radii.y))
	draw_colored_polygon(pts, Color(0, 0, 0, 0.3))


func draw_enemy(e: Dictionary) -> void:
	var t: Dictionary = e["type"]
	var p: Vector2 = e["pos"]
	var r: float = t["radius"]
	var flash: bool = e["flash"] > 0
	var look := p.direction_to(player_pos)
	var side := look.orthogonal()
	var walk := sin(anim_t * 10 + e["phase"]) * 2

	draw_ellipse_shadow(p + Vector2(0, r * 0.9), Vector2(r, r * 0.35))
	var body_p := p + Vector2(0, walk * 0.5)

	match e["kind"]:
		"knight":
			var steel := Color.WHITE if flash else Color("adb5bd")
			draw_line(body_p + side * r * 0.8, body_p + side * r * 0.8 + look * r * 1.5, Color("dee2e6"), 3)
			draw_circle(body_p, r, steel)
			draw_rect(Rect2(body_p + Vector2(-r * 0.6, -r * 0.25), Vector2(r * 1.2, r * 0.22)), Color("212529"))
			draw_circle(body_p - side * r * 0.8 + look * r * 0.3, r * 0.55, Color.WHITE if flash else Color("1c7ed6"))
			draw_circle(body_p - side * r * 0.8 + look * r * 0.3, r * 0.2, Color("ffd43b"))
			draw_colored_polygon(PackedVector2Array([body_p + Vector2(-3, -r), body_p + Vector2(3, -r), body_p + Vector2(0, -r - 9)]), Color("e03131"))
		"archer":
			var hood := Color.WHITE if flash else Color("2f9e44")
			draw_circle(body_p, r, hood)
			draw_circle(body_p + look * r * 0.35, r * 0.55, Color("ffd8a8"))
			draw_circle(body_p + look * r * 0.5 + side * r * 0.2, 1.8, Color("212529"))
			draw_circle(body_p + look * r * 0.5 - side * r * 0.2, 1.8, Color("212529"))
			var bow_c := body_p + look * r * 1.1
			draw_arc(bow_c, r * 0.9, look.angle() - 1.2, look.angle() + 1.2, 12, Color("8b5a2b"), 3)
			draw_line(bow_c + look.rotated(-1.2) * r * 0.9, bow_c + look.rotated(1.2) * r * 0.9, Color(1, 1, 1, 0.7), 1)
		"wizard":
			var robe := Color.WHITE if flash else Color("7048e8")
			draw_colored_polygon(PackedVector2Array([body_p + Vector2(-r, r), body_p + Vector2(r, r), body_p + Vector2(0, -r * 0.6)]), robe)
			draw_circle(body_p + Vector2(0, -r * 0.4), r * 0.5, Color("ffd8a8"))
			draw_colored_polygon(PackedVector2Array([body_p + Vector2(-r * 0.75, -r * 0.6), body_p + Vector2(r * 0.75, -r * 0.6), body_p + Vector2(r * 0.2, -r * 2.0)]), robe.darkened(0.2))
			var staff := body_p + side * r * 0.9
			draw_line(staff + Vector2(0, r), staff + Vector2(0, -r * 1.2), Color("8b5a2b"), 3)
			var glow := 0.6 + 0.4 * sin(anim_t * 6 + e["phase"])
			draw_circle(staff + Vector2(0, -r * 1.3), 6, Color(0.7, 0.5, 1, 0.3 * glow))
			draw_circle(staff + Vector2(0, -r * 1.3), 3.5, Color("e5dbff"))
		"hero":
			var gold_c := Color.WHITE if flash else Color("fab005")
			draw_colored_polygon(PackedVector2Array([body_p - look * r * 0.3 + side * r * 0.8, body_p - look * r * 0.3 - side * r * 0.8, body_p - look * r * 1.8]), Color("c92a2a"))
			var sword_dir := look.rotated(sin(anim_t * 3) * 0.4) if e["dash"] <= 0 else look
			draw_line(body_p + side * r * 0.7, body_p + side * r * 0.7 + sword_dir * r * 2.2, Color("e9ecef"), 6)
			draw_line(body_p + side * r * 0.7 + sword_dir.orthogonal() * 8, body_p + side * r * 0.7 - sword_dir.orthogonal() * 8, Color("e67700"), 4)
			draw_circle(body_p, r, gold_c)
			draw_arc(body_p, r - 3, 0, TAU, 32, gold_c.darkened(0.3), 3)
			draw_circle(body_p + look * r * 0.3, r * 0.45, Color("ffd8a8"))
			for k in 3:
				var tip := body_p + Vector2(-r * 0.5 + k * r * 0.5, -r)
				draw_colored_polygon(PackedVector2Array([tip + Vector2(-5, 4), tip + Vector2(5, 4), tip + Vector2(0, -8)]), Color("ffd43b"))
			if e["dash"] > 0:
				draw_arc(body_p, r + 8, 0, TAU, 32, Color(1, 0.9, 0.3, 0.6), 3)

	var max_hp: float = e["max_hp"]
	if e["hp"] < max_hp and e["kind"] != "hero":
		var bar := Rect2(p + Vector2(-r, -r - 14), Vector2(r * 2, 4))
		draw_rect(bar, Color(0, 0, 0, 0.6))
		draw_rect(Rect2(bar.position, Vector2(bar.size.x * maxf(e["hp"], 0) / max_hp, 4)), Color("ff6b6b"))


# 화면 가장자리를 어둡게
func draw_vignette() -> void:
	const W := 140.0
	var dark := Color(0, 0, 0, 0.45)
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


func draw_bar(rect: Rect2, ratio: float, fill: Color, back: Color, label: String) -> void:
	draw_rect(rect.grow(2), Color(0, 0, 0, 0.6))
	draw_rect(rect, back)
	draw_rect(Rect2(rect.position, Vector2(rect.size.x * clampf(ratio, 0, 1), rect.size.y)), fill)
	outlined(label, rect.position + Vector2(0, rect.size.y - 3), HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, 14)


func draw_hud() -> void:
	draw_bar(Rect2(16, 20, 220, 18), player_hp / PLAYER_MAX_HP, Color("e03131"), Color("5c1a1a"), "HP %d / %d" % [ceili(player_hp), roundi(PLAYER_MAX_HP)])
	draw_bar(Rect2(16, 48, 220, 14), fire / FIRE_MAX, Color("ff922b"), Color("4a2a10"), "화염 %d%%" % roundi(fire / FIRE_MAX * 100))
	outlined("웨이브 %d / %d" % [maxi(wave, 1), LAST_WAVE], Vector2(0, 40), HORIZONTAL_ALIGNMENT_CENTER, SCREEN.x, 26)
	outlined(fmt_time(elapsed), Vector2(0, 66), HORIZONTAL_ALIGNMENT_CENTER, SCREEN.x, 16, Color(1, 1, 1, 0.7))
	outlined("금화 %d" % gold, Vector2(SCREEN.x - 236, 38), HORIZONTAL_ALIGNMENT_RIGHT, 220, 24, Color("ffd43b"))
	outlined("처치 %d" % kills, Vector2(SCREEN.x - 236, 64), HORIZONTAL_ALIGNMENT_RIGHT, 220, 18)
	outlined("클릭: 불덩이   스페이스/우클릭: 화염 숨결", Vector2(16, SCREEN.y - 16), HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(1, 1, 1, 0.8))
	outlined("ESC 일시정지  /  M 메뉴", Vector2(SCREEN.x - 316, SCREEN.y - 16), HORIZONTAL_ALIGNMENT_RIGHT, 300, 14, Color(1, 1, 1, 0.5))

	# 용사 체력 바
	for e in enemies:
		if e["kind"] == "hero":
			var bar := Rect2(SCREEN.x / 2 - 250, 86, 500, 14)
			draw_bar(bar, e["hp"] / e["max_hp"], Color("fab005"), Color("3d2c00"), "용사")

	if banner_t > 0:
		var a := clampf(banner_t / 0.5, 0, 1)
		outlined(banner, Vector2(0, 200), HORIZONTAL_ALIGNMENT_CENTER, SCREEN.x, 40, Color(1, 0.85, 0.3, a))

	match state:
		State.READY:
			draw_panel("드래곤 판타지", "WASD 또는 방향키로 이동\n클릭으로 불덩이, 스페이스나 우클릭을 누르고 있으면 화염 숨결!\n몰려오는 기사단을 물리치고 금화를 모으세요\n%d웨이브에는 용사가 나타나요\n\n스페이스 또는 클릭으로 시작" % LAST_WAVE)
		State.PAUSED:
			draw_panel("일시정지", "ESC, 스페이스 또는 클릭으로 계속")
		State.OVER:
			draw_panel("용이 쓰러졌다...", "웨이브 %d  /  처치 %d  /  금화 %d\n\n스페이스 또는 클릭으로 다시 시작" % [wave, kills, gold])
		State.WON:
			draw_panel("왕국의 주인은 용!", "용사를 물리쳤어요!\n처치 %d  /  금화 %d  /  %s\n\n스페이스 또는 클릭으로 다시 시작" % [kills, gold, fmt_time(elapsed)])


func draw_panel(title: String, body: String) -> void:
	var rect := Rect2(176, 150, 800, 340)
	draw_rect(Rect2(Vector2.ZERO, SCREEN), Color(0, 0, 0, 0.35))
	draw_rect(Rect2(rect.position + Vector2(0, 8), rect.size), Color(0, 0, 0, 0.5))
	draw_rect(rect, Color("2a1a12", 0.95))
	draw_rect(rect, Color("ff922b", 0.7), false, 2)
	outlined(title, rect.position + Vector2(0, 75), HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, 40, Color("ff922b"))
	draw_multiline_string(ThemeDB.fallback_font, rect.position + Vector2(0, 135), body, HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, 22)
