# AtmosphereManager.gd
class_name AtmosphereManager
extends Node3D

@export var world_environment: WorldEnvironment
@export var sun_light: DirectionalLight3D
@export var player: Node3D

var particles: CPUParticles3D


func _ready():
	_setup_particles()


func _setup_particles():
	particles = CPUParticles3D.new()
	particles.name = "WeatherParticles"
	particles.amount = 250
	particles.lifetime = 6.0
	particles.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	particles.emission_box_extents = Vector3(25, 12, 25)
	particles.spread = 180.0
	particles.gravity = Vector3(0, -0.2, 0)
	particles.initial_velocity_min = 0.2
	particles.initial_velocity_max = 0.8
	particles.scale_amount_min = 0.08
	particles.scale_amount_max = 0.25
	
	# Create billboard particle mesh
	var quad = QuadMesh.new()
	quad.size = Vector2(0.3, 0.3)
	var mat = StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.2, 0.9, 1.0, 0.8)
	quad.material = mat
	particles.mesh = quad
	
	add_child(particles)
	particles.emitting = false


func _process(_delta: float) -> void:
	if is_instance_valid(player) and is_instance_valid(particles):
		# Follow player smoothly in XZ
		particles.global_position.x = player.global_position.x
		particles.global_position.z = player.global_position.z
		particles.global_position.y = player.global_position.y + 4.0


func apply_blueprint(blueprint: ForestBlueprint) -> void:
	if blueprint == null:
		return
		
	# 1. Update WorldEnvironment
	if is_instance_valid(world_environment) and world_environment.environment:
		var env: Environment = world_environment.environment
		env.fog_enabled = true
		env.fog_density = blueprint.fog_density
		env.fog_light_color = blueprint.fog_color
		env.glow_enabled = true
		env.glow_bloom = blueprint.glow_intensity
		
		if env.sky and env.sky.sky_material is ProceduralSkyMaterial:
			var sky_mat: ProceduralSkyMaterial = env.sky.sky_material
			sky_mat.sky_top_color = blueprint.sky_top_color
			sky_mat.sky_horizon_color = blueprint.sky_horizon_color
			sky_mat.ground_bottom_color = blueprint.ground_bottom_color
			sky_mat.ground_horizon_color = blueprint.ground_horizon_color
			
	# 2. Update Directional Sun Light
	if is_instance_valid(sun_light):
		sun_light.light_color = blueprint.light_color
		sun_light.light_energy = blueprint.light_energy
		
	# 3. Update Weather / Special Event Particles
	if is_instance_valid(particles):
		var p_mesh: QuadMesh = particles.mesh as QuadMesh
		var p_mat: StandardMaterial3D = p_mesh.material as StandardMaterial3D if p_mesh else null
		
		match blueprint.special_event:
			"floating_spores":
				particles.emitting = true
				particles.gravity = Vector3(0, 0.05, 0) # drift up
				particles.initial_velocity_min = 0.1
				particles.initial_velocity_max = 0.4
				if p_mat:
					p_mat.albedo_color = Color(0.1, 0.95, 0.8, 0.85)
			"crystal_rain":
				particles.emitting = true
				particles.gravity = Vector3(0, -2.5, 0) # fall like crystal needles
				particles.initial_velocity_min = 0.5
				particles.initial_velocity_max = 1.5
				if p_mat:
					p_mat.albedo_color = Color(0.7, 0.5, 1.0, 0.9)
			"fireflies":
				particles.emitting = true
				particles.gravity = Vector3(0, 0.0, 0) # hover
				particles.initial_velocity_min = 0.3
				particles.initial_velocity_max = 0.8
				if p_mat:
					p_mat.albedo_color = Color(1.0, 0.9, 0.2, 0.9)
			"embers":
				particles.emitting = true
				particles.gravity = Vector3(0, 0.8, 0) # float up fast
				particles.initial_velocity_min = 0.4
				particles.initial_velocity_max = 1.2
				if p_mat:
					p_mat.albedo_color = Color(1.0, 0.35, 0.05, 0.9)
			_:
				particles.emitting = false
