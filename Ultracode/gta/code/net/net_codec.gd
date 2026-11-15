class_name NetCodec
extends RefCounted
## Snapshot state blobs of the three replicated body types: player, vehicle, NPC.
## write_* packs the live node, read_* returns a plain Dictionary (see NetWorld / NetAvatar).

static var _weapon_ids: Array = []


static func weapon_index(id: String) -> int:
	if id == "" or id == "<null>":
		return 0
	if _weapon_ids.is_empty():
		_weapon_ids = Registry.ids("weapons")
	return _weapon_ids.find(id) + 1


static func weapon_id(index: int) -> String:
	if _weapon_ids.is_empty():
		_weapon_ids = Registry.ids("weapons")
	if index <= 0 or index > _weapon_ids.size():
		return ""
	return str(_weapon_ids[index - 1])


# =================================================================================================
# player
# =================================================================================================

static func write_player(b: StreamPeerBuffer, p: Player) -> void:
	var a := p.animator
	var veh := p.current_vehicle
	var veh_nid := 0
	if veh != null and is_instance_valid(veh):
		veh_nid = int(veh.get("net_id")) if veh.get("net_id") != null else 0
	var f1 := 0
	if p.is_dead:
		f1 |= 1
	if veh_nid != 0:
		f1 |= 2
	if p.is_aiming:
		f1 |= 4
	if p.is_crouching:
		f1 |= 8
	if p.is_sprinting:
		f1 |= 16
	if p.is_swimming:
		f1 |= 32
	if p.is_underwater:
		f1 |= 64
	if p.state_id == "ragdoll":
		f1 |= 128
	var f2 := 0
	if p.in_stealth:
		f2 |= 1
	if p.state_id == "parachute":
		f2 |= 2
	if p.has_parachute:
		f2 |= 4
	if a != null and a.hand_target_weight_r > 0.01:
		f2 |= 8
	if a != null and a.hand_target_weight_l > 0.01:
		f2 |= 16
	b.put_u8(f1)
	b.put_u8(f2)
	var pos := p.global_position
	if p.state != null and (p.state_id == "ragdoll" or p.state_id == "dead"):
		pos = p.state.get_focus_position()
	NetProto.put_vec3(b, pos)
	NetProto.put_angle(b, p.global_rotation.y)
	NetProto.put_vel(b, Game.get_player_velocity())
	NetProto.put_u8f(b, clampf(p.health / maxf(p.max_health, 1.0), 0.0, 1.0))
	NetProto.put_u8f(b, clampf(p.armor / maxf(p.max_armor, 1.0), 0.0, 1.0))
	var wid := ""
	if p.inventory != null and is_instance_valid(p.inventory):
		wid = str(p.inventory.get("current_id"))
		if wid == "fists":
			wid = ""
	b.put_u8(weapon_index(wid))
	NetProto.put_angle(b, p.get_view_yaw())
	NetProto.put_s8f(b, p.get_view_pitch(), 1.6)
	if veh_nid != 0:
		b.put_u32(veh_nid)
		b.put_u8(clampi(p.seat_index, 0, 255))
	# --- animator
	if a == null:
		b.put_u8(255)
		return
	b.put_u8(int(HumanoidAnimator.STATE_IDS.get(a.state, 0)))
	b.put_u8(maxi(NetProto.WEAPON_POSES.find(a.weapon_pose), 0))
	b.put_u16(clampi(roundi(a.speed * 100.0), 0, 65535))
	NetProto.put_s8f(b, a.move_dir_local.x)
	NetProto.put_s8f(b, a.move_dir_local.y)
	NetProto.put_s8f(b, a.aim_pitch, 1.6)
	NetProto.put_u8f(b, a.aim_weight)
	NetProto.put_s8f(b, a.aim_yaw, 3.2)
	NetProto.put_s8f(b, a.lean)
	NetProto.put_s8f(b, a.accel_lean)
	NetProto.put_s8f(b, a.turn_rate, 12.0)
	NetProto.put_s8f(b, a.steer)
	NetProto.put_s16f(b, a.vertical_speed, 80.0)
	NetProto.put_u8f(b, a.sneak)
	NetProto.put_u8f(b, a.flare)
	NetProto.put_s8f(b, a.look_yaw, 1.6)
	NetProto.put_s8f(b, a.look_pitch, 1.6)
	NetProto.put_u8f(b, a.guard)
	b.put_u8(255 if a.motion_t < 0.0 else clampi(roundi(a.motion_t * 250.0), 0, 250))
	b.put_u8(clampi(a.motion_style, 0, 255))
	NetProto.put_u8f(b, a.motion_height, 3.0)
	NetProto.put_s8f(b, a.cover_side)
	NetProto.put_u8f(b, a.cover_peek)
	NetProto.put_u8f(b, a.cover_blind)
	NetProto.put_u8f(b, a.swim_depth, 2.5)
	if (f2 & 8) != 0:
		NetProto.put_s8f(b, a.hand_target_r.x, 2.5)
		NetProto.put_s8f(b, a.hand_target_r.y, 2.5)
		NetProto.put_s8f(b, a.hand_target_r.z, 2.5)
		NetProto.put_u8f(b, a.hand_target_weight_r)
	if (f2 & 16) != 0:
		NetProto.put_s8f(b, a.hand_target_l.x, 2.5)
		NetProto.put_s8f(b, a.hand_target_l.y, 2.5)
		NetProto.put_s8f(b, a.hand_target_l.z, 2.5)
		NetProto.put_u8f(b, a.hand_target_weight_l)


static func read_player(b: StreamPeerBuffer) -> Dictionary:
	var d := {}
	var f1 := b.get_u8()
	var f2 := b.get_u8()
	d["dead"] = (f1 & 1) != 0
	d["aiming"] = (f1 & 4) != 0
	d["crouching"] = (f1 & 8) != 0
	d["sprinting"] = (f1 & 16) != 0
	d["swimming"] = (f1 & 32) != 0
	d["underwater"] = (f1 & 64) != 0
	d["ragdoll"] = (f1 & 128) != 0
	d["stealth"] = (f2 & 1) != 0
	d["chute"] = (f2 & 2) != 0
	d["pos"] = NetProto.get_vec3(b)
	d["yaw"] = NetProto.get_angle(b)
	d["vel"] = NetProto.get_vel(b)
	d["health"] = NetProto.get_u8f(b)
	d["armor"] = NetProto.get_u8f(b)
	d["weapon"] = weapon_id(b.get_u8())
	d["view_yaw"] = NetProto.get_angle(b)
	d["view_pitch"] = NetProto.get_s8f(b, 1.6)
	d["veh"] = 0
	d["seat"] = 0
	if (f1 & 2) != 0:
		d["veh"] = b.get_u32()
		d["seat"] = b.get_u8()
	var st := b.get_u8()
	if st == 255:
		d["anim"] = false
		return d
	d["anim"] = true
	d["a_state"] = st
	d["a_pose"] = b.get_u8()
	d["a_speed"] = float(b.get_u16()) * 0.01
	var mx := NetProto.get_s8f(b)
	var my := NetProto.get_s8f(b)
	d["a_move"] = Vector2(mx, my)
	d["a_aim_pitch"] = NetProto.get_s8f(b, 1.6)
	d["a_aim_weight"] = NetProto.get_u8f(b)
	d["a_aim_yaw"] = NetProto.get_s8f(b, 3.2)
	d["a_lean"] = NetProto.get_s8f(b)
	d["a_accel"] = NetProto.get_s8f(b)
	d["a_turn"] = NetProto.get_s8f(b, 12.0)
	d["a_steer"] = NetProto.get_s8f(b)
	d["a_vspeed"] = NetProto.get_s16f(b, 80.0)
	d["a_sneak"] = NetProto.get_u8f(b)
	d["a_flare"] = NetProto.get_u8f(b)
	d["a_look_yaw"] = NetProto.get_s8f(b, 1.6)
	d["a_look_pitch"] = NetProto.get_s8f(b, 1.6)
	d["a_guard"] = NetProto.get_u8f(b)
	var mt := b.get_u8()
	d["a_motion_t"] = -1.0 if mt == 255 else float(mt) / 250.0
	d["a_motion_style"] = b.get_u8()
	d["a_motion_height"] = NetProto.get_u8f(b, 3.0)
	d["a_cover_side"] = NetProto.get_s8f(b)
	d["a_cover_peek"] = NetProto.get_u8f(b)
	d["a_cover_blind"] = NetProto.get_u8f(b)
	d["a_swim_depth"] = NetProto.get_u8f(b, 2.5)
	d["a_hand_r_w"] = 0.0
	d["a_hand_l_w"] = 0.0
	if (f2 & 8) != 0:
		var x := NetProto.get_s8f(b, 2.5)
		var y := NetProto.get_s8f(b, 2.5)
		var z := NetProto.get_s8f(b, 2.5)
		d["a_hand_r"] = Vector3(x, y, z)
		d["a_hand_r_w"] = NetProto.get_u8f(b)
	if (f2 & 16) != 0:
		var x2 := NetProto.get_s8f(b, 2.5)
		var y2 := NetProto.get_s8f(b, 2.5)
		var z2 := NetProto.get_s8f(b, 2.5)
		d["a_hand_l"] = Vector3(x2, y2, z2)
		d["a_hand_l_w"] = NetProto.get_u8f(b)
	return d


# =================================================================================================
# vehicle
# =================================================================================================

static func write_vehicle(b: StreamPeerBuffer, v: VehicleBase) -> void:
	var puppet := v.net_puppet
	var asleep := v.sleeping and not puppet
	var f1 := 0
	if asleep:
		f1 |= 1
	if v.engine_on:
		f1 |= 2
	if v.siren_on:
		f1 |= 4
	if v.horn_on:
		f1 |= 8
	if v.is_braking():
		f1 |= 16
	if v.is_reversing():
		f1 |= 32
	if v.in_handbrake:
		f1 |= 64
	if v.on_fire:
		f1 |= 128
	var f2 := (v.headlight_mode & 3) | ((clampi(v.indicator, -1, 2) + 1) << 2)
	if v.destroyed:
		f2 |= 16
	if v.in_water:
		f2 |= 32
	if v.stalled:
		f2 |= 64
	b.put_u8(f1)
	b.put_u8(f2)
	var xf := v.global_transform
	NetProto.put_vec3(b, xf.origin)
	NetProto.put_quat(b, xf.basis.orthonormalized().get_rotation_quaternion())
	if asleep:
		NetProto.put_vel(b, Vector3.ZERO)
		NetProto.put_ang(b, Vector3.ZERO)
	else:
		NetProto.put_vel(b, v.net_velocity if puppet else v.linear_velocity)
		NetProto.put_ang(b, v.net_angular if puppet else v.angular_velocity)
	NetProto.put_s8f(b, v.in_steer)
	NetProto.put_s8f(b, v.in_throttle)
	NetProto.put_u8f(b, v.get_health_ratio())
	b.put_u16(v.net_get_damage_bits())
	b.put_u8(clampi(roundi(v.get_lid_open("hood") * 15.0), 0, 15) | (clampi(roundi(v.get_lid_open("trunk") * 15.0), 0, 15) << 4))
	var e := v.net_get_extra()
	var n := mini(e.size(), 12)
	b.put_u8(n)
	for i in n:
		NetProto.put_s16f(b, e[i], 32.0)


static func read_vehicle(b: StreamPeerBuffer) -> Dictionary:
	var f1 := b.get_u8()
	var f2 := b.get_u8()
	var d := {"f1": f1, "f2": f2}
	d["pos"] = NetProto.get_vec3(b)
	d["rot"] = NetProto.get_quat(b)
	d["vel"] = NetProto.get_vel(b)
	d["ang"] = NetProto.get_ang(b)
	d["steer"] = NetProto.get_s8f(b)
	d["throttle"] = NetProto.get_s8f(b)
	d["health"] = NetProto.get_u8f(b)
	d["dmg"] = b.get_u16()
	d["lids"] = b.get_u8()
	var n := b.get_u8()
	var e := PackedFloat32Array()
	e.resize(n)
	for i in n:
		e[i] = NetProto.get_s16f(b, 32.0)
	d["extra"] = e
	return d


## Applies everything of a vehicle state except the transform / velocity (the interpolation
## buffer owns those).
static func apply_vehicle_flags(v: VehicleBase, d: Dictionary) -> void:
	var f1 := int(d["f1"])
	var f2 := int(d["f2"])
	var engine := (f1 & 2) != 0
	if engine != v.engine_on:
		if engine:
			v.start_engine()
			v.engine_on = true
		else:
			v.engine_on = false
	var siren := (f1 & 4) != 0
	if siren != v.siren_on:
		v.siren_on = siren
		if v.lights != null:
			v.lights.refresh()
	v.horn_on = (f1 & 8) != 0
	v.net_braking = (f1 & 16) != 0
	v.net_reversing = (f1 & 32) != 0
	v.in_handbrake = (f1 & 64) != 0
	v.on_fire = (f1 & 128) != 0
	var head := f2 & 3
	var ind := ((f2 >> 2) & 3) - 1
	if head != v.headlight_mode or ind != v.indicator:
		v.headlight_mode = head
		v.indicator = ind
		if v.lights != null:
			v.lights.refresh()
	v.in_water = (f2 & 32) != 0
	v.stalled = (f2 & 64) != 0
	v.in_steer = float(d["steer"])
	v.in_throttle = float(d["throttle"])
	var destroyed := (f2 & 16) != 0
	if destroyed and not v.destroyed:
		if v.damage != null:
			v.damage.net_wreck()
	elif not destroyed and v.destroyed:
		if v.damage != null:
			v.damage.repair()
			v.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
			v.freeze = true
	if not v.destroyed:
		v.health = float(d["health"]) * v.max_health
		v.net_set_damage_bits(int(d["dmg"]))
		var lids := int(d["lids"])
		var hood := float(lids & 15) / 15.0
		var trunk := float((lids >> 4) & 15) / 15.0
		if absf(hood - v.get_lid_open("hood")) > 0.05:
			v.set_lid_open("hood", hood)
		if absf(trunk - v.get_lid_open("trunk")) > 0.05:
			v.set_lid_open("trunk", trunk)
	v.net_set_extra(d["extra"])


# =================================================================================================
# NPC
# =================================================================================================

static func write_npc(b: StreamPeerBuffer, n: NpcBase) -> void:
	var veh := n.current_vehicle
	var veh_nid := 0
	if veh != null and is_instance_valid(veh) and veh.get("net_id") != null:
		veh_nid = int(veh.get("net_id"))
	var has_look := n.look_target != Vector3.INF
	var f1 := 0
	if n.is_dead:
		f1 |= 1
	if n.is_down:
		f1 |= 2
	if n.is_crouching:
		f1 |= 4
	if n.is_aiming:
		f1 |= 8
	if n.phone_pose:
		f1 |= 16
	if veh_nid != 0:
		f1 |= 32
	if has_look:
		f1 |= 64
	b.put_u8(f1)
	NetProto.put_vec3(b, n.global_position)
	NetProto.put_angle(b, n.global_rotation.y)
	NetProto.put_s8f(b, n._glide_vel.x, 12.0)
	NetProto.put_s8f(b, n._glide_vel.z, 12.0)
	b.put_u8(maxi(NetProto.NPC_POSES.find(n._pose), 0))
	var pitch := 0.0
	if n.is_aiming and n._aim_pos != Vector3.INF:
		var to := n._aim_pos - n.get_eye_position()
		pitch = clampf(atan2(to.y, maxf(Vector2(to.x, to.z).length(), 0.01)), -1.2, 1.2)
	NetProto.put_s8f(b, pitch, 1.3)
	NetProto.put_u8f(b, n.gesture)
	NetProto.put_u8f(b, clampf(n.health / maxf(n.max_health, 1.0), 0.0, 1.0))
	b.put_u8(weapon_index(n.weapon_id))
	if veh_nid != 0:
		b.put_u32(veh_nid)
		b.put_u8(clampi(n.seat_index, 0, 255))
	if has_look:
		NetProto.put_vec3(b, n.look_target)


static func read_npc(b: StreamPeerBuffer) -> Dictionary:
	var f1 := b.get_u8()
	var d := {"f1": f1}
	d["pos"] = NetProto.get_vec3(b)
	d["yaw"] = NetProto.get_angle(b)
	var vx := NetProto.get_s8f(b, 12.0)
	var vz := NetProto.get_s8f(b, 12.0)
	d["vel"] = Vector3(vx, 0.0, vz)
	d["pose"] = b.get_u8()
	d["aim_pitch"] = NetProto.get_s8f(b, 1.3)
	d["gesture"] = NetProto.get_u8f(b)
	d["health"] = NetProto.get_u8f(b)
	d["weapon"] = weapon_id(b.get_u8())
	d["veh"] = 0
	d["seat"] = 0
	if (f1 & 32) != 0:
		d["veh"] = b.get_u32()
		d["seat"] = b.get_u8()
	d["look"] = Vector3.INF
	if (f1 & 64) != 0:
		d["look"] = NetProto.get_vec3(b)
	return d
