# Chunk.gd
extends Node3D

# --- Node References ---
@export var mesh_instance: MeshInstance3D
@export var collision_shape: CollisionShape3D
@export var water_mesh_instance: MeshInstance3D
@export var grass_multimesh: MultiMeshInstance3D
@export var tree_multimesh: MultiMeshInstance3D # <-- NEW

# --- Chunk Configuration ---
@export_group("Chunk Size")
@export var chunk_size_x: int = 32
@export var chunk_size_z: int = 32
@export var vertices_x: int = 33
@export var vertices_z: int = 33

# --- Terrain Generation ---
# ... (This entire section is unchanged) ...
@export_group("Base Continent")
@export var noise_continent: FastNoiseLite
@export var continent_slope_scale: float = 8.0
@export var continent_min_height: float = -10.0
@export var continent_max_height: float = 25.0
@export_group("Mountain Control")
@export var noise_mountain: FastNoiseLite
@export var mountain_scale: float = 40.0
@export var mountain_start_height: float = 10.0
@export var mountain_fade_height: float = 10.0
@export_group("Valley Control")
@export var noise_valley: FastNoiseLite
@export var valley_carve_scale: float = 15.0
@export var valley_apply_threshold: float = 5.0
@export_group("Erosion Control")
@export var noise_erosion: FastNoiseLite
@export var erosion_scale: float = 2.5

# --- Water Plane ---
@export_group("Water Plane")
@export var visual_water_level: float = -2.0

# --- Grass Placement Rules ---
# ... (This entire section is unchanged) ...
@export_group("Grass Placement Rules")
@export var grass_material: Material
@export var grass_min_height: float = 2.5
@export var grass_max_height: float = 79.0
@export var grass_max_slope_normal_y: float = 0.8
@export var grass_density: float = 0.1

# --- Grass Randomization ---
# ... (This entire section is unchanged) ...
@export_group("Grass Randomization")
@export var grass_rotation_min_degrees: Vector3 = Vector3(80, 0, -5)
@export var grass_rotation_max_degrees: Vector3 = Vector3(100, 360, 5)
@export var grass_scale_min: float = 0.8
@export var grass_scale_max: float = 1.3

# --- Grass LOD --- <-- NEW
@export_group("Grass LOD")
## Distances at which to switch LOD levels.
@export var lod_distances: PackedFloat32Array = [80.0, 160.0, 240.0]
## Density multipliers for each LOD level. Should have one more element than lod_distances for the final "fallback" density.
@export var lod_density_multipliers: PackedFloat32Array = [1.0, 0.5, 0.2, 0.0]


# --- Tree Placement Rules ---  <-- NEW SECTION
@export_group("Tree Placement Rules")
@export var tree_trunk_material: Material
@export var tree_leaves_material: Material
@export var tree_min_height: float = 5.0
@export var tree_max_height: float = 60.0
@export var tree_max_slope_normal_y: float = 0.9
@export var tree_density: float = 0.005 # Trees are much less dense than grass

# --- Tree Randomization --- <-- NEW SECTION
@export_group("Tree Randomization")
@export var tree_scale_min: float = 0.7
@export var tree_scale_max: float = 1.1
# Note: We only need Y-axis rotation for trees to keep them upright

@export_group("Overall Scaling")
@export var overall_scale: float = 10.0

const WorldState = preload("res://WorldState.gd")

# --- Internal State ---
var chunk_coords: Vector2i = Vector2i.ZERO
var world_state: WorldState = null
var _grass_blade_mesh: ArrayMesh
var _tree_mesh: ArrayMesh
var _sorted_grass_transforms: Array[Transform3D] = [] # <-- NEW
var active_blueprint: ForestBlueprint = null
var flora_container: Node3D

#=============================================================================
# --- CORE FUNCTIONS ---

func _ready():
	_grass_blade_mesh = _create_grass_blade_mesh()
	_tree_mesh = _create_tree_mesh()
	if not flora_container:
		flora_container = Node3D.new()
		flora_container.name = "FloraContainer"
		add_child(flora_container)

func initialize_chunk(coords: Vector2i, blueprint: ForestBlueprint = null, p_world_state: WorldState = null):
	chunk_coords = coords
	if p_world_state != null:
		world_state = p_world_state
	if is_inside_tree():
		global_position.x = coords.x * chunk_size_x * overall_scale
		global_position.z = coords.y * chunk_size_z * overall_scale
	else:
		position.x = coords.x * chunk_size_x * overall_scale
		position.z = coords.y * chunk_size_z * overall_scale
	name = "Chunk_%d_%d" % [coords.x, coords.y]
	
	if blueprint != null:
		apply_blueprint(blueprint)
	elif active_blueprint == null:
		active_blueprint = ForestBlueprint.create_default()
	
	generate_terrain()
	setup_water_plane()
	_setup_river_mesh()
	_spawn_landmarks_in_chunk()
	
	if active_blueprint != null and active_blueprint.vegetation_layers.size() > 0:
		generate_all_flora()
	else:
		generate_grass()
		generate_trees()
	
	scale = Vector3(overall_scale, overall_scale, overall_scale)

func apply_blueprint(blueprint: ForestBlueprint) -> void:
	if blueprint == null:
		return
	active_blueprint = blueprint
		
	# 1. Terrain shape parameters
	mountain_scale = blueprint.mountain_scale
	continent_max_height = blueprint.continent_max_height
	continent_slope_scale = blueprint.continent_slope_scale
	valley_carve_scale = blueprint.valley_carve_scale
	
	# Noise seeds based on blueprint world_seed
	if noise_continent:
		noise_continent = noise_continent.duplicate()
		noise_continent.seed = (blueprint.world_seed + 35) % 100000
	if noise_mountain:
		noise_mountain = noise_mountain.duplicate()
		noise_mountain.seed = (blueprint.world_seed + 90) % 100000
	if noise_valley:
		noise_valley = noise_valley.duplicate()
		noise_valley.seed = (blueprint.world_seed + 57) % 100000
	if noise_erosion:
		noise_erosion = noise_erosion.duplicate()
		noise_erosion.seed = (blueprint.world_seed + 65) % 100000
		
	# 2. Terrain shader tint
	if mesh_instance and mesh_instance.material_override:
		var mat = mesh_instance.material_override.duplicate()
		mat.set_shader_parameter("albedo_tint", blueprint.terrain_tint)
		mesh_instance.material_override = mat
		
	# 3. Grass placement and material
	grass_density = blueprint.grass_density
	grass_scale_min = blueprint.grass_scale_min
	grass_scale_max = blueprint.grass_scale_max
	if grass_material:
		var g_mat = grass_material.duplicate()
		if g_mat is ShaderMaterial:
			g_mat.set_shader_parameter("albedo", blueprint.grass_color)
		grass_material = g_mat
		
	# 4. Tree placement and materials
	tree_density = blueprint.tree_density
	tree_scale_min = blueprint.tree_scale_min
	tree_scale_max = blueprint.tree_scale_max
	
	var t_trunk = StandardMaterial3D.new()
	t_trunk.cull_mode = BaseMaterial3D.CULL_DISABLED
	t_trunk.albedo_color = blueprint.tree_trunk_color
	tree_trunk_material = t_trunk
	
	var t_leaves = StandardMaterial3D.new()
	t_leaves.cull_mode = BaseMaterial3D.CULL_DISABLED
	t_leaves.albedo_color = blueprint.tree_leaves_color
	if blueprint.tree_emissive_energy > 0.0:
		t_leaves.emission_enabled = true
		t_leaves.emission = blueprint.tree_emissive_color
		t_leaves.emission_energy_multiplier = blueprint.tree_emissive_energy
	tree_leaves_material = t_leaves
	
	# 5. Rebuild mesh definitions with updated materials
	_grass_blade_mesh = _create_grass_blade_mesh()
	_tree_mesh = _create_tree_mesh()


#=============================================================================
# --- MESH GENERATION ---

func _create_grass_blade_mesh() -> ArrayMesh:
	# ... (This function is unchanged) ...
	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var height = 0.2; var base_width = 0.02; var tip_width = 0.002
	var v0 = Vector3(-base_width, 0, 0); var v1 = Vector3(base_width, 0, 0)
	var v2 = Vector3(tip_width, 0, height); var v3 = Vector3(-tip_width, 0, height)
	st.set_uv(Vector2(0, 1)); st.add_vertex(v0); st.set_uv(Vector2(1, 1)); st.add_vertex(v1)
	st.set_uv(Vector2(1, 0)); st.add_vertex(v2); st.set_uv(Vector2(0, 0)); st.add_vertex(v3)
	st.add_index(0); st.add_index(1); st.add_index(3); st.add_index(1); st.add_index(2); st.add_index(3)
	if is_instance_valid(grass_material): st.set_material(grass_material)
	else:
		printerr("Grass Material not assigned in Chunk Inspector! Creating a bright magenta default.")
		var m = StandardMaterial3D.new(); m.albedo_color = Color.MAGENTA; m.cull_mode = BaseMaterial3D.CULL_DISABLED; st.set_material(m)
	st.generate_normals(); return st.commit()

func _create_tree_mesh() -> ArrayMesh:
	# --- The Robust Solution: Use separate SurfaceTools and commit them to the same ArrayMesh ---

	# --- 1. Create and build the TRUNK surface ---
	var st_trunk = SurfaceTool.new()
	st_trunk.begin(Mesh.PRIMITIVE_TRIANGLES)
	
	if is_instance_valid(tree_trunk_material):
		st_trunk.set_material(tree_trunk_material)
	else:
		printerr("Tree Trunk Material not assigned! Using a brown default.")
		var m = StandardMaterial3D.new(); m.albedo_color = Color("saddlebrown"); st_trunk.set_material(m)
		
	# Define Tree Dimensions
	var trunk_height = 1.5
	var trunk_width = 0.15
	
	# Trunk Vertices
	var trunk_verts = [
		Vector3(-trunk_width, 0, -trunk_width), Vector3(trunk_width, 0, -trunk_width),
		Vector3(trunk_width, 0, trunk_width), Vector3(-trunk_width, 0, trunk_width),
		Vector3(-trunk_width, trunk_height, -trunk_width), Vector3(trunk_width, trunk_height, -trunk_width),
		Vector3(trunk_width, trunk_height, trunk_width), Vector3(-trunk_width, trunk_height, trunk_width)
	]
	
	# Standard UVs for a quad face
	var uv0 = Vector2(0, 1); var uv1 = Vector2(1, 1); var uv2 = Vector2(1, 0); var uv3 = Vector2(0, 0)

	# Build trunk faces with UVs (same as before, but on st_trunk)
	# Front
	st_trunk.set_uv(uv0); st_trunk.add_vertex(trunk_verts[4]); st_trunk.set_uv(uv1); st_trunk.add_vertex(trunk_verts[5]); st_trunk.set_uv(uv2); st_trunk.add_vertex(trunk_verts[1])
	st_trunk.set_uv(uv0); st_trunk.add_vertex(trunk_verts[4]); st_trunk.set_uv(uv2); st_trunk.add_vertex(trunk_verts[1]); st_trunk.set_uv(uv3); st_trunk.add_vertex(trunk_verts[0])
	# Back
	st_trunk.set_uv(uv0); st_trunk.add_vertex(trunk_verts[6]); st_trunk.set_uv(uv1); st_trunk.add_vertex(trunk_verts[7]); st_trunk.set_uv(uv2); st_trunk.add_vertex(trunk_verts[3])
	st_trunk.set_uv(uv0); st_trunk.add_vertex(trunk_verts[6]); st_trunk.set_uv(uv2); st_trunk.add_vertex(trunk_verts[3]); st_trunk.set_uv(uv3); st_trunk.add_vertex(trunk_verts[2])
	# Left
	st_trunk.set_uv(uv0); st_trunk.add_vertex(trunk_verts[7]); st_trunk.set_uv(uv1); st_trunk.add_vertex(trunk_verts[4]); st_trunk.set_uv(uv2); st_trunk.add_vertex(trunk_verts[0])
	st_trunk.set_uv(uv0); st_trunk.add_vertex(trunk_verts[7]); st_trunk.set_uv(uv2); st_trunk.add_vertex(trunk_verts[0]); st_trunk.set_uv(uv3); st_trunk.add_vertex(trunk_verts[3])
	# Right
	st_trunk.set_uv(uv0); st_trunk.add_vertex(trunk_verts[5]); st_trunk.set_uv(uv1); st_trunk.add_vertex(trunk_verts[6]); st_trunk.set_uv(uv2); st_trunk.add_vertex(trunk_verts[2])
	st_trunk.set_uv(uv0); st_trunk.add_vertex(trunk_verts[5]); st_trunk.set_uv(uv2); st_trunk.add_vertex(trunk_verts[2]); st_trunk.set_uv(uv3); st_trunk.add_vertex(trunk_verts[1])

	st_trunk.generate_normals()
	st_trunk.generate_tangents()


	# --- 2. Create and build the LEAVES surface ---
	var st_leaves = SurfaceTool.new()
	st_leaves.begin(Mesh.PRIMITIVE_TRIANGLES)
	
	if is_instance_valid(tree_leaves_material):
		st_leaves.set_material(tree_leaves_material)
	else:
		printerr("Tree Leaves Material not assigned! Using a green default.")
		var m = StandardMaterial3D.new(); m.albedo_color = Color("forestgreen"); st_leaves.set_material(m)
		
	# Define Leaves Dimensions
	var leaves_height = 1.2
	var leaves_width = 0.7
	var leaves_base_y = trunk_height
	
	# Leaves Vertices
	var leaves_verts = [
		Vector3(-leaves_width, leaves_base_y, -leaves_width), Vector3(leaves_width, leaves_base_y, -leaves_width),
		Vector3(leaves_width, leaves_base_y, leaves_width), Vector3(-leaves_width, leaves_base_y, leaves_width),
		Vector3(-leaves_width, leaves_base_y + leaves_height, -leaves_width), Vector3(leaves_width, leaves_base_y + leaves_height, -leaves_width),
		Vector3(leaves_width, leaves_base_y + leaves_height, leaves_width), Vector3(-leaves_width, leaves_base_y + leaves_height, leaves_width)
	]
	
	# Build leaves faces with UVs (on st_leaves)
	# Front
	st_leaves.set_uv(uv0); st_leaves.add_vertex(leaves_verts[4]); st_leaves.set_uv(uv1); st_leaves.add_vertex(leaves_verts[5]); st_leaves.set_uv(uv2); st_leaves.add_vertex(leaves_verts[1])
	st_leaves.set_uv(uv0); st_leaves.add_vertex(leaves_verts[4]); st_leaves.set_uv(uv2); st_leaves.add_vertex(leaves_verts[1]); st_leaves.set_uv(uv3); st_leaves.add_vertex(leaves_verts[0])
	# Back
	st_leaves.set_uv(uv0); st_leaves.add_vertex(leaves_verts[6]); st_leaves.set_uv(uv1); st_leaves.add_vertex(leaves_verts[7]); st_leaves.set_uv(uv2); st_leaves.add_vertex(leaves_verts[3])
	st_leaves.set_uv(uv0); st_leaves.add_vertex(leaves_verts[6]); st_leaves.set_uv(uv2); st_leaves.add_vertex(leaves_verts[3]); st_leaves.set_uv(uv3); st_leaves.add_vertex(leaves_verts[2])
	# Left
	st_leaves.set_uv(uv0); st_leaves.add_vertex(leaves_verts[7]); st_leaves.set_uv(uv1); st_leaves.add_vertex(leaves_verts[4]); st_leaves.set_uv(uv2); st_leaves.add_vertex(leaves_verts[0])
	st_leaves.set_uv(uv0); st_leaves.add_vertex(leaves_verts[7]); st_leaves.set_uv(uv2); st_leaves.add_vertex(leaves_verts[0]); st_leaves.set_uv(uv3); st_leaves.add_vertex(leaves_verts[3])
	# Right
	st_leaves.set_uv(uv0); st_leaves.add_vertex(leaves_verts[5]); st_leaves.set_uv(uv1); st_leaves.add_vertex(leaves_verts[6]); st_leaves.set_uv(uv2); st_leaves.add_vertex(leaves_verts[2])
	st_leaves.set_uv(uv0); st_leaves.add_vertex(leaves_verts[5]); st_leaves.set_uv(uv2); st_leaves.add_vertex(leaves_verts[2]); st_leaves.set_uv(uv3); st_leaves.add_vertex(leaves_verts[1])
	# Top
	st_leaves.set_uv(uv0); st_leaves.add_vertex(leaves_verts[7]); st_leaves.set_uv(uv1); st_leaves.add_vertex(leaves_verts[6]); st_leaves.set_uv(uv2); st_leaves.add_vertex(leaves_verts[5])
	st_leaves.set_uv(uv0); st_leaves.add_vertex(leaves_verts[7]); st_leaves.set_uv(uv2); st_leaves.add_vertex(leaves_verts[5]); st_leaves.set_uv(uv3); st_leaves.add_vertex(leaves_verts[4])
	# Bottom
	st_leaves.set_uv(uv0); st_leaves.add_vertex(leaves_verts[0]); st_leaves.set_uv(uv1); st_leaves.add_vertex(leaves_verts[1]); st_leaves.set_uv(uv2); st_leaves.add_vertex(leaves_verts[2])
	st_leaves.set_uv(uv0); st_leaves.add_vertex(leaves_verts[0]); st_leaves.set_uv(uv2); st_leaves.add_vertex(leaves_verts[2]); st_leaves.set_uv(uv3); st_leaves.add_vertex(leaves_verts[3])

	st_leaves.generate_normals()
	st_leaves.generate_tangents()


	# --- 3. Combine the surfaces into a single ArrayMesh ---
	var final_mesh = ArrayMesh.new()
	
	# First, commit the trunk tool. This CREATES the mesh with the first surface.
	st_trunk.commit(final_mesh)
	
	# Second, commit the leaves tool TO THE SAME MESH. This APPENDS a second surface.
	st_leaves.commit(final_mesh)
	
	return final_mesh



func generate_terrain():
	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var step_x = chunk_size_x / float(vertices_x - 1)
	var step_z = chunk_size_z / float(vertices_z - 1)
	var _noise_continent = noise_continent
	var _noise_mountain = noise_mountain
	var _noise_valley = noise_valley
	var _noise_erosion = noise_erosion
	
	for z in range(vertices_z):
		for x in range(vertices_x):
			var vx = x * step_x
			var vz = z * step_z
			var height: float
			
			if world_state != null:
				# Query authoritative WorldState elevation in physical world meters
				var wx = (chunk_coords.x * chunk_size_x + vx) * overall_scale
				var wz = (chunk_coords.y * chunk_size_z + vz) * overall_scale
				var world_h = world_state.get_elevation_at(wx, wz)
				# Convert to chunk local space so that scaling by overall_scale gives world_h
				height = world_h / overall_scale if overall_scale > 0.0 else world_h
			else:
				var wx = vx + chunk_coords.x * chunk_size_x
				var wz = vz + chunk_coords.y * chunk_size_z
				var raw_continent_noise = _noise_continent.get_noise_2d(wx, wz) if _noise_continent else 0.0
				var normalized_continent_noise = (raw_continent_noise + 1.0) * 0.5
				var conceptual_base_height = lerp(continent_min_height, continent_max_height, normalized_continent_noise)
				var mountain_modulator = clamp((conceptual_base_height - mountain_start_height) / mountain_fade_height, 0.0, 1.0)
				var m_potential = max(0.0, _noise_mountain.get_noise_2d(wx, wz)) * mountain_scale if _noise_mountain else 0.0
				var m = m_potential * mountain_modulator
				var valley_carve = 0.0
				if conceptual_base_height < valley_apply_threshold and _noise_valley:
					var valley_noise = _noise_valley.get_noise_2d(wx, wz)
					var negative_valley = min(valley_noise, 0.0)
					var valley_modulator = clamp((valley_apply_threshold - conceptual_base_height) / valley_apply_threshold, 0.0, 1.0)
					valley_carve = negative_valley * valley_carve_scale * valley_modulator
				var nc = normalized_continent_noise
				var erosion_modulator = 1.0 - abs(nc - 0.5) * 2.0
				var bump_e = _noise_erosion.get_noise_2d(wx, wz) * erosion_scale * erosion_modulator if _noise_erosion else 0.0
				var c_slope_contribution = raw_continent_noise * continent_slope_scale
				var raw_h = c_slope_contribution + m + valley_carve + bump_e
				height = active_blueprint.get_height_at(wx, wz, raw_h) if active_blueprint else raw_h
				
			var vertex = Vector3(vx, height, vz)
			var uv = Vector2(x / float(vertices_x - 1), z / float(vertices_z - 1))
			st.set_uv(uv)
			st.add_vertex(vertex)
			
	for z in range(vertices_z - 1):
		for x in range(vertices_x - 1):
			var i00 = z * vertices_x + x
			var i10 = i00 + 1
			var i01 = (z + 1) * vertices_x + x
			var i11 = i01 + 1
			st.add_index(i00)
			st.add_index(i10)
			st.add_index(i01)
			st.add_index(i10)
			st.add_index(i11)
			st.add_index(i01)
			
	st.generate_normals()
	st.generate_tangents()
	var mesh: ArrayMesh = st.commit()
	mesh_instance.mesh = mesh
	var coll_shape = ConcavePolygonShape3D.new()
	coll_shape.set_faces(mesh.get_faces())
	collision_shape.shape = coll_shape

## Updates this chunk in-place from WorldState without freeing or re-instantiating the node.
func update_chunk_from_world_state(p_world_state: WorldState = null, categories: Array[String] = []) -> void:
	if p_world_state != null:
		world_state = p_world_state
		
	var update_all = categories.is_empty()
	var update_terrain = update_all or categories.has("terrain") or categories.has("collision")
	var update_water = update_all or categories.has("hydrology") or categories.has("river") or categories.has("lake")
	var update_flora = update_all or categories.has("flora") or categories.has("terrain")
	
	if update_terrain:
		generate_terrain()
		
	if update_water:
		setup_water_plane()
		_setup_river_mesh()
		
	if update_flora:
		if active_blueprint != null and active_blueprint.vegetation_layers.size() > 0:
			generate_all_flora()
		else:
			generate_grass()
			generate_trees()

func setup_water_plane() -> void:
	# ... (This function is unchanged) ...
	var plane_mesh: PlaneMesh; if water_mesh_instance.mesh is PlaneMesh and water_mesh_instance.mesh.size == Vector2(chunk_size_x, chunk_size_z): plane_mesh = water_mesh_instance.mesh
	else: plane_mesh = PlaneMesh.new(); plane_mesh.size = Vector2(chunk_size_x, chunk_size_z); water_mesh_instance.mesh = plane_mesh
	water_mesh_instance.position = Vector3(chunk_size_x / 2.0, visual_water_level, chunk_size_z / 2.0); water_mesh_instance.visible = true

# --- MODIFIED: generate_grass() ---
func generate_grass() -> void:
	_sorted_grass_transforms.clear() # Clear previous data

	if not grass_multimesh or not is_instance_valid(_grass_blade_mesh): return
	var terrain_mesh: ArrayMesh = mesh_instance.mesh
	if not terrain_mesh or terrain_mesh.get_surface_count() == 0: return

	var mesh_arrays = terrain_mesh.surface_get_arrays(0)
	var vertices = mesh_arrays[Mesh.ARRAY_VERTEX]
	var normals = mesh_arrays[Mesh.ARRAY_NORMAL]
	var indices = mesh_arrays[Mesh.ARRAY_INDEX]
	if indices.is_empty(): return

	# We generate all potential transforms into a temporary array first.
	var temp_transforms: Array[Transform3D] = []
	var mesh_global_transform = mesh_instance.global_transform if (mesh_instance and mesh_instance.is_inside_tree()) else (global_transform if is_inside_tree() else transform)

	for i in range(0, indices.size(), 3):
		var p0 = vertices[indices[i]]; var p1 = vertices[indices[i+1]]; var p2 = vertices[indices[i+2]]
		var avg_normal = (normals[indices[i]] + normals[indices[i+1]] + normals[indices[i+2]]).normalized()
		var local_avg_pos = (p0 + p1 + p2) / 3.0
		var world_avg_pos = mesh_global_transform * local_avg_pos
		
		# Use the correct global height and slope checks
		if not (world_avg_pos.y > grass_min_height and world_avg_pos.y < grass_max_height): continue
		if avg_normal.y < grass_max_slope_normal_y: continue
		
		var area = (p1 - p0).cross(p2 - p0).length() * 0.5
		var world_area = area * (overall_scale * overall_scale)
		var num_clumps_to_spawn = floori(world_area * grass_density)

		for j in range(num_clumps_to_spawn):
			var r1 = randf(); var r2 = randf(); if r1 + r2 > 1.0: r1 = 1.0 - r1; r2 = 1.0 - r2
			var point_on_triangle = p0 + r1 * (p1 - p0) + r2 * (p2 - p0)
			
			var basis = Basis.IDENTITY
			var rot_x = deg_to_rad(randf_range(grass_rotation_min_degrees.x, grass_rotation_max_degrees.x))
			var rot_y = deg_to_rad(randf_range(grass_rotation_min_degrees.y, grass_rotation_max_degrees.y))
			var rot_z = deg_to_rad(randf_range(grass_rotation_min_degrees.z, grass_rotation_max_degrees.z))
			basis = basis.rotated(Vector3.UP, rot_y).rotated(Vector3.RIGHT, rot_x).rotated(Vector3.FORWARD, rot_z)
			basis = basis.scaled(Vector3.ONE * randf_range(grass_scale_min, grass_scale_max))
			
			var transform = Transform3D(basis, point_on_triangle)
			temp_transforms.append(transform)

	if temp_transforms.is_empty():
		grass_multimesh.multimesh = null; return

	# NEW: Sort transforms by distance from the chunk's center.
	# This ensures we remove the "outer" blades of grass within a chunk first.
	var chunk_center = Vector3(chunk_size_x / 2.0, 0, chunk_size_z / 2.0)
	temp_transforms.sort_custom(
		func(a: Transform3D, b: Transform3D) -> bool:
			return a.origin.distance_squared_to(chunk_center) < b.origin.distance_squared_to(chunk_center)
	)
	# Store the fully sorted, master list of transforms.
	_sorted_grass_transforms = temp_transforms

	# Finalize the MultiMesh using ALL the sorted transforms.
	var multimesh = MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = _grass_blade_mesh
	multimesh.instance_count = _sorted_grass_transforms.size()
	
	var buffer = PackedFloat32Array()
	buffer.resize(_sorted_grass_transforms.size() * 12); var idx = 0
	for t in _sorted_grass_transforms:
		buffer[idx+0]=t.basis.x.x; buffer[idx+1]=t.basis.x.y; buffer[idx+2]=t.basis.x.z; buffer[idx+3]=t.origin.x
		buffer[idx+4]=t.basis.y.x; buffer[idx+5]=t.basis.y.y; buffer[idx+6]=t.basis.y.z; buffer[idx+7]=t.origin.y
		buffer[idx+8]=t.basis.z.x; buffer[idx+9]=t.basis.z.y; buffer[idx+10]=t.basis.z.z; buffer[idx+11]=t.origin.z
		idx += 12
	multimesh.set_buffer(buffer)
	# Initially, set the visible count to the max. It will be updated by the ChunkManager.
	multimesh.visible_instance_count = _sorted_grass_transforms.size()
	grass_multimesh.multimesh = multimesh



# --- CORRECTED FUNCTION ---
func update_grass_lod(player_pos: Vector3) -> void:
	if not is_instance_valid(grass_multimesh) or not is_instance_valid(grass_multimesh.multimesh):
		return

	# 1. Get the AABB of the visible terrain mesh in local space.
	var local_aabb: AABB = mesh_instance.get_aabb()
	
	# 2. Transform this local AABB into world space.
	var world_aabb: AABB = global_transform * local_aabb
	
	# 3. Define the min and max corners of the world AABB.
	# The max corner is the position + the size. THIS IS THE FIX.
	var min_corner: Vector3 = world_aabb.position
	var max_corner: Vector3 = world_aabb.position + world_aabb.size
	
	# 4. Find the closest point ON the surface (or inside) of the AABB to the player.
	var closest_point_on_aabb: Vector3 = player_pos.clamp(min_corner, max_corner)
	
	# 5. Now, calculate the distance from the player to that closest point.
	# If the player is inside the box, this distance will correctly be 0.
	var distance_to_chunk = player_pos.distance_to(closest_point_on_aabb)

	# --- The rest of the logic is the same and now works with the correct distance ---
	var density_multiplier = lod_density_multipliers[lod_density_multipliers.size() - 1] # Start with fallback
	for i in range(lod_distances.size()):
		if distance_to_chunk < lod_distances[i]:
			density_multiplier = lod_density_multipliers[i]
			break # Found the right LOD level, exit the loop.

	var total_instances = _sorted_grass_transforms.size()
	var visible_count = int(total_instances * density_multiplier)
	
	grass_multimesh.multimesh.visible_instance_count = visible_count



func generate_trees() -> void:
	if not tree_multimesh or not is_instance_valid(_tree_mesh): return
	var terrain_mesh: ArrayMesh = mesh_instance.mesh
	if not terrain_mesh or terrain_mesh.get_surface_count() == 0: return
	var mesh_arrays = terrain_mesh.surface_get_arrays(0)
	var vertices = mesh_arrays[Mesh.ARRAY_VERTEX]
	var normals = mesh_arrays[Mesh.ARRAY_NORMAL]
	var indices = mesh_arrays[Mesh.ARRAY_INDEX]
	if indices.is_empty(): return
	var tree_transforms: Array[Transform3D] = []
	var rng = RandomNumberGenerator.new()

	# --- FIX: Get the mesh's global transform ONCE outside the loop ---
	var mesh_global_transform = mesh_instance.global_transform if (mesh_instance and mesh_instance.is_inside_tree()) else (global_transform if is_inside_tree() else transform)

	for i in range(0, indices.size(), 3):
		var p0 = vertices[indices[i]]; var p1 = vertices[indices[i+1]]; var p2 = vertices[indices[i+2]]
		var avg_normal = (normals[indices[i]] + normals[indices[i+1]] + normals[indices[i+2]]).normalized()
		var local_avg_pos = (p0 + p1 + p2) / 3.0 # This is in LOCAL space
		
		# --- FIX: Convert the local position to a global (world) position ---
		var world_avg_pos = mesh_global_transform * local_avg_pos
		
		# --- FIX: Use the world position's Y for the height check ---
		if not (world_avg_pos.y > tree_min_height and world_avg_pos.y < tree_max_height): continue

		if avg_normal.y < tree_max_slope_normal_y: continue
		if rng.randf() > tree_density: continue

		var r1 = rng.randf(); var r2 = rng.randf()
		if r1 + r2 > 1.0: r1 = 1.0 - r1; r2 = 1.0 - r2
		var point_on_triangle = p0 + r1 * (p1 - p0) + r2 * (p2 - p0)
		
		var basis = Basis.IDENTITY
		var rot_y = rng.randf_range(0, TAU)
		basis = basis.rotated(Vector3.UP, rot_y)
		basis = basis.scaled(Vector3.ONE * rng.randf_range(tree_scale_min, tree_scale_max))
		
		var transform = Transform3D(basis, point_on_triangle)
		tree_transforms.append(transform)

	# ... (rest of the function is unchanged) ...
	if tree_transforms.is_empty(): tree_multimesh.multimesh = null; return
	var multimesh = MultiMesh.new(); multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = _tree_mesh; multimesh.instance_count = tree_transforms.size()
	var buffer = PackedFloat32Array(); buffer.resize(tree_transforms.size() * 12); var idx = 0
	for t in tree_transforms:
		buffer[idx+0]=t.basis.x.x; buffer[idx+1]=t.basis.x.y; buffer[idx+2]=t.basis.x.z; buffer[idx+3]=t.origin.x
		buffer[idx+4]=t.basis.y.x; buffer[idx+5]=t.basis.y.y; buffer[idx+6]=t.basis.y.z; buffer[idx+7]=t.origin.y
		buffer[idx+8]=t.basis.z.x; buffer[idx+9]=t.basis.z.y; buffer[idx+10]=t.basis.z.z; buffer[idx+11]=t.origin.z
		idx += 12
	multimesh.set_buffer(buffer); tree_multimesh.multimesh = multimesh


#=============================================================================
# --- MULTI-LAYER FLORA SYSTEM ---

func generate_all_flora() -> void:
	if not flora_container:
		flora_container = Node3D.new()
		flora_container.name = "FloraContainer"
		add_child(flora_container)
	else:
		for c in flora_container.get_children():
			c.queue_free()
			
	# Clear old legacy tree multimesh to prevent duplicates
	if tree_multimesh:
		tree_multimesh.multimesh = null
		
	if not active_blueprint or active_blueprint.vegetation_layers.is_empty():
		return
		
	var terrain_mesh: ArrayMesh = mesh_instance.mesh
	if not terrain_mesh or terrain_mesh.get_surface_count() == 0:
		return
		
	var mesh_arrays = terrain_mesh.surface_get_arrays(0)
	var vertices = mesh_arrays[Mesh.ARRAY_VERTEX]
	var normals = mesh_arrays[Mesh.ARRAY_NORMAL]
	var indices = mesh_arrays[Mesh.ARRAY_INDEX]
	if indices.is_empty():
		return
		
	var mesh_global_transform = mesh_instance.global_transform if (mesh_instance and mesh_instance.is_inside_tree()) else (global_transform if is_inside_tree() else transform)
	
	# Deterministic cluster distribution noise
	var cluster_noise = FastNoiseLite.new()
	cluster_noise.seed = (active_blueprint.world_seed + 1337) % 100000
	cluster_noise.frequency = 0.035
	
	# Deterministic chunk RNG seeded with blueprint world_seed + chunk coordinates
	var chunk_rng = RandomNumberGenerator.new()
	var chunk_seed = int((active_blueprint.world_seed * 73856093) ^ (chunk_coords.x * 19349663) ^ (chunk_coords.y * 83492791))
	chunk_rng.seed = chunk_seed
	
	_sorted_grass_transforms.clear()
	
	for layer_idx in range(active_blueprint.vegetation_layers.size()):
		var layer = active_blueprint.vegetation_layers[layer_idx]
		var layer_mesh = _create_mesh_for_layer(layer)
		if not is_instance_valid(layer_mesh):
			continue
			
		var transforms: Array[Transform3D] = []
		
		# Sample terrain triangles
		for i in range(0, indices.size(), 3):
			var p0 = vertices[indices[i]]
			var p1 = vertices[indices[i+1]]
			var p2 = vertices[indices[i+2]]
			var avg_normal = (normals[indices[i]] + normals[indices[i+1]] + normals[indices[i+2]]).normalized()
			var local_avg_pos = (p0 + p1 + p2) / 3.0
			var world_avg_pos = mesh_global_transform * local_avg_pos
			
			# 1. Height filter
			if world_avg_pos.y < layer.min_height or world_avg_pos.y > layer.max_height:
				continue
				
			# Targeted Mountain Flora Exclusion & Snow Cap Check
			if active_blueprint and (active_blueprint.is_flora_excluded(world_avg_pos.x, world_avg_pos.z) or active_blueprint.is_in_snow_cap(world_avg_pos.x, world_avg_pos.z, world_avg_pos.y)):
				continue
				
			# Biome affinity check
			if active_blueprint and not layer.target_biome_id.is_empty():
				var b_at_pos = active_blueprint.get_biome_at(world_avg_pos.x, world_avg_pos.z)
				if b_at_pos.id != layer.target_biome_id:
					continue
					
			# River proximity check
			if active_blueprint and (layer.near_water_only or layer.distribution == "riverbank_focused"):
				var r_info = active_blueprint.get_nearest_river_info(world_avg_pos.x, world_avg_pos.z)
				if r_info.distance > r_info.width * 2.5:
					continue
				
			# 2. Slope filter
			if avg_normal.y < layer.max_slope_normal_y:
				continue
				
			# 3. Spatial distribution filter
			var c_val = cluster_noise.get_noise_2d(world_avg_pos.x * 0.1, world_avg_pos.z * 0.1)
			match layer.distribution:
				"clustered":
					if c_val < 0.04:
						continue
				"clearing_centered":
					if c_val > -0.04:
						continue
				"edge_dense":
					var near_water = abs(world_avg_pos.y - visual_water_level) < 4.5
					var near_edge = abs(c_val) < 0.14
					if not (near_water or near_edge):
						continue
				"scattered":
					pass # Uniform coverage
					
			# 4. Density check
			if chunk_rng.randf() > layer.density:
				continue
				
			# 5. Barycentric position
			var r1 = chunk_rng.randf()
			var r2 = chunk_rng.randf()
			if r1 + r2 > 1.0:
				r1 = 1.0 - r1
				r2 = 1.0 - r2
			var pt = p0 + r1 * (p1 - p0) + r2 * (p2 - p0)
			
			# 6. Rotation & Scale
			var rot_y = chunk_rng.randf_range(0.0, TAU)
			var basis = Basis.IDENTITY.rotated(Vector3.UP, rot_y)
			if layer.archetype != "fallen_log":
				var tilt_x = deg_to_rad(chunk_rng.randf_range(-5.0, 5.0))
				var tilt_z = deg_to_rad(chunk_rng.randf_range(-5.0, 5.0))
				basis = basis.rotated(Vector3.RIGHT, tilt_x).rotated(Vector3.FORWARD, tilt_z)
				
			var s = chunk_rng.randf_range(layer.scale_min, layer.scale_max)
			basis = basis.scaled(Vector3.ONE * s)
			
			transforms.append(Transform3D(basis, pt))
			
		if transforms.is_empty():
			continue
			
		if layer.archetype == "ground_cover":
			_sorted_grass_transforms = transforms
			var multimesh = MultiMesh.new()
			multimesh.transform_format = MultiMesh.TRANSFORM_3D
			multimesh.mesh = layer_mesh
			multimesh.instance_count = transforms.size()
			var buf = PackedFloat32Array()
			buf.resize(transforms.size() * 12)
			var idx = 0
			for t in transforms:
				buf[idx+0]=t.basis.x.x; buf[idx+1]=t.basis.x.y; buf[idx+2]=t.basis.x.z; buf[idx+3]=t.origin.x
				buf[idx+4]=t.basis.y.x; buf[idx+5]=t.basis.y.y; buf[idx+6]=t.basis.y.z; buf[idx+7]=t.origin.y
				buf[idx+8]=t.basis.z.x; buf[idx+9]=t.basis.z.y; buf[idx+10]=t.basis.z.z; buf[idx+11]=t.origin.z
				idx += 12
			multimesh.set_buffer(buf)
			multimesh.visible_instance_count = transforms.size()
			if grass_multimesh:
				grass_multimesh.multimesh = multimesh
		else:
			var mmi = MultiMeshInstance3D.new()
			mmi.name = "Flora_%s_%d" % [layer.archetype, layer_idx]
			if layer.archetype in ["canopy_tree", "small_tree", "shrub", "fallen_log"]:
				mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
			else:
				mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				
			var multimesh = MultiMesh.new()
			multimesh.transform_format = MultiMesh.TRANSFORM_3D
			multimesh.mesh = layer_mesh
			multimesh.instance_count = transforms.size()
			var buf = PackedFloat32Array()
			buf.resize(transforms.size() * 12)
			var idx = 0
			for t in transforms:
				buf[idx+0]=t.basis.x.x; buf[idx+1]=t.basis.x.y; buf[idx+2]=t.basis.x.z; buf[idx+3]=t.origin.x
				buf[idx+4]=t.basis.y.x; buf[idx+5]=t.basis.y.y; buf[idx+6]=t.basis.y.z; buf[idx+7]=t.origin.y
				buf[idx+8]=t.basis.z.x; buf[idx+9]=t.basis.z.y; buf[idx+10]=t.basis.z.z; buf[idx+11]=t.origin.z
				idx += 12
			multimesh.set_buffer(buf)
			mmi.multimesh = multimesh
			flora_container.add_child(mmi)


func _create_mesh_for_layer(layer: ForestBlueprint.FloraLayerConfig) -> ArrayMesh:
	var trunk_mat = StandardMaterial3D.new()
	trunk_mat.cull_mode = BaseMaterial3D.CULL_BACK
	trunk_mat.albedo_color = layer.trunk_color
	
	var fol_mat = StandardMaterial3D.new()
	fol_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	fol_mat.albedo_color = layer.foliage_color
	if layer.emissive:
		fol_mat.emission_enabled = true
		fol_mat.emission = layer.emissive_color
		fol_mat.emission_energy_multiplier = layer.emissive_energy
		
	match layer.archetype:
		"canopy_tree":
			return _build_canopy_tree_mesh(trunk_mat, fol_mat)
		"small_tree":
			return _build_small_tree_mesh(trunk_mat, fol_mat)
		"shrub":
			return _build_shrub_mesh(trunk_mat, fol_mat)
		"fern":
			return _build_fern_mesh(fol_mat)
		"flower":
			var stem_mat = StandardMaterial3D.new()
			stem_mat.albedo_color = Color(0.15, 0.45, 0.15)
			return _build_flower_mesh(stem_mat, fol_mat)
		"ground_cover":
			return _build_ground_cover_mesh(fol_mat)
		"fallen_log":
			return _build_log_mesh(trunk_mat)
		_:
			return _build_canopy_tree_mesh(trunk_mat, fol_mat)


func _build_canopy_tree_mesh(trunk_mat: Material, foliage_mat: Material) -> ArrayMesh:
	var mesh = ArrayMesh.new()
	
	# Surface 1: Trunk (Hexagonal prism)
	var st_t = SurfaceTool.new()
	st_t.begin(Mesh.PRIMITIVE_TRIANGLES)
	st_t.set_material(trunk_mat)
	var segs = 6
	var base_r = 0.24
	var top_r = 0.14
	var h = 2.4
	for i in range(segs):
		var a0 = i * TAU / segs
		var a1 = (i + 1) * TAU / segs
		var b0 = Vector3(cos(a0) * base_r, 0, sin(a0) * base_r)
		var b1 = Vector3(cos(a1) * base_r, 0, sin(a1) * base_r)
		var t0 = Vector3(cos(a0) * top_r, h, sin(a0) * top_r)
		var t1 = Vector3(cos(a1) * top_r, h, sin(a1) * top_r)
		
		st_t.set_uv(Vector2(0, 1)); st_t.add_vertex(b0)
		st_t.set_uv(Vector2(1, 1)); st_t.add_vertex(b1)
		st_t.set_uv(Vector2(1, 0)); st_t.add_vertex(t1)
		
		st_t.set_uv(Vector2(0, 1)); st_t.add_vertex(b0)
		st_t.set_uv(Vector2(1, 0)); st_t.add_vertex(t1)
		st_t.set_uv(Vector2(0, 0)); st_t.add_vertex(t0)
	st_t.generate_normals()
	st_t.generate_tangents()
	st_t.commit(mesh)
	
	# Surface 2: Foliage (2 tiers)
	var st_f = SurfaceTool.new()
	st_f.begin(Mesh.PRIMITIVE_TRIANGLES)
	st_f.set_material(foliage_mat)
	
	# Tier 1 (lower, broader)
	var t1_y_bot = 1.6
	var t1_y_top = 2.8
	var t1_r_mid = 1.4
	for i in range(segs):
		var a0 = i * TAU / segs
		var a1 = (i + 1) * TAU / segs
		var m0 = Vector3(cos(a0) * t1_r_mid, (t1_y_bot + t1_y_top) * 0.5, sin(a0) * t1_r_mid)
		var m1 = Vector3(cos(a1) * t1_r_mid, (t1_y_bot + t1_y_top) * 0.5, sin(a1) * t1_r_mid)
		var bot = Vector3(0, t1_y_bot, 0)
		var top = Vector3(0, t1_y_top, 0)
		st_f.set_uv(Vector2(0.5, 1)); st_f.add_vertex(bot)
		st_f.set_uv(Vector2(1, 0.5)); st_f.add_vertex(m1)
		st_f.set_uv(Vector2(0, 0.5)); st_f.add_vertex(m0)
		
		st_f.set_uv(Vector2(0, 0.5)); st_f.add_vertex(m0)
		st_f.set_uv(Vector2(1, 0.5)); st_f.add_vertex(m1)
		st_f.set_uv(Vector2(0.5, 0)); st_f.add_vertex(top)
		
	# Tier 2 (upper, taller)
	var t2_y_bot = 2.5
	var t2_y_top = 4.2
	var t2_r_mid = 1.05
	for i in range(segs):
		var a0 = (i + 0.5) * TAU / segs
		var a1 = (i + 1.5) * TAU / segs
		var m0 = Vector3(cos(a0) * t2_r_mid, (t2_y_bot + t2_y_top) * 0.5, sin(a0) * t2_r_mid)
		var m1 = Vector3(cos(a1) * t2_r_mid, (t2_y_bot + t2_y_top) * 0.5, sin(a1) * t2_r_mid)
		var bot = Vector3(0, t2_y_bot, 0)
		var top = Vector3(0, t2_y_top, 0)
		st_f.set_uv(Vector2(0.5, 1)); st_f.add_vertex(bot)
		st_f.set_uv(Vector2(1, 0.5)); st_f.add_vertex(m1)
		st_f.set_uv(Vector2(0, 0.5)); st_f.add_vertex(m0)
		
		st_f.set_uv(Vector2(0, 0.5)); st_f.add_vertex(m0)
		st_f.set_uv(Vector2(1, 0.5)); st_f.add_vertex(m1)
		st_f.set_uv(Vector2(0.5, 0)); st_f.add_vertex(top)
		
	st_f.generate_normals()
	st_f.generate_tangents()
	st_f.commit(mesh)
	return mesh


func _build_small_tree_mesh(trunk_mat: Material, foliage_mat: Material) -> ArrayMesh:
	var mesh = ArrayMesh.new()
	var st_t = SurfaceTool.new()
	st_t.begin(Mesh.PRIMITIVE_TRIANGLES)
	st_t.set_material(trunk_mat)
	var segs = 5
	var base_r = 0.08
	var top_r = 0.05
	var h = 1.4
	for i in range(segs):
		var a0 = i * TAU / segs
		var a1 = (i + 1) * TAU / segs
		var b0 = Vector3(cos(a0) * base_r, 0, sin(a0) * base_r)
		var b1 = Vector3(cos(a1) * base_r, 0, sin(a1) * base_r)
		var t0 = Vector3(cos(a0) * top_r, h, sin(a0) * top_r)
		var t1 = Vector3(cos(a1) * top_r, h, sin(a1) * top_r)
		st_t.set_uv(Vector2(0, 1)); st_t.add_vertex(b0)
		st_t.set_uv(Vector2(1, 1)); st_t.add_vertex(b1)
		st_t.set_uv(Vector2(1, 0)); st_t.add_vertex(t1)
		st_t.set_uv(Vector2(0, 1)); st_t.add_vertex(b0)
		st_t.set_uv(Vector2(1, 0)); st_t.add_vertex(t1)
		st_t.set_uv(Vector2(0, 0)); st_t.add_vertex(t0)
	st_t.generate_normals()
	st_t.generate_tangents()
	st_t.commit(mesh)
	
	var st_f = SurfaceTool.new()
	st_f.begin(Mesh.PRIMITIVE_TRIANGLES)
	st_f.set_material(foliage_mat)
	var y_bot = 1.0
	var y_top = 2.4
	var r_mid = 0.75
	for i in range(segs):
		var a0 = i * TAU / segs
		var a1 = (i + 1) * TAU / segs
		var m0 = Vector3(cos(a0) * r_mid, 1.6, sin(a0) * r_mid)
		var m1 = Vector3(cos(a1) * r_mid, 1.6, sin(a1) * r_mid)
		var bot = Vector3(0, y_bot, 0)
		var top = Vector3(0, y_top, 0)
		st_f.set_uv(Vector2(0.5, 1)); st_f.add_vertex(bot)
		st_f.set_uv(Vector2(1, 0.5)); st_f.add_vertex(m1)
		st_f.set_uv(Vector2(0, 0.5)); st_f.add_vertex(m0)
		st_f.set_uv(Vector2(0, 0.5)); st_f.add_vertex(m0)
		st_f.set_uv(Vector2(1, 0.5)); st_f.add_vertex(m1)
		st_f.set_uv(Vector2(0.5, 0)); st_f.add_vertex(top)
	st_f.generate_normals()
	st_f.generate_tangents()
	st_f.commit(mesh)
	return mesh


func _build_shrub_mesh(stem_mat: Material, foliage_mat: Material) -> ArrayMesh:
	var mesh = ArrayMesh.new()
	var st_s = SurfaceTool.new()
	st_s.begin(Mesh.PRIMITIVE_TRIANGLES)
	st_s.set_material(stem_mat)
	for i in range(3):
		var ang = i * TAU / 3.0
		var dir = Vector3(cos(ang), 0.6, sin(ang)) * 0.35
		var w = Vector3(-sin(ang), 0, cos(ang)) * 0.03
		st_s.set_uv(Vector2(0, 1)); st_s.add_vertex(Vector3.ZERO - w)
		st_s.set_uv(Vector2(1, 1)); st_s.add_vertex(Vector3.ZERO + w)
		st_s.set_uv(Vector2(1, 0)); st_s.add_vertex(dir + w)
		st_s.set_uv(Vector2(0, 1)); st_s.add_vertex(Vector3.ZERO - w)
		st_s.set_uv(Vector2(1, 0)); st_s.add_vertex(dir + w)
		st_s.set_uv(Vector2(0, 0)); st_s.add_vertex(dir - w)
	st_s.generate_normals()
	st_s.commit(mesh)
	
	var st_f = SurfaceTool.new()
	st_f.begin(Mesh.PRIMITIVE_TRIANGLES)
	st_f.set_material(foliage_mat)
	var segs = 6
	var r = 0.65
	var y_bot = 0.15
	var y_mid = 0.55
	var y_top = 0.85
	for i in range(segs):
		var a0 = i * TAU / segs
		var a1 = (i + 1) * TAU / segs
		var m0 = Vector3(cos(a0) * r, y_mid, sin(a0) * r)
		var m1 = Vector3(cos(a1) * r, y_mid, sin(a1) * r)
		var bot = Vector3(0, y_bot, 0)
		var top = Vector3(0, y_top, 0)
		st_f.set_uv(Vector2(0.5, 1)); st_f.add_vertex(bot)
		st_f.set_uv(Vector2(1, 0.5)); st_f.add_vertex(m1)
		st_f.set_uv(Vector2(0, 0.5)); st_f.add_vertex(m0)
		st_f.set_uv(Vector2(0, 0.5)); st_f.add_vertex(m0)
		st_f.set_uv(Vector2(1, 0.5)); st_f.add_vertex(m1)
		st_f.set_uv(Vector2(0.5, 0)); st_f.add_vertex(top)
	st_f.generate_normals()
	st_f.generate_tangents()
	st_f.commit(mesh)
	return mesh


func _build_fern_mesh(frond_mat: Material) -> ArrayMesh:
	var mesh = ArrayMesh.new()
	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(frond_mat)
	
	var num_fronds = 6
	for i in range(num_fronds):
		var ang = i * TAU / num_fronds
		var fwd = Vector3(cos(ang), 0, sin(ang))
		var right = Vector3(-sin(ang), 0, cos(ang))
		
		var p0 = Vector3.ZERO
		var p1 = fwd * 0.35 + Vector3(0, 0.35, 0)
		var p2 = fwd * 0.65 + Vector3(0, 0.45, 0)
		var p3 = fwd * 0.85 + Vector3(0, 0.22, 0)
		
		var w1 = right * 0.08
		var w2 = right * 0.06
		
		# Quad 1
		st.set_uv(Vector2(0.5, 1.0)); st.add_vertex(p0)
		st.set_uv(Vector2(1.0, 0.65)); st.add_vertex(p1 + w1)
		st.set_uv(Vector2(0.0, 0.65)); st.add_vertex(p1 - w1)
		# Quad 2
		st.set_uv(Vector2(0.0, 0.65)); st.add_vertex(p1 - w1)
		st.set_uv(Vector2(1.0, 0.65)); st.add_vertex(p1 + w1)
		st.set_uv(Vector2(1.0, 0.35)); st.add_vertex(p2 + w2)
		st.set_uv(Vector2(0.0, 0.65)); st.add_vertex(p1 - w1)
		st.set_uv(Vector2(1.0, 0.35)); st.add_vertex(p2 + w2)
		st.set_uv(Vector2(0.0, 0.35)); st.add_vertex(p2 - w2)
		# Tip Quad
		st.set_uv(Vector2(0.0, 0.35)); st.add_vertex(p2 - w2)
		st.set_uv(Vector2(1.0, 0.35)); st.add_vertex(p2 + w2)
		st.set_uv(Vector2(0.5, 0.0)); st.add_vertex(p3)
		
	st.generate_normals()
	st.generate_tangents()
	st.commit(mesh)
	return mesh


func _build_flower_mesh(stem_mat: Material, petal_mat: Material) -> ArrayMesh:
	var mesh = ArrayMesh.new()
	var st_s = SurfaceTool.new()
	st_s.begin(Mesh.PRIMITIVE_TRIANGLES)
	st_s.set_material(stem_mat)
	var h = 0.45
	var sw = 0.02
	st_s.set_uv(Vector2(0, 1)); st_s.add_vertex(Vector3(-sw, 0, 0))
	st_s.set_uv(Vector2(1, 1)); st_s.add_vertex(Vector3(sw, 0, 0))
	st_s.set_uv(Vector2(1, 0)); st_s.add_vertex(Vector3(sw, h, 0))
	st_s.set_uv(Vector2(0, 1)); st_s.add_vertex(Vector3(-sw, 0, 0))
	st_s.set_uv(Vector2(1, 0)); st_s.add_vertex(Vector3(sw, h, 0))
	st_s.set_uv(Vector2(0, 0)); st_s.add_vertex(Vector3(-sw, h, 0))
	st_s.generate_normals()
	st_s.commit(mesh)
	
	var st_p = SurfaceTool.new()
	st_p.begin(Mesh.PRIMITIVE_TRIANGLES)
	st_p.set_material(petal_mat)
	var num_petals = 5
	var center = Vector3(0, h, 0)
	var pet_len = 0.22
	var pet_w = 0.09
	for i in range(num_petals):
		var ang = i * TAU / num_petals
		var fwd = Vector3(cos(ang), 0.25, sin(ang)).normalized() * pet_len
		var r = Vector3(-sin(ang), 0, cos(ang)) * pet_w
		st_p.set_uv(Vector2(0.5, 1)); st_p.add_vertex(center)
		st_p.set_uv(Vector2(1, 0.5)); st_p.add_vertex(center + fwd + r)
		st_p.set_uv(Vector2(0.5, 0)); st_p.add_vertex(center + fwd * 1.2)
		st_p.set_uv(Vector2(0.5, 1)); st_p.add_vertex(center)
		st_p.set_uv(Vector2(0.5, 0)); st_p.add_vertex(center + fwd * 1.2)
		st_p.set_uv(Vector2(0, 0.5)); st_p.add_vertex(center + fwd - r)
	st_p.generate_normals()
	st_p.generate_tangents()
	st_p.commit(mesh)
	return mesh


func _build_ground_cover_mesh(blade_mat: Material) -> ArrayMesh:
	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(blade_mat)
	var blades = [
		{"ang": 0.0, "h": 0.32, "w": 0.035, "tilt": 0.12},
		{"ang": 1.1, "h": 0.40, "w": 0.032, "tilt": 0.18},
		{"ang": 2.3, "h": 0.28, "w": 0.030, "tilt": 0.15},
		{"ang": 3.7, "h": 0.36, "w": 0.035, "tilt": 0.14}
	]
	for b in blades:
		var dir = Vector3(cos(b.ang), 0, sin(b.ang))
		var norm = Vector3(-sin(b.ang), 0, cos(b.ang))
		var v0 = -norm * b.w
		var v1 = norm * b.w
		var tip = dir * b.tilt + Vector3(0, b.h, 0)
		st.set_uv(Vector2(0, 1)); st.add_vertex(v0)
		st.set_uv(Vector2(1, 1)); st.add_vertex(v1)
		st.set_uv(Vector2(0.5, 0)); st.add_vertex(tip)
	st.generate_normals()
	st.generate_tangents()
	return st.commit()


func _build_log_mesh(bark_mat: Material) -> ArrayMesh:
	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(bark_mat)
	var segs = 6
	var r = 0.22
	var l_half = 1.1
	var cy = r
	for i in range(segs):
		var a0 = i * TAU / segs
		var a1 = (i + 1) * TAU / segs
		var p0_front = Vector3(cos(a0) * r, cy + sin(a0) * r, -l_half)
		var p1_front = Vector3(cos(a1) * r, cy + sin(a1) * r, -l_half)
		var p0_back = Vector3(cos(a0) * r, cy + sin(a0) * r, l_half)
		var p1_back = Vector3(cos(a1) * r, cy + sin(a1) * r, l_half)
		
		st.set_uv(Vector2(0, 1)); st.add_vertex(p0_front)
		st.set_uv(Vector2(1, 1)); st.add_vertex(p1_front)
		st.set_uv(Vector2(1, 0)); st.add_vertex(p1_back)
		st.set_uv(Vector2(0, 1)); st.add_vertex(p0_front)
		st.set_uv(Vector2(1, 0)); st.add_vertex(p1_back)
		st.set_uv(Vector2(0, 0)); st.add_vertex(p0_back)
		
		# Caps
		var c_front = Vector3(0, cy, -l_half)
		var c_back = Vector3(0, cy, l_half)
		st.set_uv(Vector2(0.5, 0.5)); st.add_vertex(c_front)
		st.set_uv(Vector2(0, 1)); st.add_vertex(p0_front)
		st.set_uv(Vector2(1, 1)); st.add_vertex(p1_front)
		st.set_uv(Vector2(0.5, 0.5)); st.add_vertex(c_back)
		st.set_uv(Vector2(1, 1)); st.add_vertex(p1_back)
		st.set_uv(Vector2(0, 1)); st.add_vertex(p0_back)
		
	st.generate_normals()
	st.generate_tangents()
	return st.commit()


#=============================================================================
# --- DYNAMIC HYDROLOGY & LANDMARK GENERATION ---

var river_mesh_instance: MeshInstance3D = null
var landmarks_container: Node3D = null

func _sample_raw_noise_height(wx: float, wz: float) -> float:
	if not noise_continent or not noise_mountain or not noise_valley or not noise_erosion:
		return 8.0
	var raw_continent_noise = noise_continent.get_noise_2d(wx, wz)
	var normalized_continent_noise = (raw_continent_noise + 1.0) * 0.5
	var conceptual_base_height = lerp(continent_min_height, continent_max_height, normalized_continent_noise)
	var mountain_modulator = clamp((conceptual_base_height - mountain_start_height) / mountain_fade_height, 0.0, 1.0)
	var m_potential = max(0.0, noise_mountain.get_noise_2d(wx, wz)) * mountain_scale
	var m = m_potential * mountain_modulator
	var valley_carve = 0.0
	if conceptual_base_height < valley_apply_threshold:
		var valley_noise = noise_valley.get_noise_2d(wx, wz)
		var negative_valley = min(valley_noise, 0.0)
		var valley_modulator = clamp((valley_apply_threshold - conceptual_base_height) / valley_apply_threshold, 0.0, 1.0)
		valley_carve = negative_valley * valley_carve_scale * valley_modulator
	var nc = normalized_continent_noise
	var erosion_modulator = 1.0 - abs(nc - 0.5) * 2.0
	var bump_e = noise_erosion.get_noise_2d(wx, wz) * erosion_scale * erosion_modulator
	var c_slope_contribution = raw_continent_noise * continent_slope_scale
	return c_slope_contribution + m + valley_carve + bump_e


func _setup_river_mesh() -> void:
	if not river_mesh_instance:
		river_mesh_instance = MeshInstance3D.new()
		river_mesh_instance.name = "RiverMeshInstance"
		add_child(river_mesh_instance)
	
	if not active_blueprint or active_blueprint.rivers.is_empty():
		river_mesh_instance.mesh = null
		return
	
	var river_shader = load("res://river.gdshader")
	if river_shader:
		var river_mat = ShaderMaterial.new()
		river_mat.shader = river_shader
		var primary_river = active_blueprint.rivers[0]
		river_mat.set_shader_parameter("flow_speed", float(primary_river.get("flow_speed", 0.65)))
		
		var total_waterfalls = 0
		for r in active_blueprint.rivers:
			var wf_list = r.get("waterfalls", [])
			if wf_list is Array:
				total_waterfalls += wf_list.size()
		river_mat.set_shader_parameter("waterfall_intensity", 0.85 if total_waterfalls > 0 else 0.0)
		river_mesh_instance.material_override = river_mat
	elif water_mesh_instance and water_mesh_instance.material_override:
		river_mesh_instance.material_override = water_mesh_instance.material_override
	
	var min_chunk_x = chunk_coords.x * chunk_size_x
	var max_chunk_x = (chunk_coords.x + 1) * chunk_size_x
	var min_chunk_z = chunk_coords.y * chunk_size_z
	var max_chunk_z = (chunk_coords.y + 1) * chunk_size_z
	
	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var has_segments = false
	
	for r in active_blueprint.rivers:
		var pts: PackedVector2Array = r.get("spline_points", r.get("points", PackedVector2Array()))
		if pts.size() < 2:
			continue
		var dists: PackedFloat32Array = r.get("distances", PackedFloat32Array())
		var half_w = float(r.get("width", 8.0)) * 0.55
		var r_depth = float(r.get("depth", 4.0))
		
		for i in range(pts.size() - 1):
			var pA = pts[i]
			var pB = pts[i + 1]
			
			var seg_min_x = minf(pA.x, pB.x) - half_w * 2.5
			var seg_max_x = maxf(pA.x, pB.x) + half_w * 2.5
			var seg_min_z = minf(pA.y, pB.y) - half_w * 2.5
			var seg_max_z = maxf(pA.y, pB.y) + half_w * 2.5
			
			if seg_max_x < min_chunk_x or seg_min_x > max_chunk_x or seg_max_z < min_chunk_z or seg_min_z > max_chunk_z:
				continue
				
			var dir = (pB - pA).normalized()
			var norm = Vector2(-dir.y, dir.x) * half_w
			
			var raw_yA = _sample_raw_noise_height(pA.x, pA.y)
			var raw_yB = _sample_raw_noise_height(pB.x, pB.y)
			var yA = active_blueprint.get_height_at(pA.x, pA.y, raw_yA) + r_depth * 0.55
			var yB = active_blueprint.get_height_at(pB.x, pB.y, raw_yB) + r_depth * 0.55
			
			var uv_y_a = (dists[i] / 12.0) if i < dists.size() else (float(i) * 0.3)
			var uv_y_b = (dists[i + 1] / 12.0) if (i + 1) < dists.size() else (float(i + 1) * 0.3)
			
			var vA_left = Vector3(pA.x + norm.x - min_chunk_x, yA, pA.y + norm.y - min_chunk_z)
			var vA_right = Vector3(pA.x - norm.x - min_chunk_x, yA, pA.y - norm.y - min_chunk_z)
			var vB_left = Vector3(pB.x + norm.x - min_chunk_x, yB, pB.y + norm.y - min_chunk_z)
			var vB_right = Vector3(pB.x - norm.x - min_chunk_x, yB, pB.y - norm.y - min_chunk_z)
			
			st.set_normal(Vector3.UP)
			st.set_uv(Vector2(0.0, uv_y_a)); st.add_vertex(vA_left)
			st.set_uv(Vector2(1.0, uv_y_a)); st.add_vertex(vA_right)
			st.set_uv(Vector2(1.0, uv_y_b)); st.add_vertex(vB_right)
			
			st.set_uv(Vector2(0.0, uv_y_a)); st.add_vertex(vA_left)
			st.set_uv(Vector2(1.0, uv_y_b)); st.add_vertex(vB_right)
			st.set_uv(Vector2(0.0, uv_y_b)); st.add_vertex(vB_left)
			has_segments = true
			
		for wf in r.get("waterfalls", []):
			var wf_pos: Vector2 = wf.get("pos", Vector2.ZERO)
			if wf_pos.x >= min_chunk_x and wf_pos.x <= max_chunk_x and wf_pos.y >= min_chunk_z and wf_pos.y <= max_chunk_z:
				var drop = float(wf.get("height_drop", 12.0))
				var raw_y = _sample_raw_noise_height(wf_pos.x, wf_pos.y)
				var top_y = active_blueprint.get_height_at(wf_pos.x, wf_pos.y, raw_y) + 1.0
				var btm_y = top_y - drop
				var local_x = wf_pos.x - min_chunk_x
				var local_z = wf_pos.y - min_chunk_z
				var c_tl = Vector3(local_x - half_w, top_y, local_z)
				var c_tr = Vector3(local_x + half_w, top_y, local_z)
				var c_br = Vector3(local_x + half_w, btm_y, local_z + 2.0)
				var c_bl = Vector3(local_x - half_w, btm_y, local_z + 2.0)
				st.set_normal(Vector3.FORWARD)
				st.set_uv(Vector2(0, 0)); st.add_vertex(c_tl)
				st.set_uv(Vector2(1, 0)); st.add_vertex(c_tr)
				st.set_uv(Vector2(1, 1)); st.add_vertex(c_br)
				st.set_uv(Vector2(0, 0)); st.add_vertex(c_tl)
				st.set_uv(Vector2(1, 1)); st.add_vertex(c_br)
				st.set_uv(Vector2(0, 1)); st.add_vertex(c_bl)
				has_segments = true
	
	if has_segments:
		st.generate_normals()
		river_mesh_instance.mesh = st.commit()
		river_mesh_instance.visible = true
	else:
		river_mesh_instance.mesh = null


func _spawn_landmarks_in_chunk() -> void:
	if not landmarks_container:
		landmarks_container = Node3D.new()
		landmarks_container.name = "LandmarksContainer"
		add_child(landmarks_container)
	else:
		for c in landmarks_container.get_children():
			c.queue_free()
	
	if not active_blueprint or active_blueprint.landmarks.is_empty():
		return
	
	var min_chunk_x = chunk_coords.x * chunk_size_x
	var max_chunk_x = (chunk_coords.x + 1) * chunk_size_x
	var min_chunk_z = chunk_coords.y * chunk_size_z
	var max_chunk_z = (chunk_coords.y + 1) * chunk_size_z
	
	for lm in active_blueprint.landmarks:
		var pos: Vector2 = lm.get("pos", Vector2.ZERO)
		if pos.x >= min_chunk_x and pos.x < max_chunk_x and pos.y >= min_chunk_z and pos.y < max_chunk_z:
			var local_x = pos.x - min_chunk_x
			var local_z = pos.y - min_chunk_z
			var local_y = active_blueprint.get_height_at(pos.x, pos.y, 10.0)
			
			var arch_mesh = _create_monolith_landmark_mesh(str(lm.get("type", "monolith")))
			var mi = MeshInstance3D.new()
			mi.mesh = arch_mesh
			mi.position = Vector3(local_x, local_y, local_z)
			mi.name = "LM_" + str(lm.get("id", "feature"))
			landmarks_container.add_child(mi)


func _create_monolith_landmark_mesh(type_str: String) -> ArrayMesh:
	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var mat = StandardMaterial3D.new()
	mat.albedo_color = Color(0.18, 0.22, 0.28)
	mat.metallic = 0.3
	mat.roughness = 0.6
	if "crystal" in type_str:
		mat.albedo_color = Color(0.4, 0.8, 1.0)
		mat.emission_enabled = true
		mat.emission = Color(0.2, 0.7, 1.0)
		mat.emission_energy_multiplier = 1.8
	st.set_material(mat)
	
	var w = 1.2
	var h = 8.0
	var d = 0.8
	var v0 = Vector3(-w, 0, -d); var v1 = Vector3(w, 0, -d); var v2 = Vector3(w, 0, d); var v3 = Vector3(-w, 0, d)
	var v4 = Vector3(-w * 0.7, h, -d * 0.7); var v5 = Vector3(w * 0.7, h, -d * 0.7); var v6 = Vector3(w * 0.7, h, d * 0.7); var v7 = Vector3(-w * 0.7, h, d * 0.7)
	
	# Front
	st.add_vertex(v0); st.add_vertex(v1); st.add_vertex(v5); st.add_vertex(v0); st.add_vertex(v5); st.add_vertex(v4)
	# Back
	st.add_vertex(v2); st.add_vertex(v3); st.add_vertex(v7); st.add_vertex(v2); st.add_vertex(v7); st.add_vertex(v6)
	# Left
	st.add_vertex(v3); st.add_vertex(v0); st.add_vertex(v4); st.add_vertex(v3); st.add_vertex(v4); st.add_vertex(v7)
	# Right
	st.add_vertex(v1); st.add_vertex(v2); st.add_vertex(v6); st.add_vertex(v1); st.add_vertex(v6); st.add_vertex(v5)
	# Top
	st.add_vertex(v4); st.add_vertex(v5); st.add_vertex(v6); st.add_vertex(v4); st.add_vertex(v6); st.add_vertex(v7)
	st.generate_normals()
	return st.commit()
