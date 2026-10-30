# Milestone1Prototype.gd
# Visual prototype and demonstration scene for Milestone 1:
# 1 km x 1 km Terrain & Elevation-Aware Hydrology River System.
extends Node3D

const TerrainEngine = preload("res://TerrainEngine.gd")
const HydrologyEngine = preload("res://HydrologyEngine.gd")
const WorldState = preload("res://WorldState.gd")
const FeatureRegistry = preload("res://FeatureRegistry.gd")
const LakeBasinSolver = preload("res://LakeBasinSolver.gd")

@export var seed_val: int = 42
@export var world_size_m: float = 1000.0
@export var grid_res: int = 256

var terrain: TerrainEngine
var hydro: HydrologyEngine
var world_state: WorldState
var lake_solver: LakeBasinSolver
var river_result: Dictionary = {}
var primary_lake: Dictionary = {}

var terrain_mesh_instance: MeshInstance3D
var river_mesh_instance: MeshInstance3D
var lake_mesh_instance: MeshInstance3D
var outflow_river_mesh_instance: MeshInstance3D
var spring_marker: MeshInstance3D
var spillway_marker: MeshInstance3D
var outlet_marker: MeshInstance3D

var camera: Camera3D
var sun: DirectionalLight3D
var env: WorldEnvironment

# UI Overlay
var hud_canvas: CanvasLayer
var map_rect: TextureRect
var info_label: Label
var is_map_visible: bool = false
var show_flow_accumulation: bool = true

var frame_count: int = 0
var auto_capture_done: bool = false

func _ready() -> void:
	print("Milestone1Prototype: Initializing 1 km² Terrain, Hydrology & Lake Simulation...")
	DirAccess.make_dir_absolute("res://screenshots")
	setup_environment()
	generate_simulation()
	export_2d_diagnostic_maps()
	build_3d_terrain()
	build_3d_river()
	build_3d_lake()
	build_3d_outflow_river()
	build_markers()
	setup_hud()
	print("Milestone1Prototype: Simulation ready! Press [M] to toggle 2D Hydrology Map, [Tab] to switch Map mode.")

func export_2d_diagnostic_maps() -> void:
	# 1. Flow Accumulation Map with River Overlay
	var acc_img = hydro.export_flow_accumulation_image()
	for pt in river_result.get("path_grid", []):
		acc_img.set_pixel(pt.x, pt.y, Color(1.0, 0.2, 0.2, 1.0))
	acc_img.save_png("res://screenshots/milestone1_flow_accumulation.png")
	print("[SAVED] res://screenshots/milestone1_flow_accumulation.png")
	
	# 2. Flow Direction Map
	var dir_img = hydro.export_flow_direction_image()
	dir_img.save_png("res://screenshots/milestone1_flow_direction.png")
	print("[SAVED] res://screenshots/milestone1_flow_direction.png")
	
	# 3. Hypsometric Topographic Shaded Relief Map
	var relief_img = Image.create(grid_res, grid_res, false, Image.FORMAT_RGBA8)
	var mm = terrain.get_min_max_height()
	var h_range = max(1.0, mm.y - mm.x)
	var sun_dir = Vector2(-0.707, -0.707)
	
	for gy in range(grid_res):
		for gx in range(grid_res):
			var h = terrain.get_height_at_cell(gx, gy)
			var norm_h = (h - mm.x) / h_range
			
			var c = Color.BLACK
			if norm_h < 0.25:
				c = Color(0.18, 0.45, 0.22).lerp(Color(0.42, 0.58, 0.25), norm_h / 0.25)
			elif norm_h < 0.55:
				c = Color(0.42, 0.58, 0.25).lerp(Color(0.72, 0.65, 0.38), (norm_h - 0.25) / 0.3)
			elif norm_h < 0.8:
				c = Color(0.72, 0.65, 0.38).lerp(Color(0.55, 0.52, 0.50), (norm_h - 0.55) / 0.25)
			else:
				c = Color(0.55, 0.52, 0.50).lerp(Color(0.96, 0.98, 1.0), (norm_h - 0.8) / 0.2)
				
			var wpos = terrain.grid_to_world(float(gx), float(gy))
			var grad = terrain.get_slope_and_gradient(wpos.x, wpos.y)["gradient"]
			var shade = clampf(1.0 - (grad.x * sun_dir.x + grad.y * sun_dir.y) * 0.4, 0.45, 1.35)
			c.r = clampf(c.r * shade, 0.0, 1.0)
			c.g = clampf(c.g * shade, 0.0, 1.0)
			c.b = clampf(c.b * shade, 0.0, 1.0)
			relief_img.set_pixel(gx, gy, c)
			
	for pt in river_result.get("path_grid", []):
		for dy in [-1, 0, 1]:
			for dx in [-1, 0, 1]:
				var px = clampi(pt.x + dx, 0, grid_res - 1)
				var py = clampi(pt.y + dy, 0, grid_res - 1)
				relief_img.set_pixel(px, py, Color(0.08, 0.85, 1.0, 1.0))
				
	# 4. Milestone 3: Topographic Lake & Drainage Map
	var lake_diag_img = Image.create(grid_res, grid_res, false, Image.FORMAT_RGBA8)
	for gy in range(grid_res):
		for gx in range(grid_res):
			var c = relief_img.get_pixel(gx, gy)
			# Highlight depression areas
			var raw_h = world_state.get_cell_elevation(gx, gy, false)
			var cond_h = world_state.get_cell_elevation(gx, gy, true)
			var dep_depth = cond_h - raw_h
			if dep_depth > 0.05:
				c = c.lerp(Color(0.1, 0.25, 0.65), 0.55)
			# Color lake water
			var lake_d = world_state.get_lake_depth_at(world_state.grid_to_world(float(gx), float(gy)).x, world_state.grid_to_world(float(gx), float(gy)).y)
			if lake_d > 0.01:
				c = Color(0.12, 0.65, 0.95, 1.0)
			lake_diag_img.set_pixel(gx, gy, c)
			
	# Highlight shoreline in white
	if not primary_lake.is_empty():
		for sc in primary_lake.get("shoreline_cells", []):
			lake_diag_img.set_pixel(sc.x, sc.y, Color(1.0, 1.0, 1.0, 1.0))
			
	# Draw Inflow River in cyan
	for pt in river_result.get("path_grid", []):
		lake_diag_img.set_pixel(pt.x, pt.y, Color(0.1, 0.95, 1.0, 1.0))
		
	# Draw Spillway marker in radiant gold
	if not primary_lake.is_empty():
		var sp_c = primary_lake["spillway_cell"]
		for dy in [-1, 0, 1]:
			for dx in [-1, 0, 1]:
				lake_diag_img.set_pixel(clampi(sp_c.x + dx, 0, grid_res - 1), clampi(sp_c.y + dy, 0, grid_res - 1), Color(1.0, 0.7, 0.0, 1.0))
				
		# Draw Outflow River in orange
		for pt in primary_lake.get("outlet_path_grid", []):
			lake_diag_img.set_pixel(pt.x, pt.y, Color(1.0, 0.45, 0.1, 1.0))
			
	lake_diag_img.save_png("res://screenshots/milestone3_depression_and_lakes.png")
	print("[SAVED] res://screenshots/milestone3_depression_and_lakes.png")

func _process(_delta: float) -> void:
	frame_count += 1
	if auto_capture_done:
		return
		
	if frame_count == 8:
		# Capture 3D Aerial Overview
		var img = get_viewport().get_texture().get_image()
		if img and not img.is_empty():
			img.save_png("res://screenshots/milestone1_3d_aerial.png")
			img.save_png("res://screenshots/milestone3_3d_aerial.png")
			print("[SAVED] res://screenshots/milestone3_3d_aerial.png")
			
		# Switch camera to view across lake towards spillway and mountain
		if not primary_lake.is_empty():
			var sp_pos = primary_lake["spillway_world_pos"]
			camera.position = Vector3(sp_pos.x + 80.0, primary_lake["water_elevation"] + 35.0, sp_pos.y + 70.0)
			camera.look_at(Vector3(sp_pos.x, primary_lake["water_elevation"] + 5.0, sp_pos.y), Vector3.UP)
		else:
			camera.position = Vector3(0.0, 60.0, 0.0)
			camera.look_at(Vector3(-220.0, 140.0, -260.0), Vector3.UP)
			
	elif frame_count == 16:
		# Capture 3D Lake Basin & Spillway perspective
		var img2 = get_viewport().get_texture().get_image()
		if img2 and not img2.is_empty():
			img2.save_png("res://screenshots/milestone1_3d_river_valley.png")
			img2.save_png("res://screenshots/milestone3_3d_lake_spillway.png")
			print("[SAVED] res://screenshots/milestone3_3d_lake_spillway.png")
		auto_capture_done = true
		
		# Check if launched for automated capture
		for arg in OS.get_cmdline_args():
			if arg == "--auto-capture":
				get_tree().quit(0)

func setup_environment() -> void:
	# Directional Sun
	sun = DirectionalLight3D.new()
	sun.name = "SunLight"
	sun.transform = Transform3D(Basis(Quaternion(Vector3.UP, deg_to_rad(45.0)) * Quaternion(Vector3.RIGHT, deg_to_rad(-55.0))), Vector3.ZERO)
	sun.light_color = Color(1.0, 0.98, 0.92)
	sun.light_energy = 1.3
	sun.shadow_enabled = true
	add_child(sun)
	
	# World Environment
	env = WorldEnvironment.new()
	var environment = Environment.new()
	environment.background_mode = Environment.BG_SKY
	var sky = Sky.new()
	var sky_mat = ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.35, 0.55, 0.85)
	sky_mat.sky_horizon_color = Color(0.7, 0.8, 0.9)
	sky_mat.ground_bottom_color = Color(0.2, 0.25, 0.2)
	sky_mat.ground_horizon_color = Color(0.65, 0.75, 0.8)
	sky.sky_material = sky_mat
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.ambient_light_sky_contribution = 0.5
	environment.tonemap_mode = Environment.TONE_MAPPER_ACES
	environment.fog_enabled = true
	environment.fog_density = 0.0006
	environment.fog_light_color = Color(0.75, 0.85, 0.95)
	env.environment = environment
	add_child(env)
	
	# Aerial Perspective Camera
	camera = Camera3D.new()
	camera.name = "PrototypeCamera"
	# Position high up looking South-East across the mountain towards the river valley
	camera.position = Vector3(-420.0, 320.0, -460.0)
	camera.current = true
	add_child(camera)
	camera.look_at(Vector3(-180.0, 60.0, -200.0), Vector3.UP)

func generate_simulation() -> void:
	terrain = TerrainEngine.new(
		Vector2(world_size_m, world_size_m),
		Vector2i(grid_res, grid_res),
		Vector2(-world_size_m * 0.5, -world_size_m * 0.5)
	)
	
	# Generate mountain massif in North-West
	terrain.generate(seed_val, {
		"mountain_peaks": [{
			"center": Vector2(-220.0, -260.0),
			"peak_height": 145.0,
			"radius": 260.0,
			"ridge_sharpness": 1.9
		}],
		"base_elevation": 10.0,
		"macro_gradient": Vector2(0.0, -0.05)
	})
	
	# Milestone 3: Carve a genuine alpine lake basin in the valley between mountain and lowlands
	var lake_center = Vector2(-75.0, -90.0)
	var lake_rad = 85.0
	for gy in range(grid_res):
		for gx in range(grid_res):
			var wpos = terrain.grid_to_world(float(gx), float(gy))
			var d = wpos.distance_to(lake_center)
			if d < lake_rad:
				var drop = 14.0 * pow(cos((d / lake_rad) * PI * 0.5), 1.6)
				var cur_h = terrain.get_height_at_cell(gx, gy)
				terrain.set_height_at_cell(gx, gy, cur_h - drop)
	
	hydro = HydrologyEngine.new(terrain)
	var hydro_stats = hydro.resolve_hydrology()
	print("Hydrology Resolved: %s" % str(hydro_stats))
	
	# Milestone 2 & 3: Initialize Authoritative WorldState and FeatureRegistry
	world_state = WorldState.new(Vector2(world_size_m, world_size_m), Vector2i(grid_res, grid_res), Vector2(-world_size_m * 0.5, -world_size_m * 0.5), seed_val)
	world_state.initialize_from_simulation(terrain, hydro)
	
	# Milestone 3: Solve Lake Basins using LakeBasinSolver
	var detected = world_state.recompute_lakes({
		"min_basin_area_cells": 15,
		"min_basin_depth_m": 1.0,
		"default_fill_ratio": 1.0,
		"register_features": true,
		"connect_rivers": true
	})
	
	if not detected.is_empty():
		primary_lake = detected[0]
		print("LakeBasinSolver: Lake '%s' detected (Area: %.0fm², Depth: %.1fm, Spillway: %.1fm)" % [
			primary_lake["id"], primary_lake["area_m2"], primary_lake["max_depth_m"], primary_lake["spillway_elevation"]
		])
	
	# Mountain spring water source
	var spring_pos = Vector2(-170.0, -220.0)
	river_result = hydro.trace_drainage_path(spring_pos, 2500)
	
	# Truncate inflow river at lake shoreline if it enters the lake
	if not primary_lake.is_empty():
		var lake_cells_dict = {}
		for c_idx in primary_lake["lake_cells"]:
			lake_cells_dict[c_idx] = true
			
		var inflow_3d = PackedVector3Array()
		var inflow_grid: Array[Vector2i] = []
		var inflow_elevs = PackedFloat32Array()
		var inflow_accs = PackedFloat32Array()
		
		var original_grid = river_result.get("path_grid", [])
		for i in range(original_grid.size()):
			var pt = original_grid[i]
			var idx = pt.y * grid_res + pt.x
			inflow_grid.append(pt)
			inflow_3d.append(river_result["path_3d"][i])
			inflow_elevs.append(river_result["elevations"][i])
			inflow_accs.append(river_result["accumulations"][i])
			if lake_cells_dict.has(idx):
				break # Reached lake body
				
		river_result["path_3d"] = inflow_3d
		river_result["path_grid"] = inflow_grid
		river_result["elevations"] = inflow_elevs
		river_result["accumulations"] = inflow_accs
		river_result["length_steps"] = inflow_grid.size()
		
		# Register inflow river and link to receiving lake
		world_state.feature_registry.register_feature({
			"id": "river_inflow_001",
			"type": "river",
			"position": spring_pos,
			"parameters": {
				"points": inflow_grid,
				"length_steps": inflow_grid.size(),
				"receiving_lake_id": primary_lake["id"],
				"start_elevation": inflow_elevs[0],
				"end_elevation": inflow_elevs[inflow_elevs.size() - 1]
			}
		})
		world_state.lake_solver.connect_inlet_river(primary_lake["id"], "river_inflow_001", world_state.feature_registry)

	world_state.feature_registry.register_feature({
		"id": "mountain_nw_001",
		"type": "mountain",
		"position": Vector2(-220.0, -260.0),
		"parameters": {
			"peak_height": 145.0,
			"radius": 260.0,
			"ridge_sharpness": 1.9,
			"snow_cap": true
		}
	})
	print("WorldState & FeatureRegistry Initialized: %d features registered" % world_state.feature_registry.get_feature_count())

func build_3d_terrain() -> void:
	terrain_mesh_instance = MeshInstance3D.new()
	terrain_mesh_instance.name = "TerrainMesh"
	
	# Build multi-vertex surface for 1 km x 1 km
	var mesh_res = 128 # 128x128 quad grid (16,384 vertices)
	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	
	var half_size = world_size_m * 0.5
	var step_size = world_size_m / float(mesh_res)
	
	for z_i in range(mesh_res):
		var wz0 = -half_size + float(z_i) * step_size
		var wz1 = -half_size + float(z_i + 1) * step_size
		
		for x_i in range(mesh_res):
			var wx0 = -half_size + float(x_i) * step_size
			var wx1 = -half_size + float(x_i + 1) * step_size
			
			# Query authoritative WorldState instead of raw terrain generator
			var h00 = world_state.get_elevation_at(wx0, wz0)
			var h10 = world_state.get_elevation_at(wx1, wz0)
			var h01 = world_state.get_elevation_at(wx0, wz1)
			var h11 = world_state.get_elevation_at(wx1, wz1)
			
			var p00 = Vector3(wx0, h00, wz0)
			var p10 = Vector3(wx1, h10, wz0)
			var p01 = Vector3(wx0, h01, wz1)
			var p11 = Vector3(wx1, h11, wz1)
			
			var n00 = world_state.get_slope_and_normal(wx0, wz0)["normal"]
			var n10 = world_state.get_slope_and_normal(wx1, wz0)["normal"]
			var n01 = world_state.get_slope_and_normal(wx0, wz1)["normal"]
			var n11 = world_state.get_slope_and_normal(wx1, wz1)["normal"]
			
			# Triangle 1: (p00, p10, p11)
			st.set_normal(n00)
			st.set_uv(Vector2((wx0 + half_size) / world_size_m, (wz0 + half_size) / world_size_m))
			st.add_vertex(p00)
			
			st.set_normal(n10)
			st.set_uv(Vector2((wx1 + half_size) / world_size_m, (wz0 + half_size) / world_size_m))
			st.add_vertex(p10)
			
			st.set_normal(n11)
			st.set_uv(Vector2((wx1 + half_size) / world_size_m, (wz1 + half_size) / world_size_m))
			st.add_vertex(p11)
			
			# Triangle 2: (p00, p11, p01)
			st.set_normal(n00)
			st.set_uv(Vector2((wx0 + half_size) / world_size_m, (wz0 + half_size) / world_size_m))
			st.add_vertex(p00)
			
			st.set_normal(n11)
			st.set_uv(Vector2((wx1 + half_size) / world_size_m, (wz1 + half_size) / world_size_m))
			st.add_vertex(p11)
			
			st.set_normal(n01)
			st.set_uv(Vector2((wx0 + half_size) / world_size_m, (wz1 + half_size) / world_size_m))
			st.add_vertex(p01)
			
	var terrain_mesh = st.commit()
	
	# Apply Chunk.gdshader with snow, slope, grass, and sand parameters
	var shader = load("res://Chunk.gdshader")
	var mat = ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("snow_start_height", 85.0)
	mat.set_shader_parameter("snow_full_height", 110.0)
	mat.set_shader_parameter("slope_threshold", 0.65)
	mat.set_shader_parameter("world_uv_scale", 0.05)
	
	# Setup procedural noise textures for the shader layers
	mat.set_shader_parameter("texture_albedo_grass", _create_color_texture(Color(0.2, 0.48, 0.18)))
	mat.set_shader_parameter("texture_albedo_snow", _create_color_texture(Color(0.95, 0.97, 1.0)))
	mat.set_shader_parameter("texture_albedo_sand", _create_color_texture(Color(0.68, 0.62, 0.45)))
	mat.set_shader_parameter("texture_albedo_slope", _create_color_texture(Color(0.42, 0.42, 0.42)))
	
	terrain_mesh_instance.mesh = terrain_mesh
	terrain_mesh_instance.material_override = mat
	add_child(terrain_mesh_instance)

func build_3d_river() -> void:
	var pts_3d: PackedVector3Array = river_result.get("path_3d", PackedVector3Array())
	if pts_3d.size() < 2:
		return
		
	var accs: PackedFloat32Array = river_result.get("accumulations", PackedFloat32Array())
	var n_pts = pts_3d.size()
	
	river_mesh_instance = MeshInstance3D.new()
	river_mesh_instance.name = "RiverMesh"
	
	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	
	var left_verts: Array[Vector3] = []
	var right_verts: Array[Vector3] = []
	var v_coords: PackedFloat32Array = PackedFloat32Array()
	
	var total_dist = 0.0
	for i in range(n_pts - 1):
		total_dist += pts_3d[i].distance_to(pts_3d[i + 1])
	total_dist = max(1.0, total_dist)
	
	var cur_dist = 0.0
	for i in range(n_pts):
		var p = pts_3d[i]
		var tangent: Vector3
		if i == 0:
			tangent = (pts_3d[1] - pts_3d[0]).normalized()
		elif i == n_pts - 1:
			tangent = (pts_3d[n_pts - 1] - pts_3d[n_pts - 2]).normalized()
		else:
			tangent = (pts_3d[i + 1] - pts_3d[i - 1]).normalized()
			
		var perp = Vector3(-tangent.z, 0.0, tangent.x).normalized()
		var acc = accs[i] if i < accs.size() else 1.0
		var half_w = clampf(3.5 + 0.25 * sqrt(acc), 3.5, 18.0)
		var lift = Vector3(0.0, 0.45, 0.0)
		
		left_verts.append(p - perp * half_w + lift)
		right_verts.append(p + perp * half_w + lift)
		
		if i > 0:
			cur_dist += pts_3d[i - 1].distance_to(p)
		v_coords.append(cur_dist / total_dist)
		
	for i in range(n_pts - 1):
		var v0_L = left_verts[i]
		var v0_R = right_verts[i]
		var v1_L = left_verts[i + 1]
		var v1_R = right_verts[i + 1]
		
		var u0 = 0.0
		var u1 = 1.0
		var vc0 = v_coords[i]
		var vc1 = v_coords[i + 1]
		
		# Triangle 1
		st.set_normal(Vector3.UP)
		st.set_uv(Vector2(u0, vc0))
		st.add_vertex(v0_L)
		
		st.set_normal(Vector3.UP)
		st.set_uv(Vector2(u1, vc0))
		st.add_vertex(v0_R)
		
		st.set_normal(Vector3.UP)
		st.set_uv(Vector2(u1, vc1))
		st.add_vertex(v1_R)
		
		# Triangle 2
		st.set_normal(Vector3.UP)
		st.set_uv(Vector2(u0, vc0))
		st.add_vertex(v0_L)
		
		st.set_normal(Vector3.UP)
		st.set_uv(Vector2(u1, vc1))
		st.add_vertex(v1_R)
		
		st.set_normal(Vector3.UP)
		st.set_uv(Vector2(u0, vc1))
		st.add_vertex(v1_L)
		
	var river_mesh = st.commit()
	
	# Apply river.gdshader
	var river_shader = load("res://river.gdshader")
	var river_mat = ShaderMaterial.new()
	river_mat.shader = river_shader
	river_mat.set_shader_parameter("shallow_color", Color(0.18, 0.68, 0.88, 0.92))
	river_mat.set_shader_parameter("deep_color", Color(0.04, 0.25, 0.52, 0.98))
	river_mat.set_shader_parameter("flow_speed", 0.75)
	
	river_mesh_instance.mesh = river_mesh
	river_mesh_instance.material_override = river_mat
	add_child(river_mesh_instance)

func build_3d_lake() -> void:
	if primary_lake.is_empty():
		return
		
	lake_mesh_instance = MeshInstance3D.new()
	lake_mesh_instance.name = "LakeMesh"
	
	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	
	var water_y = float(primary_lake["water_elevation"])
	var lake_cells: PackedInt32Array = primary_lake["lake_cells"]
	var dx = terrain.cell_size.x * 0.5
	var dy = terrain.cell_size.y * 0.5
	var w = grid_res
	
	# Build horizontal water quad for each cell in the lake basin
	for c_idx in lake_cells:
		var cx = c_idx % w
		var cy = c_idx / w
		var wpos = terrain.grid_to_world(float(cx), float(cy))
		
		var p0 = Vector3(wpos.x - dx, water_y, wpos.y - dy)
		var p1 = Vector3(wpos.x + dx, water_y, wpos.y - dy)
		var p2 = Vector3(wpos.x + dx, water_y, wpos.y + dy)
		var p3 = Vector3(wpos.x - dx, water_y, wpos.y + dy)
		
		# Quad triangles
		st.set_normal(Vector3.UP)
		st.set_uv(Vector2((p0.x + 500.0) / 1000.0, (p0.z + 500.0) / 1000.0))
		st.add_vertex(p0)
		
		st.set_normal(Vector3.UP)
		st.set_uv(Vector2((p1.x + 500.0) / 1000.0, (p1.z + 500.0) / 1000.0))
		st.add_vertex(p1)
		
		st.set_normal(Vector3.UP)
		st.set_uv(Vector2((p2.x + 500.0) / 1000.0, (p2.z + 500.0) / 1000.0))
		st.add_vertex(p2)
		
		st.set_normal(Vector3.UP)
		st.set_uv(Vector2((p0.x + 500.0) / 1000.0, (p0.z + 500.0) / 1000.0))
		st.add_vertex(p0)
		
		st.set_normal(Vector3.UP)
		st.set_uv(Vector2((p2.x + 500.0) / 1000.0, (p2.z + 500.0) / 1000.0))
		st.add_vertex(p2)
		
		st.set_normal(Vector3.UP)
		st.set_uv(Vector2((p3.x + 500.0) / 1000.0, (p3.z + 500.0) / 1000.0))
		st.add_vertex(p3)
		
	var lake_mesh = st.commit()
	
	var water_shader = load("res://river.gdshader")
	var water_mat = ShaderMaterial.new()
	water_mat.shader = water_shader
	water_mat.set_shader_parameter("shallow_color", Color(0.12, 0.58, 0.85, 0.92))
	water_mat.set_shader_parameter("deep_color", Color(0.02, 0.18, 0.42, 0.98))
	water_mat.set_shader_parameter("flow_speed", 0.2)
	
	lake_mesh_instance.mesh = lake_mesh
	lake_mesh_instance.material_override = water_mat
	add_child(lake_mesh_instance)

func build_3d_outflow_river() -> void:
	if primary_lake.is_empty():
		return
	var outlet_pts: PackedVector3Array = primary_lake.get("outlet_path_3d", PackedVector3Array())
	if outlet_pts.size() < 3:
		return
		
	outflow_river_mesh_instance = MeshInstance3D.new()
	outflow_river_mesh_instance.name = "OutflowRiverMesh"
	
	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	
	var n_pts = outlet_pts.size()
	var left_verts: Array[Vector3] = []
	var right_verts: Array[Vector3] = []
	
	for i in range(n_pts):
		var p = outlet_pts[i]
		var tangent: Vector3
		if i == 0:
			tangent = (outlet_pts[1] - outlet_pts[0]).normalized()
		elif i == n_pts - 1:
			tangent = (outlet_pts[n_pts - 1] - outlet_pts[n_pts - 2]).normalized()
		else:
			tangent = (outlet_pts[i + 1] - outlet_pts[i - 1]).normalized()
			
		var perp = Vector3(-tangent.z, 0.0, tangent.x).normalized()
		var half_w = clampf(5.0 + float(i) * 0.1, 5.0, 16.0)
		var lift = Vector3(0.0, 0.45, 0.0)
		
		left_verts.append(p - perp * half_w + lift)
		right_verts.append(p + perp * half_w + lift)
		
	for i in range(n_pts - 1):
		var v0_L = left_verts[i]; var v0_R = right_verts[i]
		var v1_L = left_verts[i + 1]; var v1_R = right_verts[i + 1]
		
		st.set_normal(Vector3.UP); st.set_uv(Vector2(0, 0)); st.add_vertex(v0_L)
		st.set_normal(Vector3.UP); st.set_uv(Vector2(1, 0)); st.add_vertex(v0_R)
		st.set_normal(Vector3.UP); st.set_uv(Vector2(1, 1)); st.add_vertex(v1_R)
		
		st.set_normal(Vector3.UP); st.set_uv(Vector2(0, 0)); st.add_vertex(v0_L)
		st.set_normal(Vector3.UP); st.set_uv(Vector2(1, 1)); st.add_vertex(v1_R)
		st.set_normal(Vector3.UP); st.set_uv(Vector2(0, 1)); st.add_vertex(v1_L)
		
	var out_mesh = st.commit()
	var river_shader = load("res://river.gdshader")
	var river_mat = ShaderMaterial.new()
	river_mat.shader = river_shader
	river_mat.set_shader_parameter("shallow_color", Color(0.15, 0.65, 0.9, 0.95))
	river_mat.set_shader_parameter("flow_speed", 0.85)
	
	outflow_river_mesh_instance.mesh = out_mesh
	outflow_river_mesh_instance.material_override = river_mat
	add_child(outflow_river_mesh_instance)

func build_markers() -> void:
	var pts_3d: PackedVector3Array = river_result.get("path_3d", PackedVector3Array())
	if pts_3d.is_empty():
		return
		
	# Mountain Spring Marker (Cyan glowing crystal/sphere)
	spring_marker = MeshInstance3D.new()
	var sphere = SphereMesh.new()
	sphere.radius = 4.0
	sphere.height = 8.0
	var sphere_mat = StandardMaterial3D.new()
	sphere_mat.albedo_color = Color(0.2, 0.9, 1.0)
	sphere_mat.emission_enabled = true
	sphere_mat.emission = Color(0.1, 0.8, 1.0)
	sphere_mat.emission_energy_multiplier = 3.0
	spring_marker.mesh = sphere
	spring_marker.material_override = sphere_mat
	spring_marker.position = pts_3d[0] + Vector3(0, 4.0, 0)
	add_child(spring_marker)
	
	# Spillway Saddle Marker (Amber/Gold glowing diamond)
	if not primary_lake.is_empty():
		spillway_marker = MeshInstance3D.new()
		var box = BoxMesh.new()
		box.size = Vector3(5.0, 5.0, 5.0)
		var b_mat = StandardMaterial3D.new()
		b_mat.albedo_color = Color(1.0, 0.65, 0.0)
		b_mat.emission_enabled = true
		b_mat.emission = Color(1.0, 0.55, 0.0)
		b_mat.emission_energy_multiplier = 3.0
		spillway_marker.mesh = box
		spillway_marker.material_override = b_mat
		spillway_marker.position = Vector3(primary_lake["spillway_world_pos"].x, primary_lake["spillway_elevation"] + 3.0, primary_lake["spillway_world_pos"].y)
		spillway_marker.rotation_degrees = Vector3(45.0, 45.0, 45.0)
		add_child(spillway_marker)
	
	# Terminal Outlet Marker (Gold glowing cylinder)
	var term_pt = pts_3d[pts_3d.size() - 1]
	if not primary_lake.is_empty() and primary_lake.get("outlet_path_3d", PackedVector3Array()).size() > 0:
		var out_pts: PackedVector3Array = primary_lake["outlet_path_3d"]
		term_pt = out_pts[out_pts.size() - 1]
		
	outlet_marker = MeshInstance3D.new()
	var cyl = CylinderMesh.new()
	cyl.top_radius = 6.0
	cyl.bottom_radius = 6.0
	cyl.height = 3.0
	var cyl_mat = StandardMaterial3D.new()
	cyl_mat.albedo_color = Color(1.0, 0.75, 0.1)
	cyl_mat.emission_enabled = true
	cyl_mat.emission = Color(1.0, 0.7, 0.1)
	cyl_mat.emission_energy_multiplier = 2.5
	outlet_marker.mesh = cyl
	outlet_marker.material_override = cyl_mat
	outlet_marker.position = term_pt + Vector3(0, 1.5, 0)
	add_child(outlet_marker)

func setup_hud() -> void:
	hud_canvas = CanvasLayer.new()
	hud_canvas.layer = 10
	add_child(hud_canvas)
	
	# Top-left information panel
	var panel = PanelContainer.new()
	panel.position = Vector2(24, 24)
	var sb = StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.08, 0.12, 0.88)
	sb.border_color = Color(0.25, 0.65, 0.95, 0.8)
	sb.border_width_left = 2
	sb.border_width_top = 2
	sb.border_width_right = 2
	sb.border_width_bottom = 2
	sb.corner_radius_top_left = 8
	sb.corner_radius_top_right = 8
	sb.corner_radius_bottom_left = 8
	sb.corner_radius_bottom_right = 8
	sb.content_margin_left = 18
	sb.content_margin_top = 16
	sb.content_margin_right = 18
	sb.content_margin_bottom = 16
	panel.add_theme_stylebox_override("panel", sb)
	hud_canvas.add_child(panel)
	
	info_label = Label.new()
	info_label.text = _format_stats_text()
	info_label.add_theme_font_size_override("font_size", 13)
	info_label.add_theme_color_override("font_color", Color(0.92, 0.95, 0.98))
	panel.add_child(info_label)
	
	# Top-right 2D Hydrology Map View
	map_rect = TextureRect.new()
	map_rect.position = Vector2(1280 - 320, 24)
	map_rect.size = Vector2(296, 296)
	map_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	map_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_update_map_texture()
	hud_canvas.add_child(map_rect)

func _format_stats_text() -> String:
	var pts_3d = river_result.get("path_3d", PackedVector3Array())
	var elevs = river_result.get("elevations", PackedFloat32Array())
	var start_h = elevs[0] if elevs.size() > 0 else 0.0
	var end_h = elevs[elevs.size() - 1] if elevs.size() > 0 else 0.0
	
	var txt = "=== SUBLIMEGREENS: TERRAIN, HYDROLOGY & LAKE BASINS ===\n"
	txt += "Domain Size: 1.0 km x 1.0 km (-500m to +500m)\n"
	txt += "Grid Resolution: 256 x 256 (65,536 cells, dx = %.2fm)\n" % world_state.cell_size.x
	txt += "Elevation: Summit %.1fm -> Lowland %.1fm\n" % [world_state.max_raw_elevation, world_state.min_raw_elevation]
	txt += "Lake Basins Detected: %d\n" % world_state.detected_basins.size()
	if not primary_lake.is_empty():
		txt += "Primary Lake: '%s' [H_water = %.1fm, Depth = %.1fm, Area = %.0fm²]\n" % [
			primary_lake["id"], primary_lake["water_elevation"], primary_lake["max_depth_m"], primary_lake["area_m2"]
		]
		txt += "Spillway Saddle: At (%.1f, %.1f) [H = %.1fm]\n" % [
			primary_lake["spillway_world_pos"].x, primary_lake["spillway_world_pos"].y, primary_lake["spillway_elevation"]
		]
	txt += "Network: Spring -> Inflow River -> Lake Basin -> Spillway -> Outflow River\n"
	txt += "Registered Features: %d (Mountains: %d, Lakes: %d, Rivers: %d)\n" % [
		world_state.feature_registry.get_feature_count(),
		world_state.feature_registry.get_feature_count("mountain"),
		world_state.feature_registry.get_feature_count("lake"),
		world_state.feature_registry.get_feature_count("river")
	]
	txt += "Inflow River Steps: %d  |  Outflow River Steps: %d\n" % [
		river_result.get("length_steps", 0),
		primary_lake.get("outlet_path_3d", PackedVector3Array()).size()
	]
	txt += "------------------------------------------------------\n"
	txt += "Controls: [M] Toggle 2D Map  |  [Tab] Toggle Acc/Dir Map\n"
	txt += "Camera: [1] Aerial Overview  |  [2] Lake Basin & Spillway"
	return txt

func _update_map_texture() -> void:
	if show_flow_accumulation:
		var acc_img = hydro.export_flow_accumulation_image()
		# Overlay the river path onto the accumulation map in red/white
		var grid_pts = river_result.get("path_grid", [])
		for pt in grid_pts:
			acc_img.set_pixel(pt.x, pt.y, Color(1.0, 0.2, 0.2, 1.0))
		map_rect.texture = ImageTexture.create_from_image(acc_img)
	else:
		var dir_img = hydro.export_flow_direction_image()
		map_rect.texture = ImageTexture.create_from_image(dir_img)

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_M:
			map_rect.visible = !map_rect.visible
		elif event.keycode == KEY_TAB:
			show_flow_accumulation = !show_flow_accumulation
			_update_map_texture()
		elif event.keycode == KEY_1:
			camera.position = Vector3(-350.0, 220.0, -420.0)
			camera.look_at(Vector3(-50.0, 30.0, 50.0), Vector3.UP)
		elif event.keycode == KEY_2:
			# Low-angle river view looking up toward the mountain
			var pts_3d: PackedVector3Array = river_result.get("path_3d", PackedVector3Array())
			if pts_3d.size() > 40:
				var mid_pt = pts_3d[35]
				camera.position = mid_pt + Vector3(30.0, 15.0, 30.0)
				camera.look_at(pts_3d[0], Vector3.UP)

func _create_color_texture(c: Color) -> ImageTexture:
	var img = Image.create(16, 16, false, Image.FORMAT_RGBA8)
	img.fill(c)
	return ImageTexture.create_from_image(img)
