class_name NetInterp
extends RefCounted
## Snapshot interpolation buffer of one remote body (docs/MULTIPLAYER.md "Interpolation").
## Snapshots are stamped in HOST time (seconds). The puppet is rendered a little in the past
## (`delay`, adapted to how often snapshots really arrive) and blended between the two snapshots
## around that moment; when the stream starves it runs on with the last velocity for a moment.

const CAPACITY := 12
const MAX_EXTRAPOLATE := 0.3         ## seconds past the newest snapshot
const MIN_DELAY := 0.07
const MAX_DELAY := 0.9

var delay: float = 0.12               ## current render delay behind host time
var out_pos: Vector3 = Vector3.ZERO
var out_rot: Quaternion = Quaternion.IDENTITY
var out_vel: Vector3 = Vector3.ZERO
var out_ang: Vector3 = Vector3.ZERO
var teleported: bool = false          ## the last sample crossed a jump (the owner teleported)
var count: int = 0

var _t := PackedFloat64Array()
var _pos := PackedVector3Array()
var _rot: Array[Quaternion] = []
var _vel := PackedVector3Array()
var _ang := PackedVector3Array()
var _interval: float = 0.05           ## smoothed time between snapshots
var _last_sample_t: float = -1.0


func clear() -> void:
	_t.clear()
	_pos.clear()
	_rot.clear()
	_vel.clear()
	_ang.clear()
	count = 0
	_last_sample_t = -1.0


func newest_time() -> float:
	return _t[count - 1] if count > 0 else -1.0


func newest_pos() -> Vector3:
	return _pos[count - 1] if count > 0 else out_pos


func push(t: float, pos: Vector3, rot: Quaternion, vel: Vector3 = Vector3.ZERO, ang: Vector3 = Vector3.ZERO) -> void:
	if count > 0:
		var last := _t[count - 1]
		if t <= last:
			return                      # out of order / duplicate: the newer one is already in
		var gap := t - last
		if gap < 2.0:
			_interval = lerpf(_interval, gap, 0.2)
		else:
			_interval = 0.1
	if count >= CAPACITY:
		_t.remove_at(0)
		_pos.remove_at(0)
		_rot.remove_at(0)
		_vel.remove_at(0)
		_ang.remove_at(0)
		count -= 1
	_t.append(t)
	_pos.append(pos)
	_rot.append(rot)
	_vel.append(vel)
	_ang.append(ang)
	count += 1
	# render far enough in the past to always have a snapshot on both sides
	var want := clampf(_interval * 1.6 + 0.03, MIN_DELAY, MAX_DELAY)
	delay = lerpf(delay, want, 0.1)


## Fills out_* for host time `now` (seconds). False while there is nothing to show yet.
func sample(now: float) -> bool:
	teleported = false
	if count == 0:
		return false
	var t := now - delay
	# time never runs backwards for the puppet (delay adaptation / clock corrections)
	if _last_sample_t >= 0.0 and t < _last_sample_t:
		t = minf(_last_sample_t, _t[count - 1] + MAX_EXTRAPOLATE)
	_last_sample_t = t
	var last := count - 1
	if t >= _t[last]:
		var ex := minf(t - _t[last], MAX_EXTRAPOLATE)
		out_pos = _pos[last] + _vel[last] * ex
		out_rot = _rot[last]
		if ex > 0.0 and _ang[last].length_squared() > 0.0001:
			var a := _ang[last]
			out_rot = (Quaternion(a.normalized(), a.length() * ex) * _rot[last]).normalized()
		# a body that stopped sending is at rest, not coasting forever
		var fade := 1.0 - ex / MAX_EXTRAPOLATE
		out_vel = _vel[last] * fade
		out_ang = _ang[last] * fade
		return true
	if t <= _t[0]:
		out_pos = _pos[0]
		out_rot = _rot[0]
		out_vel = _vel[0]
		out_ang = _ang[0]
		return true
	var i := last
	while i > 0 and _t[i - 1] > t:
		i -= 1
	var a_i := i - 1
	var span := _t[i] - _t[a_i]
	var k := clampf((t - _t[a_i]) / span, 0.0, 1.0) if span > 0.00001 else 1.0
	var pa := _pos[a_i]
	var pb := _pos[i]
	var jump := pa.distance_to(pb)
	if jump > 12.0 and jump > (_vel[a_i].length() + _vel[i].length()) * span + 6.0:
		# far more than the velocities explain: a teleport, never a slide through the city
		teleported = true
		out_pos = pb
		out_rot = _rot[i]
		out_vel = _vel[i]
		out_ang = _ang[i]
		return true
	if span > 0.00001 and span < 0.5:
		# cubic Hermite with the snapshot velocities: smooth arcs for cars between 10 Hz samples
		var k2 := k * k
		var k3 := k2 * k
		out_pos = pa * (2.0 * k3 - 3.0 * k2 + 1.0) + _vel[a_i] * ((k3 - 2.0 * k2 + k) * span) \
				+ pb * (-2.0 * k3 + 3.0 * k2) + _vel[i] * ((k3 - k2) * span)
	else:
		out_pos = pa.lerp(pb, k)
	out_rot = _rot[a_i].slerp(_rot[i], k)
	out_vel = _vel[a_i].lerp(_vel[i], k)
	out_ang = _ang[a_i].lerp(_ang[i], k)
	return true
