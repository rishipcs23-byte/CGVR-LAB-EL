# FluidSimulationManager.gd
# Central coordinator for the physically-based dynamic shallow water simulation.
# Couples WorldState terrain, LakeBasinSolver water bodies, and river networks
# to the numerical SWE solver, managing timestepping, boundary conditions, and weather.
class_name FluidSimulationManager
extends Node

const WorldState = preload("res://WorldState.gd")
const ShallowWaterSolver2D = preload("res://ShallowWaterSolver2D.gd")
const ShallowWaterComputeGPU = preload("res://ShallowWaterComputeGPU.gd")

signal simulation_stepped(dt: float, diagnostics: Dictionary)
signal state_synced_to_world()

@export var is_simulating: bool = true
@export var simulation_resolution: Vector2i = Vector2i(128, 128)
@export var use_gpu: bool = true
@export var simulation_frequency_hz: float = 30.0 # Independent simulation rate
@export var use_adaptive_timestep: bool = true
@export var fixed_timestep: float = 0.05
@export var manning_roughness: float = 0.035

# Weather rates in mm/hour (convenient physical units)
@export var rainfall_mm_h: float = 0.0
@export var infiltration_mm_h: float = 0.0
@export var evaporation_mm_h: float = 0.0

var world_state: WorldState = null
var solver: ShallowWaterSolver2D = null
var gpu_compute: ShallowWaterComputeGPU = null

# Diagnostic history & metrics
var last_diagnostics: Dictionary = {}
var total_elapsed_time: float = 0.0
var total_steps_computed: int = 0
var sim_accum_timer: float = 0.0

func _ready() -> void:
	if not solver and not world_state:
		solver = ShallowWaterSolver2D.new(simulation_resolution)
		solver.manning_n = manning_roughness

func _physics_process(delta: float) -> void:
	if not is_simulating or not solver:
		return
		
	var interval = 1.0 / maxf(1.0, simulation_frequency_hz)
	sim_accum_timer += delta
	
	if sim_accum_timer >= interval:
		var sim_dt = sim_accum_timer
		sim_accum_timer = 0.0
		
		var step_dt = sim_dt if not use_adaptive_timestep else solver.compute_cfl_timestep()
		var dt_taken = 0.0
		
		# Step with GPU if available, else CPU fallback
		if gpu_compute and gpu_compute.is_gpu_available:
			var success = gpu_compute.step_gpu(solver, step_dt)
			if success:
				dt_taken = step_dt
			else:
				dt_taken = solver.step(step_dt)
		else:
			dt_taken = solver.step(step_dt)
			
		total_elapsed_time += dt_taken
		total_steps_computed += 1
		
		last_diagnostics = get_diagnostics()
		simulation_stepped.emit(dt_taken, last_diagnostics)

## Initializes the fluid simulation solver and couples it to an authoritative WorldState.
func initialize_from_world_state(p_world_state: WorldState, res: Vector2i = Vector2i(128, 128)) -> void:
	world_state = p_world_state
	simulation_resolution = res
	
	solver = ShallowWaterSolver2D.new(simulation_resolution, world_state.world_size, world_state.world_origin)
	solver.manning_n = manning_roughness
	
	# Attempt GPU acceleration if requested
	if use_gpu:
		gpu_compute = ShallowWaterComputeGPU.new(simulation_resolution)
		if not gpu_compute.is_gpu_available:
			print("FluidSimulationManager: GPU unavailable (running on authoritative CPU solver).")
			gpu_compute = null
		else:
			print("FluidSimulationManager: GPU compute initialized on %s." % gpu_compute.rd.get_device_name())
	else:
		gpu_compute = null
		
	# 1. Resample and ingest terrain bed elevation from WorldState
	_ingest_bed_elevation()
	
	# 2. Ingest lake water bodies and river channels into the fluid depth buffer
	_ingest_water_features()
	
	# 3. Ingest river springs and inflows from FeatureRegistry
	_ingest_rivers()
	
	# 4. Set weather rates
	update_weather(rainfall_mm_h, infiltration_mm_h, evaporation_mm_h)
	
	# 5. Reset solver diagnostics for accurate mass accounting
	solver.reset_diagnostics()
	last_diagnostics = get_diagnostics()

## Resamples bed elevation from WorldState raw elevation buffer to simulation grid.
func _ingest_bed_elevation() -> void:
	var total = solver.total_cells
	var bed_buf = PackedFloat32Array()
	bed_buf.resize(total)
	
	for gy in range(solver.grid_res.y):
		var row = gy * solver.grid_res.x
		for gx in range(solver.grid_res.x):
			var wpos = grid_to_world(gx, gy)
			bed_buf[row + gx] = world_state.get_elevation_at(wpos.x, wpos.y)
			
	solver.set_bed_elevation(bed_buf)

## Ingests lake water bodies and river channel water from WorldState and FeatureRegistry.
func _ingest_water_features() -> void:
	var total = solver.total_cells
	var h_buf = PackedFloat32Array()
	h_buf.resize(total)
	h_buf.fill(0.0)
	
	# 1. Lake depressions
	for gy in range(solver.grid_res.y):
		var row = gy * solver.grid_res.x
		for gx in range(solver.grid_res.x):
			var wpos = grid_to_world(gx, gy)
			var lake_depth = world_state.get_lake_depth_at(wpos.x, wpos.y)
			if lake_depth > 0.01:
				h_buf[row + gx] = lake_depth
				
	# 2. River channel paths
	if world_state and world_state.feature_registry:
		var rivers = world_state.feature_registry.get_features_by_type("river")
		for r in rivers:
			var params: Dictionary = r.get("parameters", {})
			var pts = params.get("spline_points", params.get("points", PackedVector2Array()))
			var r_depth = float(params.get("depth", 1.5))
			var r_width = float(params.get("width", 8.0))
			var rad_cells = maxi(1, int(ceil(r_width / (2.0 * solver.dx))))
			
			for pt in pts:
				var g = world_to_grid(pt.x, pt.y)
				for dy in range(-rad_cells, rad_cells + 1):
					for dx in range(-rad_cells, rad_cells + 1):
						var cx = g.x + dx
						var cy = g.y + dy
						if cx >= 0 and cx < solver.grid_res.x and cy >= 0 and cy < solver.grid_res.y:
							var idx = cy * solver.grid_res.x + cx
							if h_buf[idx] < r_depth:
								h_buf[idx] = r_depth
								
	solver.set_water_depth(h_buf)

## Ingests river springs and tributary inflows from FeatureRegistry as point sources.
func _ingest_rivers() -> void:
	solver.point_sources.clear()
	if not world_state or not world_state.feature_registry:
		return
		
	var rivers = world_state.feature_registry.get_features_by_type("river")
	for r in rivers:
		var params: Dictionary = r.get("parameters", {})
		var pts = params.get("points", PackedVector2Array())
		if pts.size() > 0:
			var spring_pos: Vector2 = pts[0]
			var g = world_to_grid(spring_pos.x, spring_pos.y)
			# Base river discharge (e.g. 20.0 m³/s for typical headwater spring)
			var discharge = float(params.get("spring_discharge", 20.0))
			solver.point_sources.append({
				"gx": g.x,
				"gy": g.y,
				"discharge": discharge
			})

## Updates weather parameters (converts mm/hour to m/s).
func update_weather(p_rain_mm_h: float, p_infil_mm_h: float, p_evap_mm_h: float) -> void:
	rainfall_mm_h = p_rain_mm_h
	infiltration_mm_h = p_infil_mm_h
	evaporation_mm_h = p_evap_mm_h
	
	if solver:
		# mm/hour to m/s: (1e-3 m / mm) / (3600 s / hour) = 1.0 / 3.6e6
		solver.rain_rate = (rainfall_mm_h * 1e-3) / 3600.0
		solver.infiltration_rate = (infiltration_mm_h * 1e-3) / 3600.0
		solver.evaporation_rate = (evaporation_mm_h * 1e-3) / 3600.0

## Advances the simulation manually by a designated time duration (in seconds).
func advance(duration: float, dt_override: float = -1.0) -> Dictionary:
	if not solver:
		return {}
		
	var time_left = duration
	while time_left > 1e-5:
		var step_dt = dt_override if dt_override > 0.0 else solver.compute_cfl_timestep()
		if step_dt > time_left:
			step_dt = time_left
			
		var actual_dt = 0.0
		if gpu_compute and gpu_compute.is_gpu_available:
			var success = gpu_compute.step_gpu(solver, step_dt)
			actual_dt = step_dt if success else solver.step(step_dt)
		else:
			actual_dt = solver.step(step_dt)
			
		time_left -= actual_dt
		total_elapsed_time += actual_dt
		total_steps_computed += 1
		
	last_diagnostics = get_diagnostics()
	return last_diagnostics

## Applies localized terrain elevation updates from WorldEditManager dirty regions without reallocating grids.
func apply_localized_terrain_update(dirty_bounds: Rect2) -> void:
	if not solver or not world_state:
		return
		
	var min_g = world_to_grid(dirty_bounds.position.x, dirty_bounds.position.y)
	var max_g = world_to_grid(dirty_bounds.end.x, dirty_bounds.end.y)
	
	var gx0 = clampi(min_g.x - 1, 0, solver.grid_res.x - 1)
	var gy0 = clampi(min_g.y - 1, 0, solver.grid_res.y - 1)
	var gx1 = clampi(max_g.x + 1, 0, solver.grid_res.x - 1)
	var gy1 = clampi(max_g.y + 1, 0, solver.grid_res.y - 1)
	
	var w = solver.grid_res.x
	for gy in range(gy0, gy1 + 1):
		var row = gy * w
		for gx in range(gx0, gx1 + 1):
			var idx = row + gx
			var wpos = grid_to_world(gx, gy)
			solver.bed[idx] = world_state.get_elevation_at(wpos.x, wpos.y)
			
			# Re-evaluate lake depth inside the modified region
			var lake_d = world_state.get_lake_depth_at(wpos.x, wpos.y)
			if lake_d > 0.01:
				solver.h[idx] = maxf(solver.h[idx], lake_d)
				
			solver.eta[idx] = solver.bed[idx] + solver.h[idx]

# -----------------------------------------------------------------------------
# Spatial Continuous Queries
# -----------------------------------------------------------------------------

## Converts world coordinates (wx, wz) to integer grid coordinates (gx, gy).
func world_to_grid(wx: float, wz: float) -> Vector2i:
	if not solver: return Vector2i.ZERO
	var gx = int(round((wx - solver.world_origin.x) / solver.dx))
	var gy = int(round((wz - solver.world_origin.y) / solver.dz))
	return Vector2i(clampi(gx, 0, solver.grid_res.x - 1), clampi(gy, 0, solver.grid_res.y - 1))

## Converts integer grid coordinates (gx, gy) to continuous world coordinates.
func grid_to_world(gx: int, gy: int) -> Vector2:
	if not solver: return Vector2.ZERO
	var wx = solver.world_origin.x + float(gx) * solver.dx
	var wz = solver.world_origin.y + float(gy) * solver.dz
	return Vector2(wx, wz)

## Returns physical water depth (h) in meters at world coordinates.
func get_water_depth_at(wx: float, wz: float) -> float:
	if not solver: return 0.0
	return _sample_buffer_bilinear(solver.h, wx, wz)

## Returns free water surface elevation (eta = bed + h) in meters at world coordinates.
func get_water_surface_elevation_at(wx: float, wz: float) -> float:
	if not solver: return 0.0
	return _sample_buffer_bilinear(solver.eta, wx, wz)

## Returns depth-averaged velocity vector (u, v) in m/s at world coordinates.
func get_water_velocity_at(wx: float, wz: float) -> Vector2:
	if not solver: return Vector2.ZERO
	var u_val = _sample_buffer_bilinear(solver.u, wx, wz)
	var v_val = _sample_buffer_bilinear(solver.v, wx, wz)
	return Vector2(u_val, v_val)

func _sample_buffer_bilinear(buf: PackedFloat32Array, wx: float, wz: float) -> float:
	var fx = (wx - solver.world_origin.x) / solver.dx
	var fy = (wz - solver.world_origin.y) / solver.dz
	
	var x0 = clampi(int(floor(fx)), 0, solver.grid_res.x - 1)
	var y0 = clampi(int(floor(fy)), 0, solver.grid_res.y - 1)
	var x1 = clampi(x0 + 1, 0, solver.grid_res.x - 1)
	var y1 = clampi(y0 + 1, 0, solver.grid_res.y - 1)
	
	var tx = clampf(fx - float(x0), 0.0, 1.0)
	var ty = clampf(fy - float(y0), 0.0, 1.0)
	
	var w = solver.grid_res.x
	var v00 = buf[y0 * w + x0]
	var v10 = buf[y0 * w + x1]
	var v01 = buf[y1 * w + x0]
	var v11 = buf[y1 * w + x1]
	
	var top = lerpf(v00, v10, tx)
	var bot = lerpf(v01, v11, tx)
	return lerpf(top, bot, ty)

# -----------------------------------------------------------------------------
# Diagnostic Telemetry
# -----------------------------------------------------------------------------

## Returns full diagnostic telemetry including mass balance, max velocity, volume, and CFL timestep.
func get_diagnostics() -> Dictionary:
	if not solver:
		return {}
		
	var mass_info = solver.compute_mass_balance_error()
	var wet_cells = 0
	for i in range(solver.total_cells):
		if solver.h[i] > solver.h_dry:
			wet_cells += 1
			
	return {
		"sim_time_s": solver.sim_time,
		"total_steps": solver.step_count,
		"cfl_dt_s": solver.compute_cfl_timestep(),
		"current_volume_m3": mass_info.current_volume,
		"initial_volume_m3": mass_info.initial_volume,
		"cumulative_inflow_m3": mass_info.cumulative_inflow,
		"cumulative_outflow_m3": mass_info.cumulative_outflow,
		"mass_balance_abs_error_m3": mass_info.absolute_error_m3,
		"mass_balance_relative_error": mass_info.relative_error,
		"max_velocity_m_s": solver.get_max_velocity(),
		"max_depth_m": solver.get_max_depth(),
		"wet_cells_count": wet_cells,
		"wet_area_m2": float(wet_cells) * solver.cell_area
	}
