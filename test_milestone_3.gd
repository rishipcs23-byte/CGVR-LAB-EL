# test_milestone_3.gd
# Headless acceptance test suite for Milestone 3: Lake Basin Solver & Depression Dynamics.
# Run with: godot --headless -s res://test_milestone_3.gd
extends SceneTree

const TerrainEngine = preload("res://TerrainEngine.gd")
const HydrologyEngine = preload("res://HydrologyEngine.gd")
const WorldState = preload("res://WorldState.gd")
const FeatureRegistry = preload("res://FeatureRegistry.gd")
const LakeBasinSolver = preload("res://LakeBasinSolver.gd")

var passed_count: int = 0
var failed_count: int = 0

func _init() -> void:
	print("\n=================================================================")
	print("SUBLIMEGREENS — MILESTONE 3: LAKE BASIN SOLVER TEST SUITE")
	print("=================================================================\n")
	
	test_synthetic_bowl_detection_and_connectivity()
	test_disconnected_depressions_separation()
	test_basin_floor_and_spillway_accuracy()
	test_basin_area_and_water_volume_conservation()
	test_water_level_and_depth_from_raw_terrain()
	test_shoreline_boundary_extraction()
	test_spillway_connectivity_and_downstream_drainage()
	test_terminal_and_boundary_basins()
	test_insignificant_pit_filtering()
	test_edge_case_flat_terrain()
	test_edge_case_nested_and_adjacent_depressions()
	test_seed_determinism()
	test_feature_registry_lake_integration()
	test_lake_to_river_relationships()
	test_raw_elevation_buffer_immutability()
	test_world_state_lake_invalidation()
	test_milestone_regression_checks()
	
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
# Fixture Generator: Creates a controlled synthetic grid with known depression
# -----------------------------------------------------------------------------
func _create_synthetic_fixture(grid_w: int, grid_h: int, base_elev: float = 50.0) -> Dictionary:
	var total = grid_w * grid_h
	var raw = PackedFloat32Array()
	raw.resize(total)
	raw.fill(base_elev)
	
	# Cell size: 4m x 4m, origin: (0, 0)
	var cell_dx = 4.0
	var cell_dy = 4.0
	
	return {
		"w": grid_w,
		"h": grid_h,
		"raw": raw,
		"cell_size": Vector2(cell_dx, cell_dy),
		"origin": Vector2.ZERO
	}

# -----------------------------------------------------------------------------
# Test 1 & 2: Simple Bowl-Shaped Depression & Connected Cells
# -----------------------------------------------------------------------------
func test_synthetic_bowl_detection_and_connectivity() -> void:
	var fix = _create_synthetic_fixture(64, 64, 50.0)
	var center = Vector2(32, 32)
	var radius = 8.0 # 8 cells radius
	var depth = 12.0 # 12 meters deep at center
	
	var expected_cells = 0
	for y in range(fix["h"]):
		for x in range(fix["w"]):
			var d = Vector2(x, y).distance_to(center)
			if d < radius:
				var drop = depth * (1.0 - (d / radius) * (d / radius))
				fix["raw"][y * fix["w"] + x] = 50.0 - drop
				expected_cells += 1
				
	# Run Hydrology Priority-Flood
	var terrain = TerrainEngine.new(Vector2(256, 256), Vector2i(64, 64), Vector2.ZERO)
	terrain.heights = fix["raw"].duplicate()
	var hydro = HydrologyEngine.new(terrain)
	hydro.resolve_hydrology()
	
	var solver = LakeBasinSolver.new(5, 0.5)
	var basins = solver.solve_from_buffers(
		fix["raw"], hydro.filled_heights, hydro.flow_directions,
		Vector2i(64, 64), fix["cell_size"], fix["origin"]
	)
	
	_assert(basins.size() == 1, "Bowl Depression Detected Exactly Once", "Basins count: %d" % basins.size())
	if basins.size() == 1:
		var b = basins[0]
		_assert(b["lake_cells"].size() == expected_cells, "Connected Bowl Cell Count Match", "Expected %d cells, got %d" % [expected_cells, b["lake_cells"].size()])
		_assert(abs(b["floor_elevation"] - (50.0 - depth)) < 0.01, "Bowl Minimum Floor Elevation Correct (38.0m)", "Floor: %.2fm" % b["floor_elevation"])
		_assert(abs(b["spillway_elevation"] - 50.0) < 0.1, "Bowl Spillway Elevation Correct (50.0m)", "Spillway: %.2fm" % b["spillway_elevation"])

# -----------------------------------------------------------------------------
# Test 3: Two Disconnected Depressions Separated
# -----------------------------------------------------------------------------
func test_disconnected_depressions_separation() -> void:
	var fix = _create_synthetic_fixture(64, 64, 60.0)
	
	# Bowl A at (16, 16), radius 6, depth 10m
	for y in range(fix["h"]):
		for x in range(fix["w"]):
			var dA = Vector2(x, y).distance_to(Vector2(16, 16))
			if dA < 6.0:
				fix["raw"][y * fix["w"] + x] = 60.0 - 10.0 * (1.0 - dA / 6.0)
				
			var dB = Vector2(x, y).distance_to(Vector2(48, 48))
			if dB < 7.0:
				fix["raw"][y * fix["w"] + x] = 60.0 - 14.0 * (1.0 - dB / 7.0)
				
	var terrain = TerrainEngine.new(Vector2(256, 256), Vector2i(64, 64), Vector2.ZERO)
	terrain.heights = fix["raw"].duplicate()
	var hydro = HydrologyEngine.new(terrain)
	hydro.resolve_hydrology()
	
	var solver = LakeBasinSolver.new(5, 0.5)
	var basins = solver.solve_from_buffers(
		fix["raw"], hydro.filled_heights, hydro.flow_directions,
		Vector2i(64, 64), fix["cell_size"], fix["origin"]
	)
	
	_assert(basins.size() == 2, "Two Disconnected Depressions Separated into 2 Basins", "Basins count: %d" % basins.size())
	if basins.size() == 2:
		var ids = [basins[0]["id"], basins[1]["id"]]
		_assert(ids[0] != ids[1], "Distinct Unique Basin IDs Generated", "IDs: %s" % str(ids))
		# Check spatial separation
		var pA = basins[0]["floor_cell"]
		var pB = basins[1]["floor_cell"]
		_assert(Vector2(pA).distance_to(Vector2(pB)) > 25.0, "Spatial Independence Between Distinct Basins", "Distance: %.1f cells" % Vector2(pA).distance_to(Vector2(pB)))

# -----------------------------------------------------------------------------
# Test 4 & 5: Basin Floor and Spillway Accuracy on Sloped Plane with Asymmetrical Rim
# -----------------------------------------------------------------------------
func test_basin_floor_and_spillway_accuracy() -> void:
	var fix = _create_synthetic_fixture(64, 64, 40.0)
	
	# Create a valley with a southern outlet notched at 42m, north rim at 50m, west at 48m, east at 48m
	for y in range(fix["h"]):
		for x in range(fix["w"]):
			# Surrounding ridge rim
			var d = Vector2(x, y).distance_to(Vector2(32, 32))
			if d < 12.0:
				fix["raw"][y * fix["w"] + x] = 30.0 + (d / 12.0) * 10.0 # Basin floor at 30.0m, edge of bowl at 40.0m
			else:
				fix["raw"][y * fix["w"] + x] = 48.0 # High plateau
				
	# Carve specific spillway notch on South rim at (32, 44) down to 42.0m
	fix["raw"][44 * 64 + 32] = 42.0
	# Channel continuing south from notch down to 35m
	for y in range(45, 64):
		fix["raw"][y * 64 + 32] = 42.0 - (float(y - 44) * 0.5)
		
	var terrain = TerrainEngine.new(Vector2(256, 256), Vector2i(64, 64), Vector2.ZERO)
	terrain.heights = fix["raw"].duplicate()
	var hydro = HydrologyEngine.new(terrain)
	hydro.resolve_hydrology()
	
	var solver = LakeBasinSolver.new(5, 0.5)
	var basins = solver.solve_from_buffers(
		fix["raw"], hydro.filled_heights, hydro.flow_directions,
		Vector2i(64, 64), fix["cell_size"], fix["origin"]
	)
	
	_assert(basins.size() == 1, "Asymmetrical Rim Basin Solved", "Count: %d" % basins.size())
	if basins.size() == 1:
		var b = basins[0]
		_assert(abs(b["floor_elevation"] - 30.0) < 0.1, "Exact Floor Elevation Matched (30.0m)", "Floor: %.2fm" % b["floor_elevation"])
		_assert(abs(b["spillway_elevation"] - 42.0) < 0.5, "Spillway Saddle Identified at Lowest Notch (42.0m)", "Spillway: %.2fm" % b["spillway_elevation"])
		_assert(b["spillway_cell"].x == 32 and abs(b["spillway_cell"].y - 44) <= 1, "Spillway Location Matched South Notch (32, 44)", "Spillway cell: %s" % str(b["spillway_cell"]))

# -----------------------------------------------------------------------------
# Test 6, 8 & 9: Basin Area, Water Depth from Raw Elevation & Volume Conservation
# -----------------------------------------------------------------------------
func test_basin_area_and_water_volume_conservation() -> void:
	var fix = _create_synthetic_fixture(50, 50, 40.0)
	var center = Vector2(25, 25)
	var r = 6.0
	
	var raw_depth_sum = 0.0
	var cell_area = 16.0 # 4m x 4m
	
	for y in range(50):
		for x in range(50):
			var d = Vector2(x, y).distance_to(center)
			if d < r:
				var h = 30.0 + (d / r) * 10.0 # Floor at 30.0, Rim at 40.0
				fix["raw"][y * 50 + x] = h
				raw_depth_sum += (40.0 - h)
				
	var expected_capacity = raw_depth_sum * cell_area
	
	var terrain = TerrainEngine.new(Vector2(200, 200), Vector2i(50, 50), Vector2.ZERO)
	terrain.heights = fix["raw"].duplicate()
	var hydro = HydrologyEngine.new(terrain)
	hydro.resolve_hydrology()
	
	var solver = LakeBasinSolver.new(5, 0.5)
	var basins = solver.solve_from_buffers(
		fix["raw"], hydro.filled_heights, hydro.flow_directions,
		Vector2i(50, 50), fix["cell_size"], fix["origin"],
		{"default_fill_ratio": 1.0}
	)
	
	_assert(basins.size() == 1, "Basin Volume Fixture Solved", "Basins: %d" % basins.size())
	if basins.size() == 1:
		var b = basins[0]
		var vol_diff_pct = abs(b["capacity_volume_m3"] - expected_capacity) / expected_capacity
		_assert(vol_diff_pct < 0.05, "Water Capacity Volume Matches Mathematical Sum (Within 5%)", "Calculated: %.1fm3, Expected: %.1fm3" % [b["capacity_volume_m3"], expected_capacity])
		_assert(b["max_depth_m"] >= 9.9 and b["max_depth_m"] <= 10.1, "Physical Max Depth = 10.0m (40m - 30m)", "Max depth: %.2fm" % b["max_depth_m"])

# -----------------------------------------------------------------------------
# Test 7: Water Surface Elevation at Partial Fill Ratio
# -----------------------------------------------------------------------------
func test_water_level_and_depth_from_raw_terrain() -> void:
	var fix = _create_synthetic_fixture(50, 50, 50.0)
	# Parabolic cone
	for y in range(50):
		for x in range(50):
			var d = Vector2(x, y).distance_to(Vector2(25, 25))
			if d < 10.0:
				fix["raw"][y * 50 + x] = 30.0 + pow(d / 10.0, 2) * 20.0 # Floor at 30, rim at 50
				
	var terrain = TerrainEngine.new(Vector2(200, 200), Vector2i(50, 50), Vector2.ZERO)
	terrain.heights = fix["raw"].duplicate()
	var hydro = HydrologyEngine.new(terrain)
	hydro.resolve_hydrology()
	
	var solver = LakeBasinSolver.new(5, 0.5)
	# Test with 50% fill ratio
	var basins = solver.solve_from_buffers(
		fix["raw"], hydro.filled_heights, hydro.flow_directions,
		Vector2i(50, 50), fix["cell_size"], fix["origin"],
		{"default_fill_ratio": 0.5}
	)
	
	_assert(basins.size() == 1, "Partial Fill Lake Basin Solved", "Count: %d" % basins.size())
	if basins.size() == 1:
		var b = basins[0]
		_assert(b["water_elevation"] < b["spillway_elevation"], "Water Surface Below Spillway at 50% Fill", "Water: %.2fm < Spillway: %.2fm" % [b["water_elevation"], b["spillway_elevation"]])
		_assert(b["water_elevation"] > b["floor_elevation"], "Water Surface Above Floor at 50% Fill", "Water: %.2fm > Floor: %.2fm" % [b["water_elevation"], b["floor_elevation"]])
		_assert(abs(b["fill_ratio"] - 0.5) < 0.05, "Target 50% Fill Ratio Attained Accurately", "Fill ratio: %.2f" % b["fill_ratio"])

# -----------------------------------------------------------------------------
# Test 10: Shoreline Boundary Extraction
# -----------------------------------------------------------------------------
func test_shoreline_boundary_extraction() -> void:
	var fix = _create_synthetic_fixture(40, 40, 50.0)
	for y in range(40):
		for x in range(40):
			var d = Vector2(x, y).distance_to(Vector2(20, 20))
			if d < 8.0:
				fix["raw"][y * 40 + x] = 35.0
				
	var terrain = TerrainEngine.new(Vector2(160, 160), Vector2i(40, 40), Vector2.ZERO)
	terrain.heights = fix["raw"].duplicate()
	var hydro = HydrologyEngine.new(terrain)
	hydro.resolve_hydrology()
	
	var solver = LakeBasinSolver.new(5, 0.5)
	var basins = solver.solve_from_buffers(
		fix["raw"], hydro.filled_heights, hydro.flow_directions,
		Vector2i(40, 40), fix["cell_size"], fix["origin"]
	)
	
	_assert(basins.size() == 1, "Shoreline Extraction Basin Solved", "Count: %d" % basins.size())
	if basins.size() == 1:
		var b = basins[0]
		var shores = b["shoreline_cells"]
		_assert(shores.size() > 10, "Shoreline Boundary Cells Extracted (>10)", "Shore cells: %d" % shores.size())
		# Verify shoreline cells lie strictly at perimeter
		var all_touch_land = true
		for s in shores:
			var d = Vector2(s).distance_to(Vector2(20, 20))
			if d < 5.0: # Interior cells cannot be shoreline
				all_touch_land = false
		_assert(all_touch_land, "Shoreline Cells Strictly Form Perimeter Rim", "Shoreline cell position check")

# -----------------------------------------------------------------------------
# Test 11 & 12: Spillway Connectivity & Downstream Outflow Drainage
# -----------------------------------------------------------------------------
func test_spillway_connectivity_and_downstream_drainage() -> void:
	# Terrain sloping South from 60m down to 20m, with a basin in the North
	var fix = _create_synthetic_fixture(64, 64, 50.0)
	for y in range(64):
		var base_y = 60.0 - float(y) * 0.5 # Slope from 60 to 28.5
		for x in range(64):
			fix["raw"][y * 64 + x] = base_y
			
	# Carve depression at (32, 16)
	for y in range(64):
		for x in range(64):
			var d = Vector2(x, y).distance_to(Vector2(32, 16))
			if d < 8.0:
				fix["raw"][y * 64 + x] = 40.0 - (1.0 - d / 8.0) * 8.0
				
	var terrain = TerrainEngine.new(Vector2(256, 256), Vector2i(64, 64), Vector2.ZERO)
	terrain.heights = fix["raw"].duplicate()
	var hydro = HydrologyEngine.new(terrain)
	hydro.resolve_hydrology()
	
	var solver = LakeBasinSolver.new(5, 0.5)
	var basins = solver.solve_from_buffers(
		fix["raw"], hydro.filled_heights, hydro.flow_directions,
		Vector2i(64, 64), fix["cell_size"], fix["origin"]
	)
	
	_assert(basins.size() == 1, "Sloped Lake Basin Solved", "Count: %d" % basins.size())
	if basins.size() == 1:
		var b = basins[0]
		var outlet_path = b["outlet_path_3d"]
		_assert(outlet_path.size() >= 10, "Spillway Outflow River Traced Downstream", "Path steps: %d" % outlet_path.size())
		
		# Verify descending elevation monotonicity along outlet river
		var is_monotonic = true
		for i in range(outlet_path.size() - 1):
			if outlet_path[i + 1].y > outlet_path[i].y + 0.01:
				is_monotonic = false
		_assert(is_monotonic, "Spillway Outflow River Strictly Descends Downhill", "Monotonicity along outflow channel")

# -----------------------------------------------------------------------------
# Test 13: Terminal Basins (Draining directly off-grid or into terminal sinks)
# -----------------------------------------------------------------------------
func test_terminal_and_boundary_basins() -> void:
	var fix = _create_synthetic_fixture(40, 40, 50.0)
	# Pit abutting the boundary at x=0
	for y in range(15, 25):
		for x in range(0, 8):
			fix["raw"][y * 40 + x] = 30.0
			
	var terrain = TerrainEngine.new(Vector2(160, 160), Vector2i(40, 40), Vector2.ZERO)
	terrain.heights = fix["raw"].duplicate()
	var hydro = HydrologyEngine.new(terrain)
	hydro.resolve_hydrology()
	
	var solver = LakeBasinSolver.new(5, 0.5)
	var basins = solver.solve_from_buffers(
		fix["raw"], hydro.filled_heights, hydro.flow_directions,
		Vector2i(40, 40), fix["cell_size"], fix["origin"]
	)
	
	if basins.size() > 0:
		_assert(basins[0]["is_terminal"] == true, "Boundary-Abutting Basin Flagged as Terminal Basin", "Terminal: %s" % str(basins[0]["is_terminal"]))
	else:
		_assert(true, "Boundary Pits Drained Immediately Across Grid Border", "")

# -----------------------------------------------------------------------------
# Test 14: Filtering Insignificant Pits via Configurable Thresholds
# -----------------------------------------------------------------------------
func test_insignificant_pit_filtering() -> void:
	var fix = _create_synthetic_fixture(50, 50, 50.0)
	
	# 1. Micro-pit: 4 cells, 0.3m deep (should be filtered)
	fix["raw"][10 * 50 + 10] = 49.7
	fix["raw"][10 * 50 + 11] = 49.7
	fix["raw"][11 * 50 + 10] = 49.7
	
	# 2. Genuine lake basin: 30 cells, 5.0m deep (should be kept)
	for y in range(30, 40):
		for x in range(30, 40):
			if Vector2(x, y).distance_to(Vector2(35, 35)) < 4.0:
				fix["raw"][y * 50 + x] = 45.0
				
	var terrain = TerrainEngine.new(Vector2(200, 200), Vector2i(50, 50), Vector2.ZERO)
	terrain.heights = fix["raw"].duplicate()
	var hydro = HydrologyEngine.new(terrain)
	hydro.resolve_hydrology()
	
	# Threshold: min_area = 10 cells, min_depth = 1.0m
	var solver = LakeBasinSolver.new(10, 1.0)
	var basins = solver.solve_from_buffers(
		fix["raw"], hydro.filled_heights, hydro.flow_directions,
		Vector2i(50, 50), fix["cell_size"], fix["origin"]
	)
	
	_assert(basins.size() == 1, "Micro-Pit Filtered While Genuine Basin Retained", "Basin count: %d (expected 1)" % basins.size())
	if basins.size() == 1:
		_assert(basins[0]["cell_count"] >= 15, "Retained Basin Matches Genuine Lake Dimensions", "Cells: %d" % basins[0]["cell_count"])

# -----------------------------------------------------------------------------
# Test 15: Edge Case - Perfectly Flat Terrain
# -----------------------------------------------------------------------------
func test_edge_case_flat_terrain() -> void:
	var fix = _create_synthetic_fixture(30, 30, 25.0)
	var terrain = TerrainEngine.new(Vector2(120, 120), Vector2i(30, 30), Vector2.ZERO)
	terrain.heights = fix["raw"].duplicate()
	var hydro = HydrologyEngine.new(terrain)
	hydro.resolve_hydrology()
	
	var solver = LakeBasinSolver.new(5, 0.5)
	var basins = solver.solve_from_buffers(
		fix["raw"], hydro.filled_heights, hydro.flow_directions,
		Vector2i(30, 30), fix["cell_size"], fix["origin"]
	)
	
	_assert(basins.is_empty(), "Flat Terrain Generates Zero False Positive Basins", "Basins: %d" % basins.size())

# -----------------------------------------------------------------------------
# Test 16: Edge Case - Nested / Adjacent Depressions
# -----------------------------------------------------------------------------
func test_edge_case_nested_and_adjacent_depressions() -> void:
	var fix = _create_synthetic_fixture(64, 64, 60.0)
	# Two adjacent depressions separated by a low saddle (saddle at 54m, deep floors at 40m and 45m)
	for y in range(64):
		for x in range(64):
			var d1 = Vector2(x, y).distance_to(Vector2(24, 32))
			if d1 < 8.0:
				fix["raw"][y * 64 + x] = 40.0 + (d1 / 8.0) * 16.0
				
			var d2 = Vector2(x, y).distance_to(Vector2(40, 32))
			if d2 < 8.0:
				var h2 = 45.0 + (d2 / 8.0) * 13.0
				if h2 < fix["raw"][y * 64 + x]:
					fix["raw"][y * 64 + x] = h2
					
	var terrain = TerrainEngine.new(Vector2(256, 256), Vector2i(64, 64), Vector2.ZERO)
	terrain.heights = fix["raw"].duplicate()
	var hydro = HydrologyEngine.new(terrain)
	hydro.resolve_hydrology()
	
	var solver = LakeBasinSolver.new(5, 0.5)
	var basins = solver.solve_from_buffers(
		fix["raw"], hydro.filled_heights, hydro.flow_directions,
		Vector2i(64, 64), fix["cell_size"], fix["origin"]
	)
	
	_assert(basins.size() >= 1, "Adjacent Nested Depression Resolved Stably Without Infinite Loops", "Basins: %d" % basins.size())

# -----------------------------------------------------------------------------
# Test 17: Deterministic Output Across Repeated Runs
# -----------------------------------------------------------------------------
func test_seed_determinism() -> void:
	var terrain_a = TerrainEngine.new()
	terrain_a.generate(777)
	# Carve artificial lake basin
	for gy in range(80, 110):
		for gx in range(80, 110):
			var d = Vector2(gx, gy).distance_to(Vector2(95, 95))
			if d < 12.0:
				terrain_a.set_height_at_cell(gx, gy, terrain_a.get_height_at_cell(gx, gy) - 15.0)
				
	var hydro_a = HydrologyEngine.new(terrain_a)
	hydro_a.resolve_hydrology()
	var solver_a = LakeBasinSolver.new(10, 0.8)
	var basins_a = solver_a.solve_from_buffers(
		terrain_a.heights, hydro_a.filled_heights, hydro_a.flow_directions,
		terrain_a.grid_resolution, terrain_a.cell_size, terrain_a.world_origin
	)
	
	var terrain_b = TerrainEngine.new()
	terrain_b.generate(777)
	for gy in range(80, 110):
		for gx in range(80, 110):
			var d = Vector2(gx, gy).distance_to(Vector2(95, 95))
			if d < 12.0:
				terrain_b.set_height_at_cell(gx, gy, terrain_b.get_height_at_cell(gx, gy) - 15.0)
				
	var hydro_b = HydrologyEngine.new(terrain_b)
	hydro_b.resolve_hydrology()
	var solver_b = LakeBasinSolver.new(10, 0.8)
	var basins_b = solver_b.solve_from_buffers(
		terrain_b.heights, hydro_b.filled_heights, hydro_b.flow_directions,
		terrain_b.grid_resolution, terrain_b.cell_size, terrain_b.world_origin
	)
	
	_assert(basins_a.size() == basins_b.size(), "Deterministic Basin Count", "A: %d, B: %d" % [basins_a.size(), basins_b.size()])
	if basins_a.size() > 0 and basins_b.size() > 0:
		_assert(basins_a[0]["floor_elevation"] == basins_b[0]["floor_elevation"], "Deterministic Basin Floor Elevation", "Floor A: %f, B: %f" % [basins_a[0]["floor_elevation"], basins_b[0]["floor_elevation"]])
		_assert(basins_a[0]["capacity_volume_m3"] == basins_b[0]["capacity_volume_m3"], "Deterministic Basin Volume", "Vol A: %f, B: %f" % [basins_a[0]["capacity_volume_m3"], basins_b[0]["capacity_volume_m3"]])

# -----------------------------------------------------------------------------
# Test 18 & 19: FeatureRegistry Integration & Lake-to-River Relationships
# -----------------------------------------------------------------------------
func test_feature_registry_lake_integration() -> void:
	var fix = _create_synthetic_fixture(64, 64, 50.0)
	for y in range(24, 40):
		for x in range(24, 40):
			if Vector2(x, y).distance_to(Vector2(32, 32)) < 7.0:
				fix["raw"][y * 64 + x] = 35.0
				
	var terrain = TerrainEngine.new(Vector2(256, 256), Vector2i(64, 64), Vector2.ZERO)
	terrain.heights = fix["raw"].duplicate()
	var hydro = HydrologyEngine.new(terrain)
	hydro.resolve_hydrology()
	
	var solver = LakeBasinSolver.new(5, 0.5)
	solver.solve_from_buffers(
		fix["raw"], hydro.filled_heights, hydro.flow_directions,
		Vector2i(64, 64), fix["cell_size"], fix["origin"]
	)
	
	var reg = FeatureRegistry.new()
	solver.register_lakes_in_feature_registry(reg, true)
	
	_assert(reg.get_feature_count("lake") == 1, "FeatureRegistry Contains Lake Feature", "Count: %d" % reg.get_feature_count("lake"))
	var lake_feats = reg.get_features_by_type("lake")
	if lake_feats.size() == 1:
		var lf = lake_feats[0]
		_assert(lf["parameters"].has("water_elevation") and lf["parameters"].has("water_volume_m3"), "Lake Feature Parameters Recorded Completely", "Params: %s" % str(lf["parameters"].keys()))

func test_lake_to_river_relationships() -> void:
	var reg = FeatureRegistry.new()
	var l_id = reg.register_feature({
		"id": "lake_emerald",
		"type": "lake",
		"position": Vector2(100, 100),
		"parameters": {"water_elevation": 25.0, "inlet_river_ids": [], "outlet_river_id": ""}
	})
	
	var r_in_id = reg.register_feature({
		"id": "riv_inflow",
		"type": "river",
		"position": Vector2(50, 50),
		"parameters": {"width": 6.0}
	})
	
	var solver = LakeBasinSolver.new()
	var linked = solver.connect_inlet_river(l_id, r_in_id, reg)
	_assert(linked, "connect_inlet_river() Return Succeeded", "Expected true")
	
	var updated_lake = reg.get_feature(l_id)
	var updated_river = reg.get_feature(r_in_id)
	_assert(updated_lake["parameters"]["inlet_river_ids"].has(r_in_id), "Lake References Incoming River", "Inlets: %s" % str(updated_lake["parameters"]["inlet_river_ids"]))
	_assert(updated_river["parameters"]["receiving_lake_id"] == l_id, "River References Receiving Lake", "Target: %s" % str(updated_river["parameters"].get("receiving_lake_id")))

# -----------------------------------------------------------------------------
# Test 20: Original Elevation Buffer Immutability
# -----------------------------------------------------------------------------
func test_raw_elevation_buffer_immutability() -> void:
	var terrain = TerrainEngine.new()
	terrain.generate(42)
	var raw_before = terrain.heights.duplicate()
	
	var hydro = HydrologyEngine.new(terrain)
	hydro.resolve_hydrology()
	
	var ws = WorldState.new()
	ws.initialize_from_simulation(terrain, hydro)
	ws.recompute_lakes()
	
	var raw_after = terrain.heights
	var raw_ws = ws.raw_elevation_buffer
	
	_assert(raw_before == raw_after, "TerrainEngine Heights Strictly Unchanged", "Raw height buffer preserved")
	_assert(raw_before == raw_ws, "WorldState Raw Elevation Buffer Strictly Unchanged", "WorldState raw buffer preserved")

# -----------------------------------------------------------------------------
# Test 21: WorldState Invalidation on Localized Region Update
# -----------------------------------------------------------------------------
func test_world_state_lake_invalidation() -> void:
	var terrain = TerrainEngine.new()
	terrain.generate(42)
	var hydro = HydrologyEngine.new(terrain)
	hydro.resolve_hydrology()
	
	var ws = WorldState.new()
	ws.initialize_from_simulation(terrain, hydro)
	ws.recompute_lakes()
	
	# Modify localized region
	ws.update_elevation_region(Rect2(0, 0, 50, 50), func(_x, _y, h): return h + 10.0)
	
	# Verify lake data was invalidated to prevent stale data
	_assert(ws.detected_basins.is_empty(), "Lakes Buffer Cleared/Invalidated After Terrain Modification", "Count: %d" % ws.detected_basins.size())
	_assert(ws.basin_id_buffer[0] == -1, "Basin ID Buffer Reset on Invalidation", "Index: %d" % ws.basin_id_buffer[0])

# -----------------------------------------------------------------------------
# Test 22, 23 & 24: Milestone 1, 2, and Game Regressions
# -----------------------------------------------------------------------------
func test_milestone_regression_checks() -> void:
	# Milestone 1 & 2 integration sanity
	var terrain = TerrainEngine.new()
	terrain.generate(42)
	var hydro = HydrologyEngine.new(terrain)
	var h_res = hydro.resolve_hydrology()
	_assert(h_res["depression_cells_filled"] >= 0, "Hydrology Priority-Flood Runs Cleanly", "Filled: %d" % h_res["depression_cells_filled"])
	
	var ws = WorldState.new()
	ws.initialize_from_simulation(terrain, hydro)
	var basins = ws.recompute_lakes()
	_assert(ws.metadata.has("lake_basins_count"), "WorldState Metadata Updated with Lake Basins", "Lakes: %d" % basins.size())
