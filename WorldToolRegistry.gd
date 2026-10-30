# WorldToolRegistry.gd
class_name WorldToolRegistry
extends RefCounted

const WorldFeatureCatalog = preload("res://WorldFeatureCatalog.gd")

signal world_modified(blueprint: ForestBlueprint, change_summary: String)

var active_blueprint: ForestBlueprint = null
var history_stack: Array[ForestBlueprint] = []
const MAX_HISTORY: int = 12


func _init(initial_blueprint: ForestBlueprint = null):
	if initial_blueprint != null:
		active_blueprint = initial_blueprint
	else:
		active_blueprint = ForestBlueprint.create_default()


func save_history_snapshot() -> void:
	if active_blueprint:
		var raw = active_blueprint.raw_data.duplicate(true)
		var snapshot = ForestBlueprint.from_json(raw)
		snapshot.mountains = active_blueprint.mountains.duplicate(true)
		snapshot.mountain_ranges = active_blueprint.mountain_ranges.duplicate(true)
		snapshot.rivers = active_blueprint.rivers.duplicate(true)
		snapshot.lakes = active_blueprint.lakes.duplicate(true)
		snapshot.biome_regions = active_blueprint.biome_regions.duplicate(true)
		snapshot.landmarks = active_blueprint.landmarks.duplicate(true)
		snapshot.regional_snow = active_blueprint.regional_snow.duplicate(true)
		
		var cloned_layers = []
		for l in active_blueprint.vegetation_layers:
			cloned_layers.append(l.duplicate())
		snapshot.vegetation_layers = cloned_layers
		
		history_stack.append(snapshot)
		if history_stack.size() > MAX_HISTORY:
			history_stack.pop_front()


func execute_tool(tool_name: String, args: Dictionary) -> Dictionary:
	match tool_name:
		"get_world_status":
			return tool_get_world_status(args)
		"list_world_features":
			return tool_list_world_features(args)
		"find_feature_by_location":
			return tool_find_feature_by_location(args)
		"find_largest_feature":
			return tool_find_largest_feature(args)
		"get_feature_catalog":
			return tool_get_feature_catalog(args)
		"generate_world":
			return tool_generate_world(args)
		"modify_terrain_region":
			return tool_modify_terrain_region(args)
		"create_mountain_range":
			return tool_create_mountain_range(args)
		"modify_mountain":
			return tool_modify_mountain(args)
		"create_or_modify_river":
			return tool_create_or_modify_river(args)
		"modify_river":
			return tool_modify_river(args)
		"modify_all_rivers":
			return tool_modify_all_rivers(args)
		"modify_water_flow":
			return tool_modify_water_flow(args)
		"create_waterfall":
			return tool_create_waterfall(args)
		"set_biome_region":
			return tool_set_biome_region(args)
		"modify_biome":
			return tool_modify_biome(args)
		"set_regional_snow":
			return tool_set_regional_snow(args)
		"distribute_flora":
			return tool_distribute_flora(args)
		"clear_mountain_flora":
			return tool_clear_mountain_flora(args)
		"add_landmark":
			return tool_add_landmark(args)
		"regenerate_world_map":
			return tool_regenerate_world_map(args)
		"undo_last_edit":
			return tool_undo_last_edit(args)
		_:
			return {
				"status": "error",
				"message": "Unknown tool: %s" % tool_name
			}


func _describe_quadrant(pos: Vector2) -> String:
	var ns = "north" if pos.y < -15.0 else ("south" if pos.y > 15.0 else "central")
	var ew = "west" if pos.x < -15.0 else ("east" if pos.x > 15.0 else "central")
	if ns == "central" and ew == "central":
		return "center"
	if ns == "central":
		return ew
	if ew == "central":
		return ns
	return ns + ew


func tool_get_world_status(_args: Dictionary) -> Dictionary:
	if not active_blueprint:
		return {"status": "error", "message": "No active world blueprint"}
	return {
		"status": "success",
		"theme": active_blueprint.theme,
		"seed": active_blueprint.world_seed,
		"terrain_type": active_blueprint.terrain_type,
		"mountains": active_blueprint.mountains,
		"rivers": active_blueprint.rivers,
		"lakes": active_blueprint.lakes,
		"biome_regions": active_blueprint.biome_regions,
		"regional_snow": active_blueprint.regional_snow,
		"mountain_count": active_blueprint.mountains.size(),
		"river_count": active_blueprint.rivers.size(),
		"lake_count": active_blueprint.lakes.size(),
		"biome_region_count": active_blueprint.biome_regions.size(),
		"vegetation_layer_count": active_blueprint.vegetation_layers.size()
	}


func tool_list_world_features(_args: Dictionary) -> Dictionary:
	if not active_blueprint:
		return {"status": "error", "message": "No active world blueprint"}
		
	var mtn_summaries = []
	var sorted_mtns = active_blueprint.mountains.duplicate()
	sorted_mtns.sort_custom(func(a, b): return float(a.get("height", 0.0)) > float(b.get("height", 0.0)))
	
	for rank in range(sorted_mtns.size()):
		var m = sorted_mtns[rank]
		var pos: Vector2 = m.get("pos", Vector2.ZERO)
		mtn_summaries.append({
			"id": m.get("id", ""),
			"name": m.get("name", ""),
			"pos": [pos.x, pos.y],
			"region": _describe_quadrant(pos),
			"height": float(m.get("height", 50.0)),
			"radius": float(m.get("radius", 65.0)),
			"snow_cap": bool(m.get("snow_cap", false)),
			"flora_cleared": bool(m.get("flora_cleared", false)),
			"height_rank": rank + 1
		})
		
	var river_summaries = []
	for r in active_blueprint.rivers:
		var pts: PackedVector2Array = r.get("points", PackedVector2Array())
		var start_p = pts[0] if pts.size() > 0 else Vector2.ZERO
		var end_p = pts[pts.size() - 1] if pts.size() > 0 else Vector2.ZERO
		var mid_p = pts[int(pts.size() / 2)] if pts.size() > 0 else Vector2.ZERO
		river_summaries.append({
			"id": r.get("id", ""),
			"name": r.get("name", ""),
			"width": float(r.get("width", 8.0)),
			"depth": float(r.get("depth", 4.0)),
			"flow_speed": float(r.get("flow_speed", 0.65)),
			"length": float(r.get("total_length", 100.0)),
			"region": _describe_quadrant(mid_p),
			"source": [start_p.x, start_p.y],
			"destination": [end_p.x, end_p.y],
			"waterfall_count": r.get("waterfalls", []).size()
		})
		
	return {
		"status": "success",
		"mountains": mtn_summaries,
		"rivers": river_summaries,
		"lakes": active_blueprint.lakes,
		"biome_regions": active_blueprint.biome_regions,
		"regional_snow": active_blueprint.regional_snow
	}


func tool_find_feature_by_location(args: Dictionary) -> Dictionary:
	var region = str(args.get("region", args.get("location", "northwest"))).to_lower()
	var f_type = str(args.get("type", "any")).to_lower()
	var matches = []
	
	if f_type in ["any", "mountain", "peak"]:
		for m in active_blueprint.mountains:
			var pos: Vector2 = m.get("pos", Vector2.ZERO)
			var q = _describe_quadrant(pos)
			if region in q or q in region or (region == "north" and pos.y < 0) or (region == "south" and pos.y > 0) or (region == "west" and pos.x < 0) or (region == "east" and pos.x > 0):
				matches.append({"type": "mountain", "id": m.id, "name": m.name, "pos": pos, "height": m.height, "region": q, "data": m})
				
	if f_type in ["any", "river", "stream"]:
		for r in active_blueprint.rivers:
			var pts: PackedVector2Array = r.get("points", PackedVector2Array())
			for pt in pts:
				var q = _describe_quadrant(pt)
				if region in q or q in region or (region == "north" and pt.y < 0) or (region == "south" and pt.y > 0) or (region == "west" and pt.x < 0) or (region == "east" and pt.x > 0):
					matches.append({"type": "river", "id": r.id, "name": r.name, "region": q, "data": r})
					break
					
	return {
		"status": "success",
		"region": region,
		"count": matches.size(),
		"matches": matches
	}


func tool_find_largest_feature(args: Dictionary) -> Dictionary:
	var f_type = str(args.get("type", "mountain")).to_lower()
	var count = clampi(int(args.get("count", 1)), 1, 10)
	
	if "mountain" in f_type or "peak" in f_type:
		var sorted_mtns = active_blueprint.mountains.duplicate()
		sorted_mtns.sort_custom(func(a, b): return float(a.get("height", 0.0)) > float(b.get("height", 0.0)))
		var top_mtns = sorted_mtns.slice(0, mini(count, sorted_mtns.size()))
		return {
			"status": "success",
			"type": "mountain",
			"features": top_mtns,
			"largest": top_mtns[0] if top_mtns.size() > 0 else {}
		}
	elif "river" in f_type:
		var sorted_rivers = active_blueprint.rivers.duplicate()
		sorted_rivers.sort_custom(func(a, b): return float(a.get("total_length", 0.0)) > float(b.get("total_length", 0.0)))
		var top_rivers = sorted_rivers.slice(0, mini(count, sorted_rivers.size()))
		return {
			"status": "success",
			"type": "river",
			"features": top_rivers,
			"largest": top_rivers[0] if top_rivers.size() > 0 else {}
		}
	return {"status": "warning", "message": "No matching features of type: " + f_type}


func tool_get_feature_catalog(_args: Dictionary) -> Dictionary:
	return {
		"status": "success",
		"catalog": WorldFeatureCatalog.get_summary()
	}


func tool_generate_world(args: Dictionary) -> Dictionary:
	save_history_snapshot()
	var blueprint_dict = args.get("blueprint", args)
	var new_bp = ForestBlueprint.from_json(blueprint_dict)
	active_blueprint = new_bp
	var summary = "Created world '%s' with %d mountains, %d rivers, and %d flora layers." % [
		new_bp.theme, new_bp.mountains.size(), new_bp.rivers.size(), new_bp.vegetation_layers.size()
	]
	return {
		"status": "success",
		"message": summary,
		"blueprint": new_bp
	}


func tool_create_mountain_range(args: Dictionary) -> Dictionary:
	save_history_snapshot()
	var range_name = str(args.get("name", "Mountain Peak"))
	var count = clampi(int(args.get("count", 1)), 1, 8)
	var center_x = float(args.get("center_x", 0.0))
	var center_z = float(args.get("center_z", 0.0))
	var spacing = float(args.get("spacing", 45.0))
	var base_h = clampf(float(args.get("height", 60.0)), 20.0, 115.0)
	var rad = clampf(float(args.get("radius", 65.0)), 25.0, 140.0)
	var snow = bool(args.get("snow_cap", base_h > 45.0))
	
	var peak_ids: Array = []
	for i in range(count):
		var p_id = "mtn_%s_%d" % [range_name.to_snake_case(), active_blueprint.mountains.size() + 1]
		var px = center_x + (i - (count - 1) * 0.5) * spacing
		var pz = center_z + sin(i * 1.2) * (spacing * 0.3)
		var h = base_h + (i % 2 - 0.5) * 6.0 if count > 1 else base_h
		
		active_blueprint.mountains.append({
			"id": p_id,
			"name": "%s %d" % [range_name, i + 1] if count > 1 else range_name,
			"pos": Vector2(px, pz),
			"height": h,
			"radius": rad,
			"snow_cap": snow,
			"flora_cleared": false
		})
		peak_ids.append(p_id)
		
	active_blueprint.mountain_ranges.append({
		"id": "range_" + range_name.to_snake_case(),
		"name": range_name,
		"peak_ids": peak_ids
	})
	
	var summary = "Erected %s (%d peak%s, height %.0fm) at coordinates (%.0f, %.0f)%s." % [
		range_name, count, "s" if count > 1 else "", base_h, center_x, center_z,
		" [snow-capped]" if snow else ""
	]
	return {
		"status": "success",
		"message": summary,
		"peak_count": count,
		"coordinates": Vector2(center_x, center_z)
	}


func _resolve_mountain_target(query: String) -> Dictionary:
	var q = query.to_lower().strip_edges()
	if active_blueprint.mountains.is_empty():
		return {}
		
	# 1. Exact or substring ID/name match
	for m in active_blueprint.mountains:
		var m_name = str(m.get("name", "")).to_lower()
		var m_id = str(m.get("id", "")).to_lower()
		if not q.is_empty() and (q == m_id or q == m_name or q in m_name or m_name in q):
			return m
			
	# 2. Tallest / largest match
	if "tallest" in q or "largest" in q or "highest" in q or "biggest" in q:
		var best = active_blueprint.mountains[0]
		for m in active_blueprint.mountains:
			if float(m.get("height", 0.0)) > float(best.get("height", 0.0)):
				best = m
		return best
		
	# 3. Spatial quadrant match (e.g. "northwest", "northwestern", "southwest")
	var target_dir = Vector2.ZERO
	if "northwest" in q or "north-west" in q or "top left" in q:
		target_dir = Vector2(-1, -1)
	elif "northeast" in q or "north-east" in q or "top right" in q:
		target_dir = Vector2(1, -1)
	elif "southwest" in q or "south-west" in q or "bottom left" in q:
		target_dir = Vector2(-1, 1)
	elif "southeast" in q or "south-east" in q or "bottom right" in q:
		target_dir = Vector2(1, 1)
	elif "north" in q:
		target_dir = Vector2(0, -1)
	elif "south" in q:
		target_dir = Vector2(0, 1)
	elif "west" in q:
		target_dir = Vector2(-1, 0)
	elif "east" in q:
		target_dir = Vector2(1, 0)
		
	if target_dir != Vector2.ZERO:
		var best_m = null
		var best_score = -999999.0
		for m in active_blueprint.mountains:
			var pos: Vector2 = m.get("pos", Vector2.ZERO)
			var score = pos.dot(target_dir)
			if score > best_score:
				best_score = score
				best_m = m
		if best_m != null:
			return best_m
			
	return active_blueprint.mountains[0]


func tool_modify_mountain(args: Dictionary) -> Dictionary:
	save_history_snapshot()
	var target_query = str(args.get("target", args.get("id", args.get("name", args.get("location", "northwest")))))
	var m = _resolve_mountain_target(target_query)
	if m.is_empty():
		return {"status": "warning", "message": "No mountain found matching '%s'." % target_query}
		
	var old_h = float(m.get("height", 50.0))
	if args.has("new_height") or args.has("height"):
		m["height"] = clampf(float(args.get("new_height", args.get("height", old_h))), 15.0, 125.0)
	elif args.has("height_delta"):
		m["height"] = clampf(old_h + float(args.get("height_delta", 20.0)), 15.0, 125.0)
	elif args.has("height_multiplier"):
		m["height"] = clampf(old_h * float(args.get("height_multiplier", 1.35)), 15.0, 125.0)
		
	if args.has("new_radius") or args.has("radius"):
		m["radius"] = clampf(float(args.get("new_radius", args.get("radius", m.get("radius", 65.0)))), 20.0, 160.0)
	if args.has("snow_cap") or args.has("set_snow_cap"):
		m["snow_cap"] = bool(args.get("snow_cap", args.get("set_snow_cap", true)))
	if args.has("flora_cleared") or args.has("set_flora_cleared"):
		m["flora_cleared"] = bool(args.get("flora_cleared", args.get("set_flora_cleared", false)))
		
	var summary = "Modified '%s' (ID: %s) at (%.0f, %.0f): height %.0fm -> %.0fm%s%s." % [
		str(m.get("name", "Peak")),
		str(m.get("id", "")),
		m.pos.x,
		m.pos.y,
		old_h,
		float(m["height"]),
		", snow-capped" if bool(m.get("snow_cap", false)) else "",
		", flora cleared" if bool(m.get("flora_cleared", false)) else ""
	]
	return {
		"status": "success",
		"message": summary,
		"mountain": m
	}


func tool_create_or_modify_river(args: Dictionary) -> Dictionary:
	save_history_snapshot()
	var r_name = str(args.get("name", "River"))
	var r_id = str(args.get("id", "river_" + r_name.to_snake_case()))
	var is_u_shaped = bool(args.get("is_u_shaped", false))
	var width = clampf(float(args.get("width", 8.0)), 3.0, 28.0)
	var depth = clampf(float(args.get("depth", 4.0)), 1.5, 12.0)
	var flow_speed = clampf(float(args.get("flow_speed", 0.65)), 0.1, 4.0)
	
	var points = PackedVector2Array()
	if args.has("points") and args["points"] is Array and args["points"].size() >= 2:
		for p in args["points"]:
			if p is Array and p.size() >= 2:
				points.append(Vector2(float(p[0]), float(p[1])))
			elif p is Dictionary:
				points.append(Vector2(float(p.get("x", 0)), float(p.get("z", 0))))
	elif is_u_shaped:
		var center_y = float(args.get("center_z", 40.0))
		points.append(Vector2(-90.0, center_y - 45.0))
		points.append(Vector2(-60.0, center_y + 20.0))
		points.append(Vector2(0.0, center_y + 42.0))
		points.append(Vector2(60.0, center_y + 20.0))
		points.append(Vector2(90.0, center_y - 45.0))
	else:
		var start_x = float(args.get("start_x", -80.0))
		var start_z = float(args.get("start_z", -80.0))
		var end_x = float(args.get("end_x", 80.0))
		var end_z = float(args.get("end_z", 80.0))
		var mid = Vector2(start_x + end_x, start_z + end_z) * 0.5 + Vector2(25, -20)
		points.append(Vector2(start_x, start_z))
		points.append(mid)
		points.append(Vector2(end_x, end_z))
		
	_remove_river_by_id(r_id)
	
	var springs = args.get("spring_sources", [points[0]])
	var waterfalls = args.get("waterfalls", [])
	var spline_data = ForestBlueprint.build_river_spline_data(points, 3.5)
	
	active_blueprint.rivers.append({
		"id": r_id,
		"name": r_name,
		"points": points,
		"spline_points": spline_data.spline_points,
		"distances": spline_data.distances,
		"total_length": spline_data.total_length,
		"width": width,
		"depth": depth,
		"flow_speed": flow_speed,
		"spring_sources": springs,
		"waterfalls": waterfalls
	})
	
	var summary = "Carved smooth hydraulic river channel '%s' (width: %.1fm, flow_speed: %.2f) with %d spline segments." % [
		r_name, width, flow_speed, spline_data.spline_points.size()
	]
	return {
		"status": "success",
		"message": summary,
		"river_id": r_id
	}


func _resolve_river_target(query: String) -> Dictionary:
	if active_blueprint.rivers.is_empty():
		return {}
	var q = query.to_lower().strip_edges()
	for r in active_blueprint.rivers:
		var r_name = str(r.get("name", "")).to_lower()
		var r_id = str(r.get("id", "")).to_lower()
		if not q.is_empty() and (q == r_id or q == r_name or q in r_name or r_name in q):
			return r
	if "east" in q:
		var best_r = active_blueprint.rivers[0]
		var max_x = -999999.0
		for r in active_blueprint.rivers:
			for pt in r.get("points", PackedVector2Array()):
				if pt.x > max_x:
					max_x = pt.x
					best_r = r
		return best_r
	if "west" in q:
		var best_r = active_blueprint.rivers[0]
		var min_x = 999999.0
		for r in active_blueprint.rivers:
			for pt in r.get("points", PackedVector2Array()):
				if pt.x < min_x:
					min_x = pt.x
					best_r = r
		return best_r
	# Default to longest / main river
	var main_r = active_blueprint.rivers[0]
	for r in active_blueprint.rivers:
		if float(r.get("width", 0.0)) * float(r.get("total_length", 100.0)) > float(main_r.get("width", 0.0)) * float(main_r.get("total_length", 100.0)):
			main_r = r
	return main_r


func tool_modify_river(args: Dictionary) -> Dictionary:
	save_history_snapshot()
	var target_query = str(args.get("target", args.get("id", args.get("name", "main"))))
	if target_query.to_lower() == "all":
		return tool_modify_all_rivers(args)
		
	var r = _resolve_river_target(target_query)
	if r.is_empty():
		return tool_create_or_modify_river(args)
		
	if args.has("new_width") or args.has("width"):
		r["width"] = clampf(float(args.get("new_width", args.get("width", r.get("width", 8.0)))), 3.0, 28.0)
	elif args.has("width_multiplier"):
		r["width"] = clampf(float(r.get("width", 8.0)) * float(args.get("width_multiplier", 1.5)), 3.0, 28.0)
		
	if args.has("new_depth") or args.has("depth"):
		r["depth"] = clampf(float(args.get("new_depth", args.get("depth", r.get("depth", 4.0)))), 1.5, 12.0)
	if args.has("new_flow_speed") or args.has("flow_speed"):
		r["flow_speed"] = clampf(float(args.get("new_flow_speed", args.get("flow_speed", r.get("flow_speed", 0.85)))), 0.1, 4.0)
		
	var reshaped = false
	if bool(args.get("is_u_shaped", false)):
		var center_y = float(args.get("center_z", 35.0))
		var u_pts = PackedVector2Array([
			Vector2(-85.0, center_y - 45.0),
			Vector2(-55.0, center_y + 20.0),
			Vector2(0.0, center_y + 45.0),
			Vector2(55.0, center_y + 20.0),
			Vector2(85.0, center_y - 45.0)
		])
		r["points"] = u_pts
		reshaped = true
	elif args.has("points") and args["points"] is Array and args["points"].size() >= 2:
		var new_pts = PackedVector2Array()
		for p in args["points"]:
			if p is Array and p.size() >= 2:
				new_pts.append(Vector2(float(p[0]), float(p[1])))
			elif p is Dictionary:
				new_pts.append(Vector2(float(p.get("x", 0)), float(p.get("z", 0))))
		r["points"] = new_pts
		reshaped = true
		
	if reshaped:
		var spline_data = ForestBlueprint.build_river_spline_data(r["points"], 3.5)
		r["spline_points"] = spline_data.spline_points
		r["distances"] = spline_data.distances
		r["total_length"] = spline_data.total_length
		
	var summary = "Modified river '%s' (width: %.1fm, depth: %.1fm, flow_speed: %.2f%s)." % [
		str(r.get("name", "River")),
		float(r.get("width", 8.0)),
		float(r.get("depth", 4.0)),
		float(r.get("flow_speed", 0.65)),
		", U-shaped course" if reshaped else ""
	]
	return {
		"status": "success",
		"message": summary,
		"river": r
	}


func tool_modify_all_rivers(args: Dictionary) -> Dictionary:
	save_history_snapshot()
	var w_mult = float(args.get("width_multiplier", 1.5))
	var d_mult = float(args.get("depth_multiplier", 1.15))
	var s_mult = float(args.get("speed_multiplier", 1.0))
	
	for r in active_blueprint.rivers:
		if args.has("new_width"):
			r["width"] = clampf(float(args["new_width"]), 3.0, 28.0)
		else:
			r["width"] = clampf(float(r.get("width", 8.0)) * w_mult, 3.0, 28.0)
		r["depth"] = clampf(float(r.get("depth", 4.0)) * d_mult, 1.5, 12.0)
		r["flow_speed"] = clampf(float(r.get("flow_speed", 0.65)) * s_mult, 0.1, 4.0)
		
	var summary = "Widened all %d river(s) (x%.2f width) while preserving all mountain positions." % [
		active_blueprint.rivers.size(), w_mult
	]
	return {
		"status": "success",
		"message": summary,
		"river_count": active_blueprint.rivers.size()
	}


func tool_modify_water_flow(args: Dictionary) -> Dictionary:
	save_history_snapshot()
	var target_query = str(args.get("target", args.get("river_id", "all")))
	var speed = clampf(float(args.get("flow_speed", args.get("speed", 1.1))), 0.1, 4.0)
	if target_query == "all":
		for r in active_blueprint.rivers:
			r["flow_speed"] = speed
		return {"status": "success", "message": "Set downstream directional water flow speed to %.2f on all rivers." % speed}
	else:
		var r = _resolve_river_target(target_query)
		if not r.is_empty():
			r["flow_speed"] = speed
			return {"status": "success", "message": "Set downstream flow speed to %.2f on '%s'." % [speed, str(r.get("name", "River"))]}
	return {"status": "warning", "message": "No river found to adjust flow speed."}


func tool_create_waterfall(args: Dictionary) -> Dictionary:
	save_history_snapshot()
	var target_query = str(args.get("target", args.get("river_id", "east")))
	var r = _resolve_river_target(target_query)
	if r.is_empty():
		return {"status": "warning", "message": "No river available to place a waterfall."}
		
	var pts: PackedVector2Array = r.get("spline_points", r.get("points", PackedVector2Array()))
	var pos_t = clampf(float(args.get("position_t", 0.65)), 0.1, 0.9)
	var drop = clampf(float(args.get("height_drop", 14.0)), 5.0, 35.0)
	
	var wf_pos = Vector2.ZERO
	if args.has("x") and args.has("z"):
		wf_pos = Vector2(float(args["x"]), float(args["z"]))
	elif pts.size() >= 2:
		var idx = clampi(int(pos_t * float(pts.size() - 1)), 0, pts.size() - 1)
		wf_pos = pts[idx]
		
	if not r.has("waterfalls") or not (r["waterfalls"] is Array):
		r["waterfalls"] = []
	r["waterfalls"].append({
		"id": "wf_%d" % (r["waterfalls"].size() + 1),
		"pos": wf_pos,
		"position_t": pos_t,
		"height_drop": drop
	})
	# Increase flow speed slightly for energetic cascade
	r["flow_speed"] = maxf(float(r.get("flow_speed", 0.65)), 0.95)
	
	var summary = "Created %.0fm vertical waterfall drop on '%s' at (%.0f, %.0f)." % [
		drop, str(r.get("name", "River")), wf_pos.x, wf_pos.y
	]
	return {
		"status": "success",
		"message": summary,
		"waterfall_pos": wf_pos,
		"river_id": r.get("id", "")
	}


func tool_clear_mountain_flora(args: Dictionary) -> Dictionary:
	save_history_snapshot()
	var query = str(args.get("target", args.get("feature_id", "")))
	var found_mtn = _resolve_mountain_target(query)
		
	if not found_mtn.is_empty():
		found_mtn["flora_cleared"] = true
		var summary = "Successfully cleared all trees and vegetation from '%s' (ID: %s, pos: (%.0f, %.0f), radius: %.0fm)." % [
			found_mtn.get("name", "Peak"),
			found_mtn.get("id", ""),
			found_mtn.pos.x,
			found_mtn.pos.y,
			float(found_mtn.radius)
		]
		return {
			"status": "success",
			"message": summary,
			"target": found_mtn
		}
	else:
		return {
			"status": "warning",
			"message": "No mountain peak matching '%s' found to clear." % query
		}


func tool_distribute_flora(args: Dictionary) -> Dictionary:
	save_history_snapshot()
	var action = str(args.get("action", ""))
	var target = str(args.get("feature_id", args.get("target", "")))
	
	if action == "clear" or "clear" in target.to_lower() or "remove" in target.to_lower():
		return tool_clear_mountain_flora({"target": target})
		
	var density_mult = clampf(float(args.get("density_multiplier", 1.5)), 0.1, 4.0)
	var specific_archetype = str(args.get("archetype", ""))
	var custom_color_str = str(args.get("color", ""))
	var riverbank_only = bool(args.get("riverbank_only", false))
	
	if riverbank_only or not custom_color_str.is_empty():
		var new_layer = ForestBlueprint.FloraLayerConfig.new()
		new_layer.archetype = specific_archetype if not specific_archetype.is_empty() else "fern"
		new_layer.name = "Riverbank %s" % new_layer.archetype.capitalize()
		new_layer.distribution = "riverbank_focused"
		new_layer.density = 0.035 * density_mult
		new_layer.near_water_only = true
		if not custom_color_str.is_empty():
			new_layer.foliage_color = ForestBlueprint.parse_color(custom_color_str, Color.FOREST_GREEN)
			if custom_color_str.to_lower() in ["cyan", "neon green", "violet", "magenta"]:
				new_layer.emissive = true
				new_layer.emissive_color = new_layer.foliage_color
				new_layer.emissive_energy = 1.8
		else:
			new_layer.foliage_color = Color(0.12, 0.58, 0.22)
		active_blueprint.vegetation_layers.append(new_layer)
		var summary = "Added dense %s vegetation concentrated along riverbanks (density %.3f)." % [
			new_layer.name, new_layer.density
		]
		return {"status": "success", "message": summary}
		
	for l in active_blueprint.vegetation_layers:
		if specific_archetype.is_empty() or l.archetype == specific_archetype:
			l.density = clampf(l.density * density_mult, 0.001, 0.6)
			
	var summary = "Adjusted vegetation density (x%.1f) across target area." % density_mult
	return {"status": "success", "message": summary}


func tool_modify_terrain_region(args: Dictionary) -> Dictionary:
	save_history_snapshot()
	var cx = float(args.get("center_x", 0.0))
	var cz = float(args.get("center_z", 0.0))
	var rad = clampf(float(args.get("radius", 65.0)), 10.0, 200.0)
	var height_delta = float(args.get("height_delta", 50.0))
	var name_str = str(args.get("name", "Elevated Formation"))
	
	active_blueprint.mountains.append({
		"id": "mtn_region_%d" % (active_blueprint.mountains.size() + 1),
		"name": name_str,
		"pos": Vector2(cx, cz),
		"height": height_delta,
		"radius": rad,
		"snow_cap": height_delta > 45.0,
		"flora_cleared": false
	})
	
	var summary = "Created %s at (%.0f, %.0f) with height %.0fm and radius %.0fm." % [
		name_str, cx, cz, height_delta, rad
	]
	return {
		"status": "success",
		"message": summary
	}


func tool_set_biome_region(args: Dictionary) -> Dictionary:
	save_history_snapshot()
	var b_name = str(args.get("name", "Custom Biome"))
	var b_id = str(args.get("id", "biome_" + b_name.to_snake_case()))
	var cx = float(args.get("center_x", 0.0))
	var cz = float(args.get("center_z", 0.0))
	var rad = clampf(float(args.get("radius", 60.0)), 15.0, 180.0)
	var gt = ForestBlueprint.parse_color(args.get("ground_tint", "forest green"), Color(0.2, 0.6, 0.2))
	var fc = ForestBlueprint.parse_color(args.get("foliage_color", "emerald"), Color(0.1, 0.8, 0.4))
	var boost = clampf(float(args.get("boost", 1.2)), 0.2, 3.0)
	
	_remove_biome_by_id(b_id)
	active_blueprint.biome_regions.append({
		"id": b_id,
		"name": b_name,
		"center": Vector2(cx, cz),
		"radius": rad,
		"ground_tint": gt,
		"foliage_color": fc,
		"boost": boost
	})
	
	var summary = "Defined biome region '%s' at (%.0f, %.0f) with radius %.0fm." % [
		b_name, cx, cz, rad
	]
	return {
		"status": "success",
		"message": summary,
		"biome_id": b_id
	}


func tool_modify_biome(args: Dictionary) -> Dictionary:
	save_history_snapshot()
	var target = str(args.get("target", "")).to_lower()
	for b in active_blueprint.biome_regions:
		if target.is_empty() or target in str(b.get("name", "")).to_lower() or target in str(b.get("id", "")).to_lower():
			if args.has("ground_tint"):
				b["ground_tint"] = ForestBlueprint.parse_color(args["ground_tint"], b["ground_tint"])
			if args.has("foliage_color"):
				b["foliage_color"] = ForestBlueprint.parse_color(args["foliage_color"], b["foliage_color"])
			if args.has("boost"):
				b["boost"] = clampf(float(args["boost"]), 0.2, 3.0)
			if args.has("radius_delta"):
				b["radius"] = clampf(float(b.get("radius", 60.0)) + float(args["radius_delta"]), 15.0, 180.0)
			return {"status": "success", "message": "Updated biome region '%s'." % str(b.get("name", "Biome"))}
	return tool_set_biome_region(args)


func tool_set_regional_snow(args: Dictionary) -> Dictionary:
	save_history_snapshot()
	var enabled = bool(args.get("enabled", true))
	var changed_regions = []
	for dir_key in ["south", "north", "east", "west"]:
		if args.has(dir_key):
			active_blueprint.regional_snow[dir_key] = bool(args[dir_key])
			if bool(args[dir_key]):
				changed_regions.append(dir_key)
	var region_str = str(args.get("region", "")).to_lower()
	for dir_key in ["south", "north", "east", "west"]:
		if dir_key in region_str:
			active_blueprint.regional_snow[dir_key] = enabled
			if not (dir_key in changed_regions):
				changed_regions.append(dir_key)
				
	var summary = "Applied regional snow cover to %s region(s) while leaving other regions unchanged." % (
		", ".join(changed_regions) if changed_regions.size() > 0 else "target"
	)
	return {
		"status": "success",
		"message": summary,
		"regional_snow": active_blueprint.regional_snow
	}


func tool_add_landmark(args: Dictionary) -> Dictionary:
	save_history_snapshot()
	var lm_name = str(args.get("name", "Ancient Monolith"))
	var lm_type = str(args.get("type", "monolith"))
	var lx = float(args.get("x", 0.0))
	var lz = float(args.get("z", 0.0))
	
	active_blueprint.landmarks.append({
		"id": "lm_" + lm_name.to_snake_case(),
		"name": lm_name,
		"type": lm_type,
		"pos": Vector2(lx, lz)
	})
	
	var summary = "Placed %s landmark at (%.0f, %.0f)." % [lm_name, lx, lz]
	return {"status": "success", "message": summary}


func tool_regenerate_world_map(_args: Dictionary) -> Dictionary:
	return {
		"status": "success",
		"map_dirty": true,
		"message": "Regenerated satellite world map texture from current elevation, hydrology, and flora state."
	}


func tool_undo_last_edit(_args: Dictionary) -> Dictionary:
	if history_stack.is_empty():
		return {
			"status": "warning",
			"message": "No previous edits to undo."
		}
	var prev = history_stack.pop_back()
	active_blueprint = prev
	return {
		"status": "success",
		"message": "Reverted to previous world state.",
		"blueprint": active_blueprint
	}


func _remove_river_by_id(id: String) -> void:
	for i in range(active_blueprint.rivers.size() - 1, -1, -1):
		if active_blueprint.rivers[i].get("id") == id:
			active_blueprint.rivers.remove_at(i)


func _remove_biome_by_id(id: String) -> void:
	for i in range(active_blueprint.biome_regions.size() - 1, -1, -1):
		if active_blueprint.biome_regions[i].get("id") == id:
			active_blueprint.biome_regions.remove_at(i)
