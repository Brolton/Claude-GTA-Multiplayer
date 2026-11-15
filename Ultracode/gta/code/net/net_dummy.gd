extends Node3D
## Seated stand-in driver of a PUPPET traffic vehicle (the multiplayer twin of TrafficDummy).
## The host's traffic system drives the real car; here only somebody has to sit at the wheel so
## the car is not empty, the seat counts as taken and a carjack has someone to pull out.
## Net.world attaches the humanoid visual only near the camera.

const HUMANOID_SCENE := "res://gta/scenes/characters/humanoid.tscn"

var look_archetype: String = "civilian_m"
var look_seed: int = 0
var vehicle: Node3D = null
var visual: Node3D = null
var animator: HumanoidAnimator = null
var health: float = 100.0


func _init() -> void:
	name = "NetDriver"


func has_visual() -> bool:
	return visual != null and is_instance_valid(visual)


func show_visual() -> void:
	if has_visual() or not ResourceLoader.exists(HUMANOID_SCENE):
		return
	var ps := load(HUMANOID_SCENE) as PackedScene
	if ps == null:
		return
	visual = ps.instantiate() as Node3D
	if visual == null:
		return
	visual.name = "DriverVisual"
	if "default_archetype" in visual:
		visual.set("default_archetype", "")
	add_child(visual)
	visual.transform = Transform3D.IDENTITY
	if visual.has_method("randomize_appearance"):
		visual.call("randomize_appearance", look_archetype, look_seed)
	if visual.has_method("set_lod"):
		visual.call("set_lod", 1)
	if visual.has_method("get_skeleton"):
		animator = HumanoidAnimator.new()
		animator.name = "SeatedAnimator"
		visual.add_child(animator)
		animator.setup(visual.call("get_skeleton"))
		animator.update_rate_hz = 8.0
		var bike := vehicle != null and str(vehicle.get("vehicle_class")) in ["bike", "bicycle"]
		animator.set_state("seated_bike" if bike else "seated_car", 0.0)
		if vehicle != null and vehicle.has_method("get_part"):
			var wheel: Variant = vehicle.call("get_part", "SteeringWheel")
			if wheel is Node3D and is_instance_valid(wheel) and is_inside_tree():
				var local: Vector3 = global_transform.affine_inverse() * (wheel as Node3D).global_position
				if local.length() < 1.2 and local.z < -0.15:
					animator.wheel_pos = local
		animator.snap()


func hide_visual() -> void:
	if has_visual():
		visual.queue_free()
	visual = null
	animator = null


## Hits on the stand-in belong to the car's authority (it hurts its own driver).
func apply_damage(_info: Dictionary) -> void:
	pass


func is_dead() -> bool:
	return false


## VehicleBase._evict / a carjack on this machine: the real driver gets out on the host.
func on_vehicle_ejected(_vehicle: Node, _exit_xform: Transform3D, _impulse: Vector3 = Vector3.ZERO) -> void:
	net_dismiss()


func net_dismiss() -> void:
	if not is_queued_for_deletion():
		queue_free()


func get_appearance() -> Dictionary:
	if has_visual() and visual.has_method("get_appearance"):
		return visual.call("get_appearance")
	return {}


func get_target_position() -> Vector3:
	return global_position + Vector3.UP * 0.45
