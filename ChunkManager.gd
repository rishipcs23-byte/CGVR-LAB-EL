# ChunkManager.gd
class_name ChunkManager
extends Node3D

const WorldState = preload("res://WorldState.gd")
const WorldEditManager = preload("res://WorldEditManager.gd")
const DirtyRegionTracker = preload("res://DirtyRegionTracker.gd")
const TerrainEngine = preload("res://TerrainEngine.gd")
const HydrologyEngine = preload("res://HydrologyEngine.gd")
const FluidSimulationManagerClass = preload("res://FluidSimulationManager.gd")
const WaterSurfaceRendererClass = preload("res://WaterSurfaceRenderer.gd")

# --- Exports ---
@export var player: CharacterBody3D
@export var chunk_scene: PackedScene
@export var render_distance: int = 4
@export var update_interval: float = 0.5
@export var chunk_size_x: int = 32
@export var chunk_size_z: int = 32
@export var overall_scale: float = 10.0
@export var lod_update_interval: float = 0.1 # Update LOD 10 times per second

@export var atmosphere_manager: AtmosphereManager
@export var fluid_simulation_manager: Node = null
@export var water_surface_renderer: Node3D = null
var world_state: WorldState = null

# --- Internal State ---
var active_chunks: Dictionary = {}
var current_player_chunk_coords: Vector2i = Vector2i(9999, 9999)
var update_timer: float = 0.0
var lod_update_timer: float = 0.0 # <-- NEW: Timer specifically for LOD updates
var active_blueprint: ForestBlueprint = null
var edit_manager: WorldEditManager = null

# Pre-calculate effective size for efficiency
var effective_chunk_size_x: float
var effective_chunk_size_z: float

func _ready():
	effective_chunk_size_x = chunk_size_x * overall_scale
	effective_chunk_size_z = chunk_size_z * overall_scale

	if effective_chunk_size_x <= 0 or effective_chunk_size_z <= 0:
		printerr("ChunkManager: Invalid overall_scale resulted in zero or negative effective chunk size!")
		effective_chunk_size_x = 1.0
		effective_chunk_size_z = 1.0
		set_process(false) # Stop processing if config is bad

	ensure_world_state()
	
	if not edit_manager:
		edit_manager = WorldEditManager.new()
		edit_manager.name = "WorldEditManager"
		edit_manager.world_state = world_state
		edit_manager.chunk_manager = self
		add_child(edit_manager)

	update_chunks() # Initial chunk load

func _get_player_pos() -> Vector3:
	if not is_instance_valid(player):
		return Vector3.ZERO
	return player.global_position if player.is_inside_tree() else player.position

# --- MODIFIED: _process() ---
func _process(delta: float) -> void:
	if not is_instance_valid(player):
		return
	# --- Handle chunk loading/unloading based on its own interval ---
	update_timer += delta
	if update_timer >= update_interval:
		update_timer = 0.0 # Reset timer
		
		var new_coords = get_chunk_coords_from_pos(_get_player_pos())
		if new_coords != current_player_chunk_coords:
			update_chunks()
			
	# --- NEW: Handle grass LOD updates based on its own, faster interval ---
	lod_update_timer += delta
	if lod_update_timer >= lod_update_interval:
		lod_update_timer = 0.0 # Reset timer
		
		var player_pos = _get_player_pos()
		# Iterate through all currently active chunks
		for chunk in active_chunks.values():
			if is_instance_valid(chunk):
				# Call the function we created in Chunk.gd
				chunk.update_grass_lod(player_pos)

# --- UNCHANGED FUNCTIONS BELOW ---

func get_chunk_coords_from_pos(pos: Vector3) -> Vector2i:
	if effective_chunk_size_x == 0 or effective_chunk_size_z == 0:
		printerr("Cannot calculate chunk coords: Effective chunk size is zero.")
		return Vector2i(9999,9999)

	return Vector2i( floori(pos.x / effective_chunk_size_x), floori(pos.z / effective_chunk_size_z) )

func update_chunks() -> void:
	var player_pos = _get_player_pos()
	var new_coords = get_chunk_coords_from_pos(player_pos)

	if new_coords == current_player_chunk_coords:
		return

	current_player_chunk_coords = new_coords

	var required: Dictionary = {}
	for x in range(current_player_chunk_coords.x - render_distance, current_player_chunk_coords.x + render_distance + 1):
		for z in range(current_player_chunk_coords.y - render_distance, current_player_chunk_coords.y + render_distance + 1):
			required[Vector2i(x, z)] = true

	for coord in active_chunks.keys().duplicate():
		if not required.has(coord):
			unload_chunk(coord)

	for coord in required.keys():
		if not active_chunks.has(coord):
			load_chunk(coord)

func load_chunk(coord: Vector2i) -> void:
	if active_chunks.has(coord):
		printerr("Attempted to load chunk that is already active: ", coord)
		return

	var chunk = chunk_scene.instantiate()
	add_child(chunk)

	if chunk.has_method("initialize_chunk"):
		chunk.initialize_chunk(coord, active_blueprint, world_state)
		active_chunks[coord] = chunk
	else:
		printerr("Instantiated chunk scene does not have 'initialize_chunk' method!")
		chunk.queue_free()

func unload_chunk(coord: Vector2i) -> void:
	if active_chunks.has(coord):
		var chunk_to_remove = active_chunks[coord]
		active_chunks.erase(coord)

		if is_instance_valid(chunk_to_remove):
			chunk_to_remove.queue_free()
	else:
		printerr("Attempted to unload chunk that is not active: ", coord)

var lakes_container: Node3D = null

func _setup_world_lakes() -> void:
	if not lakes_container:
		lakes_container = Node3D.new()
		lakes_container.name = "LakesContainer"
		add_child(lakes_container)
		
	for child in lakes_container.get_children():
		child.queue_free()
		
	if not active_blueprint or active_blueprint.lakes.is_empty():
		return
		
	var water_mat: Material = null
	for chunk in active_chunks.values():
		if is_instance_valid(chunk) and chunk.water_mesh_instance and chunk.water_mesh_instance.material_override:
			water_mat = chunk.water_mesh_instance.material_override
			break
			
	if not water_mat:
		var st_mat = StandardMaterial3D.new()
		st_mat.albedo_color = Color(0.15, 0.45, 0.65, 0.85)
		st_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		st_mat.roughness = 0.1
		st_mat.metallic = 0.2
		water_mat = st_mat

	for lake in active_blueprint.lakes:
		var center: Vector2 = lake.get("center", Vector2.ZERO)
		var rad: float = float(lake.get("radius", 30.0))
		var w_level: float = float(lake.get("water_level", -1.5))
		
		var lake_disc = MeshInstance3D.new()
		lake_disc.name = "LakeMesh_" + str(lake.get("id", "lake"))
		
		var st = SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		st.set_material(water_mat)
		var segments = 36
		var center_v = Vector3(0.0, 0.0, 0.0)
		st.set_normal(Vector3.UP)
		for i in range(segments):
			var a1 = (float(i) / segments) * TAU
			var a2 = (float(i + 1) / segments) * TAU
			var p1 = Vector3(cos(a1) * rad * overall_scale, 0.0, sin(a1) * rad * overall_scale)
			var p2 = Vector3(cos(a2) * rad * overall_scale, 0.0, sin(a2) * rad * overall_scale)
			
			st.set_uv(Vector2(0.5, 0.5)); st.add_vertex(center_v)
			st.set_uv(Vector2(0.5 + 0.5 * cos(a1), 0.5 + 0.5 * sin(a1))); st.add_vertex(p1)
			st.set_uv(Vector2(0.5 + 0.5 * cos(a2), 0.5 + 0.5 * sin(a2))); st.add_vertex(p2)
			
		st.generate_normals()
		lake_disc.mesh = st.commit()
		lake_disc.material_override = water_mat
		lake_disc.position = Vector3(center.x * overall_scale, w_level * overall_scale, center.y * overall_scale)
		lakes_container.add_child(lake_disc)

func rebuild_world_from_blueprint(blueprint: ForestBlueprint) -> void:
	active_blueprint = blueprint
	
	# 1. Update atmosphere
	if is_instance_valid(atmosphere_manager):
		atmosphere_manager.apply_blueprint(blueprint)
		
	# Synchronize WorldState from blueprint
	_sync_world_state_from_blueprint()
	
	# 2. Despawn all active chunks
	for coord in active_chunks.keys().duplicate():
		unload_chunk(coord)
	active_chunks.clear()
	
	# 3. Setup visible water surfaces for all lakes in blueprint
	_setup_world_lakes()
	
	# 4. Elevate player safely so they aren't buried inside high terrain
	if is_instance_valid(player):
		player.global_position.y += 20.0
		if player.global_position.y < 35.0:
			player.global_position.y = 45.0
			
	# 5. Force reload all chunks around player
	current_player_chunk_coords = Vector2i(99999, 99999)
	update_chunks()

# =============================================================================
# --- LOCALIZED DIRTY-REGION CHUNK MANAGEMENT (Milestone 4) ---
# =============================================================================

## Ensures WorldState exists and is initialized.
func ensure_world_state() -> WorldState:
	if world_state == null:
		# Step 1: WorldState becomes available
		world_state = WorldState.new(
			Vector2(1000.0, 1000.0),
			Vector2i(256, 256),
			Vector2(-500.0, -500.0),
			active_blueprint.world_seed if active_blueprint else 42
		)
		if active_blueprint != null:
			_sync_world_state_from_blueprint()
		else:
			# Step 2: Terrain elevation is initialized
			var terr = TerrainEngine.new(world_state.world_size, world_state.grid_resolution, world_state.world_origin)
			terr.generate(42, {"base_elevation": 12.0})
			# Step 3: Hydrology is computed
			var hyd = HydrologyEngine.new(terr)
			hyd.resolve_hydrology()
			world_state.initialize_from_simulation(terr, hyd)
			# Step 4: Lake basins and river networks are initialized
			world_state.recompute_lakes({
				"min_basin_area_cells": 10,
				"min_basin_depth_m": 0.5,
				"default_fill_ratio": 1.0,
				"register_features": true,
				"connect_rivers": true
			})
			_setup_fluid_simulation()
	return world_state

## Sets up and links FluidSimulationManager and WaterSurfaceRenderer.
func _setup_fluid_simulation() -> void:
	if not fluid_simulation_manager and is_inside_tree():
		fluid_simulation_manager = get_node_or_null("../FluidSimulationManager")
	if not water_surface_renderer and is_inside_tree():
		water_surface_renderer = get_node_or_null("../WaterSurfaceRenderer")
		
	# Step 5: FluidSimulationManager initializes its simulation grid
	if is_instance_valid(fluid_simulation_manager):
		if fluid_simulation_manager.has_method("initialize_from_world_state"):
			fluid_simulation_manager.initialize_from_world_state(world_state, Vector2i(128, 128))
			
	# Step 6: WaterSurfaceRenderer creates its rendering resources
	if is_instance_valid(water_surface_renderer):
		if water_surface_renderer.has_method("initialize"):
			water_surface_renderer.initialize(fluid_simulation_manager)
		elif "fluid_manager" in water_surface_renderer:
			water_surface_renderer.fluid_manager = fluid_simulation_manager
			if water_surface_renderer.has_method("update_simulation_textures"):
				water_surface_renderer.update_simulation_textures()
				
	# Step 7: Simulation begins
	if is_instance_valid(fluid_simulation_manager) and "is_simulating" in fluid_simulation_manager:
		fluid_simulation_manager.is_simulating = true

## Synchronizes WorldState simulation buffers and FeatureRegistry from active_blueprint.
func _sync_world_state_from_blueprint() -> void:
	if not active_blueprint:
		return
	if not world_state:
		world_state = WorldState.new(
			Vector2(1000.0, 1000.0),
			Vector2i(256, 256),
			Vector2(-500.0, -500.0),
			active_blueprint.world_seed
		)
		
	var w = world_state.grid_resolution.x
	var h = world_state.grid_resolution.y
	for gy in range(h):
		var row_offset = gy * w
		for gx in range(w):
			var wpos = world_state.grid_to_world(float(gx), float(gy))
			# Query height from blueprint
			var raw_h = active_blueprint.get_height_at(wpos.x, wpos.y, 0.0)
			world_state.raw_elevation_buffer[row_offset + gx] = raw_h
			
	world_state._update_elevation_metrics()
	world_state.recompute_hydrology()
	world_state.recompute_lakes({
		"min_basin_area_cells": 10,
		"min_basin_depth_m": 0.5,
		"default_fill_ratio": 1.0,
		"register_features": true,
		"connect_rivers": true
	})
	
	if world_state.feature_registry:
		for m in active_blueprint.mountains:
			world_state.feature_registry.register_feature({
				"id": m.get("id", "mountain"),
				"type": "mountain",
				"position": m.get("pos", Vector2.ZERO),
				"parameters": m
			})
		for r in active_blueprint.rivers:
			world_state.feature_registry.register_feature({
				"id": r.get("id", "river"),
				"type": "river",
				"parameters": r
			})
			
	_setup_fluid_simulation()

## Returns the effective chunk size in world units.
func get_effective_chunk_size() -> Vector2:
	if effective_chunk_size_x <= 0.0 or effective_chunk_size_z <= 0.0:
		effective_chunk_size_x = chunk_size_x * overall_scale
		effective_chunk_size_z = chunk_size_z * overall_scale
	return Vector2(effective_chunk_size_x, effective_chunk_size_z)

## Returns the world-space bounding box for a given chunk coordinate.
func get_chunk_world_rect(coord: Vector2i) -> Rect2:
	var eff = get_effective_chunk_size()
	return Rect2(coord.x * eff.x, coord.y * eff.y, eff.x, eff.y)

## Returns all chunk coordinates intersecting the specified world-space bounding box.
func get_chunks_intersecting_rect(rect: Rect2) -> Array[Vector2i]:
	var eff = get_effective_chunk_size()
	if eff.x <= 0.0 or eff.y <= 0.0:
		return []
		
	var min_cx = floori(rect.position.x / eff.x)
	var min_cz = floori(rect.position.y / eff.y)
	var max_cx = floori(rect.end.x / eff.x)
	var max_cz = floori(rect.end.y / eff.y)
	
	var res: Array[Vector2i] = []
	for cz in range(min_cz, max_cz + 1):
		for cx in range(min_cx, max_cx + 1):
			res.append(Vector2i(cx, cz))
	return res

## Updates only active chunks intersecting the specified dirty region.
## Does NOT unload or rebuild unaffected chunks, preserving player and gameplay stability.
func update_dirty_region(dirty_region: RefCounted) -> Array[Vector2i]:
	if not dirty_region:
		return []
		
	var updated: Array[Vector2i] = []
	var bounds: Rect2 = dirty_region.world_bounds
	var categories: Array[String] = dirty_region.change_categories
	var candidate_coords: Array[Vector2i] = dirty_region.affected_chunk_coords
	
	if candidate_coords.is_empty():
		candidate_coords = get_chunks_intersecting_rect(bounds)
		
	# Deduplicate coordinates
	var unique_coords: Array[Vector2i] = []
	for c in candidate_coords:
		if not unique_coords.has(c):
			unique_coords.append(c)
			
	# Update ONLY intersecting active chunks in-place
	for coord in unique_coords:
		if active_chunks.has(coord):
			var chunk = active_chunks[coord]
			if is_instance_valid(chunk) and chunk.has_method("update_chunk_from_world_state"):
				chunk.update_chunk_from_world_state(world_state, categories)
				updated.append(coord)
				
	# Safe player collision recovery if player is within dirty bounds
	check_and_recover_player(bounds)
	
	# Update FluidSimulationManager bed and lakes inside dirty region
	if is_instance_valid(fluid_simulation_manager) and fluid_simulation_manager.has_method("apply_localized_terrain_update"):
		fluid_simulation_manager.apply_localized_terrain_update(bounds)
	if is_instance_valid(water_surface_renderer) and water_surface_renderer.has_method("update_simulation_textures"):
		water_surface_renderer.update_simulation_textures()
	
	return updated

## Handles safe vertical collision recovery for the player if ground elevation changed beneath them.
func check_and_recover_player(dirty_bounds: Rect2) -> bool:
	if not is_instance_valid(player) or not world_state:
		return false
		
	var p_pos = player.global_position if player.is_inside_tree() else player.position
	var p2d = Vector2(p_pos.x, p_pos.z)
	
	if not dirty_bounds.has_point(p2d):
		return false # Outside modified region; player unchanged
		
	var ground_h = world_state.get_elevation_at(p_pos.x, p_pos.z)
	var clearance = 1.2
	
	if p_pos.y < ground_h + clearance:
		p_pos.y = ground_h + clearance
		if player.is_inside_tree():
			player.global_position = p_pos
		else:
			player.position = p_pos
		if player.velocity.y < 0.0:
			player.velocity.y = 0.0
		return true
		
	return false
