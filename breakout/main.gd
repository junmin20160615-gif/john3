extends Node2D

const SCREEN := Vector2(1152, 648)
const BG_COLOR := Color("1b1b2f")

const PADDLE_SIZE := Vector2(140, 18)
const PADDLE_Y := 600.0
const PADDLE_SPEED := 700.0

const BALL_RADIUS := 9.0
const BALL_START_SPEED := 420.0
const BALL_MAX_SPEED := 800.0

const BRICK_COLS := 10
const BRICK_ROWS := 6
const BRICK_SIZE := Vector2(96, 26)
const BRICK_GAP := 6.0
const BRICK_TOP := 80.0
const ROW_COLORS := [
	Color("ef476f"), Color("f78c6b"), Color("ffd166"),
	Color("06d6a0"), Color("118ab2"), Color("8338ec"),
]

enum State { READY, PLAYING, WON, LOST }

var state := State.READY
var paddle_x := SCREEN.x / 2
var ball_pos := Vector2.ZERO
var ball_vel := Vector2.ZERO
var bricks: Array[Dictionary] = []  # { rect: Rect2, color: Color, points: int }
var score := 0
var lives := 3


func _ready() -> void:
	RenderingServer.set_default_clear_color(BG_COLOR)
	new_game()


func new_game() -> void:
	score = 0
	lives = 3
	build_bricks()
	reset_ball()


func build_bricks() -> void:
	bricks.clear()
	var total_w := BRICK_COLS * BRICK_SIZE.x + (BRICK_COLS - 1) * BRICK_GAP
	var left := (SCREEN.x - total_w) / 2
	for row in BRICK_ROWS:
		for col in BRICK_COLS:
			var pos := Vector2(
				left + col * (BRICK_SIZE.x + BRICK_GAP),
				BRICK_TOP + row * (BRICK_SIZE.y + BRICK_GAP)
			)
			bricks.append({
				"rect": Rect2(pos, BRICK_SIZE),
				"color": ROW_COLORS[row % ROW_COLORS.size()],
				"points": (BRICK_ROWS - row) * 10,
			})


# 공을 패들 위에 올려두고 발사 대기
func reset_ball() -> void:
	state = State.READY
	ball_vel = Vector2.ZERO
	stick_ball_to_paddle()


func stick_ball_to_paddle() -> void:
	ball_pos = Vector2(paddle_x, PADDLE_Y - BALL_RADIUS - 1)


func launch() -> void:
	var angle := randf_range(-PI / 4, PI / 4)
	ball_vel = Vector2.UP.rotated(angle) * BALL_START_SPEED
	state = State.PLAYING


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		paddle_x = get_global_mouse_position().x

	var mb := event as InputEventMouseButton
	var clicked := mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT
	if not (clicked or event.is_action_pressed("ui_accept")):
		return

	match state:
		State.READY:
			launch()
		State.WON, State.LOST:
			new_game()


func _process(delta: float) -> void:
	paddle_x += Input.get_axis("ui_left", "ui_right") * PADDLE_SPEED * delta
	paddle_x = clampf(paddle_x, PADDLE_SIZE.x / 2, SCREEN.x - PADDLE_SIZE.x / 2)

	if state == State.READY:
		stick_ball_to_paddle()
	elif state == State.PLAYING:
		update_ball(delta)

	queue_redraw()


# 빠른 공이 벽돌을 뚫고 지나가지 않도록 여러 번 나눠서 이동
func update_ball(delta: float) -> void:
	var steps := maxi(1, ceili(ball_vel.length() * delta / BALL_RADIUS))
	var dt := delta / steps
	for i in steps:
		ball_pos += ball_vel * dt
		collide_walls()
		collide_paddle()
		collide_bricks()
		if state != State.PLAYING:
			return


func collide_walls() -> void:
	if ball_pos.x < BALL_RADIUS:
		ball_pos.x = BALL_RADIUS
		ball_vel.x = absf(ball_vel.x)
	elif ball_pos.x > SCREEN.x - BALL_RADIUS:
		ball_pos.x = SCREEN.x - BALL_RADIUS
		ball_vel.x = -absf(ball_vel.x)

	if ball_pos.y < BALL_RADIUS:
		ball_pos.y = BALL_RADIUS
		ball_vel.y = absf(ball_vel.y)

	if ball_pos.y - BALL_RADIUS > SCREEN.y:
		lives -= 1
		if lives <= 0:
			state = State.LOST
		else:
			reset_ball()


func paddle_rect() -> Rect2:
	return Rect2(Vector2(paddle_x - PADDLE_SIZE.x / 2, PADDLE_Y), PADDLE_SIZE)


# 패들의 어느 부분에 맞았는지에 따라 튕겨 나가는 각도가 달라짐
func collide_paddle() -> void:
	if ball_vel.y <= 0:
		return
	var rect := paddle_rect()
	if not circle_hits_rect(ball_pos, rect):
		return
	var offset := clampf((ball_pos.x - paddle_x) / (PADDLE_SIZE.x / 2), -1.0, 1.0)
	ball_vel = Vector2.UP.rotated(offset * deg_to_rad(60)) * ball_vel.length()
	ball_pos.y = rect.position.y - BALL_RADIUS


func collide_bricks() -> void:
	for i in bricks.size():
		var rect: Rect2 = bricks[i]["rect"]
		if not circle_hits_rect(ball_pos, rect):
			continue

		# 덜 겹친 축 방향으로 반사
		var overlap_x := minf(ball_pos.x + BALL_RADIUS - rect.position.x, rect.end.x - (ball_pos.x - BALL_RADIUS))
		var overlap_y := minf(ball_pos.y + BALL_RADIUS - rect.position.y, rect.end.y - (ball_pos.y - BALL_RADIUS))
		var center := rect.get_center()
		if overlap_x < overlap_y:
			ball_vel.x = -absf(ball_vel.x) if ball_pos.x < center.x else absf(ball_vel.x)
		else:
			ball_vel.y = -absf(ball_vel.y) if ball_pos.y < center.y else absf(ball_vel.y)

		score += bricks[i]["points"]
		bricks.remove_at(i)
		ball_vel = ball_vel.normalized() * minf(ball_vel.length() * 1.02, BALL_MAX_SPEED)
		if bricks.is_empty():
			state = State.WON
		return


func circle_hits_rect(p: Vector2, rect: Rect2) -> bool:
	var closest := p.clamp(rect.position, rect.end)
	return p.distance_squared_to(closest) <= BALL_RADIUS * BALL_RADIUS


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, SCREEN), BG_COLOR)

	for b in bricks:
		draw_rect(b["rect"], b["color"])

	draw_rect(paddle_rect(), Color.WHITE)
	if state != State.LOST:
		draw_circle(ball_pos, BALL_RADIUS, Color.WHITE)

	var font := ThemeDB.fallback_font
	draw_string(font, Vector2(20, 40), "점수: %d" % score, HORIZONTAL_ALIGNMENT_LEFT, -1, 24)
	draw_string(font, Vector2(SCREEN.x - 220, 40), "목숨: %d" % lives, HORIZONTAL_ALIGNMENT_RIGHT, 200, 24)

	var message := ""
	match state:
		State.READY:
			message = "스페이스 또는 클릭으로 발사"
		State.WON:
			message = "클리어! 스페이스 또는 클릭으로 다시 시작"
		State.LOST:
			message = "게임 오버 - 스페이스 또는 클릭으로 다시 시작"
	if message != "":
		draw_string(font, Vector2(0, SCREEN.y * 0.65), message, HORIZONTAL_ALIGNMENT_CENTER, SCREEN.x, 30)
