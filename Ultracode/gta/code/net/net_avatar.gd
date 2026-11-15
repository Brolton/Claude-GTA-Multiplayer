class_name NetAvatar
extends NpcBase
## Another player as seen on this machine (docs/MULTIPLAYER.md "Avatars").
##
## An NpcBase body without brain / senses / steering: the shared humanoid visual, the procedural
## animator fed with the owner's animator parameters, the weapon model in the hand, ragdolls, and
## the NPC seat logic for vehicles. It lives on the NPC layer and in the "npc" group, so bullets,
## melee, explosions and bumpers find it like any character - and every hit is forwarded to the
## machine of its owner (NpcBase.apply_damage -> Net.world.on_puppet_npc_damage).
## It is deliberately NOT in the "player" group: single-player code that asks for "the player"
## always means the local one.

const NAME_HEIGHT := 2.08

var peer_id: int = 0
var player_name: String = ""
var interp := NetInterp.new()
var view_yaw: float = 0.0
var view_pitch: float = 0.0
var armor_ratio: float = 0.0
var has_state: bool = false

var _st: Dictionary = {}
var _label: Label3D = null
var _ragdolled: bool = false
var _was_dead: bool = false
var _want_veh: int = 0
var _want_seat: int = 0
var _weapon_now: String = ""
var _hidden_far: bool = false


func setup_avatar(peer: int, pname: String, appearance: Dictionary, color: Color) -> void:
	peer_id = peer
	player_name = pname
	net_puppet = true
	managed = false
	persistent = true
	var arch: Variant = Registry.get_def("npc_archetypes", "civilian_m")
	var opts := {"weapon": "", "brain": Node.new(), "persistent": true}
	if not appearance.is_empty():
		opts["appearance"] = appearance
	configure(arch as Resource, opts, peer)
	faction = "player"
	hostile = false
	cash_carried = 0
	for g in get_groups():
		if str(g) != "npc" and not str(g).begins_with("_"):
			remove_from_group(g)
	add_to_group("net_player")
	set_meta("humanoid", true)
	set_meta("net_peer", peer)
	max_health = 100.0
	health = 100.0
	_label = Label3D.new()
	_label.name = "NameTag"
	_label.text = pname
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.fixed_size = true
	_label.pixel_size = 0.0011
	_label.font_size = 30
	_label.outline_size = 10
	_label.modulate = color
	_label.outline_modulate = Color(0.02, 0.03, 0.06, 0.9)
	_label.no_depth_test = true          # friends are easy to find, also behind buildings
	_label.shaded = false
	_label.double_sided = true
	_label.position = Vector3(0.0, NAME_HEIGHT, 0.0)
	add_child(_label)
	set_physics_process(true)
	set_process(true)


func set_player_name(pname: String, color: Color) -> void:
	player_name = pname
	if _label != null:
		_label.text = pname
		_label.modulate = color


func set_appearance(appearance: Dictionary) -> void:
	if visual != null and visual.has_method("apply_appearance") and not appearance.is_empty():
		visual.call("apply_appearance", appearance)


# =================================================================================================
# state from the owner
# =================================================================================================

## One decoded player snapshot (NetCodec.read_player) stamped with host time `t`.
func push_state(t: float, d: Dictionary) -> void:
	_st = d
	has_state = true
	interp.push(t, d["pos"], Quaternion(Vector3.UP, float(d["yaw"])), d["vel"])
	view_yaw = float(d["view_yaw"])
	view_pitch = float(d["view_pitch"])
	health = float(d["health"]) * max_health
	armor_ratio = float(d["armor"])
	is_crouching = bool(d["crouching"])
	is_aiming = bool(d["aiming"])
	height = CROUCH_HEIGHT if is_crouching else HEIGHT
	_want_veh = int(d["veh"])
	_want_seat = int(d["seat"])
	var w := str(d["weapon"])
	if w != _weapon_now:
		_weapon_now = w
		set_weapon(w)
	var dead := bool(d["dead"])
	if dead and not _was_dead:
		_enter_dead()
	elif not dead and _was_dead:
		_leave_dead()
	_was_dead = dead
	var rag := bool(d["ragdoll"]) and not dead
	if rag and not _ragdolled:
		_ragdolled = true
		is_down = true
		_set_collision(false)
		_spawn_ragdoll(Vector3(float((d["vel"] as Vector3).x), 1.0, float((d["vel"] as Vector3).z)) * 30.0, true)
	elif not rag and _ragdolled:
		_ragdolled = false
		is_down = false
		_clear_ragdoll()
		if visual != null:
			visual.visible = true
		if not is_dead and current_vehicle == null:
			_set_collision(true)


## Position the owner last reported (also while seated / far away): minimap, focus of the host.
func get_net_position() -> Vector3:
	if current_vehicle != null and is_instance_valid(current_vehicle) and is_inside_tree():
		return current_vehicle.global_position
	if has_state:
		return _st["pos"]
	return global_position if is_inside_tree() else Vector3.ZERO


func get_net_velocity() -> Vector3:
	return _st["vel"] if has_state else Vector3.ZERO


func is_in_vehicle() -> bool:
	return _want_veh != 0


func _enter_dead() -> void:
	is_dead = true
	_ragdolled = false
	is_down = false
	_set_collision(false)
	if current_vehicle == null:
		_ragdoll_frame = Engine.get_physics_frames()
		var v: Vector3 = _st.get("vel", Vector3.ZERO)
		_spawn_death_ragdoll(v * 20.0)
	if _weapon_model != null and is_instance_valid(_weapon_model):
		_weapon_model.visible = false
	if _label != null:
		_label.visible = false


func _leave_dead() -> void:
	is_dead = false
	dead_time = 0.0
	_clear_ragdoll()
	if visual != null:
		visual.visible = true
	if _weapon_model != null and is_instance_valid(_weapon_model):
		_weapon_model.visible = true
	if _label != null:
		_label.visible = true
	if current_vehicle == null:
		_set_collision(true)
	interp.clear()
	if has_state:
		interp.push(Net.host_time(), _st["pos"], Quaternion(Vector3.UP, float(_st["yaw"])), Vector3.ZERO)
	if animator != null:
		animator.call("snap")


# =================================================================================================
# ticking
# =================================================================================================

func _physics_process(_delta: float) -> void:
	if not has_state or not is_inside_tree():
		return
	_sync_vehicle()
	if current_vehicle != null:
		return
	if is_dead or _ragdolled:
		_follow_ragdoll()
		if _ragdoll == null or not is_instance_valid(_ragdoll):
			global_position = _st["pos"]
		return
	if interp.sample(Net.host_time()):
		global_position = interp.out_pos
		rotation = Vector3(0.0, interp.out_rot.get_euler().y, 0.0)
		velocity = interp.out_vel
		_glide_vel = Vector3(interp.out_vel.x, 0.0, interp.out_vel.z)


func _sync_vehicle() -> void:
	var want: Node3D = null
	if _want_veh != 0 and not is_dead:
		want = Net.world.get_entity_node(_want_veh)
		if want != null and (not want.has_method("get_seat_node") or want.get("destroyed") == true):
			want = null
	if want == current_vehicle:
		if want != null and seat_index != _want_seat:
			_leave_seat()
			_seat_into(want, _want_seat)
		return
	if current_vehicle != null:
		_leave_seat()
	if want != null:
		# an NPC / stand-in still in that seat on this machine gives way to the player
		var occ: Variant = want.call("get_occupant", _want_seat) if want.has_method("get_occupant") else null
		if occ != null and is_instance_valid(occ) and occ != self and not (occ is NetAvatar) and want.has_method("occupant_exit"):
			want.call("occupant_exit", _want_seat)
			if occ is Node and (occ as Node).has_method("net_dismiss"):
				(occ as Node).call("net_dismiss")
		_ragdolled = false
		is_down = false
		_clear_ragdoll()
		if visual != null:
			visual.visible = true
		_seat_into(want, _want_seat)


func _leave_seat() -> void:
	var v := current_vehicle
	if v != null and is_instance_valid(v) and v.has_method("get_seat_of") and int(v.call("get_seat_of", self)) >= 0:
		v.call("occupant_exit", seat_index)
	var pos: Vector3 = _st.get("pos", global_position)
	_leave_vehicle_to(Transform3D(Basis(Vector3.UP, float(_st.get("yaw", 0.0))), pos))
	if is_dead or _ragdolled:
		_set_collision(false)
	interp.clear()
	interp.push(Net.host_time(), pos, Quaternion(Vector3.UP, float(_st.get("yaw", 0.0))), _st.get("vel", Vector3.ZERO))


func _process(delta: float) -> void:
	var a := animator as HumanoidAnimator
	if a == null or not has_state:
		return
	if visual != null and not visual.visible:
		return
	var d := _st
	if not bool(d.get("anim", false)):
		a.advance(delta)
		return
	var st_name := "idle"
	var sid := int(d["a_state"])
	for k: String in HumanoidAnimator.STATE_IDS:
		if int(HumanoidAnimator.STATE_IDS[k]) == sid:
			st_name = k
			break
	if is_dead:
		st_name = "dead"
	if a.state != st_name:
		a.state = st_name
	a.speed = float(d["a_speed"])
	a.move_dir_local = d["a_move"]
	a.aim_pitch = float(d["a_aim_pitch"])
	a.aim_weight = float(d["a_aim_weight"])
	a.aim_yaw = float(d["a_aim_yaw"])
	a.weapon_pose = NetProto.WEAPON_POSES[clampi(int(d["a_pose"]), 0, NetProto.WEAPON_POSES.size() - 1)]
	a.lean = float(d["a_lean"])
	a.accel_lean = float(d["a_accel"])
	a.turn_rate = float(d["a_turn"])
	a.steer = float(d["a_steer"])
	a.vertical_speed = float(d["a_vspeed"])
	a.sneak = float(d["a_sneak"])
	a.flare = float(d["a_flare"])
	a.look_yaw = float(d["a_look_yaw"])
	a.look_pitch = float(d["a_look_pitch"])
	a.guard = float(d["a_guard"])
	a.motion_t = float(d["a_motion_t"])
	a.motion_style = int(d["a_motion_style"])
	a.motion_height = float(d["a_motion_height"])
	a.cover_side = float(d["a_cover_side"])
	a.cover_peek = float(d["a_cover_peek"])
	a.cover_blind = float(d["a_cover_blind"])
	a.swim_depth = float(d["a_swim_depth"])
	a.hand_target_weight_r = float(d["a_hand_r_w"])
	a.hand_target_weight_l = float(d["a_hand_l_w"])
	if d.has("a_hand_r"):
		a.hand_target_r = d["a_hand_r"]
	if d.has("a_hand_l"):
		a.hand_target_l = d["a_hand_l"]
	a.advance(delta)


## One-shot action of the owner (reload, punch, enter_car ...).
func play_remote_action(action: String, duration: float) -> void:
	var a := animator as HumanoidAnimator
	if a != null:
		a.play_action(action, duration)


# =================================================================================================
# NpcBase overrides: everything that would change the body is the owner's decision
# =================================================================================================

func physics_tick(_delta: float) -> void:
	pass


func think_tick(_delta: float) -> void:
	pass


func anim_tick(_delta: float) -> void:
	pass


## A vehicle on this machine threw the avatar out (carjack by the local player, explosion):
## tell the owner - its Player does the real exit.
func on_vehicle_ejected(vehicle: Node3D, exit_xform: Transform3D, impulse: Vector3) -> void:
	Net.world.forward_eject(peer_id, vehicle, exit_xform, impulse)


func get_target_position() -> Vector3:
	if current_vehicle != null and is_inside_tree():
		return global_transform * Vector3(0.0, 0.42, 0.0)
	return global_position + Vector3(0.0, 0.85 if is_crouching else 1.25, 0.0)


func kill(_cause: String = "generic") -> void:
	pass


func heal(_amount: float) -> void:
	pass


func enter_vehicle(_vehicle: Node3D, _seat: int = 0, _instant: bool = false) -> void:
	pass


func exit_vehicle() -> void:
	pass


func can_be_cleaned() -> bool:
	return false


func set_sim_tier(tier: int) -> void:
	super.set_sim_tier(mini(tier, 1))
