class_name NetProto
extends RefCounted
## Multiplayer wire protocol: constants, event ids and the compact binary helpers that the snapshot
## packets use (docs/MULTIPLAYER.md). Snapshots are hand-packed with a StreamPeerBuffer because a
## busy street is ~100 entities at 10-20 Hz: Variant arrays would cost several times the bandwidth.

const VERSION := 3                   ## bumped whenever a packet layout / event changes
const GAME_PORT := 24565             ## UDP, ENet
const DISCOVERY_PORT := 24566        ## UDP, host discovery (LAN broadcast + tailnet unicast probes)
const DISCOVERY_MAGIC := "HBAY?"     ## probe; the answer starts with DISCOVERY_REPLY
const DISCOVERY_REPLY := "HBAY!"
const MAX_PLAYERS := 8               ## hard limit of slots (the host setting is usually 4)

## ENet transfer channels.
const CH_EVENTS := 0                 ## reliable, ordered
const CH_SNAPSHOT := 1               ## unreliable, ordered (old snapshots are dropped)
const CH_FX := 2                     ## reliable cosmetic events (shots, sounds) - never block entity events

# --- reliable events (Net._rpc_ev) ------------------------------------------------------------------
enum {
	EV_SPAWN,            ## [nid, kind, auth_peer, desc: Dictionary, state: PackedByteArray]
	EV_DESPAWN,          ## [nid]
	EV_AUTH,             ## [nid, new_auth_peer]
	EV_CLAIM,            ## [nid]                      client -> host: "I drive this now"
	EV_RELEASE,          ## [nid, state]               client -> host: "take it back"
	EV_DENY,             ## [nid]                      host -> client: claim refused, get out
	EV_DAMAGE,           ## [target_ref, info: Dictionary]   routed to the authority of the target
	EV_JACK,             ## [nid, seat, thief_ref]     routed to the authority: pull the AI driver out
	EV_EJECT,            ## [peer, nid, xform, impulse]  routed to that player: you were thrown out
	EV_KNOCK,            ## [target_ref, impulse]      routed to the authority: knock_down
	EV_VEH_STATE,        ## [nid, what: String, value]  authority -> all: destroyed / repaired / tire / paint / mods / lids
	EV_NPC_STATE,        ## [nid, what: String, value]  authority -> all: died / down / up / weapon / action
	EV_ANIM,             ## [ref, action, duration]    one-shot animator action of a player / NPC
	EV_SHOT,             ## [ref, weapon_id, origin, dir, spread, pellets]   cosmetic re-fire
	EV_PROJECTILE,       ## [ref, kind, origin, velocity, fuse, weapon_id]
	EV_EXPLOSION,        ## [pos, radius, visual_scale]
	EV_SOUND,            ## [id, pos, vol_db, pitch, max_dist]
	EV_KILL,             ## [victim_peer, killer_ref, cause, weapon_id]
	EV_RESPAWN,          ## [peer, pos]
	EV_APPEARANCE,       ## [peer, appearance: Dictionary]
	EV_CHAT,             ## [peer, text]
	EV_WORLD,            ## [hour, day, weather_id, transition, rate]
	EV_NOTIFY,           ## [text, kind]
	EV_CRIME,            ## [peer, crime_id, pos]      host NPC witnessed a crime of that player
	EV_TRAM,             ## [index, s, v, phase, next_stop, dwell_t, door_target]
}

## Events the host forwards to every other client after handling them.
const RELAY_ALL := [EV_VEH_STATE, EV_NPC_STATE, EV_ANIM, EV_SHOT, EV_PROJECTILE, EV_EXPLOSION, EV_SOUND,
		EV_KILL, EV_RESPAWN, EV_APPEARANCE, EV_CHAT]
## Cosmetic events travel on their own channel.
const FX_EVENTS := [EV_ANIM, EV_SHOT, EV_PROJECTILE, EV_EXPLOSION, EV_SOUND]

# --- entity references ------------------------------------------------------------------------------
## A node on the wire: [REF_PLAYER, peer_id] or [REF_ENTITY, nid]; [] = nobody / unknown.
const REF_PLAYER := 0
const REF_ENTITY := 1

# --- entity kinds -----------------------------------------------------------------------------------
const KIND_VEHICLE := 0
const KIND_NPC := 1

# --- snapshot sections ------------------------------------------------------------------------------
const SEC_PLAYER := 1
const SEC_VEHICLE := 2
const SEC_NPC := 3
const SEC_END := 0

const NPC_POSES: Array[String] = ["", "cower", "surrender", "sit", "kneel", "spray"]
const WEAPON_POSES: Array[String] = ["none", "pistol", "rifle", "melee", "rpg", "throw"]


# =================================================================================================
# binary helpers
# =================================================================================================

static func put_vec3(b: StreamPeerBuffer, v: Vector3) -> void:
	b.put_float(v.x)
	b.put_float(v.y)
	b.put_float(v.z)


static func get_vec3(b: StreamPeerBuffer) -> Vector3:
	var x := b.get_float()
	var y := b.get_float()
	var z := b.get_float()
	return Vector3(x, y, z)


## Velocity in cm/s (+-327 m/s).
static func put_vel(b: StreamPeerBuffer, v: Vector3) -> void:
	b.put_16(clampi(roundi(v.x * 100.0), -32767, 32767))
	b.put_16(clampi(roundi(v.y * 100.0), -32767, 32767))
	b.put_16(clampi(roundi(v.z * 100.0), -32767, 32767))


static func get_vel(b: StreamPeerBuffer) -> Vector3:
	var x := b.get_16()
	var y := b.get_16()
	var z := b.get_16()
	return Vector3(x, y, z) * 0.01


## Angular velocity in mrad/s (+-32 rad/s).
static func put_ang(b: StreamPeerBuffer, v: Vector3) -> void:
	b.put_16(clampi(roundi(v.x * 1000.0), -32767, 32767))
	b.put_16(clampi(roundi(v.y * 1000.0), -32767, 32767))
	b.put_16(clampi(roundi(v.z * 1000.0), -32767, 32767))


static func get_ang(b: StreamPeerBuffer) -> Vector3:
	var x := b.get_16()
	var y := b.get_16()
	var z := b.get_16()
	return Vector3(x, y, z) * 0.001


static func put_quat(b: StreamPeerBuffer, q: Quaternion) -> void:
	b.put_16(clampi(roundi(q.x * 32767.0), -32767, 32767))
	b.put_16(clampi(roundi(q.y * 32767.0), -32767, 32767))
	b.put_16(clampi(roundi(q.z * 32767.0), -32767, 32767))
	b.put_16(clampi(roundi(q.w * 32767.0), -32767, 32767))


static func get_quat(b: StreamPeerBuffer) -> Quaternion:
	var x := float(b.get_16())
	var y := float(b.get_16())
	var z := float(b.get_16())
	var w := float(b.get_16())
	var q := Quaternion(x, y, z, w)
	if q.length_squared() < 0.000001:
		return Quaternion.IDENTITY
	return q.normalized()


## Angle in radians as 16 bit.
static func put_angle(b: StreamPeerBuffer, a: float) -> void:
	b.put_16(clampi(roundi(wrapf(a, -PI, PI) / PI * 32767.0), -32767, 32767))


static func get_angle(b: StreamPeerBuffer) -> float:
	return float(b.get_16()) / 32767.0 * PI


## v in [-range, range] as a signed byte.
static func put_s8f(b: StreamPeerBuffer, v: float, value_range: float = 1.0) -> void:
	b.put_8(clampi(roundi(v / value_range * 127.0), -127, 127))


static func get_s8f(b: StreamPeerBuffer, value_range: float = 1.0) -> float:
	return float(b.get_8()) / 127.0 * value_range


## v in [0, range] as an unsigned byte.
static func put_u8f(b: StreamPeerBuffer, v: float, value_range: float = 1.0) -> void:
	b.put_u8(clampi(roundi(v / value_range * 255.0), 0, 255))


static func get_u8f(b: StreamPeerBuffer, value_range: float = 1.0) -> float:
	return float(b.get_u8()) / 255.0 * value_range


## v in [-range, range] as 16 bit.
static func put_s16f(b: StreamPeerBuffer, v: float, value_range: float) -> void:
	b.put_16(clampi(roundi(v / value_range * 32767.0), -32767, 32767))


static func get_s16f(b: StreamPeerBuffer, value_range: float) -> float:
	return float(b.get_16()) / 32767.0 * value_range


# =================================================================================================
# reliable-event payload helpers (Variants)
# =================================================================================================

## Damage info for the wire: plain values only (the instigator travels as a reference).
static func pack_damage(info: Dictionary, instigator_ref: Array) -> Dictionary:
	var out := {
		"a": float(info.get("amount", 0.0)),
		"t": str(info.get("type", "generic")),
		"i": instigator_ref,
		"p": info.get("position", Vector3.ZERO),
		"d": info.get("direction", Vector3.ZERO),
	}
	var imp: Variant = info.get("impulse", 0.0)
	if imp is Vector3:
		imp = (imp as Vector3).length()
	if float(imp) != 0.0:
		out["m"] = float(imp)
	var w := str(info.get("weapon_id", ""))
	if w != "":
		out["w"] = w
	var z := str(info.get("zone", ""))
	if z != "":
		out["z"] = z
	var flags := 0
	if bool(info.get("headshot", false)):
		flags |= 1
	if bool(info.get("silent", false)):
		flags |= 2
	if bool(info.get("knockdown", false)):
		flags |= 4
	if bool(info.get("heavy", false)):
		flags |= 8
	if bool(info.get("knockout", false)):
		flags |= 16
	if bool(info.get("no_ragdoll", false)):
		flags |= 32
	if flags != 0:
		out["f"] = flags
	if info.has("knockout_seconds"):
		out["k"] = float(info["knockout_seconds"])
	if info.has("pellets"):
		out["n"] = int(info["pellets"])
	return out


## Rebuild a Dmg info dictionary on the receiving side (`instigator` already resolved to a Node).
static func unpack_damage(d: Dictionary, instigator: Node) -> Dictionary:
	var flags := int(d.get("f", 0))
	var info := Dmg.make(float(d.get("a", 0.0)), str(d.get("t", "generic")), instigator,
			d.get("p", Vector3.ZERO), d.get("d", Vector3.ZERO), {
		"impulse": float(d.get("m", 0.0)),
		"weapon_id": str(d.get("w", "")),
		"zone": str(d.get("z", "")),
		"headshot": (flags & 1) != 0,
		"silent": (flags & 2) != 0,
		"net": true,                      # arrived over the network: never forward it again
	})
	if (flags & 4) != 0:
		info["knockdown"] = true
	if (flags & 8) != 0:
		info["heavy"] = true
	if (flags & 16) != 0:
		info["knockout"] = true
		if d.has("k"):
			info["knockout_seconds"] = float(d["k"])
	if (flags & 32) != 0:
		info["no_ragdoll"] = true
	if d.has("n"):
		info["pellets"] = int(d["n"])
	return info
