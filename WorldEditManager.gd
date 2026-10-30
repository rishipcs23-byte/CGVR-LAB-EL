# WorldEditManager.gd
# Central coordinator for localized, non-destructive geographical modifications in SublimeGreens.
# Enforces transactional safety, snapshot rollback, dependency invalidation,
# and dirty-region notifications to ChunkManager.
class_name WorldEditManager
extends Node

const WorldState = preload("res://WorldState.gd")
const DirtyRegionTracker = preload("res://DirtyRegionTracker.gd")
const DirtyRegion = DirtyRegionTracker.DirtyRegion
const TerrainEngine = preload("res://TerrainEngine.gd")
const HydrologyEngine = preload("res://HydrologyEngine.gd")
const LakeBasinSolver = preload("res://LakeBasinSolver.gd")

signal edit_started(tx_id: int, description: String)
signal edit_committed(tx_id: int, dirty_region: RefCounted)
signal edit_rolled_back(tx_id: int, reason: String)

var world_state: WorldState = null
@export var chunk_manager: Node3D # ChunkManager

var tracker: DirtyRegionTracker = DirtyRegionTracker.new()
var active_transactions: Dictionary = {}
var next_tx_id: int = 1

func _ready() -> void:
	if not world_state and chunk_manager and "world_state" in chunk_manager and chunk_manager.world_state:
		world_state = chunk_manager.world_state

# -----------------------------------------------------------------------------
# Transaction Lifecycle Management
# -----------------------------------------------------------------------------

## Begins a reversible modification transaction.
## Snapshots affected raw elevation cells and feature state within proposed bounds.
func begin_transaction(description: String, proposed_bounds: Rect2) -> int:
	var tx_id = next_tx_id
	next_tx_id += 1
	
	if not world_state:
		printerr("WorldEditManager: Cannot begin transaction without authoritative WorldState!")
		return -1
		
	# Clamp proposed bounds to world boundaries
	var world_bounds = world_state.get_bounds_rect()
	var clamped_bounds = proposed_bounds.intersection(world_bounds)
	
	# Snapshot the affected grid cell range
	var g_min = world_state.world_to_grid(clamped_bounds.position.x, clamped_bounds.position.y)
	var g_max = world_state.world_to_grid(clamped_bounds.end.x, clamped_bounds.end.y)
	var gx0 = clampi(int(floor(g_min.x)), 0, world_state.grid_resolution.x - 1)
	var gy0 = clampi(int(floor(g_min.y)), 0, world_state.grid_resolution.y - 1)
	var gx1 = clampi(int(ceil(g_max.x)), 0, world_state.grid_resolution.x - 1)
	var gy1 = clampi(int(ceil(g_max.y)), 0, world_state.grid_resolution.y - 1)
	var cell_range = Rect2i(gx0, gy0, max(1, gx1 - gx0 + 1), max(1, gy1 - gy0 + 1))
	
	# Extract cell elevations for snapshot
	var saved_elevations = PackedFloat32Array()
	var w = world_state.grid_resolution.x
	saved_elevations.resize(cell_range.size.x * cell_range.size.y)
	var s_idx = 0
	for gy in range(cell_range.position.y, cell_range.end.y):
		var row_offset = gy * w
		for gx in range(cell_range.position.x, cell_range.end.x):
			saved_elevations[s_idx] = world_state.raw_elevation_buffer[row_offset + gx]
			s_idx += 1
			
	# Extract affected features snapshot from FeatureRegistry
	var saved_features = []
	if world_state.feature_registry:
		var feats = world_state.feature_registry.get_features_in_region(clamped_bounds)
		for f in feats:
			saved_features.append(f.duplicate(true))
			
	var tx = {
		"id": tx_id,
		"description": description,
		"bounds": clamped_bounds,
		"cell_range": cell_range,
		"saved_elevations": saved_elevations,
		"saved_features": saved_features,
		"saved_basins": world_state.detected_basins.duplicate(true),
		"status": "open",
		"timestamp": Time.get_unix_time_from_system()
	}
	
	active_transactions[tx_id] = tx
	edit_started.emit(tx_id, description)
	return tx_id

## Validates candidate world state following modifications.
## Checks for NaNs, Infs, and physically plausible elevation limits.
func validate_candidate_state(tx_id: int) -> Dictionary:
	if not active_transactions.has(tx_id):
		return {"valid": false, "error": "Transaction ID not found: %d" % tx_id}
		
	var tx = active_transactions[tx_id]
	var cell_range: Rect2i = tx.cell_range
	var w = world_state.grid_resolution.x
	
	for gy in range(cell_range.position.y, cell_range.end.y):
		var row_offset = gy * w
		for gx in range(cell_range.position.x, cell_range.end.x):
			var idx = row_offset + gx
			var h = world_state.raw_elevation_buffer[idx]
			if is_nan(h) or is_inf(h):
				return {"valid": false, "error": "Invalid elevation (NaN or Inf) detected at cell (%d, %d)" % [gx, gy]}
			if h < -300.0 or h > 3000.0:
				return {"valid": false, "error": "Elevation out of physical limits (%.1fm) at cell (%d, %d)" % [h, gx, gy]}
				
	return {"valid": true, "error": ""}

## Rolls back candidate modifications and restores the exact pre-edit snapshot.
func rollback_transaction(tx_id: int, reason: String = "") -> bool:
	if not active_transactions.has(tx_id):
		printerr("WorldEditManager: Cannot rollback non-existent transaction: ", tx_id)
		return false
		
	var tx = active_transactions[tx_id]
	var cell_range: Rect2i = tx.cell_range
	var saved_elevations: PackedFloat32Array = tx.saved_elevations
	var w = world_state.grid_resolution.x
	
	# Restore raw elevation cells
	var s_idx = 0
	for gy in range(cell_range.position.y, cell_range.end.y):
		var row_offset = gy * w
		for gx in range(cell_range.position.x, cell_range.end.x):
			world_state.raw_elevation_buffer[row_offset + gx] = saved_elevations[s_idx]
			s_idx += 1
			
	world_state._update_elevation_metrics()
	
	# Restore detected basins
	world_state.detected_basins = tx.saved_basins.duplicate(true)
	
	tx["status"] = "rolled_back"
	active_transactions.erase(tx_id)
	edit_rolled_back.emit(tx_id, reason)
	return true

## Commits a transaction after validation.
## Executes dependency cascade (hydrology, lakes, features, chunks, collision, flora)
## and recovers the player position if safe.
func commit_transaction(tx_id: int) -> Dictionary:
	if not active_transactions.has(tx_id):
		return {"success": false, "error": "Transaction ID not found: %d" % tx_id}
		
	var tx = active_transactions[tx_id]
	
	# 1. Validate candidate modifications
	var val_res = validate_candidate_state(tx_id)
	if not val_res.valid:
		var err = val_res.error
		rollback_transaction(tx_id, err)
		return {"success": false, "error": err}
		
	# 2. Dependency Cascade: Recalculate Hydrology & Conditioned Elevation
	world_state.recompute_hydrology()
	
	# 3. Dependency Cascade: Recalculate Lake Basins
	world_state.recompute_lakes({
		"min_basin_area_cells": 10,
		"min_basin_depth_m": 0.5,
		"default_fill_ratio": 1.0,
		"register_features": true,
		"connect_rivers": true
	})
	
	# 4. Compute effective chunk size for chunk intersecting queries
	var eff_chunk_size = Vector2(64.0, 64.0)
	if chunk_manager and "effective_chunk_size_x" in chunk_manager:
		eff_chunk_size = Vector2(chunk_manager.effective_chunk_size_x, chunk_manager.effective_chunk_size_z)
		
	# 5. Create authoritative DirtyRegion with dependency categories
	var dirty = tracker.mark_dirty(
		tx.bounds,
		tx.description,
		["terrain", "hydrology", "river", "lake", "flora", "collision"],
		world_state,
		eff_chunk_size
	)
	
	# 6. Apply localized chunk updates without full world destruction
	var updated_chunks: Array[Vector2i] = []
	if chunk_manager and chunk_manager.has_method("update_dirty_region"):
		updated_chunks = chunk_manager.update_dirty_region(dirty)
	elif chunk_manager and "active_chunks" in chunk_manager:
		# Fallback direct loop over active chunks
		for coord in dirty.affected_chunk_coords:
			if chunk_manager.active_chunks.has(coord):
				var ch = chunk_manager.active_chunks[coord]
				if is_instance_valid(ch) and ch.has_method("update_chunk_from_world_state"):
					ch.update_chunk_from_world_state(world_state, dirty.change_categories)
					updated_chunks.append(coord)
					
	# 7. Player safety & collision recovery
	if chunk_manager and chunk_manager.has_method("check_and_recover_player"):
		chunk_manager.check_and_recover_player(tx.bounds)
	elif chunk_manager and "player" in chunk_manager and is_instance_valid(chunk_manager.player):
		_handle_player_collision_recovery(chunk_manager.player, tx.bounds)
		
	tx["status"] = "committed"
	active_transactions.erase(tx_id)
	edit_committed.emit(tx_id, dirty)
	
	return {
		"success": true,
		"tx_id": tx_id,
		"dirty_region": dirty,
		"affected_chunks": dirty.affected_chunk_coords,
		"updated_chunks": updated_chunks
	}

# -----------------------------------------------------------------------------
# Geographical Editing Operations
# -----------------------------------------------------------------------------

## Applies a radial elevation brush (e.g. raising or lowering terrain).
## If tx_id is -1, creates, validates, and commits an atomic transaction automatically.
func apply_elevation_brush(center: Vector2, radius: float, height_delta: float, profile: String = "smooth", tx_id: int = -1) -> Dictionary:
	if radius <= 0.0:
		return {"success": false, "error": "Brush radius must be positive"}
		
	var auto_commit = (tx_id == -1)
	var edit_bounds = Rect2(center.x - radius, center.y - radius, radius * 2.0, radius * 2.0)
	
	if auto_commit:
		tx_id = begin_transaction("Elevation Brush (r=%.0fm, dh=%.1fm)" % [radius, height_delta], edit_bounds)
		if tx_id == -1:
			return {"success": false, "error": "Failed to initiate transaction"}
			
	var g_min = world_state.world_to_grid(edit_bounds.position.x, edit_bounds.position.y)
	var g_max = world_state.world_to_grid(edit_bounds.end.x, edit_bounds.end.y)
	var gx0 = clampi(int(floor(g_min.x)), 0, world_state.grid_resolution.x - 1)
	var gy0 = clampi(int(floor(g_min.y)), 0, world_state.grid_resolution.y - 1)
	var gx1 = clampi(int(ceil(g_max.x)), 0, world_state.grid_resolution.x - 1)
	var gy1 = clampi(int(ceil(g_max.y)), 0, world_state.grid_resolution.y - 1)
	
	var w = world_state.grid_resolution.x
	for gy in range(gy0, gy1 + 1):
		var row_offset = gy * w
		for gx in range(gx0, gx1 + 1):
			var wpos = world_state.grid_to_world(float(gx), float(gy))
			var dist = wpos.distance_to(center)
			if dist <= radius:
				var t = dist / radius
				var weight: float = 0.0
				match profile:
					"smooth":
						weight = 0.5 * (1.0 + cos(t * PI))
					"linear":
						weight = 1.0 - t
					"gaussian":
						weight = exp(-4.0 * t * t)
					"plateau":
						weight = 1.0 if t < 0.7 else (1.0 - (t - 0.7) / 0.3)
					_:
						weight = 0.5 * (1.0 + cos(t * PI))
				var idx = row_offset + gx
				world_state.raw_elevation_buffer[idx] += height_delta * weight
				
	world_state._update_elevation_metrics()
	
	if auto_commit:
		return commit_transaction(tx_id)
	return {"success": true, "tx_id": tx_id}

## Flattens terrain within a radius to a specified target elevation.
func apply_elevation_flatten(center: Vector2, radius: float, target_elevation: float, blend_margin: float = 10.0, tx_id: int = -1) -> Dictionary:
	if radius <= 0.0:
		return {"success": false, "error": "Flatten radius must be positive"}
		
	var total_radius = radius + blend_margin
	var auto_commit = (tx_id == -1)
	var edit_bounds = Rect2(center.x - total_radius, center.y - total_radius, total_radius * 2.0, total_radius * 2.0)
	
	if auto_commit:
		tx_id = begin_transaction("Flatten Region (r=%.0fm, target=%.1fm)" % [radius, target_elevation], edit_bounds)
		if tx_id == -1:
			return {"success": false, "error": "Failed to initiate transaction"}
			
	var g_min = world_state.world_to_grid(edit_bounds.position.x, edit_bounds.position.y)
	var g_max = world_state.world_to_grid(edit_bounds.end.x, edit_bounds.end.y)
	var gx0 = clampi(int(floor(g_min.x)), 0, world_state.grid_resolution.x - 1)
	var gy0 = clampi(int(floor(g_min.y)), 0, world_state.grid_resolution.y - 1)
	var gx1 = clampi(int(ceil(g_max.x)), 0, world_state.grid_resolution.x - 1)
	var gy1 = clampi(int(ceil(g_max.y)), 0, world_state.grid_resolution.y - 1)
	
	var w = world_state.grid_resolution.x
	for gy in range(gy0, gy1 + 1):
		var row_offset = gy * w
		for gx in range(gx0, gx1 + 1):
			var wpos = world_state.grid_to_world(float(gx), float(gy))
			var dist = wpos.distance_to(center)
			if dist <= total_radius:
				var idx = row_offset + gx
				var current_h = world_state.raw_elevation_buffer[idx]
				if dist <= radius:
					world_state.raw_elevation_buffer[idx] = target_elevation
				else:
					var blend_t = (dist - radius) / max(0.001, blend_margin)
					var weight = 0.5 * (1.0 + cos(blend_t * PI))
					world_state.raw_elevation_buffer[idx] = lerpf(current_h, target_elevation, weight)
					
	world_state._update_elevation_metrics()
	
	if auto_commit:
		return commit_transaction(tx_id)
	return {"success": true, "tx_id": tx_id}

## Applies a custom mathematical modification callable over a specified rectangular region.
func apply_custom_brush(region_rect: Rect2, modifier: Callable, description: String = "Custom Brush", tx_id: int = -1) -> Dictionary:
	var auto_commit = (tx_id == -1)
	if auto_commit:
		tx_id = begin_transaction(description, region_rect)
		if tx_id == -1:
			return {"success": false, "error": "Failed to initiate transaction"}
			
	var g_min = world_state.world_to_grid(region_rect.position.x, region_rect.position.y)
	var g_max = world_state.world_to_grid(region_rect.end.x, region_rect.end.y)
	var gx0 = clampi(int(floor(g_min.x)), 0, world_state.grid_resolution.x - 1)
	var gy0 = clampi(int(floor(g_min.y)), 0, world_state.grid_resolution.y - 1)
	var gx1 = clampi(int(ceil(g_max.x)), 0, world_state.grid_resolution.x - 1)
	var gy1 = clampi(int(ceil(g_max.y)), 0, world_state.grid_resolution.y - 1)
	
	var w = world_state.grid_resolution.x
	for gy in range(gy0, gy1 + 1):
		var row_offset = gy * w
		for gx in range(gx0, gx1 + 1):
			var idx = row_offset + gx
			var wpos = world_state.grid_to_world(float(gx), float(gy))
			var cur_h = world_state.raw_elevation_buffer[idx]
			world_state.raw_elevation_buffer[idx] = float(modifier.call(wpos.x, wpos.y, cur_h))
			
	world_state._update_elevation_metrics()
	
	if auto_commit:
		return commit_transaction(tx_id)
	return {"success": true, "tx_id": tx_id}

# -----------------------------------------------------------------------------
# Player Collision Recovery
# -----------------------------------------------------------------------------

## Checks if the player is standing inside the modified region and recovers their elevation
## if the terrain has moved beneath them.
func _handle_player_collision_recovery(p_player: CharacterBody3D, dirty_bounds: Rect2) -> bool:
	if not is_instance_valid(p_player) or not world_state:
		return false
		
	var player_pos = p_player.global_position if p_player.is_inside_tree() else p_player.position
	var p2d = Vector2(player_pos.x, player_pos.z)
	
	if not dirty_bounds.has_point(p2d):
		return false # Player is outside the modified region; no recovery needed
		
	var ground_h = world_state.get_elevation_at(player_pos.x, player_pos.z)
	var clearance = 1.2 # Height offset above new ground surface
	
	# If ground has risen above player or player is embedded in geometry
	if player_pos.y < ground_h + clearance:
		player_pos.y = ground_h + clearance
		if p_player.is_inside_tree():
			p_player.global_position = player_pos
		else:
			p_player.position = player_pos
		# Zero out downward velocity so player doesn't instantly snap/fall
		if p_player.velocity.y < 0.0:
			p_player.velocity.y = 0.0
		return true
		
	return false
