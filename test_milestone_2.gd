# test_milestone_2.gd
# Headless acceptance test suite for Milestone 2: WorldState & Feature Registry.
# Run with: godot --headless -s res://test_milestone_2.gd
extends SceneTree

const TerrainEngine = preload("res://TerrainEngine.gd")
const HydrologyEngine = preload("res://HydrologyEngine.gd")
const WorldState = preload("res://WorldState.gd")
const FeatureRegistry = preload("res://FeatureRegistry.gd")

var passed_count: int = 0
var failed_count: int = 0

func _init() -> void:
	print("\n=================================================================")
	print("SUBLIMEGREENS — MILESTONE 2: WORLDSTATE & FEATURE REGISTRY TEST SUITE")
	print("=================================================================\n")
	
	test_world_state_initialization()
	test_world_state_simulation_ingestion()
	test_raw_vs_conditioned_elevation_invariant()
	test_elevation_sampling_consistency()
	test_hydrology_queries()
	test_coordinate_transforms_and_bounds()
	test_localized_region_modification()
	test_feature_registry_crud_and_id_generation()
	test_feature_registry_spatial_queries()
	test_feature_registry_serialization()
	test_feature_registry_signal_emission()
	
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
# Test 1: WorldState Initialization
# -----------------------------------------------------------------------------
func test_world_state_initialization() -> void:
	var ws = WorldState.new(Vector2(1000.0, 1000.0), Vector2i(256, 256), Vector2(-500.0, -500.0), 123)
	_assert(ws.world_size == Vector2(1000.0, 1000.0), "WorldState World Size", "Expected 1000x1000, got %s" % str(ws.world_size))
	_assert(ws.grid_resolution == Vector2i(256, 256), "WorldState Grid Resolution", "Expected 256x256, got %s" % str(ws.grid_resolution))
	_assert(ws.total_cells == 65536, "WorldState Total Cells", "Expected 65536, got %d" % ws.total_cells)
	_assert(ws.raw_elevation_buffer.size() == 65536, "Raw Elevation Buffer Allocation", "Size: %d" % ws.raw_elevation_buffer.size())
	_assert(ws.conditioned_elevation_buffer.size() == 65536, "Conditioned Elevation Buffer Allocation", "Size: %d" % ws.conditioned_elevation_buffer.size())
	_assert(ws.flow_direction_buffer.size() == 65536, "Flow Direction Buffer Allocation", "Size: %d" % ws.flow_direction_buffer.size())
	_assert(ws.flow_accumulation_buffer.size() == 65536, "Flow Accumulation Buffer Allocation", "Size: %d" % ws.flow_accumulation_buffer.size())
	_assert(ws.feature_registry != null, "FeatureRegistry Ownership", "WorldState must own a FeatureRegistry instance")

# -----------------------------------------------------------------------------
# Test 2: Simulation Ingestion
# -----------------------------------------------------------------------------
func test_world_state_simulation_ingestion() -> void:
	var terrain = TerrainEngine.new(Vector2(1000.0, 1000.0), Vector2i(256, 256), Vector2(-500.0, -500.0))
	terrain.generate(42, {
		"mountain_peaks": [{
			"center": Vector2(-200.0, -250.0),
			"peak_height": 130.0,
			"radius": 220.0
		}]
	})
	
	var hydro = HydrologyEngine.new(terrain)
	hydro.resolve_hydrology()
	
	var ws = WorldState.new()
	ws.initialize_from_simulation(terrain, hydro, {"test_run": true})
	
	_assert(ws.raw_elevation_buffer.size() == 65536, "Ingested Raw Buffer Size", "Expected 65536")
	_assert(ws.max_raw_elevation > 100.0, "Ingested Mountain Peak Elevation", "Max elevation: %.1fm" % ws.max_raw_elevation)
	_assert(ws.max_flow_accumulation > 1000.0, "Ingested River Channel Flow Accumulation", "Max acc: %.0f" % ws.max_flow_accumulation)
	_assert(ws.metadata.get("test_run") == true, "Metadata Preservation", "Metadata missing test_run")

# -----------------------------------------------------------------------------
# Test 3: Raw vs Conditioned Invariant
# -----------------------------------------------------------------------------
func test_raw_vs_conditioned_elevation_invariant() -> void:
	var terrain = TerrainEngine.new()
	terrain.generate(42)
	# Inject artificial depression
	terrain.set_height_at_cell(100, 100, terrain.get_height_at_cell(100, 100) - 15.0)
	
	var hydro = HydrologyEngine.new(terrain)
	hydro.resolve_hydrology()
	
	var ws = WorldState.new()
	ws.initialize_from_simulation(terrain, hydro)
	
	var all_cond_ge_raw = true
	var depression_detected = false
	var max_diff = 0.0
	
	for i in range(ws.total_cells):
		var raw_h = ws.raw_elevation_buffer[i]
		var cond_h = ws.conditioned_elevation_buffer[i]
		
		# Conditioned elevation must NEVER be lower than raw elevation (within floating tolerance)
		if cond_h < raw_h - 0.001:
			all_cond_ge_raw = false
			
		var diff = cond_h - raw_h
		if diff > 1.0:
			depression_detected = true
			if diff > max_diff: max_diff = diff
			
	_assert(all_cond_ge_raw, "Invariant: Conditioned Elevation >= Raw Elevation for All Cells", "Conditioned surface must never drop below raw topography")
	_assert(depression_detected, "Depression Separation Verified (Raw Never Overwritten)", "Max depression depth: %.2fm" % max_diff)

# -----------------------------------------------------------------------------
# Test 4: Elevation Sampling Consistency
# -----------------------------------------------------------------------------
func test_elevation_sampling_consistency() -> void:
	var terrain = TerrainEngine.new()
	terrain.generate(42)
	var hydro = HydrologyEngine.new(terrain)
	hydro.resolve_hydrology()
	
	var ws = WorldState.new()
	ws.initialize_from_simulation(terrain, hydro)
	
	# Sample exact grid points
	var exact_match = true
	for gy in [20, 80, 128, 210]:
		for gx in [30, 95, 160, 225]:
			var raw_cell = ws.get_cell_elevation(gx, gy, false)
			var wpos = ws.grid_to_world(float(gx), float(gy))
			var sampled_raw = ws.get_elevation_at(wpos.x, wpos.y)
			if abs(raw_cell - sampled_raw) > 0.0001:
				exact_match = false
				
	_assert(exact_match, "Continuous Bilinear Sampling Exactness on Grid Nodes", "Sampled values must match cell values exactly")
	
	# Slope and normal calculation
	var slope_info = ws.get_slope_and_normal(-200.0, -250.0) # Near summit
	_assert(slope_info.has("normal") and slope_info["normal"].is_normalized(), "Normal Vector Calculation Normalized", "Normal: %s" % str(slope_info["normal"]))
	_assert(slope_info["slope_angle_deg"] >= 0.0 and slope_info["slope_angle_deg"] <= 90.0, "Slope Angle Plausibility", "Slope: %.1f deg" % slope_info["slope_angle_deg"])

# -----------------------------------------------------------------------------
# Test 5: Hydrology Queries (Flow Direction & Accumulation)
# -----------------------------------------------------------------------------
func test_hydrology_queries() -> void:
	var terrain = TerrainEngine.new()
	terrain.generate(42)
	var hydro = HydrologyEngine.new(terrain)
	hydro.resolve_hydrology()
	
	var ws = WorldState.new()
	ws.initialize_from_simulation(terrain, hydro)
	
	# Boundary cell query must be OUTLET (-1)
	var dir_at_border = ws.get_flow_direction_at(-500.0, 0.0)
	_assert(dir_at_border == HydrologyEngine.OUTLET, "Perimeter World Query Yields OUTLET", "Direction: %d" % dir_at_border)
	
	# Accumulation query must be >= 1.0 everywhere
	var acc_center = ws.get_flow_accumulation_at(0.0, 0.0)
	_assert(acc_center >= 1.0, "Flow Accumulation World Query >= 1.0", "Acc: %.2f" % acc_center)

# -----------------------------------------------------------------------------
# Test 6: Coordinate Transforms & Bounds Checking
# -----------------------------------------------------------------------------
func test_coordinate_transforms_and_bounds() -> void:
	var ws = WorldState.new(Vector2(1000.0, 1000.0), Vector2i(256, 256), Vector2(-500.0, -500.0))
	
	# Roundtrip test
	var original_wpos = Vector2(-234.5, 345.6)
	var grid_pos = ws.world_to_grid(original_wpos.x, original_wpos.y)
	var roundtrip_wpos = ws.grid_to_world(grid_pos.x, grid_pos.y)
	var roundtrip_err = (original_wpos - roundtrip_wpos).length()
	_assert(roundtrip_err < 0.001, "World-to-Grid Roundtrip Precision", "Error: %f" % roundtrip_err)
	
	# Bounds checking
	_assert(ws.is_in_bounds(0.0, 0.0), "In-Bounds Center Coordinate", "Expected true for (0, 0)")
	_assert(ws.is_in_bounds(-500.0, 500.0), "In-Bounds Corner Coordinate", "Expected true for (-500, 500)")
	_assert(!ws.is_in_bounds(-501.0, 0.0), "Out-of-Bounds West Boundary", "Expected false for (-501, 0)")
	_assert(!ws.is_in_bounds(0.0, 501.0), "Out-of-Bounds South Boundary", "Expected false for (0, 501)")

# -----------------------------------------------------------------------------
# Test 7: Localized Region Modification
# -----------------------------------------------------------------------------
func test_localized_region_modification() -> void:
	var terrain = TerrainEngine.new()
	terrain.generate(42)
	var hydro = HydrologyEngine.new(terrain)
	hydro.resolve_hydrology()
	
	var ws = WorldState.new()
	ws.initialize_from_simulation(terrain, hydro)
	
	# Target localized region: 100m x 100m box around (100, 100)
	var target_box = Rect2(100.0, 100.0, 100.0, 100.0)
	var old_outside_h = ws.get_elevation_at(-200.0, -200.0)
	
	var modified_cells = ws.update_elevation_region(target_box, func(_wx, _wz, cur_h):
		return cur_h + 30.0 # Raise plateau by 30m
	)
	
	_assert(modified_cells > 0, "Localized Elevation Modification Cell Count", "Modified cells: %d" % modified_cells)
	
	# Check inside region was raised
	var new_inside_h = ws.get_elevation_at(150.0, 150.0)
	var old_inside_approx = terrain.sample_height(150.0, 150.0)
	_assert(abs(new_inside_h - (old_inside_approx + 30.0)) < 0.5, "Region Inside Height Modified Appropriately", "Expected ~%.1f, got %.1f" % [old_inside_approx + 30.0, new_inside_h])
	
	# Check outside region was untouched
	var new_outside_h = ws.get_elevation_at(-200.0, -200.0)
	_assert(abs(new_outside_h - old_outside_h) < 0.001, "Outside Region Strictly Preserved", "Old: %f, New: %f" % [old_outside_h, new_outside_h])

# -----------------------------------------------------------------------------
# Test 8: FeatureRegistry CRUD & ID Generation
# -----------------------------------------------------------------------------
func test_feature_registry_crud_and_id_generation() -> void:
	var reg = FeatureRegistry.new(100.0)
	
	# Register Mountain
	var m_id = reg.register_feature({
		"type": "mountain",
		"position": Vector2(-220.0, -260.0),
		"parameters": {"peak_height": 140.0, "radius": 200.0}
	})
	_assert(m_id.begins_with("mtn_"), "Mountain ID Prefix Generation", "ID: %s" % m_id)
	_assert(reg.has_feature(m_id), "Feature Existence Check", "ID must exist in registry")
	
	# Register River
	var r_id = reg.register_feature({
		"id": "river_crystal",
		"type": "river",
		"position": Vector2(-150.0, -200.0),
		"parameters": {"width": 8.0, "depth": 3.0, "points": [Vector2(-150, -200), Vector2(-100, 0), Vector2(0, 300)]}
	})
	_assert(r_id == "river_crystal", "Explicit Feature ID Preservation", "ID: %s" % r_id)
	
	# Register Lake
	var l_id = reg.register_feature({
		"type": "lake",
		"position": Vector2(50.0, 80.0),
		"parameters": {"radius": 45.0, "water_level": 4.5}
	})
	_assert(l_id.begins_with("lak_"), "Lake ID Prefix Generation", "ID: %s" % l_id)
	
	# Register Tree
	var t_id = reg.register_feature({
		"type": "tree",
		"position": Vector2(10.0, 15.0),
		"parameters": {"species": "oak", "height": 12.0}
	})
	_assert(t_id.begins_with("tre_"), "Tree ID Prefix Generation", "ID: %s" % t_id)
	
	# Counts by type
	_assert(reg.get_feature_count("mountain") == 1, "Count Mountains", "Count: %d" % reg.get_feature_count("mountain"))
	_assert(reg.get_feature_count("river") == 1, "Count Rivers", "Count: %d" % reg.get_feature_count("river"))
	_assert(reg.get_feature_count("lake") == 1, "Count Lakes", "Count: %d" % reg.get_feature_count("lake"))
	_assert(reg.get_feature_count("tree") == 1, "Count Trees", "Count: %d" % reg.get_feature_count("tree"))
	_assert(reg.get_feature_count() == 4, "Total Registered Features", "Count: %d" % reg.get_feature_count())
	
	# Update feature
	var update_ok = reg.update_feature(m_id, {"peak_height": 180.0})
	_assert(update_ok, "Update Feature Parameters Return", "Expected true")
	_assert(reg.get_feature(m_id)["parameters"]["peak_height"] == 180.0, "Updated Feature Value Verification", "Height: %s" % str(reg.get_feature(m_id)["parameters"]["peak_height"]))
	_assert(reg.get_feature(m_id)["status"] == FeatureRegistry.STATUS_MODIFIED, "Feature Status Transition to Modified", "Status: %s" % reg.get_feature(m_id)["status"])
	
	# Unregister feature
	var unreg_ok = reg.unregister_feature(t_id)
	_assert(unreg_ok, "Unregister Feature Return", "Expected true")
	_assert(!reg.has_feature(t_id), "Unregistered Feature No Longer Exists", "Expected false")
	_assert(reg.get_feature_count() == 3, "Feature Count After Unregistration", "Count: %d" % reg.get_feature_count())

# -----------------------------------------------------------------------------
# Test 9: Spatial Range Queries
# -----------------------------------------------------------------------------
func test_feature_registry_spatial_queries() -> void:
	var reg = FeatureRegistry.new(100.0)
	
	# Place 3 trees in different spatial sectors
	reg.register_feature({"id": "tree_north", "type": "tree", "position": Vector2(0.0, -300.0), "parameters": {"scale": 2.0}})
	reg.register_feature({"id": "tree_center", "type": "tree", "position": Vector2(0.0, 0.0), "parameters": {"scale": 2.0}})
	reg.register_feature({"id": "tree_south", "type": "tree", "position": Vector2(0.0, 300.0), "parameters": {"scale": 2.0}})
	
	# Query box around center: [-50, -50, 100, 100]
	var center_hits = reg.get_features_in_region(Rect2(-50.0, -50.0, 100.0, 100.0))
	_assert(center_hits.size() == 1, "Spatial Query Hit Count for Center Sector", "Hits: %d" % center_hits.size())
	if center_hits.size() == 1:
		_assert(center_hits[0]["id"] == "tree_center", "Spatial Query Matched Correct Center Feature", "Found: %s" % center_hits[0]["id"])
		
	# Query box covering whole world
	var all_hits = reg.get_features_in_region(Rect2(-500.0, -500.0, 1000.0, 1000.0))
	_assert(all_hits.size() == 3, "Global Spatial Query Returns All Features", "Hits: %d" % all_hits.size())
	
	# Query with type filter
	reg.register_feature({"id": "mtn_center", "type": "mountain", "position": Vector2(10.0, 10.0), "parameters": {"radius": 80.0}})
	var tree_only_hits = reg.get_features_in_region(Rect2(-100.0, -100.0, 200.0, 200.0), "tree")
	_assert(tree_only_hits.size() == 1 and tree_only_hits[0]["id"] == "tree_center", "Spatial Query Type Filtering", "Expected 1 tree, got %d" % tree_only_hits.size())

# -----------------------------------------------------------------------------
# Test 10: Serialization & Deserialization
# -----------------------------------------------------------------------------
func test_feature_registry_serialization() -> void:
	var reg_a = FeatureRegistry.new(100.0)
	reg_a.register_feature({"id": "m1", "type": "mountain", "position": Vector2(-100, -150), "parameters": {"peak_height": 120.0, "radius": 150.0}})
	reg_a.register_feature({"id": "r1", "type": "river", "position": Vector2(0, 0), "parameters": {"width": 10.0, "points": [Vector2(0, 0), Vector2(50, 50)]}})
	
	var serialized = reg_a.to_dict()
	_assert(serialized.has("features") and serialized["features"].size() == 2, "Serialization Output Structure", "Size: %d" % serialized["features"].size())
	
	var reg_b = FeatureRegistry.new()
	reg_b.from_dict(serialized)
	
	_assert(reg_b.get_feature_count() == 2, "Deserialized Registry Feature Count", "Count: %d" % reg_b.get_feature_count())
	_assert(reg_b.has_feature("m1") and reg_b.has_feature("r1"), "Deserialized Features Preserved IDs", "Has m1: %s, Has r1: %s" % [str(reg_b.has_feature("m1")), str(reg_b.has_feature("r1"))])
	_assert(reg_b.get_feature("m1")["parameters"]["peak_height"] == 120.0, "Deserialized Feature Parameters Exact Match", "Height: %s" % str(reg_b.get_feature("m1")["parameters"]["peak_height"]))

# -----------------------------------------------------------------------------
# Test 11: Signal Emissions
# -----------------------------------------------------------------------------
func test_feature_registry_signal_emission() -> void:
	var reg = FeatureRegistry.new()
	var sig_state = {
		"registered": false,
		"updated": false,
		"removed": false
	}
	
	reg.feature_registered.connect(func(_id, _type): sig_state["registered"] = true)
	reg.feature_updated.connect(func(_id): sig_state["updated"] = true)
	reg.feature_removed.connect(func(_id): sig_state["removed"] = true)
	
	var fid = reg.register_feature({"type": "tree", "position": Vector2(5, 5)})
	_assert(sig_state["registered"], "Signal: feature_registered", "Expected signal emission")
	
	reg.update_feature(fid, {"scale": 3.0})
	_assert(sig_state["updated"], "Signal: feature_updated", "Expected signal emission")
	
	reg.unregister_feature(fid)
	_assert(sig_state["removed"], "Signal: feature_removed", "Expected signal emission")
