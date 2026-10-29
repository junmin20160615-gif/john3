extends Node2D

const SCREEN := Vector2(1152, 648)
const WIN_TIME := 300.0
const MAX_ENEMIES := 250
const PLAYER_RADIUS := 14.0

const BLADE_RADIUS := 75.0
const BLADE_DAMAGE := 12.0
const BLADE_SIZE := 10.0
const MAX_BLADES := 8

const MAX_PARTICLES := 300
const MAX_TEXTS := 80
const MEAT_HEAL := 30.0

const ENEMY_TYPES := [
	{"shape": "bat", "hp": 8.0, "speed": 95.0, "radius": 10.0, "damage": 5, "xp": 1, "color": Color("9c36b5"), "from": 0.0, "meat": 0.01},
	{"shape": "zombie", "hp": 25.0, "speed": 60.0, "radius": 15.0, "damage": 10, "xp": 3, "color": Color("2f9e44"), "from": 40.0, "meat": 0.02},
	{"shape": "knight", "hp": 70.0, "speed": 75.0, "radius": 19.0, "damage": 15, "xp": 8, "color": Color("868e96"), "from": 100.0, "meat": 0.05},
	{"shape": "golem", "hp": 220.0, "speed": 55.0, "radius": 28.0, "damage": 25, "xp": 20, "color": Color("a0522d"), "from": 200.0, "meat": 0.25},
]

const UPGRADES := [
	{"id": "bolt_power", "name": "마법 화살 강화", "desc": "화살 피해 +5, 발사 간격 -10%"},
	{"id": "bolt_count", "name": "화살 개수 +1", "desc": "한 번에 쏘는 화살이 1개 늘어남"},
	{"id": "blade", "name": "회전 칼날", "desc": "몸 주위를 도는 칼날 +1"},
	{"id": "aura", "name": "마늘 오라", "desc": "주변 적에게 지속 피해 (범위와 피해 증가)"},
	{"id": "knife", "name": "단검", "desc": "바라보는 방향으로 단검을 빠르게 던짐 (2마리 관통)"},
	{"id": "axe", "name": "도끼", "desc": "위로 던진 도끼가 포물선을 그리며 모든 적을 관통"},
	{"id": "lightning", "name": "번개", "desc": "화면 안의 무작위 적에게 강력한 번개"},
	{"id": "holy_water", "name": "성수", "desc": "바닥에 푸른 불꽃 웅덩이를 만들어 지속 피해"},
	{"id": "speed", "name": "신속", "desc": "이동 속도 +10%"},
	{"id": "max_hp", "name": "강인함", "desc": "최대 체력 +20, 체력 모두 회복"},
	{"id": "magnet", "name": "자석", "desc": "경험치 보석 흡수 범위 +40%"},
]

enum State { READY, PLAYING, LEVEL_UP, OVER, WON, PAUSED }

var state := State.READY
var elapsed := 0.0
var kills := 0
var anim_t := 0.0

var player_pos := Vector2.ZERO
var player_hp := 100.0
var player_max_hp := 100.0
var player_speed := 200.0
var facing := Vector2.RIGHT
var moving := false
var invuln := 0.0

var level := 1
var xp := 0
var xp_needed := 5
var pending_levels := 0
var choices: Array = []
var magnet_radius := 90.0

var bolt_level := 1
var bolt_count := 1
var bolt_timer := 0.0
var blade_count := 0
var blade_angle := 0.0
var aura_level := 0
var aura_timer := 0.0
var knife_level := 0
var knife_timer := 0.0
var axe_level := 0
var axe_timer := 0.0
var lightning_level := 0
var lightning_timer := 0.0
var water_level := 0
var water_timer := 0.0

var enemies: Array[Dictionary] = []  # { id, type, pos, hp, max_hp, knock, blade_cd, flash }
var bullets: Array[Dictionary] = []  # { kind, pos, vel, gravity, life, damage, pierce, size, hits }
var gems: Array[Dictionary] = []  # { pos, value }
var meats: Array[Vector2] = []  # 체력 회복 고기
var strikes: Array[Dictionary] = []  # 번개 이펙트 { pos, life }
var pools: Array[Dictionary] = []  # 성수 웅덩이 { pos, radius, life, tick }
var particles: Array[Dictionary] = []  # { pos, vel, life, max_life, color, size }
var texts: Array[Dictionary] = []  # 떠오르는 숫자 { pos, text, life, color }
var spawn_timer := 0.0
var next_enemy_id := 0

# 연출용
var shake := 0.0
var hurt_flash := 0.0
var level_flash := 0.0


func _ready() -> void:
	RenderingServer.set_default_clear_color(Color("4c8c3a"))
	new_game()
	state = State.READY


func new_game() -> void:
	elapsed = 0.0
	kills = 0
	player_pos = Vector2.ZERO
	player_max_hp = 100.0
	player_hp = player_max_hp
	player_speed = 200.0
	facing = Vector2.RIGHT
	invuln = 0.0
	level = 1
	xp = 0
	xp_needed = xp_for_level(1)
	pending_levels = 0
	magnet_radius = 90.0
	bolt_level = 1
	bolt_count = 1
	bolt_timer = 0.0
	blade_count = 0
	aura_level = 0
	knife_level = 0
	axe_level = 0
	lightning_level = 0
	water_level = 0
	enemies.clear()
	bullets.clear()
	gems.clear()
	meats.clear()
	strikes.clear()
	pools.clear()
	particles.clear()
	texts.clear()
	spawn_timer = 0.0
	shake = 0.0
	hurt_flash = 0.0
	level_flash = 0.0
	state = State.PLAYING


func bolt_damage() -> float:
	return 10.0 + 5.0 * (bolt_level - 1)


func bolt_cooldown() -> float:
	return 0.8 * pow(0.9, bolt_level - 1)


func aura_radius() -> float:
	return 50.0 + 20.0 * aura_level


func aura_damage() -> float:
	return 5.0 * aura_level


func water_radius() -> float:
	return 50.0 + 6.0 * water_level


func _unhandled_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	var clicked := mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT

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
		State.LEVEL_UP:
			var key := event as InputEventKey
			if key != null and key.pressed and not key.echo:
				var idx := key.keycode - KEY_1
				if idx >= 0 and idx < choices.size():
					pick_upgrade(idx)
			elif clicked:
				for i in choices.size():
					if card_rect(i).has_point(get_global_mouse_position()):
						pick_upgrade(i)
						break


func _process(delta: float) -> void:
	anim_t += delta
	if state == State.PLAYING:
		update_game(delta)
	queue_redraw()


func update_game(delta: float) -> void:
	elapsed += delta
	if elapsed >= WIN_TIME:
		state = State.WON
		return
	shake = move_toward(shake, 0, 40 * delta)
	hurt_flash = maxf(hurt_flash - delta, 0)
	level_flash = maxf(level_flash - delta, 0)
	move_player(delta)
	spawn_enemies(delta)
	update_enemies(delta)
	separate_enemies(delta)
	update_weapons(delta)
	update_bullets(delta)
	update_effects(delta)
	remove_dead()
	update_pickups(delta)


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
	player_pos += dir * player_speed * delta
	invuln = maxf(invuln - delta, 0)


# 시간이 지날수록 더 자주, 더 많이, 더 센 적이 나옴
func spawn_enemies(delta: float) -> void:
	spawn_timer -= delta
	if spawn_timer > 0:
		return
	spawn_timer = maxf(0.12, 0.9 - elapsed * 0.0045)
	var count := 1 + int(elapsed / 45)
	for i in count:
		if enemies.size() >= MAX_ENEMIES:
			return
		spawn_enemy()


func spawn_enemy() -> void:
	var available := ENEMY_TYPES.filter(func(t): return elapsed >= t["from"])
	var t: Dictionary = available.pick_random()
	var pos := player_pos + Vector2.RIGHT.rotated(randf() * TAU) * (SCREEN.length() / 2 + 40)
	var hp: float = t["hp"] * (1.0 + elapsed / 90.0)
	next_enemy_id += 1
	enemies.append({
		"id": next_enemy_id,
		"type": t,
		"pos": pos,
		"hp": hp,
		"max_hp": hp,
		"knock": Vector2.ZERO,
		"blade_cd": 0.0,
		"flash": 0.0,
	})


func update_enemies(delta: float) -> void:
	for e in enemies:
		var t: Dictionary = e["type"]
		var pos: Vector2 = e["pos"]
		var knock: Vector2 = e["knock"]
		pos = pos.move_toward(player_pos, t["speed"] * delta) + knock * delta
		e["pos"] = pos
		e["knock"] = knock.move_toward(Vector2.ZERO, 900 * delta)
		e["blade_cd"] = maxf(e["blade_cd"] - delta, 0)
		e["flash"] = maxf(e["flash"] - delta, 0)
		if invuln <= 0 and pos.distance_to(player_pos) < t["radius"] + PLAYER_RADIUS:
			hurt_player(t["damage"])


func hurt_player(amount: float) -> void:
	player_hp -= amount
	invuln = 0.5
	shake = 9.0
	hurt_flash = 0.3
	add_text(player_pos + Vector2(0, -24), "-%d" % amount, Color("ff6b6b"))
	if player_hp <= 0:
		player_hp = 0
		state = State.OVER


# 적끼리 겹쳐서 한 덩어리가 되지 않도록 서로 밀어냄 (격자로 가까운 적만 검사)
func separate_enemies(delta: float) -> void:
	const CELL := 48.0
	var grid := {}
	for i in enemies.size():
		var p: Vector2 = enemies[i]["pos"]
		var key := Vector2i(floori(p.x / CELL), floori(p.y / CELL))
		if not grid.has(key):
			grid[key] = []
		grid[key].append(i)

	var strength := minf(1.0, 8.0 * delta)
	for i in enemies.size():
		var e := enemies[i]
		var p: Vector2 = e["pos"]
		var r: float = e["type"]["radius"]
		var key := Vector2i(floori(p.x / CELL), floori(p.y / CELL))
		var push := Vector2.ZERO
		for dx in range(-1, 2):
			for dy in range(-1, 2):
				var cell = grid.get(key + Vector2i(dx, dy))
				if cell == null:
					continue
				for j in cell:
					if j == i:
						continue
					var o: Vector2 = enemies[j]["pos"]
					var min_d: float = r + enemies[j]["type"]["radius"]
					var diff := p - o
					var d2 := diff.length_squared()
					if d2 < min_d * min_d and d2 > 0.0001:
						var d := sqrt(d2)
						push += diff / d * (min_d - d)
		e["pos"] = p + push * strength


# knock: 얼마나 세게 밀려나는지 (큰 적일수록 덜 밀림)
func hurt(e: Dictionary, amount: float, knock := 1.0) -> void:
	e["hp"] -= amount
	e["flash"] = 0.1
	var r: float = e["type"]["radius"]
	var away: Vector2 = player_pos.direction_to(e["pos"])
	e["knock"] = away * 140.0 * knock * (12.0 / r)
	add_text(e["pos"] + Vector2(randf_range(-8, 8), -r), str(roundi(amount)), Color.WHITE)


func add_text(pos: Vector2, text: String, color: Color) -> void:
	if texts.size() >= MAX_TEXTS:
		texts.pop_front()
	texts.append({"pos": pos, "text": text, "life": 0.6, "color": color})


func burst(pos: Vector2, color: Color, count: int, speed: float, size: float) -> void:
	for i in count:
		if particles.size() >= MAX_PARTICLES:
			particles.pop_front()
		var life := randf_range(0.25, 0.5)
		particles.append({
			"pos": pos,
			"vel": Vector2.RIGHT.rotated(randf() * TAU) * randf_range(speed * 0.4, speed),
			"life": life, "max_life": life, "color": color, "size": size * randf_range(0.6, 1.2),
		})


func nearest_enemies(n: int) -> Array:
	var near := enemies.filter(func(e): return e["hp"] > 0 and player_pos.distance_to(e["pos"]) < 450)
	near.sort_custom(func(a, b): return player_pos.distance_squared_to(a["pos"]) < player_pos.distance_squared_to(b["pos"]))
	return near.slice(0, n)


func on_screen_enemies() -> Array:
	return enemies.filter(func(e):
		var d: Vector2 = (e["pos"] - player_pos).abs()
		return e["hp"] > 0 and d.x < SCREEN.x / 2 and d.y < SCREEN.y / 2)


func blade_pos(i: int) -> Vector2:
	return player_pos + Vector2.RIGHT.rotated(blade_angle + TAU * i / blade_count) * BLADE_RADIUS


# pierce: 몇 마리까지 맞히고 사라지는지
func add_bullet(kind: String, vel: Vector2, damage: float, pierce: int, life: float, size: float, gravity := 0.0, offset := Vector2.ZERO) -> void:
	bullets.append({
		"kind": kind, "pos": player_pos + offset, "vel": vel, "gravity": gravity,
		"life": life, "damage": damage, "pierce": pierce, "size": size, "hits": [],
	})


func update_weapons(delta: float) -> void:
	# 마법 화살: 가장 가까운 적에게 자동 발사
	bolt_timer -= delta
	if bolt_timer <= 0:
		var targets := nearest_enemies(bolt_count)
		if not targets.is_empty():
			bolt_timer = bolt_cooldown()
			for i in bolt_count:
				var target: Dictionary = targets[i % targets.size()]
				var dir := player_pos.direction_to(target["pos"])
				if i >= targets.size():
					dir = dir.rotated(randf_range(-0.3, 0.3))
				add_bullet("bolt", dir * 520, bolt_damage(), 1, 1.4, 5)

	# 회전 칼날
	blade_angle += 3.5 * delta
	for i in blade_count:
		var bp := blade_pos(i)
		for e in enemies:
			if e["blade_cd"] <= 0 and bp.distance_to(e["pos"]) < e["type"]["radius"] + BLADE_SIZE:
				hurt(e, BLADE_DAMAGE)
				e["blade_cd"] = 0.35

	# 마늘 오라: 0.5초마다 주변에 피해
	if aura_level > 0:
		aura_timer -= delta
		if aura_timer <= 0:
			aura_timer = 0.5
			for e in enemies:
				if player_pos.distance_to(e["pos"]) < aura_radius() + e["type"]["radius"]:
					hurt(e, aura_damage(), 0.6)

	# 단검: 바라보는 방향으로 나란히 던짐
	if knife_level > 0:
		knife_timer -= delta
		if knife_timer <= 0:
			knife_timer = 0.6 * pow(0.92, knife_level - 1)
			var count := ceili(knife_level / 2.0)
			for i in count:
				var offset := facing.orthogonal() * (i - (count - 1) / 2.0) * 12
				add_bullet("knife", facing * 700, 8.0 + 3.0 * (knife_level - 1), 2, 0.8, 6, 0.0, offset)

	# 도끼: 위로 던지면 중력으로 떨어지며 관통
	if axe_level > 0:
		axe_timer -= delta
		if axe_timer <= 0:
			axe_timer = 1.8
			for i in axe_level:
				add_bullet("axe", Vector2(randf_range(-170, 170), -560), 25.0 + 8.0 * (axe_level - 1), 999, 2.0, 14, 950.0)

	# 번개: 화면 안 무작위 적에게 즉시 피해
	if lightning_level > 0:
		lightning_timer -= delta
		if lightning_timer <= 0:
			var targets := on_screen_enemies()
			if not targets.is_empty():
				lightning_timer = maxf(0.8, 2.2 - 0.2 * (lightning_level - 1))
				targets.shuffle()
				for e in targets.slice(0, lightning_level):
					hurt(e, 35.0 + 10.0 * (lightning_level - 1), 0.3)
					strikes.append({"pos": e["pos"], "life": 0.2})
					burst(e["pos"], Color("fff3bf"), 6, 220, 4)
				shake = maxf(shake, 3.0)

	# 성수: 주변 무작위 위치에 웅덩이 생성
	if water_level > 0:
		water_timer -= delta
		if water_timer <= 0:
			water_timer = 3.0
			for i in water_level:
				var pos := player_pos + Vector2(randf_range(-260, 260), randf_range(-180, 180))
				pools.append({"pos": pos, "radius": water_radius(), "life": 2.5, "tick": 0.0})


func update_bullets(delta: float) -> void:
	for i in range(bullets.size() - 1, -1, -1):
		var b := bullets[i]
		var vel: Vector2 = b["vel"]
		vel.y += b["gravity"] * delta
		b["vel"] = vel
		var pos: Vector2 = b["pos"] + vel * delta
		b["pos"] = pos
		b["life"] -= delta
		var hits: Array = b["hits"]
		for e in enemies:
			if e["hp"] > 0 and not hits.has(e["id"]) and pos.distance_to(e["pos"]) < e["type"]["radius"] + b["size"]:
				hurt(e, b["damage"])
				hits.append(e["id"])
				b["pierce"] -= 1
				if b["pierce"] <= 0:
					break
		if b["pierce"] <= 0 or b["life"] <= 0:
			if b["kind"] == "bolt" and b["pierce"] <= 0:
				burst(pos, Color("ffe066"), 4, 120, 3)
			bullets.remove_at(i)


func update_effects(delta: float) -> void:
	for i in range(strikes.size() - 1, -1, -1):
		strikes[i]["life"] -= delta
		if strikes[i]["life"] <= 0:
			strikes.remove_at(i)

	var water_damage := 6.0 + 3.0 * (water_level - 1)
	for i in range(pools.size() - 1, -1, -1):
		var p := pools[i]
		p["life"] -= delta
		p["tick"] -= delta
		if p["tick"] <= 0:
			p["tick"] = 0.3
			for e in enemies:
				if p["pos"].distance_to(e["pos"]) < p["radius"] + e["type"]["radius"]:
					hurt(e, water_damage, 0.2)
		if p["life"] <= 0:
			pools.remove_at(i)

	for i in range(particles.size() - 1, -1, -1):
		var p := particles[i]
		var vel: Vector2 = p["vel"]
		p["pos"] += vel * delta
		p["vel"] = vel.move_toward(Vector2.ZERO, 400 * delta)
		p["life"] -= delta
		if p["life"] <= 0:
			particles.remove_at(i)

	for i in range(texts.size() - 1, -1, -1):
		texts[i]["pos"] += Vector2(0, -45 * delta)
		texts[i]["life"] -= delta
		if texts[i]["life"] <= 0:
			texts.remove_at(i)


func remove_dead() -> void:
	for i in range(enemies.size() - 1, -1, -1):
		var e := enemies[i]
		if e["hp"] <= 0:
			var t: Dictionary = e["type"]
			gems.append({"pos": e["pos"], "value": t["xp"]})
			if randf() < t["meat"]:
				meats.append(e["pos"] + Vector2(randf_range(-10, 10), randf_range(-10, 10)))
			burst(e["pos"], t["color"], 8, 180, t["radius"] * 0.35)
			kills += 1
			enemies.remove_at(i)


func update_pickups(delta: float) -> void:
	for i in range(gems.size() - 1, -1, -1):
		var g := gems[i]
		var pos: Vector2 = g["pos"]
		var d := pos.distance_to(player_pos)
		if d < PLAYER_RADIUS + 6:
			gems.remove_at(i)
			gain_xp(g["value"])
		elif d < magnet_radius:
			# 가까울수록 빨리 빨려옴
			g["pos"] = pos.move_toward(player_pos, lerpf(600, 250, d / magnet_radius) * delta)

	for i in range(meats.size() - 1, -1, -1):
		if meats[i].distance_to(player_pos) < PLAYER_RADIUS + 12:
			var healed := minf(MEAT_HEAL, player_max_hp - player_hp)
			player_hp += healed
			add_text(player_pos + Vector2(0, -24), "+%d" % healed, Color("69db7c"))
			burst(meats[i], Color("69db7c"), 8, 120, 3)
			meats.remove_at(i)


func gain_xp(amount: int) -> void:
	xp += amount
	while xp >= xp_needed:
		xp -= xp_needed
		level += 1
		xp_needed = xp_for_level(level)
		pending_levels += 1
	if pending_levels > 0 and state == State.PLAYING:
		state = State.LEVEL_UP
		level_flash = 0.6
		burst(player_pos, Color("ffd43b"), 20, 260, 4)
		roll_choices()


func xp_for_level(lv: int) -> int:
	return 2 + lv * 3


func roll_choices() -> void:
	var pool := UPGRADES.filter(func(u): return not (u["id"] == "blade" and blade_count >= MAX_BLADES))
	pool.shuffle()
	choices = pool.slice(0, 3)


func pick_upgrade(idx: int) -> void:
	apply_upgrade(choices[idx]["id"])
	pending_levels -= 1
	if pending_levels > 0:
		roll_choices()
	else:
		state = State.PLAYING


func apply_upgrade(id: String) -> void:
	match id:
		"bolt_power":
			bolt_level += 1
		"bolt_count":
			bolt_count += 1
		"blade":
			blade_count += 1
		"aura":
			aura_level += 1
		"knife":
			knife_level += 1
		"axe":
			axe_level += 1
		"lightning":
			lightning_level += 1
		"holy_water":
			water_level += 1
		"speed":
			player_speed *= 1.1
		"max_hp":
			player_max_hp += 20
			player_hp = player_max_hp
		"magnet":
			magnet_radius *= 1.4


# 무기 강화의 현재 단계 (-1이면 단계 표시가 없는 능력치 강화)
func upgrade_level(id: String) -> int:
	match id:
		"bolt_power":
			return bolt_level
		"bolt_count":
			return bolt_count
		"blade":
			return blade_count
		"aura":
			return aura_level
		"knife":
			return knife_level
		"axe":
			return axe_level
		"lightning":
			return lightning_level
		"holy_water":
			return water_level
	return -1


func card_rect(i: int) -> Rect2:
	return Rect2(96 + i * 330, 230, 300, 180)


func fmt_time(t: float) -> String:
	return "%02d:%02d" % [floori(t / 60), int(t) % 60]


func gem_color(value: int) -> Color:
	if value >= 20:
		return Color("cc5de8")
	if value >= 8:
		return Color("ff6b6b")
	if value >= 3:
		return Color("51cf66")
	return Color("3bc9db")


# ---------------------------------------------------------------- 그리기


func _draw() -> void:
	# 월드는 플레이어가 화면 가운데 오도록 옮겨서 그림 (맞으면 화면이 흔들림)
	var cam := player_pos - SCREEN / 2 + Vector2(randf_range(-1, 1), randf_range(-1, 1)) * shake
	draw_set_transform(-cam)
	draw_ground(cam)

	for p in pools:
		var alpha: float = clampf(p["life"] / 0.5, 0, 1)
		var wobble := sin(anim_t * 6 + p["pos"].x) * 3
		draw_circle(p["pos"], p["radius"] + wobble, Color(0.3, 0.6, 1, 0.25 * alpha))
		draw_circle(p["pos"], (p["radius"] + wobble) * 0.6, Color(0.5, 0.8, 1, 0.2 * alpha))
		draw_arc(p["pos"], p["radius"] + wobble, 0, TAU, 40, Color(0.6, 0.85, 1, 0.7 * alpha), 2)

	for g in gems:
		var col := gem_color(g["value"])
		var p: Vector2 = g["pos"] + Vector2(0, sin(anim_t * 4 + g["pos"].x * 0.1) * 2)
		draw_circle(p, 9, Color(col, 0.18))
		draw_colored_polygon(PackedVector2Array([
			p + Vector2(0, -7), p + Vector2(5, 0), p + Vector2(0, 7), p + Vector2(-5, 0),
		]), col)
		draw_line(p + Vector2(-1, -4), p + Vector2(1, -1), Color(1, 1, 1, 0.7), 1.5)

	for m in meats:
		draw_meat(m)

	if aura_level > 0:
		var pulse := 1.0 + sin(anim_t * 5) * 0.04
		draw_circle(player_pos, aura_radius() * pulse, Color(1, 0.9, 0.4, 0.08))
		draw_arc(player_pos, aura_radius() * pulse, 0, TAU, 48, Color(1, 0.9, 0.4, 0.35), 2)

	for e in enemies:
		draw_enemy(e)

	for b in bullets:
		var p: Vector2 = b["pos"]
		match b["kind"]:
			"bolt":
				var tail: Vector2 = b["vel"].normalized() * 14
				draw_line(p - tail, p, Color(1, 0.9, 0.4, 0.35), 6)
				draw_circle(p, 8, Color(1, 0.9, 0.4, 0.25))
				draw_circle(p, 4.5, Color("fff3bf"))
			"knife":
				var d: Vector2 = b["vel"].normalized() * 10
				draw_line(p - d * 1.8, p - d, Color(1, 1, 1, 0.25), 3)
				draw_line(p - d, p + d, Color("f1f3f5"), 3)
				draw_line(p - d, p - d * 0.4, Color("5c3d1e"), 4)
			"axe":
				draw_set_transform(p - cam, anim_t * 14)
				draw_rect(Rect2(-2, -12, 4, 24), Color("8b5a2b"))
				draw_colored_polygon(PackedVector2Array([
					Vector2(2, -12), Vector2(14, -9), Vector2(14, 3), Vector2(2, -2),
				]), Color("ced4da"))
				draw_set_transform(-cam)

	for i in blade_count:
		var bp := blade_pos(i)
		draw_circle(bp, 12, Color(0.65, 0.85, 1, 0.15))
		draw_set_transform(bp - cam, blade_angle * 3)
		draw_colored_polygon(PackedVector2Array([
			Vector2(-14, 0), Vector2(0, -5), Vector2(14, 0), Vector2(0, 5),
		]), Color("a5d8ff"))
		draw_set_transform(-cam)

	for p in particles:
		var a: float = p["life"] / p["max_life"]
		draw_circle(p["pos"], p["size"] * a, Color(p["color"], a))

	# 번개: 화면 위에서 적까지 지그재그 선
	for s in strikes:
		var target: Vector2 = s["pos"]
		var pts := PackedVector2Array()
		var top := target.y - SCREEN.y
		for k in 9:
			var y := lerpf(top, target.y, k / 8.0)
			var jitter := 0.0 if k == 0 or k == 8 else randf_range(-18, 18)
			pts.append(Vector2(target.x + jitter, y))
		draw_polyline(pts, Color(1, 1, 0.7, 0.35), 10)
		draw_polyline(pts, Color("fff3bf"), 3)
		draw_circle(target, 18, Color(1, 1, 0.7, 0.4))

	draw_player()

	if level_flash > 0:
		var t := 1.0 - level_flash / 0.6
		draw_arc(player_pos, 20 + t * 260, 0, TAU, 48, Color(1, 0.85, 0.3, 1.0 - t), 5)

	var font := ThemeDB.fallback_font
	for t in texts:
		var a: float = clampf(t["life"] / 0.3, 0, 1)
		var p: Vector2 = t["pos"] - Vector2(40, 0)
		draw_string_outline(font, p, t["text"], HORIZONTAL_ALIGNMENT_CENTER, 80, 16, 4, Color(0, 0, 0, a))
		draw_string(font, p, t["text"], HORIZONTAL_ALIGNMENT_CENTER, 80, 16, Color(t["color"], a))

	draw_set_transform(Vector2.ZERO)
	draw_vignette()
	if hurt_flash > 0:
		draw_rect(Rect2(Vector2.ZERO, SCREEN), Color(1, 0, 0, 0.25 * hurt_flash / 0.3))
	draw_hud()


# 바닥: 푸른 초원. 칸마다 정해진 풀 무늬/풀숲/꽃/돌 장식
func draw_ground(cam: Vector2) -> void:
	const STEP := 64.0
	var x0 := floori(cam.x / STEP) - 1
	var y0 := floori(cam.y / STEP) - 1
	var flowers := [Color("fff9db"), Color("ffe066"), Color("faa2c1"), Color("d0bfff")]
	var x1 := x0 + int(SCREEN.x / STEP) + 3
	var y1 := y0 + int(SCREEN.y / STEP) + 3

	# 밝고 어두운 풀 얼룩 (칸 경계를 넘어 퍼져서 타일이 안 보임)
	for cx in range(x0, x1):
		for cy in range(y0, y1):
			var origin := Vector2(cx, cy) * STEP
			var h := hash(Vector2i(cx, cy))
			if posmod(h >> 4, 3) == 0:
				draw_circle(origin + Vector2(32, 32), 40 + posmod(h >> 12, 16), Color("57983f", 0.6))
			elif posmod(h >> 4, 5) == 1:
				draw_circle(origin + Vector2(32, 32), 34 + posmod(h >> 12, 12), Color("437f33", 0.6))

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
						draw_ellipse_poly(spot + Vector2(0, 3), Vector2(7, 2.5), Color(0, 0, 0, 0.2))
						draw_circle(spot, 5, Color("8a9199"))
						draw_circle(spot + Vector2(-1.5, -1.5), 3, Color("adb5bd"))


func draw_ellipse_poly(center: Vector2, radii: Vector2, color: Color) -> void:
	var pts := PackedVector2Array()
	for i in 14:
		var a := TAU * i / 14
		pts.append(center + Vector2(cos(a) * radii.x, sin(a) * radii.y))
	draw_colored_polygon(pts, color)


# fwd 방향으로 길쭉한 타원
func draw_oval(center: Vector2, fwd: Vector2, length: float, width: float, color: Color) -> void:
	var pts := PackedVector2Array()
	for i in 16:
		var a := TAU * i / 16
		pts.append(center + fwd * cos(a) * length + fwd.orthogonal() * sin(a) * width)
	draw_colored_polygon(pts, color)


func draw_enemy(e: Dictionary) -> void:
	var t: Dictionary = e["type"]
	var p: Vector2 = e["pos"]
	var r: float = t["radius"]
	var flash: bool = e["flash"] > 0
	var col: Color = Color.WHITE if flash else t["color"]
	var dark: Color = Color.WHITE if flash else col.darkened(0.35)
	var look := p.direction_to(player_pos)
	var side := look.orthogonal()

	draw_ellipse_poly(p + Vector2(0, r * 0.85), Vector2(r * 0.85, r * 0.3), Color(0, 0, 0, 0.3))

	match t["shape"]:
		"bat":
			var flap := sin(anim_t * 18 + e["id"]) * 0.6
			for s in [-1.0, 1.0]:
				draw_colored_polygon(PackedVector2Array([
					p + Vector2(s * r * 0.5, 0),
					p + Vector2(s * r * 2.0, -r * (0.7 + flap)),
					p + Vector2(s * r * 1.3, r * 0.5),
				]), dark)
			draw_circle(p, r, col)
		"zombie":
			for s in [-1.0, 1.0]:
				var shoulder: Vector2 = p + side * s * r * 0.7
				draw_line(shoulder, shoulder + look * r * 1.1, dark, 5)
			draw_circle(p, r, col)
			draw_circle(p + Vector2(r * 0.3, r * 0.35), r * 0.18, dark)
		"knight":
			draw_circle(p, r, col)
			draw_arc(p, r - 2, 0, TAU, 24, dark, 3)
			draw_colored_polygon(PackedVector2Array([
				p + Vector2(-3, -r + 2), p + Vector2(3, -r + 2), p + Vector2(0, -r - 10),
			]), Color.WHITE if flash else Color("e03131"))
			draw_rect(Rect2(p + look * r * 0.2 + Vector2(-r * 0.6, -r * 0.35), Vector2(r * 1.2, r * 0.3)), Color("212529"))
		"golem":
			var pts := PackedVector2Array()
			for i in 8:
				var a := TAU * i / 8 + 0.2
				pts.append(p + Vector2(cos(a), sin(a)) * r * (0.9 + 0.1 * (i % 2)))
			draw_colored_polygon(pts, col)
			draw_line(p + Vector2(-r * 0.5, r * 0.1), p + Vector2(-r * 0.1, r * 0.5), dark, 3)
			draw_line(p + Vector2(r * 0.2, -r * 0.6), p + Vector2(r * 0.5, -r * 0.2), dark, 3)

	# 눈은 플레이어 쪽을 바라봄
	var eye_col := Color("ffd43b") if t["shape"] == "knight" else Color("ff6b6b")
	var eye_center := p + look * r * 0.3 + Vector2(0, -r * 0.2)
	draw_circle(eye_center + side * r * 0.3, maxf(2.0, r * 0.13), eye_col)
	draw_circle(eye_center - side * r * 0.3, maxf(2.0, r * 0.13), eye_col)

	var max_hp: float = e["max_hp"]
	if max_hp >= 100 and e["hp"] < max_hp:
		var bar := Rect2(p + Vector2(-r, -r - 10), Vector2(r * 2, 4))
		draw_rect(bar, Color(0, 0, 0, 0.6))
		draw_rect(Rect2(bar.position, Vector2(bar.size.x * e["hp"] / max_hp, 4)), Color("ff6b6b"))


func draw_meat(p: Vector2) -> void:
	var bob := Vector2(0, sin(anim_t * 3 + p.x) * 2)
	var c := p + bob
	draw_ellipse_poly(p + Vector2(0, 10), Vector2(10, 3), Color(0, 0, 0, 0.3))
	draw_line(c + Vector2(4, 2), c + Vector2(12, 8), Color("f1f3f5"), 4)
	draw_circle(c + Vector2(13, 9), 3, Color("f1f3f5"))
	draw_circle(c, 9, Color("c0632f"))
	draw_circle(c + Vector2(-3, -3), 4, Color("e8834e"))


func draw_player() -> void:
	draw_ellipse_poly(player_pos + Vector2(0, PLAYER_RADIUS * 0.9), Vector2(PLAYER_RADIUS, PLAYER_RADIUS * 0.35), Color(0, 0, 0, 0.35))

	# 맞은 직후에는 깜빡임
	if not (invuln > 0 and int(anim_t * 20) % 2 == 0):
		var bounce := Vector2(0, -absf(sin(anim_t * 10)) * 2)
		var c := player_pos + bounce
		var side := facing.orthogonal()
		var skin := Color("adb5bd")
		var dark := Color("495057")

		# 꼬리: 뒤로 갈수록 가늘어지고 살랑거림
		var prev := c - facing * 8
		for k in range(1, 8):
			var pt := c - facing * (8 + k * 4) + side * sin(anim_t * 8 - k * 0.8) * k * 0.9
			draw_line(prev, pt, skin, 8 - k)
			prev = pt

		# 다리: 움직일 때만 번갈아 걸음
		var step := sin(anim_t * 16) * 4 if moving else 0.0
		for f in [-1.0, 1.0]:
			for s in [-1.0, 1.0]:
				var hip: Vector2 = c + facing * f * 6 + side * s * 5
				var foot: Vector2 = hip + side * s * 7 + facing * (f * 3 + step * f * s)
				draw_line(hip, foot, dark, 3)
				draw_circle(foot, 2.5, dark)

		# 몸통과 등 무늬
		draw_oval(c, facing, 12, 8, skin)
		for k in [-1.0, 0.0, 1.0]:
			draw_circle(c + facing * k * 5, 2, dark)

		# 머리
		var head := c + facing * 13
		draw_oval(head, facing, 7, 6, skin)
		for s in [-1.0, 1.0]:
			var eye: Vector2 = head + facing * 1 + side * s * 4.5
			draw_circle(eye, 2.5, Color("212529"))
			draw_circle(eye + facing * 0.8 - side * s * 0.6, 0.9, Color.WHITE)

		# 가끔 혀를 날름
		if sin(anim_t * 3) > 0.85:
			var tip := head + facing * 13
			draw_line(head + facing * 6, tip, Color("e03131"), 2)
			draw_line(tip, tip + facing * 3 + side * 2, Color("e03131"), 1.5)
			draw_line(tip, tip + facing * 3 - side * 2, Color("e03131"), 1.5)

	var bar := Rect2(player_pos + Vector2(-22, PLAYER_RADIUS + 10), Vector2(44, 5))
	draw_rect(bar.grow(1), Color(0, 0, 0, 0.6))
	draw_rect(bar, Color("c92a2a"))
	draw_rect(Rect2(bar.position, Vector2(bar.size.x * player_hp / player_max_hp, bar.size.y)), Color("51cf66"))


# 화면 가장자리를 어둡게
func draw_vignette() -> void:
	const W := 140.0
	var dark := Color(0, 0, 0, 0.5)
	var clear := Color(0, 0, 0, 0)
	var s := SCREEN
	draw_polygon(PackedVector2Array([Vector2(0, 0), Vector2(s.x, 0), Vector2(s.x, W), Vector2(0, W)]), PackedColorArray([dark, dark, clear, clear]))
	draw_polygon(PackedVector2Array([Vector2(0, s.y - W), Vector2(s.x, s.y - W), Vector2(s.x, s.y), Vector2(0, s.y)]), PackedColorArray([clear, clear, dark, dark]))
	draw_polygon(PackedVector2Array([Vector2(0, 0), Vector2(W, 0), Vector2(W, s.y), Vector2(0, s.y)]), PackedColorArray([dark, clear, clear, dark]))
	draw_polygon(PackedVector2Array([Vector2(s.x - W, 0), Vector2(s.x, 0), Vector2(s.x, s.y), Vector2(s.x - W, s.y)]), PackedColorArray([clear, dark, dark, clear]))


func weapon_summary() -> String:
	var parts: Array[String] = ["화살 Lv%d x%d" % [bolt_level, bolt_count]]
	if blade_count > 0:
		parts.append("칼날 x%d" % blade_count)
	if aura_level > 0:
		parts.append("오라 Lv%d" % aura_level)
	if knife_level > 0:
		parts.append("단검 Lv%d" % knife_level)
	if axe_level > 0:
		parts.append("도끼 Lv%d" % axe_level)
	if lightning_level > 0:
		parts.append("번개 Lv%d" % lightning_level)
	if water_level > 0:
		parts.append("성수 Lv%d" % water_level)
	return "  |  ".join(parts)


func outlined(text: String, pos: Vector2, align: HorizontalAlignment, width: float, size: int, color := Color.WHITE) -> void:
	var font := ThemeDB.fallback_font
	draw_string_outline(font, pos, text, align, width, size, 6, Color(0, 0, 0, 0.8))
	draw_string(font, pos, text, align, width, size, color)


func draw_hud() -> void:
	var minutes := int(WIN_TIME / 60)

	# 경험치 바
	draw_rect(Rect2(0, 0, SCREEN.x, 14), Color(0, 0, 0, 0.6))
	draw_rect(Rect2(0, 0, SCREEN.x * xp / xp_needed, 14), Color("3bc9db"))
	draw_rect(Rect2(0, 0, SCREEN.x * xp / xp_needed, 4), Color(1, 1, 1, 0.3))

	# 체력 바
	var hp_bar := Rect2(16, 26, 220, 18)
	draw_rect(hp_bar.grow(2), Color(0, 0, 0, 0.6))
	draw_rect(hp_bar, Color("5c1a1a"))
	draw_rect(Rect2(hp_bar.position, Vector2(hp_bar.size.x * player_hp / player_max_hp, hp_bar.size.y)), Color("e03131"))
	outlined("HP %d / %d" % [ceili(player_hp), roundi(player_max_hp)], hp_bar.position + Vector2(0, 14), HORIZONTAL_ALIGNMENT_CENTER, hp_bar.size.x, 14)
	outlined("Lv %d" % level, Vector2(250, 43), HORIZONTAL_ALIGNMENT_LEFT, -1, 22, Color("ffd43b"))

	var time_col := Color("ff8787") if WIN_TIME - elapsed < 30 else Color.WHITE
	outlined(fmt_time(elapsed), Vector2(0, 50), HORIZONTAL_ALIGNMENT_CENTER, SCREEN.x, 32, time_col)
	outlined("처치 %d" % kills, Vector2(SCREEN.x - 236, 43), HORIZONTAL_ALIGNMENT_RIGHT, 220, 22)
	outlined(weapon_summary(), Vector2(16, SCREEN.y - 16), HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(1, 1, 1, 0.85))
	outlined("ESC 일시정지", Vector2(SCREEN.x - 216, SCREEN.y - 16), HORIZONTAL_ALIGNMENT_RIGHT, 200, 14, Color(1, 1, 1, 0.5))

	match state:
		State.READY:
			draw_panel("뱀서라이크 미니", "WASD 또는 방향키로 이동, 공격은 자동!\n%d분 동안 살아남으세요\n\n스페이스 또는 클릭으로 시작" % minutes)
		State.PAUSED:
			draw_panel("일시정지", "ESC, 스페이스 또는 클릭으로 계속")
		State.OVER:
			draw_panel("쓰러졌다...", "생존 시간 %s  /  처치 %d  /  Lv %d\n\n스페이스 또는 클릭으로 다시 시작" % [fmt_time(elapsed), kills, level])
		State.WON:
			draw_panel("%d분 생존 성공!" % minutes, "처치 %d  /  Lv %d\n\n스페이스 또는 클릭으로 다시 시작" % [kills, level])
		State.LEVEL_UP:
			draw_level_up()


func draw_level_up() -> void:
	var font := ThemeDB.fallback_font
	var mouse := get_global_mouse_position()
	draw_rect(Rect2(Vector2.ZERO, SCREEN), Color(0, 0, 0, 0.6))
	outlined("레벨 업!", Vector2(0, 150), HORIZONTAL_ALIGNMENT_CENTER, SCREEN.x, 40, Color("ffd43b"))
	outlined("강화를 고르세요 (1 / 2 / 3 키 또는 클릭)", Vector2(0, 192), HORIZONTAL_ALIGNMENT_CENTER, SCREEN.x, 20)
	for i in choices.size():
		var rect := card_rect(i)
		var hovered := rect.has_point(mouse)
		if hovered:
			rect = rect.grow(6)
		var lv := upgrade_level(choices[i]["id"])
		var tag := ""
		if lv == 0:
			tag = "새 무기!"
		elif lv > 0:
			tag = "Lv %d → %d" % [lv, lv + 1]
		draw_rect(Rect2(rect.position + Vector2(0, 6), rect.size), Color(0, 0, 0, 0.5))
		draw_rect(rect, Color("343450") if hovered else Color("2b2b3d"))
		draw_rect(Rect2(rect.position, Vector2(rect.size.x, 6)), Color("ffd43b"))
		draw_rect(rect, Color("ffe066") if hovered else Color("ffd43b", 0.7), false, 3 if hovered else 2)
		draw_string(font, rect.position + Vector2(0, 55), "[%d] %s" % [i + 1, choices[i]["name"]], HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, 24)
		draw_string(font, rect.position + Vector2(0, 85), tag, HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, 18, Color("69db7c") if lv == 0 else Color("ffd43b"))
		draw_multiline_string(font, rect.position + Vector2(20, 120), choices[i]["desc"], HORIZONTAL_ALIGNMENT_CENTER, rect.size.x - 40, 17, -1, Color("ced4da"))


func draw_panel(title: String, body: String) -> void:
	var rect := Rect2(226, 170, 700, 300)
	draw_rect(Rect2(Vector2.ZERO, SCREEN), Color(0, 0, 0, 0.35))
	draw_rect(Rect2(rect.position + Vector2(0, 8), rect.size), Color(0, 0, 0, 0.5))
	draw_rect(rect, Color("1b1b2a", 0.95))
	draw_rect(rect, Color("ffd43b", 0.6), false, 2)
	outlined(title, rect.position + Vector2(0, 75), HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, 40, Color("ffd43b"))
	draw_multiline_string(ThemeDB.fallback_font, rect.position + Vector2(0, 140), body, HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, 22)
