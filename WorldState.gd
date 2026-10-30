# WorldState.gd
# Authoritative unified world state for SublimeGreens Milestone 2.
# Stores continuous terrain/hydrological simulation buffers and owns the FeatureRegistry.
# Acts as the authoritative source of truth for both raw and hydro-conditioned surfaces.
class_name WorldState
extends RefCounted

const TerrainEngine = preload("res://TerrainEngine.gd")
const HydrologyEngine = preload("res://HydrologyEngine.gd")
const FeatureRegistry = preload("res://FeatureRegistry.gd")
const LakeBasinSolver = preload("res://LakeBasinSolver.gd")

signal region_updated(region_rect: Rect2)
signal world_reinitialized()
signal lakes_updated()

# --- World Metrics & Spatial Coordinate System ---
var world_size: Vector2 = Vector2(1000.0, 1000.0) # 1 km x 1 km
var world_origin: Vector2 = Vector2(-500.0, -500.0) # [-500, 500] centered
var grid_resolution: Vector2i = Vector2i(256, 256)
var cell_size: Vector2 = Vector2.ZERO
var total_cells: int = 0
var world_seed: int = 42

# --- Authoritative Geographical Simulation Buffers ---
# 1. Geological / raw terrain elevation buffer (meters)
var raw_elevation_buffer: PackedFloat32Array = PackedFloat32Array()

# 2. Hydrologically conditioned drainage surface (Priority-Flood filled)
var conditioned_elevation_buffer: PackedFloat32Array = PackedFloat32Array()

# 3. D8 Flow direction buffer (-1 for OUTLET, 0..7 for D8 directions, -2 for SINK)
var flow_direction_buffer: PackedInt32Array = PackedInt32Array()

# 4. Flow accumulation buffer (contributing upstream cells)
var flow_accumulation_buffer: PackedFloat32Array = PackedFloat32Array()

# --- Lake Basin Data Structures (Milestone 3) ---
var lake_solver: LakeBasinSolver = null
var basin_id_buffer: PackedInt32Array = PackedInt32Array() # -1 = land, basin_idx = lake
var lake_depth_buffer: PackedFloat32Array = PackedFloat32Array() # depth in meters (0 on land)
var lake_elevation_buffer: PackedFloat32Array = PackedFloat32Array() # water elevation (-999 on land)
var detected_basins: Array[Dictionary] = []

# --- Feature Registry ---
var feature_registry: FeatureRegistry = null

# --- Metadata & Diagnostics ---
var metadata: Dictionary = {}
var min_raw_elevation: float = 0.0
var max_raw_elevation: float = 0.0
var min_cond_elevation: float = 0.0
var max_cond_elevation: float = 0.0
var max_flow_accumulation: float = 1.0

func _init(p_size: Vector2 = Vector2(1000.0, 1000.0), p_res: Vector2i = Vector2i(256, 256), p_origin: Vector2 = Vector2(-500.0, -500.0), p_seed: int = 42) -> void:
	feature_registry = FeatureRegistry.new()
	initialize(p_size, p_res, p_origin, p_seed)

## Re-initializes buffers and dimensions
func initialize(p_size: Vector2, p_res: Vector2i, p_origin: Vector2, p_seed: int) -> void:
	world_size = p_size
	grid_resolution = p_res
	world_origin = p_origin
	world_seed = p_seed
	
	var denom_x = max(1, grid_resolution.x - 1)
	var denom_y = max(1, grid_resolution.y - 1)
	cell_size = Vector2(world_size.x / float(denom_x), world_size.y / float(denom_y))
	total_cells = grid_resolution.x * grid_resolution.y
	
	raw_elevation_buffer.resize(total_cells)
	raw_elevation_buffer.fill(0.0)
	
	conditioned_elevation_buffer.resize(total_cells)
	conditioned_elevation_buffer.fill(0.0)
	
	flow_direction_buffer.resize(total_cells)
	flow_direction_buffer.fill(-1)
	
	flow_accumulation_buffer.resize(total_cells)
	flow_accumulation_buffer.fill(1.0)
	
	basin_id_buffer.resize(total_cells)
	basin_id_buffer.fill(-1)
	
	lake_depth_buffer.resize(total_cells)
	lake_depth_buffer.fill(0.0)
	
	lake_elevation_buffer.resize(total_cells)
	lake_elevation_buffer.fill(-999.0)
	
	detected_basins.clear()
	
	metadata.clear()
	metadata["created_timestamp"] = Time.get_unix_time_from_system()
	metadata["engine_version"] = "SublimeGreens_2.0"
	metadata["cell_area_m2"] = cell_size.x * cell_size.y

# -----------------------------------------------------------------------------
# Simulation Ingestion
# -----------------------------------------------------------------------------

## Authoritatively ingests outputs from TerrainEngine and HydrologyEngine.
## Preserves strict separation between original geological terrain and hydro-conditioned surface.
func initialize_from_simulation(p_terrain: TerrainEngine, p_hydro: HydrologyEngine, p_metadata: Dictionary = {}) -> void:
	initialize(p_terrain.world_size, p_terrain.grid_resolution, p_terrain.world_origin, p_terrain.current_seed)
	
	# 1. Authoritative Raw Geological Elevation
	raw_elevation_buffer = p_terrain.heights.duplicate()
	
	# 2. Authoritative Conditioned Hydrological Surface
	if p_hydro.filled_heights.size() == total_cells:
		conditioned_elevation_buffer = p_hydro.filled_heights.duplicate()
	else:
		conditioned_elevation_buffer = raw_elevation_buffer.duplicate()
		
	# 3. Flow Directions & Accumulation
	if p_hydro.flow_directions.size() == total_cells:
		flow_direction_buffer = p_hydro.flow_directions.duplicate()
	if p_hydro.flow_accumulation.size() == total_cells:
		flow_accumulation_buffer = p_hydro.flow_accumulation.duplicate()
		
	# 4. Calculate buffer bounds
	_update_elevation_metrics()
	
	# 5. Metadata
	for k in p_metadata.keys():
		metadata[k] = p_metadata[k]
	metadata["depressions_filled"] = p_hydro.depression_cells_count
	metadata["max_accumulation"] = p_hydro.max_accumulation
	metadata["outlets_count"] = p_hydro.outlets_list.size()
	
	world_reinitialized.emit()

func _update_elevation_metrics() -> void:
	if total_cells <= 0:
		return
	min_raw_elevation = raw_elevation_buffer[0]
	max_raw_elevation = raw_elevation_buffer[0]
	min_cond_elevation = conditioned_elevation_buffer[0]
	max_cond_elevation = conditioned_elevation_buffer[0]
	max_flow_accumulation = flow_accumulation_buffer[0]
	
	for i in range(total_cells):
		var rh = raw_elevation_buffer[i]
		if rh < min_raw_elevation: min_raw_elevation = rh
		if rh > max_raw_elevation: max_raw_elevation = rh
		
		var ch = conditioned_elevation_buffer[i]
		if ch < min_cond_elevation: min_cond_elevation = ch
		if ch > max_cond_elevation: max_cond_elevation = ch
		
		var acc = flow_accumulation_buffer[i]
		if acc > max_flow_accumulation: max_flow_accumulation = acc

# -----------------------------------------------------------------------------
# Continuous Elevation Queries
# -----------------------------------------------------------------------------

## Returns the raw geological terrain elevation at world coordinates (wx, wz) using bilinear interpolation.
func get_elevation_at(wx: float, wz: float) -> float:
	return _sample_buffer_bilinear(raw_elevation_buffer, wx, wz)

## Returns the hydrologically conditioned drainage elevation at world coordinates (wx, wz).
## Guaranteed to be non-decreasing relative to raw elevation (conditioned >= raw).
func get_conditioned_elevation_at(wx: float, wz: float) -> float:
	return _sample_buffer_bilinear(conditioned_elevation_buffer, wx, wz)

## Returns the depth of depression/water fill at world coordinates (conditioned - raw).
## Values > 0 indicate potential lake basins or depression sinks.
func get_depression_depth_at(wx: float, wz: float) -> float:
	var raw_h = get_elevation_at(wx, wz)
	var cond_h = get_conditioned_elevation_at(wx, wz)
	return maxf(0.0, cond_h - raw_h)

## Internal fast bilinear sampling on a PackedFloat32Array buffer
func _sample_buffer_bilinear(buffer: PackedFloat32Array, wx: float, wz: float) -> float:
	if buffer.is_empty():
		return 0.0
		
	var gx_f = (wx - world_origin.x) / cell_size.x
	var gy_f = (wz - world_origin.y) / cell_size.y
	
	var gx0 = clampi(int(floor(gx_f)), 0, grid_resolution.x - 1)
	var gy0 = clampi(int(floor(gy_f)), 0, grid_resolution.y - 1)
	var gx1 = mini(gx0 + 1, grid_resolution.x - 1)
	var gy1 = mini(gy0 + 1, grid_resolution.y - 1)
	
	var tx = clampf(gx_f - float(gx0), 0.0, 1.0)
	var ty = clampf(gy_f - float(gy0), 0.0, 1.0)
	
	var w = grid_resolution.x
	var h00 = buffer[gy0 * w + gx0]
	var h10 = buffer[gy0 * w + gx1]
	var h01 = buffer[gy1 * w + gx0]
	var h11 = buffer[gy1 * w + gx1]
	
	var top = lerpf(h00, h10, tx)
	var bot = lerpf(h01, h11, tx)
	return lerpf(top, bot, ty)

# -----------------------------------------------------------------------------
# Hydrological & Topographic Spatial Queries
# -----------------------------------------------------------------------------

## Returns the D8 flow direction code at world coordinates (-1=outlet, 0..7=D8, -2=sink).
func get_flow_direction_at(wx: float, wz: float) -> int:
	var g = world_to_grid(wx, wz)
	var gx = clampi(int(round(g.x)), 0, grid_resolution.x - 1)
	var gy = clampi(int(round(g.y)), 0, grid_resolution.y - 1)
	return flow_direction_buffer[gy * grid_resolution.x + gx]

## Returns the contributing upstream catchment area (in cell units) at world coordinates.
func get_flow_accumulation_at(wx: float, wz: float) -> float:
	return _sample_buffer_bilinear(flow_accumulation_buffer, wx, wz)

## Returns spatial gradient, normal vector, and slope angle at world coordinates.
func get_slope_and_normal(wx: float, wz: float, use_conditioned: bool = false) -> Dictionary:
	var eps_x = cell_size.x * 0.5
	var eps_z = cell_size.y * 0.5
	
	var h_xp: float
	var h_xm: float
	var h_zp: float
	var h_zm: float
	var h_mid: float
	
	if use_conditioned:
		h_mid = get_conditioned_elevation_at(wx, wz)
		h_xp = get_conditioned_elevation_at(wx + eps_x, wz)
		h_xm = get_conditioned_elevation_at(wx - eps_x, wz)
		h_zp = get_conditioned_elevation_at(wx, wz + eps_z)
		h_zm = get_conditioned_elevation_at(wx, wz - eps_z)
	else:
		h_mid = get_elevation_at(wx, wz)
		h_xp = get_elevation_at(wx + eps_x, wz)
		h_xm = get_elevation_at(wx - eps_x, wz)
		h_zp = get_elevation_at(wx, wz + eps_z)
		h_zm = get_elevation_at(wx, wz - eps_z)
		
	var dh_dx = (h_xp - h_xm) / (2.0 * eps_x)
	var dh_dz = (h_zp - h_zm) / (2.0 * eps_z)
	
	var gradient = Vector2(dh_dx, dh_dz)
	var normal = Vector3(-dh_dx, 1.0, -dh_dz).normalized()
	var slope_angle_rad = acos(clampf(normal.y, -1.0, 1.0))
	var slope_angle_deg = rad_to_deg(slope_angle_rad)
	
	return {
		"elevation": h_mid,
		"gradient": gradient,
		"gradient_magnitude": gradient.length(),
		"normal": normal,
		"slope_angle_deg": slope_angle_deg,
		"slope_angle_rad": slope_angle_rad
	}

# -----------------------------------------------------------------------------
# Coordinate Conversions & Bounds Checking
# -----------------------------------------------------------------------------

func world_to_grid(wx: float, wz: float) -> Vector2:
	var gx = (wx - world_origin.x) / cell_size.x
	var gy = (wz - world_origin.y) / cell_size.y
	return Vector2(gx, gy)

func grid_to_world(gx: float, gy: float) -> Vector2:
	var wx = world_origin.x + gx * cell_size.x
	var wz = world_origin.y + gy * cell_size.y
	return Vector2(wx, wz)

func is_in_bounds(wx: float, wz: float) -> bool:
	return (wx >= world_origin.x and wx <= world_origin.x + world_size.x and
			wz >= world_origin.y and wz <= world_origin.y + world_size.y)

func is_grid_in_bounds(gx: int, gy: int) -> bool:
	return gx >= 0 and gx < grid_resolution.x and gy >= 0 and gy < grid_resolution.y

func get_bounds_rect() -> Rect2:
	return Rect2(world_origin, world_size)

func get_cell_elevation(gx: int, gy: int, conditioned: bool = false) -> float:
	if not is_grid_in_bounds(gx, gy):
		return 0.0
	var idx = gy * grid_resolution.x + gx
	return conditioned_elevation_buffer[idx] if conditioned else raw_elevation_buffer[idx]

func set_cell_elevation(gx: int, gy: int, val: float, update_conditioned: bool = true) -> void:
	if not is_grid_in_bounds(gx, gy):
		return
	var idx = gy * grid_resolution.x + gx
	raw_elevation_buffer[idx] = val
	if update_conditioned:
		conditioned_elevation_buffer[idx] = maxf(conditioned_elevation_buffer[idx], val)

# -----------------------------------------------------------------------------
# Localized Region Modification
# -----------------------------------------------------------------------------

## Updates an AABB region of the raw elevation buffer without rebuilding the entire world.
## Modifies raw_elevation_buffer and keeps conditioned_elevation_buffer valid.
## Emits region_updated signal.
func update_elevation_region(region_rect: Rect2, elevation_modifier: Callable) -> int:
	var min_grid = world_to_grid(region_rect.position.x, region_rect.position.y)
	var max_grid = world_to_grid(region_rect.end.x, region_rect.end.y)
	
	var gx0 = clampi(int(floor(min_grid.x)), 0, grid_resolution.x - 1)
	var gy0 = clampi(int(floor(min_grid.y)), 0, grid_resolution.y - 1)
	var gx1 = clampi(int(ceil(max_grid.x)), 0, grid_resolution.x - 1)
	var gy1 = clampi(int(ceil(max_grid.y)), 0, grid_resolution.y - 1)
	
	var modified_count = 0
	var w = grid_resolution.x
	
	for gy in range(gy0, gy1 + 1):
		var row_offset = gy * w
		for gx in range(gx0, gx1 + 1):
			var idx = row_offset + gx
			var wpos = grid_to_world(float(gx), float(gy))
			var current_h = raw_elevation_buffer[idx]
			var new_h = float(elevation_modifier.call(wpos.x, wpos.y, current_h))
			
			if not is_equal_approx(current_h, new_h):
				raw_elevation_buffer[idx] = new_h
				# Conditioned elevation must never drop below raw elevation
				if conditioned_elevation_buffer[idx] < new_h:
					conditioned_elevation_buffer[idx] = new_h
				modified_count += 1
				
	if modified_count > 0:
		_update_elevation_metrics()
		invalidate_lakes()
		region_updated.emit(region_rect)
		
	return modified_count

## Recomputes the D8 flow direction, Priority-Flood conditioned elevation, and flow accumulation
## from the current raw_elevation_buffer using HydrologyEngine.
func recompute_hydrology() -> Dictionary:
	var temp_terrain = TerrainEngine.new(world_size, grid_resolution, world_origin)
	temp_terrain.heights = raw_elevation_buffer.duplicate()
	var hydro = HydrologyEngine.new(temp_terrain)
	var stats = hydro.resolve_hydrology()
	if hydro.filled_heights.size() == total_cells:
		conditioned_elevation_buffer = hydro.filled_heights.duplicate()
	if hydro.flow_directions.size() == total_cells:
		flow_direction_buffer = hydro.flow_directions.duplicate()
	if hydro.flow_accumulation.size() == total_cells:
		flow_accumulation_buffer = hydro.flow_accumulation.duplicate()
	_update_elevation_metrics()
	return stats

# -----------------------------------------------------------------------------
# Lake Basin Methods (Milestone 3)
# -----------------------------------------------------------------------------

## Recomputes lake basins using LakeBasinSolver and updates lake buffers.
func recompute_lakes(config: Dictionary = {}) -> Array[Dictionary]:
	lake_solver = LakeBasinSolver.new()
	detected_basins = lake_solver.solve(self, config)
	
	basin_id_buffer = lake_solver.basin_id_buffer.duplicate()
	lake_depth_buffer = lake_solver.lake_depth_buffer.duplicate()
	lake_elevation_buffer = lake_solver.lake_elevation_buffer.duplicate()
	
	if config.get("register_features", true) and feature_registry != null:
		lake_solver.register_lakes_in_feature_registry(feature_registry, config.get("connect_rivers", true))
		
	metadata["lake_basins_count"] = detected_basins.size()
	lakes_updated.emit()
	return detected_basins

## Invalidates and clears lake buffers when terrain is modified.
func invalidate_lakes() -> void:
	basin_id_buffer.fill(-1)
	lake_depth_buffer.fill(0.0)
	lake_elevation_buffer.fill(-999.0)
	detected_basins.clear()
	lakes_updated.emit()

## Returns the physical water depth of a lake at world coordinates (0.0 if on dry land).
func get_lake_depth_at(wx: float, wz: float) -> float:
	return _sample_buffer_bilinear(lake_depth_buffer, wx, wz)

## Returns the lake water surface elevation at world coordinates (-999.0 if on dry land).
func get_lake_elevation_at(wx: float, wz: float) -> float:
	var g = world_to_grid(wx, wz)
	var gx = clampi(int(round(g.x)), 0, grid_resolution.x - 1)
	var gy = clampi(int(round(g.y)), 0, grid_resolution.y - 1)
	return lake_elevation_buffer[gy * grid_resolution.x + gx]

## Returns whether world coordinates are inside a lake body.
func is_in_lake(wx: float, wz: float) -> bool:
	var g = world_to_grid(wx, wz)
	var gx = clampi(int(round(g.x)), 0, grid_resolution.x - 1)
	var gy = clampi(int(round(g.y)), 0, grid_resolution.y - 1)
	return basin_id_buffer[gy * grid_resolution.x + gx] >= 0

## Returns the basin dictionary record for the lake at world coordinates, or {} if on land.
func get_basin_at(wx: float, wz: float) -> Dictionary:
	var g = world_to_grid(wx, wz)
	var gx = clampi(int(round(g.x)), 0, grid_resolution.x - 1)
	var gy = clampi(int(round(g.y)), 0, grid_resolution.y - 1)
	var b_idx = basin_id_buffer[gy * grid_resolution.x + gx]
	if b_idx >= 0 and b_idx < detected_basins.size():
		return detected_basins[b_idx]
	return {}

# -----------------------------------------------------------------------------
# Diagnostic Image Exports
# -----------------------------------------------------------------------------

func export_raw_elevation_image() -> Image:
	var img = Image.create(grid_resolution.x, grid_resolution.y, false, Image.FORMAT_RF)
	for gy in range(grid_resolution.y):
		for gx in range(grid_resolution.x):
			var h = get_cell_elevation(gx, gy, false)
			img.set_pixel(gx, gy, Color(h, 0, 0, 1))
	return img

func export_depression_mask_image() -> Image:
	var img = Image.create(grid_resolution.x, grid_resolution.y, false, Image.FORMAT_RGBA8)
	for gy in range(grid_resolution.y):
		for gx in range(grid_resolution.x):
			var raw_h = get_cell_elevation(gx, gy, false)
			var cond_h = get_cell_elevation(gx, gy, true)
			var depth = maxf(0.0, cond_h - raw_h)
			if depth > 0.05:
				var t = clampf(depth / 10.0, 0.0, 1.0)
				img.set_pixel(gx, gy, Color(0.1, 0.3 + t * 0.7, 1.0, 1.0))
			else:
				img.set_pixel(gx, gy, Color(0.05, 0.05, 0.05, 1.0))
	return img

