# ForestConsole.gd
class_name ForestConsole
extends CanvasLayer

signal request_generate(prompt: String, multi_agent: bool)

@export var player: CharacterBody3D
@export var chunk_manager: Node3D
@export var forest_architect: ForestArchitect

enum StudioState { STUDIO_LANDING, GENERATING, IN_EXPLORER }
var current_state: StudioState = StudioState.STUDIO_LANDING

# UI Controls created dynamically with the square minimalist design system
var landing_overlay: Control
var creation_overlay: Control
var explorer_hud: Control
var expanded_map_overlay: Control
var world_map_minimap: Control
var world_map_expanded: Control

# UI Elements inside Landing Screen
var prompt_input: LineEdit
var create_btn: Button
var random_btn: Button
var ai_status_badge: Label
var typewriter_label: Label
var seed_input: SpinBox

# UI Elements inside Creation Screen
var creation_stage_label: Label
var creation_progress_bar: ProgressBar
var creation_detail_label: Label

# UI Elements inside Explorer HUD
var hud_biome_label: Label
var hud_stats_label: Label
var edit_input: LineEdit
var edit_btn: Button
var edit_status_label: Label
var undo_btn: Button
var return_studio_btn: Button

# Typewriter & Suggestions State
var suggestion_index: int = 0
var typewriter_timer: float = 0.0
var typewriter_char_idx: int = 0
var is_typing: bool = false
var active_suggestion_text: String = ""

# Map & Feature Selection Context
var selected_feature_context: Dictionary = {}

const WorldMapClass = preload("res://WorldMap.gd")


func _ready():
	_build_ui_nodes()
	_apply_square_minimalist_theme()
	
	if forest_architect:
		forest_architect.started.connect(_on_architect_started)
		forest_architect.status_updated.connect(_on_architect_status)
		forest_architect.blueprint_ready.connect(_on_blueprint_ready)
		forest_architect.edit_completed.connect(_on_edit_completed)
		forest_architect.suggestions_ready.connect(_on_suggestions_ready)
		forest_architect.failed.connect(_on_architect_failed)
		
	_check_ollama_status()
	_start_suggestion_rotation()
	
	# Start in Creator Studio
	_set_studio_state(StudioState.STUDIO_LANDING)


func _process(delta: float) -> void:
	if current_state == StudioState.STUDIO_LANDING and is_typing:
		typewriter_timer += delta
		if typewriter_timer >= 0.035:
			typewriter_timer = 0.0
			typewriter_char_idx += 1
			if typewriter_char_idx <= active_suggestion_text.length():
				typewriter_label.text = active_suggestion_text.substr(0, typewriter_char_idx) + "▊"
			else:
				typewriter_label.text = active_suggestion_text
				is_typing = false


func _unhandled_input(event: InputEvent) -> void:
	if current_state == StudioState.IN_EXPLORER:
		if event is InputEventKey and event.pressed:
			if event.keycode == KEY_M:
				_toggle_expanded_map()
				get_viewport().set_input_as_handled()
			elif event.keycode == KEY_T or event.keycode == KEY_QUOTELEFT:
				if not edit_input.has_focus():
					edit_input.grab_focus()
					if is_instance_valid(player) and player.has_method("set_input_enabled"):
						player.set_input_enabled(false)
					get_viewport().set_input_as_handled()
			elif event.keycode == KEY_ESCAPE:
				if expanded_map_overlay.visible:
					_toggle_expanded_map()
					get_viewport().set_input_as_handled()
				elif edit_input.has_focus():
					edit_input.release_focus()
					if is_instance_valid(player) and player.has_method("set_input_enabled"):
						player.set_input_enabled(true)
					get_viewport().set_input_as_handled()


func _set_studio_state(new_state: StudioState) -> void:
	current_state = new_state
	landing_overlay.visible = (new_state == StudioState.STUDIO_LANDING)
	creation_overlay.visible = (new_state == StudioState.GENERATING)
	explorer_hud.visible = (new_state == StudioState.IN_EXPLORER)
	expanded_map_overlay.visible = false
	
	if is_instance_valid(player) and player.has_method("set_input_enabled"):
		player.set_input_enabled(new_state == StudioState.IN_EXPLORER)


func _build_ui_nodes() -> void:
	# Root container
	var root_ctrl = Control.new()
	root_ctrl.name = "StudioRoot"
	root_ctrl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(root_ctrl)
	
	# =========================================================================
	# 1. LANDING OVERLAY (Creator's Studio)
	# =========================================================================
	landing_overlay = Control.new()
	landing_overlay.name = "LandingOverlay"
	landing_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root_ctrl.add_child(landing_overlay)
	
	# Background Vignette Panel
	var bg_vignette = Panel.new()
	bg_vignette.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var vig_style = StyleBoxFlat.new()
	vig_style.bg_color = Color(0.04, 0.06, 0.08, 0.65)
	bg_vignette.add_theme_stylebox_override("panel", vig_style)
	landing_overlay.add_child(bg_vignette)
	
	# Main Centered Card Panel (Crisp square corners)
	var landing_card = PanelContainer.new()
	landing_card.custom_minimum_size = Vector2(740, 520)
	landing_card.set_anchors_preset(Control.PRESET_CENTER)
	landing_card.grow_horizontal = Control.GROW_DIRECTION_BOTH
	landing_card.grow_vertical = Control.GROW_DIRECTION_BOTH
	
	var card_style = StyleBoxFlat.new()
	card_style.bg_color = Color(0.08, 0.10, 0.12, 0.94)
	card_style.border_color = Color(0.24, 0.30, 0.36, 0.9)
	card_style.set_border_width_all(1)
	card_style.set_corner_radius_all(0) # SQUARE CORNERS
	card_style.content_margin_left = 36
	card_style.content_margin_right = 36
	card_style.content_margin_top = 32
	card_style.content_margin_bottom = 32
	landing_card.add_theme_stylebox_override("panel", card_style)
	landing_overlay.add_child(landing_card)
	
	var card_vbox = VBoxContainer.new()
	card_vbox.add_theme_constant_override("separation", 14)
	landing_card.add_child(card_vbox)
	
	# Top Header Row: Brand & AI Status
	var header_hbox = HBoxContainer.new()
	var title_lbl = Label.new()
	title_lbl.text = "SUBLIMEGREENS"
	title_lbl.add_theme_color_override("font_color", Color(0.95, 0.96, 0.98))
	title_lbl.add_theme_font_size_override("font_size", 22)
	header_hbox.add_child(title_lbl)
	
	var tag_lbl = Label.new()
	tag_lbl.text = "  ·  AI-ASSISTED TERRAIN BUILDER"
	tag_lbl.add_theme_color_override("font_color", Color(0.45, 0.75, 0.50))
	tag_lbl.add_theme_font_size_override("font_size", 12)
	header_hbox.add_child(tag_lbl)
	
	var spacer1 = Control.new()
	spacer1.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_hbox.add_child(spacer1)
	
	ai_status_badge = Label.new()
	ai_status_badge.text = "AI: CONNECTING..."
	ai_status_badge.add_theme_color_override("font_color", Color(0.85, 0.65, 0.15))
	ai_status_badge.add_theme_font_size_override("font_size", 11)
	header_hbox.add_child(ai_status_badge)
	card_vbox.add_child(header_hbox)
	
	var subhead_lbl = Label.new()
	subhead_lbl.text = "Shape worlds that have never existed. Describe a landscape. Collaborate with AI."
	subhead_lbl.add_theme_color_override("font_color", Color(0.65, 0.70, 0.75))
	subhead_lbl.add_theme_font_size_override("font_size", 12)
	card_vbox.add_child(subhead_lbl)
	
	var sep1 = HSeparator.new()
	sep1.add_theme_constant_override("separation", 10)
	card_vbox.add_child(sep1)
	
	# Rotating Suggestion Banner
	var sugg_box = PanelContainer.new()
	var sugg_style = StyleBoxFlat.new()
	sugg_style.bg_color = Color(0.12, 0.15, 0.18, 0.8)
	sugg_style.border_color = Color(0.20, 0.26, 0.32, 0.7)
	sugg_style.set_border_width_all(1)
	sugg_style.set_corner_radius_all(0)
	sugg_style.content_margin_left = 12
	sugg_style.content_margin_right = 12
	sugg_style.content_margin_top = 8
	sugg_style.content_margin_bottom = 8
	sugg_box.add_theme_stylebox_override("panel", sugg_style)
	
	var sugg_vbox = VBoxContainer.new()
	var sugg_header = Label.new()
	sugg_header.text = "CREATIVE INTELLIGENCE SUGGESTION:"
	sugg_header.add_theme_color_override("font_color", Color(0.96, 0.62, 0.05))
	sugg_header.add_theme_font_size_override("font_size", 10)
	sugg_vbox.add_child(sugg_header)
	
	typewriter_label = Label.new()
	typewriter_label.text = ""
	typewriter_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	typewriter_label.add_theme_color_override("font_color", Color(0.85, 0.88, 0.92))
	typewriter_label.add_theme_font_size_override("font_size", 12)
	sugg_vbox.add_child(typewriter_label)
	sugg_box.add_child(sugg_vbox)
	card_vbox.add_child(sugg_box)
	
	# Main Prompt Input
	var input_lbl = Label.new()
	input_lbl.text = "DESCRIBE YOUR WORLD CONCEPT:"
	input_lbl.add_theme_color_override("font_color", Color(0.70, 0.75, 0.80))
	input_lbl.add_theme_font_size_override("font_size", 11)
	card_vbox.add_child(input_lbl)
	
	prompt_input = LineEdit.new()
	prompt_input.placeholder_text = "e.g. Create three snowy peaks in the northwest, with two springs joining into a U-shaped river..."
	prompt_input.custom_minimum_size = Vector2(0, 44)
	prompt_input.text = "Create three snowy peaks in the northwest, with two springs joining into a U-shaped river across the southern plains."
	prompt_input.text_submitted.connect(func(_t): _on_create_pressed())
	card_vbox.add_child(prompt_input)
	
	# Curated Quick Presets Grid
	var presets_lbl = Label.new()
	presets_lbl.text = "CATALOG ARCHETYPES:"
	presets_lbl.add_theme_color_override("font_color", Color(0.55, 0.60, 0.65))
	presets_lbl.add_theme_font_size_override("font_size", 10)
	card_vbox.add_child(presets_lbl)
	
	var presets_grid = GridContainer.new()
	presets_grid.columns = 3
	presets_grid.add_theme_constant_override("h_separation", 8)
	presets_grid.add_theme_constant_override("v_separation", 6)
	
	_add_preset_button(presets_grid, "Three Alpine Peaks", "Create three snowy peaks in the northwest, with two springs joining into a U-shaped river across the southern plains.")
	_add_preset_button(presets_grid, "Alien Wetland Lakes", "Create a dense alien wetland with unusual flora clustered around several connected lakes.")
	_add_preset_button(presets_grid, "Crystal Spires", "Generate a floating crystal forest with prismatic spires and glowing night blooms.")
	_add_preset_button(presets_grid, "Fungal Marsh", "An ancient bioluminescent fungal basin with giant spore trees and cyan mist.")
	_add_preset_button(presets_grid, "Volcanic Rift", "An obsidian canyon with crimson ember showers and glowing magma flora.")
	_add_preset_button(presets_grid, "Riverbank Flora", "Make the valley wetter, introduce unusual blue vegetation along the riverbanks, and leave the central clearing untouched.")
	card_vbox.add_child(presets_grid)
	
	var sep2 = HSeparator.new()
	sep2.add_theme_constant_override("separation", 8)
	card_vbox.add_child(sep2)
	
	# Action Buttons Row
	var actions_hbox = HBoxContainer.new()
	actions_hbox.add_theme_constant_override("separation", 12)
	
	create_btn = Button.new()
	create_btn.text = "CREATE WORLD [ENTER]"
	create_btn.custom_minimum_size = Vector2(240, 42)
	create_btn.pressed.connect(_on_create_pressed)
	actions_hbox.add_child(create_btn)
	
	random_btn = Button.new()
	random_btn.text = "EXPLORE A RANDOM WORLD"
	random_btn.custom_minimum_size = Vector2(220, 42)
	random_btn.pressed.connect(_on_random_pressed)
	actions_hbox.add_child(random_btn)
	
	var spacer2 = Control.new()
	spacer2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	actions_hbox.add_child(spacer2)
	
	var seed_lbl = Label.new()
	seed_lbl.text = "SEED:"
	seed_lbl.add_theme_color_override("font_color", Color(0.6, 0.65, 0.7))
	seed_lbl.add_theme_font_size_override("font_size", 11)
	actions_hbox.add_child(seed_lbl)
	
	seed_input = SpinBox.new()
	seed_input.min_value = 1
	seed_input.max_value = 999999
	seed_input.value = 42
	actions_hbox.add_child(seed_input)
	card_vbox.add_child(actions_hbox)

	# =========================================================================
	# 2. CREATION OVERLAY (Multi-Stage Animated Sequence)
	# =========================================================================
	creation_overlay = Control.new()
	creation_overlay.name = "CreationOverlay"
	creation_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root_ctrl.add_child(creation_overlay)
	
	var cr_bg = Panel.new()
	cr_bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var cr_style = StyleBoxFlat.new()
	cr_style.bg_color = Color(0.05, 0.07, 0.09, 0.92)
	cr_bg.add_theme_stylebox_override("panel", cr_style)
	creation_overlay.add_child(cr_bg)
	
	var cr_card = PanelContainer.new()
	cr_card.custom_minimum_size = Vector2(560, 240)
	cr_card.set_anchors_preset(Control.PRESET_CENTER)
	cr_card.grow_horizontal = Control.GROW_DIRECTION_BOTH
	cr_card.grow_vertical = Control.GROW_DIRECTION_BOTH
	cr_card.add_theme_stylebox_override("panel", card_style)
	creation_overlay.add_child(cr_card)
	
	var cr_vbox = VBoxContainer.new()
	cr_vbox.add_theme_constant_override("separation", 16)
	cr_card.add_child(cr_vbox)
	
	var cr_head = Label.new()
	cr_head.text = "GENERATING SUBLIMEGREENS WORLD"
	cr_head.add_theme_color_override("font_color", Color(0.45, 0.75, 0.50))
	cr_head.add_theme_font_size_override("font_size", 13)
	cr_vbox.add_child(cr_head)
	
	creation_stage_label = Label.new()
	creation_stage_label.text = "01 — Interpreting your vision (Qwen3:4B)"
	creation_stage_label.add_theme_color_override("font_color", Color.WHITE)
	creation_stage_label.add_theme_font_size_override("font_size", 18)
	cr_vbox.add_child(creation_stage_label)
	
	creation_progress_bar = ProgressBar.new()
	creation_progress_bar.custom_minimum_size = Vector2(0, 10)
	creation_progress_bar.show_percentage = false
	creation_progress_bar.value = 25.0
	cr_vbox.add_child(creation_progress_bar)
	
	creation_detail_label = Label.new()
	creation_detail_label.text = "Synthesizing landforms, waterways, and biomes into deterministic blueprint..."
	creation_detail_label.add_theme_color_override("font_color", Color(0.65, 0.70, 0.75))
	creation_detail_label.add_theme_font_size_override("font_size", 12)
	cr_vbox.add_child(creation_detail_label)

	# =========================================================================
	# 3. IMMERSIVE EXPLORER HUD
	# =========================================================================
	explorer_hud = Control.new()
	explorer_hud.name = "ExplorerHud"
	explorer_hud.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root_ctrl.add_child(explorer_hud)
	
	# Top-Left Minimalist Header
	var top_left_panel = PanelContainer.new()
	top_left_panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	top_left_panel.offset_left = 20
	top_left_panel.offset_top = 20
	var tl_style = StyleBoxFlat.new()
	tl_style.bg_color = Color(0.08, 0.10, 0.12, 0.88)
	tl_style.border_color = Color(0.25, 0.30, 0.35, 0.8)
	tl_style.set_border_width_all(1)
	tl_style.set_corner_radius_all(0)
	tl_style.content_margin_left = 16
	tl_style.content_margin_right = 16
	tl_style.content_margin_top = 10
	tl_style.content_margin_bottom = 10
	top_left_panel.add_theme_stylebox_override("panel", tl_style)
	
	var tl_vbox = VBoxContainer.new()
	hud_biome_label = Label.new()
	hud_biome_label.text = "SUBLIMEGREENS · ALIVE"
	hud_biome_label.add_theme_color_override("font_color", Color(0.45, 0.75, 0.50))
	hud_biome_label.add_theme_font_size_override("font_size", 14)
	tl_vbox.add_child(hud_biome_label)
	
	hud_stats_label = Label.new()
	hud_stats_label.text = "WASD: Walk  |  SHIFT: Sprint  |  SPACE: Jump  |  M: Map  |  T: AI Edit"
	hud_stats_label.add_theme_color_override("font_color", Color(0.70, 0.75, 0.80))
	hud_stats_label.add_theme_font_size_override("font_size", 11)
	tl_vbox.add_child(hud_stats_label)
	top_left_panel.add_child(tl_vbox)
	explorer_hud.add_child(top_left_panel)
	
	# Bottom-Right Minimap Container
	var minimap_container = PanelContainer.new()
	minimap_container.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	minimap_container.offset_right = -20
	minimap_container.offset_bottom = -20
	minimap_container.offset_left = -244
	minimap_container.offset_top = -244
	minimap_container.add_theme_stylebox_override("panel", tl_style)
	
	world_map_minimap = WorldMapClass.new()
	world_map_minimap.mode = WorldMapClass.Mode.MINIMAP
	world_map_minimap.player = player
	world_map_minimap.feature_selected.connect(_on_feature_selected_on_map)
	minimap_container.add_child(world_map_minimap)
	explorer_hud.add_child(minimap_container)
	
	# Bottom Conversational AI Edit Bar
	var bottom_bar = PanelContainer.new()
	bottom_bar.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	bottom_bar.offset_left = 20
	bottom_bar.offset_bottom = -20
	bottom_bar.offset_right = 680
	bottom_bar.offset_top = -110
	bottom_bar.add_theme_stylebox_override("panel", tl_style)
	
	var bar_vbox = VBoxContainer.new()
	bar_vbox.add_theme_constant_override("separation", 6)
	
	edit_status_label = Label.new()
	edit_status_label.text = "COLLABORATIVE ARCHITECT [PRESS T TO EDIT WORLD]:"
	edit_status_label.add_theme_color_override("font_color", Color(0.96, 0.62, 0.05))
	edit_status_label.add_theme_font_size_override("font_size", 10)
	bar_vbox.add_child(edit_status_label)
	
	var edit_input_row = HBoxContainer.new()
	edit_input_row.add_theme_constant_override("separation", 8)
	
	edit_input = LineEdit.new()
	edit_input.placeholder_text = "e.g. Make the northwestern mountain taller, make all rivers wider, add waterfall..."
	edit_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit_input.text_submitted.connect(func(_t): _on_apply_edit_pressed())
	edit_input_row.add_child(edit_input)
	
	edit_btn = Button.new()
	edit_btn.text = "APPLY EDIT"
	edit_btn.pressed.connect(_on_apply_edit_pressed)
	edit_input_row.add_child(edit_btn)
	
	undo_btn = Button.new()
	undo_btn.text = "UNDO"
	undo_btn.pressed.connect(_on_undo_pressed)
	edit_input_row.add_child(undo_btn)
	
	return_studio_btn = Button.new()
	return_studio_btn.text = "STUDIO"
	return_studio_btn.pressed.connect(func(): _set_studio_state(StudioState.STUDIO_LANDING))
	edit_input_row.add_child(return_studio_btn)
	
	bar_vbox.add_child(edit_input_row)
	bottom_bar.add_child(bar_vbox)
	explorer_hud.add_child(bottom_bar)

	# =========================================================================
	# 4. EXPANDED INTERACTIVE WORLD MAP OVERLAY
	# =========================================================================
	expanded_map_overlay = Control.new()
	expanded_map_overlay.name = "ExpandedMapOverlay"
	expanded_map_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root_ctrl.add_child(expanded_map_overlay)
	
	var map_bg = Panel.new()
	map_bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var map_bg_style = StyleBoxFlat.new()
	map_bg_style.bg_color = Color(0.04, 0.06, 0.08, 0.85)
	map_bg.add_theme_stylebox_override("panel", map_bg_style)
	expanded_map_overlay.add_child(map_bg)
	
	var exp_card = PanelContainer.new()
	exp_card.custom_minimum_size = Vector2(760, 560)
	exp_card.set_anchors_preset(Control.PRESET_CENTER)
	exp_card.grow_horizontal = Control.GROW_DIRECTION_BOTH
	exp_card.grow_vertical = Control.GROW_DIRECTION_BOTH
	exp_card.add_theme_stylebox_override("panel", card_style)
	expanded_map_overlay.add_child(exp_card)
	
	var exp_vbox = VBoxContainer.new()
	exp_vbox.add_theme_constant_override("separation", 10)
	exp_card.add_child(exp_vbox)
	
	var exp_hdr = HBoxContainer.new()
	var exp_title = Label.new()
	exp_title.text = "SATELLITE TERRAIN SURVEY — LIVE WORLD HEIGHTFIELD, HYDROLOGY & BIOMES"
	exp_title.add_theme_color_override("font_color", Color(0.96, 0.62, 0.05))
	exp_title.add_theme_font_size_override("font_size", 12)
	exp_hdr.add_child(exp_title)
	
	var exp_spacer = Control.new()
	exp_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	exp_hdr.add_child(exp_spacer)
	
	var regen_map_btn = Button.new()
	regen_map_btn.text = "REFRESH SATELLITE"
	regen_map_btn.pressed.connect(func():
		if is_instance_valid(world_map_expanded) and world_map_expanded.has_method("regenerate_satellite"):
			world_map_expanded.regenerate_satellite()
		if is_instance_valid(world_map_minimap) and world_map_minimap.has_method("regenerate_satellite"):
			world_map_minimap.regenerate_satellite()
	)
	exp_hdr.add_child(regen_map_btn)
	
	var close_map_btn = Button.new()
	close_map_btn.text = "CLOSE MAP [ESC]"
	close_map_btn.pressed.connect(_toggle_expanded_map)
	exp_hdr.add_child(close_map_btn)
	exp_vbox.add_child(exp_hdr)
	
	world_map_expanded = WorldMapClass.new()
	world_map_expanded.mode = WorldMapClass.Mode.EXPANDED
	world_map_expanded.player = player
	world_map_expanded.size_flags_vertical = Control.SIZE_EXPAND_FILL
	world_map_expanded.feature_selected.connect(_on_feature_selected_on_map)
	exp_vbox.add_child(world_map_expanded)


func _add_preset_button(parent: GridContainer, label_text: String, prompt_text: String) -> void:
	var btn = Button.new()
	btn.text = label_text
	btn.add_theme_font_size_override("font_size", 11)
	btn.pressed.connect(func():
		prompt_input.text = prompt_text
		_on_create_pressed()
	)
	parent.add_child(btn)


func _apply_square_minimalist_theme() -> void:
	# Define square button styling
	var btn_normal = StyleBoxFlat.new()
	btn_normal.bg_color = Color(0.14, 0.18, 0.22, 1.0)
	btn_normal.border_color = Color(0.28, 0.36, 0.44, 1.0)
	btn_normal.set_border_width_all(1)
	btn_normal.set_corner_radius_all(0) # SQUARE
	btn_normal.content_margin_left = 12
	btn_normal.content_margin_right = 12
	btn_normal.content_margin_top = 6
	btn_normal.content_margin_bottom = 6
	
	var btn_hover = btn_normal.duplicate()
	btn_hover.bg_color = Color(0.18, 0.24, 0.30, 1.0)
	btn_hover.border_color = Color(0.45, 0.75, 0.50, 1.0)
	
	var btn_pressed = btn_normal.duplicate()
	btn_pressed.bg_color = Color(0.10, 0.14, 0.18, 1.0)
	
	var line_style = StyleBoxFlat.new()
	line_style.bg_color = Color(0.06, 0.08, 0.10, 1.0)
	line_style.border_color = Color(0.30, 0.38, 0.46, 1.0)
	line_style.set_border_width_all(1)
	line_style.set_corner_radius_all(0) # SQUARE
	line_style.content_margin_left = 10
	line_style.content_margin_right = 10
	
	for btn in [create_btn, random_btn, edit_btn, undo_btn, return_studio_btn]:
		if is_instance_valid(btn):
			btn.add_theme_stylebox_override("normal", btn_normal)
			btn.add_theme_stylebox_override("hover", btn_hover)
			btn.add_theme_stylebox_override("pressed", btn_pressed)
			
	prompt_input.add_theme_stylebox_override("normal", line_style)
	edit_input.add_theme_stylebox_override("normal", line_style)


func _check_ollama_status() -> void:
	# Check via HTTPClient
	var test_http = HTTPRequest.new()
	test_http.timeout = 2.0
	add_child(test_http)
	test_http.request_completed.connect(func(res, code, _h, _b):
		if res == HTTPRequest.RESULT_SUCCESS and code == 200:
			ai_status_badge.text = "OLLAMA: READY [qwen3:4b]"
			ai_status_badge.add_theme_color_override("font_color", Color(0.35, 0.85, 0.45))
		else:
			ai_status_badge.text = "LOCAL FALLBACK: READY"
			ai_status_badge.add_theme_color_override("font_color", Color(0.95, 0.75, 0.2))
		test_http.queue_free()
	)
	test_http.request("http://127.0.0.1:11434/api/tags")


func _start_suggestion_rotation() -> void:
	if forest_architect and forest_architect.cached_suggestions.size() > 0:
		active_suggestion_text = forest_architect.cached_suggestions[suggestion_index]
		typewriter_char_idx = 0
		is_typing = true


func _on_suggestions_ready(suggestions: Array[String]) -> void:
	if suggestions.size() > 0:
		active_suggestion_text = suggestions[0]
		typewriter_char_idx = 0
		is_typing = true


func _on_create_pressed() -> void:
	var text = prompt_input.text.strip_edges()
	if text.is_empty():
		return
	_start_generation_sequence(text)


func _on_random_pressed() -> void:
	if forest_architect and forest_architect.cached_suggestions.size() > 0:
		var idx = randi() % forest_architect.cached_suggestions.size()
		prompt_input.text = forest_architect.cached_suggestions[idx]
	_on_create_pressed()


func _start_generation_sequence(prompt_text: String) -> void:
	_set_studio_state(StudioState.GENERATING)
	creation_stage_label.text = "01 — Interpreting your vision (Qwen3:4B)"
	creation_progress_bar.value = 15.0
	creation_detail_label.text = "Connecting to Qwen3:4B to establish landforms, hydrology, and biomes..."
	
	if forest_architect:
		forest_architect.generate_world(prompt_text)
	emit_signal("request_generate", prompt_text, false)


func _on_architect_started(_prompt: String) -> void:
	creation_progress_bar.value = 30.0


func _on_architect_status(status_msg: String) -> void:
	if current_state == StudioState.GENERATING:
		creation_detail_label.text = status_msg
		if "landform" in status_msg.to_lower():
			creation_stage_label.text = "02 — Designing the landforms"
			creation_progress_bar.value = 45.0
		elif "river" in status_msg.to_lower() or "hydrology" in status_msg.to_lower():
			creation_stage_label.text = "03 — Tracing rivers and waterways"
			creation_progress_bar.value = 65.0
		elif "biome" in status_msg.to_lower() or "flora" in status_msg.to_lower():
			creation_stage_label.text = "04 — Composing the biomes & flora"
			creation_progress_bar.value = 80.0
	elif current_state == StudioState.IN_EXPLORER:
		edit_status_label.text = "ARCHITECT: " + status_msg


func _on_blueprint_ready(blueprint: ForestBlueprint, _raw_dict: Dictionary) -> void:
	if current_state == StudioState.GENERATING:
		creation_stage_label.text = "06 — Preparing your world for exploration"
		creation_progress_bar.value = 100.0
		
	# 1. Update 3D World via ChunkManager
	if is_instance_valid(chunk_manager) and chunk_manager.has_method("rebuild_world_from_blueprint"):
		chunk_manager.rebuild_world_from_blueprint(blueprint)
		
	# 2. Update Minimap & Expanded Map
	if is_instance_valid(world_map_minimap):
		world_map_minimap.set_blueprint(blueprint)
	if is_instance_valid(world_map_expanded):
		world_map_expanded.set_blueprint(blueprint)
		
	# 3. Update HUD labels
	hud_biome_label.text = "SUBLIMEGREENS · " + blueprint.theme.to_upper()
	hud_stats_label.text = "Peaks: %d  |  Rivers: %d  |  Biomes: %d  |  Seed: %d" % [
		blueprint.mountains.size(), blueprint.rivers.size(), blueprint.biome_regions.size(), blueprint.world_seed
	]
	
	if current_state == StudioState.GENERATING:
		# Transition smoothly into explorer
		get_tree().create_timer(0.4).timeout.connect(func():
			_set_studio_state(StudioState.IN_EXPLORER)
		)


func _on_edit_completed(summary_msg: String) -> void:
	edit_status_label.text = "EDIT APPLIED: " + summary_msg
	edit_input.text = ""


func _on_architect_failed(err_msg: String) -> void:
	if current_state == StudioState.GENERATING:
		creation_detail_label.text = "Notice: " + err_msg + " (Procedural fallback executed)"
	else:
		edit_status_label.text = "Notice: " + err_msg


func _on_apply_edit_pressed() -> void:
	var text = edit_input.text.strip_edges()
	if text.is_empty():
		return
	edit_status_label.text = "Architect executing edit..."
	if forest_architect:
		forest_architect.edit_world(text, selected_feature_context)


func _on_undo_pressed() -> void:
	if forest_architect and forest_architect.tool_registry:
		var res = forest_architect.tool_registry.execute_tool("undo_last_edit", {})
		edit_status_label.text = res.get("message", "Reverted world state.")
		if res.get("status") == "success":
			var bp = forest_architect.tool_registry.active_blueprint
			if is_instance_valid(chunk_manager) and chunk_manager.has_method("rebuild_world_from_blueprint"):
				chunk_manager.rebuild_world_from_blueprint(bp)
			if is_instance_valid(world_map_minimap):
				world_map_minimap.set_blueprint(bp)
			if is_instance_valid(world_map_expanded):
				world_map_expanded.set_blueprint(bp)


func _toggle_expanded_map() -> void:
	var show = not expanded_map_overlay.visible
	expanded_map_overlay.visible = show
	if is_instance_valid(player) and player.has_method("set_input_enabled"):
		player.set_input_enabled(not show)


func _on_feature_selected_on_map(feature: Dictionary) -> void:
	selected_feature_context = feature
	var f_name = str(feature.get("name", "Feature"))
	var f_type = str(feature.get("type", "feature"))
	edit_status_label.text = "SELECTED: %s [%s] — Ready for targeted instruction" % [f_name.to_upper(), f_type.to_upper()]
	edit_input.placeholder_text = "Instruct change for %s (e.g. increase flora, elevate peak)..." % f_name
