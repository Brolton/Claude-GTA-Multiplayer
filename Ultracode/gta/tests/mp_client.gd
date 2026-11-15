extends Node
## Multiplayer smoke test, client side:
##   godot --headless --path . -- --join=127.0.0.1 --test=mp_client --test-timeout=120
## Sees the host and its world, walks, takes a car, shoots the host.


func _ready() -> void:
	TestHarness.check(Net.is_client(), "running as client")
	var p := Game.player as Player
	await TestHarness.wait_seconds(4.0)
	var host := Net.world.get_avatar(1)
	TestHarness.check(host != null and host.has_state, "the host's avatar exists and has state")
	var veh := 0
	var npc := 0
	for nid: int in Net.world.ents:
		if Net.world.ents[nid].kind == NetProto.KIND_VEHICLE:
			veh += 1
		else:
			npc += 1
	TestHarness.log_line("client puppets: vehicles=%d npcs=%d, ping %d ms" % [veh, npc, int(Net.rtt * 1000.0)])
	TestHarness.check(veh > 3, "vehicle puppets arrived")
	TestHarness.check(Game.get_system("traffic") == null, "no local traffic system on the client")
	if host != null and not TestHarness.is_headless():
		var hp := host.get_net_position()
		p.teleport(hp + Vector3(2.5, 0.2, 2.5), 0.0)
		await TestHarness.wait_seconds(1.0)
		var to_h := hp - p.global_position
		p.camera.snap_to(atan2(-to_h.x, -to_h.z))
		await TestHarness.wait_seconds(1.0)
		await TestHarness.shot("mp_client_sees_host")
	# walk
	Input.action_press("move_forward")
	await TestHarness.wait_seconds(2.0)
	Input.action_release("move_forward")
	# shoot the host
	if host != null:
		p.inventory.call("give_weapon", "assault_rifle", 200)
		p.inventory.call("equip", "assault_rifle")
		await TestHarness.wait_seconds(0.5)
		for i in 12:
			var from := p.global_position + Vector3(0.0, 1.5, 0.0)
			var to := host.get_target_position()
			Combat.fire_hitscan(from, (to - from).normalized(), "assault_rifle", p, {"spread_deg": 0.0})
			await TestHarness.wait_seconds(0.1)
	# take the nearest parked / free car
	var best: VehicleBase = null
	var best_d := 1.0e9
	for nid: int in Net.world.ents:
		var e = Net.world.ents[nid]
		if e.kind != NetProto.KIND_VEHICLE or e.node == null or not (e.node is Car):
			continue
		var v := e.node as VehicleBase
		if v.driver != null or v.destroyed:
			continue
		var d := v.global_position.distance_to(p.global_position)
		if d < best_d:
			best_d = d
			best = v
	TestHarness.check(best != null, "found a free car puppet (%.0f m)" % best_d)
	if best != null:
		TestHarness.check(best.net_puppet, "it is a puppet before we take it")
		p.enter_vehicle(best, 0, true)
		await TestHarness.wait_seconds(1.0)
		TestHarness.check(p.current_vehicle == best, "sitting in the car")
		TestHarness.check(not best.net_puppet, "the car is simulated here now")
		var c0 := best.global_position
		Input.action_press("move_forward")
		await TestHarness.wait_seconds(4.0)
		Input.action_release("move_forward")
		TestHarness.check(best.global_position.distance_to(c0) > 3.0, "the car drove %.1f m" % best.global_position.distance_to(c0))
		await TestHarness.shot("mp_client_driving")
		var e2 = Net.world.ents.get(best.net_id, null)
		TestHarness.check(e2 != null and e2.auth == Net.my_id, "the host confirmed our authority")
		p.exit_vehicle()
		await TestHarness.wait_seconds(2.0)
	TestHarness.log_line("client stats %s" % str(Net.stats))
	TestHarness.finish()
