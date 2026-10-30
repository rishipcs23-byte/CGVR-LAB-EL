# test_milestone_1.gd
# Headless acceptance test suite for Milestone 1: Terrain & Hydrology Foundation.
# Run with: godot --headless -s res://test_milestone_1.gd
extends SceneTree

const TerrainEngine = preload("res://TerrainEngine.gd")
const HydrologyEngine = preload("res://HydrologyEngine.gd")

var passed_count: int = 0
var failed_count: int = 0

func _init() -> void:
	print("\n=================================================================")
	print("SUBLIMEGREENS — MILESTONE 1: TERRAIN & HYDROLOGY TEST SUITE")
	print("=================================================================\n")
	
	test_heightmap_dimensions()
	test_elevation_sampling_consistency()
	test_hydrology_depression_filling()
	test_flow_directions_bounds()
	test_flow_accumulation_mass_conservation()
	test_river_path_connectivity_and_monotonicity()
	test_river_reaches_valid_outlet()
	test_seed_determinism()
	
	print("\n=================================================================")
	if failed_count == 0:
		print("ALL %d ACCEPTANCE TESTS PASSED SUCCESSFULLY!" % passed_count)
		print("=================================================================\n")
		quit(0)
	else:
		printerr("TEST RUN FAILED: %d failed, %d passed." % [failed_count, passed_count])
		print("=================================================================\n")
		quit(1)

func _assert(condition: bool, test_name: String, error_msg: String = "") -> void:
	if condition:
		passed_count += 1
		print("[PASS] %s" % test_name)
	else:
		failed_count += 1
		printerr("[FAIL] %s: %s" % [test_name, error_msg])

# -----------------------------------------------------------------------------
# Test 1: Heightmap Dimensions
# -----------------------------------------------------------------------------
func test_heightmap_dimensions() -> void:
	var terrain = TerrainEngine.new(Vector2(1000.0, 1000.0), Vector2i(256, 256), Vector2(-500.0, -500.0))
	terrain.generate(42)
	
	_assert(terrain.grid_resolution == Vector2i(256, 256), "Heightmap Resolution", "Expected 256x256, got %s" % str(terrain.grid_resolution))
	_assert(terrain.heights.size() == 256 * 256, "Heightmap Storage Size", "Expected 65536 cells, got %d" % terrain.heights.size())
	_assert(terrain.world_size == Vector2(1000.0, 1000.0), "World Size (1km x 1km)", "Expected 1000x1000m, got %s" % str(terrain.world_size))
	
	var expected_cell_dx = 1000.0 / 255.0
	_assert(abs(terrain.cell_size.x - expected_cell_dx) < 0.001, "Cell Metrics Calculation", "Expected cell size ~%.3f, got %.3f" % [expected_cell_dx, terrain.cell_size.x])

# -----------------------------------------------------------------------------
# Test 2: Elevation Sampling Consistency & Slope/Gradient
# -----------------------------------------------------------------------------
func test_elevation_sampling_consistency() -> void:
	var terrain = TerrainEngine.new()
	terrain.generate(42)
	
	# Sample at exact grid cells
	var exact_match = true
	var max_err = 0.0
	for gy in [10, 50, 128, 200]:
		for gx in [15, 64, 150, 240]:
			var raw_h = terrain.get_height_at_cell(gx, gy)
			var wpos = terrain.grid_to_world(float(gx), float(gy))
			var sampled_h = terrain.sample_height(wpos.x, wpos.y)
			var err = abs(raw_h - sampled_h)
			if err > max_err: max_err = err
			if err > 0.0001:
				exact_match = false
				
	_assert(exact_match, "Grid Cell Elevation Sampling Exactness", "Max error: %f" % max_err)
	
	# Bilinear continuity: intermediate sample lies between cell neighbors
	var w0 = terrain.grid_to_world(100.0, 100.0)
	var w1 = terrain.grid_to_world(101.0, 100.0)
	var w_mid = (w0 + w1) * 0.5
	var h0 = terrain.sample_height(w0.x, w0.y)
	var h1 = terrain.sample_height(w1.x, w1.y)
	var h_mid = terrain.sample_height(w_mid.x, w_mid.y)
	var lerp_expected = lerpf(h0, h1, 0.5)
	_assert(abs(h_mid - lerp_expected) < 0.001, "Bilinear Interpolation Continuity", "Sample: %f, Expected: %f" % [h_mid, lerp_expected])
	
	# Gradient & slope calculation at mountain flank
	var m_center = terrain.mountain_peaks[0]["center"]
	var flank_pos = m_center + Vector2(60.0, 60.0)
	var slope_info = terrain.get_slope_and_gradient(flank_pos.x, flank_pos.y)
	_assert(slope_info["slope_angle_deg"] > 10.0, "Mountain Flank Slope Detection", "Slope angle expected >10 deg, got %.2f deg" % slope_info["slope_angle_deg"])
	_assert(slope_info["normal"].y < 0.98 and slope_info["normal"].y > 0.3, "Normal Vector Plausibility", "Normal.y = %.3f" % slope_info["normal"].y)

# -----------------------------------------------------------------------------
# Test 3: Priority-Flood Depression Resolution
# -----------------------------------------------------------------------------
func test_hydrology_depression_filling() -> void:
	var terrain = TerrainEngine.new()
	terrain.generate(42)
	
	# Inject an artificial severe pit in the plateau (cell 120, 120)
	var pit_gx = 120
	var pit_gy = 120
	var original_h = terrain.get_height_at_cell(pit_gx, pit_gy)
	terrain.set_height_at_cell(pit_gx, pit_gy, original_h - 25.0) # 25m depression
	
	var hydro = HydrologyEngine.new(terrain)
	var filled_count = hydro.fill_depressions_priority_flood()
	
	_assert(filled_count > 0, "Depression Detection and Filling", "Priority-Flood filled %d cells" % filled_count)
	
	var resolved_pit_h = hydro.filled_heights[pit_gy * hydro.grid_size.x + pit_gx]
	_assert(resolved_pit_h >= original_h - 25.0 + 1.0, "Pit Elevation Raised to Spillway", "Pit was %f, raised to %f" % [original_h - 25.0, resolved_pit_h])

# -----------------------------------------------------------------------------
# Test 4: Flow Directions & Boundary Invariants
# -----------------------------------------------------------------------------
func test_flow_directions_bounds() -> void:
	var terrain = TerrainEngine.new()
	terrain.generate(42)
	var hydro = HydrologyEngine.new(terrain)
	hydro.resolve_hydrology()
	
	var w = hydro.grid_size.x
	var h = hydro.grid_size.y
	var all_valid = true
	var boundary_outlets_correct = true
	
	for y in range(h):
		for x in range(w):
			var idx = y * w + x
			var dir = hydro.flow_directions[idx]
			
			if x == 0 or x == w - 1 or y == 0 or y == h - 1:
				if dir != HydrologyEngine.OUTLET:
					boundary_outlets_correct = false
			else:
				if dir < 0 or dir >= 8:
					all_valid = false
				else:
					var target_idx = hydro.get_downstream_cell_index(idx)
					if target_idx < 0 or target_idx >= hydro.total_cells:
						all_valid = false
						
	_assert(boundary_outlets_correct, "Boundary Cells Configured as Outlets", "All perimeter cells must route off-grid")
	_assert(all_valid, "D8 Flow Directions Contained Within Grid", "Interior cells have valid 0..7 flow directions pointing in-bounds")

# -----------------------------------------------------------------------------
# Test 5: Flow Accumulation & Mass Conservation
# -----------------------------------------------------------------------------
func test_flow_accumulation_mass_conservation() -> void:
	var terrain = TerrainEngine.new()
	terrain.generate(42)
	var hydro = HydrologyEngine.new(terrain)
	hydro.resolve_hydrology()
	
	var all_ge_one = true
	var total_runoff_sum = 0.0
	
	for idx in range(hydro.total_cells):
		var acc = hydro.flow_accumulation[idx]
		if acc < 1.0:
			all_ge_one = false
		if hydro.flow_directions[idx] == HydrologyEngine.OUTLET:
			total_runoff_sum += acc
			
	_assert(all_ge_one, "Flow Accumulation Minimum Baseline (Runoff >= 1.0)", "Every cell contributes at least its own area")
	_assert(hydro.max_accumulation > 1000.0, "River Channel Emergence", "Max accumulation reaches %.0f cells (>1000 required for major river)" % hydro.max_accumulation)
	
	# In a fully drained DAG with no unresolved sinks, sum of outlet discharge must equal total cells
	var mass_diff = abs(total_runoff_sum - float(hydro.total_cells))
	_assert(mass_diff < 1.0, "Hydrological Mass Conservation (Total Runoff = %d)" % hydro.total_cells, "Outlet sum: %.1f, Total cells: %d, Diff: %.1f" % [total_runoff_sum, hydro.total_cells, mass_diff])

# -----------------------------------------------------------------------------
# Test 6: River Path Connectivity & Topographic Monotonicity
# -----------------------------------------------------------------------------
func test_river_path_connectivity_and_monotonicity() -> void:
	var terrain = TerrainEngine.new()
	terrain.generate(42)
	var hydro = HydrologyEngine.new(terrain)
	hydro.resolve_hydrology()
	
	# Start water source at high mountain slope: North-West (-160, -220)
	var spring_pos = Vector2(-160.0, -220.0)
	var result = hydro.trace_drainage_path(spring_pos, 2000)
	
	_assert(result["length_steps"] >= 40, "River Traverses Significant Distance", "Path length: %d steps" % result["length_steps"])
	
	# Connectivity check: 8-neighbor spatial adjacency
	var grid_pts = result["path_grid"]
	var is_8_connected = true
	for i in range(grid_pts.size() - 1):
		var p0 = grid_pts[i]
		var p1 = grid_pts[i + 1]
		var dx = abs(p1.x - p0.x)
		var dy = abs(p1.y - p0.y)
		if dx > 1 or dy > 1 or (dx == 0 and dy == 0):
			is_8_connected = false
			break
	_assert(is_8_connected, "River Path Spatial 8-Neighbor Connectivity", "Path must not have spatial gaps or teleportations")
	
	# Topographic Monotonicity on resolved drainage surface: strictly descending
	_assert(result["is_monotonic"], "Elevation Monotonicity (River Flows Downhill)", "Violations: %d" % result["violation_count"])
	
	var start_elev = result["elevations"][0]
	var end_elev = result["elevations"][result["elevations"].size() - 1]
	_assert(end_elev < start_elev - 20.0, "Significant Downward Relief Traverse", "Spring elevation: %.1fm -> Outlet elevation: %.1fm (Drop: %.1fm)" % [start_elev, end_elev, start_elev - end_elev])

# -----------------------------------------------------------------------------
# Test 7: River Reaches Valid Boundary Outlet
# -----------------------------------------------------------------------------
func test_river_reaches_valid_outlet() -> void:
	var terrain = TerrainEngine.new()
	terrain.generate(42)
	var hydro = HydrologyEngine.new(terrain)
	hydro.resolve_hydrology()
	
	var spring_pos = Vector2(-160.0, -220.0)
	var result = hydro.trace_drainage_path(spring_pos, 2000)
	
	_assert(result["termination_reason"] == "reached_boundary_outlet" or result["termination_reason"] == "reached_boundary_edge", 
			"River Drainage Reaches World Boundary", "Termination: %s" % result["termination_reason"])
	
	var end_pt = result["end_point"]
	var at_border = (abs(end_pt.x - 500.0) < 10.0 or abs(end_pt.x - (-500.0)) < 10.0 or
					 abs(end_pt.z - 500.0) < 10.0 or abs(end_pt.z - (-500.0)) < 10.0)
	_assert(at_border, "Terminal Point Reaches World Perimeter Edge", "End coordinate: %s" % str(end_pt))
	_assert(hydro.outlets_list.size() > 0, "Cataloged Drainage Outlets Present", "Outlets found: %d" % hydro.outlets_list.size())

# -----------------------------------------------------------------------------
# Test 8: Determinism Across Repeated Runs
# -----------------------------------------------------------------------------
func test_seed_determinism() -> void:
	var terrain_a = TerrainEngine.new()
	terrain_a.generate(999)
	var hydro_a = HydrologyEngine.new(terrain_a)
	hydro_a.resolve_hydrology()
	var path_a = hydro_a.trace_drainage_path(Vector2(-150.0, -200.0))
	
	var terrain_b = TerrainEngine.new()
	terrain_b.generate(999)
	var hydro_b = HydrologyEngine.new(terrain_b)
	hydro_b.resolve_hydrology()
	var path_b = hydro_b.trace_drainage_path(Vector2(-150.0, -200.0))
	
	var heights_identical = (terrain_a.heights == terrain_b.heights)
	var dirs_identical = (hydro_a.flow_directions == hydro_b.flow_directions)
	var acc_identical = (hydro_a.flow_accumulation == hydro_b.flow_accumulation)
	var paths_identical = (path_a["path_grid"] == path_b["path_grid"])
	
	_assert(heights_identical, "Deterministic Terrain Heights", "Identical seed produces identical height buffer")
	_assert(dirs_identical, "Deterministic Flow Directions", "Identical seed produces identical D8 directions")
	_assert(acc_identical, "Deterministic Flow Accumulation", "Identical seed produces identical accumulation")
	_assert(paths_identical, "Deterministic River Path Waypoints", "Identical seed traces identical river trajectory")
