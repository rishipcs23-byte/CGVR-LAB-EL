# WaterSurfaceRenderer.gd
# Dynamic 3D water surface rendering engine driven by SWE simulation fields.
# Uploads depth, velocity, and elevation data to GPU textures and drives fluid_water.gdshader.
# Supports rivers, lakes, rapids, spillways, and localized waterfall splash effects.
class_name WaterSurfaceRenderer
extends Node3D

const FluidSimulationManager = preload("res://FluidSimulationManager.gd")

@export var fluid_manager: FluidSimulationManager
@export var update_frequency_hz: float = 30.0 # Visual texture upload rate
@export var mesh_resolution: int = 128 # Quad mesh vertex resolution (matches 128x128 simulation)

var water_mesh_instance: MeshInstance3D = null
var water_material: ShaderMaterial = null

var depth_image: Image = null
var elevation_image: Image = null
var u_image: Image = null
var v_image: Image = null
var velocity_image: Image = null
var depth_texture: ImageTexture = null
var elevation_texture: ImageTexture = null
var u_texture: ImageTexture = null
var v_texture: ImageTexture = null
var velocity_texture: ImageTexture = null

var upload_timer: float = 0.0

func _ready() -> void:
	if not fluid_manager:
		# Auto-locate in parent or scene
		fluid_manager = get_node_or_null("../FluidSimulationManager")
		
	_setup_mesh_and_material()

## Explicitly initializes the renderer with an authoritative FluidSimulationManager.
func initialize(p_manager: FluidSimulationManager) -> void:
	fluid_manager = p_manager
	_setup_mesh_and_material()
	if fluid_manager and fluid_manager.solver:
		update_simulation_textures()

func _setup_mesh_and_material() -> void:
	if not water_mesh_instance:
		water_mesh_instance = MeshInstance3D.new()
		water_mesh_instance.name = "SWEWaterMeshInstance"
		add_child(water_mesh_instance)
		
	var shader = load("res://fluid_water.gdshader")
	if shader and not water_material:
		water_material = ShaderMaterial.new()
		water_material.shader = shader
		water_mesh_instance.material_override = water_material
		
	if water_mesh_instance.mesh == null:
		_build_base_plane_mesh()

func _build_base_plane_mesh() -> void:
	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	
	var res = mesh_resolution
	var half_w = 500.0
	var step_w = 1000.0 / float(res)
	
	for z_i in range(res):
		var z0 = -half_w + float(z_i) * step_w
		var z1 = -half_w + float(z_i + 1) * step_w
		var v0 = float(z_i) / float(res)
		var v1 = float(z_i + 1) / float(res)
		
		for x_i in range(res):
			var x0 = -half_w + float(x_i) * step_w
			var x1 = -half_w + float(x_i + 1) * step_w
			var u0 = float(x_i) / float(res)
			var u1 = float(x_i + 1) / float(res)
			
			var p00 = Vector3(x0, 0.0, z0)
			var p10 = Vector3(x1, 0.0, z0)
			var p01 = Vector3(x0, 0.0, z1)
			var p11 = Vector3(x1, 0.0, z1)
			
			# Triangle 1
			st.set_normal(Vector3.UP)
			st.set_uv(Vector2(u0, v0)); st.add_vertex(p00)
			st.set_uv(Vector2(u1, v0)); st.add_vertex(p10)
			st.set_uv(Vector2(u1, v1)); st.add_vertex(p11)
			
			# Triangle 2
			st.set_normal(Vector3.UP)
			st.set_uv(Vector2(u0, v0)); st.add_vertex(p00)
			st.set_uv(Vector2(u1, v1)); st.add_vertex(p11)
			st.set_uv(Vector2(u0, v1)); st.add_vertex(p01)
			
	st.generate_normals()
	water_mesh_instance.mesh = st.commit()

func _process(delta: float) -> void:
	if not fluid_manager or not fluid_manager.solver:
		return
		
	upload_timer += delta
	var interval = 1.0 / maxf(1.0, update_frequency_hz)
	if upload_timer >= interval:
		upload_timer = 0.0
		update_simulation_textures()

## Updates the GPU textures from the SWE simulation fields.
func update_simulation_textures() -> void:
	if not fluid_manager or not fluid_manager.solver:
		return
		
	var solver = fluid_manager.solver
	var gw = solver.grid_res.x
	var gh = solver.grid_res.y
	
	var h_bytes = solver.h.to_byte_array()
	var eta_bytes = solver.eta.to_byte_array()
	var u_bytes = solver.u.to_byte_array()
	var v_bytes = solver.v.to_byte_array()
		
	if not depth_image or depth_image.get_width() != gw or depth_image.get_height() != gh:
		depth_image = Image.create_from_data(gw, gh, false, Image.FORMAT_RF, h_bytes)
		elevation_image = Image.create_from_data(gw, gh, false, Image.FORMAT_RF, eta_bytes)
		u_image = Image.create_from_data(gw, gh, false, Image.FORMAT_RF, u_bytes)
		v_image = Image.create_from_data(gw, gh, false, Image.FORMAT_RF, v_bytes)
		velocity_image = u_image
		
		depth_texture = ImageTexture.create_from_image(depth_image)
		elevation_texture = ImageTexture.create_from_image(elevation_image)
		u_texture = ImageTexture.create_from_image(u_image)
		v_texture = ImageTexture.create_from_image(v_image)
		velocity_texture = u_texture
		
		if water_material:
			water_material.set_shader_parameter("depth_texture", depth_texture)
			water_material.set_shader_parameter("elevation_texture", elevation_texture)
			water_material.set_shader_parameter("vel_u_texture", u_texture)
			water_material.set_shader_parameter("vel_v_texture", v_texture)
			water_material.set_shader_parameter("velocity_texture", velocity_texture)
	else:
		depth_image.set_data(gw, gh, false, Image.FORMAT_RF, h_bytes)
		elevation_image.set_data(gw, gh, false, Image.FORMAT_RF, eta_bytes)
		u_image.set_data(gw, gh, false, Image.FORMAT_RF, u_bytes)
		v_image.set_data(gw, gh, false, Image.FORMAT_RF, v_bytes)
		
		depth_texture.update(depth_image)
		elevation_texture.update(elevation_image)
		u_texture.update(u_image)
		v_texture.update(v_image)
