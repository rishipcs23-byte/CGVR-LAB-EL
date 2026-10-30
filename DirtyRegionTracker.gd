# DirtyRegionTracker.gd
# Tracks localized bounding boxes, cell ranges, chunk coordinates, and change categories
# for non-destructive geographical updates in SublimeGreens Milestone 4.
class_name DirtyRegionTracker
extends RefCounted

const WorldState = preload("res://WorldState.gd")

## Represents a single invalidated region of the world.
class DirtyRegion extends RefCounted:
	var world_bounds: Rect2 = Rect2()
	var cell_range: Rect2i = Rect2i()
	var affected_chunk_coords: Array[Vector2i] = []
	var change_categories: Array[String] = [] # "terrain", "hydrology", "river", "lake", "flora", "collision"
	var reason: String = ""
	var revision: int = 0
	var timestamp: float = 0.0

	func _init(p_bounds: Rect2 = Rect2(), p_reason: String = "", p_rev: int = 0) -> void:
		world_bounds = p_bounds
		reason = p_reason
		revision = p_rev
		timestamp = Time.get_unix_time_from_system()

	func add_category(cat: String) -> void:
		if not change_categories.has(cat):
			change_categories.append(cat)

	func has_category(cat: String) -> bool:
		return change_categories.has(cat)

	func intersects(other: DirtyRegion) -> bool:
		return world_bounds.intersects(other.world_bounds)

	func merge_with(other: DirtyRegion) -> void:
		world_bounds = world_bounds.merge(other.world_bounds)
		cell_range = cell_range.merge(other.cell_range)
		for c in other.change_categories:
			add_category(c)
		for coord in other.affected_chunk_coords:
			if not affected_chunk_coords.has(coord):
				affected_chunk_coords.append(coord)
		if not other.reason.is_empty() and other.reason != reason:
			if reason.is_empty():
				reason = other.reason
			else:
				reason += "; " + other.reason
		revision = maxi(revision, other.revision)

	func contains_point(point: Vector2) -> bool:
		return world_bounds.has_point(point)

	func to_dict() -> Dictionary:
		var coords_arr = []
		for c in affected_chunk_coords:
			coords_arr.append([c.x, c.y])
		return {
			"world_bounds": {
				"position": [world_bounds.position.x, world_bounds.position.y],
				"size": [world_bounds.size.x, world_bounds.size.y]
			},
			"cell_range": {
				"position": [cell_range.position.x, cell_range.position.y],
				"size": [cell_range.size.x, cell_range.size.y]
			},
			"affected_chunk_coords": coords_arr,
			"change_categories": change_categories.duplicate(),
			"reason": reason,
			"revision": revision,
			"timestamp": timestamp
		}

# --- Tracker State ---
var current_revision: int = 0
var pending_regions: Array[DirtyRegion] = []
var history: Array[DirtyRegion] = []
var max_history: int = 50

## Creates a new DirtyRegion given world-space bounds and invalidation metadata.
func mark_dirty(world_bounds: Rect2, reason: String, categories: Array[String], world_state: WorldState = null, effective_chunk_size: Vector2 = Vector2(64.0, 64.0)) -> DirtyRegion:
	current_revision += 1
	var region = DirtyRegion.new(world_bounds, reason, current_revision)
	
	for cat in categories:
		region.add_category(cat)
		
	# Compute affected grid cells if WorldState is provided
	if world_state:
		var g_min = world_state.world_to_grid(world_bounds.position.x, world_bounds.position.y)
		var g_max = world_state.world_to_grid(world_bounds.end.x, world_bounds.end.y)
		var gx0 = clampi(int(floor(g_min.x)), 0, world_state.grid_resolution.x - 1)
		var gy0 = clampi(int(floor(g_min.y)), 0, world_state.grid_resolution.y - 1)
		var gx1 = clampi(int(ceil(g_max.x)), 0, world_state.grid_resolution.x - 1)
		var gy1 = clampi(int(ceil(g_max.y)), 0, world_state.grid_resolution.y - 1)
		region.cell_range = Rect2i(gx0, gy0, max(1, gx1 - gx0 + 1), max(1, gy1 - gy0 + 1))
	
	# Compute affected chunk coordinates
	region.affected_chunk_coords = calculate_intersecting_chunks(world_bounds, effective_chunk_size)
	
	pending_regions.append(region)
	return region

## Calculates all chunk coordinates that intersect the given world-space bounding box.
static func calculate_intersecting_chunks(world_bounds: Rect2, effective_chunk_size: Vector2) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	if effective_chunk_size.x <= 0.0 or effective_chunk_size.y <= 0.0:
		return result
		
	var min_cx = floori(world_bounds.position.x / effective_chunk_size.x)
	var min_cz = floori(world_bounds.position.y / effective_chunk_size.y)
	var max_cx = floori(world_bounds.end.x / effective_chunk_size.x)
	var max_cz = floori(world_bounds.end.y / effective_chunk_size.y)
	
	for cz in range(min_cz, max_cz + 1):
		for cx in range(min_cx, max_cx + 1):
			result.append(Vector2i(cx, cz))
			
	return result

## Consolidates and merges overlapping or contiguous pending dirty regions.
func consolidate_pending_regions() -> Array[DirtyRegion]:
	if pending_regions.is_empty():
		return []
		
	var merged: Array[DirtyRegion] = []
	
	for reg in pending_regions:
		var was_merged = false
		for m in merged:
			if m.intersects(reg):
				m.merge_with(reg)
				was_merged = true
				break
		if not was_merged:
			merged.append(reg)
			
	pending_regions.clear()
	
	for m in merged:
		history.append(m)
		if history.size() > max_history:
			history.pop_front()
			
	return merged

## Clears all pending regions.
func clear_pending() -> void:
	pending_regions.clear()

