# SatelliteMapRenderer.gd
class_name SatelliteMapRenderer
extends RefCounted

## Generates a satellite-style aerial terrain ImageTexture directly from the actual
## ForestBlueprint elevation, hydrology, snow-cap, biome, and vegetation data in ~50ms.
static func render(blueprint: ForestBlueprint, res: int = 180, world_min: Vector2 = Vector2(-200.0, -200.0), world_max: Vector2 = Vector2(200.0, 200.0), show_contours: bool = true) -> ImageTexture:
	if blueprint == null:
		blueprint = ForestBlueprint.create_default()
		
	var total_pixels = res * res
	var height_grid = PackedFloat32Array()
	height_grid.resize(total_pixels)
	
	# River proximity mask:
	# > 1.0 = inside waterfall foam
	# 0.0 .. 1.0 = inside river channel (0.01 = center, 1.0 = bank edge)
	# -1.0 = riparian riverbank zone
	# -2.0 = not near river
	var river_grid = PackedFloat32Array()
	river_grid.resize(total_pixels)
	river_grid.fill(-2.0)
	
	var base_noise = FastNoiseLite.new()
	base_noise.seed = (blueprint.world_seed + 35) % 100000
	base_noise.frequency = 0.008
	
	var detail_noise = FastNoiseLite.new()
	detail_noise.seed = (blueprint.world_seed + 90) % 100000
	detail_noise.frequency = 0.022
	
	var flora_noise = FastNoiseLite.new()
	flora_noise.seed = (blueprint.world_seed + 1337) % 100000
	flora_noise.frequency = 0.035
	
	var span_x = world_max.x - world_min.x
	var span_z = world_max.y - world_min.y
	var inv_span_x = float(res - 1) / span_x
	var inv_span_z = float(res - 1) / span_z
	var world_per_px = span_x / float(res - 1)
	
	# Fast Raster Pass for Rivers & Waterfalls: O(spline_points) instead of O(pixels * spline_points)
	for r in blueprint.rivers:
		var pts: PackedVector2Array = r.get("spline_points", r.get("points", PackedVector2Array()))
		var half_w = maxf(float(r.get("width", 8.0)) * 0.5, 2.4)
		var bank_w = half_w * 2.4
		var px_rad = ceili(bank_w / world_per_px) + 1
		
		for pt in pts:
			var c_px = int((pt.x - world_min.x) * inv_span_x)
			var c_py = int((pt.y - world_min.y) * inv_span_z)
			var y0 = maxi(0, c_py - px_rad)
			var y1 = mini(res - 1, c_py + px_rad)
			var x0 = maxi(0, c_px - px_rad)
			var x1 = mini(res - 1, c_px + px_rad)
			
			for py in range(y0, y1 + 1):
				var wz = world_min.y + float(py) * world_per_px
				var dy = wz - pt.y
				var row_off = py * res
				for px in range(x0, x1 + 1):
					var wx = world_min.x + float(px) * world_per_px
					var dx = wx - pt.x
					var d = sqrt(dx * dx + dy * dy)
					var cell_idx = row_off + px
					if d <= half_w:
						var norm_d = clampf(d / half_w, 0.01, 0.99)
						var cur = river_grid[cell_idx]
						if cur < 0.0 or norm_d < cur:
							river_grid[cell_idx] = norm_d
					elif d <= bank_w and river_grid[cell_idx] < -1.5:
						river_grid[cell_idx] = -1.0
						
		for wf in r.get("waterfalls", []):
			var wf_pos: Vector2 = wf.get("pos", Vector2.ZERO)
			var wf_rad = half_w * 1.6
			var wf_px_rad = ceili(wf_rad / world_per_px) + 1
			var c_px = int((wf_pos.x - world_min.x) * inv_span_x)
			var c_py = int((wf_pos.y - world_min.y) * inv_span_z)
			for py in range(maxi(0, c_py - wf_px_rad), mini(res - 1, c_py + wf_px_rad) + 1):
				var wz = world_min.y + float(py) * world_per_px
				for px in range(maxi(0, c_px - wf_px_rad), mini(res - 1, c_px + wf_px_rad) + 1):
					var wx = world_min.x + float(px) * world_per_px
					if Vector2(wx, wz).distance_to(wf_pos) <= wf_rad:
						river_grid[py * res + px] = 2.0

	# Pass 1: Compute true elevation grid (including mountains, lakes, and riverbeds)
	for py in range(res):
		var wz = world_min.y + float(py) * world_per_px
		var row_offset = py * res
		for px in range(res):
			var wx = world_min.x + float(px) * world_per_px
			var n_base = base_noise.get_noise_2d(wx, wz)
			var n_det = maxf(0.0, detail_noise.get_noise_2d(wx, wz))
			var h = 6.0 + n_base * blueprint.continent_slope_scale + n_det * (blueprint.mountain_scale * 0.35)
			
			var pos2 = Vector2(wx, wz)
			for m in blueprint.mountains:
				var dist = pos2.distance_to(m.pos)
				var rad = float(m.radius)
				if dist < rad:
					h += float(m.height) * 0.5 * (1.0 + cos(PI * (dist / rad)))
					
			for l in blueprint.lakes:
				var dist = pos2.distance_to(l.center)
				var rad = float(l.radius)
				if dist < rad:
					var factor = 1.0 - (dist / rad)
					h = minf(h, float(l.water_level) - factor * factor * 9.0)
					
			var r_val = river_grid[row_offset + px]
			if r_val > 0.0 and r_val <= 1.0:
				h -= 3.5 * (1.0 - r_val)
			height_grid[row_offset + px] = h
			
	# Pass 2: Shade terrain, rivers, vegetation canopy, snow caps, and contours into RGB8 buffer
	var rgb_bytes = PackedByteArray()
	rgb_bytes.resize(total_pixels * 3)
	
	var south_snow = bool(blueprint.regional_snow.get("south", false))
	var north_snow = bool(blueprint.regional_snow.get("north", false))
	var east_snow = bool(blueprint.regional_snow.get("east", false))
	var west_snow = bool(blueprint.regional_snow.get("west", false))
	
	for py in range(res):
		var wz = world_min.y + float(py) * world_per_px
		var row_offset = py * res
		var py_up = maxi(0, py - 1) * res
		var py_dn = mini(res - 1, py + 1) * res
		
		for px in range(res):
			var wx = world_min.x + float(px) * world_per_px
			var pos2 = Vector2(wx, wz)
			var idx = row_offset + px
			var h = height_grid[idx]
			
			# Directional NW Hillshading
			var h_L = height_grid[row_offset + maxi(0, px - 1)]
			var h_R = height_grid[row_offset + mini(res - 1, px + 1)]
			var h_U = height_grid[py_up + px]
			var h_D = height_grid[py_dn + px]
			var dx = h_R - h_L
			var dy = h_D - h_U
			var shade = clampf(1.0 - (dx * 0.045 + dy * 0.045), 0.42, 1.38)
			
			var r_val = river_grid[idx]
			var is_waterfall = r_val > 1.5
			var is_river = r_val > 0.0 and r_val <= 1.5
			var is_riverbank = r_val == -1.0
			
			var is_lake = false
			for l in blueprint.lakes:
				if pos2.distance_to(l.center) <= float(l.radius):
					is_lake = true
					break
					
			var col = Color(0.18, 0.42, 0.22)
			
			if is_waterfall:
				col = Color(0.88, 0.96, 1.0)
			elif is_river or is_lake or h < -2.0:
				var depth_t = r_val if is_river else 0.2
				col = Color(0.08, 0.34, 0.68).lerp(Color(0.22, 0.58, 0.88), depth_t * 0.65)
			else:
				if h < 5.0:
					col = Color(0.36, 0.52, 0.26)
				elif h < 20.0:
					col = Color(0.22, 0.46, 0.22)
				elif h < 34.0:
					var rt = (h - 20.0) / 14.0
					col = Color(0.22, 0.46, 0.22).lerp(Color(0.46, 0.45, 0.42), rt)
				else:
					col = Color(0.50, 0.49, 0.46)
					
				for b in blueprint.biome_regions:
					var b_dist = pos2.distance_to(b.center)
					var b_rad = float(b.radius)
					if b_dist < b_rad:
						var b_w = clampf(1.0 - (b_dist / b_rad), 0.0, 1.0) * 0.55
						var b_tint: Color = b.get("ground_tint", Color(0.2, 0.6, 0.2))
						col = col.lerp(b_tint, b_w)
						
				var is_snow = (south_snow and wz > 25.0) or (north_snow and wz < -25.0) or (east_snow and wx > 25.0) or (west_snow and wx < -25.0)
				var is_cleared = false
				for m in blueprint.mountains:
					var md = pos2.distance_to(m.pos)
					var mrad = float(m.radius)
					if not is_snow and m.get("snow_cap", false) and md < mrad * 0.48 and h > 25.0:
						is_snow = true
					if m.get("flora_cleared", false) and md < mrad * 1.15:
						is_cleared = true
						
				if is_snow:
					col = Color(0.92, 0.95, 0.99)
				else:
					if not is_cleared and h > 1.5 and h < 30.0:
						var fn = flora_noise.get_noise_2d(wx * 1.4, wz * 1.4)
						if is_riverbank:
							col = col.lerp(Color(0.10, 0.38, 0.16), 0.55)
						elif fn > -0.05:
							var canopy_dark = Color(0.11, 0.32, 0.14)
							col = col.lerp(canopy_dark, clampf((fn + 0.05) * 0.85, 0.15, 0.65))
					elif is_cleared and h > 14.0:
						col = col.lerp(Color(0.55, 0.50, 0.44), 0.65)
						
				if show_contours:
					var contour_mod = fposmod(h, 12.0)
					if contour_mod < 0.55 and (abs(dx) + abs(dy)) > 0.35:
						shade *= 0.86
						
				col = Color(
					clampf(col.r * shade, 0.0, 1.0),
					clampf(col.g * shade, 0.0, 1.0),
					clampf(col.b * shade, 0.0, 1.0)
				)
				
			var byte_idx = idx * 3
			rgb_bytes[byte_idx] = int(col.r * 255.0)
			rgb_bytes[byte_idx + 1] = int(col.g * 255.0)
			rgb_bytes[byte_idx + 2] = int(col.b * 255.0)
			
	var img = Image.create_from_data(res, res, false, Image.FORMAT_RGB8, rgb_bytes)
	return ImageTexture.create_from_image(img)
