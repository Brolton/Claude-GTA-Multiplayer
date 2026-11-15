extends Node
## Finding games (child "Discovery" of the Net autoload).
##
## The host answers small UDP probes on NetProto.DISCOVERY_PORT. A client that looks for games
## sends the probe to
##   * the LAN broadcast addresses (same Wi-Fi / switch),
##   * every online peer of its Tailscale network (a tailnet has no broadcast; the peer list comes
##     from `tailscale status --json`, read once in a thread),
##   * the addresses it joined before.
## Whoever answers shows up in the list of the start menu.

signal games_changed()

const PROBE_INTERVAL := 1.0
const STALE_AFTER := 4.5

var games: Dictionary = {}            ## address -> {address, name, players, max, port, version, seen, kind}

var _server: PacketPeerUDP = null
var _client: PacketPeerUDP = null
var _scanning: bool = false
var _probe_t: float = 0.0
var _tail_ips: PackedStringArray = []
var _tail_thread: Thread = null
var _tail_done: bool = false
var _mutex := Mutex.new()


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


# --- host side --------------------------------------------------------------------------------------

func start_host() -> void:
	stop_host()
	_server = PacketPeerUDP.new()
	if _server.bind(NetProto.DISCOVERY_PORT) != OK:
		push_warning("[Net] discovery port %d is busy - friends must type the address" % NetProto.DISCOVERY_PORT)
		_server = null


func stop_host() -> void:
	if _server != null:
		_server.close()
	_server = null


func _answer_probes() -> void:
	while _server.get_available_packet_count() > 0:
		var pkt := _server.get_packet()
		if pkt.get_string_from_utf8() != NetProto.DISCOVERY_MAGIC:
			continue
		var info := {"name": Net.player_name, "players": Net.players.size(), "max": Net.max_players,
				"port": Net.port, "version": NetProto.VERSION}
		_server.set_dest_address(_server.get_packet_ip(), _server.get_packet_port())
		_server.put_packet((NetProto.DISCOVERY_REPLY + JSON.stringify(info)).to_utf8_buffer())


# --- client side ------------------------------------------------------------------------------------

func start_scan() -> void:
	if _scanning:
		return
	_scanning = true
	games.clear()
	_client = PacketPeerUDP.new()
	_client.set_broadcast_enabled(true)
	_client.bind(0)
	_probe_t = 0.0
	if _tail_thread == null and not _tail_done:
		_tail_thread = Thread.new()
		_tail_thread.start(_read_tailnet)


func stop_scan() -> void:
	_scanning = false
	if _client != null:
		_client.close()
	_client = null


func get_games() -> Array:
	var out: Array = games.values()
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a["address"]) < str(b["address"]))
	return out


func _process(delta: float) -> void:
	if _server != null:
		_answer_probes()
	if not _scanning or _client == null:
		return
	if _tail_thread != null and not _tail_thread.is_alive():
		_tail_thread.wait_to_finish()
		_tail_thread = null
		_tail_done = true
	_probe_t -= delta
	if _probe_t <= 0.0:
		_probe_t = PROBE_INTERVAL
		_send_probes()
	var changed := false
	while _client.get_available_packet_count() > 0:
		var pkt := _client.get_packet()
		var ip := _client.get_packet_ip()
		var text := pkt.get_string_from_utf8()
		if not text.begins_with(NetProto.DISCOVERY_REPLY):
			continue
		var parsed: Variant = JSON.parse_string(text.substr(NetProto.DISCOVERY_REPLY.length()))
		if not (parsed is Dictionary):
			continue
		var d := parsed as Dictionary
		var address := ip
		var gport := int(d.get("port", NetProto.GAME_PORT))
		if gport != NetProto.GAME_PORT:
			address = "%s:%d" % [ip, gport]
		var is_new := not games.has(address)
		games[address] = {"address": address, "name": str(d.get("name", "?")), "players": int(d.get("players", 1)),
				"max": int(d.get("max", 4)), "port": gport, "version": int(d.get("version", 0)),
				"seen": Time.get_ticks_msec(), "kind": _kind_of(ip)}
		changed = changed or is_new
	var now := Time.get_ticks_msec()
	for a: String in games.keys():
		if now - int((games[a] as Dictionary)["seen"]) > int(STALE_AFTER * 1000.0):
			games.erase(a)
			changed = true
	if changed:
		games_changed.emit()


func _kind_of(ip: String) -> String:
	var parts := ip.split(".")
	if parts.size() == 4 and int(parts[0]) == 100 and int(parts[1]) >= 64 and int(parts[1]) <= 127:
		return "Tailscale"
	return "LAN"


func _send_probes() -> void:
	var targets := {"255.255.255.255": true}
	for a: String in IP.get_local_addresses():
		if a.contains(":") or a.begins_with("127.") or a.begins_with("169.254."):
			continue
		var parts := a.split(".")
		if parts.size() == 4:
			targets["%s.%s.%s.255" % [parts[0], parts[1], parts[2]]] = true
	_mutex.lock()
	for ip: String in _tail_ips:
		targets[ip] = true
	_mutex.unlock()
	var known: Array = Array(Net.recent_addresses)
	if Net.last_address != "":
		known.append(Net.last_address)
	for a: Variant in known:
		var host := str(a)
		if host.contains(":"):
			host = host.substr(0, host.rfind(":"))
		if host.is_valid_ip_address():
			targets[host] = true
	var probe := NetProto.DISCOVERY_MAGIC.to_utf8_buffer()
	for ip: String in targets:
		if _client.set_dest_address(ip, NetProto.DISCOVERY_PORT) == OK:
			_client.put_packet(probe)


## Thread: the online peers of this machine's tailnet (empty when Tailscale is not installed).
func _read_tailnet() -> void:
	var exes: Array[String] = ["tailscale"]
	if OS.get_name() == "Windows":
		exes.append("C:\\Program Files\\Tailscale\\tailscale.exe")
		exes.append("C:\\Program Files (x86)\\Tailscale\\tailscale.exe")
	elif OS.get_name() == "macOS":
		exes.append("/Applications/Tailscale.app/Contents/MacOS/Tailscale")
	for exe: String in exes:
		var out: Array = []
		var code := OS.execute(exe, ["status", "--json"], out, false, false)
		if code != 0 or out.is_empty():
			continue
		var parsed: Variant = JSON.parse_string(str(out[0]))
		if not (parsed is Dictionary):
			continue
		var peers: Variant = (parsed as Dictionary).get("Peer", {})
		var ips := PackedStringArray()
		if peers is Dictionary:
			for k: Variant in (peers as Dictionary):
				var p: Variant = (peers as Dictionary)[k]
				if not (p is Dictionary) or not bool((p as Dictionary).get("Online", false)):
					continue
				var list: Variant = (p as Dictionary).get("TailscaleIPs", [])
				if list is Array:
					for ip: Variant in list:
						if str(ip).is_valid_ip_address() and not str(ip).contains(":"):
							ips.append(str(ip))
		_mutex.lock()
		_tail_ips = ips
		_mutex.unlock()
		return


func _exit_tree() -> void:
	stop_host()
	stop_scan()
	if _tail_thread != null:
		_tail_thread.wait_to_finish()
		_tail_thread = null
