extends Node
## Autoload "Net": the multiplayer session (docs/MULTIPLAYER.md).
##
##   SOLO    the single-player game, untouched (every hook in the game checks Net.is_active()).
##   HOST    the single-player game + an ENet server. The host simulates the ambient world (traffic,
##           pedestrians, emergency services) around EVERY player and replicates it.
##   CLIENT  simulates only what it owns - its player, the vehicle it drives, the police that chase
##           it - and shows everything else as puppets driven by snapshots from the host.
##
## Topology: a star. Clients only talk to the host; the host relays. Every replicated body has one
## AUTHORITY peer that simulates it; all other peers hold a puppet. Whoever causes damage detects the
## hit on its own machine and sends it to the authority of the victim (Net.world.forward_damage).
##
## The mode is fixed for the lifetime of the process: joining / leaving a game restarts the process
## (OS.set_restart_on_exit) so that a world is never converted while it runs.
##
## Command line (after `--`):
##   --host                 start as host            --port=N        game port (default 24565)
##   --join=ADDR[:PORT]     start as client          --name=NAME     player name
##   --solo                 skip the start menu      --max-players=N host: slots (2..8, default 4)

signal session_started()
signal session_ended(reason: String)
signal roster_changed()
signal player_joined(info: Dictionary)
signal player_left(info: Dictionary)
signal chat_received(peer: int, text: String)
signal kill_reported(victim: int, killer_ref: Array, cause: String, weapon_id: String)

enum Mode { SOLO, HOST, CLIENT }

const CONFIG_PATH := "user://multiplayer.cfg"
const SNAPSHOT_HZ := 20.0
const PING_INTERVAL := 1.0
const CONNECT_TIMEOUT := 8.0
const WELCOME_TIMEOUT := 8.0
## Systems a client never builds: the host simulates them and replicates the result.
const CLIENT_DISABLED_SYSTEMS: Array[String] = ["traffic", "emergency", "taxi"]
const NetWorldScript := preload("res://gta/code/net/net_world.gd")
const NetCombatScript := preload("res://gta/code/net/net_combat.gd")
const NetDiscoveryScript := preload("res://gta/code/net/net_discovery.gd")
const NetHudScript := preload("res://gta/code/net/net_hud.gd")
const NetLobbyScript := preload("res://gta/code/net/net_lobby.gd")

var mode: int = Mode.SOLO
var my_id: int = 1                       ## multiplayer unique id (1 = host)
var my_slot: int = 0                     ## 0 = host, 1.. = clients in join order
var player_name: String = "Player"
var port: int = NetProto.GAME_PORT
var max_players: int = 4
var last_address: String = ""
var recent_addresses: PackedStringArray = []
var lowspec_choice: int = -1             ## -1 auto, 0 off, 1 on (see net_lowspec.gd)
## peer id -> {id, slot, name, ready, ping, kills, deaths, appearance}
var players: Dictionary = {}
var world: NetWorldScript = null         ## entity replication
var combat: NetCombatScript = null       ## damage routing + cosmetic combat events
var discovery: NetDiscoveryScript = null
var hud: NetHudScript = null
var lobby: NetLobbyScript = null
var last_error: String = ""
var session_time_offset: float = 0.0     ## client: host_time = local_time + offset (seconds)
var rtt: float = 0.0                     ## client: smoothed round trip to the host (seconds)
var booted: bool = false                 ## the world is built and the local player exists
var stats := {"snap_out": 0, "snap_in": 0, "bytes_out": 0, "bytes_in": 0, "ev_out": 0, "ev_in": 0}

var _cmd_mode: String = ""               ## "", "host", "join", "solo"
var _cmd_address: String = ""
var _enet: ENetMultiplayerPeer = null
var _snap_t: float = 0.0
var _ping_t: float = 0.0
var _best_rtt: float = 1.0e9
var _offset_samples: int = 0
var _welcome: Dictionary = {}
var _welcomed: bool = false
var _connect_state: int = 0              ## 0 idle, 1 connecting, 2 connected, -1 failed
var _world_t: float = 0.0
var _quitting: bool = false
var _start_usec: int = 0


func _enter_tree() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_start_usec = Time.get_ticks_usec()
	_load_config()
	_parse_cmdline()


func _ready() -> void:
	world = NetWorldScript.new()
	world.name = "World"
	add_child(world)
	combat = NetCombatScript.new()
	combat.name = "Combat"
	add_child(combat)
	discovery = NetDiscoveryScript.new()
	discovery.name = "Discovery"
	add_child(discovery)
	hud = NetHudScript.new()
	hud.name = "Hud"
	add_child(hud)
	lobby = NetLobbyScript.new()
	lobby.name = "Lobby"
	add_child(lobby)
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	var sm := multiplayer as SceneMultiplayer
	if sm != null:
		sm.server_relay = false          # a strict star: the host relays what clients need
		sm.allow_object_decoding = false


# =================================================================================================
# queries
# =================================================================================================

## A session is running (host or client).
func is_active() -> bool:
	return mode != Mode.SOLO


func is_host() -> bool:
	return mode == Mode.HOST


func is_client() -> bool:
	return mode == Mode.CLIENT


## This peer decides about the ambient world (true in single player too).
func is_world_authority() -> bool:
	return mode != Mode.CLIENT


## Somebody else is in the session with us (the host with no clients behaves like single player).
func has_remote_players() -> bool:
	return mode != Mode.SOLO and players.size() > 1


## Seconds of local monotonic time.
func local_time() -> float:
	return float(Time.get_ticks_usec() - _start_usec) / 1000000.0


## Session clock: the host's local_time() as seen from this peer.
func host_time() -> float:
	return local_time() + session_time_offset


func get_player_info(peer: int) -> Dictionary:
	return players.get(peer, {})


func get_player_name(peer: int) -> String:
	var info: Dictionary = players.get(peer, {})
	return str(info.get("name", "Player %d" % peer))


## Peer ids of the other players that finished loading.
func remote_peers() -> Array[int]:
	var out: Array[int] = []
	for id: int in players:
		if id != my_id and bool((players[id] as Dictionary).get("ready", false)):
			out.append(id)
	return out


## Per-slot player colour (name tags, minimap blips, kill feed).
func slot_color(slot: int) -> Color:
	const COLORS := [Color(1.0, 0.82, 0.25), Color(0.35, 0.8, 1.0), Color(1.0, 0.45, 0.4), Color(0.5, 0.95, 0.5),
			Color(0.85, 0.55, 1.0), Color(1.0, 0.65, 0.2), Color(0.4, 0.95, 0.85), Color(1.0, 0.6, 0.8)]
	return COLORS[posmod(slot, COLORS.size())]


func peer_color(peer: int) -> Color:
	return slot_color(int((players.get(peer, {}) as Dictionary).get("slot", 0)))


## Local IPv4 addresses a friend could use to reach this machine (LAN first, tailnet 100.x marked).
func get_local_addresses() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for a: String in IP.get_local_addresses():
		if a.contains(":") or a.begins_with("127.") or a.begins_with("169.254."):
			continue
		var kind := "LAN"
		var parts := a.split(".")
		if parts.size() == 4 and int(parts[0]) == 100 and int(parts[1]) >= 64 and int(parts[1]) <= 127:
			kind = "Tailscale"
		out.append({"address": a, "kind": kind})
	out.sort_custom(func(x: Dictionary, y: Dictionary) -> bool: return str(x["kind"]) < str(y["kind"]))
	return out


# =================================================================================================
# configuration
# =================================================================================================

func _load_config() -> void:
	var cfg := ConfigFile.new()
	var def_name := OS.get_environment("USERNAME")
	if def_name == "":
		def_name = OS.get_environment("USER")
	if def_name == "":
		def_name = "Player"
	player_name = def_name
	if cfg.load(CONFIG_PATH) == OK:
		player_name = str(cfg.get_value("mp", "name", def_name))
		last_address = str(cfg.get_value("mp", "last_address", ""))
		port = int(cfg.get_value("mp", "port", NetProto.GAME_PORT))
		max_players = clampi(int(cfg.get_value("mp", "max_players", 4)), 2, NetProto.MAX_PLAYERS)
		lowspec_choice = int(cfg.get_value("mp", "lowspec", -1))
		var rec: Variant = cfg.get_value("mp", "recent", PackedStringArray())
		if rec is PackedStringArray:
			recent_addresses = rec
	player_name = sanitize_name(player_name)


func save_config() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("mp", "name", player_name)
	cfg.set_value("mp", "last_address", last_address)
	cfg.set_value("mp", "port", port)
	cfg.set_value("mp", "max_players", max_players)
	cfg.set_value("mp", "lowspec", lowspec_choice)
	cfg.set_value("mp", "recent", recent_addresses)
	cfg.save(CONFIG_PATH)


static func sanitize_name(n: String) -> String:
	var s := n.strip_edges().replace("\n", " ").replace("\t", " ")
	if s.length() > 18:
		s = s.substr(0, 18)
	return s if s != "" else "Player"


func _parse_cmdline() -> void:
	for a: String in OS.get_cmdline_user_args():
		if a == "--host":
			_cmd_mode = "host"
		elif a.begins_with("--join="):
			_cmd_mode = "join"
			_cmd_address = a.substr(7)
		elif a == "--solo":
			_cmd_mode = "solo"
		elif a.begins_with("--name="):
			player_name = sanitize_name(a.substr(7))
		elif a.begins_with("--port="):
			port = clampi(int(a.substr(7)), 1024, 65535)
		elif a.begins_with("--max-players="):
			max_players = clampi(int(a.substr(14)), 2, NetProto.MAX_PLAYERS)
		elif a.begins_with("--test=") and _cmd_mode == "":
			_cmd_mode = "solo"            # automated tests never wait in the start menu


# =================================================================================================
# boot integration (called by core/main.gd)
# =================================================================================================

## Before the world is built: decide the mode (command line or the start menu) and, for a client,
## connect and shake hands. Returns when the game may boot.
func pre_boot() -> void:
	var choice := _cmd_mode
	var address := _cmd_address
	while true:
		if choice == "":
			if DisplayServer.get_name() == "headless":
				choice = "solo"
			else:
				var picked: Dictionary = await _run_lobby()
				choice = str(picked.get("mode", "solo"))
				address = str(picked.get("address", ""))
		if choice == "host":
			if host_game():
				break
			_show_boot_error("Could not host a game: %s" % last_error)
		elif choice == "join":
			_set_boot_status("Connecting to %s ..." % address)
			if await join_game(address):
				break
			_show_boot_error("Could not join %s: %s" % [address, last_error])
		else:
			break
		if DisplayServer.get_name() == "headless" or _cmd_mode != "" and Game.flags.has("no-lobby"):
			push_error("[Net] %s" % last_error)
			break
		choice = ""                       # back to the menu
	_close_lobby()
	if mode == Mode.CLIENT:
		for s: String in CLIENT_DISABLED_SYSTEMS:
			Game.disabled_systems[s] = true
		# a client never continues (or overwrites) its single-player save
		Game.flags["new-game"] = true
		SaveSystem.set("_new_game", true)
		SaveSystem.autosave_enabled = false
	print("[Net] mode=%s name=%s slot=%d" % [Mode.keys()[mode], player_name, my_slot])


## After the world is built and the local player exists.
func post_boot() -> void:
	booted = true
	NetLowspec.apply_boot_preset()
	NetLowspec.apply_viewport()
	if mode == Mode.SOLO:
		return
	world.on_session_boot()
	combat.on_session_boot()
	hud.on_session_boot()
	if mode == Mode.CLIENT:
		var peds := Game.get_system("peds")
		if peds != null:
			peds.call("set_enabled", false)      # no ambient pedestrians of our own: the host's arrive as puppets
		_apply_world_state(_welcome.get("world", []))
		_tighten_timeouts()
		send_event_to(1, NetProto.EV_APPEARANCE, [my_id, _local_appearance()])
		_rpc_ready.rpc_id(1)
	elif mode == Mode.HOST:
		_mark_ready(1)
	session_started.emit()


## Where a joining player appears: beside the host's player (never inside it), else the start spot.
func get_spawn_transform() -> Transform3D:
	var base := Game.get_location("spawn_start")
	if mode != Mode.CLIENT:
		return base
	var sp: Variant = _welcome.get("spawn", null)
	if sp is Transform3D:
		return sp
	return Transform3D(base.basis, base.origin + base.basis.x * (1.6 * float(my_slot)))


func _run_lobby() -> Dictionary:
	return await lobby.run_boot_menu()


## The multiplayer menu of the running game (pause menu entry, F6).
func open_menu() -> void:
	if lobby != null and not lobby.is_open():
		lobby.toggle_in_game()


func _close_lobby() -> void:
	if lobby != null and is_instance_valid(lobby):
		lobby.close_boot_menu()


func _set_boot_status(text: String) -> void:
	print("[Net] ", text)
	if lobby != null and is_instance_valid(lobby):
		lobby.set_status(text)


func _show_boot_error(text: String) -> void:
	push_warning("[Net] " + text)
	if lobby != null and is_instance_valid(lobby):
		lobby.set_error(text)


# =================================================================================================
# host / join / leave
# =================================================================================================

func host_game() -> bool:
	if mode != Mode.SOLO:
		last_error = "a session is already running"
		return false
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, NetProto.MAX_PLAYERS - 1, 3)
	if err != OK:
		last_error = "port %d is busy (error %d)" % [port, err]
		return false
	_enet = peer
	multiplayer.multiplayer_peer = peer
	mode = Mode.HOST
	my_id = 1
	my_slot = 0
	session_time_offset = 0.0
	players.clear()
	players[1] = {"id": 1, "slot": 0, "name": player_name, "ready": booted, "ping": 0, "kills": 0, "deaths": 0,
			"appearance": {}}
	discovery.start_host()
	save_config()
	print("[Net] hosting on UDP %d (%s)" % [port, str(get_local_addresses())])
	if booted:
		# opened from the pause menu of a running single-player game
		world.on_session_boot()
		combat.on_session_boot()
		hud.on_session_boot()
		session_started.emit()
	roster_changed.emit()
	return true


## Connects and shakes hands. True once the host has welcomed us (the world is NOT built yet).
func join_game(address: String) -> bool:
	if mode != Mode.SOLO:
		last_error = "a session is already running"
		return false
	var host_addr := address.strip_edges()
	var host_port := port
	if host_addr.contains(":") and not host_addr.contains("::"):
		var cut := host_addr.rfind(":")
		host_port = clampi(int(host_addr.substr(cut + 1)), 1, 65535)
		host_addr = host_addr.substr(0, cut)
	if host_addr == "":
		last_error = "no address"
		return false
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(host_addr, host_port, 3)
	if err != OK:
		last_error = "cannot open a connection (error %d)" % err
		return false
	_enet = peer
	_connect_state = 1
	_welcomed = false
	multiplayer.multiplayer_peer = peer
	var t0 := Time.get_ticks_msec()
	while _connect_state == 1 and Time.get_ticks_msec() - t0 < int(CONNECT_TIMEOUT * 1000.0):
		await get_tree().process_frame
	if _connect_state != 2:
		last_error = "no answer (is the host running, and is UDP port %d allowed through its firewall?)" % host_port
		_drop_peer()
		return false
	_loosen_timeouts()
	_rpc_hello.rpc_id(1, {"proto": NetProto.VERSION, "name": player_name})
	t0 = Time.get_ticks_msec()
	while not _welcomed and _connect_state == 2 and Time.get_ticks_msec() - t0 < int(WELCOME_TIMEOUT * 1000.0):
		await get_tree().process_frame
	if not _welcomed:
		if last_error == "":
			last_error = "the host did not answer the handshake"
		_drop_peer()
		return false
	mode = Mode.CLIENT
	my_id = multiplayer.get_unique_id()
	my_slot = int(_welcome.get("slot", 1))
	_set_roster(_welcome.get("roster", []))
	session_time_offset = float(_welcome.get("time", 0.0)) - local_time()
	last_address = address.strip_edges()
	var rec := Array(recent_addresses)
	rec.erase(last_address)
	rec.push_front(last_address)
	recent_addresses = PackedStringArray(rec.slice(0, 6))
	save_config()
	return true


## Leave the session. A client (and a host that asks for it) restarts the process into `next_args`.
func leave_game(restart: bool = true, next_args: PackedStringArray = PackedStringArray()) -> void:
	if mode == Mode.SOLO and not restart:
		return
	var was := mode
	_drop_peer()
	if was == Mode.HOST and not restart:
		# back to plain single player without a restart: the world is ours anyway
		mode = Mode.SOLO
		world.on_session_end()
		combat.on_session_end()
		hud.on_session_end()
		players.clear()
		discovery.stop_host()
		session_ended.emit("stopped")
		roster_changed.emit()
		return
	restart_process(next_args)


## Quit and start again with `args` after the `--` (join / leave always pass through here).
func restart_process(args: PackedStringArray = PackedStringArray()) -> void:
	if _quitting:
		return
	_quitting = true
	var keep := PackedStringArray()
	var engine_args := OS.get_cmdline_args()
	for i in engine_args.size():
		var a := engine_args[i]
		if a == "--":
			break
		keep.append(a)
	var full := keep.duplicate()
	if not args.is_empty():
		full.append("--")
		full.append_array(args)
	OS.set_restart_on_exit(true, full)
	get_tree().quit()


func _drop_peer() -> void:
	if _enet != null:
		_enet.close()
	_enet = null
	_connect_state = 0
	multiplayer.multiplayer_peer = null


func _loosen_timeouts() -> void:
	_set_timeouts(32, 20000, 90000)       # long hitches while a world loads must not drop the peer


func _tighten_timeouts() -> void:
	_set_timeouts(32, 6000, 20000)


func _set_timeouts(limit: int, t_min: int, t_max: int) -> void:
	if _enet == null:
		return
	if mode == Mode.HOST:
		for id: int in multiplayer.get_peers():
			var p := _enet.get_peer(id)
			if p != null:
				p.set_timeout(limit, t_min, t_max)
	else:
		var sp := _enet.get_peer(1)
		if sp != null:
			sp.set_timeout(limit, t_min, t_max)


# =================================================================================================
# connection callbacks
# =================================================================================================

func _on_connected_to_server() -> void:
	_connect_state = 2


func _on_connection_failed() -> void:
	_connect_state = -1


func _on_server_disconnected() -> void:
	if _quitting:
		return
	print("[Net] the host closed the session")
	if mode == Mode.CLIENT and booted:
		hud.show_fatal("The host has left the game")
		await get_tree().create_timer(2.5, true, false, true).timeout
		leave_game(true)
	else:
		last_error = "the host closed the connection"
		_connect_state = -1


func _on_peer_connected(id: int) -> void:
	if mode != Mode.HOST:
		return
	var p := _enet.get_peer(id) if _enet != null else null
	if p != null:
		p.set_timeout(32, 20000, 90000)   # generous until it reports ready
	print("[Net] peer %d connected" % id)


func _on_peer_disconnected(id: int) -> void:
	if mode != Mode.HOST or not players.has(id):
		return
	var info: Dictionary = players[id]
	print("[Net] %s left" % str(info.get("name", id)))
	players.erase(id)
	world.on_peer_left(id)
	_broadcast_roster()
	player_left.emit(info)
	hud.feed("%s left the game" % str(info.get("name", "Player")), Color(0.8, 0.8, 0.8))
	_host_notify_all("%s left the game" % str(info.get("name", "Player")), "info", id)


# =================================================================================================
# handshake RPCs
# =================================================================================================

@rpc("any_peer", "call_remote", "reliable", NetProto.CH_EVENTS)
func _rpc_hello(info: Dictionary) -> void:
	if mode != Mode.HOST:
		return
	var id := multiplayer.get_remote_sender_id()
	if int(info.get("proto", -1)) != NetProto.VERSION:
		_rpc_refuse.rpc_id(id, "different game version (host %d, you %d) - both need the same build" % [NetProto.VERSION, int(info.get("proto", -1))])
		return
	if players.size() >= max_players:
		_rpc_refuse.rpc_id(id, "the game is full (%d players)" % max_players)
		return
	var slot := 1
	var used := {}
	for pid: int in players:
		used[int((players[pid] as Dictionary)["slot"])] = true
	while used.has(slot):
		slot += 1
	var pname := _unique_name(sanitize_name(str(info.get("name", "Player"))))
	players[id] = {"id": id, "slot": slot, "name": pname, "ready": false, "ping": 0, "kills": 0, "deaths": 0,
			"appearance": {}}
	var spawn := _spawn_for_slot(slot)
	_rpc_welcome.rpc_id(id, {
		"slot": slot, "roster": _roster_array(), "time": local_time(), "world": _world_state(),
		"spawn": spawn, "max_players": max_players,
	})
	_broadcast_roster()


@rpc("authority", "call_remote", "reliable", NetProto.CH_EVENTS)
func _rpc_welcome(data: Dictionary) -> void:
	_welcome = data
	_welcomed = true


@rpc("authority", "call_remote", "reliable", NetProto.CH_EVENTS)
func _rpc_refuse(reason: String) -> void:
	last_error = reason
	_connect_state = -1


@rpc("any_peer", "call_remote", "reliable", NetProto.CH_EVENTS)
func _rpc_ready() -> void:
	if mode != Mode.HOST:
		return
	var id := multiplayer.get_remote_sender_id()
	if not players.has(id):
		return
	var p := _enet.get_peer(id) if _enet != null else null
	if p != null:
		p.set_timeout(32, 6000, 20000)
	_mark_ready(id)
	var info: Dictionary = players[id]
	hud.feed("%s joined the game" % str(info["name"]), peer_color(id))
	_host_notify_all("%s joined the game" % str(info["name"]), "good", id)
	world.on_peer_ready(id)
	player_joined.emit(info)


func _mark_ready(id: int) -> void:
	if players.has(id):
		(players[id] as Dictionary)["ready"] = true
	if mode == Mode.HOST:
		_broadcast_roster()


func _unique_name(n: String) -> String:
	var out := n
	var i := 2
	var taken := true
	while taken:
		taken = false
		for pid: int in players:
			if str((players[pid] as Dictionary)["name"]) == out:
				taken = true
				out = "%s %d" % [n, i]
				i += 1
				break
	return out


func _spawn_for_slot(slot: int) -> Transform3D:
	# beside the host's player when it stands on dry ground, else the start spot
	var base := Game.get_location("spawn_start")
	var p := Game.player
	if p != null and is_instance_valid(p) and p.is_inside_tree() and Game.get_player_vehicle() == null \
			and p.get("is_dead") != true and p.get("is_swimming") != true and p.get("grounded") == true:
		base = Transform3D(Basis(Vector3.UP, p.global_rotation.y), p.global_position)
	var side := 1.0 if slot % 2 == 1 else -1.0
	var off := base.basis.x * (1.4 * side * ceilf(float(slot) / 2.0)) + base.basis.z * 1.2
	var pos := base.origin + off
	pos.y = maxf(Game.ground_height(pos.x, pos.z), base.origin.y - 1.5) + 0.2 if Game.world != null else base.origin.y
	if absf(pos.y - base.origin.y) > 2.5:
		pos = base.origin + base.basis.z * 1.0     # a ledge / wall next to the host: stay close behind
	return Transform3D(base.basis, pos)


# --- roster -----------------------------------------------------------------------------------------

func _roster_array() -> Array:
	var out: Array = []
	for id: int in players:
		var p: Dictionary = players[id]
		out.append([id, int(p["slot"]), str(p["name"]), bool(p["ready"]), int(p.get("ping", 0)),
				int(p.get("kills", 0)), int(p.get("deaths", 0))])
	return out


func _broadcast_roster() -> void:
	if mode != Mode.HOST:
		return
	var r := _roster_array()
	for id: int in multiplayer.get_peers():
		if players.has(id):
			_rpc_roster.rpc_id(id, r)
	roster_changed.emit()


@rpc("authority", "call_remote", "reliable", NetProto.CH_EVENTS)
func _rpc_roster(r: Array) -> void:
	_set_roster(r)


func _set_roster(r: Variant) -> void:
	if not (r is Array):
		return
	var seen := {}
	for e: Variant in r:
		if not (e is Array) or (e as Array).size() < 7:
			continue
		var a := e as Array
		var id := int(a[0])
		seen[id] = true
		var old: Dictionary = players.get(id, {})
		var was_ready := bool(old.get("ready", false))
		players[id] = {"id": id, "slot": int(a[1]), "name": str(a[2]), "ready": bool(a[3]), "ping": int(a[4]),
				"kills": int(a[5]), "deaths": int(a[6]), "appearance": old.get("appearance", {})}
		if booted and bool(a[3]) and not was_ready and id != my_id:
			player_joined.emit(players[id])
	for id: int in players.keys():
		if not seen.has(id):
			var info: Dictionary = players[id]
			players.erase(id)
			if booted:
				world.on_peer_left(id)
				player_left.emit(info)
	roster_changed.emit()


# =================================================================================================
# events (reliable)
# =================================================================================================

## Send a reliable event to the host (client) or to every ready client (host).
func send_event(kind: int, args: Array) -> void:
	if mode == Mode.SOLO:
		return
	if mode == Mode.CLIENT:
		_send_ev(1, kind, args, my_id)
	else:
		for id: int in remote_peers():
			_send_ev(id, kind, args, 1)


## Send a reliable event to one peer (through the host when we are a client).
func send_event_to(peer: int, kind: int, args: Array) -> void:
	if mode == Mode.SOLO or peer == my_id:
		return
	if mode == Mode.CLIENT:
		# clients only reach the host; the host routes by event kind
		_send_ev(1, kind, args, my_id)
	elif players.has(peer):
		_send_ev(peer, kind, args, 1)


func _send_ev(to: int, kind: int, args: Array, origin: int) -> void:
	stats["ev_out"] = int(stats["ev_out"]) + 1
	if NetProto.FX_EVENTS.has(kind):
		_rpc_fx.rpc_id(to, kind, args, origin)
	else:
		_rpc_ev.rpc_id(to, kind, args, origin)


@rpc("any_peer", "call_remote", "reliable", NetProto.CH_EVENTS)
func _rpc_ev(kind: int, args: Array, origin: int) -> void:
	_receive_event(kind, args, origin)


@rpc("any_peer", "call_remote", "reliable", NetProto.CH_FX)
func _rpc_fx(kind: int, args: Array, origin: int) -> void:
	_receive_event(kind, args, origin)


func _receive_event(kind: int, args: Array, origin: int) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if mode == Mode.HOST:
		if not players.has(sender):
			return
		origin = sender                   # never trust a client about who it is
	elif mode == Mode.CLIENT:
		if sender != 1:
			return
	else:
		return
	stats["ev_in"] = int(stats["ev_in"]) + 1
	if not booted:
		return
	_handle_event(kind, args, origin)
	if mode == Mode.HOST and NetProto.RELAY_ALL.has(kind):
		for id: int in remote_peers():
			if id != origin:
				_send_ev(id, kind, args, origin)


func _handle_event(kind: int, a: Array, origin: int) -> void:
	match kind:
		NetProto.EV_SPAWN, NetProto.EV_DESPAWN, NetProto.EV_AUTH, NetProto.EV_CLAIM, NetProto.EV_RELEASE, \
		NetProto.EV_DENY, NetProto.EV_JACK, NetProto.EV_EJECT, NetProto.EV_KNOCK, NetProto.EV_VEH_STATE, \
		NetProto.EV_NPC_STATE, NetProto.EV_TRAM:
			world.handle_event(kind, a, origin)
		NetProto.EV_DAMAGE, NetProto.EV_ANIM, NetProto.EV_SHOT, NetProto.EV_PROJECTILE, NetProto.EV_EXPLOSION, \
		NetProto.EV_SOUND, NetProto.EV_CRIME:
			combat.handle_event(kind, a, origin)
		NetProto.EV_KILL:
			if a.size() >= 4:
				_on_kill(int(a[0]), a[1], str(a[2]), str(a[3]))
		NetProto.EV_RESPAWN:
			if a.size() >= 2:
				world.on_player_respawned(int(a[0]), a[1])
		NetProto.EV_APPEARANCE:
			if a.size() >= 2 and a[1] is Dictionary:
				var peer := origin if mode == Mode.HOST else int(a[0])
				if players.has(peer):
					(players[peer] as Dictionary)["appearance"] = a[1]
				world.on_player_appearance(peer, a[1])
		NetProto.EV_CHAT:
			if a.size() >= 2:
				var peer2 := origin if mode == Mode.HOST else int(a[0])
				var text := str(a[1]).substr(0, 160)
				chat_received.emit(peer2, text)
				hud.feed("%s: %s" % [get_player_name(peer2), text], peer_color(peer2))
		NetProto.EV_WORLD:
			_apply_world_state(a)
		NetProto.EV_NOTIFY:
			if a.size() >= 2:
				hud.feed(str(a[0]), Color(0.85, 0.9, 1.0))


func _host_notify_all(text: String, kind: String, except: int = 0) -> void:
	for id: int in remote_peers():
		if id != except:
			_send_ev(id, NetProto.EV_NOTIFY, [text, kind], 1)


func send_chat(text: String) -> void:
	var t := text.strip_edges().substr(0, 160)
	if t == "" or mode == Mode.SOLO:
		return
	send_event(NetProto.EV_CHAT, [my_id, t])
	chat_received.emit(my_id, t)
	hud.feed("%s: %s" % [player_name, t], peer_color(my_id))


# --- kills / score ----------------------------------------------------------------------------------

## The local player died: tell everybody who did it.
func report_local_death(killer_ref: Array, cause: String, weapon_id: String) -> void:
	if mode == Mode.SOLO:
		return
	send_event(NetProto.EV_KILL, [my_id, killer_ref, cause, weapon_id])
	_on_kill(my_id, killer_ref, cause, weapon_id)


func _on_kill(victim: int, killer_ref: Variant, cause: String, weapon_id: String) -> void:
	var kref: Array = killer_ref if killer_ref is Array else []
	if players.has(victim):
		(players[victim] as Dictionary)["deaths"] = int((players[victim] as Dictionary).get("deaths", 0)) + 1
	var killer := -1
	if kref.size() >= 2 and int(kref[0]) == NetProto.REF_PLAYER:
		killer = int(kref[1])
		if killer != victim and players.has(killer):
			(players[killer] as Dictionary)["kills"] = int((players[killer] as Dictionary).get("kills", 0)) + 1
	kill_reported.emit(victim, kref, cause, weapon_id)
	hud.on_kill(victim, killer, cause, weapon_id)
	roster_changed.emit()


# --- world state (clock, weather) -------------------------------------------------------------------

func _world_state() -> Array:
	return [float(WorldClock.hour), int(WorldClock.day), str(Weather.current), float(Weather.transition),
			float(WorldClock.rate), bool(WorldClock.paused)]


func _apply_world_state(a: Variant) -> void:
	if not (a is Array) or (a as Array).size() < 6 or mode != Mode.CLIENT:
		return
	var arr := a as Array
	var h := float(arr[0])
	WorldClock.rate = float(arr[4])
	WorldClock.paused = bool(arr[5])
	WorldClock.day = int(arr[1])
	# only correct a real drift: a set_hour() every second would restart the sky blends
	var diff := absf(angle_difference(h / 24.0 * TAU, float(WorldClock.hour) / 24.0 * TAU)) / TAU * 24.0
	if diff > 0.05:
		WorldClock.set_hour(h)
	Weather.auto_cycle = false
	var w := str(arr[2])
	if w != str(Weather.current) and Weather.TYPES.has(w):
		if not booted or float(arr[3]) >= 0.99:
			Weather.snap_weather(w)
		else:
			Weather.set_weather(w, 8.0)


# =================================================================================================
# snapshots (unreliable) + clock
# =================================================================================================

func _process(delta: float) -> void:
	if mode == Mode.SOLO or not booted:
		return
	_ping_t -= delta
	if _ping_t <= 0.0:
		_ping_t = PING_INTERVAL if _offset_samples >= 6 else 0.25
		if mode == Mode.CLIENT:
			_rpc_ping.rpc_id(1, local_time())
	if mode == Mode.HOST:
		_world_t -= delta
		if _world_t <= 0.0:
			_world_t = 1.0
			var ws := _world_state()
			for id: int in remote_peers():
				_send_ev(id, NetProto.EV_WORLD, ws, 1)


func _physics_process(delta: float) -> void:
	if mode == Mode.SOLO or not booted:
		return
	_snap_t -= delta
	if _snap_t > 0.0:
		return
	_snap_t += 1.0 / SNAPSHOT_HZ
	if _snap_t < -0.2:
		_snap_t = 0.0
	if mode == Mode.CLIENT:
		var data := world.build_client_snapshot()
		if not data.is_empty():
			_send_snapshot(1, data)
	else:
		for id: int in remote_peers():
			for data: PackedByteArray in world.build_host_snapshots(id):
				_send_snapshot(id, data)


func _send_snapshot(to: int, data: PackedByteArray) -> void:
	stats["snap_out"] = int(stats["snap_out"]) + 1
	stats["bytes_out"] = int(stats["bytes_out"]) + data.size()
	_rpc_snap.rpc_id(to, data)


@rpc("any_peer", "call_remote", "unreliable_ordered", NetProto.CH_SNAPSHOT)
func _rpc_snap(data: PackedByteArray) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if not booted:
		return
	if mode == Mode.HOST:
		if not players.has(sender) or not bool((players[sender] as Dictionary).get("ready", false)):
			return
	elif mode == Mode.CLIENT:
		if sender != 1:
			return
	else:
		return
	stats["snap_in"] = int(stats["snap_in"]) + 1
	stats["bytes_in"] = int(stats["bytes_in"]) + data.size()
	world.apply_snapshot(data, sender)


@rpc("any_peer", "call_remote", "unreliable", NetProto.CH_SNAPSHOT)
func _rpc_ping(t_client: float) -> void:
	if mode != Mode.HOST:
		return
	var id := multiplayer.get_remote_sender_id()
	_rpc_pong.rpc_id(id, t_client, local_time())


@rpc("authority", "call_remote", "unreliable", NetProto.CH_SNAPSHOT)
func _rpc_pong(t_client: float, t_host: float) -> void:
	if mode != Mode.CLIENT:
		return
	var now := local_time()
	var sample_rtt := maxf(now - t_client, 0.0)
	rtt = sample_rtt if _offset_samples == 0 else lerpf(rtt, sample_rtt, 0.15)
	# the sample with the shortest round trip gives the best estimate of the host clock
	_best_rtt = minf(_best_rtt * 1.02 + 0.0002, 1.0e9)
	if sample_rtt <= _best_rtt:
		_best_rtt = sample_rtt
		var target := t_host + sample_rtt * 0.5 - now
		if _offset_samples == 0 or absf(target - session_time_offset) > 0.5:
			session_time_offset = target
		else:
			session_time_offset = lerpf(session_time_offset, target, 0.5)
	_offset_samples += 1
	if players.has(my_id):
		(players[my_id] as Dictionary)["ping"] = int(rtt * 1000.0)
	if _offset_samples % 3 == 0:
		_rpc_report_ping.rpc_id(1, int(rtt * 1000.0))


@rpc("any_peer", "call_remote", "unreliable", NetProto.CH_SNAPSHOT)
func _rpc_report_ping(ms: int) -> void:
	if mode != Mode.HOST:
		return
	var id := multiplayer.get_remote_sender_id()
	if players.has(id):
		(players[id] as Dictionary)["ping"] = clampi(ms, 0, 9999)


func _local_appearance() -> Dictionary:
	var p := Game.player
	if p != null and is_instance_valid(p) and p.has_method("get_appearance"):
		var a: Variant = p.call("get_appearance")
		if a is Dictionary:
			return a
	return {}


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		if _enet != null and mode != Mode.SOLO:
			_enet.close()
