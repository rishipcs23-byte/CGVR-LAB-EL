# WorldMap.gd
class_name WorldMap
extends Control

const SatelliteMapRenderer = preload("res://SatelliteMapRenderer.gd")

signal feature_selected(feature: Dictionary)
signal map_mode_changed(is_expanded: bool)

enum Mode { MINIMAP, EXPANDED }

@export var mode: Mode = Mode.MINIMAP
@export var player: CharacterBody3D
var blueprint: ForestBlueprint = null
var satellite_texture: ImageTexture = null

# World Coordinate Range mapped onto UI
var world_min: Vector2 = Vector2(-200.0, -200.0)
var world_max: Vector2 = Vector2(200.0, 200.0)

# Expanded Viewport Pan & Zoom
var zoom_level: float = 1.0
var pan_offset: Vector2 = Vector2.ZERO
var is_dragging: bool = false
var drag_start: Vector2 = Vector2.ZERO

# Selection & Hover State
var selected_feature: Dictionary = {}
var hovered_feature: Dictionary = {}

# Theme Palette (Charcoal, Warm Off-White, Forest Green, Amber)
const COLOR_BG = Color(0.06, 0.08, 0.10, 0.96)
const COLOR_GRID = Color(0.85, 0.90, 0.95, 0.12)
const COLOR_BORDER = Color(0.25, 0.32, 0.38, 0.95)
const COLOR_MOUNTAIN = Color(0.92, 0.95, 0.98, 0.9)
const COLOR_RIVER = Color(0.25, 0.68, 0.98, 0.9)
const COLOR_PLAYER = Color(0.98, 0.78, 0.12, 1.0)
const COLOR_SELECT = Color(0.96, 0.62, 0.05, 1.0)
const COLOR_TEXT = Color(0.92, 0.94, 0.96, 0.95)
const COLOR_TEXT_MUTED = Color(0.72, 0.78, 0.82, 0.9)


func _ready():
	custom_minimum_size = Vector2(220, 220) if mode == Mode.MINIMAP else Vector2(720, 520)
	clip_contents = true
	set_process(true)
	if blueprint != null and satellite_texture == null:
		regenerate_satellite(blueprint)


func _process(_delta: float) -> void:
	if is_visible_in_tree():
		queue_redraw()


func set_blueprint(new_bp: ForestBlueprint) -> void:
	blueprint = new_bp
	selected_feature.clear()
	hovered_feature.clear()
	regenerate_satellite(new_bp)


func regenerate_satellite(bp: ForestBlueprint = null) -> void:
	if bp != null:
		blueprint = bp
	if blueprint != null:
		var res = 160 if mode == Mode.MINIMAP else 200
		satellite_texture = SatelliteMapRenderer.render(blueprint, res, world_min, world_max, true)
	queue_redraw()


func set_mode(new_mode: Mode) -> void:
	mode = new_mode
	if mode == Mode.MINIMAP:
		zoom_level = 1.0
		pan_offset = Vector2.ZERO
		custom_minimum_size = Vector2(220, 220)
	else:
		custom_minimum_size = Vector2(720, 520)
	emit_signal("map_mode_changed", mode == Mode.EXPANDED)
	queue_redraw()


func toggle_mode() -> void:
	set_mode(Mode.EXPANDED if mode == Mode.MINIMAP else Mode.MINIMAP)


func _get_map_draw_rect() -> Rect2:
	var rect_sz = size
	if mode == Mode.EXPANDED:
		var center = rect_sz * 0.5
		var draw_w = rect_sz.x * zoom_level
		var draw_h = rect_sz.y * zoom_level
		var top_left = Vector2(center.x - draw_w * 0.5 + pan_offset.x, center.y - draw_h * 0.5 + pan_offset.y)
		return Rect2(top_left, Vector2(draw_w, draw_h))
	else:
		var pad = 8.0
		return Rect2(Vector2(pad, pad), Vector2(rect_sz.x - pad * 2.0, rect_sz.y - pad * 2.0))


func world_to_map_pos(w_pos: Vector2) -> Vector2:
	var norm_x = (w_pos.x - world_min.x) / (world_max.x - world_min.x)
	var norm_y = (w_pos.y - world_min.y) / (world_max.y - world_min.y)
	var map_rect = _get_map_draw_rect()
	return Vector2(
		map_rect.position.x + norm_x * map_rect.size.x,
		map_rect.position.y + norm_y * map_rect.size.y
	)


func map_to_world_pos(m_pos: Vector2) -> Vector2:
	var map_rect = _get_map_draw_rect()
	var norm_x = (m_pos.x - map_rect.position.x) / maxf(map_rect.size.x, 1.0)
	var norm_y = (m_pos.y - map_rect.position.y) / maxf(map_rect.size.y, 1.0)
	return Vector2(
		world_min.x + norm_x * (world_max.x - world_min.x),
		world_min.y + norm_y * (world_max.y - world_min.y)
	)


func _gui_input(event: InputEvent) -> void:
	if mode != Mode.EXPANDED:
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			toggle_mode()
			accept_event()
		return

	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			zoom_level = clampf(zoom_level * 1.15, 0.6, 4.0)
			queue_redraw()
			accept_event()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			zoom_level = clampf(zoom_level / 1.15, 0.6, 4.0)
			queue_redraw()
			accept_event()
		elif event.button_index == MOUSE_BUTTON_MIDDLE or (event.button_index == MOUSE_BUTTON_LEFT and Input.is_key_pressed(KEY_SPACE)):
			is_dragging = event.pressed
			drag_start = event.position
			accept_event()
		elif event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			_select_feature_at_mouse(event.position)
			accept_event()

	elif event is InputEventMouseMotion:
		if is_dragging:
			pan_offset += event.position - drag_start
			drag_start = event.position
			queue_redraw()
			accept_event()
		else:
			_hover_feature_at_mouse(event.position)


func _select_feature_at_mouse(m_pos: Vector2) -> void:
	var w_click = map_to_world_pos(m_pos)
	var best_f = _find_nearest_feature(w_click, 30.0 / zoom_level)
	if not best_f.is_empty():
		selected_feature = best_f
		emit_signal("feature_selected", selected_feature)
	else:
		selected_feature.clear()
	queue_redraw()


func _hover_feature_at_mouse(m_pos: Vector2) -> void:
	var w_click = map_to_world_pos(m_pos)
	var best_f = _find_nearest_feature(w_click, 25.0 / zoom_level)
	if best_f != hovered_feature:
		hovered_feature = best_f
		queue_redraw()


func _find_nearest_feature(w_pos: Vector2, threshold: float) -> Dictionary:
	if not blueprint:
		return {}
		
	var best_dist = threshold
	var found = {}
	
	# Check Mountains
	for m in blueprint.mountains:
		var d = w_pos.distance_to(m.pos)
		if d < best_dist:
			best_dist = d
			found = {"type": "mountain", "id": m.id, "name": m.name, "pos": m.pos, "height": m.height, "data": m}
			
	# Check Lakes
	for l in blueprint.lakes:
		var d = w_pos.distance_to(l.center)
		if d < best_dist:
			best_dist = d
			found = {"type": "lake", "id": l.id, "name": l.name, "pos": l.center, "data": l}
			
	# Check Rivers (using smooth spline points)
	for r in blueprint.rivers:
		var pts: PackedVector2Array = r.get("spline_points", r.get("points", PackedVector2Array()))
		for pt in pts:
			var d = w_pos.distance_to(pt)
			if d < best_dist:
				best_dist = d
				found = {"type": "river", "id": r.id, "name": r.name, "pos": pt, "data": r}
				
	# Check Biome Regions
	for b in blueprint.biome_regions:
		var d = w_pos.distance_to(b.center)
		if d < best_dist:
			best_dist = d
			found = {"type": "biome", "id": b.id, "name": b.name, "pos": b.center, "data": b}
			
	return found


func _draw() -> void:
	var rect_sz = size
	draw_rect(Rect2(Vector2.ZERO, rect_sz), COLOR_BG, true)
	
	var map_rect = _get_map_draw_rect()
	
	# 1. Draw Satellite Terrain Texture generated from actual world heightfield, hydrology & flora
	if satellite_texture != null:
		draw_texture_rect(satellite_texture, map_rect, false)
	
	# 2. Subtle Coordinate Grid Overlay
	var grid_step = 50.0
	var min_gx = floor(world_min.x / grid_step) * grid_step
	var max_gx = ceil(world_max.x / grid_step) * grid_step
	for gx in range(int(min_gx), int(max_gx) + 1, int(grid_step)):
		var p1 = world_to_map_pos(Vector2(gx, world_min.y))
		var p2 = world_to_map_pos(Vector2(gx, world_max.y))
		draw_line(p1, p2, COLOR_GRID, 1.0)
		
	var min_gz = floor(world_min.y / grid_step) * grid_step
	var max_gz = ceil(world_max.y / grid_step) * grid_step
	for gz in range(int(min_gz), int(max_gz) + 1, int(grid_step)):
		var p1 = world_to_map_pos(Vector2(world_min.x, gz))
		var p2 = world_to_map_pos(Vector2(world_max.x, gz))
		draw_line(p1, p2, COLOR_GRID, 1.0)

	# 3. Feature Annotations & Overlays
	if blueprint:
		# Highlight river flow direction and waterfalls
		for r in blueprint.rivers:
			for s in r.get("spring_sources", []):
				if s is Vector2:
					draw_circle(world_to_map_pos(s), 3.0, Color(0.4, 0.95, 1.0, 0.9))
			for wf in r.get("waterfalls", []):
				var wf_pos = wf.get("pos", Vector2.ZERO)
				var wf_map = world_to_map_pos(wf_pos)
				draw_circle(wf_map, 4.5, Color(0.95, 0.98, 1.0, 0.95))
				draw_arc(wf_map, 6.5, 0, TAU, 16, Color(0.2, 0.85, 1.0, 0.9), 1.5)
				if mode == Mode.EXPANDED:
					draw_string(ThemeDB.fallback_font, wf_map + Vector2(8, 3), "Waterfall (-%.0fm)" % float(wf.get("height_drop", 12.0)), HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(0.75, 0.95, 1.0))

		# Peak summit markers & elevation labels in Expanded mode
		for m in blueprint.mountains:
			var m_pos = world_to_map_pos(m.pos)
			var summit_col = Color.WHITE if m.get("snow_cap", false) else COLOR_MOUNTAIN
			draw_circle(m_pos, 3.0, summit_col)
			draw_arc(m_pos, 5.5, 0, TAU, 16, Color(0, 0, 0, 0.65), 1.2)
			if mode == Mode.EXPANDED:
				var label_str = "%s (%.0fm)" % [str(m.get("name", "Peak")), float(m.get("height", 50.0))]
				draw_string(ThemeDB.fallback_font, m_pos + Vector2(8, 4), label_str, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, COLOR_TEXT)

		# Landmarks
		for lm in blueprint.landmarks:
			var lm_pos = world_to_map_pos(lm.pos)
			draw_rect(Rect2(lm_pos - Vector2(3, 3), Vector2(6, 6)), Color.LIGHT_CORAL, true)

	# 4. Selected / Hovered Feature Highlight
	if not selected_feature.is_empty():
		var sel_pos = world_to_map_pos(selected_feature.get("pos", Vector2.ZERO))
		draw_arc(sel_pos, 14.0, 0, TAU, 24, COLOR_SELECT, 2.0)
		draw_string(ThemeDB.fallback_font, sel_pos + Vector2(16, 4), str(selected_feature.get("name", "")), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, COLOR_SELECT)
		
	if not hovered_feature.is_empty() and hovered_feature != selected_feature:
		var hov_pos = world_to_map_pos(hovered_feature.get("pos", Vector2.ZERO))
		draw_arc(hov_pos, 10.0, 0, TAU, 16, Color.WHITE, 1.0)

	# 5. Live Player Marker (Triangle pointing in heading direction)
	if is_instance_valid(player):
		var p_xz = Vector2(player.global_position.x, player.global_position.z)
		var p_map = world_to_map_pos(p_xz)
		
		var forward = -player.global_transform.basis.z
		var angle = atan2(forward.x, -forward.z)
		
		var p_size = 7.0
		var p_tip = p_map + Vector2(sin(angle), -cos(angle)) * p_size * 1.5
		var p_l = p_map + Vector2(sin(angle + 2.4), -cos(angle + 2.4)) * p_size
		var p_r = p_map + Vector2(sin(angle - 2.4), -cos(angle - 2.4)) * p_size
		
		draw_colored_polygon(PackedVector2Array([p_tip, p_r, p_l]), COLOR_PLAYER)
		draw_circle(p_map, 2.5, Color.BLACK)

	# Crisp Minimal Outer Border & Header Label
	draw_rect(Rect2(Vector2.ZERO, rect_sz), COLOR_BORDER, false, 1.5)
	
	var header_bg = Rect2(Vector2(1, 1), Vector2(rect_sz.x - 2, 22))
	draw_rect(header_bg, Color(0.04, 0.06, 0.08, 0.78), true)
	var mode_text = "SATELLITE MAP [M]" if mode == Mode.MINIMAP else "SATELLITE SURVEY [M] — SCROLL ZOOM · CLICK TO INSPECT"
	draw_string(ThemeDB.fallback_font, Vector2(8, 15), mode_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, COLOR_TEXT_MUTED)
