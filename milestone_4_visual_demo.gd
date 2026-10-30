# milestone_4_visual_demo.gd
# Generates high-resolution 2D diagnostic visual evidence of localized dirty-region chunk updates,
# boundary crossings, and player stability for the Milestone 4 completion report.
extends SceneTree

const TerrainEngine = preload("res://TerrainEngine.gd")
const HydrologyEngine = preload("res://HydrologyEngine.gd")
const WorldState = preload("res://WorldState.gd")
const DirtyRegionTracker = preload("res://DirtyRegionTracker.gd")
const WorldEditManager = preload("res://WorldEditManager.gd")
const ChunkManagerClass = preload("res://ChunkManager.gd")

func _init() -> void:
	print("Milestone 4: Generating visual diagnostic map for localized chunk updates...")
	DirAccess.make_dir_absolute("res://screenshots")
	
	var ws = WorldState.new(Vector2(1000.0, 1000.0), Vector2i(256, 256), Vector2(-500.0, -500.0), 42)
	# Rolling terrain
	var terr = TerrainEngine.new(ws.world_size, ws.grid_resolution, ws.world_origin)
	terr.generate(42, {"base_elevation": 12.0})
	var hyd = HydrologyEngine.new(terr)
	hyd.resolve_hydrology()
	ws.initialize_from_simulation(terr, hyd)
	
	var edit_mgr = WorldEditManager.new()
	edit_mgr.world_state = ws
	
	# Apply an localized edit (radial mountain at (40.0, 40.0), radius 60.0m, height 35.0m)
	# This crosses chunks: (0,0), (1,0), (0,1), (1,1)
	var edit_center = Vector2(40.0, 40.0)
	var edit_radius = 60.0
	var edit_res = edit_mgr.apply_elevation_brush(edit_center, edit_radius, 35.0, "smooth", -1)
	var dirty_region = edit_res.dirty_region
	var affected_chunks: Array[Vector2i] = edit_res.affected_chunks
	
	# Render 512x512 diagnostic map
	var img_size = 512
	var img = Image.create(img_size, img_size, false, Image.FORMAT_RGBA8)
	var mm = Vector2(ws.min_raw_elevation, ws.max_raw_elevation)
	var h_range = max(1.0, mm.y - mm.x)
	var eff_chunk_size = 64.0
	
	for py in range(img_size):
		var wz = -500.0 + (float(py) / float(img_size)) * 1000.0
		for px in range(img_size):
			var wx = -500.0 + (float(px) / float(img_size)) * 1000.0
			var h = ws.get_elevation_at(wx, wz)
			var norm_h = clampf((h - mm.x) / h_range, 0.0, 1.0)
			
			# Base hypsometric tint
			var c = Color(0.2, 0.45, 0.25).lerp(Color(0.85, 0.8, 0.65), norm_h)
			if norm_h > 0.7:
				c = Color(0.85, 0.8, 0.65).lerp(Color(0.98, 0.98, 1.0), (norm_h - 0.7) / 0.3)
				
			# Chunk grid lines
			var cx = floori(wx / eff_chunk_size)
			var cz = floori(wz / eff_chunk_size)
			var is_chunk_border_x = abs(fposmod(wx, eff_chunk_size)) < 1.8 or abs(fposmod(wx, eff_chunk_size) - eff_chunk_size) < 1.8
			var is_chunk_border_z = abs(fposmod(wz, eff_chunk_size)) < 1.8 or abs(fposmod(wz, eff_chunk_size) - eff_chunk_size) < 1.8
			
			if is_chunk_border_x or is_chunk_border_z:
				c = c.lerp(Color(0.15, 0.2, 0.25), 0.5)
				
			# Highlight affected chunks
			if affected_chunks.has(Vector2i(cx, cz)):
				c = c.lerp(Color(0.2, 0.8, 0.4), 0.22)
				
			# Draw dirty region bounding box outline
			var bounds: Rect2 = dirty_region.world_bounds
			var in_bounds_x = wx >= bounds.position.x and wx <= bounds.end.x
			var in_bounds_z = wz >= bounds.position.y and wz <= bounds.end.y
			var on_edge_x = abs(wx - bounds.position.x) < 2.5 or abs(wx - bounds.end.x) < 2.5
			var on_edge_z = abs(wz - bounds.position.y) < 2.5 or abs(wz - bounds.end.y) < 2.5
			if (in_bounds_x and on_edge_z) or (in_bounds_z and on_edge_x):
				c = Color(1.0, 0.85, 0.1, 1.0) # Yellow boundary
				
			# Draw player marker at (0.0, 0.0)
			if Vector2(wx, wz).distance_to(Vector2.ZERO) < 6.0:
				c = Color(1.0, 0.2, 0.2, 1.0) # Red dot for player
				
			img.set_pixel(px, py, c)
			
	var save_path = "res://screenshots/milestone4_dirty_chunks_and_player.png"
	img.save_png(save_path)
	print("[SAVED] %s" % save_path)
	quit(0)

