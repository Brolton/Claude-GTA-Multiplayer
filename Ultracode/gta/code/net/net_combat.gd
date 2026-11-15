extends Node
## Combat over the network (child "Combat" of the Net autoload, docs/MULTIPLAYER.md).
##
## Rule: whoever causes damage detects the hit on its OWN machine (its ray, its swing, its blast,
## its bumper) and the hit is delivered to the machine that simulates the victim (EV_DAMAGE).
## Everybody else only gets the looks: the shot is re-played with Combat's "cosmetic" option
## (tracer, impact, muzzle flash, sound and AI noise - no damage), explosions and projectiles
## arrive as damage-free twins.

const FX_RANGE := 260.0

var _connected: bool = false
var _replaying: bool = false          ## a remote effect is being played: do not send it back


func on_session_boot() -> void:
	if _connected:
		return
	_connected = true
	EventBus.weapon_fired.connect(_on_weapon_fired)
	EventBus.explosion.connect(_on_explosion)
	EventBus.player_died.connect(_on_player_died)


func on_session_end() -> void:
	pass


## The node is simulated on this machine (the local player, or a body we have authority over).
func _is_mine(n: Variant) -> bool:
	if n == null or not is_instance_valid(n) or not (n is Node):
		return false
	if n == Game.player:
		return true
	if n is NetAvatar:
		return false
	var nid: Variant = (n as Node).get("net_id")
	return nid != null and int(nid) != 0 and (n as Node).get("net_puppet") != true


func _too_far(pos: Vector3) -> bool:
	var cam := get_viewport().get_camera_3d()
	var ref := cam.global_position if cam != null else Game.get_player_position()
	return ref.distance_to(pos) > FX_RANGE


# --- shots ------------------------------------------------------------------------------------------

func _on_weapon_fired(weapon_id: String, shooter: Node, origin: Vector3, direction: Vector3) -> void:
	if _replaying or not Net.has_remote_players() or not _is_mine(shooter):
		return
	var spec := WeaponSpec.resolve(weapon_id)
	if spec == null:
		return
	var ref := Net.world.ref_of(shooter)
	if spec.is_hitscan():
		Net.send_event(NetProto.EV_SHOT, [ref, weapon_id, origin, direction])
	elif spec.sound_fire != "":
		Net.send_event(NetProto.EV_SOUND, [spec.sound_fire, origin, 0.0, 1.0, 120.0])


func _play_shot(ref: Variant, weapon_id: String, origin: Vector3, direction: Vector3) -> void:
	if _too_far(origin) and not Net.is_host():
		return
	var node := Net.world.node_of(ref)
	if node == Game.player:
		return
	var opts := {"cosmetic": true, "no_crime": true}
	if node != null and node.has_method("get_muzzle_node"):
		var mn: Variant = node.call("get_muzzle_node")
		if mn is Node3D and is_instance_valid(mn):
			opts["muzzle_node"] = mn
			opts["muzzle"] = (mn as Node3D).global_position
	if _too_far(origin):
		opts["no_fx"] = true            # the host still needs the noise for its pedestrians
		opts["no_sound"] = true
	_replaying = true
	Combat.fire_hitscan(origin, direction, weapon_id, node, opts)
	_replaying = false
	if node is NetAvatar:
		(node as NetAvatar).play_remote_action("fire", -1.0)


# --- projectiles / explosions -----------------------------------------------------------------------

func on_local_projectile(p: Node, velocity: Vector3) -> void:
	if _replaying or not Net.has_remote_players():
		return
	var who: Variant = p.get("instigator")
	if who != null and is_instance_valid(who) and not _is_mine(who):
		return
	Net.send_event(NetProto.EV_PROJECTILE, [Net.world.ref_of(who), str(p.get("kind")), (p as Node3D).global_position,
			velocity, float(p.get("fuse")), str(p.get("weapon_id"))])


func _on_explosion(position: Vector3, radius: float, _instigator: Node) -> void:
	if _replaying or not Net.has_remote_players():
		return
	Net.send_event(NetProto.EV_EXPLOSION, [position, radius])


# --- deaths -----------------------------------------------------------------------------------------

func _on_player_died(cause: String) -> void:
	if not Net.is_active():
		return
	var p := Game.player as Player
	var kref: Array = []
	var weapon := ""
	if p != null and cause != "fall" and cause != "drown":
		var info := p.last_damage_info
		var inst: Variant = info.get("instigator", null)
		kref = Net.world.ref_of(inst)
		if inst != null and is_instance_valid(inst) and inst is Node and (inst as Node).is_in_group("vehicle"):
			var drv: Variant = (inst as Node).get("driver")
			var dref := Net.world.ref_of(drv)
			if not dref.is_empty():
				kref = dref
		weapon = str(info.get("weapon_id", ""))
	if kref.size() >= 2 and int(kref[0]) == NetProto.REF_PLAYER and int(kref[1]) == Net.my_id:
		kref = []
	Net.report_local_death(kref, cause, weapon)


# --- events -----------------------------------------------------------------------------------------

func handle_event(kind: int, a: Array, origin: int) -> void:
	match kind:
		NetProto.EV_DAMAGE:
			if a.size() >= 2 and a[1] is Dictionary:
				_handle_damage(a[0], a[1], origin)
		NetProto.EV_SHOT:
			if a.size() >= 4 and a[2] is Vector3 and a[3] is Vector3:
				_play_shot(a[0], str(a[1]), a[2], a[3])
		NetProto.EV_ANIM:
			if a.size() >= 3:
				var node := Net.world.node_of(a[0])
				if node is NetAvatar:
					(node as NetAvatar).play_remote_action(str(a[1]), float(a[2]))
				elif node is NpcBase and (node as NpcBase).net_puppet:
					(node as NpcBase).play_action(str(a[1]), float(a[2]))
		NetProto.EV_PROJECTILE:
			if a.size() >= 6 and a[2] is Vector3 and a[3] is Vector3:
				if _too_far(a[2]):
					return
				_replaying = true
				Projectile.launch(str(a[1]), a[2], a[3], Net.world.node_of(a[0]),
						{"fuse": float(a[4]), "weapon_id": str(a[5]), "net_cosmetic": true})
				_replaying = false
		NetProto.EV_EXPLOSION:
			if a.size() >= 2 and a[0] is Vector3:
				if (a[0] as Vector3).distance_to(Game.get_player_position()) > 700.0:
					return
				_replaying = true
				Fx.explosion(a[0], float(a[1]), 0.0, null, {"no_damage": true, "no_crime": true})
				_replaying = false
		NetProto.EV_SOUND:
			if a.size() >= 5 and a[1] is Vector3 and not _too_far(a[1]):
				Audio.play_at(str(a[0]), a[1], float(a[2]), float(a[3]), float(a[4]), "Weapons")


func _handle_damage(ref: Variant, d: Dictionary, origin: int) -> void:
	var auth := Net.world.authority_of(ref)
	if auth != Net.my_id:
		if Net.is_host() and auth != 0 and auth != origin:
			Net.send_event_to(auth, NetProto.EV_DAMAGE, [ref, d])
		return
	var target := Net.world.node_of(ref)
	if target == null or not target.has_method("apply_damage"):
		return
	var inst := Net.world.node_of(d.get("i", []))
	var info := NetProto.unpack_damage(d, inst)
	target.call("apply_damage", info)
