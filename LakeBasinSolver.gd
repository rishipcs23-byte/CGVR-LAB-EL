# LakeBasinSolver.gd
# Deterministic lake basin, depression dynamics, and spillway solver for SublimeGreens Milestone 3.
# Identifies genuine terrain depressions, calculates equilibrium lake levels,
# extracts polygon shorelines, and connects spillway saddle outlets to downstream river networks.
class_name LakeBasinSolver
extends RefCounted

const TerrainEngine = preload("res://TerrainEngine.gd")
const HydrologyEngine = preload("res://HydrologyEngine.gd")
const FeatureRegistry = preload("res://FeatureRegistry.gd")

# 8-neighbor offsets
const D8_OFFSETS: Array[Vector2i] = [
	Vector2i(0, -1),  # 0: North
	Vector2i(1, -1),  # 1: North-East
	Vector2i(1, 0),   # 2: East
	Vector2i(1, 1),   # 3: South-East
	Vector2i(0, 1),   # 4: South
	Vector2i(-1, 1),  # 5: South-West
	Vector2i(-1, 0),  # 6: West
	Vector2i(-1, -1)  # 7: North-West
]

# Configurable detection thresholds
var min_basin_area_cells: int = 15
var min_basin_depth_m: float = 0.5
var depth_epsilon: float = 0.005
var default_fill_ratio: float = 1.0

# Solved basin records
var basins: Array[Dictionary] = []

# Continuous spatial buffers (size W x H)
var basin_id_buffer: PackedInt32Array = PackedInt32Array() # -1 for land, basin_idx for lake
var lake_depth_buffer: PackedFloat32Array = PackedFloat32Array() # 0.0 on land, depth > 0 in lake
var lake_elevation_buffer: PackedFloat32Array = PackedFloat32Array() # -999.0 on land, water level in lake

var grid_size: Vector2i = Vector2i.ZERO
var cell_size: Vector2 = Vector2.ZERO
var world_origin: Vector2 = Vector2.ZERO
var total_cells: int = 0

func _init(p_min_area: int = 15, p_min_depth: float = 0.5) -> void:
	min_basin_area_cells = p_min_area
	min_basin_depth_m = p_min_depth

# -----------------------------------------------------------------------------
# Primary Solver Pipeline
# -----------------------------------------------------------------------------

## Solves lake basins directly from an authoritative WorldState instance.
func solve(world_state, config: Dictionary = {}) -> Array[Dictionary]:
	return solve_from_buffers(
		world_state.raw_elevation_buffer,
		world_state.conditioned_elevation_buffer,
		world_state.flow_direction_buffer,
		world_state.grid_resolution,
		world_state.cell_size,
		world_state.world_origin,
		config
	)

## Solves lake basins from discrete elevation and hydrological buffers.
func solve_from_buffers(
	raw_heights: PackedFloat32Array,
	filled_heights: PackedFloat32Array,
	flow_directions: PackedInt32Array,
	p_grid_res: Vector2i,
	p_cell_size: Vector2,
	p_origin: Vector2,
	config: Dictionary = {}
) -> Array[Dictionary]:
	var t0 = Time.get_ticks_usec()
	
	if config.has("min_basin_area_cells"):
		min_basin_area_cells = int(config["min_basin_area_cells"])
	if config.has("min_basin_depth_m"):
		min_basin_depth_m = float(config["min_basin_depth_m"])
	if config.has("depth_epsilon"):
		depth_epsilon = float(config["depth_epsilon"])
	if config.has("default_fill_ratio"):
		default_fill_ratio = clampf(float(config["default_fill_ratio"]), 0.05, 1.0)
		
	grid_size = p_grid_res
	cell_size = p_cell_size
	world_origin = p_origin
	total_cells = grid_size.x * grid_size.y
	
	basins.clear()
	basin_id_buffer.resize(total_cells)
	basin_id_buffer.fill(-1)
	
	lake_depth_buffer.resize(total_cells)
	lake_depth_buffer.fill(0.0)
	
	lake_elevation_buffer.resize(total_cells)
	lake_elevation_buffer.fill(-999.0)
	
	if raw_heights.size() != total_cells or filled_heights.size() != total_cells:
		printerr("LakeBasinSolver: Buffer size mismatch (expected %d cells)" % total_cells)
		return basins
		
	# 1. Connected Component Labeling of Depression Regions
	var raw_basins = _extract_connected_depressions(raw_heights, filled_heights)
	
	# 2. Analyze Basin Geometry, Spillways, Water Levels, and Outflow Rivers
	var cell_area = cell_size.x * cell_size.y
	var basin_idx = 0
	
	for b_cells in raw_basins:
		var basin_record = _analyze_basin(
			basin_idx,
			b_cells,
			raw_heights,
			filled_heights,
			flow_directions,
			cell_area
		)
		
		if basin_record.is_empty():
			continue
			
		# Populate raster buffers for this basin
		var w_elev = basin_record["water_elevation"]
		for c_idx in basin_record["lake_cells"]:
			var d = maxf(0.0, w_elev - raw_heights[c_idx])
			if d > 0.001:
				basin_id_buffer[c_idx] = basin_idx
				lake_depth_buffer[c_idx] = d
				lake_elevation_buffer[c_idx] = w_elev
				
		basins.append(basin_record)
		basin_idx += 1
		
	var t1 = Time.get_ticks_usec()
	# Diagnostics log
	return basins

# -----------------------------------------------------------------------------
# Depression Extraction (Connected Component Labeling)
# -----------------------------------------------------------------------------

func _extract_connected_depressions(raw_heights: PackedFloat32Array, filled_heights: PackedFloat32Array) -> Array[PackedInt32Array]:
	var w = grid_size.x
	var h = grid_size.y
	var visited = PackedByteArray()
	visited.resize(total_cells)
	visited.fill(0)
	
	var components: Array[PackedInt32Array] = []
	var queue: Array[int] = []
	
	for y in range(h):
		var row = y * w
		for x in range(w):
			var idx = row + x
			if visited[idx] == 1:
				continue
				
			var diff = filled_heights[idx] - raw_heights[idx]
			if diff <= depth_epsilon:
				continue # Not a depression cell
				
			# BFS flood-fill connected depression component
			var component_cells = PackedInt32Array()
			visited[idx] = 1
			queue.clear()
			queue.append(idx)
			
			var max_depth = diff
			
			while not queue.is_empty():
				var c_idx = queue.pop_back()
				component_cells.append(c_idx)
				var cx = c_idx % w
				var cy = c_idx / w
				
				var c_diff = filled_heights[c_idx] - raw_heights[c_idx]
				if c_diff > max_depth:
					max_depth = c_diff
					
				for offset in D8_OFFSETS:
					var nx = cx + offset.x
					var ny = cy + offset.y
					if nx >= 0 and nx < w and ny >= 0 and ny < h:
						var n_idx = ny * w + nx
						if visited[n_idx] == 0:
							var n_diff = filled_heights[n_idx] - raw_heights[n_idx]
							if n_diff > depth_epsilon:
								visited[n_idx] = 1
								queue.append(n_idx)
								
			# Filter insignificant pits
			if component_cells.size() >= min_basin_area_cells and max_depth >= min_basin_depth_m:
				components.append(component_cells)
				
	return components

# -----------------------------------------------------------------------------
# Basin Analysis: Spillway, Capacity, Water Elevation & Outlets
# -----------------------------------------------------------------------------

func _analyze_basin(
	basin_idx: int,
	cell_indices: PackedInt32Array,
	raw_heights: PackedFloat32Array,
	filled_heights: PackedFloat32Array,
	flow_directions: PackedInt32Array,
	cell_area: float
) -> Dictionary:
	var w = grid_size.x
	var h = grid_size.y
	
	var floor_h = 999999.0
	var floor_idx = -1
	
	var cell_set: Dictionary = {}
	for idx in cell_indices:
		cell_set[idx] = true
		var rh = raw_heights[idx]
		if rh < floor_h:
			floor_h = rh
			floor_idx = idx
			
	# 1. Identify Rim Cells & Spillway Saddle
	# A rim cell is a cell NOT in the basin that neighbors at least one basin cell
	var rim_cells_set: Dictionary = {}
	var touches_boundary = false
	
	for c_idx in cell_indices:
		var cx = c_idx % w
		var cy = c_idx / w
		if cx == 0 or cx == w - 1 or cy == 0 or cy == h - 1:
			touches_boundary = true
			
		for offset in D8_OFFSETS:
			var nx = cx + offset.x
			var ny = cy + offset.y
			if nx >= 0 and nx < w and ny >= 0 and ny < h:
				var n_idx = ny * w + nx
				if not cell_set.has(n_idx):
					rim_cells_set[n_idx] = true
			else:
				touches_boundary = true
				
	var spillway_h = 999999.0
	var spillway_idx = -1
	
	# The spillway saddle is the lowest rim cell
	for r_idx in rim_cells_set.keys():
		var rh = raw_heights[r_idx]
		if rh < spillway_h:
			spillway_h = rh
			spillway_idx = r_idx
			
	# In case the depression has no interior rim (boundary terminal sink)
	if spillway_idx < 0:
		spillway_h = filled_heights[cell_indices[0]]
		spillway_idx = cell_indices[0]
		
	# Fallback if Priority-Flood level is lower than rim detection
	var sample_filled = filled_heights[cell_indices[0]]
	if spillway_h > sample_filled + 0.1:
		spillway_h = sample_filled
		
	# 2. Basin Capacity Volume (at spillway level)
	var capacity_volume = 0.0
	for c_idx in cell_indices:
		var d = maxf(0.0, spillway_h - raw_heights[c_idx])
		capacity_volume += d * cell_area
		
	# 3. Water Surface Elevation at requested fill ratio
	var fill_ratio = default_fill_ratio
	var water_elevation = spillway_h
	var water_volume = capacity_volume
	
	if fill_ratio < 0.999:
		var target_vol = capacity_volume * fill_ratio
		water_elevation = _solve_water_elevation_binary_search(
			cell_indices, raw_heights, floor_h, spillway_h, target_vol, cell_area
		)
		water_volume = 0.0
		for c_idx in cell_indices:
			water_volume += maxf(0.0, water_elevation - raw_heights[c_idx]) * cell_area
			
	# 4. Flooded Lake Cells at water_elevation
	var lake_cells = PackedInt32Array()
	var lake_cell_set: Dictionary = {}
	var min_gx = w; var max_gx = 0
	var min_gy = h; var max_gy = 0
	
	var depth_sum = 0.0
	for c_idx in cell_indices:
		var rh = raw_heights[c_idx]
		if rh < water_elevation:
			lake_cells.append(c_idx)
			lake_cell_set[c_idx] = true
			var d = water_elevation - rh
			depth_sum += d
			var cx = c_idx % w
			var cy = c_idx / w
			if cx < min_gx: min_gx = cx
			if cx > max_gx: max_gx = cx
			if cy < min_gy: min_gy = cy
			if cy > max_gy: max_gy = cy
			
	if lake_cells.is_empty():
		return {}
		
	var mean_depth = depth_sum / float(lake_cells.size())
	var max_depth = water_elevation - floor_h
	
	# 5. Extract Shoreline Boundary Cells
	var shoreline_cells: Array[Vector2i] = []
	for c_idx in lake_cells:
		var cx = c_idx % w
		var cy = c_idx / w
		var is_shore = false
		for offset in D8_OFFSETS:
			var nx = cx + offset.x
			var ny = cy + offset.y
			if nx >= 0 and nx < w and ny >= 0 and ny < h:
				var n_idx = ny * w + nx
				if not lake_cell_set.has(n_idx):
					is_shore = true
					break
			else:
				is_shore = true
				break
		if is_shore:
			shoreline_cells.append(Vector2i(cx, cy))
			
	# 6. Spatial Bounds (Rect2)
	var min_world = _grid_to_world(float(min_gx), float(min_gy))
	var max_world = _grid_to_world(float(max_gx + 1), float(max_gy + 1))
	var bounds = Rect2(min_world, max_world - min_world)
	
	# 7. Trace Spillway Outlet River Path (if lake overflows at spillway)
	var outlet_path_3d = PackedVector3Array()
	var outlet_path_grid: Array[Vector2i] = []
	var is_terminal = touches_boundary or (spillway_idx == floor_idx)
	
	if not is_terminal and water_elevation >= spillway_h - 0.05:
		var outlet_res = _trace_spillway_outlet(
			spillway_idx, flow_directions, filled_heights, lake_cell_set
		)
		outlet_path_3d = outlet_res["path_3d"]
		outlet_path_grid = outlet_res["path_grid"]
		
	var spillway_gx = spillway_idx % w
	var spillway_gy = spillway_idx / w
	var floor_gx = floor_idx % w
	var floor_gy = floor_idx / w
	
	return {
		"id": "lake_%03d" % (basin_idx + 1),
		"basin_index": basin_idx,
		"cell_count": lake_cells.size(),
		"lake_cells": lake_cells,
		"total_depression_cells": cell_indices.size(),
		"area_m2": float(lake_cells.size()) * cell_area,
		"floor_elevation": floor_h,
		"floor_cell": Vector2i(floor_gx, floor_gy),
		"floor_world_pos": _grid_to_world(float(floor_gx), float(floor_gy)),
		"spillway_elevation": spillway_h,
		"spillway_cell": Vector2i(spillway_gx, spillway_gy),
		"spillway_world_pos": _grid_to_world(float(spillway_gx), float(spillway_gy)),
		"water_elevation": water_elevation,
		"max_depth_m": max_depth,
		"mean_depth_m": mean_depth,
		"capacity_volume_m3": capacity_volume,
		"water_volume_m3": water_volume,
		"fill_ratio": water_volume / max(0.001, capacity_volume),
		"is_terminal": is_terminal,
		"shoreline_cells": shoreline_cells,
		"bounds": bounds,
		"outlet_path_3d": outlet_path_3d,
		"outlet_path_grid": outlet_path_grid,
		"inlet_river_ids": [],
		"outlet_river_id": "",
		"status": "active"
	}

# -----------------------------------------------------------------------------
# Binary Search for Water Elevation Given Target Storage Volume
# -----------------------------------------------------------------------------

func _solve_water_elevation_binary_search(
	cells: PackedInt32Array,
	raw_heights: PackedFloat32Array,
	low_h: float,
	high_h: float,
	target_vol: float,
	cell_area: float
) -> float:
	var low = low_h
	var high = high_h
	
	for _iter in range(18):
		var mid = (low + high) * 0.5
		var vol = 0.0
		for idx in cells:
			var rh = raw_heights[idx]
			if rh < mid:
				vol += (mid - rh) * cell_area
		if vol < target_vol:
			low = mid
		else:
			high = mid
			
	return (low + high) * 0.5

# -----------------------------------------------------------------------------
# Spillway Outflow River Tracing
# -----------------------------------------------------------------------------

func _trace_spillway_outlet(
	start_spillway_idx: int,
	flow_directions: PackedInt32Array,
	filled_heights: PackedFloat32Array,
	lake_cell_set: Dictionary
) -> Dictionary:
	var w = grid_size.x
	var h = grid_size.y
	
	var path_3d = PackedVector3Array()
	var path_grid: Array[Vector2i] = []
	var visited: Dictionary = {}
	
	var cur_idx = start_spillway_idx
	var steps = 0
	var max_steps = 2000
	
	while steps < max_steps:
		var cx = cur_idx % w
		var cy = cur_idx / w
		var wpos = _grid_to_world(float(cx), float(cy))
		var elev = filled_heights[cur_idx]
		
		path_grid.append(Vector2i(cx, cy))
		path_3d.append(Vector3(wpos.x, elev, wpos.y))
		visited[cur_idx] = true
		steps += 1
		
		# Termination on boundary or sink
		if cx == 0 or cx == w - 1 or cy == 0 or cy == h - 1:
			break
		var dir = flow_directions[cur_idx]
		if dir == HydrologyEngine.OUTLET or dir < 0 or dir >= 8:
			break
			
		var offset = D8_OFFSETS[dir]
		var nx = cx + offset.x
		var ny = cy + offset.y
		if nx < 0 or nx >= w or ny < 0 or ny >= h:
			break
			
		var next_idx = ny * w + nx
		# Stop if loop detected or if it flows back into the same lake
		if visited.has(next_idx) or lake_cell_set.has(next_idx):
			break
			
		cur_idx = next_idx
		
	return {
		"path_3d": path_3d,
		"path_grid": path_grid
	}

# -----------------------------------------------------------------------------
# FeatureRegistry & Hydrological Integration
# -----------------------------------------------------------------------------

## Registers all detected lake basins into FeatureRegistry and registers outlet rivers.
func register_lakes_in_feature_registry(registry: FeatureRegistry, connect_rivers: bool = true) -> void:
	for basin in basins:
		var lake_id = basin["id"]
		
		# Register Lake feature
		registry.register_feature({
			"id": lake_id,
			"type": "lake",
			"position": basin["floor_world_pos"],
			"bounds": basin["bounds"],
			"parameters": {
				"water_elevation": basin["water_elevation"],
				"spillway_elevation": basin["spillway_elevation"],
				"floor_elevation": basin["floor_elevation"],
				"max_depth_m": basin["max_depth_m"],
				"mean_depth_m": basin["mean_depth_m"],
				"area_m2": basin["area_m2"],
				"water_volume_m3": basin["water_volume_m3"],
				"capacity_volume_m3": basin["capacity_volume_m3"],
				"fill_ratio": basin["fill_ratio"],
				"spillway_pos": basin["spillway_world_pos"],
				"shoreline_cell_count": basin["shoreline_cells"].size(),
				"is_terminal": basin["is_terminal"],
				"inlet_river_ids": basin["inlet_river_ids"],
				"outlet_river_id": basin["outlet_river_id"]
			},
			"status": "active",
			"metadata": {
				"basin_index": basin["basin_index"],
				"spillway_cell": basin["spillway_cell"],
				"floor_cell": basin["floor_cell"]
			}
		})
		
		# If basin has an active spillway outflow river, register it
		var outlet_pts: PackedVector3Array = basin["outlet_path_3d"]
		if connect_rivers and outlet_pts.size() >= 3:
			var outlet_riv_id = "riv_outflow_%s" % lake_id
			basin["outlet_river_id"] = outlet_riv_id
			
			var riv_points: Array[Vector2] = []
			for p3 in outlet_pts:
				riv_points.append(Vector2(p3.x, p3.z))
				
			registry.register_feature({
				"id": outlet_riv_id,
				"type": "river",
				"position": Vector2(outlet_pts[0].x, outlet_pts[0].z),
				"parameters": {
					"source_lake_id": lake_id,
					"points": riv_points,
					"waypoints_3d": outlet_pts,
					"width": 8.0,
					"start_elevation": outlet_pts[0].y,
					"end_elevation": outlet_pts[outlet_pts.size() - 1].y
				},
				"status": "active"
			})
			# Update lake parameters with outlet river reference
			registry.update_feature(lake_id, {"outlet_river_id": outlet_riv_id})

## Connects an incoming upstream river to a receiving lake.
func connect_inlet_river(lake_id: String, river_id: String, registry: FeatureRegistry) -> bool:
	if not registry.has_feature(lake_id) or not registry.has_feature(river_id):
		return false
		
	# Update Lake feature
	var lake = registry.get_feature(lake_id)
	var inlets: Array = lake["parameters"].get("inlet_river_ids", [])
	if not inlets.has(river_id):
		inlets.append(river_id)
		registry.update_feature(lake_id, {"inlet_river_ids": inlets})
		
	# Update River feature
	registry.update_feature(river_id, {"receiving_lake_id": lake_id})
	return true

# -----------------------------------------------------------------------------
# Coordinate Conversions
# -----------------------------------------------------------------------------

func _grid_to_world(gx: float, gy: float) -> Vector2:
	return Vector2(world_origin.x + gx * cell_size.x, world_origin.y + gy * cell_size.y)

