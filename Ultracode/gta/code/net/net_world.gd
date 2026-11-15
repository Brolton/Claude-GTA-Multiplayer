extends Node
## Entity replication (child "World" of the Net autoload, docs/MULTIPLAYER.md).
##
## Replicated bodies: the players (one avatar per remote peer), every VehicleBase and every NpcBase.
## Each vehicle / NPC is an Ent with a session-wide id (nid) and ONE authority peer:
##   * whatever a machine spawns itself (not as a puppet) is its own: the host's traffic, parked
##     cars and pedestrians, a client's police units, garage / admin spawns ...
##   * a vehicle changes hands when a player takes its wheel (EV_CLAIM -> EV_AUTH), and goes back to
##     the host when its owner leaves it behind (EV_RELEASE) or disconnects.
## The authority simulates and streams state; everybody else holds a puppet (the real game object
## with net_puppet = true) that follows an interpolation buffer.
## The host is the hub: clients send it what they own, it forwards what each client needs
## (interest management by distance), with the original timestamps.

const VEH_IN := 240.0                 ## host: a vehicle closer than this to a client's player is replicated to it
const VEH_OUT := 285.0
const NPC_IN := 135.0
const NPC_OUT := 165.0
const SPAWNS_PER_TICK := 14           ## per client and relevance pass (join burst control)
const RELEVANCE_INTERVAL := 0.25
const MAX_PACKET := 1100
const RELEASE_DISTANCE := 130.0       ## client: an abandoned vehicle this far away goes back to the host
const RELEASE_IDLE := 25.0
const DUMMY_VISUAL_DIST := 55.0
const DUMMY_VISUAL_MAX := 10
const NetDummyScript := preload("res://gta/code/net/net_dummy.gd")


class Ent extends RefCounted:
	var nid: int = 0
	var kind: int = 0
	var node: Node3D = null
	var auth: int = 1
	var local: bool = false           ## this machine simulates it
	var interp: NetInterp = null      ## puppets
	var st: Dictionary = {}           ## last decoded state (puppets)
	var known: Dictionary = {}        ## host: peer -> true (spawn was sent)
	var sent: Dictionary = {}         ## peer -> host time of the last state sent (client: key 1)
	var raw: PackedByteArray = PackedByteArray()   ## host: latest state blob from a client authority
	var raw_t: float = -1.0
	var raw_sent: Dictionary = {}     ## host: peer -> raw_t last forwarded
	var ai: Array = []                ## vehicle: [look_archetype, look_seed] of the AI stand-in driver
	var dummy: Node3D = null          ## puppet vehicle: the stand-in driver node
	var idle_t: float = 0.0           ## client: seconds unoccupied (release)
	var dead_t: float = 0.0           ## puppet NPC: seconds the dead flag has been set without the event
	var weapon: String = ""


var ents: Dictionary = {}             ## nid -> Ent
var avatars: Dictionary = {}          ## peer id -> NetAvatar
var active: bool = false

var _spawning: bool = false           ## a puppet is being created: the spawn signals are ours
var _counter: int = 0
var _raw_player: Dictionary = {}      ## host: peer -> [blob, host time]
var _raw_player_sent: Dictionary = {} ## host: "from:to" -> time
var _relevance_t: float = 0.0
var _slow_t: float = 0.0
var _buf := StreamPeerBuffer.new()
var _blob := StreamPeerBuffer.new()
var _rd := StreamPeerBuffer.new()
var _connected: bool = false
var _dummy_visuals: int = 0


# =================================================================================================
# session
# =================================================================================================

func on_session_boot() -> void:
	active = true
	if not _connected:
		_connected = true
		EventBus.vehicle_spawned.connect(_on_vehicle_spawned)
		EventBus.npc_spawned.connect(_on_npc_spawned)
		EventBus.player_entered_vehicle.connect(_on_player_entered_vehicle)
		EventBus.player_respawned.connect(_on_player_respawned)
		EventBus.player_appearance_changed.connect(_on_player_appearance_changed)
		EventBus.vehicle_modified.connect(_on_vehicle_modified)
		Net.roster_changed.connect(_sync_avatars)
	var p := Game.player as Player
	if p != null and p.animator != null and not p.animator.action_started.is_connected(_on_local_action):
		p.animator.action_started.connect(_on_local_action)
	var vm := Game.get_system("vehicles")
	if vm != null:
		vm.set("max_vehicles", 170)
	# what already exists on this machine is ours (the host's world; a client starts empty)
	for n: Node in get_tree().get_nodes_in_group("vehicle"):
		if n is VehicleBase and (n as VehicleBase).net_id == 0:
			_register_local(n as Node3D, NetProto.KIND_VEHICLE)
	for n: Node in get_tree().get_nodes_in_group("npc"):
		if n is NpcBase and not (n is NetAvatar) and (n as NpcBase).net_id == 0 and n.is_inside_tree():
			_register_local(n as Node3D, NetProto.KIND_NPC)
	_sync_avatars()


func on_session_end() -> void:
	active = false
	for peer: int in avatars.keys():
		_free_avatar(peer)
	for nid: int in ents.keys():
		var e: Ent = ents[nid]
		if e.node != null and is_instance_valid(e.node):
			if e.local:
				e.node.set("net_id", 0)
			else:
				_free_node(e)
	ents.clear()
	_raw_player.clear()


## Host: a client finished loading - the next relevance pass sends it the world around it.
func on_peer_ready(_peer: int) -> void:
	_sync_avatars()
	_relevance_t = 0.0
	Net.send_event_to(_peer, NetProto.EV_APPEARANCE, [1, Net._local_appearance()])
	for other: int in Net.players:
		if other != _peer and other != 1:
			var app: Variant = (Net.players[other] as Dictionary).get("appearance", {})
			if app is Dictionary and not (app as Dictionary).is_empty():
				Net._send_ev(_peer, NetProto.EV_APPEARANCE, [other, app], other)


func on_peer_left(peer: int) -> void:
	_free_avatar(peer)
	_raw_player.erase(peer)
	for nid: int in ents.keys():
		var e: Ent = ents[nid]
		e.known.erase(peer)
		e.sent.erase(peer)
		e.raw_sent.erase(peer)
		if e.auth != peer or not Net.is_host():
			continue
		if e.kind == NetProto.KIND_VEHICLE and e.node != null and is_instance_valid(e.node):
			_host_take(e)              # its cars stay in the world
		else:
			_host_despawn(e)           # its police officers leave with it


# =================================================================================================
# queries used by the game hooks
# =================================================================================================

func get_entity_node(nid: int) -> Node3D:
	var e: Ent = ents.get(nid, null)
	if e != null and e.node != null and is_instance_valid(e.node):
		return e.node
	return null


func get_avatar(peer: int) -> NetAvatar:
	var a: Variant = avatars.get(peer, null)
	if a != null and is_instance_valid(a):
		return a as NetAvatar
	return null


## Positions of every player (the local one first): the host's population systems spawn around all.
func get_foci() -> PackedVector3Array:
	var out := PackedVector3Array()
	if Game.has_player():
		out.append(Game.get_player_position())
	if active:
		for peer: int in avatars:
			var a := get_avatar(peer)
			if a != null and a.has_state:
				out.append(a.get_net_position())
	return out


## Flat distance from `pos` to the nearest player (INF without players).
func focus_distance(pos: Vector3) -> float:
	var best := INF
	for f: Vector3 in get_foci():
		best = minf(best, Vector2(pos.x - f.x, pos.z - f.z).length())
	return best


## A remote player is probably looking at `pos` (view cone + range; no occlusion test).
func is_seen_by_remote(pos: Vector3, max_dist: float = 240.0) -> bool:
	if not active:
		return false
	for peer: int in avatars:
		var a := get_avatar(peer)
		if a == null or not a.has_state:
			continue
		var from := a.get_net_position() + Vector3(0.0, 1.6, 0.0)
		var to := pos - from
		var d := to.length()
		if d > max_dist:
			continue
		if d < 12.0:
			return true
		var fwd := Vector3(-sin(a.view_yaw), 0.0, -cos(a.view_yaw))
		if to.normalized().dot(fwd) > 0.45:
			return true
	return false


## Nearest remote player position to `pos` closer than `radius` (Vector3.INF if none).
func remote_player_near(pos: Vector3, radius: float) -> Vector3:
	if not active:
		return Vector3.INF
	for peer: int in avatars:
		var a := get_avatar(peer)
		if a != null and a.has_state and a.get_net_position().distance_to(pos) < radius:
			return a.get_net_position()
	return Vector3.INF


## A remote player sits in `v` (any seat).
func is_player_vehicle(v: Node) -> bool:
	if not active or v == null:
		return false
	for peer: int in avatars:
		var a := get_avatar(peer)
		if a != null and a.current_vehicle == v:
			return true
	return false


## `who` is the avatar of another player.
func is_remote_player(who: Variant) -> bool:
	return who != null and is_instance_valid(who) and who is NetAvatar


## Wire reference of a node ([] when it is not replicated).
func ref_of(node: Variant) -> Array:
	if node == null or not is_instance_valid(node) or not (node is Node):
		return []
	if node == Game.player:
		return [NetProto.REF_PLAYER, Net.my_id]
	if node is NetAvatar:
		return [NetProto.REF_PLAYER, (node as NetAvatar).peer_id]
	var nid: Variant = (node as Node).get("net_id")
	if nid != null and int(nid) != 0:
		return [NetProto.REF_ENTITY, int(nid)]
	return []


func node_of(ref: Variant) -> Node:
	if not (ref is Array) or (ref as Array).size() < 2:
		return null
	var r := ref as Array
	if int(r[0]) == NetProto.REF_PLAYER:
		if int(r[1]) == Net.my_id:
			return Game.player
		return get_avatar(int(r[1]))
	return get_entity_node(int(r[1]))


## Peer that decides about the node behind `ref` (0 = unknown).
func authority_of(ref: Variant) -> int:
	if not (ref is Array) or (ref as Array).size() < 2:
		return 0
	var r := ref as Array
	if int(r[0]) == NetProto.REF_PLAYER:
		return int(r[1])
	var e: Ent = ents.get(int(r[1]), null)
	return e.auth if e != null else 0


# =================================================================================================
# avatars
# =================================================================================================

func _sync_avatars() -> void:
	if not active or not Net.booted:
		return
	for peer: int in Net.players:
		if peer == Net.my_id:
			continue
		var info: Dictionary = Net.players[peer]
		if not bool(info.get("ready", false)):
			continue
		var a := get_avatar(peer)
		if a == null:
			a = NetAvatar.new()
			a.name = "Avatar_%d" % peer
			Game.get_entities_root().add_child(a)
			a.global_position = Vector3(0.0, -500.0, 0.0)      # until its first snapshot arrives
			a.setup_avatar(peer, str(info["name"]), info.get("appearance", {}), Net.slot_color(int(info["slot"])))
			avatars[peer] = a
		else:
			a.set_player_name(str(info["name"]), Net.slot_color(int(info["slot"])))
	for peer: int in avatars.keys():
		if not Net.players.has(peer):
			_free_avatar(peer)


func _free_avatar(peer: int) -> void:
	var a := get_avatar(peer)
	avatars.erase(peer)
	if a == null:
		return
	if a.current_vehicle != null and is_instance_valid(a.current_vehicle):
		var v := a.current_vehicle
		if v.has_method("get_seat_of") and int(v.call("get_seat_of", a)) >= 0:
			v.call("occupant_exit", a.seat_index)
		a._leave_vehicle_to(Transform3D(Basis.IDENTITY, v.global_position))
	a.queue_free()


func on_player_respawned(peer: int, _pos: Variant) -> void:
	var a := get_avatar(peer)
	if a != null:
		a.interp.clear()


func on_player_appearance(peer: int, appearance: Variant) -> void:
	var a := get_avatar(peer)
	if a != null and appearance is Dictionary:
		a.set_appearance(appearance)


func _on_player_respawned(pos: Vector3) -> void:
	if active:
		Net.send_event(NetProto.EV_RESPAWN, [Net.my_id, pos])


func _on_player_appearance_changed(appearance: Dictionary) -> void:
	if active:
		if Net.players.has(Net.my_id):
			(Net.players[Net.my_id] as Dictionary)["appearance"] = appearance
		Net.send_event(NetProto.EV_APPEARANCE, [Net.my_id, appearance])


func _on_local_action(action: String, duration: float) -> void:
	if active and action != "fire":
		Net.send_event(NetProto.EV_ANIM, [[NetProto.REF_PLAYER, Net.my_id], action, duration])


# =================================================================================================
# registration of local bodies
# =================================================================================================

func _alloc_nid() -> int:
	_counter += 1
	if _counter >= 99990:
		_counter = 1
	var nid := Net.my_slot * 100000 + _counter
	while ents.has(nid):
		_counter += 1
		nid = Net.my_slot * 100000 + _counter
	return nid


func _on_vehicle_spawned(v: Node3D) -> void:
	if not active or _spawning or not (v is VehicleBase) or (v as VehicleBase).net_id != 0:
		return
	_register_local(v, NetProto.KIND_VEHICLE)


func _on_npc_spawned(npc: Node3D) -> void:
	if not active or _spawning or not (npc is NpcBase) or npc is NetAvatar:
		return
	if (npc as NpcBase).net_id != 0:
		return
	_register_local(npc, NetProto.KIND_NPC)


func _register_local(node: Node3D, kind: int) -> Ent:
	var e := Ent.new()
	e.nid = _alloc_nid()
	e.kind = kind
	e.node = node
	e.auth = Net.my_id
	e.local = true
	ents[e.nid] = e
	node.set("net_id", e.nid)
	node.set("net_puppet", false)
	_watch(e)
	if Net.is_client():
		_announce.call_deferred(e.nid)       # one frame later: paint, crew and stand-in driver are set by then
	return e


func _announce(nid: int) -> void:
	var e: Ent = ents.get(nid, null)
	if e == null or not e.local or e.node == null or not is_instance_valid(e.node) or not e.node.is_inside_tree():
		return
	Net.send_event(NetProto.EV_SPAWN, [e.nid, e.kind, Net.my_id, _describe(e), _state_blob(e)])


func _watch(e: Ent) -> void:
	var cb := _on_node_exited.bind(e.nid, e.node.get_instance_id())
	if not e.node.tree_exited.is_connected(cb):
		e.node.tree_exited.connect(cb)


func _on_node_exited(nid: int, iid: int) -> void:
	# seats re-parent their occupants and the pedestrian pool takes bodies out of the tree: only a
	# body that is still outside one frame later is really gone
	_check_gone.call_deferred(nid, iid)


func _check_gone(nid: int, iid: int) -> void:
	var e: Ent = ents.get(nid, null)
	if e == null:
		return
	var obj := instance_from_id(iid)
	if obj != null and is_instance_valid(obj) and (obj as Node).is_inside_tree() and not (obj as Node).is_queued_for_deletion():
		return
	if e.node != null and is_instance_valid(e.node) and e.node.get_instance_id() != iid:
		return
	_forget(e, true)


## Drop an entity whose node is gone. notify: tell the others when it was ours.
func _forget(e: Ent, notify: bool) -> void:
	ents.erase(e.nid)
	if e.node != null and is_instance_valid(e.node):
		e.node.set("net_id", 0)
		e.node.set("net_puppet", false)
	if e.dummy != null and is_instance_valid(e.dummy):
		e.dummy.queue_free()
	if not notify or not active:
		return
	if e.local:
		if Net.is_client():
			Net.send_event(NetProto.EV_DESPAWN, [e.nid])
		else:
			for peer: int in e.known:
				Net.send_event_to(peer, NetProto.EV_DESPAWN, [e.nid])
	elif Net.is_host():
		# a puppet of a client's body vanished on the host (cap / cleanup): the others drop it too
		for peer: int in e.known:
			if peer != e.auth:
				Net.send_event_to(peer, NetProto.EV_DESPAWN, [e.nid])


func _describe(e: Ent) -> Dictionary:
	if e.kind == NetProto.KIND_VEHICLE:
		var v := e.node as VehicleBase
		e.ai = _ai_of(v)
		return {"s": v.spec_id, "c1": v.paint_primary, "c2": v.paint_secondary, "m": v.mods.duplicate(),
				"o": v.owner_tag, "r": v.is_roof_open(), "ai": e.ai}
	var n := e.node as NpcBase
	var look: Dictionary = {}
	if n.visual != null and n.visual.has_method("get_appearance"):
		var a: Variant = n.visual.call("get_appearance")
		if a is Dictionary:
			look = a
	return {"a": n.archetype_id, "l": look, "w": n.weapon_id, "f": n.faction}


func _ai_of(v: VehicleBase) -> Array:
	var d := v.driver
	if d != null and is_instance_valid(d) and d is TrafficDummy:
		return [(d as TrafficDummy).look_archetype, (d as TrafficDummy).look_seed]
	return []


func _state_blob(e: Ent) -> PackedByteArray:
	_blob.clear()
	if e.kind == NetProto.KIND_VEHICLE:
		NetCodec.write_vehicle(_blob, e.node as VehicleBase)
	else:
		NetCodec.write_npc(_blob, e.node as NpcBase)
	return _blob.data_array


# =================================================================================================
# puppets
# =================================================================================================

func _spawn_puppet(nid: int, kind: int, auth: int, desc: Dictionary, state: PackedByteArray) -> Ent:
	if ents.has(nid):
		return ents[nid]
	_rd.data_array = state
	_rd.seek(0)
	var node: Node3D = null
	var st: Dictionary = {}
	_spawning = true
	if kind == NetProto.KIND_VEHICLE:
		st = NetCodec.read_vehicle(_rd)
		var xf := Transform3D(Basis(st["rot"] as Quaternion), st["pos"] as Vector3)
		var opts := {"owner_tag": str(desc.get("o", "civilian")), "color": desc.get("c1", Color(0.8, 0.8, 0.8)),
				"color2": desc.get("c2", Color(0, 0, 0, 0)), "roof_open": bool(desc.get("r", false))}
		var mods: Variant = desc.get("m", {})
		if mods is Dictionary and not (mods as Dictionary).is_empty():
			opts["mods"] = mods
		node = Game.spawn_vehicle(str(desc.get("s", "")), xf, opts)
	else:
		st = NetCodec.read_npc(_rd)
		var opts2 := {"weapon": str(desc.get("w", "")), "brain": Node.new(), "persistent": true, "yaw": float(st["yaw"])}
		var look: Variant = desc.get("l", {})
		if look is Dictionary and not (look as Dictionary).is_empty():
			opts2["appearance"] = look
		node = Game.spawn_npc(str(desc.get("a", "civilian_m")), st["pos"] as Vector3, opts2)
		if node == null:
			(opts2["brain"] as Node).free()
	_spawning = false
	if node == null:
		return null
	var e := Ent.new()
	e.nid = nid
	e.kind = kind
	e.node = node
	e.auth = auth
	e.local = false
	e.interp = NetInterp.new()
	e.st = st
	ents[nid] = e
	node.set("net_id", nid)
	var now := Net.host_time()
	if kind == NetProto.KIND_VEHICLE:
		var v := node as VehicleBase
		v.net_velocity = st["vel"]
		v.net_angular = st["ang"]
		v.net_set_puppet(true)
		e.interp.push(now, st["pos"], st["rot"], st["vel"], st["ang"])
		NetCodec.apply_vehicle_flags(v, st)
		var ai: Variant = desc.get("ai", [])
		_set_dummy(e, ai if ai is Array else [])
	else:
		var n := node as NpcBase
		n.net_puppet = true
		n.ambient = false
		n.hostile = false
		e.weapon = n.weapon_id
		e.interp.push(now, st["pos"], Quaternion(Vector3.UP, float(st["yaw"])), st["vel"])
		_apply_npc_state(e, st, true)
	_watch(e)
	return e


func _free_node(e: Ent) -> void:
	var node := e.node
	e.node = null
	if e.dummy != null and is_instance_valid(e.dummy):
		e.dummy.queue_free()
	e.dummy = null
	if node == null or not is_instance_valid(node):
		return
	if e.kind == NetProto.KIND_VEHICLE:
		var v := node as VehicleBase
		# never free the local player together with the car
		if Game.get_player_vehicle() == v and Game.player != null:
			var st: Variant = (Game.player as Player).states.get("vehicle", null)
			if st != null:
				(st as PlayerStateVehicle).request_exit(true)
		for peer: int in avatars:
			var a := get_avatar(peer)
			if a != null and a.current_vehicle == v:
				a._leave_seat()
		var vm := Game.get_system("vehicles")
		if vm != null and vm.has_method("despawn_vehicle"):
			vm.call("despawn_vehicle", v)
		else:
			v.queue_free()
	else:
		var n := node as NpcBase
		if n.current_vehicle != null and is_instance_valid(n.current_vehicle):
			if n.current_vehicle.has_method("get_seat_of") and int(n.current_vehicle.call("get_seat_of", n)) >= 0:
				n.current_vehicle.call("occupant_exit", n.seat_index)
		n.queue_free()


## Puppet vehicle: the stand-in driver of an AI car ([] = none).
func _set_dummy(e: Ent, ai: Array) -> void:
	e.ai = ai
	if e.dummy != null and is_instance_valid(e.dummy):
		var old := e.dummy
		e.dummy = null
		var v0 := e.node as VehicleBase
		if v0 != null and is_instance_valid(v0) and v0.get_seat_of(old) >= 0:
			v0.occupant_exit(v0.get_seat_of(old))
		old.queue_free()
	if ai.size() < 2 or e.node == null or not is_instance_valid(e.node) or e.local:
		return
	var v := e.node as VehicleBase
	if v.get_occupant(0) != null:
		return
	var dm := NetDummyScript.new()
	dm.look_archetype = str(ai[0])
	dm.look_seed = int(ai[1])
	var seat := v.get_seat_node(0)
	(seat if seat != null else v).add_child(dm)
	dm.transform = Transform3D.IDENTITY
	dm.vehicle = v
	v.occupant_enter(dm, 0)
	e.dummy = dm


func _apply_npc_state(e: Ent, d: Dictionary, snap: bool) -> void:
	var n := e.node as NpcBase
	if n == null or not is_instance_valid(n):
		return
	var f1 := int(d["f1"])
	n.health = float(d["health"]) * n.max_health
	var w := str(d["weapon"])
	if w != e.weapon:
		e.weapon = w
		n.set_weapon(w)
	if n.is_dead:
		return
	var dead := (f1 & 1) != 0
	if dead:
		# the "died" event normally arrives first; this is the fallback when it got lost / we joined late
		e.dead_t += 1.0 if snap else 0.15
		if e.dead_t >= 0.6:
			n._die({}, null)
		return
	e.dead_t = 0.0
	var down := (f1 & 2) != 0
	if down and not n.is_down and n.current_vehicle == null:
		n._go_down(Vector3(float((d["vel"] as Vector3).x), 0.5, float((d["vel"] as Vector3).z)) * 40.0)
	elif not down and n.is_down:
		n._stand_up()
		n._finish_get_up()
	n.set_crouched((f1 & 4) != 0)
	n.is_aiming = (f1 & 8) != 0
	n.phone_pose = (f1 & 16) != 0
	n.gesture = float(d["gesture"])
	n.look_target = d["look"]
	var pose: String = NetProto.NPC_POSES[clampi(int(d["pose"]), 0, NetProto.NPC_POSES.size() - 1)]
	if pose != n._pose:
		n._pose = pose
		n._set_collision(pose != "sit" and not n.is_down)


# =================================================================================================
# per-frame: move the puppets
# =================================================================================================

func _physics_process(delta: float) -> void:
	if not active or not Net.booted:
		return
	var now := Net.host_time()
	for nid: int in ents:
		var e: Ent = ents[nid]
		if e.local or e.node == null or not is_instance_valid(e.node) or not e.node.is_inside_tree():
			continue
		if e.kind == NetProto.KIND_VEHICLE:
			_tick_vehicle_puppet(e, now, delta)
		else:
			_tick_npc_puppet(e, now)
	if Net.is_host():
		_relevance_t -= delta
		if _relevance_t <= 0.0:
			_relevance_t = RELEVANCE_INTERVAL
			_relevance_pass()
	_slow_t -= delta
	if _slow_t <= 0.0:
		_slow_t = 0.5
		_slow_pass(0.5)


func _tick_vehicle_puppet(e: Ent, now: float, delta: float) -> void:
	var v := e.node as VehicleBase
	if not e.interp.sample(now):
		return
	var pos := e.interp.out_pos
	var here := v.global_position
	var jump := here.distance_to(pos)
	if jump > 0.0005 or e.interp.out_ang.length_squared() > 0.000001:
		if (e.interp.teleported or jump > 20.0) and not v.destroyed:
			# a teleport: no kinematic sweep through whatever stands in between
			v.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
			v.global_transform = Transform3D(Basis(e.interp.out_rot), pos)
			v.set_deferred("freeze_mode", RigidBody3D.FREEZE_MODE_KINEMATIC)
		else:
			v.global_transform = Transform3D(Basis(e.interp.out_rot), pos)
	v.net_velocity = e.interp.out_vel
	v.net_angular = e.interp.out_ang
	v.net_puppet_tick(delta)


func _tick_npc_puppet(e: Ent, now: float) -> void:
	var n := e.node as NpcBase
	if n.is_dead:
		return
	var d := e.st
	var want: Node3D = null
	var veh_nid := int(d.get("veh", 0))
	if veh_nid != 0:
		want = get_entity_node(veh_nid)
		if want != null and want.get("destroyed") == true:
			want = null
	if want != n.current_vehicle:
		if n.current_vehicle != null:
			var cur := n.current_vehicle
			if is_instance_valid(cur) and cur.has_method("get_seat_of") and int(cur.call("get_seat_of", n)) >= 0:
				cur.call("occupant_exit", n.seat_index)
			n._leave_vehicle_to(Transform3D(Basis(Vector3.UP, float(d["yaw"])), d["pos"] as Vector3))
			e.interp.clear()
			e.interp.push(now, d["pos"], Quaternion(Vector3.UP, float(d["yaw"])), d["vel"])
		if want != null and not n.is_down:
			var seat := int(d.get("seat", 0))
			var occ: Variant = want.call("get_occupant", seat)
			if occ != null and is_instance_valid(occ) and occ != n and (occ as Node).has_method("net_dismiss"):
				want.call("occupant_exit", seat)
				(occ as Node).call("net_dismiss")
			n._seat_into(want, seat)
	if n.current_vehicle != null or n.is_down:
		return
	if not e.interp.sample(now):
		return
	n.global_position = e.interp.out_pos
	var yaw := e.interp.out_rot.get_euler().y
	n._yaw_rate = angle_difference(n.rotation.y, yaw) * 60.0
	n.rotation = Vector3(0.0, yaw, 0.0)
	n.velocity = e.interp.out_vel
	n._glide_vel = Vector3(e.interp.out_vel.x, 0.0, e.interp.out_vel.z)
	if n.is_aiming:
		var fwd := -n.global_basis.z
		n._aim_pos = n.get_eye_position() + fwd * 10.0 + Vector3.UP * tan(float(d["aim_pitch"])) * 10.0
	else:
		n._aim_pos = Vector3.INF


func _slow_pass(dt: float) -> void:
	var cam := get_viewport().get_camera_3d()
	var ref := cam.global_position if cam != null else Game.get_player_position()
	var my_pos := Game.get_player_position()
	var pv := Game.get_player_vehicle()
	for nid: int in ents.keys():
		var e: Ent = ents[nid]
		if e.node == null or not is_instance_valid(e.node):
			continue
		if e.kind != NetProto.KIND_VEHICLE:
			continue
		var v := e.node as VehicleBase
		if not e.local:
			# stand-in driver visuals near the camera only
			if e.dummy != null and is_instance_valid(e.dummy):
				var near := v.global_position.distance_to(ref) < DUMMY_VISUAL_DIST
				var has: bool = e.dummy.call("has_visual")
				if near and not has and _dummy_visuals < DUMMY_VISUAL_MAX:
					e.dummy.call("show_visual")
					_dummy_visuals += 1
				elif not near and has and v.global_position.distance_to(ref) > DUMMY_VISUAL_DIST + 12.0:
					e.dummy.call("hide_visual")
					_dummy_visuals = maxi(_dummy_visuals - 1, 0)
			continue
		# authority: the AI stand-in driver came / went (carjack, despawn)
		var ai := _ai_of(v)
		if ai != e.ai:
			e.ai = ai
			Net.send_event(NetProto.EV_VEH_STATE, [e.nid, "ai", ai])
		# a client hands vehicles it no longer cares about back to the host
		if Net.is_client():
			var busy := v == pv or v.driver != null or v.personal or v.has_meta("ai_controller") \
					or not v.get_occupants().is_empty() or v.owner_tag == "police"
			if busy:
				e.idle_t = 0.0
			else:
				e.idle_t += dt
				var far := v.global_position.distance_to(my_pos) > RELEASE_DISTANCE
				if (far and e.idle_t > 3.0) or (e.idle_t > RELEASE_IDLE and v.linear_velocity.length() < 0.3):
					_client_release(e)


# =================================================================================================
# snapshots
# =================================================================================================

func _begin_packet(now: float) -> void:
	_buf.clear()
	_buf.put_double(now)


func _put_record(sec: int, id: int, dt_ms: int, blob: PackedByteArray) -> void:
	_buf.put_u8(sec)
	_buf.put_u32(id)
	_buf.put_16(clampi(dt_ms, -32000, 32000))
	_buf.put_u8(blob.size())
	_buf.put_data(blob)


func _end_packet() -> PackedByteArray:
	_buf.put_u8(NetProto.SEC_END)
	return _buf.data_array


func _player_blob() -> PackedByteArray:
	var p := Game.player as Player
	if p == null or not is_instance_valid(p) or not p.is_inside_tree():
		return PackedByteArray()
	_blob.clear()
	NetCodec.write_player(_blob, p)
	return _blob.data_array


## Client -> host: my player and everything I simulate.
func build_client_snapshot() -> PackedByteArray:
	var now := Net.host_time()
	_begin_packet(now)
	var pb := _player_blob()
	if not pb.is_empty():
		_put_record(NetProto.SEC_PLAYER, Net.my_id, 0, pb)
	var pv := Game.get_player_vehicle()
	for nid: int in ents:
		var e: Ent = ents[nid]
		if not e.local or e.node == null or not is_instance_valid(e.node) or not e.node.is_inside_tree():
			continue
		var interval := 0.1
		if e.kind == NetProto.KIND_VEHICLE:
			var v := e.node as VehicleBase
			if v == pv:
				interval = 0.0
			elif v.sleeping or v.destroyed:
				interval = 1.5
		else:
			var n := e.node as NpcBase
			if n.is_dead:
				interval = 2.0
			elif n.current_vehicle != null:
				interval = 0.4
		if now - float(e.sent.get(1, -100.0)) < interval:
			continue
		if _buf.get_size() > MAX_PACKET:
			break                        # the rest goes out with the next tick (their timers are older)
		e.sent[1] = now
		_put_record(NetProto.SEC_VEHICLE if e.kind == NetProto.KIND_VEHICLE else NetProto.SEC_NPC, e.nid, 0, _state_blob(e))
	return _end_packet()


## Host -> one client: the other players and every body that client knows and does not simulate.
func build_host_snapshots(peer: int) -> Array[PackedByteArray]:
	var out: Array[PackedByteArray] = []
	var now := Net.host_time()
	var target := _peer_position(peer)
	_begin_packet(now)
	var pb := _player_blob()
	if not pb.is_empty():
		_put_record(NetProto.SEC_PLAYER, 1, 0, pb)
	for other: int in _raw_player:
		if other == peer or not Net.players.has(other):
			continue
		var rp: Array = _raw_player[other]
		var key := other * 1000003 + peer
		if float(_raw_player_sent.get(key, -1.0)) >= float(rp[1]):
			continue
		_raw_player_sent[key] = rp[1]
		_put_record(NetProto.SEC_PLAYER, other, int((float(rp[1]) - now) * 1000.0), rp[0])
	for nid: int in ents:
		var e: Ent = ents[nid]
		if e.auth == peer or not e.known.has(peer) or e.node == null or not is_instance_valid(e.node) \
				or not e.node.is_inside_tree():
			continue
		var d := e.node.global_position.distance_to(target)
		var interval := 0.1
		if e.kind == NetProto.KIND_VEHICLE:
			var v := e.node as VehicleBase
			if (v.sleeping and e.local) or v.destroyed:
				interval = 1.5
			elif d < 90.0:
				interval = 0.05
			elif d < 190.0:
				interval = 0.1
			else:
				interval = 0.35
		else:
			var n := e.node as NpcBase
			if n.is_dead:
				interval = 2.0
			elif n.current_vehicle != null:
				interval = 0.4
			elif d < 55.0:
				interval = 0.1
			elif d < 120.0:
				interval = 0.2
			else:
				interval = 0.5
		if now - float(e.sent.get(peer, -100.0)) < interval - 0.004:
			continue
		var sec := NetProto.SEC_VEHICLE if e.kind == NetProto.KIND_VEHICLE else NetProto.SEC_NPC
		if e.local:
			e.sent[peer] = now
			_put_record(sec, e.nid, 0, _state_blob(e))
		else:
			if e.raw.is_empty() or float(e.raw_sent.get(peer, -1.0)) >= e.raw_t:
				continue
			e.sent[peer] = now
			e.raw_sent[peer] = e.raw_t
			_put_record(sec, e.nid, int((e.raw_t - now) * 1000.0), e.raw)
		if _buf.get_size() > MAX_PACKET:
			out.append(_end_packet())
			_begin_packet(now)
	if _buf.get_size() > 8:
		out.append(_end_packet())
	return out


func apply_snapshot(data: PackedByteArray, sender: int) -> void:
	if data.size() < 9:
		return
	var b := StreamPeerBuffer.new()
	b.data_array = data
	var base := b.get_double()
	var host := Net.is_host()
	var now := Net.host_time()
	# a client stamps with its estimate of the host clock: never accept a time from the future
	if base > now + 0.25:
		base = now
	while b.get_position() < b.get_size():
		var sec := b.get_u8()
		if sec == NetProto.SEC_END:
			break
		if b.get_size() - b.get_position() < 7:
			break
		var id := b.get_u32()
		var t := base + float(b.get_16()) * 0.001
		var n := b.get_u8()
		if b.get_size() - b.get_position() < n:
			break
		var res: Array = b.get_data(n)
		if int(res[0]) != OK:
			break
		var blob: PackedByteArray = res[1]
		_rd.data_array = blob
		_rd.seek(0)
		match sec:
			NetProto.SEC_PLAYER:
				if host:
					if id != sender:
						continue
					_raw_player[id] = [blob, t]
				elif id == Net.my_id:
					continue
				var a := get_avatar(id)
				if a != null:
					a.push_state(t, NetCodec.read_player(_rd))
			NetProto.SEC_VEHICLE, NetProto.SEC_NPC:
				var e: Ent = ents.get(id, null)
				if e == null or e.local or e.node == null or not is_instance_valid(e.node):
					continue
				if host:
					if e.auth != sender:
						continue
					e.raw = blob
					e.raw_t = t
				if sec == NetProto.SEC_VEHICLE and e.kind == NetProto.KIND_VEHICLE:
					var st := NetCodec.read_vehicle(_rd)
					e.st = st
					e.interp.push(t, st["pos"], st["rot"], st["vel"], st["ang"])
					NetCodec.apply_vehicle_flags(e.node as VehicleBase, st)
				elif sec == NetProto.SEC_NPC and e.kind == NetProto.KIND_NPC:
					var st2 := NetCodec.read_npc(_rd)
					e.st = st2
					e.interp.push(t, st2["pos"], Quaternion(Vector3.UP, float(st2["yaw"])), st2["vel"])
					_apply_npc_state(e, st2, false)


func _peer_position(peer: int) -> Vector3:
	if peer == Net.my_id:
		return Game.get_player_position()
	var a := get_avatar(peer)
	if a != null and a.has_state:
		return a.get_net_position()
	return Game.get_player_position()


# =================================================================================================
# host: interest management
# =================================================================================================

func _relevance_pass() -> void:
	for peer: int in Net.remote_peers():
		var a := get_avatar(peer)
		if a == null or not a.has_state:
			continue
		var target := a.get_net_position()
		var todo: Array = []
		for nid: int in ents:
			var e: Ent = ents[nid]
			if e.auth == peer or e.node == null or not is_instance_valid(e.node) or not e.node.is_inside_tree():
				continue
			var d := e.node.global_position.distance_to(target)
			var r_in := VEH_IN if e.kind == NetProto.KIND_VEHICLE else NPC_IN
			var r_out := VEH_OUT if e.kind == NetProto.KIND_VEHICLE else NPC_OUT
			var pinned := false
			if e.kind == NetProto.KIND_VEHICLE:
				pinned = a.is_in_vehicle() and a._want_veh == e.nid or _has_player_aboard(e.node)
			else:
				# a crew member travels with its (relevant) vehicle
				var cv: Variant = e.node.get("current_vehicle")
				if cv != null and is_instance_valid(cv):
					var ve: Ent = ents.get(int((cv as Node).get("net_id")), null)
					pinned = ve != null and ve.known.has(peer)
					if ve != null and not ve.known.has(peer) and ve.auth != peer:
						d = INF
			if e.known.has(peer):
				if d > r_out and not pinned:
					e.known.erase(peer)
					e.sent.erase(peer)
					e.raw_sent.erase(peer)
					Net.send_event_to(peer, NetProto.EV_DESPAWN, [e.nid])
			elif d < r_in or pinned:
				todo.append([0.0 if pinned else d, e])
		if todo.is_empty():
			continue
		todo.sort_custom(func(x: Array, y: Array) -> bool: return float(x[0]) < float(y[0]))
		# vehicles first: a crew needs its car
		var sent := 0
		for pass_kind: int in [NetProto.KIND_VEHICLE, NetProto.KIND_NPC]:
			for item: Array in todo:
				var e2: Ent = item[1]
				if e2.kind != pass_kind or sent >= SPAWNS_PER_TICK:
					continue
				var blob := _state_blob(e2) if e2.local else e2.raw
				if blob.is_empty():
					blob = _state_blob(e2)
				e2.known[peer] = true
				Net.send_event_to(peer, NetProto.EV_SPAWN, [e2.nid, e2.kind, e2.auth, _describe(e2), blob])
				sent += 1


func _has_player_aboard(v: Node) -> bool:
	if v == Game.get_player_vehicle():
		return true
	return is_player_vehicle(v)


# =================================================================================================
# authority
# =================================================================================================

func _on_player_entered_vehicle(vehicle: Node3D, seat: int) -> void:
	if not active or seat != 0 or not (vehicle is VehicleBase):
		return
	var v := vehicle as VehicleBase
	var e: Ent = ents.get(v.net_id, null)
	if e == null:
		_on_vehicle_spawned(v)
		return
	if e.local:
		return
	# optimistic: drive at once, the host confirms (or refuses when another player was faster)
	_make_local(e)
	if Net.is_client():
		Net.send_event(NetProto.EV_CLAIM, [e.nid])
	else:
		_host_set_auth(e, 1)


func _make_local(e: Ent) -> void:
	e.local = true
	e.auth = Net.my_id
	e.idle_t = 0.0
	if e.dummy != null and is_instance_valid(e.dummy):
		_set_dummy(e, [])
	var v := e.node as VehicleBase
	if v != null and is_instance_valid(v):
		v.net_set_puppet(false)


func _make_puppet(e: Ent, auth: int) -> void:
	e.local = false
	e.auth = auth
	if e.interp == null:
		e.interp = NetInterp.new()
	e.interp.clear()
	var v := e.node as VehicleBase
	if v != null and is_instance_valid(v):
		var lv := v.linear_velocity
		var av := v.angular_velocity
		v.net_set_puppet(true)
		v.net_velocity = lv
		v.net_angular = av
		e.interp.push(Net.host_time(), v.global_position, v.global_transform.basis.orthonormalized().get_rotation_quaternion(), lv, av)


func _host_set_auth(e: Ent, auth: int) -> void:
	e.auth = auth
	e.raw = PackedByteArray()
	e.raw_t = -1.0
	for peer: int in Net.remote_peers():
		Net.send_event_to(peer, NetProto.EV_AUTH, [e.nid, auth])


## Host: a client's vehicle becomes ours (owner left / released it).
func _host_take(e: Ent) -> void:
	_make_local(e)
	e.auth = 1
	_host_set_auth(e, 1)
	var v := e.node as VehicleBase
	if v != null and is_instance_valid(v) and v.driver == null and not v.personal:
		var tr := Game.get_system("traffic")
		if tr != null and tr.has_method("adopt_orphan"):
			tr.call("adopt_orphan", v)


func _host_despawn(e: Ent) -> void:
	for peer: int in e.known:
		Net.send_event_to(peer, NetProto.EV_DESPAWN, [e.nid])
	ents.erase(e.nid)
	_free_node(e)


func _client_release(e: Ent) -> void:
	Net.send_event(NetProto.EV_RELEASE, [e.nid, _state_blob(e)])
	_make_puppet(e, 1)


# =================================================================================================
# events
# =================================================================================================

func handle_event(kind: int, a: Array, origin: int) -> void:
	match kind:
		NetProto.EV_SPAWN:
			if a.size() < 5 or not (a[3] is Dictionary) or not (a[4] is PackedByteArray):
				return
			var auth := origin if Net.is_host() else int(a[2])
			var e := _spawn_puppet(int(a[0]), int(a[1]), auth, a[3], a[4])
			if e != null and Net.is_host():
				e.raw = a[4]
				e.raw_t = Net.host_time()
		NetProto.EV_DESPAWN:
			if a.size() < 1:
				return
			var e2: Ent = ents.get(int(a[0]), null)
			if e2 == null or e2.local:
				return
			if Net.is_host():
				if e2.auth != origin:
					return
				_host_despawn(e2)
			else:
				ents.erase(e2.nid)
				_free_node(e2)
		NetProto.EV_CLAIM:
			if a.size() >= 1 and Net.is_host():
				_host_claim(int(a[0]), origin)
		NetProto.EV_RELEASE:
			if a.size() >= 1 and Net.is_host():
				var e3: Ent = ents.get(int(a[0]), null)
				if e3 != null and e3.auth == origin and not e3.local and e3.kind == NetProto.KIND_VEHICLE:
					_host_take(e3)
		NetProto.EV_AUTH:
			if a.size() >= 2 and Net.is_client():
				var e4: Ent = ents.get(int(a[0]), null)
				if e4 == null:
					return
				var auth2 := int(a[1])
				if auth2 == Net.my_id:
					if not e4.local:
						_make_local(e4)
				elif e4.local:
					_make_puppet(e4, auth2)
					_kick_local_driver(e4)
				else:
					e4.auth = auth2
		NetProto.EV_DENY:
			if a.size() >= 1 and Net.is_client():
				var e5: Ent = ents.get(int(a[0]), null)
				if e5 != null and e5.local:
					_make_puppet(e5, int(a[1]) if a.size() >= 2 else 1)
					_kick_local_driver(e5)
		NetProto.EV_JACK:
			if a.size() >= 2:
				_handle_jack(int(a[0]), int(a[1]), a[2] if a.size() >= 3 else [], origin)
		NetProto.EV_EJECT:
			if a.size() >= 4:
				_handle_eject(int(a[0]), int(a[1]), a[2], a[3], origin)
		NetProto.EV_KNOCK:
			if a.size() >= 2:
				_handle_knock(a[0], a[1], origin)
		NetProto.EV_VEH_STATE:
			if a.size() >= 3:
				_handle_vehicle_state(int(a[0]), str(a[1]), a[2], origin)
		NetProto.EV_NPC_STATE:
			if a.size() >= 3:
				_handle_npc_state(int(a[0]), str(a[1]), a[2])


func _host_claim(nid: int, peer: int) -> void:
	var e: Ent = ents.get(nid, null)
	if e == null or e.kind != NetProto.KIND_VEHICLE or e.node == null or not is_instance_valid(e.node):
		return
	if e.auth == peer:
		return
	var v := e.node as VehicleBase
	# The latest claim wins: a player only claims after it sat down at the wheel on its own machine
	# (it pulled the previous driver out there, or both went for the same empty car). Whoever held
	# the wheel before gets EV_AUTH and steps out (_kick_local_driver).
	if e.local:
		_kick_local_driver(e)
		if v.has_meta("ai_controller"):
			var ctrl: Variant = v.get_meta("ai_controller")
			if ctrl is Object and is_instance_valid(ctrl) and (ctrl as Object).has_method("release_vehicle"):
				(ctrl as Object).call("release_vehicle", v, "carjacked")
			if v.has_meta("ai_controller"):
				v.remove_meta("ai_controller")
		_make_puppet(e, peer)
	_host_set_auth(e, peer)


func _kick_local_driver(e: Ent) -> void:
	var p := Game.player as Player
	if p != null and Game.get_player_vehicle() == e.node and p.seat_index == 0:
		p.exit_vehicle()


## The local player pulls the AI occupant of a puppet out (PlayerVehicleInteraction.pull_out).
func request_jack(v: Node, seat: int) -> void:
	var e: Ent = ents.get(int(v.get("net_id")), null) if v != null else null
	if e == null or e.local or not active:
		return
	if e.dummy != null and is_instance_valid(e.dummy) and seat == 0:
		_set_dummy(e, [])
	_route(e.auth, NetProto.EV_JACK, [e.nid, seat, [NetProto.REF_PLAYER, Net.my_id]])


func _handle_jack(nid: int, seat: int, thief_ref: Variant, origin: int) -> void:
	var e: Ent = ents.get(nid, null)
	if e == null or e.node == null or not is_instance_valid(e.node):
		return
	if not e.local:
		if Net.is_host():
			Net.send_event_to(e.auth, NetProto.EV_JACK, [nid, seat, [NetProto.REF_PLAYER, origin]])
		return
	var v := e.node as VehicleBase
	var occ := v.get_occupant(seat)
	if occ == null or occ == Game.player or occ is NetAvatar:
		return
	var thief := node_of(thief_ref if Net.is_client() else [NetProto.REF_PLAYER, origin])
	if seat == 0 and v.has_meta("ai_controller"):
		var ctrl: Variant = v.get_meta("ai_controller")
		if ctrl is Object and is_instance_valid(ctrl) and (ctrl as Object).has_method("release_vehicle"):
			var r: Variant = (ctrl as Object).call("release_vehicle", v, "carjacked")
			if r is Node3D and is_instance_valid(r) and (r as Node3D).has_method("knock_down"):
				var away := (r as Node3D).global_position - v.global_position
				away.y = 0.0
				away = away.normalized() if away.length_squared() > 0.001 else -v.global_basis.x
				(r as Node3D).call("knock_down", away * 130.0 + Vector3(0.0, 60.0, 0.0))
				if thief != null and (r as Node3D).has_method("panic"):
					(r as Node3D).call("panic", (thief as Node3D).global_position)
		if v.has_meta("ai_controller"):
			v.remove_meta("ai_controller")
		occ = v.get_occupant(seat)
	if occ != null and is_instance_valid(occ):
		var side := -v.global_basis.x if seat % 2 == 0 else v.global_basis.x
		v._evict(seat, side * 130.0 + Vector3(0.0, 60.0, 0.0))


func forward_eject(peer: int, vehicle: Node, exit_xform: Transform3D, impulse: Vector3) -> void:
	if not active or vehicle == null:
		return
	_route(peer, NetProto.EV_EJECT, [peer, int(vehicle.get("net_id")), exit_xform, impulse])


func _handle_eject(peer: int, nid: int, xform: Variant, impulse: Variant, _origin: int) -> void:
	if peer != Net.my_id:
		if Net.is_host():
			Net.send_event_to(peer, NetProto.EV_EJECT, [peer, nid, xform, impulse])
		return
	var p := Game.player as Player
	var v := get_entity_node(nid)
	if p == null or v == null or Game.get_player_vehicle() != v:
		return
	var imp: Vector3 = impulse if impulse is Vector3 else Vector3.ZERO
	var exit_xf: Transform3D = v.call("occupant_exit", p.seat_index)
	if xform is Transform3D and (xform as Transform3D).origin.distance_to(v.global_position) < 10.0:
		exit_xf = xform
	p.on_vehicle_ejected(v, exit_xf, imp if imp.length() > 1.0 else (exit_xf.origin - v.global_position).normalized() * 130.0)


func forward_knock(node: Node, impulse: Vector3) -> void:
	var ref := ref_of(node)
	if ref.is_empty() or not active:
		return
	_route(authority_of(ref), NetProto.EV_KNOCK, [ref, impulse])


func _handle_knock(ref: Variant, impulse: Variant, _origin: int) -> void:
	var auth := authority_of(ref)
	if auth != Net.my_id:
		if Net.is_host() and auth != 0:
			Net.send_event_to(auth, NetProto.EV_KNOCK, [ref, impulse])
		return
	var n := node_of(ref)
	if n != null and n.has_method("knock_down") and impulse is Vector3:
		n.call("knock_down", impulse)


## Send an entity-addressed event towards `auth` (clients always go through the host).
func _route(auth: int, kind: int, args: Array) -> void:
	if auth == Net.my_id or auth == 0:
		return
	Net.send_event_to(auth, kind, args)


# --- vehicle state events ---------------------------------------------------------------------------

## A puppet asks its authority for something ("repair").
func request_vehicle_state(v: Node, what: String, value: Variant) -> void:
	var e: Ent = ents.get(int(v.get("net_id")), null) if v != null else null
	if e == null or e.local or not active:
		return
	_route(e.auth, NetProto.EV_VEH_STATE, [e.nid, what, value])


func _on_vehicle_modified(vehicle: Node3D) -> void:
	if not active or not (vehicle is VehicleBase):
		return
	var v := vehicle as VehicleBase
	var e: Ent = ents.get(v.net_id, null)
	if e != null and e.local:
		Net.send_event(NetProto.EV_VEH_STATE, [e.nid, "look", [v.paint_primary, v.paint_secondary, v.mods.duplicate()]])


func _handle_vehicle_state(nid: int, what: String, value: Variant, origin: int) -> void:
	var e: Ent = ents.get(nid, null)
	if e == null or e.node == null or not is_instance_valid(e.node) or e.kind != NetProto.KIND_VEHICLE:
		return
	var v := e.node as VehicleBase
	match what:
		"repair":
			if e.local:
				v.repair()
			elif Net.is_host():
				Net.send_event_to(e.auth, NetProto.EV_VEH_STATE, [nid, what, value])
		"ai":
			if not e.local and (Net.is_client() or e.auth == origin) and value is Array:
				_set_dummy(e, value)
		"look":
			if not e.local and (Net.is_client() or e.auth == origin) and value is Array and (value as Array).size() >= 3:
				var arr := value as Array
				if arr[2] is Dictionary:
					v.apply_mods(arr[2])
				if arr[0] is Color and arr[1] is Color:
					v.set_paint(arr[0], arr[1])


# --- NPC events -------------------------------------------------------------------------------------

func on_local_npc_action(npc: Node, action: String, duration: float) -> void:
	if active and Net.has_remote_players():
		Net.send_event(NetProto.EV_ANIM, [[NetProto.REF_ENTITY, int(npc.get("net_id"))], action, duration])


func on_local_npc_died(npc: Node, info: Dictionary, killer: Node) -> void:
	if not active:
		return
	var dir: Vector3 = info.get("direction", Vector3.ZERO)
	var imp: Variant = info.get("impulse", 0.0)
	if imp is Vector3:
		imp = (imp as Vector3).length()
	Net.send_event(NetProto.EV_NPC_STATE, [int(npc.get("net_id")), "died",
			[dir, float(imp), str(info.get("type", "generic")), ref_of(killer)]])


func _handle_npc_state(nid: int, what: String, value: Variant) -> void:
	var e: Ent = ents.get(nid, null)
	if e == null or e.local or e.node == null or not is_instance_valid(e.node) or e.kind != NetProto.KIND_NPC:
		return
	var n := e.node as NpcBase
	if what == "died" and value is Array and (value as Array).size() >= 4 and not n.is_dead:
		var arr := value as Array
		var killer := node_of(arr[3])
		if killer != null and killer.is_in_group("vehicle") and killer == Game.get_player_vehicle():
			killer = Game.player
		if killer == Game.player and killer != null:
			n._report_harm(str(arr[2]), true, {})
		n._die({"direction": arr[0], "impulse": float(arr[1]), "type": str(arr[2])}, killer)


# =================================================================================================
# damage
# =================================================================================================

## A puppet was hit on this machine: its authority decides what the hit does.
func forward_damage(target: Node, info: Dictionary) -> void:
	if not active or bool(info.get("net", false)):
		return
	var ref := ref_of(target)
	if ref.is_empty():
		return
	var inst: Variant = info.get("instigator", null)
	var iref := ref_of(inst)
	if iref.is_empty() and inst != null and is_instance_valid(inst) and inst is Node and (inst as Node).is_in_group("vehicle"):
		iref = ref_of((inst as Node).get("driver"))
	_route(authority_of(ref), NetProto.EV_DAMAGE, [ref, NetProto.pack_damage(info, iref)])


## NpcBase.apply_damage of a puppet (an NPC of another machine, or the avatar of a player).
func on_puppet_npc_damage(npc: NpcBase, info: Dictionary) -> void:
	if not active:
		return
	var type := str(info.get("type", "generic"))
	var pos: Vector3 = info.get("position", Vector3.ZERO)
	var dir: Vector3 = info.get("direction", Vector3.ZERO)
	if (type == "bullet" or type == "melee") and pos != Vector3.ZERO:
		Fx.blood(pos, -dir if dir != Vector3.ZERO else Vector3.UP)
	if not (npc is NetAvatar) and Dmg.caused_by_player(info):
		npc._report_harm(type, false, info)      # the local player's crime, on the local wanted level
	forward_damage(npc, info)
