# ForestBlueprint.gd
class_name ForestBlueprint
extends RefCounted

class FloraLayerConfig:
	var archetype: String = "canopy_tree" # canopy_tree, small_tree, shrub, fern, flower, ground_cover, fallen_log
	var name: String = "Canopy Tree"
	var distribution: String = "clustered" # clustered, scattered, edge_dense, clearing_centered, riverbank_focused
	var density: float = 0.008
	var scale_min: float = 1.0
	var scale_max: float = 1.8
	var trunk_color: Color = Color("saddlebrown")
	var foliage_color: Color = Color("forestgreen")
	var emissive: bool = false
	var emissive_color: Color = Color.BLACK
	var emissive_energy: float = 0.0
	var min_height: float = 1.0
	var max_height: float = 55.0
	var max_slope_normal_y: float = 0.82
	var target_biome_id: String = ""
	var near_water_only: bool = false

	func duplicate() -> FloraLayerConfig:
		var cfg = FloraLayerConfig.new()
		cfg.archetype = archetype
		cfg.name = name
		cfg.distribution = distribution
		cfg.density = density
		cfg.scale_min = scale_min
		cfg.scale_max = scale_max
		cfg.trunk_color = trunk_color
		cfg.foliage_color = foliage_color
		cfg.emissive = emissive
		cfg.emissive_color = emissive_color
		cfg.emissive_energy = emissive_energy
		cfg.min_height = min_height
		cfg.max_height = max_height
		cfg.max_slope_normal_y = max_slope_normal_y
		cfg.target_biome_id = target_biome_id
		cfg.near_water_only = near_water_only
		return cfg


# --- Core Global Settings ---
var version: int = 4
var theme: String = "Temperate Wilderness"
var terrain_type: String = "rolling" # rolling, mountainous, peaks, valleys, canyon, flat, alpine
var special_event: String = "none" # floating_spores, crystal_rain, fireflies, cosmic_dust, embers, none
var world_seed: int = 42

# --- Atmosphere & Lighting ---
var sky_top_color: Color = Color(0.38, 0.45, 0.55)
var sky_horizon_color: Color = Color(0.66, 0.67, 0.69)
var ground_bottom_color: Color = Color(0.2, 0.17, 0.13)
var ground_horizon_color: Color = Color(0.66, 0.67, 0.69)
var light_color: Color = Color(1.0, 0.96, 0.88)
var light_energy: float = 1.0
var fog_density: float = 0.0015
var fog_color: Color = Color(0.66, 0.67, 0.69)
var glow_intensity: float = 0.25

# --- Terrain Shape Scales ---
var mountain_scale: float = 40.0
var continent_max_height: float = 25.0
var continent_slope_scale: float = 8.0
var valley_carve_scale: float = 15.0
var terrain_tint: Color = Color(1.0, 1.0, 1.0)

# --- Regional Climate Modifiers ---
# e.g. "southern snowy": dictionary with { "south": true, "snow": true }
var regional_snow: Dictionary = {"south": false, "north": false, "west": false, "east": false}

# --- Structured World Blueprint & Feature Registry ---
var requirements: Dictionary = {}
var feature_registry: Dictionary = {
	"mountains": {},
	"mountain_ranges": {},
	"rivers": {},
	"lakes": {},
	"waterfalls": {},
	"biome_regions": {},
	"vegetation_layers": {}
}

# --- Discrete Structural Landforms ---
# Mountains: Array of Dictionary { id, name, pos: Vector2, height: float, radius: float, snow_cap: bool, flora_cleared: bool }
var mountains: Array = []
# Mountain Ranges: Array of Dictionary { id, name, peak_ids: Array[String] }
var mountain_ranges: Array = []

# --- Hydrology ---
# Rivers: Array of Dictionary { id, name, points, spline_points, distances, total_length, width, depth, flow_speed, spring_sources, confluences, waterfalls }
var rivers: Array = []
# Lakes: Array of Dictionary { id, name, center: Vector2, radius: float, water_level: float }
var lakes: Array = []

# --- Biome Regions ---
# Biome Regions: Array of Dictionary { id, name, center: Vector2, radius: float, ground_tint: Color, foliage_color: Color, boost: float }
var biome_regions: Array = []

# --- Landmarks ---
# Landmarks: Array of Dictionary { id, name, pos: Vector2, type: String }
var landmarks: Array = []

# --- Flora Layers ---
var vegetation_layers: Array = []

# Legacy compatibility accessors
var tree_density: float = 0.008
var tree_scale_min: float = 1.0
var tree_scale_max: float = 1.8
var tree_trunk_color: Color = Color("saddlebrown")
var tree_leaves_color: Color = Color("forestgreen")
var tree_emissive_color: Color = Color.BLACK
var tree_emissive_energy: float = 0.0
var grass_density: float = 0.3
var grass_scale_min: float = 1.5
var grass_scale_max: float = 2.4
var grass_color: Color = Color(0.0, 0.55, 0.31)

var raw_data: Dictionary = {}


func sync_feature_registry() -> void:
	feature_registry["mountains"].clear()
	for m in mountains:
		var m_id = str(m.get("id", "mtn_%d" % (feature_registry["mountains"].size() + 1)))
		m["id"] = m_id
		m["type"] = "mountain"
		m["status"] = m.get("status", "verified")
		feature_registry["mountains"][m_id] = m
		
	feature_registry["mountain_ranges"].clear()
	for mr in mountain_ranges:
		var mr_id = str(mr.get("id", "range_%d" % (feature_registry["mountain_ranges"].size() + 1)))
		mr["id"] = mr_id
		mr["type"] = "mountain_range"
		mr["status"] = mr.get("status", "verified")
		feature_registry["mountain_ranges"][mr_id] = mr
		
	feature_registry["rivers"].clear()
	for r in rivers:
		var r_id = str(r.get("id", "river_%d" % (feature_registry["rivers"].size() + 1)))
		r["id"] = r_id
		r["type"] = "river"
		r["status"] = r.get("status", "verified")
		feature_registry["rivers"][r_id] = r
		
	feature_registry["lakes"].clear()
	for l in lakes:
		var l_id = str(l.get("id", "lake_%d" % (feature_registry["lakes"].size() + 1)))
		l["id"] = l_id
		l["type"] = "lake"
		l["status"] = l.get("status", "verified")
		feature_registry["lakes"][l_id] = l
		
	feature_registry["waterfalls"].clear()
	for r in rivers:
		for wf in r.get("waterfalls", []):
			var wf_id = str(wf.get("id", "wf_%d" % (feature_registry["waterfalls"].size() + 1)))
			wf["id"] = wf_id
			wf["type"] = "waterfall"
			wf["status"] = wf.get("status", "verified")
			feature_registry["waterfalls"][wf_id] = wf
			
	feature_registry["biome_regions"].clear()
	for b in biome_regions:
		var b_id = str(b.get("id", "biome_%d" % (feature_registry["biome_regions"].size() + 1)))
		b["id"] = b_id
		b["type"] = "biome"
		b["status"] = b.get("status", "verified")
		feature_registry["biome_regions"][b_id] = b


func to_dict() -> Dictionary:
	var feat_list: Array = []
	for m in mountains:
		feat_list.append({
			"id": m.get("id", ""),
			"type": "mountain",
			"name": m.get("name", "Mountain"),
			"pos": [m.pos.x, m.pos.y],
			"height": m.get("height", 50.0),
			"radius": m.get("radius", 65.0),
			"snow_cap": m.get("snow_cap", false),
			"status": m.get("status", "verified")
		})
	for r in rivers:
		var pts_arr = []
		for p in r.get("points", []):
			pts_arr.append([p.x, p.y])
		feat_list.append({
			"id": r.get("id", ""),
			"type": "river",
			"name": r.get("name", "River"),
			"points": pts_arr,
			"width": r.get("width", 8.0),
			"depth": r.get("depth", 4.0),
			"flow_speed": r.get("flow_speed", 0.65),
			"waterfalls": r.get("waterfalls", []),
			"status": r.get("status", "verified")
		})
	for l in lakes:
		feat_list.append({
			"id": l.get("id", ""),
			"type": "lake",
			"name": l.get("name", "Lake"),
			"center": [l.center.x, l.center.y],
			"radius": l.get("radius", 30.0),
			"water_level": l.get("water_level", -1.5),
			"status": l.get("status", "verified")
		})
	return {
		"theme": theme,
		"terrain": terrain_type,
		"requirements": requirements,
		"features": feat_list,
		"mountains": mountains,
		"mountain_ranges": mountain_ranges,
		"rivers": rivers,
		"lakes": lakes,
		"biome_regions": biome_regions,
		"regional_snow": regional_snow
	}


static func create_default() -> ForestBlueprint:
	var bp = ForestBlueprint.new()
	bp.world_seed = 42
	_populate_default_structures(bp)
	_populate_default_layers_for_theme(bp)
	bp.sync_feature_registry()
	return bp


static func parse_color(val, default_color: Color) -> Color:
	if val is Color:
		return val
	if not (val is String):
		return default_color
	
	var s: String = (val as String).strip_edges().to_lower()
	if s.is_empty():
		return default_color
		
	var named_colors: Dictionary = {
		"violet": Color(0.58, 0.0, 0.83),
		"purple": Color(0.63, 0.13, 0.94),
		"cyan": Color(0.0, 0.9, 0.9),
		"magenta": Color(1.0, 0.0, 1.0),
		"neon blue": Color(0.1, 0.5, 1.0),
		"light blue": Color(0.4, 0.7, 1.0),
		"deep blue": Color(0.05, 0.1, 0.4),
		"blue": Color(0.2, 0.4, 0.9),
		"turquoise": Color(0.25, 0.88, 0.82),
		"teal": Color(0.0, 0.5, 0.5),
		"emerald": Color(0.31, 0.78, 0.47),
		"forest green": Color(0.13, 0.55, 0.13),
		"green": Color(0.1, 0.75, 0.2),
		"neon green": Color(0.2, 1.0, 0.2),
		"lime": Color(0.75, 1.0, 0.0),
		"lime green": Color(0.6, 0.9, 0.1),
		"olive": Color(0.45, 0.55, 0.2),
		"crimson": Color(0.86, 0.08, 0.24),
		"red": Color(0.9, 0.15, 0.15),
		"orange": Color(1.0, 0.5, 0.0),
		"amber": Color(1.0, 0.75, 0.0),
		"gold": Color(1.0, 0.84, 0.0),
		"golden": Color(1.0, 0.84, 0.0),
		"pale gold": Color(0.95, 0.9, 0.7),
		"yellow": Color(1.0, 0.95, 0.2),
		"pink": Color(1.0, 0.4, 0.7),
		"rose": Color(1.0, 0.25, 0.5),
		"lavender": Color(0.8, 0.6, 1.0),
		"lilac": Color(0.78, 0.64, 0.88),
		"white": Color(1.0, 1.0, 1.0),
		"silver": Color(0.75, 0.75, 0.8),
		"gray": Color(0.5, 0.5, 0.5),
		"light gray": Color(0.7, 0.7, 0.7),
		"dark gray": Color(0.25, 0.25, 0.25),
		"dark slate gray": Color(0.18, 0.22, 0.25),
		"black": Color(0.05, 0.05, 0.05),
		"brown": Color("saddlebrown"),
		"dark brown": Color(0.22, 0.12, 0.05),
		"dark violet": Color(0.35, 0.0, 0.5),
		"blood red": Color(0.6, 0.0, 0.0),
		"coral": Color(1.0, 0.5, 0.31),
		"peach": Color(1.0, 0.85, 0.7)
	}
	
	if named_colors.has(s):
		return named_colors[s]
		
	for k in named_colors.keys():
		if k in s:
			return named_colors[k]
			
	if s.begins_with("#") or (s.length() in [3, 6, 8] and s.is_valid_hex_number(false)):
		var hex_str = s if s.begins_with("#") else ("#" + s)
		return Color.from_string(hex_str, default_color)
		
	return default_color


static func from_json(dict: Dictionary) -> ForestBlueprint:
	var bp = ForestBlueprint.new()
	bp.raw_data = dict
	
	if dict.has("seed"):
		bp.world_seed = int(dict["seed"])
	else:
		bp.world_seed = 42 + (hash(str(dict.get("theme", ""))) % 99991)
	
	if dict.has("theme"):
		bp.theme = str(dict["theme"])
		
	# Atmosphere
	if dict.has("sky_color"):
		var col = parse_color(dict["sky_color"], bp.sky_top_color)
		bp.sky_top_color = col
		bp.sky_horizon_color = col.lerp(Color.WHITE, 0.35)
		bp.fog_color = col.lerp(Color.WHITE, 0.25)
		
	if dict.has("horizon_color"):
		bp.sky_horizon_color = parse_color(dict["horizon_color"], bp.sky_horizon_color)
		
	if dict.has("fog_color"):
		bp.fog_color = parse_color(dict["fog_color"], bp.fog_color)
		
	if dict.has("fog_density"):
		var fd = float(dict["fog_density"])
		if fd > 0.1:
			bp.fog_density = clampf(fd * 0.03, 0.001, 0.05)
		else:
			bp.fog_density = clampf(fd, 0.0005, 0.05)
			
	if dict.has("light_color"):
		bp.light_color = parse_color(dict["light_color"], bp.light_color)
		
	if dict.has("light_energy"):
		bp.light_energy = clampf(float(dict["light_energy"]), 0.1, 2.5)
			
	if dict.has("terrain"):
		bp.terrain_type = str(dict["terrain"]).to_lower()
	elif dict.has("terrain_type"):
		bp.terrain_type = str(dict["terrain_type"]).to_lower()
		
	if "mountain" in bp.terrain_type or "peak" in bp.terrain_type or "alpine" in bp.terrain_type:
		bp.mountain_scale = 70.0
		bp.continent_max_height = 35.0
		bp.continent_slope_scale = 12.0
	elif "valley" in bp.terrain_type or "canyon" in bp.terrain_type:
		bp.mountain_scale = 35.0
		bp.valley_carve_scale = 30.0
		bp.continent_max_height = 20.0
	elif "flat" in bp.terrain_type or "plain" in bp.terrain_type:
		bp.mountain_scale = 10.0
		bp.continent_max_height = 10.0
		bp.continent_slope_scale = 4.0
	else:
		bp.mountain_scale = 40.0
		bp.continent_max_height = 22.0
		bp.continent_slope_scale = 8.0
		
	if dict.has("terrain_tint"):
		bp.terrain_tint = parse_color(dict["terrain_tint"], Color.WHITE)
		
	# Parse Explicit Requirements
	if dict.has("requirements") and dict["requirements"] is Dictionary:
		bp.requirements = dict["requirements"].duplicate(true)

	# Parse Structured Features List if present
	if dict.has("features") and dict["features"] is Array:
		for f in dict["features"]:
			if not (f is Dictionary):
				continue
			var f_type = str(f.get("type", "")).to_lower().strip_edges()
			var f_id = str(f.get("id", ""))
			var f_name = str(f.get("name", f_type.capitalize()))
			var f_status = str(f.get("status", "planned"))
			
			match f_type:
				"mountain":
					var mx = 0.0
					var mz = 0.0
					if f.has("pos") and f["pos"] is Array and f["pos"].size() >= 2:
						mx = float(f["pos"][0])
						mz = float(f["pos"][1])
					elif f.has("coordinates") and f["coordinates"] is Array and f["coordinates"].size() >= 2:
						mx = float(f["coordinates"][0])
						mz = float(f["coordinates"][1])
					else:
						mx = float(f.get("x", 0.0))
						mz = float(f.get("z", 0.0))
					var mh = clampf(float(f.get("height", 55.0)), 15.0, 120.0)
					var mr = clampf(float(f.get("radius", 65.0)), 20.0, 160.0)
					var sc = bool(f.get("snow_cap", mh > 40.0))
					bp.mountains.append({
						"id": f_id if not f_id.is_empty() else "mtn_%d" % (bp.mountains.size() + 1),
						"name": f_name,
						"pos": Vector2(mx, mz),
						"height": mh,
						"radius": mr,
						"snow_cap": sc,
						"flora_cleared": bool(f.get("flora_cleared", false)),
						"status": f_status
					})
				"river":
					var pts = PackedVector2Array()
					if f.has("points"):
						if f["points"] is PackedVector2Array:
							pts = f["points"]
						elif f["points"] is Array:
							for p in f["points"]:
								if p is Vector2:
									pts.append(p)
								elif p is Array and p.size() >= 2:
									pts.append(Vector2(float(p[0]), float(p[1])))
								elif p is Dictionary:
									pts.append(Vector2(float(p.get("x", 0.0)), float(p.get("z", 0.0))))
					var rw = clampf(float(f.get("width", 8.0)), 3.0, 25.0)
					var rd = clampf(float(f.get("depth", 4.0)), 1.5, 10.0)
					var rspd = clampf(float(f.get("flow_speed", 0.65)), 0.1, 4.0)
					var spline_data = build_river_spline_data(pts, 3.5)
					bp.rivers.append({
						"id": f_id if not f_id.is_empty() else "river_%d" % (bp.rivers.size() + 1),
						"name": f_name,
						"points": pts,
						"spline_points": spline_data.spline_points,
						"distances": spline_data.distances,
						"total_length": spline_data.total_length,
						"width": rw,
						"depth": rd,
						"flow_speed": rspd,
						"spring_sources": f.get("spring_sources", []),
						"waterfalls": f.get("waterfalls", []),
						"status": f_status
					})
				"lake":
					var cx = 0.0
					var cz = 0.0
					if f.has("center") and f["center"] is Array and f["center"].size() >= 2:
						cx = float(f["center"][0])
						cz = float(f["center"][1])
					else:
						cx = float(f.get("x", 0.0))
						cz = float(f.get("z", 0.0))
					var lrad = clampf(float(f.get("radius", 30.0)), 10.0, 100.0)
					var wlvl = float(f.get("water_level", -1.5))
					bp.lakes.append({
						"id": f_id if not f_id.is_empty() else "lake_%d" % (bp.lakes.size() + 1),
						"name": f_name,
						"center": Vector2(cx, cz),
						"radius": lrad,
						"water_level": wlvl,
						"status": f_status
					})
				"mountain_range":
					bp.mountain_ranges.append({
						"id": f_id if not f_id.is_empty() else "range_%d" % (bp.mountain_ranges.size() + 1),
						"name": f_name,
						"peak_ids": f.get("peak_ids", []),
						"status": f_status
					})

	# Parse Mountains (Top-level array)
	bp.mountains.clear()
	if dict.has("mountains") and dict["mountains"] is Array:
		for m_data in dict["mountains"]:
			if m_data is Dictionary:
				var m_id = str(m_data.get("id", "mtn_%d" % (bp.mountains.size() + 1)))
				var m_name = str(m_data.get("name", "Mountain Peak"))
				var mx = float(m_data.get("x", 0.0))
				var mz = float(m_data.get("z", 0.0))
				var m_height = clampf(float(m_data.get("height", 50.0)), 15.0, 115.0)
				var m_rad = clampf(float(m_data.get("radius", 65.0)), 20.0, 160.0)
				var snow = bool(m_data.get("snow_cap", m_height > 40.0))
				var cleared = bool(m_data.get("flora_cleared", false))
				bp.mountains.append({
					"id": m_id,
					"name": m_name,
					"pos": Vector2(mx, mz),
					"height": m_height,
					"radius": m_rad,
					"snow_cap": snow,
					"flora_cleared": cleared
				})
				
	# Parse Mountain Ranges
	bp.mountain_ranges.clear()
	if dict.has("mountain_ranges") and dict["mountain_ranges"] is Array:
		for r_data in dict["mountain_ranges"]:
			if r_data is Dictionary:
				bp.mountain_ranges.append({
					"id": str(r_data.get("id", "range_1")),
					"name": str(r_data.get("name", "Mountain Range")),
					"peak_ids": r_data.get("peak_ids", [])
				})
				
	# Parse Rivers
	bp.rivers.clear()
	if dict.has("rivers") and dict["rivers"] is Array:
		for r_data in dict["rivers"]:
			if r_data is Dictionary:
				var pts = PackedVector2Array()
				if r_data.has("points"):
					if r_data["points"] is PackedVector2Array:
						pts = r_data["points"]
					elif r_data["points"] is Array:
						for p in r_data["points"]:
							if p is Vector2:
								pts.append(p)
							elif p is Array and p.size() >= 2:
								pts.append(Vector2(float(p[0]), float(p[1])))
							elif p is Dictionary:
								pts.append(Vector2(float(p.get("x", 0.0)), float(p.get("z", 0.0))))
				var r_width = clampf(float(r_data.get("width", 8.0)), 3.0, 25.0)
				var r_depth = clampf(float(r_data.get("depth", 4.0)), 1.5, 10.0)
				var r_speed = clampf(float(r_data.get("flow_speed", 0.65)), 0.1, 4.0)
				
				var spline_data = build_river_spline_data(pts, 3.5)
				bp.rivers.append({
					"id": str(r_data.get("id", "river_%d" % (bp.rivers.size() + 1))),
					"name": str(r_data.get("name", "River")),
					"points": pts,
					"spline_points": spline_data.spline_points,
					"distances": spline_data.distances,
					"total_length": spline_data.total_length,
					"width": r_width,
					"depth": r_depth,
					"flow_speed": r_speed,
					"spring_sources": r_data.get("spring_sources", []),
					"waterfalls": r_data.get("waterfalls", [])
				})
				
	# Parse Lakes
	bp.lakes.clear()
	if dict.has("lakes") and dict["lakes"] is Array:
		for l_data in dict["lakes"]:
			if l_data is Dictionary:
				bp.lakes.append({
					"id": str(l_data.get("id", "lake_%d" % (bp.lakes.size() + 1))),
					"name": str(l_data.get("name", "Basin Lake")),
					"center": Vector2(float(l_data.get("x", 0.0)), float(l_data.get("z", 0.0))),
					"radius": clampf(float(l_data.get("radius", 30.0)), 10.0, 100.0),
					"water_level": float(l_data.get("water_level", -1.5))
				})
				
	# Parse Biome Regions
	bp.biome_regions.clear()
	if dict.has("biome_regions") and dict["biome_regions"] is Array:
		for b_data in dict["biome_regions"]:
			if b_data is Dictionary:
				bp.biome_regions.append({
					"id": str(b_data.get("id", "biome_%d" % (bp.biome_regions.size() + 1))),
					"name": str(b_data.get("name", "Biome Region")),
					"center": Vector2(float(b_data.get("x", 0.0)), float(b_data.get("z", 0.0))),
					"radius": clampf(float(b_data.get("radius", 50.0)), 15.0, 150.0),
					"ground_tint": parse_color(b_data.get("ground_tint", "forest green"), Color(0.2, 0.6, 0.2)),
					"foliage_color": parse_color(b_data.get("foliage_color", "emerald"), Color(0.1, 0.8, 0.4)),
					"boost": float(b_data.get("boost", 1.0))
				})
				
	if bp.mountains.size() == 0 and bp.rivers.size() == 0 and bp.lakes.size() == 0 and bp.requirements.is_empty():
		_populate_default_structures(bp)
		
	# Parse Vegetation Layers
	bp.vegetation_layers.clear()
	var raw_layers = []
	if dict.has("vegetation_layers") and dict["vegetation_layers"] is Array:
		raw_layers = dict["vegetation_layers"]
	elif dict.has("flora_layers") and dict["flora_layers"] is Array:
		raw_layers = dict["flora_layers"]
		
	if raw_layers.size() > 0:
		for l_data in raw_layers:
			if l_data is Dictionary:
				var layer = _parse_single_layer(l_data, bp)
				if layer != null:
					bp.vegetation_layers.append(layer)
					
	if bp.vegetation_layers.size() == 0:
		_populate_default_layers_for_theme(bp)
		
	bp.sync_feature_registry()
	return bp


static func _parse_single_layer(data: Dictionary, bp: ForestBlueprint) -> FloraLayerConfig:
	var cfg = FloraLayerConfig.new()
	var valid_archetypes = ["canopy_tree", "small_tree", "shrub", "fern", "flower", "ground_cover", "fallen_log"]
	var arch = str(data.get("archetype", "canopy_tree")).to_lower().strip_edges()
	cfg.archetype = arch if arch in valid_archetypes else "canopy_tree"
	cfg.name = str(data.get("name", cfg.archetype.capitalize()))
	
	var valid_dists = ["clustered", "scattered", "edge_dense", "clearing_centered", "riverbank_focused"]
	var dist = str(data.get("distribution", "scattered")).to_lower().strip_edges()
	cfg.distribution = dist if dist in valid_dists else "scattered"
	
	var raw_density = float(data.get("density", 0.01))
	match cfg.archetype:
		"canopy_tree": cfg.density = clampf(raw_density, 0.001, 0.018)
		"small_tree": cfg.density = clampf(raw_density, 0.002, 0.025)
		"shrub": cfg.density = clampf(raw_density, 0.003, 0.035)
		"fern": cfg.density = clampf(raw_density, 0.005, 0.06)
		"flower": cfg.density = clampf(raw_density, 0.005, 0.07)
		"ground_cover": cfg.density = clampf(raw_density, 0.05, 0.6)
		"fallen_log": cfg.density = clampf(raw_density, 0.0005, 0.004)
		_: cfg.density = clampf(raw_density, 0.001, 0.05)
		
	var s_min = float(data.get("scale_min", data.get("scale", 1.0)))
	var s_max = float(data.get("scale_max", s_min * 1.4))
	cfg.scale_min = clampf(minf(s_min, s_max), 0.25, 4.0)
	cfg.scale_max = clampf(maxf(s_min, s_max), 0.35, 5.0)
	
	cfg.trunk_color = parse_color(data.get("trunk_color", "saddlebrown"), Color("saddlebrown"))
	cfg.foliage_color = parse_color(data.get("foliage_color", data.get("color", Color("forestgreen"))), Color("forestgreen"))
	
	var is_emissive = bool(data.get("emissive", data.get("bioluminescent", false)))
	cfg.emissive = is_emissive
	if is_emissive:
		cfg.emissive_color = parse_color(data.get("emissive_color", cfg.foliage_color), cfg.foliage_color)
		cfg.emissive_energy = clampf(float(data.get("emissive_energy", 2.0)), 0.5, 4.0)
		
	cfg.min_height = clampf(float(data.get("min_height", 1.0)), -5.0, 100.0)
	cfg.max_height = clampf(float(data.get("max_height", 60.0)), cfg.min_height + 2.0, 150.0)
	cfg.max_slope_normal_y = clampf(float(data.get("max_slope", data.get("max_slope_normal_y", 0.8))), 0.5, 0.98)
	cfg.target_biome_id = str(data.get("target_biome_id", ""))
	cfg.near_water_only = bool(data.get("near_water_only", cfg.distribution == "riverbank_focused"))
	
	return cfg


static func _populate_default_structures(bp: ForestBlueprint) -> void:
	bp.mountains.clear()
	bp.mountains.append({
		"id": "mtn_1",
		"name": "North Peak",
		"pos": Vector2(-50.0, -80.0),
		"height": 55.0,
		"radius": 75.0,
		"snow_cap": true,
		"flora_cleared": false
	})
	bp.mountains.append({
		"id": "mtn_2",
		"name": "Shadow Ridge",
		"pos": Vector2(40.0, -90.0),
		"height": 45.0,
		"radius": 65.0,
		"snow_cap": true,
		"flora_cleared": false
	})
	
	bp.mountain_ranges.clear()
	bp.mountain_ranges.append({
		"id": "range_north",
		"name": "Northern Crest",
		"peak_ids": ["mtn_1", "mtn_2"]
	})
	
	bp.rivers.clear()
	var raw_pts = PackedVector2Array([
		Vector2(-70.0, -70.0),
		Vector2(-40.0, -30.0),
		Vector2(-10.0, 0.0),
		Vector2(25.0, 35.0),
		Vector2(80.0, 75.0)
	])
	var spline_data = build_river_spline_data(raw_pts, 3.5)
	bp.rivers.append({
		"id": "river_main",
		"name": "Silver River",
		"points": raw_pts,
		"spline_points": spline_data.spline_points,
		"distances": spline_data.distances,
		"total_length": spline_data.total_length,
		"width": 8.0,
		"depth": 3.5,
		"flow_speed": 0.65,
		"spring_sources": [Vector2(-70.0, -70.0)],
		"waterfalls": []
	})
	
	bp.biome_regions.clear()
	bp.biome_regions.append({
		"id": "biome_central_wilds",
		"name": "Verdant Clearing",
		"center": Vector2(0.0, 10.0),
		"radius": 55.0,
		"ground_tint": Color(0.2, 0.65, 0.3),
		"foliage_color": Color(0.1, 0.8, 0.3),
		"boost": 1.2
	})


static func _populate_default_layers_for_theme(bp: ForestBlueprint) -> void:
	bp.vegetation_layers.clear()
	var c_tree = FloraLayerConfig.new()
	c_tree.archetype = "canopy_tree"
	c_tree.name = "Ancient Canopy Oak"
	c_tree.distribution = "clustered"
	c_tree.density = 0.007
	c_tree.scale_min = 1.3
	c_tree.scale_max = 2.4
	c_tree.trunk_color = parse_color("dark brown", Color(0.28, 0.16, 0.06))
	c_tree.foliage_color = parse_color("forest green", Color(0.12, 0.52, 0.15))
	bp.vegetation_layers.append(c_tree)
	
	var s_tree = FloraLayerConfig.new()
	s_tree.archetype = "small_tree"
	s_tree.name = "Silver Birch Sapling"
	s_tree.density = 0.009
	s_tree.scale_min = 0.8
	s_tree.scale_max = 1.5
	s_tree.trunk_color = parse_color("light gray", Color(0.75, 0.75, 0.72))
	s_tree.foliage_color = parse_color("lime green", Color(0.45, 0.78, 0.15))
	bp.vegetation_layers.append(s_tree)
	
	var shrub = FloraLayerConfig.new()
	shrub.archetype = "shrub"
	shrub.name = "Woodland Bramble"
	shrub.distribution = "edge_dense"
	shrub.density = 0.016
	shrub.foliage_color = parse_color("olive", Color(0.38, 0.52, 0.18))
	bp.vegetation_layers.append(shrub)
	
	var fern = FloraLayerConfig.new()
	fern.archetype = "fern"
	fern.name = "Highland Frond Fern"
	fern.density = 0.035
	fern.foliage_color = parse_color("emerald", Color(0.15, 0.72, 0.32))
	bp.vegetation_layers.append(fern)
	
	var flower = FloraLayerConfig.new()
	flower.archetype = "flower"
	flower.name = "Clearing Bluebell"
	flower.density = 0.04
	flower.foliage_color = parse_color("pink", Color(0.95, 0.35, 0.65))
	bp.vegetation_layers.append(flower)
	
	var grass = FloraLayerConfig.new()
	grass.archetype = "ground_cover"
	grass.name = "Lush Meadow Grass"
	grass.density = 0.3
	grass.foliage_color = parse_color("green", Color(0.08, 0.65, 0.25))
	bp.vegetation_layers.append(grass)


# --- Geometry & Smooth Hydraulic River Profile ---

func get_height_at(wx: float, wz: float, base_noise_height: float) -> float:
	var final_h = base_noise_height
	var pos2 = Vector2(wx, wz)
	
	# 1. Discrete Mountain Peaks (Smooth Cosine profile)
	for m in mountains:
		var dist = pos2.distance_to(m.pos)
		var rad = float(m.radius)
		if dist < rad:
			var profile = 0.5 * (1.0 + cos(PI * (dist / rad)))
			final_h += float(m.height) * profile
			
	# 2. Lakes (Smooth basin depression)
	for l in lakes:
		var dist = pos2.distance_to(l.center)
		var rad = float(l.radius)
		if dist < rad:
			var factor = 1.0 - (dist / rad)
			var carve = factor * factor * 9.0
			final_h = minf(final_h, float(l.water_level) - carve)
			
	# 3. Smooth Riverbed Hydraulic Excavation
	var river_info = get_nearest_river_info(wx, wz)
	var half_w = river_info.width * 0.5
	if river_info.distance < half_w:
		# Deep central river channel with parabolic bed
		var bed_profile = cos((river_info.distance / half_w) * (PI * 0.5))
		final_h -= river_info.depth * bed_profile
	elif river_info.distance < half_w * 2.2:
		# Smooth natural embankment transitioning into surrounding terrain
		var t = (river_info.distance - half_w) / (half_w * 1.2)
		var bank_profile = 0.5 * (1.0 + cos(clampf(t, 0.0, 1.0) * PI))
		final_h -= river_info.depth * 0.35 * bank_profile
		
	# 4. Waterfall ledge steps if near waterfall position
	for r in rivers:
		for wf in r.get("waterfalls", []):
			var wf_pos = wf.get("pos", Vector2.ZERO)
			if pos2.distance_to(wf_pos) < float(r.get("width", 8.0)) * 1.5:
				var drop = float(wf.get("height_drop", 12.0))
				# Plunge step downstream
				var dir = (pos2 - wf_pos).normalized()
				if dir.y > 0.0:
					final_h -= drop * 0.75
					
	return final_h


func get_nearest_river_info(wx: float, wz: float) -> Dictionary:
	var pos2 = Vector2(wx, wz)
	var min_dist = 999999.0
	var river_w = 8.0
	var river_d = 4.0
	var river_name = ""
	var river_id = ""
	var river_obj = null
	
	for r in rivers:
		var pts: PackedVector2Array = r.get("spline_points", r.get("points", PackedVector2Array()))
		if pts.size() < 2:
			continue
		for i in range(pts.size() - 1):
			var seg_a = pts[i]
			var seg_b = pts[i + 1]
			var d = _distance_point_to_segment(pos2, seg_a, seg_b)
			if d < min_dist:
				min_dist = d
				river_w = float(r.get("width", 8.0))
				river_d = float(r.get("depth", 4.0))
				river_name = str(r.get("name", "River"))
				river_id = str(r.get("id", ""))
				river_obj = r
				
	return {
		"distance": min_dist,
		"width": river_w,
		"depth": river_d,
		"name": river_name,
		"id": river_id,
		"river": river_obj
	}


func is_flora_excluded(wx: float, wz: float) -> bool:
	var pos2 = Vector2(wx, wz)
	for m in mountains:
		if m.get("flora_cleared", false):
			var d = pos2.distance_to(m.pos)
			if d < float(m.radius) * 1.15:
				return true
				
	for m in mountains:
		if m.get("snow_cap", false):
			var d = pos2.distance_to(m.pos)
			if d < float(m.radius) * 0.45:
				return true
				
	for l in lakes:
		var d = pos2.distance_to(l.center)
		if d < float(l.radius) * 1.05:
			return true
				
	return false


func is_in_snow_cap(wx: float, wz: float, h: float) -> bool:
	# Regional snow modifier (e.g. "make the southern region snowy")
	if regional_snow.get("south", false) and wz > 25.0:
		return true
	if regional_snow.get("north", false) and wz < -25.0:
		return true
		
	var pos2 = Vector2(wx, wz)
	for m in mountains:
		if m.get("snow_cap", false):
			var dist = pos2.distance_to(m.pos)
			if dist < float(m.radius) * 0.45 and h > 26.0:
				return true
	return false


func get_biome_at(wx: float, wz: float) -> Dictionary:
	var pos2 = Vector2(wx, wz)
	for b in biome_regions:
		var dist = pos2.distance_to(b.center)
		if dist < float(b.radius):
			var weight = 1.0 - (dist / float(b.radius))
			return {
				"id": b.id,
				"name": b.name,
				"ground_tint": b.ground_tint,
				"foliage_color": b.foliage_color,
				"weight": weight,
				"boost": float(b.get("boost", 1.0))
			}
	return {
		"id": "global_default",
		"name": theme,
		"ground_tint": terrain_tint,
		"foliage_color": grass_color,
		"weight": 1.0,
		"boost": 1.0
	}


func find_feature_by_name(query: String) -> Dictionary:
	var q = query.to_lower().strip_edges()
	if q.is_empty():
		return {}
		
	for m in mountains:
		var m_name = str(m.get("name", "")).to_lower()
		var m_id = str(m.get("id", "")).to_lower()
		if q in m_name or m_name in q or q in m_id or (("north" in q and "north" in m_name) or ("shadow" in q and "shadow" in m_name)):
			return {"type": "mountain", "id": m.id, "name": m.name, "pos": m.pos, "data": m}
			
	for r in rivers:
		var r_name = str(r.get("name", "")).to_lower()
		var r_id = str(r.get("id", "")).to_lower()
		if q in r_name or r_name in q or q in r_id or "river" in q:
			return {"type": "river", "id": r.id, "name": r.name, "points": r.points, "data": r}
			
	for l in lakes:
		var l_name = str(l.get("name", "")).to_lower()
		if q in l_name or l_name in q or "lake" in q:
			return {"type": "lake", "id": l.id, "name": l.name, "center": l.center, "data": l}
			
	return {}


# Generate smooth Catmull-Rom spline with accumulated distance array
static func build_river_spline_data(control_pts: PackedVector2Array, step: float = 3.5) -> Dictionary:
	var spline = _generate_catmull_rom_spline(control_pts, step)
	var dists = PackedFloat32Array()
	var total_d = 0.0
	dists.append(0.0)
	for i in range(spline.size() - 1):
		total_d += spline[i].distance_to(spline[i + 1])
		dists.append(total_d)
	return {
		"spline_points": spline,
		"distances": dists,
		"total_length": total_d
	}


static func _generate_catmull_rom_spline(control_pts: PackedVector2Array, step: float = 3.5) -> PackedVector2Array:
	if control_pts.size() < 2:
		return control_pts
	if control_pts.size() == 2:
		var subdivided = PackedVector2Array()
		var p0 = control_pts[0]
		var p1 = control_pts[1]
		var dist = p0.distance_to(p1)
		var num_steps = maxi(2, int(dist / step))
		for i in range(num_steps + 1):
			subdivided.append(p0.lerp(p1, float(i) / float(num_steps)))
		return subdivided
		
	var result = PackedVector2Array()
	var n = control_pts.size()
	
	for i in range(n - 1):
		var p0 = control_pts[maxi(0, i - 1)]
		var p1 = control_pts[i]
		var p2 = control_pts[i + 1]
		var p3 = control_pts[mini(n - 1, i + 2)]
		
		var seg_len = p1.distance_to(p2)
		var num_sub = maxi(4, int(seg_len / step))
		
		for s in range(num_sub):
			var t = float(s) / float(num_sub)
			var pt = _catmull_rom(p0, p1, p2, p3, t)
			result.append(pt)
			
	result.append(control_pts[n - 1])
	return result


static func _catmull_rom(p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2, t: float) -> Vector2:
	var t2 = t * t
	var t3 = t2 * t
	return 0.5 * (
		(2.0 * p1) +
		(-p0 + p2) * t +
		(2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2 +
		(-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3
	)


static func _distance_point_to_segment(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab = b - a
	var ab_len_sq = ab.length_squared()
	if ab_len_sq < 0.0001:
		return p.distance_to(a)
	var t = clampf((p - a).dot(ab) / ab_len_sq, 0.0, 1.0)
	var projection = a + t * ab
	return p.distance_to(projection)
