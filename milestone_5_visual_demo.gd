# milestone_5_visual_demo.gd
# Generates high-resolution 2D diagnostic visual evidence of Shallow Water Equations (SWE)
# fluid simulation (water depth, surface elevation, and velocity dynamics) for Milestone 5.
extends SceneTree

const TerrainEngine = preload("res://TerrainEngine.gd")
const HydrologyEngine = preload("res://HydrologyEngine.gd")
const LakeBasinSolver = preload("res://LakeBasinSolver.gd")
const WorldState = preload("res://WorldState.gd")
const ShallowWaterSolver2D = preload("res://ShallowWaterSolver2D.gd")
const FluidSimulationManager = preload("res://FluidSimulationManager.gd")

func _init() -> void:
	print("Milestone 5: Generating visual diagnostic map for SWE shallow water simulation...")
	DirAccess.make_dir_absolute("res://screenshots")
	
	var world_size = Vector2(1000.0, 1000.0)
	var grid_res = Vector2i(128, 128)
	var origin = Vector2(-500.0, -500.0)
	
	var ws = WorldState.new(world_size, grid_res, origin, 42)
	var terr = TerrainEngine.new(world_size, grid_res, origin)
	terr.generate(42, {"base_elevation": 20.0, "mountain_count": 2})
	
	# Carve a defined central river valley and a lake basin in the southeast
	var valley_center_x = 0.0
	for y in range(grid_res.y):
		var wz = origin.y + (float(y) / float(grid_res.y - 1)) * world_size.y
		for x in range(grid_res.x):
			var wx = origin.x + (float(x) / float(grid_res.x - 1)) * world_size.x
			var idx = y * grid_res.x + x
			# Valley carve along curved path wx = 120.0 * sin(wz * 0.005)
			var path_x = 120.0 * sin(wz * 0.005)
			var dist_to_path = abs(wx - path_x)
			if dist_to_path < 60.0:
				var carve = (1.0 - (dist_to_path / 60.0)) * 14.0
				var current_h = terr.heights[idx]
				terr.heights[idx] = max(5.0, current_h - carve)
				
			# Lake basin bowl in lower-middle reach (wz in [100, 300], wx in [-50, 150])
			var basin_center = Vector2(40.0, 200.0)
			var dist_to_basin = Vector2(wx, wz).distance_to(basin_center)
			if dist_to_basin < 110.0:
				var bowl_carve = (1.0 - (dist_to_basin / 110.0)) * 18.0
				var cur = terr.heights[idx]
				terr.heights[idx] = max(4.0, cur - bowl_carve)
	var hyd = HydrologyEngine.new(terr)
	hyd.resolve_hydrology()
	ws.initialize_from_simulation(terr, hyd)
	
	ws.recompute_lakes({"min_basin_area_cells": 5, "min_basin_depth_m": 0.2})
	
	var fluid_mgr = FluidSimulationManager.new()
	fluid_mgr.initialize_from_world_state(ws, grid_res)
	
	# Add upstream river source inflow at top of valley (wz = -450.0, wx = -120.0 * sin(-450 * 0.005))
	var src_pos = Vector2(120.0 * sin(-450.0 * 0.005), -450.0)
	var src_gi = ws.world_to_grid(src_pos.x, src_pos.y)
	fluid_mgr.solver.point_sources.append({"gx": src_gi.x, "gy": src_gi.y, "discharge": 45.0})
	
	# Add a dam break pulse: sudden localized water release at mid-valley (wz = -150.0)
	var pulse_pos = Vector2(120.0 * sin(-150.0 * 0.005), -150.0)
	var pulse_gi = ws.world_to_grid(pulse_pos.x, pulse_pos.y)
	for dy in range(-3, 4):
		for dx in range(-3, 4):
			var gx = pulse_gi.x + dx
			var gy = pulse_gi.y + dy
			if gx >= 0 and gx < grid_res.x and gy >= 0 and gy < grid_res.y:
				var rad = sqrt(float(dx*dx + dy*dy))
				if rad <= 3.0:
					var init_h = (1.0 - rad/3.0) * 6.5
					var p_idx = gy * grid_res.x + gx
					fluid_mgr.solver.h[p_idx] += init_h
					
	print("Simulating SWE physical dynamics...")
	fluid_mgr.advance(15.0)
		
	var stats = fluid_mgr.get_diagnostics()
	print("SWE Simulation complete. Mass error: " + str(stats.mass_balance_relative_error) + (", Max Vel: %.2f m/s, Total Vol: %.1f m³" % [
		stats.max_velocity_m_s, stats.current_volume_m3
	]))
	
	# Render Dual-Panel Visualization (Width = 1024, Height = 512)
	# Left: Water Depth + Shaded Relief
	# Right: Velocity Magnitude + Flow Directions
	var panel_w = 512
	var panel_h = 512
	var img = Image.create(panel_w * 2, panel_h, false, Image.FORMAT_RGBA8)
	
	var mm = Vector2(ws.min_raw_elevation, ws.max_raw_elevation)
	var h_range = max(1.0, mm.y - mm.x)
	var light_dir = Vector3(-0.577, 0.577, -0.577).normalized()
	
	for py in range(panel_h):
		var wz = origin.y + (float(py) / float(panel_h)) * world_size.y
		for px in range(panel_w):
			var wx = origin.x + (float(px) / float(panel_w)) * world_size.x
			
			# Terrain elevation & slope shading
			var elev = ws.get_elevation_at(wx, wz)
			var norm_h = clampf((elev - mm.x) / h_range, 0.0, 1.0)
			var slope_data = ws.get_slope_and_normal(wx, wz)
			var n: Vector3 = slope_data.normal
			var diffuse = clampf(n.dot(light_dir) * 0.6 + 0.4, 0.15, 1.0)
			
			# Bed hypsometric color
			var bed_col = Color(0.24, 0.42, 0.22).lerp(Color(0.78, 0.72, 0.55), norm_h)
			if norm_h > 0.65:
				bed_col = Color(0.78, 0.72, 0.55).lerp(Color(0.92, 0.94, 0.96), (norm_h - 0.65) / 0.35)
			bed_col = bed_col * diffuse
			
			# Fluid query
			var depth = fluid_mgr.get_water_depth_at(wx, wz)
			var vel = fluid_mgr.get_water_velocity_at(wx, wz)
			var speed = vel.length()
			
			# --- LEFT PANEL: Water Depth ---
			var left_col = bed_col
			if depth > 0.01:
				var d_norm = clampf(depth / 5.0, 0.0, 1.0)
				# Gradient: shallow turquoise -> vibrant azure -> deep abyssal navy
				var water_col = Color(0.15, 0.85, 0.9, 0.85).lerp(Color(0.04, 0.25, 0.7, 0.95), d_norm)
				# Highlight ripples / motion
				if speed > 1.0:
					var foam = clampf((speed - 1.0) / 4.0, 0.0, 0.45)
					water_col = water_col.lerp(Color(1.0, 1.0, 1.0), foam)
				left_col = bed_col.lerp(water_col, 0.85)
			elif depth > 0.0001:
				left_col = bed_col.lerp(Color(0.2, 0.7, 0.8), 0.3) # Wet margin
				
			img.set_pixel(px, py, left_col)
			
			# --- RIGHT PANEL: Velocity Magnitude ---
			# Dark topographic background
			var right_col = bed_col * 0.28
			if depth > 0.01:
				var v_norm = clampf(speed / 4.5, 0.0, 1.0)
				# Heatmap: navy (slow) -> teal -> green -> yellow -> hot red/white (torrent)
				var heat = Color.BLACK
				if v_norm < 0.2:
					heat = Color(0.05, 0.15, 0.6).lerp(Color(0.1, 0.7, 0.8), v_norm / 0.2)
				elif v_norm < 0.5:
					heat = Color(0.1, 0.7, 0.8).lerp(Color(0.2, 0.95, 0.3), (v_norm - 0.2) / 0.3)
				elif v_norm < 0.8:
					heat = Color(0.2, 0.95, 0.3).lerp(Color(1.0, 0.9, 0.1), (v_norm - 0.5) / 0.3)
				else:
					heat = Color(1.0, 0.9, 0.1).lerp(Color(1.0, 0.2, 0.1), (v_norm - 0.8) / 0.2)
					
				# Velocity arrow / directional indicator on 16x16 grid centers
				var gx_sub = px % 16
				var gy_sub = py % 16
				if gx_sub == 8 and gy_sub == 8 and speed > 0.15:
					heat = Color(1.0, 1.0, 1.0) # Velocity marker
					
				right_col = right_col.lerp(heat, 0.92)
			elif depth > 0.0001:
				right_col = Color(0.08, 0.12, 0.18)
				
			# Separator bar
			if px == panel_w - 1 or px == panel_w - 2:
				img.set_pixel(px, py, Color(0.9, 0.8, 0.2))
				img.set_pixel(px + panel_w, py, right_col)
			else:
				img.set_pixel(px + panel_w, py, right_col)
				
	var save_path = "res://screenshots/milestone5_swe_fluid_depth_velocity.png"
	img.save_png(save_path)
	print("[SAVED] %s (1024x512)" % save_path)
	quit(0)
