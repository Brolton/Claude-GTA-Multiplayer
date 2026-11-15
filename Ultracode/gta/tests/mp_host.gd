extends Node
## Multiplayer smoke test, host side (run together with mp_client on a second instance):
##   godot --headless --path . -- --host --test=mp_host --test-timeout=120 --new-game
## Waits for a client, checks that its avatar follows it, that it can take a car and hurt us.


func _ready() -> void:
	TestHarness.check(Net.is_host(), "running as host")
	Game.invulnerable = false
	var t0 := Time.get_ticks_msec()
	while Net.world.avatars.is_empty() and Time.get_ticks_msec() - t0 < 60000:
		await TestHarness.wait_frames(10)
	TestHarness.check(not Net.world.avatars.is_empty(), "a client joined")
	if Net.world.avatars.is_empty():
		TestHarness.finish(false, "no client")
		return
	var peer: int = Net.world.avatars.keys()[0]
	var a := Net.world.get_avatar(peer)
	t0 = Time.get_ticks_msec()
	while not a.has_state and Time.get_ticks_msec() - t0 < 10000:
		await TestHarness.wait_frames(5)
	TestHarness.check(a.has_state, "the avatar receives snapshots")
	var p0 := a.get_net_position()
	TestHarness.log_line("avatar %s at %s, name tag '%s'" % [peer, str(p0), a.player_name])
	TestHarness.check(p0.distance_to(Game.get_player_position()) < 12.0, "the client spawned beside the host")
	var veh := 0
	var npc := 0
	for nid: int in Net.world.ents:
		if Net.world.ents[nid].kind == NetProto.KIND_VEHICLE:
			veh += 1
		else:
			npc += 1
	TestHarness.log_line("host entities: vehicles=%d npcs=%d" % [veh, npc])
	TestHarness.check(veh > 5, "the host registered its vehicles")
	var hp0: float = Game.player.health
	# the client walks, takes a car, shoots at us: watch for 25 s
	var moved := false
	var drove := false
	var shot_done := false
	var t_end := Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < t_end and Net.world.avatars.has(peer):
		await TestHarness.wait_frames(10)
		if not is_instance_valid(a):
			break
		if a.get_net_position().distance_to(p0) > 2.0:
			moved = true
		if a.current_vehicle != null:
			drove = true
			if not shot_done and not TestHarness.is_headless():
				shot_done = true
				var vp := a.current_vehicle.global_position
				Game.invulnerable = true
				Game.player.teleport(vp + Vector3(5.0, 0.3, 5.0), 0.0)
				await TestHarness.wait_seconds(0.6)
				var tv: Vector3 = a.current_vehicle.global_position - Game.player.global_position
				Game.player.camera.snap_to(atan2(-tv.x, -tv.z))
				await TestHarness.wait_seconds(0.8)
				await TestHarness.shot("mp_host_sees_client_car")
	TestHarness.check(moved, "the avatar moved")
	TestHarness.check(drove, "the avatar sat in a vehicle on the host")
	var deaths := int((Net.players[1] as Dictionary).get("deaths", 0))
	TestHarness.check(Game.player.health < hp0 or Game.player.is_dead or deaths > 0, "the client's shots hurt the host (hp %.0f -> %.0f, deaths %d)" % [hp0, Game.player.health, deaths])
	var client_owned := 0
	for nid: int in Net.world.ents:
		if Net.world.ents[nid].auth == peer:
			client_owned += 1
	TestHarness.log_line("entities owned by the client: %d, stats %s" % [client_owned, str(Net.stats)])
	TestHarness.finish()
