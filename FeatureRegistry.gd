# FeatureRegistry.gd
# Authoritative geographical feature registry for SublimeGreens Milestone 2.
# Tracks discrete world features (mountains, rivers, lakes, trees) with persistent IDs,
# spatial bounding boxes, parameters, status tracking, and spatial hash acceleration.
class_name FeatureRegistry
extends RefCounted

signal feature_registered(feature_id: String, feature_type: String)
signal feature_updated(feature_id: String)
signal feature_removed(feature_id: String)
signal registry_cleared()

# Valid feature types supported by the simulation
const VALID_TYPES: Array[String] = [
	"mountain",
	"mountain_range",
	"river",
	"lake",
	"tree",
	"flora_patch",
	"landmark"
]

# Valid status states
const STATUS_PLANNED: String = "planned"
const STATUS_ACTIVE: String = "active"
const STATUS_MODIFIED: String = "modified"
const STATUS_REMOVED: String = "removed"

# Primary feature storage: id -> feature Dictionary
var _features: Dictionary = {}

# Secondary index: type -> Array[String] (feature IDs)
var _features_by_type: Dictionary = {}

# Spatial Hash Index for fast localized range/AABB queries
var spatial_cell_size: float = 100.0 # 100m buckets
var _spatial_grid: Dictionary = {} # Vector2i -> Array[String]

var _id_counters: Dictionary = {}

func _init(p_spatial_cell_size: float = 100.0) -> void:
	spatial_cell_size = p_spatial_cell_size
	_clear_indices()

func _clear_indices() -> void:
	_features.clear()
	_features_by_type.clear()
	for t in VALID_TYPES:
		_features_by_type[t] = []
	_spatial_grid.clear()
	_id_counters.clear()

# -----------------------------------------------------------------------------
# Registration & Mutation
# -----------------------------------------------------------------------------

## Registers a feature into the registry.
## Expected keys in feature_data:
## - id (optional): String. If omitted, generated automatically.
## - type: String ("mountain", "river", "lake", "tree", etc.)
## - position: Vector2 (or Vector3)
## - bounds (optional): Rect2. If omitted, computed from position and parameters.
## - parameters: Dictionary
## - status (optional): String ("planned", "active", etc.)
## - metadata (optional): Dictionary
func register_feature(feature_data: Dictionary) -> String:
	var f_type: String = str(feature_data.get("type", "landmark")).to_lower()
	if not _features_by_type.has(f_type):
		_features_by_type[f_type] = []
		
	var f_id: String = str(feature_data.get("id", "")).strip_edges()
	if f_id.is_empty():
		f_id = _generate_unique_id(f_type)
		
	var pos: Vector2 = _extract_vector2(feature_data.get("position", Vector2.ZERO))
	var params: Dictionary = feature_data.get("parameters", {}).duplicate(true)
	
	# Determine spatial bounding rect
	var bounds: Rect2
	if feature_data.has("bounds") and feature_data["bounds"] is Rect2:
		bounds = feature_data["bounds"]
	else:
		bounds = _calculate_default_bounds(f_type, pos, params, feature_data)
		
	var status: String = str(feature_data.get("status", STATUS_ACTIVE))
	var meta: Dictionary = feature_data.get("metadata", {}).duplicate(true)
	
	var feature_record: Dictionary = {
		"id": f_id,
		"type": f_type,
		"position": pos,
		"bounds": bounds,
		"parameters": params,
		"status": status,
		"metadata": meta
	}
	
	# If already exists, remove old spatial references first
	if _features.has(f_id):
		_remove_from_spatial_grid(f_id, _features[f_id]["bounds"])
		_features_by_type[_features[f_id]["type"]].erase(f_id)
		
	_features[f_id] = feature_record
	_features_by_type[f_type].append(f_id)
	_insert_into_spatial_grid(f_id, bounds)
	
	feature_registered.emit(f_id, f_type)
	return f_id

## Unregisters and removes a feature from the registry.
func unregister_feature(feature_id: String) -> bool:
	if not _features.has(feature_id):
		return false
		
	var record = _features[feature_id]
	_remove_from_spatial_grid(feature_id, record["bounds"])
	
	var f_type: String = record["type"]
	if _features_by_type.has(f_type):
		_features_by_type[f_type].erase(feature_id)
		
	_features.erase(feature_id)
	feature_removed.emit(feature_id)
	return true

## Updates the parameters and optionally the bounds/position of an existing feature.
func update_feature(feature_id: String, new_params: Dictionary, new_bounds: Variant = null, new_pos: Variant = null) -> bool:
	if not _features.has(feature_id):
		return false
		
	var record = _features[feature_id]
	for k in new_params.keys():
		record["parameters"][k] = new_params[k]
		
	record["status"] = STATUS_MODIFIED
	
	var bounds_changed = false
	var old_bounds: Rect2 = record["bounds"]
	
	if new_pos != null:
		record["position"] = _extract_vector2(new_pos)
		bounds_changed = true
		
	if new_bounds != null and new_bounds is Rect2:
		record["bounds"] = new_bounds
		bounds_changed = true
	elif bounds_changed:
		record["bounds"] = _calculate_default_bounds(record["type"], record["position"], record["parameters"], record)
		
	if bounds_changed:
		_remove_from_spatial_grid(feature_id, old_bounds)
		_insert_into_spatial_grid(feature_id, record["bounds"])
		
	feature_updated.emit(feature_id)
	return true

## Sets the operational status of a feature ("planned", "active", "modified", "removed").
func set_feature_status(feature_id: String, new_status: String) -> bool:
	if not _features.has(feature_id):
		return false
	_features[feature_id]["status"] = new_status
	feature_updated.emit(feature_id)
	return true

# -----------------------------------------------------------------------------
# Query Functions
# -----------------------------------------------------------------------------

## Retrieves a feature record dictionary by ID.
func get_feature(feature_id: String) -> Dictionary:
	if _features.has(feature_id):
		return _features[feature_id]
	return {}

## Checks whether a feature ID exists.
func has_feature(feature_id: String) -> bool:
	return _features.has(feature_id)

## Returns all features in the registry as an Array of Dictionaries.
func get_all_features() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for f in _features.values():
		result.append(f)
	return result

## Returns all features of a specific type (e.g. "mountain", "river", "lake", "tree").
func get_features_by_type(type: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var t_key = type.to_lower()
	if _features_by_type.has(t_key):
		for f_id in _features_by_type[t_key]:
			if _features.has(f_id):
				result.append(_features[f_id])
	return result

## Fast spatial query returning all features overlapping a target Rect2 region.
## Optionally filters by feature type.
func get_features_in_region(query_rect: Rect2, type_filter: String = "") -> Array[Dictionary]:
	var min_c = _to_spatial_cell(query_rect.position)
	var max_c = _to_spatial_cell(query_rect.end)
	var candidate_ids: Dictionary = {}
	
	for cy in range(min_c.y, max_c.y + 1):
		for cx in range(min_c.x, max_c.x + 1):
			var cell_coord = Vector2i(cx, cy)
			if _spatial_grid.has(cell_coord):
				for f_id in _spatial_grid[cell_coord]:
					candidate_ids[f_id] = true
					
	var filter_active = not type_filter.is_empty()
	var t_filter_key = type_filter.to_lower()
	var matching_features: Array[Dictionary] = []
	
	for f_id in candidate_ids.keys():
		if _features.has(f_id):
			var feat = _features[f_id]
			if filter_active and feat["type"] != t_filter_key:
				continue
			var f_bounds: Rect2 = feat["bounds"]
			if query_rect.intersects(f_bounds):
				matching_features.append(feat)
				
	return matching_features

## Returns count of features, optionally filtered by type.
func get_feature_count(type_filter: String = "") -> int:
	if type_filter.is_empty():
		return _features.size()
	var t_key = type_filter.to_lower()
	if _features_by_type.has(t_key):
		return _features_by_type[t_key].size()
	return 0

## Clears all features and indices.
func clear() -> void:
	_clear_indices()
	registry_cleared.emit()

# -----------------------------------------------------------------------------
# Spatial Index Helpers
# -----------------------------------------------------------------------------

func _to_spatial_cell(pos: Vector2) -> Vector2i:
	return Vector2i(floori(pos.x / spatial_cell_size), floori(pos.y / spatial_cell_size))

func _insert_into_spatial_grid(f_id: String, bounds: Rect2) -> void:
	var min_c = _to_spatial_cell(bounds.position)
	var max_c = _to_spatial_cell(bounds.end)
	
	for cy in range(min_c.y, max_c.y + 1):
		for cx in range(min_c.x, max_c.x + 1):
			var cell_coord = Vector2i(cx, cy)
			if not _spatial_grid.has(cell_coord):
				_spatial_grid[cell_coord] = []
			_spatial_grid[cell_coord].append(f_id)

func _remove_from_spatial_grid(f_id: String, bounds: Rect2) -> void:
	var min_c = _to_spatial_cell(bounds.position)
	var max_c = _to_spatial_cell(bounds.end)
	
	for cy in range(min_c.y, max_c.y + 1):
		for cx in range(min_c.x, max_c.x + 1):
			var cell_coord = Vector2i(cx, cy)
			if _spatial_grid.has(cell_coord):
				_spatial_grid[cell_coord].erase(f_id)
				if _spatial_grid[cell_coord].is_empty():
					_spatial_grid.erase(cell_coord)

func _calculate_default_bounds(f_type: String, pos: Vector2, params: Dictionary, data: Dictionary) -> Rect2:
	match f_type:
		"mountain":
			var r = float(params.get("radius", 150.0))
			return Rect2(pos.x - r, pos.y - r, r * 2.0, r * 2.0)
		"lake":
			var r = float(params.get("radius", 60.0))
			return Rect2(pos.x - r, pos.y - r, r * 2.0, r * 2.0)
		"river":
			var pts: Array = params.get("points", data.get("points", []))
			if pts.is_empty():
				pts = params.get("path", data.get("path", []))
			if pts.is_empty():
				return Rect2(pos.x - 25.0, pos.y - 25.0, 50.0, 50.0)
			
			var p0 = _extract_vector2(pts[0])
			var min_x = p0.x
			var max_x = p0.x
			var min_y = p0.y
			var max_y = p0.y
			for p in pts:
				var v = _extract_vector2(p)
				if v.x < min_x: min_x = v.x
				if v.x > max_x: max_x = v.x
				if v.y < min_y: min_y = v.y
				if v.y > max_y: max_y = v.y
			var w = float(params.get("width", 12.0))
			return Rect2(min_x - w, min_y - w, (max_x - min_x) + w * 2.0, (max_y - min_y) + w * 2.0)
		"tree":
			var scale = float(params.get("scale", 2.0))
			var r = scale * 3.0
			return Rect2(pos.x - r, pos.y - r, r * 2.0, r * 2.0)
		"flora_patch":
			var r = float(params.get("radius", 40.0))
			return Rect2(pos.x - r, pos.y - r, r * 2.0, r * 2.0)
		_:
			return Rect2(pos.x - 10.0, pos.y - 10.0, 20.0, 20.0)

func _generate_unique_id(type: String) -> String:
	if not _id_counters.has(type):
		_id_counters[type] = 0
	_id_counters[type] += 1
	var short_type = type
	match type:
		"mountain": short_type = "mtn"
		"river": short_type = "riv"
		"lake": short_type = "lak"
		"tree": short_type = "tre"
		"flora_patch": short_type = "flr"
		"mountain_range": short_type = "rng"
	return "%s_%03d" % [short_type, _id_counters[type]]

func _extract_vector2(val: Variant) -> Vector2:
	if val is Vector2:
		return val
	elif val is Vector3:
		return Vector2(val.x, val.z)
	elif val is Array and val.size() >= 2:
		return Vector2(float(val[0]), float(val[1]))
	elif val is Dictionary and val.has("x") and (val.has("y") or val.has("z")):
		return Vector2(float(val["x"]), float(val.get("y", val.get("z", 0.0))))
	return Vector2.ZERO

# -----------------------------------------------------------------------------
# Serialization
# -----------------------------------------------------------------------------

func to_dict() -> Dictionary:
	var out_features: Array[Dictionary] = []
	for f in _features.values():
		var copy = f.duplicate(true)
		# Convert Rect2 to array for clean JSON compatibility
		var b: Rect2 = copy["bounds"]
		copy["bounds_array"] = [b.position.x, b.position.y, b.size.x, b.size.y]
		copy.erase("bounds")
		var p: Vector2 = copy["position"]
		copy["position_array"] = [p.x, p.y]
		copy.erase("position")
		out_features.append(copy)
	return {
		"spatial_cell_size": spatial_cell_size,
		"features": out_features
	}

func from_dict(dict: Dictionary) -> void:
	clear()
	if dict.has("spatial_cell_size"):
		spatial_cell_size = float(dict["spatial_cell_size"])
	if dict.has("features") and dict["features"] is Array:
		for item in dict["features"]:
			if item is Dictionary:
				var rec = item.duplicate(true)
				if rec.has("bounds_array") and rec["bounds_array"] is Array and rec["bounds_array"].size() == 4:
					rec["bounds"] = Rect2(rec["bounds_array"][0], rec["bounds_array"][1], rec["bounds_array"][2], rec["bounds_array"][3])
					rec.erase("bounds_array")
				if rec.has("position_array") and rec["position_array"] is Array and rec["position_array"].size() == 2:
					rec["position"] = Vector2(rec["position_array"][0], rec["position_array"][1])
					rec.erase("position_array")
				register_feature(rec)

