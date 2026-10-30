# test_milestone_4.gd
# Comprehensive automated acceptance test suite for Milestone 4:
# Dirty-Region Chunk Updates, Non-Destructive World Integration, Transactional Safety & Player Stability.
extends SceneTree

const TerrainEngine = preload("res://TerrainEngine.gd")
const HydrologyEngine = preload("res://HydrologyEngine.gd")
const WorldState = preload("res://WorldState.gd")
const FeatureRegistry = preload("res://FeatureRegistry.gd")
const LakeBasinSolver = preload("res://LakeBasinSolver.gd")
const DirtyRegionTracker = preload("res://DirtyRegionTracker.gd")
const WorldEditManager = preload("res://WorldEditManager.gd")
const ChunkManagerClass = preload("res://ChunkManager.gd")

var total_assertions: int = 0
var passed_assertions: int = 0

func assert_true(condition: bool, test_name: String, detail: String = "") -> void:
	total_assertions += 1
	if condition:
		passed_assertions += 1
		print("[PASS] %s" % test_name)
	else:
		printerr("[FAIL] %s - Detail: %s" % [test_name, detail])

func _init() -> void:
	print("\n=================================================================")
	print("SUBLIMEGREENS — MILESTONE 4: DIRTY-REGION & WORLD INTEGRATION TEST SUITE")
	print("=================================================================\n")
	
	test_initial_chunk_loading_and_world_state()
	test_chunk_bounding_box_intersections()
	test_dirty_region_tracking_and_merging()
	test_transaction_rollback_safety()
	test_transaction_commit_and_dependency_cascade()
	test_localized_chunk_updates_non_destructive()
	test_player_preservation_outside_edit_bounds()
	test_player_collision_recovery_beneath_feet()
	test_multi_chunk_boundary_crossing()
	test_full_system_stability()
	
	print("\n=================================================================")
	if passed_assertions == total_assertions:
		print("ALL %d ACCEPTANCE TESTS PASSED SUCCESSFULLY!" % total_assertions)
		print("=================================================================\n")
		quit(0)
	else:
		printerr("FAILED: %d / %d assertions passed." % [passed_assertions, total_assertions])
		print("=================================================================\n")
		quit(1)

# -----------------------------------------------------------------------------
# 1. Initial Chunk Loading with WorldState
# -----------------------------------------------------------------------------
func test_initial_chunk_loading_and_world_state() -> void:
	var root = Node3D.new()
	get_root().add_child(root)
	
	var ws = WorldState.new(Vector2(1000.0, 1000.0), Vector2i(256, 256), Vector2(-500.0, -500.0), 42)
	# Setup base elevation 15.0m
	for i in range(ws.total_cells):
		ws.raw_elevation_buffer[i] = 15.0
	ws.recompute_hydrology()
	
	var cm = ChunkManagerClass.new()
	cm.chunk_scene = load("res://Chunk.tscn")
	cm.render_distance = 1 # 3x3 chunks = 9 chunks
	cm.chunk_size_x = 32
	cm.chunk_size_z = 32
	cm.overall_scale = 2.0
	cm.world_state = ws
	root.add_child(cm)
	cm._ready()
	
	assert_true(cm.active_chunks.size() == 9, "Initial Chunk Loading: 9 Chunks Spawned for Render Distance 1", "Active chunks count: %d" % cm.active_chunks.size())
	
	var center_chunk = cm.active_chunks.get(Vector2i(0, 0))
	assert_true(center_chunk != null, "Center Chunk (0,0) Loaded")
	
	if center_chunk:
		assert_true(center_chunk.world_state == ws, "Chunk References Authoritative WorldState")
		var mesh_inst: MeshInstance3D = center_chunk.mesh_instance
		assert_true(mesh_inst != null and mesh_inst.mesh != null, "Chunk Terrain Mesh Generated")
		
		# In world space, vertex height should be 15.0m. Local vertex.y = 15.0 / 2.0 = 7.5m
		var arrays = mesh_inst.mesh.surface_get_arrays(0)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var first_v = verts[0]
		assert_true(is_equal_approx(first_v.y * cm.overall_scale, 15.0), "Vertex Height Matches WorldState Elevation", "Got world y: %.2f, expected 15.0" % (first_v.y * cm.overall_scale))
		
		# Collision shape check
		var coll: CollisionShape3D = center_chunk.collision_shape
		assert_true(coll != null and coll.shape is ConcavePolygonShape3D, "Collision Shape Generated from Mesh Faces")
	
	root.queue_free()

# -----------------------------------------------------------------------------
# 2. Chunk Bounding Box and Intersection Calculations
# -----------------------------------------------------------------------------
func test_chunk_bounding_box_intersections() -> void:
	var tracker = DirtyRegionTracker.new()
	var eff_size = Vector2(64.0, 64.0) # 32 * 2.0
	
	# Edit fully contained within Chunk (0, 0) -> [0, 64] x [0, 64]
	var rect_inside = Rect2(10.0, 10.0, 20.0, 20.0)
	var chunks_inside = DirtyRegionTracker.calculate_intersecting_chunks(rect_inside, eff_size)
	assert_true(chunks_inside.size() == 1, "Single Chunk Intersection Count", "Count: %d" % chunks_inside.size())
	assert_true(chunks_inside[0] == Vector2i(0, 0), "Single Chunk Coordinate Matches (0,0)", "Got: %s" % str(chunks_inside))
	
	# Edit crossing boundary between Chunk (0, 0) and Chunk (1, 0)
	var rect_cross_x = Rect2(50.0, 20.0, 30.0, 20.0) # X from 50 to 80 (crosses 64)
	var chunks_cross_x = DirtyRegionTracker.calculate_intersecting_chunks(rect_cross_x, eff_size)
	assert_true(chunks_cross_x.size() == 2, "Two Chunks Intersected on X-Boundary", "Count: %d" % chunks_cross_x.size())
	assert_true(chunks_cross_x.has(Vector2i(0, 0)) and chunks_cross_x.has(Vector2i(1, 0)), "Boundary Coordinates are (0,0) and (1,0)", "Got: %s" % str(chunks_cross_x))
	
	# Edit spanning 4 adjacent chunk corners: (0,0), (1,0), (0,1), (1,1)
	var rect_4_corners = Rect2(50.0, 50.0, 25.0, 25.0) # X: 50..75, Z: 50..75
	var chunks_4 = DirtyRegionTracker.calculate_intersecting_chunks(rect_4_corners, eff_size)
	assert_true(chunks_4.size() == 4, "Four Adjacent Chunks Intersected at Corner Junction", "Count: %d" % chunks_4.size())
	assert_true(chunks_4.has(Vector2i(0, 0)) and chunks_4.has(Vector2i(1, 0)) and chunks_4.has(Vector2i(0, 1)) and chunks_4.has(Vector2i(1, 1)), "All 4 Corner Chunks Identified Accurately")

# -----------------------------------------------------------------------------
# 3. Dirty-Region Tracking and Consolidation
# -----------------------------------------------------------------------------
func test_dirty_region_tracking_and_merging() -> void:
	var tracker = DirtyRegionTracker.new()
	var ws = WorldState.new(Vector2(1000.0, 1000.0), Vector2i(256, 256), Vector2(-500.0, -500.0), 42)
	
	var r1 = tracker.mark_dirty(Rect2(0, 0, 40, 40), "Edit 1", ["terrain", "collision"], ws, Vector2(64, 64))
	assert_true(r1.revision == 1, "DirtyRegion Revision 1 Generated")
	assert_true(r1.has_category("terrain"), "DirtyRegion Contains 'terrain' Category")
	assert_true(r1.has_category("collision"), "DirtyRegion Contains 'collision' Category")
	assert_true(not r1.has_category("flora"), "DirtyRegion Does Not Contain Unset Category")
	
	# Add second overlapping region
	var r2 = tracker.mark_dirty(Rect2(30, 30, 40, 40), "Edit 2", ["hydrology", "lake"], ws, Vector2(64, 64))
	assert_true(r2.revision == 2, "DirtyRegion Revision 2 Generated")
	assert_true(r1.intersects(r2), "Regions Intersect Check")
	
	# Consolidate overlapping regions
	var consolidated = tracker.consolidate_pending_regions()
	assert_true(consolidated.size() == 1, "Overlapping Regions Consolidated into Single Region", "Consolidated count: %d" % consolidated.size())
	
	var merged = consolidated[0]
	assert_true(merged.world_bounds == Rect2(0, 0, 70, 70), "Merged World Bounds Spans Combined Bounding Box", "Bounds: %s" % str(merged.world_bounds))
	assert_true(merged.has_category("terrain") and merged.has_category("hydrology") and merged.has_category("lake"), "Merged Region Retains All Unique Categories")
	assert_true(merged.revision == 2, "Merged Region Preserves Highest Revision")

# -----------------------------------------------------------------------------
# 4. Transactional Safety and Snapshot Rollback
# -----------------------------------------------------------------------------
func test_transaction_rollback_safety() -> void:
	var root = Node3D.new()
	get_root().add_child(root)
	
	var ws = WorldState.new(Vector2(1000.0, 1000.0), Vector2i(256, 256), Vector2(-500.0, -500.0), 42)
	for i in range(ws.total_cells):
		ws.raw_elevation_buffer[i] = 20.0
	ws.recompute_hydrology()
	
	var edit_mgr = WorldEditManager.new()
	edit_mgr.world_state = ws
	root.add_child(edit_mgr)
	
	var edit_rect = Rect2(-50.0, -50.0, 100.0, 100.0)
	var tx_id = edit_mgr.begin_transaction("Test Brush with Rollback", edit_rect)
	assert_true(tx_id > 0, "Transaction Begun Successfully (tx_id > 0)")
	
	# Apply an extreme modification that we will roll back
	edit_mgr.apply_elevation_brush(Vector2(0, 0), 40.0, 50.0, "smooth", tx_id)
	
	# Check that candidate elevation is elevated
	var elevated_h = ws.get_elevation_at(0.0, 0.0)
	assert_true(elevated_h > 65.0, "Candidate Elevation Applied Before Commit", "Elevated h: %.2f" % elevated_h)
	
	# Execute rollback
	var rolled_back = edit_mgr.rollback_transaction(tx_id, "User Cancelled Edit")
	assert_true(rolled_back, "Rollback Execution Succeeded")
	
	# Verify that raw elevation is strictly restored to original 20.0m
	var restored_h = ws.get_elevation_at(0.0, 0.0)
	assert_true(is_equal_approx(restored_h, 20.0), "Elevation Strictly Restored to Pre-Transaction Value", "Restored h: %.4f" % restored_h)
	
	# Verify transaction record is cleared
	assert_true(not edit_mgr.active_transactions.has(tx_id), "Transaction Record Erased Following Rollback")
	
	root.queue_free()

# -----------------------------------------------------------------------------
# 5. Transaction Commit and Dependency Cascade
# -----------------------------------------------------------------------------
func test_transaction_commit_and_dependency_cascade() -> void:
	var root = Node3D.new()
	get_root().add_child(root)
	
	var ws = WorldState.new(Vector2(1000.0, 1000.0), Vector2i(256, 256), Vector2(-500.0, -500.0), 42)
	for i in range(ws.total_cells):
		ws.raw_elevation_buffer[i] = 10.0
	ws.recompute_hydrology()
	
	var edit_mgr = WorldEditManager.new()
	edit_mgr.world_state = ws
	root.add_child(edit_mgr)
	
	# Carve a genuine lake depression at (50, 50)
	var res = edit_mgr.apply_elevation_brush(Vector2(50.0, 50.0), 40.0, -12.0, "smooth", -1)
	assert_true(res.success, "Atomic Elevation Brush Succeeded")
	assert_true(res.tx_id > 0, "Transaction ID Generated and Committed")
	
	# Verify terrain is carved
	var center_h = ws.get_elevation_at(50.0, 50.0)
	assert_true(center_h < 0.0, "Center Carved Below Sea Level", "Center h: %.2f" % center_h)
	
	# Dependency Cascade 1: Conditioned elevation Priority-Flood filled the carved depression
	var cond_h = ws.get_conditioned_elevation_at(50.0, 50.0)
	assert_true(cond_h > center_h, "Hydrology Invalidation: Conditioned Elevation Preserves Drainage Surface", "Cond h: %.2f > Raw h: %.2f" % [cond_h, center_h])
	
	# Dependency Cascade 2: LakeBasinSolver detected the carved depression
	assert_true(ws.detected_basins.size() > 0, "Lake Basin Invalidation: Lake Detected in Carved Depression", "Detected basins count: %d" % ws.detected_basins.size())
	
	# Dependency Cascade 3: Lake depth query returns positive depth
	var depth = ws.get_lake_depth_at(50.0, 50.0)
	assert_true(depth > 5.0, "Authoritative Lake Depth Query Matches Carved Relief", "Lake depth: %.2fm" % depth)
	
	root.queue_free()

# -----------------------------------------------------------------------------
# 6. Localized Chunk Updates (Non-Destructive In-Place Rebuild)
# -----------------------------------------------------------------------------
func test_localized_chunk_updates_non_destructive() -> void:
	var root = Node3D.new()
	get_root().add_child(root)
	
	var ws = WorldState.new(Vector2(1000.0, 1000.0), Vector2i(256, 256), Vector2(-500.0, -500.0), 42)
	for i in range(ws.total_cells):
		ws.raw_elevation_buffer[i] = 10.0
	ws.recompute_hydrology()
	
	var cm = ChunkManagerClass.new()
	cm.chunk_scene = load("res://Chunk.tscn")
	cm.render_distance = 1 # 9 chunks: (-1..1, -1..1)
	cm.chunk_size_x = 32
	cm.chunk_size_z = 32
	cm.overall_scale = 2.0
	cm.world_state = ws
	root.add_child(cm)
	cm._ready()
	
	# Record Chunk Node instance IDs to prove they are NOT destroyed
	var target_chunk = cm.active_chunks[Vector2i(0, 0)]
	var target_inst_id = target_chunk.get_instance_id()
	var untouched_chunk = cm.active_chunks[Vector2i(-1, -1)]
	var untouched_inst_id = untouched_chunk.get_instance_id()
	
	var edit_mgr = cm.edit_manager
	assert_true(edit_mgr != null, "WorldEditManager Automatically Wired to ChunkManager")
	
	# Apply localized edit inside Chunk (0, 0) only: [0, 64] x [0, 64]
	var edit_res = edit_mgr.apply_elevation_brush(Vector2(32.0, 32.0), 15.0, 25.0, "smooth", -1)
	assert_true(edit_res.success, "Localized Edit Succeeded")
	
	# Verify that updated chunks only contains Chunk (0, 0)
	var updated_chunks: Array[Vector2i] = edit_res.updated_chunks
	assert_true(updated_chunks.has(Vector2i(0, 0)), "Target Chunk (0,0) Included in Update List")
	assert_true(not updated_chunks.has(Vector2i(-1, -1)), "Untouched Chunk (-1,-1) Excluded from Update List")
	
	# NON-DESTRUCTIVE PROOF: Chunk nodes were NOT destroyed or reallocated
	assert_true(is_instance_valid(target_chunk), "Target Chunk Still Valid Node")
	assert_true(target_chunk.get_instance_id() == target_inst_id, "Target Chunk Preserved Instance ID (Not Re-Instantiated)")
	assert_true(is_instance_valid(untouched_chunk), "Untouched Chunk Still Valid Node")
	assert_true(untouched_chunk.get_instance_id() == untouched_inst_id, "Untouched Chunk Preserved Instance ID")
	
	# Verify target chunk visual mesh updated to new elevation
	var mesh_arrays = target_chunk.mesh_instance.mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = mesh_arrays[Mesh.ARRAY_VERTEX]
	var max_v_y = -999.0
	for v in verts:
		if v.y > max_v_y: max_v_y = v.y
	assert_true(max_v_y * cm.overall_scale > 30.0, "Target Chunk Visual Mesh Reflected Raised Elevation", "Max world y: %.2f" % (max_v_y * cm.overall_scale))
	
	root.queue_free()

# -----------------------------------------------------------------------------
# 7. Player Preservation Outside Edit Footprint
# -----------------------------------------------------------------------------
func test_player_preservation_outside_edit_bounds() -> void:
	var root = Node3D.new()
	get_root().add_child(root)
	
	var ws = WorldState.new(Vector2(1000.0, 1000.0), Vector2i(256, 256), Vector2(-500.0, -500.0), 42)
	for i in range(ws.total_cells):
		ws.raw_elevation_buffer[i] = 10.0
	ws.recompute_hydrology()
	
	# Spawn Player at position (-100, 15, -100) with forward velocity
	var player = CharacterBody3D.new()
	player.position = Vector3(-100.0, 15.0, -100.0)
	player.velocity = Vector3(4.5, -2.0, 8.0)
	root.add_child(player)
	
	var cm = ChunkManagerClass.new()
	cm.player = player
	cm.world_state = ws
	cm.chunk_scene = load("res://Chunk.tscn")
	cm.render_distance = 1
	cm.overall_scale = 2.0
	root.add_child(cm)
	cm._ready()
	
	var original_pos = player.global_position if player.is_inside_tree() else player.position
	var original_vel = player.velocity
	
	# Apply edit far away in East quadrant (120, 120)
	var edit_res = cm.edit_manager.apply_elevation_brush(Vector2(120.0, 120.0), 30.0, 40.0, "smooth", -1)
	assert_true(edit_res.success, "Remote Edit Succeeded")
	
	# Verify player position and velocity are 100% UNTOUCHED
	var cur_pos = player.global_position if player.is_inside_tree() else player.position
	assert_true(cur_pos == original_pos, "Player Position Strictly Preserved During Remote Edit", "Got %s, expected %s" % [str(cur_pos), str(original_pos)])
	assert_true(player.velocity == original_vel, "Player Velocity Strictly Preserved During Remote Edit", "Got %s, expected %s" % [str(player.velocity), str(original_vel)])
	
	root.queue_free()

# -----------------------------------------------------------------------------
# 8. Explicit Collision Recovery Beneath Player
# -----------------------------------------------------------------------------
func test_player_collision_recovery_beneath_feet() -> void:
	var root = Node3D.new()
	get_root().add_child(root)
	
	var ws = WorldState.new(Vector2(1000.0, 1000.0), Vector2i(256, 256), Vector2(-500.0, -500.0), 42)
	for i in range(ws.total_cells):
		ws.raw_elevation_buffer[i] = 10.0
	ws.recompute_hydrology()
	
	# Player is standing at (0, 11.2, 0) on 10.0m terrain
	var player = CharacterBody3D.new()
	player.position = Vector3(0.0, 11.2, 0.0)
	player.velocity = Vector3(3.0, -5.0, 2.0)
	root.add_child(player)
	
	var cm = ChunkManagerClass.new()
	cm.player = player
	cm.world_state = ws
	cm.chunk_scene = load("res://Chunk.tscn")
	cm.render_distance = 1
	cm.overall_scale = 2.0
	root.add_child(cm)
	cm._ready()
	
	# Terrain directly beneath player is raised by 25 meters (from 10m to 35m)
	var edit_res = cm.edit_manager.apply_elevation_brush(Vector2(0.0, 0.0), 20.0, 25.0, "smooth", -1)
	assert_true(edit_res.success, "Edit Beneath Player Succeeded")
	
	var new_ground = ws.get_elevation_at(0.0, 0.0)
	assert_true(new_ground > 30.0, "Ground Elevated Beneath Player Footprint", "New ground: %.2f" % new_ground)
	
	# Collision recovery: Player vertical position should be raised safely above new ground
	var cur_player_pos = player.global_position if player.is_inside_tree() else player.position
	assert_true(cur_player_pos.y >= new_ground + 1.0, "Player Safely Elevated Above Rising Ground", "Player y: %.2fm, Ground: %.2fm" % [cur_player_pos.y, new_ground])
	
	# Player horizontal (X, Z) coordinates should be preserved (NOT arbitrarily teleported)
	assert_true(is_equal_approx(cur_player_pos.x, 0.0) and is_equal_approx(cur_player_pos.z, 0.0), "Player Horizontal Position (X, Z) Strictly Preserved During Vertical Recovery")
	
	# Downward velocity should be neutralized to prevent penetrating ground
	assert_true(player.velocity.y >= 0.0, "Player Downward Velocity Neutralized on Vertical Recovery")
	
	root.queue_free()

# -----------------------------------------------------------------------------
# 9. Multi-Chunk Boundary Crossing
# -----------------------------------------------------------------------------
func test_multi_chunk_boundary_crossing() -> void:
	var root = Node3D.new()
	get_root().add_child(root)
	
	var ws = WorldState.new(Vector2(1000.0, 1000.0), Vector2i(256, 256), Vector2(-500.0, -500.0), 42)
	for i in range(ws.total_cells):
		ws.raw_elevation_buffer[i] = 10.0
	ws.recompute_hydrology()
	
	var cm = ChunkManagerClass.new()
	cm.chunk_scene = load("res://Chunk.tscn")
	cm.render_distance = 1
	cm.overall_scale = 2.0 # Effective chunk size = 64m
	cm.world_state = ws
	root.add_child(cm)
	cm._ready()
	
	# Apply edit centered exactly at the 4-way corner junction (0.0, 0.0)
	# This intersects (-1, -1), (-1, 0), (0, -1), (0, 0)
	var edit_res = cm.edit_manager.apply_elevation_brush(Vector2(0.0, 0.0), 30.0, 20.0, "smooth", -1)
	assert_true(edit_res.success, "Corner Junction Edit Succeeded")
	
	var updated = edit_res.updated_chunks
	assert_true(updated.size() == 4, "All 4 Bordering Chunks Updated for Corner Edit", "Updated count: %d" % updated.size())
	assert_true(updated.has(Vector2i(-1, -1)) and updated.has(Vector2i(-1, 0)) and updated.has(Vector2i(0, -1)) and updated.has(Vector2i(0, 0)), "Boundary Chunks Contain All 4 Corners")
	
	root.queue_free()

# -----------------------------------------------------------------------------
# 10. Full System Stability and Invariants
# -----------------------------------------------------------------------------
func test_full_system_stability() -> void:
	var ws = WorldState.new(Vector2(1000.0, 1000.0), Vector2i(256, 256), Vector2(-500.0, -500.0), 42)
	for i in range(ws.total_cells):
		ws.raw_elevation_buffer[i] = 12.0
	ws.recompute_hydrology()
	
	var edit_mgr = WorldEditManager.new()
	edit_mgr.world_state = ws
	
	# 1. Validation rejection on NaN / Inf inside transaction region
	var tx_id = edit_mgr.begin_transaction("Invalid NaN Test", Rect2(0, 0, 50, 50))
	var center_grid = ws.world_to_grid(25.0, 25.0)
	var cell_idx = int(center_grid.y) * ws.grid_resolution.x + int(center_grid.x)
	ws.raw_elevation_buffer[cell_idx] = NAN
	var val_res = edit_mgr.validate_candidate_state(tx_id)
	assert_true(not val_res.valid, "Validation Correctly Rejects NaN Values")
	edit_mgr.rollback_transaction(tx_id, "Rejected NaN")
	assert_true(is_equal_approx(ws.raw_elevation_buffer[cell_idx], 12.0), "Rollback Clears NaN and Restores Original Height")
	
	# 2. Invariant: Conditioned elevation is always >= raw elevation
	edit_mgr.apply_elevation_brush(Vector2(100, 100), 50.0, 30.0, "smooth", -1)
	var all_ge = true
	for i in range(ws.total_cells):
		if ws.conditioned_elevation_buffer[i] < ws.raw_elevation_buffer[i] - 0.001:
			all_ge = false
			break
	assert_true(all_ge, "System Invariant: Conditioned Elevation >= Raw Elevation Across All Cells")
