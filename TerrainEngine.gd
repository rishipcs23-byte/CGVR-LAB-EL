# TerrainEngine.gd
# Deterministic 1-4 km² heightmap terrain engine for SublimeGreens Milestone 1.
# Independent of visual mesh generation and UI.
class_name TerrainEngine
extends RefCounted

# Spatial bounds configuration
var world_size: Vector2 = Vector2(1000.0, 1000.0) # 1 km x 1 km
var world_origin: Vector2 = Vector2(-500.0, -500.0) # Centered at (0, 0) -> [-500, 500]
var grid_resolution: Vector2i = Vector2i(256, 256)

# Internal grid dimensions and cell spacing
var cell_size: Vector2 = Vector2.ZERO
var heights: PackedFloat32Array = PackedFloat32Array()

# Generation parameters
var current_seed: int = 42
var base_elevation: float = 8.0
var macro_gradient: Vector2 = Vector2(0.0, -0.05) # Regional North-to-South tilt (-50m over 1000m)
var mountain_peaks: Array = []

func _init(p_size: Vector2 = Vector2(1000.0, 1000.0), p_res: Vector2i = Vector2i(256, 256), p_origin: Vector2 = Vector2(-500.0, -500.0)) -> void:
	world_size = p_size
	grid_resolution = p_res
	world_origin = p_origin
	_update_cell_metrics()

func _update_cell_metrics() -> void:
	var denom_x = max(1, grid_resolution.x - 1)
	var denom_y = max(1, grid_resolution.y - 1)
	cell_size = Vector2(world_size.x / float(denom_x), world_size.y / float(denom_y))

# -----------------------------------------------------------------------------
# Terrain Generation
# -----------------------------------------------------------------------------

func generate(p_seed: int = 42, p_config: Dictionary = {}) -> void:
	current_seed = p_seed
	_update_cell_metrics()
	
	if p_config.has("world_size"):
		world_size = p_config["world_size"]
	if p_config.has("grid_resolution"):
		grid_resolution = p_config["grid_resolution"]
	if p_config.has("world_origin"):
		world_origin = p_config["world_origin"]
	_update_cell_metrics()
	
	if p_config.has("base_elevation"):
		base_elevation = p_config["base_elevation"]
	if p_config.has("macro_gradient"):
		macro_gradient = p_config["macro_gradient"]
		
	mountain_peaks.clear()
	if p_config.has("mountain_peaks"):
		for peak in p_config["mountain_peaks"]:
			if peak is Dictionary:
				mountain_peaks.append(peak.duplicate(true))
	else:
		# Default: Place one prominent mountain massif in the North-West
		# Coordinates within [-500, 500] domain
		mountain_peaks.append({
			"center": Vector2(-200.0, -250.0),
			"peak_height": 140.0,
			"radius": 240.0,
			"ridge_sharpness": 1.8
		})
	
	# Setup deterministic FastNoiseLite instances
	var base_noise = FastNoiseLite.new()
	base_noise.seed = current_seed
	base_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	base_noise.frequency = 0.0018
	base_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	base_noise.fractal_octaves = 4
	base_noise.fractal_lacunarity = 2.0
	base_noise.fractal_gain = 0.5
	
	var detail_noise = FastNoiseLite.new()
	detail_noise.seed = current_seed + 101
	detail_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	detail_noise.frequency = 0.008
	detail_noise.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	detail_noise.fractal_octaves = 3
	detail_noise.fractal_gain = 0.4
	
	var total_cells = grid_resolution.x * grid_resolution.y
	heights.resize(total_cells)
	
	var gx_max = grid_resolution.x
	var gy_max = grid_resolution.y
	
	for gy in range(gy_max):
		var wy = world_origin.y + float(gy) * cell_size.y
		var row_offset = gy * gx_max
		
		# Regional slope contribution: North (wy=-500) is elevated, South (wy=+500) slopes to sea level
		# macro_gradient.y is negative, so (-wy * gradient) creates high North, low South
		var slope_elev = -wy * macro_gradient.y
		
		for gx in range(gx_max):
			var wx = world_origin.x + float(gx) * cell_size.x
			
			# 1. Base continental relief
			var n_val = base_noise.get_noise_2d(wx, wy) # [-1, 1]
			var d_val = detail_noise.get_noise_2d(wx, wy)
			
			var h = base_elevation + slope_elev + (n_val * 18.0) + (d_val * 5.0)
			
			# 2. Add mountain massifs with realistic radial power falloff and ridge texture
			for peak in mountain_peaks:
				var m_center: Vector2 = peak.get("center", Vector2.ZERO)
				var m_height: float = peak.get("peak_height", 120.0)
				var m_radius: float = peak.get("radius", 200.0)
				var m_sharp: float = peak.get("ridge_sharpness", 2.0)
				
				var dist = (Vector2(wx, wy) - m_center).length()
				if dist < m_radius:
					var norm_dist = dist / m_radius
					# Hermite / cosine power falloff: smooth at boundary, peaked at summit
					var falloff = pow(cos(norm_dist * PI * 0.5), m_sharp)
					
					# High-frequency ridge modulation along peak
					var ridge_mod = 0.85 + 0.15 * cos(dist * 0.08 + detail_noise.get_noise_2d(wx * 2.0, wy * 2.0) * 3.0)
					h += m_height * falloff * ridge_mod
			
			# Prevent negative ocean basins in standard inland terrain
			if h < 1.0:
				h = 1.0
				
			heights[row_offset + gx] = h

# -----------------------------------------------------------------------------
# Grid & Height Sampling
# -----------------------------------------------------------------------------

func get_height_at_cell(gx: int, gy: int) -> float:
	if gx < 0 or gx >= grid_resolution.x or gy < 0 or gy >= grid_resolution.y:
		return 0.0
	return heights[gy * grid_resolution.x + gx]

func set_height_at_cell(gx: int, gy: int, val: float) -> void:
	if gx < 0 or gx >= grid_resolution.x or gy < 0 or gy >= grid_resolution.y:
		return
	heights[gy * grid_resolution.x + gx] = val

func sample_height(wx: float, wz: float) -> float:
	var gx_f = (wx - world_origin.x) / cell_size.x
	var gy_f = (wz - world_origin.y) / cell_size.y
	
	var gx0 = clampi(int(floor(gx_f)), 0, grid_resolution.x - 1)
	var gy0 = clampi(int(floor(gy_f)), 0, grid_resolution.y - 1)
	var gx1 = mini(gx0 + 1, grid_resolution.x - 1)
	var gy1 = mini(gy0 + 1, grid_resolution.y - 1)
	
	var tx = clampf(gx_f - float(gx0), 0.0, 1.0)
	var ty = clampf(gy_f - float(gy0), 0.0, 1.0)
	
	var w = grid_resolution.x
	var h00 = heights[gy0 * w + gx0]
	var h10 = heights[gy0 * w + gx1]
	var h01 = heights[gy1 * w + gx0]
	var h11 = heights[gy1 * w + gx1]
	
	var h_top = lerpf(h00, h10, tx)
	var h_bot = lerpf(h01, h11, tx)
	return lerpf(h_top, h_bot, ty)

func get_slope_and_gradient(wx: float, wz: float) -> Dictionary:
	var eps_x = cell_size.x * 0.5
	var eps_z = cell_size.y * 0.5
	
	var h_mid = sample_height(wx, wz)
	var h_xp = sample_height(wx + eps_x, wz)
	var h_xm = sample_height(wx - eps_x, wz)
	var h_zp = sample_height(wx, wz + eps_z)
	var h_zm = sample_height(wx, wz - eps_z)
	
	var dh_dx = (h_xp - h_xm) / (2.0 * eps_x)
	var dh_dz = (h_zp - h_zm) / (2.0 * eps_z)
	
	var gradient = Vector2(dh_dx, dh_dz)
	var grad_mag = gradient.length()
	var normal = Vector3(-dh_dx, 1.0, -dh_dz).normalized()
	var slope_angle_rad = acos(clampf(normal.y, -1.0, 1.0))
	var slope_angle_deg = rad_to_deg(slope_angle_rad)
	
	return {
		"elevation": h_mid,
		"gradient": gradient,
		"gradient_magnitude": grad_mag,
		"normal": normal,
		"slope_angle_deg": slope_angle_deg,
		"slope_angle_rad": slope_angle_rad
	}

# -----------------------------------------------------------------------------
# Coordinate Conversions
# -----------------------------------------------------------------------------

func world_to_grid(wx: float, wz: float) -> Vector2:
	var gx = (wx - world_origin.x) / cell_size.x
	var gy = (wz - world_origin.y) / cell_size.y
	return Vector2(gx, gy)

func grid_to_world(gx: float, gy: float) -> Vector2:
	var wx = world_origin.x + gx * cell_size.x
	var wz = world_origin.y + gy * cell_size.y
	return Vector2(wx, wz)

func cell_to_world_3d(gx: int, gy: int) -> Vector3:
	var pos2d = grid_to_world(float(gx), float(gy))
	var h = get_height_at_cell(gx, gy)
	return Vector3(pos2d.x, h, pos2d.y)

func is_in_bounds(wx: float, wz: float) -> bool:
	return (wx >= world_origin.x and wx <= world_origin.x + world_size.x and
			wz >= world_origin.y and wz <= world_origin.y + world_size.y)

func is_grid_in_bounds(gx: int, gy: int) -> bool:
	return gx >= 0 and gx < grid_resolution.x and gy >= 0 and gy < grid_resolution.y

func get_min_max_height() -> Vector2:
	if heights.is_empty():
		return Vector2.ZERO
	var min_h = heights[0]
	var max_h = heights[0]
	for h in heights:
		if h < min_h: min_h = h
		if h > max_h: max_h = h
	return Vector2(min_h, max_h)

# -----------------------------------------------------------------------------
# Heightmap Export
# -----------------------------------------------------------------------------

func export_heightmap_image() -> Image:
	var img = Image.create(grid_resolution.x, grid_resolution.y, false, Image.FORMAT_RF)
	var mm = get_min_max_height()
	var range_h = max(0.001, mm.y - mm.x)
	
	for gy in range(grid_resolution.y):
		for gx in range(grid_resolution.x):
			var h = get_height_at_cell(gx, gy)
			# Store exact raw height or normalized float
			img.set_pixel(gx, gy, Color(h, 0.0, 0.0, 1.0))
	return img
