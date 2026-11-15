class_name NetLowspec
extends RefCounted
## Automatic "low-spec" graphics preset for integrated GPUs (Intel UHD / Iris / Arc iGPU, AMD
## Radeon Graphics). Measured on an Iris Xe at 1080p: 26-39 fps at the shipped defaults, 62-80 fps
## with a 0.6 render scale, low shadows and no local traffic simulation (multiplayer client).
##
## Applied once per machine (it changes the saved settings, which the player can raise again in
## Pause -> Settings). `--lowspec` forces it on every start, `--no-lowspec` never applies it.

const TARGET_PIXELS := 1150000.0      ## 3D pixels the preset aims for (about 1440x800)
const MARK := "user://lowspec_applied.cfg"


static func is_integrated_gpu() -> bool:
	if DisplayServer.get_name() == "headless":
		return false
	var n := RenderingServer.get_video_adapter_name().to_lower()
	var t := RenderingServer.get_video_adapter_type()
	if t == RenderingDevice.DEVICE_TYPE_INTEGRATED_GPU or t == RenderingDevice.DEVICE_TYPE_CPU:
		return true
	# Direct3D reports every adapter as "discrete": fall back to the name
	if n.contains("intel"):
		return not (n.contains("arc(tm) a") or n.contains("arc(tm) b") or n.contains("arc a") or n.contains("arc b"))
	if n.contains("radeon(tm) graphics") or n.contains("radeon graphics") or n.contains("vega"):
		return true
	return n.contains("microsoft basic")


static func apply_boot_preset() -> void:
	if DisplayServer.get_name() == "headless":
		return
	var force := Game.flags.has("lowspec") or Net.lowspec_choice == 1
	if Game.flags.has("no-lowspec") or Net.lowspec_choice == 0:
		return
	if not force:
		if FileAccess.file_exists(MARK) or not is_integrated_gpu():
			return
	var size := DisplayServer.screen_get_size()
	var win := DisplayServer.window_get_size()
	var px := float(maxi(win.x * win.y, 1))
	if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_WINDOWED:
		px = float(maxi(win.x * win.y, 1280 * 720))
	else:
		px = float(maxi(size.x * size.y, 1))
	var scale := clampf(snappedf(sqrt(TARGET_PIXELS / px), 0.05), 0.5, 1.0)
	Settings.set_value("render_scale", scale, false)
	Settings.set_value("shadows", 1, false)
	Settings.save_settings()
	var f := FileAccess.open(MARK, FileAccess.WRITE)
	if f != null:
		f.store_string("render_scale=%.2f\n" % scale)
		f.close()
	apply_viewport()
	print("[Net] low-spec preset: %s -> render scale %.2f, low shadows" % [RenderingServer.get_video_adapter_name(), scale])


## MSAA off and a sharper upscale whenever the 3D resolution is reduced on an integrated GPU.
static func apply_viewport() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return
	var vp := tree.root
	if not is_integrated_gpu() and not Game.flags.has("lowspec"):
		return
	vp.msaa_3d = Viewport.MSAA_DISABLED
	if vp.scaling_3d_scale < 0.95:
		vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR
		vp.fsr_sharpness = 0.3
