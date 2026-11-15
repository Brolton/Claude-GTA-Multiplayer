extends Node
## Multiplayer fork: whole-game performance tour (windowed runs only make sense).
## Teleports the player through the districts and prints the measured frame rate of each stop.
##
##   godot --path . --gpu-index N -- --test=mp_perf --test-timeout=300 [--perf-scale=0.7] [--perf-shadows=1]
##
## Output lines: `PERF: <stop> avg_fps=.. low1_fps=.. ...` (uncapped: V-Sync and the FPS cap are
## switched off for the measurement only; nothing is written to the user's settings).

const STOPS := ["spawn_start", "downtown_plaza", "general_store", "residential_park", "industrial_yard",
		"marina_dock", "beach", "hill_viewpoint", "airport_runway_start"]
const SETTLE_SEC := 3.0
const SAMPLE_SEC := 4.0


func _ready() -> void:
	await TestHarness.wait_frames(20)
	var p: Node3D = Game.player
	if p == null:
		TestHarness.finish(false, "no player")
		return
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("--perf-scale="):
			Settings.set_value("render_scale", float(a.substr(13)), false)
		elif a.begins_with("--perf-shadows="):
			Settings.set_value("shadows", int(a.substr(15)), false)
	Engine.max_fps = 0
	if not TestHarness.is_headless():
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	print("PERF_GPU: %s | %s | window %s | scale %.2f | shadows %s" % [RenderingServer.get_video_adapter_name(),
			RenderingServer.get_video_adapter_vendor(), str(DisplayServer.window_get_size()),
			get_viewport().scaling_3d_scale, str(Settings.get_value("shadows"))])
	if Weather.has_method("snap_weather"):
		Weather.call("snap_weather", "clear")
	Weather.auto_cycle = false
	WorldClock.set_hour(11.0)
	WorldClock.paused = true
	Game.invulnerable = true
	for stop: String in STOPS:
		_tp(stop)
		await _settle(SETTLE_SEC)
		await _sample(stop, SAMPLE_SEC)
	# night in the busiest district (street lamps, lit windows, headlights)
	_tp("downtown_plaza")
	WorldClock.set_hour(22.5)
	await _settle(SETTLE_SEC)
	await _sample("downtown_plaza_night", SAMPLE_SEC)
	# rain (particles + wet shading)
	if Weather.has_method("snap_weather"):
		Weather.call("snap_weather", "storm")
		await _settle(SETTLE_SEC)
		await _sample("downtown_plaza_night_storm", SAMPLE_SEC)
	TestHarness.finish()


func _tp(loc: String) -> void:
	var xf := Game.get_location(loc)
	Game.player.teleport(xf.origin, xf.basis.get_euler().y)


## Real-time wait (the frame rate is uncapped, so game-time timers would be fine too, but real
## seconds keep the run length predictable on slow machines).
func _settle(seconds: float) -> void:
	var t_end := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < t_end:
		await get_tree().process_frame


func _sample(label: String, seconds: float) -> void:
	var cam: Variant = Game.player.get("camera")
	var times := PackedFloat32Array()
	var t_end := Time.get_ticks_msec() + int(seconds * 1000.0)
	var last := Time.get_ticks_usec()
	var proc := 0.0
	var phys := 0.0
	var calls := 0.0
	var prims := 0.0
	while Time.get_ticks_msec() < t_end:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		times.append(float(now - last) / 1000.0)
		last = now
		if cam != null:
			cam.set("yaw", float(cam.get("yaw")) + 0.012)      # slow pan: the whole surroundings get drawn
		proc += Performance.get_monitor(Performance.TIME_PROCESS)
		phys += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)
		calls += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
		prims += Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
	var n := times.size()
	if n == 0:
		return
	var sum := 0.0
	for t in times:
		sum += t
	times.sort()
	var avg := sum / float(n)
	var p99 := times[mini(int(float(n) * 0.99), n - 1)]
	print("PERF: %s avg_fps=%.1f low1_fps=%.1f avg_ms=%.2f p99_ms=%.2f proc_ms=%.2f phys_ms=%.2f draw_calls=%d prims=%dk vehicles=%d npcs=%d" % [
			label, 1000.0 / avg, 1000.0 / p99, avg, p99, proc / float(n) * 1000.0, phys / float(n) * 1000.0,
			int(calls / float(n)), int(prims / float(n) / 1000.0),
			get_tree().get_nodes_in_group("vehicle").size(), get_tree().get_nodes_in_group("npc").size()])
