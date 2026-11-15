extends CanvasLayer
## The multiplayer menu (child "Lobby" of the Net autoload).
##   * start menu, before the world is built: Single player / Host a game / Join a game
##   * in the running game (pause menu -> Multiplayer, or F6): who is here, the addresses friends
##     need, open the running single-player game to others, join another game, leave.
## Built in code with plain Controls so it works before any game system exists.

signal chosen(result: Dictionary)

var _ru: bool = false
var _panel: PanelContainer = null
var _name_edit: LineEdit = null
var _addr_edit: LineEdit = null
var _list: ItemList = null
var _status: Label = null
var _info: RichTextLabel = null
var _in_game: bool = false
var _open: bool = false
var _locked_input: bool = false
var _refresh_t: float = 0.0


func _ready() -> void:
	layer = 90
	process_mode = Node.PROCESS_MODE_ALWAYS
	_ru = OS.get_locale_language() == "ru"
	visible = false


func _t(en: String, ru: String) -> String:
	return ru if _ru else en


func is_open() -> bool:
	return _open


# =================================================================================================
# start menu
# =================================================================================================

## Shows the start menu and returns {"mode": "solo"|"host"|"join", "address": String}.
func run_boot_menu() -> Dictionary:
	_in_game = false
	_show()
	var result: Dictionary = await chosen
	return result


func close_boot_menu() -> void:
	if _open and not _in_game:
		_hide()


func set_status(text: String) -> void:
	if _status != null:
		_status.add_theme_color_override("font_color", Color(0.8, 0.9, 1.0))
		_status.text = text


func set_error(text: String) -> void:
	if _status != null:
		_status.add_theme_color_override("font_color", Color(1.0, 0.5, 0.45))
		_status.text = text


# =================================================================================================
# in-game menu
# =================================================================================================

func toggle_in_game() -> void:
	if _open:
		_hide()
	else:
		_in_game = true
		_show()


func _unhandled_key_input(event: InputEvent) -> void:
	if not Net.booted:
		return
	var k := event as InputEventKey
	if k == null or not k.pressed or k.echo:
		return
	if k.physical_keycode == KEY_F6:
		toggle_in_game()
		get_viewport().set_input_as_handled()
	elif k.physical_keycode == KEY_ESCAPE and _open and _in_game:
		_hide()
		get_viewport().set_input_as_handled()


# =================================================================================================
# building
# =================================================================================================

func _show() -> void:
	_rebuild()
	_open = true
	visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if _in_game and not _locked_input:
		_locked_input = true
		Game.lock_input()
	if not Net.is_active() or not _in_game:
		Net.discovery.start_scan()
		if not Net.discovery.games_changed.is_connected(_refresh_list):
			Net.discovery.games_changed.connect(_refresh_list)


func _hide() -> void:
	_open = false
	visible = false
	Net.discovery.stop_scan()
	if _locked_input:
		_locked_input = false
		Game.unlock_input()
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _button(text: String, cb: Callable, accent: bool = false) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 52)
	b.add_theme_font_size_override("font_size", 22)
	if accent:
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.98, 0.62, 0.3)
		sb.set_corner_radius_all(8)
		sb.set_content_margin_all(10)
		b.add_theme_stylebox_override("normal", sb)
		var sh := sb.duplicate() as StyleBoxFlat
		sh.bg_color = Color(1.0, 0.72, 0.42)
		b.add_theme_stylebox_override("hover", sh)
		b.add_theme_stylebox_override("focus", sh)
		b.add_theme_color_override("font_color", Color(0.05, 0.08, 0.14))
		b.add_theme_color_override("font_hover_color", Color(0.05, 0.08, 0.14))
		b.add_theme_color_override("font_focus_color", Color(0.05, 0.08, 0.14))
	b.pressed.connect(cb)
	return b


func _label(text: String, size: int = 20, color: Color = Color(0.85, 0.9, 1.0)) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l


func _rebuild() -> void:
	for c in get_children():
		c.queue_free()
	var bg := ColorRect.new()
	bg.color = Color(0.02, 0.04, 0.09, 1.0 if not _in_game else 0.72)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	_panel = PanelContainer.new()
	_panel.custom_minimum_size = Vector2(760, 0)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.1, 0.18, 0.97)
	sb.set_corner_radius_all(14)
	sb.set_content_margin_all(30)
	sb.border_color = Color(0.2, 0.75, 0.75, 0.6)
	sb.set_border_width_all(2)
	_panel.add_theme_stylebox_override("panel", sb)
	center.add_child(_panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	_panel.add_child(v)
	v.add_child(_label("HALCYON BAY", 44, Color(1.0, 0.85, 0.4)))
	v.add_child(_label(_t("Multiplayer", "Сетевая игра"), 22, Color(0.4, 0.9, 0.9)))
	v.add_child(HSeparator.new())
	if _in_game and Net.is_active():
		_build_session(v)
	else:
		_build_start(v)
	_status = _label("", 18)
	v.add_child(_status)
	_refresh_list()


func _build_start(v: VBoxContainer) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.add_child(_label(_t("Your name", "Ваше имя"), 20))
	_name_edit = LineEdit.new()
	_name_edit.text = Net.player_name
	_name_edit.max_length = 18
	_name_edit.custom_minimum_size = Vector2(320, 44)
	_name_edit.add_theme_font_size_override("font_size", 22)
	row.add_child(_name_edit)
	v.add_child(row)
	if not _in_game:
		v.add_child(_button(_t("Single player", "Одиночная игра"), _on_solo))
	v.add_child(_button(_t("Host a game  (others join you)", "Создать игру  (к вам подключаются)"), _on_host, true))
	v.add_child(HSeparator.new())
	v.add_child(_label(_t("Games found on your network / Tailscale:", "Найденные игры (домашняя сеть / Tailscale):"), 20))
	_list = ItemList.new()
	_list.custom_minimum_size = Vector2(0, 130)
	_list.add_theme_font_size_override("font_size", 20)
	_list.item_activated.connect(_on_list_activated)
	_list.item_selected.connect(_on_list_selected)
	v.add_child(_list)
	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", 12)
	_addr_edit = LineEdit.new()
	_addr_edit.placeholder_text = _t("Host address, e.g. 192.168.1.20 or 100.x.y.z", "Адрес хоста, например 192.168.1.20 или 100.x.y.z")
	_addr_edit.text = Net.last_address
	_addr_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_addr_edit.custom_minimum_size = Vector2(0, 44)
	_addr_edit.add_theme_font_size_override("font_size", 20)
	_addr_edit.text_submitted.connect(func(_s: String) -> void: _on_join())
	row2.add_child(_addr_edit)
	var jb := _button(_t("Join", "Подключиться"), _on_join, true)
	jb.custom_minimum_size = Vector2(190, 48)
	row2.add_child(jb)
	v.add_child(row2)
	if _in_game:
		v.add_child(_label(_t("Joining restarts the game as a client.", "При подключении игра перезапустится как клиент."), 16, Color(0.65, 0.7, 0.8)))
		v.add_child(_button(_t("Back", "Назад"), _hide))
	else:
		v.add_child(_button(_t("Quit", "Выход"), func() -> void: get_tree().quit()))


func _build_session(v: VBoxContainer) -> void:
	_info = RichTextLabel.new()
	_info.bbcode_enabled = true
	_info.fit_content = true
	_info.scroll_active = false
	_info.add_theme_font_size_override("normal_font_size", 20)
	_info.add_theme_font_size_override("bold_font_size", 20)
	v.add_child(_info)
	_refresh_info()
	if Net.is_host():
		v.add_child(_button(_t("Stop hosting (back to single player)", "Закрыть игру для других (одиночная)"), func() -> void:
			Net.leave_game(false)
			_hide()))
	else:
		v.add_child(_button(_t("Leave the game", "Покинуть игру"), func() -> void: Net.leave_game(true)))
	v.add_child(_button(_t("Back", "Назад"), _hide))


func _refresh_info() -> void:
	if _info == null or not is_instance_valid(_info):
		return
	var t := ""
	if Net.is_host():
		t += _t("[b]You are hosting.[/b] Friends join with one of these addresses:\n", "[b]Вы хост.[/b] Друзья подключаются по одному из адресов:\n")
		for a: Dictionary in Net.get_local_addresses():
			t += "   [color=#ffd966][b]%s[/b][/color]   (%s)\n" % [str(a["address"]), str(a["kind"])]
		t += _t("On the same Wi-Fi the game appears in their list by itself.\n", "В одной сети Wi-Fi игра сама появится у них в списке.\n")
	else:
		t += _t("[b]Connected[/b], ping %d ms\n", "[b]Подключено[/b], пинг %d мс\n") % int(Net.rtt * 1000.0)
	t += "\n" + _t("[b]Players[/b]\n", "[b]Игроки[/b]\n")
	for id: int in Net.players:
		var p: Dictionary = Net.players[id]
		t += "   [color=#%s]%s[/color]%s\n" % [Net.slot_color(int(p["slot"])).to_html(false), str(p["name"]),
				_t(" (host)", " (хост)") if id == 1 else ""]
	_info.text = t


func _process(delta: float) -> void:
	if not _open:
		return
	_refresh_t -= delta
	if _refresh_t <= 0.0:
		_refresh_t = 1.0
		_refresh_info()


func _refresh_list() -> void:
	if _list == null or not is_instance_valid(_list):
		return
	var sel := ""
	var s := _list.get_selected_items()
	if not s.is_empty():
		sel = str(_list.get_item_metadata(s[0]))
	_list.clear()
	for g: Dictionary in Net.discovery.get_games():
		var line := "%s   -   %s   (%d/%d, %s)" % [str(g["name"]), str(g["address"]), int(g["players"]), int(g["max"]), str(g["kind"])]
		if int(g["version"]) != NetProto.VERSION:
			line += _t("   [different version]", "   [другая версия]")
		var i := _list.add_item(line)
		_list.set_item_metadata(i, str(g["address"]))
		if str(g["address"]) == sel:
			_list.select(i)
	if _list.item_count == 0:
		var i2 := _list.add_item(_t("searching ...", "поиск ..."))
		_list.set_item_disabled(i2, true)
		_list.set_item_metadata(i2, "")


func _take_name() -> void:
	if _name_edit != null and is_instance_valid(_name_edit):
		Net.player_name = Net.sanitize_name(_name_edit.text)
		Net.save_config()


func _on_solo() -> void:
	_take_name()
	chosen.emit({"mode": "solo"})


func _on_host() -> void:
	_take_name()
	if _in_game:
		if Net.host_game():
			_rebuild()
		else:
			set_error(Net.last_error)
		return
	chosen.emit({"mode": "host"})


func _on_list_selected(i: int) -> void:
	var a := str(_list.get_item_metadata(i))
	if a != "" and _addr_edit != null:
		_addr_edit.text = a


func _on_list_activated(i: int) -> void:
	_on_list_selected(i)
	_on_join()


func _on_join() -> void:
	_take_name()
	var address := _addr_edit.text.strip_edges() if _addr_edit != null else ""
	if address == "":
		set_error(_t("Type the host address or pick a game from the list.", "Введите адрес хоста или выберите игру из списка."))
		return
	if _in_game:
		Net.restart_process(PackedStringArray(["--join=" + address, "--name=" + Net.player_name]))
		return
	chosen.emit({"mode": "join", "address": address})
