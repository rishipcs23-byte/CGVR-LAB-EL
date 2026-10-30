# HydrologyEngine.gd
# Deterministic hydrology and drainage network solver for SublimeGreens Milestone 1.
# Implements D8 flow direction, Priority-Flood depression filling, flow accumulation,
# and gravity-driven drainage path tracing.
class_name HydrologyEngine
extends RefCounted

const TerrainEngine = preload("res://TerrainEngine.gd")

const OUTLET: int = -1
const SINK: int = -2

# 8 Neighbor offsets in grid coordinates: (dx, dy)
# 0: North, 1: North-East, 2: East, 3: South-East,
# 4: South, 5: South-West, 6: West, 7: North-West
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

var terrain: TerrainEngine = null
var grid_size: Vector2i = Vector2i.ZERO
var total_cells: int = 0

# Hydrological data layers
var raw_heights: PackedFloat32Array = PackedFloat32Array()
var filled_heights: PackedFloat32Array = PackedFloat32Array()
var flow_directions: PackedInt32Array = PackedInt32Array() # -1 for outlet, 0..7 for D8, -2 for sink
var flow_accumulation: PackedFloat32Array = PackedFloat32Array() # Upslope contributing area (cell units)

# Diagnostics and metrics
var depression_cells_count: int = 0
var max_accumulation: float = 1.0
var outlets_list: Array[Dictionary] = []

# Internal Binary Min-Heap for Priority-Flood
var _heap_cells: PackedInt32Array = PackedInt32Array()
var _heap_keys: PackedFloat32Array = PackedFloat32Array()
var _heap_size: int = 0

func _init(p_terrain: TerrainEngine = null) -> void:
	if p_terrain != null:
		setup_from_terrain(p_terrain)

func setup_from_terrain(p_terrain: TerrainEngine) -> void:
	terrain = p_terrain
	grid_size = terrain.grid_resolution
	total_cells = grid_size.x * grid_size.y
	raw_heights = terrain.heights.duplicate()
	filled_heights = raw_heights.duplicate()
	
	flow_directions.resize(total_cells)
	flow_directions.fill(SINK)
	
	flow_accumulation.resize(total_cells)
	flow_accumulation.fill(1.0)

# -----------------------------------------------------------------------------
# Binary Min-Heap Implementation
# -----------------------------------------------------------------------------

func _heap_init(capacity: int) -> void:
	_heap_cells.resize(capacity)
	_heap_keys.resize(capacity)
	_heap_size = 0

func _heap_push(cell_idx: int, key: float) -> void:
	if _heap_size >= _heap_cells.size():
		var new_cap = max(1024, _heap_size * 2)
		_heap_cells.resize(new_cap)
		_heap_keys.resize(new_cap)
		
	var i = _heap_size
	_heap_size += 1
	_heap_cells[i] = cell_idx
	_heap_keys[i] = key
	
	# Sift up
	while i > 0:
		var parent = (i - 1) >> 1
		if _heap_keys[i] < _heap_keys[parent]:
			var tmp_c = _heap_cells[i]
			_heap_cells[i] = _heap_cells[parent]
			_heap_cells[parent] = tmp_c
			
			var tmp_k = _heap_keys[i]
			_heap_keys[i] = _heap_keys[parent]
			_heap_keys[parent] = tmp_k
			
			i = parent
		else:
			break

func _heap_pop() -> int:
	if _heap_size <= 0:
		return -1
	var top_cell = _heap_cells[0]
	_heap_size -= 1
	
	if _heap_size > 0:
		_heap_cells[0] = _heap_cells[_heap_size]
		_heap_keys[0] = _heap_keys[_heap_size]
		
		# Sift down
		var i = 0
		while true:
			var left = (i << 1) + 1
			var right = left + 1
			var smallest = i
			
			if left < _heap_size and _heap_keys[left] < _heap_keys[smallest]:
				smallest = left
			if right < _heap_size and _heap_keys[right] < _heap_keys[smallest]:
				smallest = right
				
			if smallest != i:
				var tmp_c = _heap_cells[i]
				_heap_cells[i] = _heap_cells[smallest]
				_heap_cells[smallest] = tmp_c
				
				var tmp_k = _heap_keys[i]
				_heap_keys[i] = _heap_keys[smallest]
				_heap_keys[smallest] = tmp_k
				
				i = smallest
			else:
				break
				
	return top_cell

# -----------------------------------------------------------------------------
# Core Hydrological Solvers
# -----------------------------------------------------------------------------

## Computes the full hydrological cycle:
## 1. Priority-Flood depression filling
## 2. D8 Flow directions
## 3. Flow accumulation
## 4. Outlet cataloging
func resolve_hydrology() -> Dictionary:
	var t0 = Time.get_ticks_usec()
	depression_cells_count = fill_depressions_priority_flood()
	var t1 = Time.get_ticks_usec()
	calculate_d8_flow_directions()
	var t2 = Time.get_ticks_usec()
	calculate_flow_accumulation()
	var t3 = Time.get_ticks_usec()
	catalog_outlets()
	var t4 = Time.get_ticks_usec()
	
	return {
		"depression_cells_filled": depression_cells_count,
		"max_accumulation": max_accumulation,
		"outlets_count": outlets_list.size(),
		"time_fill_ms": (t1 - t0) / 1000.0,
		"time_d8_ms": (t2 - t1) / 1000.0,
		"time_acc_ms": (t3 - t2) / 1000.0,
		"time_total_ms": (t4 - t0) / 1000.0
	}

## Priority-Flood Algorithm (Barnes, Lehman, Mulla, 2014)
## Resolves all interior pits/sinks by filling to spillway levels with an epsilon gradient.
## Guarantees that every cell in the domain has a descending path to the boundary.
func fill_depressions_priority_flood() -> int:
	var w = grid_size.x
	var h = grid_size.y
	var visited = PackedByteArray()
	visited.resize(total_cells)
	visited.fill(0)
	
	_heap_init(total_cells)
	filled_heights = raw_heights.duplicate()
	
	# 1. Push all grid boundary cells into min-heap
	for x in range(w):
		# Top row (y = 0)
		var idx_top = x
		visited[idx_top] = 1
		_heap_push(idx_top, filled_heights[idx_top])
		
		# Bottom row (y = h - 1)
		var idx_bot = (h - 1) * w + x
		visited[idx_bot] = 1
		_heap_push(idx_bot, filled_heights[idx_bot])
		
	for y in range(1, h - 1):
		# Left column (x = 0)
		var idx_left = y * w
		visited[idx_left] = 1
		_heap_push(idx_left, filled_heights[idx_left])
		
		# Right column (x = w - 1)
		var idx_right = y * w + (w - 1)
		visited[idx_right] = 1
		_heap_push(idx_right, filled_heights[idx_right])
		
	var filled_count = 0
	# Tiny gradient increment to break flats and route flow to spillway
	var epsilon = 0.0002
	
	# 2. Process flood front from lowest spillway upwards
	while _heap_size > 0:
		var c_idx = _heap_pop()
		var c_elev = filled_heights[c_idx]
		var cx = c_idx % w
		var cy = c_idx / w
		
		for offset in D8_OFFSETS:
			var nx = cx + offset.x
			var ny = cy + offset.y
			if nx >= 0 and nx < w and ny >= 0 and ny < h:
				var n_idx = ny * w + nx
				if visited[n_idx] == 0:
					visited[n_idx] = 1
					if filled_heights[n_idx] <= c_elev:
						# Depression detected! Fill to spillway + epsilon
						filled_heights[n_idx] = c_elev + epsilon
						filled_count += 1
					_heap_push(n_idx, filled_heights[n_idx])
					
	return filled_count

## Calculates D8 flow directions based on steepest downhill descent
func calculate_d8_flow_directions() -> void:
	var w = grid_size.x
	var h = grid_size.y
	flow_directions.resize(total_cells)
	
	var cell_dx = terrain.cell_size.x
	var cell_dy = terrain.cell_size.y
	var diag_dist = sqrt(cell_dx * cell_dx + cell_dy * cell_dy)
	
	var distances = [
		cell_dy,    # 0: North
		diag_dist,  # 1: North-East
		cell_dx,    # 2: East
		diag_dist,  # 3: South-East
		cell_dy,    # 4: South
		diag_dist,  # 5: South-West
		cell_dx,    # 6: West
		diag_dist   # 7: North-West
	]
	
	for y in range(h):
		var row_offset = y * w
		for x in range(w):
			var c_idx = row_offset + x
			
			# Boundary cells drain out of the grid as outlets
			if x == 0 or x == w - 1 or y == 0 or y == h - 1:
				flow_directions[c_idx] = OUTLET
				continue
				
			var c_elev = filled_heights[c_idx]
			var max_slope = -999999.0
			var best_dir = SINK
			
			for dir_idx in range(8):
				var offset = D8_OFFSETS[dir_idx]
				var nx = x + offset.x
				var ny = y + offset.y
				var n_idx = ny * w + nx
				var n_elev = filled_heights[n_idx]
				
				# Drop per unit distance
				var slope = (c_elev - n_elev) / distances[dir_idx]
				if slope > max_slope:
					max_slope = slope
					best_dir = dir_idx
					
			if max_slope > 0.0:
				flow_directions[c_idx] = best_dir
			else:
				# In case of remaining perfectly flat cells, point toward boundary or lowest raw height
				flow_directions[c_idx] = _resolve_flat_direction(x, y, c_idx)

func _resolve_flat_direction(x: int, y: int, c_idx: int) -> int:
	var w = grid_size.x
	var min_raw = raw_heights[c_idx]
	var best_dir = 0
	
	for dir_idx in range(8):
		var offset = D8_OFFSETS[dir_idx]
		var nx = x + offset.x
		var ny = y + offset.y
		if nx >= 0 and nx < w and ny >= 0 and ny < grid_size.y:
			var n_idx = ny * w + nx
			if raw_heights[n_idx] < min_raw:
				min_raw = raw_heights[n_idx]
				best_dir = dir_idx
	return best_dir

## Computes flow accumulation using topological sorting (DAG propagation from ridges downward)
func calculate_flow_accumulation() -> void:
	var w = grid_size.x
	var h = grid_size.y
	flow_accumulation.resize(total_cells)
	flow_accumulation.fill(1.0)
	
	# In-degree: how many cells flow into cell c
	var in_degree = PackedInt32Array()
	in_degree.resize(total_cells)
	in_degree.fill(0)
	
	for c_idx in range(total_cells):
		var target_idx = get_downstream_cell_index(c_idx)
		if target_idx >= 0:
			in_degree[target_idx] += 1
			
	# Queue of ridge cells (in_degree == 0)
	var queue = PackedInt32Array()
	queue.resize(total_cells)
	var q_head = 0
	var q_tail = 0
	
	for c_idx in range(total_cells):
		if in_degree[c_idx] == 0:
			queue[q_tail] = c_idx
			q_tail += 1
			
	max_accumulation = 1.0
	
	while q_head < q_tail:
		var c_idx = queue[q_head]
		q_head += 1
		
		var acc = flow_accumulation[c_idx]
		if acc > max_accumulation:
			max_accumulation = acc
			
		var target_idx = get_downstream_cell_index(c_idx)
		if target_idx >= 0:
			flow_accumulation[target_idx] += acc
			in_degree[target_idx] -= 1
			if in_degree[target_idx] == 0:
				queue[q_tail] = target_idx
				q_tail += 1

func catalog_outlets() -> void:
	outlets_list.clear()
	var w = grid_size.x
	var h = grid_size.y
	
	for y in range(h):
		for x in range(w):
			var idx = y * w + x
			if flow_directions[idx] == OUTLET:
				var acc = flow_accumulation[idx]
				if acc > 10.0: # Filter minor boundary edge noise
					var pos_world = terrain.grid_to_world(float(x), float(y))
					outlets_list.append({
						"grid_pos": Vector2i(x, y),
						"world_pos": pos_world,
						"elevation": filled_heights[idx],
						"accumulation": acc
					})
					
	outlets_list.sort_custom(func(a, b): return a["accumulation"] > b["accumulation"])

# -----------------------------------------------------------------------------
# Spatial Navigation & Drainage Path Tracing
# -----------------------------------------------------------------------------

func get_downstream_cell_index(c_idx: int) -> int:
	var dir = flow_directions[c_idx]
	if dir < 0 or dir >= 8:
		return -1
	var w = grid_size.x
	var cx = c_idx % w
	var cy = c_idx / w
	var offset = D8_OFFSETS[dir]
	var nx = cx + offset.x
	var ny = cy + offset.y
	if nx >= 0 and nx < w and ny >= 0 and ny < grid_size.y:
		return ny * w + nx
	return -1

## Traces a downhill river path from a world coordinate following the drainage network
func trace_drainage_path(start_world_pos: Vector2, max_steps: int = 2000) -> Dictionary:
	var grid_pos = terrain.world_to_grid(start_world_pos.x, start_world_pos.y)
	var gx = clampi(int(round(grid_pos.x)), 0, grid_size.x - 1)
	var gy = clampi(int(round(grid_pos.y)), 0, grid_size.y - 1)
	
	var path_world_3d: PackedVector3Array = PackedVector3Array()
	var path_grid: Array[Vector2i] = []
	var path_elevations: PackedFloat32Array = PackedFloat32Array()
	var path_accumulations: PackedFloat32Array = PackedFloat32Array()
	
	var visited_cells = {}
	var current_idx = gy * grid_size.x + gx
	var steps = 0
	var termination_reason = "max_steps_exceeded"
	
	while steps < max_steps:
		var cx = current_idx % grid_size.x
		var cy = current_idx / grid_size.x
		var wpos_2d = terrain.grid_to_world(float(cx), float(cy))
		var elev = filled_heights[current_idx]
		var acc = flow_accumulation[current_idx]
		
		path_grid.append(Vector2i(cx, cy))
		path_world_3d.append(Vector3(wpos_2d.x, elev, wpos_2d.y))
		path_elevations.append(elev)
		path_accumulations.append(acc)
		
		visited_cells[current_idx] = true
		steps += 1
		
		var dir = flow_directions[current_idx]
		if dir == OUTLET:
			termination_reason = "reached_boundary_outlet"
			break
		elif dir == SINK:
			termination_reason = "trapped_in_sink"
			break
			
		var next_idx = get_downstream_cell_index(current_idx)
		if next_idx < 0:
			termination_reason = "reached_boundary_edge"
			break
			
		if visited_cells.has(next_idx):
			termination_reason = "loop_detected"
			break
			
		current_idx = next_idx

	# Validate hydrological monotonicity along path: Z[i+1] <= Z[i] + 1e-4
	var is_monotonic = true
	var violation_count = 0
	for i in range(path_elevations.size() - 1):
		if path_elevations[i + 1] > path_elevations[i] + 0.001:
			is_monotonic = false
			violation_count += 1
			
	return {
		"path_3d": path_world_3d,
		"path_grid": path_grid,
		"elevations": path_elevations,
		"accumulations": path_accumulations,
		"length_steps": path_grid.size(),
		"is_monotonic": is_monotonic,
		"violation_count": violation_count,
		"termination_reason": termination_reason,
		"start_point": path_world_3d[0] if path_world_3d.size() > 0 else Vector3.ZERO,
		"end_point": path_world_3d[path_world_3d.size() - 1] if path_world_3d.size() > 0 else Vector3.ZERO
	}

# -----------------------------------------------------------------------------
# Diagnostic & Visualization Image Generators
# -----------------------------------------------------------------------------

## Exports a high-contrast flow accumulation map showing drainage veins
func export_flow_accumulation_image() -> Image:
	var w = grid_size.x
	var h = grid_size.y
	var img = Image.create(w, h, false, Image.FORMAT_RGBA8)
	var log_max = log(max(2.0, max_accumulation))
	
	for y in range(h):
		var row = y * w
		for x in range(w):
			var acc = flow_accumulation[row + x]
			var log_acc = log(acc) / log_max
			
			# Background: deep dark slate; Channels: radiant cyan/white
			var c = Color.BLACK
			if log_acc < 0.2:
				# Hillslope (very low flow)
				c = Color(0.04, 0.07, 0.1, 1.0)
			elif log_acc < 0.5:
				# Creek / tributary
				var t = (log_acc - 0.2) / 0.3
				c = Color(0.08, 0.2 + t * 0.3, 0.4 + t * 0.4, 1.0)
			else:
				# Major river channel
				var t = (log_acc - 0.5) / 0.5
				c = Color(0.2 + t * 0.8, 0.6 + t * 0.4, 1.0, 1.0)
				
			img.set_pixel(x, y, c)
	return img

## Exports a color-coded flow direction map (D8 angles)
func export_flow_direction_image() -> Image:
	var w = grid_size.x
	var h = grid_size.y
	var img = Image.create(w, h, false, Image.FORMAT_RGBA8)
	
	# Hue-coded colors for each of the 8 directions
	var dir_colors = [
		Color(1.0, 0.2, 0.2), # 0: N (Red)
		Color(1.0, 0.6, 0.2), # 1: NE (Orange)
		Color(1.0, 1.0, 0.2), # 2: E (Yellow)
		Color(0.2, 1.0, 0.2), # 3: SE (Green)
		Color(0.2, 1.0, 1.0), # 4: S (Cyan)
		Color(0.2, 0.4, 1.0), # 5: SW (Blue)
		Color(0.7, 0.2, 1.0), # 6: W (Purple)
		Color(1.0, 0.2, 0.7)  # 7: NW (Magenta)
	]
	
	for y in range(h):
		var row = y * w
		for x in range(w):
			var dir = flow_directions[row + x]
			var c = Color(0.1, 0.1, 0.1, 1.0) # Black for outlet/sink
			if dir >= 0 and dir < 8:
				c = dir_colors[dir]
			elif dir == OUTLET:
				c = Color.WHITE
			img.set_pixel(x, y, c)
	return img
