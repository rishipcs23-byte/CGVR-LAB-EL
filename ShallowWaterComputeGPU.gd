# ShallowWaterComputeGPU.gd
# GPU Compute Shader pipeline for 2D Shallow Water Equations in Godot 4.4.
# Uses RenderingDevice compute pipelines for parallel numerical flux calculation.
# Includes parity validation against the authoritative CPU reference solver.
class_name ShallowWaterComputeGPU
extends RefCounted

const ShallowWaterSolver2D = preload("res://ShallowWaterSolver2D.gd")

var is_gpu_available: bool = false
var rd: RenderingDevice = null
var shader_rid: RID
var pipeline_rid: RID

var grid_res: Vector2i = Vector2i(128, 128)
var total_cells: int = 0

# Storage buffer RIDs
var buf_in_h: RID
var buf_in_qx: RID
var buf_in_qz: RID
var buf_in_bed: RID
var buf_out_h: RID
var buf_out_qx: RID
var buf_out_qz: RID
var uniform_set: RID

func _init(p_res: Vector2i = Vector2i(128, 128)) -> void:
	grid_res = p_res
	total_cells = grid_res.x * grid_res.y
	_initialize_rendering_device()

func _initialize_rendering_device() -> void:
	# Attempt to acquire a RenderingDevice instance from RenderingServer
	rd = RenderingServer.create_local_rendering_device()
	if not rd:
		# Fall back to main rendering device if local device creation is unsupported
		rd = RenderingServer.get_rendering_device()
		
	if not rd:
		print("ShallowWaterComputeGPU: RenderingDevice unavailable (running on CPU reference fallback).")
		is_gpu_available = false
		return
		
	var glsl_text = FileAccess.get_file_as_string("res://shaders/shallow_water_equations.glsl")
	if glsl_text.is_empty():
		printerr("ShallowWaterComputeGPU: Failed to read compute shader: res://shaders/shallow_water_equations.glsl")
		is_gpu_available = false
		return
		
	if glsl_text.begins_with("#[compute]"):
		glsl_text = glsl_text.substr(glsl_text.find("\n") + 1)
		
	var shader_src = RDShaderSource.new()
	shader_src.source_compute = glsl_text
	shader_src.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	
	var shader_spirv: RDShaderSPIRV = rd.shader_compile_spirv_from_source(shader_src)
	if not shader_spirv:
		printerr("ShallowWaterComputeGPU: Could not obtain SPIR-V bytecode from compute shader.")
		is_gpu_available = false
		return
		
	var err_msg = shader_spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	if not err_msg.is_empty():
		printerr("ShallowWaterComputeGPU: Shader compile error: ", err_msg)
		is_gpu_available = false
		return
		
	shader_rid = rd.shader_create_from_spirv(shader_spirv)
	if not shader_rid.is_valid():
		printerr("ShallowWaterComputeGPU: Failed to create shader from SPIR-V.")
		is_gpu_available = false
		return
		
	pipeline_rid = rd.compute_pipeline_create(shader_rid)
	if not pipeline_rid.is_valid():
		printerr("ShallowWaterComputeGPU: Failed to create compute pipeline.")
		is_gpu_available = false
		return
		
	is_gpu_available = true
	_allocate_buffers()

func _allocate_buffers() -> void:
	if not is_gpu_available:
		return
		
	var buffer_size_bytes = total_cells * 4 # 4 bytes per float32
	var zero_data = PackedByteArray()
	zero_data.resize(buffer_size_bytes)
	zero_data.fill(0)
	
	buf_in_h = rd.storage_buffer_create(buffer_size_bytes, zero_data)
	buf_in_qx = rd.storage_buffer_create(buffer_size_bytes, zero_data)
	buf_in_qz = rd.storage_buffer_create(buffer_size_bytes, zero_data)
	buf_in_bed = rd.storage_buffer_create(buffer_size_bytes, zero_data)
	
	buf_out_h = rd.storage_buffer_create(buffer_size_bytes, zero_data)
	buf_out_qx = rd.storage_buffer_create(buffer_size_bytes, zero_data)
	buf_out_qz = rd.storage_buffer_create(buffer_size_bytes, zero_data)
	
	# Create Uniform Set once during buffer allocation
	var uniforms: Array[RDUniform] = []
	var rids = [buf_in_h, buf_in_qx, buf_in_qz, buf_in_bed, buf_out_h, buf_out_qx, buf_out_qz]
	for binding in range(rids.size()):
		var u = RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		u.binding = binding
		u.add_id(rids[binding])
		uniforms.append(u)
		
	uniform_set = rd.uniform_set_create(uniforms, shader_rid, 0)

## Dispatches one GPU compute step given the current CPU solver state.
func step_gpu(solver: ShallowWaterSolver2D, dt: float) -> bool:
	if not is_gpu_available or not rd:
		return false
		
	var byte_size = total_cells * 4
	
	# Upload inputs
	var in_h_bytes = solver.h.to_byte_array()
	var in_qx_bytes = solver.qx.to_byte_array()
	var in_qz_bytes = solver.qz.to_byte_array()
	var in_bed_bytes = solver.bed.to_byte_array()
	
	rd.buffer_update(buf_in_h, 0, byte_size, in_h_bytes)
	rd.buffer_update(buf_in_qx, 0, byte_size, in_qx_bytes)
	rd.buffer_update(buf_in_qz, 0, byte_size, in_qz_bytes)
	rd.buffer_update(buf_in_bed, 0, byte_size, in_bed_bytes)
	
	# Pack push constants:
	# int width, int height, float dx, float dz, float dt, float g, float manning_n, float h_dry,
	# float rain, float infil, float evap, int bc_type
	var pc = PackedByteArray()
	pc.resize(48)
	pc.encode_s32(0, solver.grid_res.x)
	pc.encode_s32(4, solver.grid_res.y)
	pc.encode_float(8, solver.dx)
	pc.encode_float(12, solver.dz)
	pc.encode_float(16, dt)
	pc.encode_float(20, solver.gravity)
	pc.encode_float(24, solver.manning_n)
	pc.encode_float(28, solver.h_dry)
	pc.encode_float(32, solver.rain_rate)
	pc.encode_float(36, solver.infiltration_rate)
	pc.encode_float(40, solver.evaporation_rate)
	pc.encode_s32(44, int(solver.boundary_north))
	
	# Dispatch Compute List
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline_rid)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	rd.compute_list_set_push_constant(compute_list, pc, pc.size())
	
	var gx = int(ceil(float(solver.grid_res.x) / 16.0))
	var gy = int(ceil(float(solver.grid_res.y) / 16.0))
	rd.compute_list_dispatch(compute_list, gx, gy, 1)
	rd.compute_list_end()
	
	# Synchronize
	rd.submit()
	rd.sync()
	
	# Download output back into CPU solver buffers
	var out_h_bytes = rd.buffer_get_data(buf_out_h, 0, byte_size)
	var out_qx_bytes = rd.buffer_get_data(buf_out_qx, 0, byte_size)
	var out_qz_bytes = rd.buffer_get_data(buf_out_qz, 0, byte_size)
	
	solver.h = out_h_bytes.to_float32_array()
	solver.qx = out_qx_bytes.to_float32_array()
	solver.qz = out_qz_bytes.to_float32_array()
	solver._update_derived_fields()
	solver.sim_time += dt
	solver.step_count += 1
	
	return true

## Validates numerical parity between GPU compute output and CPU reference solver.
func validate_parity_with_cpu(solver_initial: ShallowWaterSolver2D, dt: float, max_tolerance: float = 1e-3) -> Dictionary:
	if not is_gpu_available:
		return {"tested": false, "gpu_available": false, "reason": "GPU RenderingDevice not supported in this runtime environment"}
		
	# Create two duplicate solvers
	var cpu_copy = ShallowWaterSolver2D.new(solver_initial.grid_res, solver_initial.world_size, solver_initial.world_origin)
	cpu_copy.manning_n = solver_initial.manning_n
	cpu_copy.set_bed_elevation(solver_initial.bed)
	cpu_copy.set_water_depth(solver_initial.h)
	cpu_copy.qx = solver_initial.qx.duplicate()
	cpu_copy.qz = solver_initial.qz.duplicate()
	cpu_copy._update_derived_fields()
	
	var gpu_copy = ShallowWaterSolver2D.new(solver_initial.grid_res, solver_initial.world_size, solver_initial.world_origin)
	gpu_copy.manning_n = solver_initial.manning_n
	gpu_copy.set_bed_elevation(solver_initial.bed)
	gpu_copy.set_water_depth(solver_initial.h)
	gpu_copy.qx = solver_initial.qx.duplicate()
	gpu_copy.qz = solver_initial.qz.duplicate()
	gpu_copy._update_derived_fields()
	
	# Step both
	cpu_copy.step(dt)
	var gpu_success = step_gpu(gpu_copy, dt)
	if not gpu_success:
		return {"tested": false, "gpu_available": false, "reason": "GPU step dispatch failed"}
		
	var max_diff_h = 0.0
	var max_diff_qx = 0.0
	var max_diff_qz = 0.0
	
	for i in range(total_cells):
		var dh = absf(cpu_copy.h[i] - gpu_copy.h[i])
		var dqx = absf(cpu_copy.qx[i] - gpu_copy.qx[i])
		var dqz = absf(cpu_copy.qz[i] - gpu_copy.qz[i])
		if dh > max_diff_h: max_diff_h = dh
		if dqx > max_diff_qx: max_diff_qx = dqx
		if dqz > max_diff_qz: max_diff_qz = dqz
		
	var within_tol = max_diff_h <= max_tolerance and max_diff_qx <= max_tolerance and max_diff_qz <= max_tolerance
	
	return {
		"tested": true,
		"gpu_available": true,
		"within_tolerance": within_tol,
		"max_diff_h": max_diff_h,
		"max_diff_qx": max_diff_qx,
		"max_diff_qz": max_diff_qz,
		"tolerance": max_tolerance
	}

func cleanup() -> void:
	if not is_gpu_available or not rd:
		return
	if uniform_set.is_valid(): rd.free_rid(uniform_set)
	if pipeline_rid.is_valid(): rd.free_rid(pipeline_rid)
	if shader_rid.is_valid(): rd.free_rid(shader_rid)
	if buf_in_h.is_valid(): rd.free_rid(buf_in_h)
	if buf_in_qx.is_valid(): rd.free_rid(buf_in_qx)
	if buf_in_qz.is_valid(): rd.free_rid(buf_in_qz)
	if buf_in_bed.is_valid(): rd.free_rid(buf_in_bed)
	if buf_out_h.is_valid(): rd.free_rid(buf_out_h)
	if buf_out_qx.is_valid(): rd.free_rid(buf_out_qx)
	if buf_out_qz.is_valid(): rd.free_rid(buf_out_qz)
	is_gpu_available = false

