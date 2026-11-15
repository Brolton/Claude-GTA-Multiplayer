extends CanvasLayer
## Multiplayer overlay (child "Hud" of the Net autoload): the event feed (joins, kills, chat), the
## session line in the corner, the player list (hold N) and the distance on the name tags.

const FEED_LINES := 6
const FEED_SECONDS := 7.0

var _root: Control = null
var _feed: VBoxContainer = null
var _status: Label = null
var _board: PanelContainer = null
var _board_text: RichTextLabel = null
var _fatal: Label = null
var _status_t: float = 0.0
var _built: bool = false


func _ready() -> void:
	layer = 60
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false


func on_session_boot() -> void:
	_build()
	visible = true
	_refresh_status()


func on_session_end() -> void:
	visible = false


func _build() -> void:
	if _built:
		return
	_built = true
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)
	_feed = VBoxContainer.new()
	_feed.anchor_left = 0.0
	_feed.anchor_top = 0.0
	_feed.offset_left = 28.0
	_feed.offset_top = 150.0
	_feed.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_feed.add_theme_constant_override("separation", 2)
	_root.add_child(_feed)
	_status = Label.new()
	_status.anchor_left = 1.0
	_status.anchor_right = 1.0
	_status.offset_left = -640.0
	_status.offset_right = -24.0
	_status.offset_top = 6.0
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_status.add_theme_font_size_override("font_size", 16)
	_status.add_theme_color_override("font_color", Color(1, 1, 1, 0.75))
	_status.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	_status.add_theme_constant_override("outline_size", 5)
	_status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_status)
	_board = PanelContainer.new()
	_board.set_anchors_preset(Control.PRESET_CENTER)
	_board.custom_minimum_size = Vector2(560, 120)
	_board.offset_left = -280.0
	_board.offset_right = 280.0
	_board.offset_top = -160.0
	_board.visible = false
	_board.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.03, 0.06, 0.12, 0.88)
	sb.set_corner_radius_all(10)
	sb.set_content_margin_all(18)
	_board.add_theme_stylebox_override("panel", sb)
	_root.add_child(_board)
	_board_text = RichTextLabel.new()
	_board_text.bbcode_enabled = true
	_board_text.fit_content = true
	_board_text.scroll_active = false
	_board_text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_board_text.add_theme_font_size_override("normal_font_size", 22)
	_board_text.add_theme_font_size_override("bold_font_size", 22)
	_board.add_child(_board_text)
	_fatal = Label.new()
	_fatal.set_anchors_preset(Control.PRESET_CENTER)
	_fatal.offset_left = -500.0
	_fatal.offset_right = 500.0
	_fatal.offset_top = -40.0
	_fatal.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_fatal.add_theme_font_size_override("font_size", 40)
	_fatal.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_fatal.add_theme_constant_override("outline_size", 10)
	_fatal.visible = false
	_root.add_child(_fatal)


## One line in the event feed.
func feed(text: String, color: Color = Color.WHITE) -> void:
	print("[Net] ", text)
	if not _built:
		return
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 20)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	l.add_theme_constant_override("outline_size", 6)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_feed.add_child(l)
	while _feed.get_child_count() > FEED_LINES:
		var old := _feed.get_child(0)
		_feed.remove_child(old)
		old.queue_free()
	var tw := l.create_tween()
	tw.tween_interval(FEED_SECONDS)
	tw.tween_property(l, "modulate:a", 0.0, 0.8)
	tw.tween_callback(l.queue_free)


func on_kill(victim: int, killer: int, cause: String, _weapon_id: String) -> void:
	var vn := Net.get_player_name(victim)
	if killer >= 0 and killer != victim and Net.players.has(killer):
		feed("%s  >  %s" % [Net.get_player_name(killer), vn], Net.peer_color(killer))
	elif cause == "fall":
		feed("%s fell" % vn, Color(0.85, 0.85, 0.85))
	elif cause == "drown":
		feed("%s drowned" % vn, Color(0.85, 0.85, 0.85))
	else:
		feed("%s is down" % vn, Color(0.85, 0.85, 0.85))


func show_fatal(text: String) -> void:
	_build()
	visible = true
	_fatal.text = text
	_fatal.visible = true


func _process(delta: float) -> void:
	if not visible or not _built:
		return
	_status_t -= delta
	if _status_t <= 0.0:
		_status_t = 0.5
		_refresh_status()
		_refresh_tags()
	var show := Input.is_physical_key_pressed(KEY_N) and not Game.is_input_locked()
	if show != _board.visible:
		_board.visible = show
		if show:
			_refresh_board()


func _refresh_status() -> void:
	if _status == null:
		return
	if Net.is_host():
		var addr := ""
		for a: Dictionary in Net.get_local_addresses():
			addr += "  %s" % str(a["address"])
		_status.text = "HOST · %d/%d ·%s · N = players" % [Net.players.size(), Net.max_players, addr]
	elif Net.is_client():
		_status.text = "%d players · ping %d ms · N = players" % [Net.players.size(), int(Net.rtt * 1000.0)]
	else:
		_status.text = ""


func _refresh_board() -> void:
	var t := "[b]PLAYERS[/b]\n"
	var ids: Array = Net.players.keys()
	ids.sort_custom(func(a: int, b: int) -> bool: return int((Net.players[a] as Dictionary)["slot"]) < int((Net.players[b] as Dictionary)["slot"]))
	for id: int in ids:
		var p: Dictionary = Net.players[id]
		var c := Net.slot_color(int(p["slot"])).to_html(false)
		t += "[color=#%s][b]%s[/b][/color]%s    kills %d   deaths %d   %s\n" % [c, str(p["name"]),
				" (host)" if id == 1 else "", int(p.get("kills", 0)), int(p.get("deaths", 0)),
				"" if id == 1 else "%d ms" % int(p.get("ping", 0))]
	_board_text.text = t


## Name tags show the distance once the other player is far away.
func _refresh_tags() -> void:
	if not Game.has_player():
		return
	var me := Game.get_player_position()
	for peer: int in Net.world.avatars:
		var a := Net.world.get_avatar(peer)
		if a == null or a._label == null:
			continue
		var d := a.get_net_position().distance_to(me)
		a._label.text = a.player_name if d < 40.0 else "%s  %dm" % [a.player_name, int(d)]
