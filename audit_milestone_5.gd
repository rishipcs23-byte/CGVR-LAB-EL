# audit_milestone_5.gd
# Independent verification, numerical benchmarks, and performance audit for Milestone 5.
extends SceneTree

const TerrainEngine = preload("res://TerrainEngine.gd")
const HydrologyEngine = preload("res://HydrologyEngine.gd")
const LakeBasinSolver = preload("res://LakeBasinSolver.gd")
const WorldState = preload("res://WorldState.gd")
const FeatureRegistry = preload("res://FeatureRegistry.gd")
const ShallowWaterSolver2D = preload("res://ShallowWaterSolver2D.gd")
const FluidSimulationManager = preload("res://FluidSimulationManager.gd")
const ShallowWaterComputeGPU = preload("res://ShallowWaterComputeGPU.gd")
const WaterSurfaceRenderer = preload("res://WaterSurfaceRenderer.gd")
const DirtyRegionTracker = preload("res://DirtyRegionTracker.gd")
const WorldEditManager = preload("res://WorldEditManager.gd")

func _init() -> void:
	print("=================================================================")
	print("SUBLIMEGREENS — MILESTONE 5 INDEPENDENT AUDIT & VERIFICATION")
	print("=================================================================\n")
	
	run_numerical_correctness_and_ritter_audit()
	run_mass_conservation_audit()
	run_gpu_audit()
	run_integration_audit()
	run_cpu_profiling_and_benchmarks()
	
	print("\n=================================================================")
	print("AUDIT EXECUTION COMPLETE")
	print("=================================================================")
	quit(0)

# =============================================================================
# 1. NUMERICAL CORRECTNESS & RITTER DAM-BREAK BENCHMARK
# =============================================================================

func run_numerical_correctness_and_ritter_audit() -> void:
	print("--- 1. NUMERICAL CORRECTNESS & 1D RITTER DAM-BREAK BENCHMARK ---")
	
	# Analytical Ritter (1892) Benchmark:
	# 1D dam break on dry flat bed with zero friction
	# Domain: [-100, 100] m, N = 200 cells (dx = 1.0 m)
	# Dam at x = 0. Initial: h0 = 10.0 m for x <= 0, h = 0 m for x > 0.
	# At t = 2.5s, compare numerical h(x) against analytical h_ritter(x).
	var grid_res = Vector2i(200, 3) # Quasi-1D (width 200, depth 3)
	var world_size = Vector2(200.0, 3.0)
	var origin = Vector2(-100.0, -1.5)
	
	var solver = ShallowWaterSolver2D.new(grid_res, world_size, origin)
	solver.manning_n = 0.0 # Frictionless for Ritter comparison
	solver.h_dry = 1e-4
	solver.cfl = 0.4
	
	var h0 = 10.0
	var g = solver.gravity
	var c0 = sqrt(g * h0) # Wave speed = ~9.9028 m/s
	
	for y in range(grid_res.y):
		for x in range(grid_res.x):
			var idx = y * grid_res.x + x
			var wx = origin.x + float(x) * solver.dx
			solver.bed[idx] = 0.0
			solver.h[idx] = h0 if wx <= 0.0 else 0.0
	solver._update_derived_fields()
	
	var target_time = 2.5 # seconds
	var current_t = 0.0
	while current_t < target_time:
		var dt = solver.compute_cfl_timestep()
		if current_t + dt > target_time:
			dt = target_time - current_t
		solver.step(dt)
		current_t += dt
		
	# Compute analytical Ritter solution along center row y = 1
	var y_mid = 1
	var x_tail = -target_time * c0 # Rarefaction wave tail
	var x_tip = 2.0 * target_time * c0 # Wetting front tip
	
	var sum_abs_err = 0.0
	var sum_sq_err = 0.0
	var max_abs_err = 0.0
	var sum_exact = 0.0
	var mid_dam_err = 0.0
	var count = 0
	
	for x in range(grid_res.x):
		var wx = origin.x + float(x) * solver.dx + 0.5 * solver.dx
		var h_num = solver.h[y_mid * grid_res.x + x]
		
		# Analytical Ritter depth
		var h_exact = 0.0
		if wx <= x_tail:
			h_exact = h0
		elif wx < x_tip:
			var term = c0 - (wx / (2.0 * target_time))
			h_exact = (4.0 / (9.0 * g)) * (term * term)
		else:
			h_exact = 0.0
			
		var err = absf(h_num - h_exact)
		sum_abs_err += err
		sum_sq_err += err * err
		if err > max_abs_err:
			max_abs_err = err
		sum_exact += h_exact
		count += 1
		
		# Sample error near dam crest wx ~ 0.0
		if absf(wx) < 1.0:
			mid_dam_err = absf(h_num - (4.0 / 9.0) * h0)
			
	var l1_err = sum_abs_err / float(count)
	var l2_rms = sqrt(sum_sq_err / float(count))
	var rel_l1 = sum_abs_err / maxf(1.0, sum_exact)
	
	print("[RITTER 1D BENCHMARK] Simulation Time: %.2fs" % target_time)
	print("  - Dam initial head:         %.2f m" % h0)
	print("  - Wave celerity c0:         %.3f m/s" % c0)
	print("  - Rarefaction tail x_tail:  %.2f m (exact)" % x_tail)
	print("  - Wetting front tip x_tip:  %.2f m (exact)" % x_tip)
	print("  - Theoretical Dam Depth:    %.3f m (4/9 * h0)" % ((4.0 / 9.0) * h0))
	print("  - Dam Site Abs Error:       %.4f m" % mid_dam_err)
	print("  - Mean L1 Error:            %.4f m" % l1_err)
	print("  - RMS L2 Error:             %.4f m" % l2_rms)
	print("  - Max Absolute Error:       %.4f m" % max_abs_err)
	print("  - Relative L1 Error:        %.2f %%" % (rel_l1 * 100.0))
	
	# Lake-at-rest well-balanced check on steep slope
	var sloped_solver = ShallowWaterSolver2D.new(Vector2i(64, 64), Vector2(100.0, 100.0))
	sloped_solver.manning_n = 0.0
	for y in range(64):
		for x in range(64):
			var idx = y * 64 + x
			var b = float(x) * 0.5 + float(y) * 0.3 # 50m slope
			sloped_solver.bed[idx] = b
			sloped_solver.h[idx] = maxf(0.0, 45.0 - b) # Still water level at 45m
	sloped_solver._update_derived_fields()
	for s in range(50):
		sloped_solver.step(0.02)
	var max_v = sloped_solver.get_max_velocity()
	print("[WELL-BALANCED AUDUSSE TEST] 50 steps on steep sloped bed:")
	print("  - Spurious maximum velocity: " + str(max_v) + " m/s")
	print("  - Well-balanced status:      %s\n" % ("PASS (< 1e-5)" if max_v < 1e-5 else "FAIL"))

# =============================================================================
# 2. MASS CONSERVATION AUDIT ACROSS 7 INDEPENDENT SCENARIOS
# =============================================================================

func run_mass_conservation_audit() -> void:
	print("--- 2. MASS CONSERVATION AUDIT ACROSS 7 SCENARIOS ---")
	
	var scenarios = [
		{"name": "1. Closed domain sloshing (zero sources/sinks)", "rain": 0.0, "infil": 0.0, "evap": 0.0, "inflow": 0.0, "open_bc": false, "init_water": true},
		{"name": "2. Rainfall (50 mm/h on dry & wet terrain)", "rain": 50.0, "infil": 0.0, "evap": 0.0, "inflow": 0.0, "open_bc": false, "init_water": true},
		{"name": "3. Soil infiltration (20 mm/h)", "rain": 0.0, "infil": 20.0, "evap": 0.0, "inflow": 0.0, "open_bc": false, "init_water": true},
		{"name": "4. Evaporation (15 mm/h)", "rain": 0.0, "infil": 0.0, "evap": 15.0, "inflow": 0.0, "open_bc": false, "init_water": true},
		{"name": "5. River continuous inflow (30 m³/s spring)", "rain": 0.0, "infil": 0.0, "evap": 0.0, "inflow": 30.0, "open_bc": false, "init_water": false},
		{"name": "6. Open boundaries (water draining out domain)", "rain": 0.0, "infil": 0.0, "evap": 0.0, "inflow": 0.0, "open_bc": true, "init_water": true},
		{"name": "7. Combined sources & sinks (Rain + Infil + Evap + Inflow + Open BC)", "rain": 25.0, "infil": 10.0, "evap": 8.0, "inflow": 20.0, "open_bc": true, "init_water": true}
	]
	
	for sc in scenarios:
		var solver = ShallowWaterSolver2D.new(Vector2i(64, 64), Vector2(200.0, 200.0))
		solver.manning_n = 0.03
		
		# Initial water distribution
		if sc["init_water"]:
			for y in range(64):
				for x in range(64):
					var idx = y * 64 + x
					# Central Gaussian mound
					var dist = Vector2(float(x - 32), float(y - 32)).length()
					if dist < 18.0:
						solver.h[idx] = (1.0 - dist / 18.0) * 3.0
					else:
						solver.h[idx] = 0.0
		else:
			solver.h.fill(0.0)
		solver._update_derived_fields()
		solver.initial_volume = solver.compute_total_water_volume()
		
		# Weather
		solver.rain_rate = (sc["rain"] * 1e-3) / 3600.0
		solver.infiltration_rate = (sc["infil"] * 1e-3) / 3600.0
		solver.evaporation_rate = (sc["evap"] * 1e-3) / 3600.0
		
		# Inflow point source
		if sc["inflow"] > 0.0:
			solver.point_sources.append({"gx": 32, "gy": 32, "discharge": sc["inflow"]})
			
		# Open boundary
		if sc["open_bc"]:
			solver.boundary_north = ShallowWaterSolver2D.BoundaryType.WALL
			solver.boundary_south = ShallowWaterSolver2D.BoundaryType.WALL
			solver.boundary_west = ShallowWaterSolver2D.BoundaryType.WALL
			solver.boundary_east = ShallowWaterSolver2D.BoundaryType.OUTFLOW
			# Create a slope descending eastward towards the open east boundary
			for y in range(64):
				for x in range(64):
					var idx = y * 64 + x
					solver.bed[idx] = float(64 - x) * 0.1 # High in west, low at east boundary
					if x >= 55 and x <= 62: # Water near eastern exit
						solver.h[idx] = 1.5
					else:
						solver.h[idx] = 0.0
			solver._update_derived_fields()
			solver.initial_volume = solver.compute_total_water_volume()
			
		# Step simulation for 30 steps
		for step in range(30):
			solver.step(0.1)
			
		var res = solver.compute_mass_balance_error()
		print("[%s]" % sc["name"])
		print("  - Initial Volume:     %12.4f m³" % res.initial_volume)
		print("  - Final Volume:       %12.4f m³" % res.current_volume)
		print("  - Cumulative Rain:    %12.4f m³" % solver.cumulative_rain_vol)
		print("  - Cumulative Infil:   %12.4f m³" % solver.cumulative_infil_vol)
		print("  - Cumulative Evap:    %12.4f m³" % solver.cumulative_evap_vol)
		print("  - Cumulative Inflow:  %12.4f m³" % res.cumulative_inflow)
		print("  - Cumulative Outflow: %12.4f m³" % res.cumulative_outflow)
		print("  - Expected Volume:    %12.4f m³" % res.expected_volume)
		print("  - Absolute Error:     " + str(res.absolute_error_m3) + " m³")
		print("  - Relative Error:     " + str(res.relative_error) + (" (%.6f %%)" % (res.relative_error * 100.0)))
		var pass_status = "PASS" if res.relative_error < 1e-3 else "FAIL"
		print("  - Status:             %s\n" % pass_status)

# =============================================================================
# 3. GPU COMPUTE VERIFICATION
# =============================================================================

func run_gpu_audit() -> void:
	print("--- 3. GPU COMPUTE SHADER AUDIT ---")
	
	var gpu = ShallowWaterComputeGPU.new(Vector2i(128, 128))
	print("  - GPU Initialized:      %s" % str(gpu.is_gpu_available))
	print("  - RenderingDevice:      %s" % ("Active" if gpu.rd != null else "Null"))
	if gpu.rd:
		print("  - Device Name:          %s" % gpu.rd.get_device_name())
	else:
		print("  - Execution Mode:       Headless CPU Reference Fallback")
		
	if not gpu.is_gpu_available:
		print("  [NOTE] GPU compute is unavailable in headless execution mode (as expected for headless dummy driver).")
		print("         When executed with '--rendering-driver vulkan', the GPU pipeline dispatches on the active hardware GPU.\n")
		return
		
	# If GPU is available (e.g. running with Vulkan driver)
	var solver_cpu = ShallowWaterSolver2D.new(Vector2i(128, 128), Vector2(500.0, 500.0))
	for y in range(128):
		for x in range(128):
			var idx = y * 128 + x
			solver_cpu.bed[idx] = float(x) * 0.1
			solver_cpu.h[idx] = 2.0 if x < 64 else 0.0
	solver_cpu._update_derived_fields()
	
	var parity = gpu.validate_parity_with_cpu(solver_cpu, 0.05, 1e-3)
	print("  - Parity Executed:      %s" % str(parity.tested))
	print("  - Within Tolerance:     %s" % str(parity.within_tolerance))
	print("  - Max Depth Diff:       " + str(parity.max_diff_h) + " m")
	print("  - Max Qx Diff:          " + str(parity.max_diff_qx) + " m²/s")
	print("  - Max Qz Diff:          " + str(parity.max_diff_qz) + " m²/s")
	
	# GPU Performance Benchmark at 128x128 and 256x256
	print("\n  [GPU COMPUTE BENCHMARKS (Vulkan - NVIDIA RTX 3050)]")
	for b_res in [Vector2i(128, 128), Vector2i(256, 256)]:
		var b_gpu = ShallowWaterComputeGPU.new(b_res)
		var b_solver = ShallowWaterSolver2D.new(b_res)
		b_solver.h.fill(1.5)
		b_solver._update_derived_fields()
		
		# Warmup
		b_gpu.step_gpu(b_solver, 0.05)
		
		var t_start = Time.get_ticks_usec()
		var n_steps = 20
		for step in range(n_steps):
			b_gpu.step_gpu(b_solver, 0.05)
		var t_total = float(Time.get_ticks_usec() - t_start) / 1000.0
		var avg_step = t_total / float(n_steps)
		print("  - GPU %d × %d (%d cells): %6.2f ms/step (%5.1f steps/sec)" % [
			b_res.x, b_res.y, b_res.x * b_res.y, avg_step, 1000.0 / avg_step
		])
	print("")

# =============================================================================
# 4. SYSTEM INTEGRATION & MAIN.TSCN AUDIT
# =============================================================================

func run_integration_audit() -> void:
	print("--- 4. SYSTEM INTEGRATION & MAIN.TSCN AUDIT ---")
	
	# 4.1 Check FluidSimulationManager coupling with WorldState, LakeBasinSolver, FeatureRegistry
	var ws = WorldState.new(Vector2(1000.0, 1000.0), Vector2i(128, 128), Vector2(-500.0, -500.0), 42)
	var terr = TerrainEngine.new(ws.world_size, ws.grid_resolution, ws.world_origin)
	terr.generate(42, {"base_elevation": 15.0})
	var hyd = HydrologyEngine.new(terr)
	hyd.resolve_hydrology()
	ws.initialize_from_simulation(terr, hyd)
	ws.recompute_lakes({"min_basin_area_cells": 5, "min_basin_depth_m": 0.2})
	
	# Add a registered river
	var r_pts = PackedVector2Array([Vector2(-100.0, -100.0), Vector2(0.0, 0.0), Vector2(100.0, 100.0)])
	ws.feature_registry.register_feature({
		"type": "river",
		"parameters": {"points": r_pts, "spring_discharge": 25.0}
	})
	
	var fluid_mgr = FluidSimulationManager.new()
	fluid_mgr.initialize_from_world_state(ws, Vector2i(128, 128))
	
	# Verify bed elevation received
	var bed_diff = 0.0
	for i in range(128 * 128):
		var wpos = fluid_mgr.grid_to_world(i % 128, i / 128)
		var h_ws = ws.get_elevation_at(wpos.x, wpos.y)
		bed_diff = maxf(bed_diff, absf(fluid_mgr.solver.bed[i] - h_ws))
	print("  - Bed Elevation Sync Max Error:       " + str(bed_diff) + " m")
	
	# Verify river spring entry cell
	var pt_srcs = fluid_mgr.solver.point_sources
	var river_inflow_found = false
	for s in pt_srcs:
		if s.discharge == 25.0:
			river_inflow_found = true
			var expected_g = ws.world_to_grid(-100.0, -100.0)
			print("  - River Spring Source Cell:           (%d, %d) [Expected: (%d, %d)]" % [s.gx, s.gy, expected_g.x, expected_g.y])
	print("  - River Spring Inflow Registered:     %s" % ("YES" if river_inflow_found else "NO"))
	
	# Verify dirty-region elevation edit invalidation
	var old_bed_center = fluid_mgr.solver.bed[64 * 128 + 64]
	var dirty_rect = Rect2(Vector2(-50.0, -50.0), Vector2(100.0, 100.0))
	ws.update_elevation_region(dirty_rect, func(wx, wz, old_h): return old_h + 10.0)
	fluid_mgr.apply_localized_terrain_update(dirty_rect)
	var new_bed_center = fluid_mgr.solver.bed[64 * 128 + 64]
	print("  - Dirty Region Update Applied:        %s (Old: %.2fm -> New: %.2fm)" % [
		"YES" if (new_bed_center > old_bed_center + 5.0) else "NO", old_bed_center, new_bed_center
	])
	
	# Verify WaterSurfaceRenderer texture updates
	var renderer = WaterSurfaceRenderer.new()
	renderer.fluid_manager = fluid_mgr
	renderer._setup_mesh_and_material()
	fluid_mgr.solver.h[64 * 128 + 64] = 5.0
	fluid_mgr.solver.u[64 * 128 + 64] = 2.0
	renderer.update_simulation_textures()
	var depth_tex_val = renderer.depth_image.get_pixel(64, 64).r
	print("  - WaterSurfaceRenderer Texture Sync:  %s (Pixel Depth: %.2fm)" % [
		"YES" if absf(depth_tex_val - 5.0) < 0.01 else "NO", depth_tex_val
	])
	
	# 4.2 Check Main.tscn integration status
	print("\n  [AUDIT: MAIN.TSCN GAME SCENE CHECK]")
	var main_scene: PackedScene = load("res://Main.tscn")
	var main_node = main_scene.instantiate()
	var has_fluid_mgr = main_node.find_child("FluidSimulationManager", true, false) != null
	var has_water_renderer = main_node.find_child("WaterSurfaceRenderer", true, false) != null
	var chunk_mgr = main_node.find_child("ChunkManager", true, false)
	
	print("  - Main.tscn contains ChunkManager:           %s" % ("YES" if chunk_mgr != null else "NO"))
	print("  - Main.tscn contains FluidSimulationManager:  %s" % ("YES" if has_fluid_mgr else "NO"))
	print("  - Main.tscn contains WaterSurfaceRenderer:   %s" % ("YES" if has_water_renderer else "NO"))
	
	if not has_fluid_mgr or not has_water_renderer:
		print("  - Main.tscn Integration Finding:             INCOMPLETE / UNWIRED IN MAIN GAME SCENE.")
		print("    While FluidSimulationManager and WaterSurfaceRenderer are fully implemented and")
		print("    verified in standalone scenes and test suites, they are NOT instantiated in Main.tscn.")
	main_node.queue_free()
	print("")

# =============================================================================
# 5. PERFORMANCE INVESTIGATION & CPU PROFILING
# =============================================================================

func run_cpu_profiling_and_benchmarks() -> void:
	print("--- 5. PERFORMANCE INVESTIGATION & DETAILED CPU PROFILING ---")
	
	var resolutions = [
		Vector2i(128, 128),
		Vector2i(256, 256),
		Vector2i(512, 512)
	]
	
	for res in resolutions:
		var total_cells = res.x * res.y
		var solver = ShallowWaterSolver2D.new(res, Vector2(1000.0, 1000.0))
		solver.manning_n = 0.035
		
		# Sloped terrain with river channel
		for y in range(res.y):
			for x in range(res.x):
				var idx = y * res.x + x
				solver.bed[idx] = float(res.x - x) * 0.1
				if abs(y - res.y / 2) < 4:
					solver.h[idx] = 2.0
		solver._update_derived_fields()
		
		# Profile individual components over 5 steps
		var t_flux_x = 0
		var t_flux_z = 0
		var t_integrate = 0
		var t_friction = 0
		var t_derived = 0
		var t_cfl = 0
		var step_latencies: Array[float] = []
		
		var num_steps = 10 if res.x <= 256 else 3 # Limit 512 to 3 steps due to CPU execution time
		
		for s in range(num_steps):
			var step_start = Time.get_ticks_usec()
			
			var t0 = Time.get_ticks_usec()
			solver._compute_x_fluxes()
			var t1 = Time.get_ticks_usec()
			solver._compute_z_fluxes()
			var t2 = Time.get_ticks_usec()
			solver._integrate_state(0.05)
			var t3 = Time.get_ticks_usec()
			solver._apply_bottom_friction(0.05)
			var t4 = Time.get_ticks_usec()
			solver._update_derived_fields()
			var t5 = Time.get_ticks_usec()
			solver.compute_cfl_timestep()
			var t6 = Time.get_ticks_usec()
			
			t_flux_x += (t1 - t0)
			t_flux_z += (t2 - t1)
			t_integrate += (t3 - t2)
			t_friction += (t4 - t3)
			t_derived += (t5 - t4)
			t_cfl += (t6 - t5)
			
			var total_step_ms = float(Time.get_ticks_usec() - step_start) / 1000.0
			step_latencies.append(total_step_ms)
			
		var min_lat = step_latencies[0]
		var max_lat = step_latencies[0]
		var sum_lat = 0.0
		for lat in step_latencies:
			if lat < min_lat: min_lat = lat
			if lat > max_lat: max_lat = lat
			sum_lat += lat
		var avg_lat = sum_lat / float(step_latencies.size())
		var steps_per_sec = 1000.0 / avg_lat
		
		var total_prof = float(t_flux_x + t_flux_z + t_integrate + t_friction + t_derived + t_cfl)
		
		print("[GRID %d × %d (%d cells)]" % [res.x, res.y, total_cells])
		print("  - Avg Step Latency:     %8.2f ms" % avg_lat)
		print("  - Min Step Latency:     %8.2f ms" % min_lat)
		print("  - Max Step Latency:     %8.2f ms" % max_lat)
		print("  - Update Rate:          %8.2f steps/sec" % steps_per_sec)
		print("  - Component Breakdown:")
		print("    * X-Fluxes (HLL+Audusse): %6.2f ms (%4.1f %%)" % [float(t_flux_x) / (num_steps * 1000.0), (float(t_flux_x) / total_prof) * 100.0])
		print("    * Z-Fluxes (HLL+Audusse): %6.2f ms (%4.1f %%)" % [float(t_flux_z) / (num_steps * 1000.0), (float(t_flux_z) / total_prof) * 100.0])
		print("    * State Integration:      %6.2f ms (%4.1f %%)" % [float(t_integrate) / (num_steps * 1000.0), (float(t_integrate) / total_prof) * 100.0])
		print("    * Bottom Friction:        %6.2f ms (%4.1f %%)" % [float(t_friction) / (num_steps * 1000.0), (float(t_friction) / total_prof) * 100.0])
		print("    * Derived Fields Update:  %6.2f ms (%4.1f %%)" % [float(t_derived) / (num_steps * 1000.0), (float(t_derived) / total_prof) * 100.0])
		print("    * CFL Timestep Eval:      %6.2f ms (%4.1f %%)" % [float(t_cfl) / (num_steps * 1000.0), (float(t_cfl) / total_prof) * 100.0])
		print("  - Real-Time Capability: %s (At dt=0.05s, requires <= 50ms for real-time)\n" % (
			"YES (Real-Time)" if avg_lat <= 50.0 else "NO (Slower than real-time on CPU)"
		))
