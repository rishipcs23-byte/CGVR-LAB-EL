# milestone_6_visual_demo.gd
# Generates high-resolution visual evidence of Milestone 6: Main Scene Fluid Integration.
# Renders the full 1 km x 1 km domain showing terrain relief, chunk boundaries,
# SWE dynamic water depth, velocity streamlines, shoreline foam, and player position.
extends SceneTree

const WorldState = preload("res://WorldState.gd")
const ChunkManager = preload("res://ChunkManager.gd")
const FluidSimulationManager = preload("res://FluidSimulationManager.gd")
const WaterSurfaceRenderer = preload("res://WaterSurfaceRenderer.gd")
const WorldEditManager = preload("res://WorldEditManager.gd")

func _init() -> void:
	print("Milestone 6: Generating visual evidence of Main Scene Fluid Integration...")
	generate_demo()

func generate_demo() -> void:
	DirAccess.make_dir_absolute("res://screenshots")
	
	# Load and instantiate Main.tscn
	var sc = load("res://Main.tscn")
	var inst = sc.instantiate()
	root.add_child(inst)
	
	await process_frame
	await process_frame
	
	var cm: ChunkManager = inst.find_child("ChunkManager", true, false)
	var fsm: FluidSimulationManager = inst.find_child("FluidSimulationManager", true, false)
	var wsr: WaterSurfaceRenderer = inst.find_child("WaterSurfaceRenderer", true, false)
	var player: Node3D = inst.find_child("Player", true, false)
	var edit_mgr: WorldEditManager = cm.edit_manager
	
	# Register a prominent winding river into the registry and re-ingest
	var river_feat = {
		"id": "visual_stem_river",
		"type": "river",
		"parameters": {
			"depth": 3.0,
			"width": 24.0,
			"spring_discharge": 35.0,
			"points": PackedVector2Array([
				Vector2(-350.0, -350.0),
				Vector2(-200.0, -200.0),
				Vector2(-50.0, -100.0),
				Vector2(40.0, 50.0),
				Vector2(120.0, 180.0),
				Vector2(200.0, 320.0)
			])
		}
	}
	cm.world_state.feature_registry.register_feature(river_feat)
	fsm._ingest_water_features()
	fsm._ingest_rivers()
	
	# Apply an interactive brush edit in the northeast quadrant
	var edit_res = edit_mgr.apply_elevation_brush(Vector2(220.0, -200.0), 45.0, 22.0, "raise")
	var dirty_bounds = edit_res.dirty_region.world_bounds
	
	# Advance fluid simulation by 0.5 seconds so velocities, currents, and waves develop
	print("Simulating SWE shallow water dynamics on GPU / reference solver...")
	fsm.advance(0.5, 0.02)
	wsr.update_simulation_textures()
	
	var ws = cm.world_state
	
	# Render 512x512 composite diagnostic map
	var S = 512
	var img = Image.create(S, S, false, Image.FORMAT_RGBA8)
	var mm = Vector2(ws.min_raw_elevation, ws.max_raw_elevation)
	var h_range = max(1.0, mm.y - mm.x)
	var eff_chunk_size = 64.0
	
	for py in range(S):
		var wz = -500.0 + (float(py) / float(S - 1)) * 1000.0
		for px in range(S):
			var wx = -500.0 + (float(px) / float(S - 1)) * 1000.0
			
			var ground_h = ws.get_elevation_at(wx, wz)
			var water_d = fsm.get_water_depth_at(wx, wz)
			var vel = fsm.get_water_velocity_at(wx, wz)
			var spd = vel.length()
			
			var norm_h = clampf((ground_h - mm.x) / h_range, 0.0, 1.0)
			
			# Hypsometric terrain base color (topographic relief)
			var col = Color(0.18, 0.38, 0.22).lerp(Color(0.78, 0.72, 0.52), norm_h)
			if norm_h > 0.65:
				col = Color(0.78, 0.72, 0.52).lerp(Color(0.95, 0.96, 1.0), (norm_h - 0.65) / 0.35)
				
			# Chunk grid lines
			var cx = floori(wx / eff_chunk_size)
			var cz = floori(wz / eff_chunk_size)
			var edge_dist_x = absf(fposmod(wx, eff_chunk_size))
			var edge_dist_z = absf(fposmod(wz, eff_chunk_size))
			if edge_dist_x < 1.2 or absf(edge_dist_x - eff_chunk_size) < 1.2 or edge_dist_z < 1.2 or absf(edge_dist_z - eff_chunk_size) < 1.2:
				col = col.lerp(Color(0.1, 0.15, 0.2), 0.45)
				
			# Dynamic SWE Water Surface Layer
			if water_d > 0.01:
				var depth_ratio = clampf(water_d / 12.0, 0.0, 1.0)
				# Cyan (shallow) to Deep Navy Blue (deep lake basin)
				var shallow_c = Color(0.14, 0.72, 0.82, 0.85)
				var deep_c = Color(0.04, 0.18, 0.48, 0.95)
				var water_c = shallow_c.lerp(deep_c, depth_ratio)
				
				# Flow ripples modulated by velocity vector
				var ripple = sin(wx * 0.25 - vel.x * 4.0) * cos(wz * 0.25 - vel.y * 4.0)
				if spd > 0.2:
					water_c = water_c.lerp(Color(0.8, 0.95, 1.0, 1.0), absf(ripple) * 0.22)
					
				# Shoreline & spillway foam
				if water_d < 0.25 or spd > 2.0:
					var foam_intensity = clampf((0.25 - water_d) / 0.25 * 0.6 + maxf(0.0, spd - 2.0) * 0.3, 0.0, 0.85)
					water_c = water_c.lerp(Color(0.98, 1.0, 1.0, 1.0), foam_intensity)
					
				col = col.lerp(water_c, water_c.a)
				
			# Draw dirty region bounding box outline (Yellow dashed border)
			var in_bounds_x = wx >= dirty_bounds.position.x and wx <= dirty_bounds.end.x
			var in_bounds_z = wz >= dirty_bounds.position.y and wz <= dirty_bounds.end.y
			var on_edge_x = absf(wx - dirty_bounds.position.x) < 3.0 or absf(wx - dirty_bounds.end.x) < 3.0
			var on_edge_z = absf(wz - dirty_bounds.position.y) < 3.0 or absf(wz - dirty_bounds.end.y) < 3.0
			if (in_bounds_x and on_edge_z) or (in_bounds_z and on_edge_x):
				col = Color(1.0, 0.84, 0.0, 1.0) # Bright yellow
				
			# Draw Player location (bright red circle with white crosshair)
			var p_2d = Vector2(player.global_position.x, player.global_position.z)
			var dist_p = Vector2(wx, wz).distance_to(p_2d)
			if dist_p < 8.0:
				col = Color(1.0, 0.15, 0.15, 1.0)
			elif dist_p < 11.0:
				col = Color(1.0, 1.0, 1.0, 0.9)
				
			img.set_pixel(px, py, col)
			
	var save_path = "res://screenshots/milestone6_main_scene_fluid_integration.png"
	img.save_png(save_path)
	print("[SAVED] Successfully saved Milestone 6 visual artifact: %s" % save_path)
	
	inst.queue_free()
	quit(0)
