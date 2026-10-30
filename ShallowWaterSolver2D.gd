# ShallowWaterSolver2D.gd
# Physically-based two-dimensional depth-averaged Shallow Water Equation (SWE) solver.
# Uses conservative finite-volume discretization with the HLL approximate Riemann solver,
# Audusse well-balanced hydrostatic reconstruction, semi-implicit Manning bed friction,
# and wetting/drying tracking for SublimeGreens Milestone 5.
class_name ShallowWaterSolver2D
extends RefCounted

enum BoundaryType {
	WALL,      # Closed reflective slip wall (zero normal flux)
	OUTFLOW    # Open transmissive boundary (free drainage)
}

# --- Physical Constants & Parameters ---
var gravity: float = 9.81
var manning_n: float = 0.035        # Roughness coefficient (natural streams/vegetation)
var h_dry: float = 1e-4             # Wetting/drying threshold (0.1 mm)
var cfl: float = 0.45               # Courant-Friedrichs-Lewy stability number
var dt_min: float = 0.0005          # Minimum allowable timestep (s)
var dt_max: float = 0.15            # Maximum allowable timestep (s)

# --- Grid Dimensions & Spatial Metrics ---
var grid_res: Vector2i = Vector2i(128, 128)
var world_size: Vector2 = Vector2(1000.0, 1000.0)
var world_origin: Vector2 = Vector2(-500.0, -500.0)
var dx: float = 1.0
var dz: float = 1.0
var cell_area: float = 1.0
var total_cells: int = 0

# --- Authoritative Fluid State Buffers ---
var h: PackedFloat32Array = PackedFloat32Array()       # Water depth (m)
var qx: PackedFloat32Array = PackedFloat32Array()      # X-discharge (hu, m²/s)
var qz: PackedFloat32Array = PackedFloat32Array()      # Z-discharge (hv, m²/s)
var bed: PackedFloat32Array = PackedFloat32Array()     # Terrain bed elevation (m)

# Derived fields
var u: PackedFloat32Array = PackedFloat32Array()       # Depth-averaged X-velocity (m/s)
var v: PackedFloat32Array = PackedFloat32Array()       # Depth-averaged Z-velocity (m/s)
var eta: PackedFloat32Array = PackedFloat32Array()     # Free water surface elevation (bed + h, m)

# Intermediate flux buffers for finite-volume update
var _flux_h_x: PackedFloat32Array = PackedFloat32Array()
var _flux_qx_x: PackedFloat32Array = PackedFloat32Array()
var _flux_qz_x: PackedFloat32Array = PackedFloat32Array()

var _flux_h_z: PackedFloat32Array = PackedFloat32Array()
var _flux_qx_z: PackedFloat32Array = PackedFloat32Array()
var _flux_qz_z: PackedFloat32Array = PackedFloat32Array()

var _source_bed_x: PackedFloat32Array = PackedFloat32Array()
var _source_bed_z: PackedFloat32Array = PackedFloat32Array()

# --- Boundary Conditions ---
var boundary_north: BoundaryType = BoundaryType.OUTFLOW
var boundary_south: BoundaryType = BoundaryType.OUTFLOW
var boundary_west: BoundaryType = BoundaryType.OUTFLOW
var boundary_east: BoundaryType = BoundaryType.OUTFLOW

# --- Sources, Sinks & Weather ---
var rain_rate: float = 0.0           # Uniform rainfall (m/s)
var infiltration_rate: float = 0.0   # Uniform soil infiltration (m/s)
var evaporation_rate: float = 0.0    # Atmospheric evaporation (m/s)

# Discrete point sources (springs/tributaries): Array of { gx: int, gy: int, discharge: float }
var point_sources: Array[Dictionary] = []
# Discrete point sinks (culverts/drainage pits): Array of { gx: int, gy: int, max_rate: float }
var point_sinks: Array[Dictionary] = []

# --- Mass Conservation & Cumulative Diagnostics ---
var sim_time: float = 0.0
var step_count: int = 0
var initial_volume: float = 0.0
var cumulative_rain_vol: float = 0.0
var cumulative_infil_vol: float = 0.0
var cumulative_evap_vol: float = 0.0
var cumulative_inflow_vol: float = 0.0
var cumulative_outflow_vol: float = 0.0

func _init(p_res: Vector2i = Vector2i(128, 128), p_size: Vector2 = Vector2(1000.0, 1000.0), p_origin: Vector2 = Vector2(-500.0, -500.0)) -> void:
	initialize_grid(p_res, p_size, p_origin)

## Allocates and initializes simulation buffers for the given grid resolution.
func initialize_grid(p_res: Vector2i, p_size: Vector2, p_origin: Vector2) -> void:
	grid_res = p_res
	world_size = p_size
	world_origin = p_origin
	total_cells = grid_res.x * grid_res.y
	
	dx = world_size.x / float(max(1, grid_res.x - 1))
	dz = world_size.y / float(max(1, grid_res.y - 1))
	cell_area = dx * dz
	
	h.resize(total_cells)
	h.fill(0.0)
	
	qx.resize(total_cells)
	qx.fill(0.0)
	
	qz.resize(total_cells)
	qz.fill(0.0)
	
	bed.resize(total_cells)
	bed.fill(0.0)
	
	u.resize(total_cells)
	u.fill(0.0)
	
	v.resize(total_cells)
	v.fill(0.0)
	
	eta.resize(total_cells)
	eta.fill(0.0)
	
	# Interface flux buffers:
	# X-interfaces: (grid_res.x + 1) * grid_res.y
	var num_fx = (grid_res.x + 1) * grid_res.y
	_flux_h_x.resize(num_fx)
	_flux_qx_x.resize(num_fx)
	_flux_qz_x.resize(num_fx)
	
	# Z-interfaces: grid_res.x * (grid_res.y + 1)
	var num_fz = grid_res.x * (grid_res.y + 1)
	_flux_h_z.resize(num_fz)
	_flux_qx_z.resize(num_fz)
	_flux_qz_z.resize(num_fz)
	
	_source_bed_x.resize(total_cells)
	_source_bed_z.resize(total_cells)
	
	reset_diagnostics()

## Resets diagnostic mass tracking variables.
func reset_diagnostics() -> void:
	sim_time = 0.0
	step_count = 0
	initial_volume = compute_total_water_volume()
	cumulative_rain_vol = 0.0
	cumulative_infil_vol = 0.0
	cumulative_evap_vol = 0.0
	cumulative_inflow_vol = 0.0
	cumulative_outflow_vol = 0.0

## Sets the immobile terrain bed elevation buffer.
func set_bed_elevation(p_bed: PackedFloat32Array) -> void:
	if p_bed.size() == total_cells:
		bed = p_bed.duplicate()
	else:
		printerr("ShallowWaterSolver2D: Bed buffer size (%d) mismatch total_cells (%d)" % [p_bed.size(), total_cells])
	_update_derived_fields()

## Sets initial water depth buffer.
func set_water_depth(p_h: PackedFloat32Array) -> void:
	if p_h.size() == total_cells:
		h = p_h.duplicate()
		for i in range(total_cells):
			if h[i] < 0.0: h[i] = 0.0
	_update_derived_fields()
	initial_volume = compute_total_water_volume()

## Computes the adaptive timestep governed by the CFL condition.
func compute_cfl_timestep() -> float:
	var max_wave_speed: float = 0.0
	
	for i in range(total_cells):
		var hi = h[i]
		if hi > h_dry:
			var c = sqrt(gravity * hi)
			var spd_x = absf(u[i]) + c
			var spd_z = absf(v[i]) + c
			var max_spd = maxf(spd_x, spd_z)
			if max_spd > max_wave_speed:
				max_wave_speed = max_spd
				
	if max_wave_speed < 1e-4:
		return dt_max
		
	var min_d = minf(dx, dz)
	var dt = cfl * (min_d / max_wave_speed)
	return clampf(dt, dt_min, dt_max)

## Advances the fluid simulation by one adaptive (or explicit) timestep.
func step(dt_override: float = -1.0) -> float:
	var dt = dt_override if dt_override > 0.0 else compute_cfl_timestep()
	
	# 1. Compute conservative numerical fluxes at all cell interfaces
	_compute_x_fluxes()
	_compute_z_fluxes()
	
	# 2. Advance state variables via finite-volume integration
	_integrate_state(dt)
	
	# 3. Apply weather sources (rain, infiltration, evaporation) & point sources
	_apply_sources_and_sinks(dt)
	
	# 4. Apply semi-implicit bottom friction
	_apply_bottom_friction(dt)
	
	# 5. Enforce wetting/drying thresholds and update derived velocities
	_update_derived_fields()
	
	sim_time += dt
	step_count += 1
	return dt

# -----------------------------------------------------------------------------
# Finite Volume Numerical Fluxes (HLL Riemann Solver + Well-Balanced Hydrostatic)
# -----------------------------------------------------------------------------

## Computes numerical fluxes across X-interfaces (between cell (x, y) and (x+1, y)).
func _compute_x_fluxes() -> void:
	var w = grid_res.x
	var h_res = grid_res.y
	_source_bed_x.fill(0.0)
	
	for gy in range(h_res):
		var row_offset = gy * w
		var f_offset = gy * (w + 1)
		
		for gx in range(w + 1):
			var f_idx = f_offset + gx
			
			# Boundary interfaces
			if gx == 0:
				if boundary_west == BoundaryType.WALL:
					_flux_h_x[f_idx] = 0.0
					var h_cell = h[row_offset]
					_flux_qx_x[f_idx] = 0.5 * gravity * h_cell * h_cell
					_flux_qz_x[f_idx] = 0.0
				else: # OUTFLOW
					var h0 = h[row_offset]
					var qx0 = qx[row_offset]
					var qz0 = qz[row_offset]
					var u0 = u[row_offset]
					var flux = _physical_flux_x(h0, qx0, qz0, u0)
					_flux_h_x[f_idx] = flux.h
					_flux_qx_x[f_idx] = flux.qx
					_flux_qz_x[f_idx] = flux.qz
				continue
				
			if gx == w:
				if boundary_east == BoundaryType.WALL:
					_flux_h_x[f_idx] = 0.0
					var h_cell = h[row_offset + w - 1]
					_flux_qx_x[f_idx] = 0.5 * gravity * h_cell * h_cell
					_flux_qz_x[f_idx] = 0.0
				else: # OUTFLOW
					var h1 = h[row_offset + w - 1]
					var qx1 = qx[row_offset + w - 1]
					var qz1 = qz[row_offset + w - 1]
					var u1 = u[row_offset + w - 1]
					var flux = _physical_flux_x(h1, qx1, qz1, u1)
					_flux_h_x[f_idx] = flux.h
					_flux_qx_x[f_idx] = flux.qx
					_flux_qz_x[f_idx] = flux.qz
				continue
				
			# Interior interface between cell_L (gx - 1) and cell_R (gx)
			var idx_L = row_offset + gx - 1
			var idx_R = row_offset + gx
			
			var h_L = h[idx_L]
			var h_R = h[idx_R]
			var b_L = bed[idx_L]
			var b_R = bed[idx_R]
			
			# Audusse Hydrostatic Reconstruction: common interface bed elevation
			var b_int = maxf(b_L, b_R)
			var h_L_star = maxf(0.0, h_L + b_L - b_int)
			var h_R_star = maxf(0.0, h_R + b_R - b_int)
			
			var u_L = u[idx_L]
			var u_R = u[idx_R]
			var v_L = v[idx_L]
			var v_R = v[idx_R]
			
			var qx_L_star = h_L_star * u_L
			var qx_R_star = h_R_star * u_R
			var qz_L_star = h_L_star * v_L
			var qz_R_star = h_R_star * v_R
			
			# Evaluate HLL Riemann flux
			var hll = _hll_flux_1d(h_L_star, qx_L_star, qz_L_star, u_L, v_L,
								   h_R_star, qx_R_star, qz_R_star, u_R, v_R)
								   
			_flux_h_x[f_idx] = hll.h
			_flux_qx_x[f_idx] = hll.qx
			_flux_qz_x[f_idx] = hll.qz
			
			# Hydrostatic bed source correction to guarantee well-balancedness
			var s_L = 0.5 * gravity * (h_L_star * h_L_star - h_L * h_L)
			var s_R = 0.5 * gravity * (h_R * h_R - h_R_star * h_R_star)
			_source_bed_x[idx_L] += s_L
			_source_bed_x[idx_R] += s_R

## Computes numerical fluxes across Z-interfaces (between cell (x, y) and (x, y+1)).
func _compute_z_fluxes() -> void:
	var w = grid_res.x
	var h_res = grid_res.y
	_source_bed_z.fill(0.0)
	
	for gy in range(h_res + 1):
		var f_offset = gy * w
		
		for gx in range(w):
			var f_idx = f_offset + gx
			
			# North Boundary (gy == 0)
			if gy == 0:
				if boundary_north == BoundaryType.WALL:
					_flux_h_z[f_idx] = 0.0
					_flux_qx_z[f_idx] = 0.0
					var h_cell = h[gx]
					_flux_qz_z[f_idx] = 0.5 * gravity * h_cell * h_cell
				else: # OUTFLOW
					var h0 = h[gx]
					var qx0 = qx[gx]
					var qz0 = qz[gx]
					var v0 = v[gx]
					var flux = _physical_flux_z(h0, qx0, qz0, v0)
					_flux_h_z[f_idx] = flux.h
					_flux_qx_z[f_idx] = flux.qx
					_flux_qz_z[f_idx] = flux.qz
				continue
				
			# South Boundary (gy == h_res)
			if gy == h_res:
				if boundary_south == BoundaryType.WALL:
					_flux_h_z[f_idx] = 0.0
					_flux_qx_z[f_idx] = 0.0
					var h_cell = h[(h_res - 1) * w + gx]
					_flux_qz_z[f_idx] = 0.5 * gravity * h_cell * h_cell
				else: # OUTFLOW
					var h1 = h[(h_res - 1) * w + gx]
					var qx1 = qx[(h_res - 1) * w + gx]
					var qz1 = qz[(h_res - 1) * w + gx]
					var v1 = v[(h_res - 1) * w + gx]
					var flux = _physical_flux_z(h1, qx1, qz1, v1)
					_flux_h_z[f_idx] = flux.h
					_flux_qx_z[f_idx] = flux.qx
					_flux_qz_z[f_idx] = flux.qz
				continue
				
			# Interior interface between cell_T (gy - 1) and cell_B (gy)
			var idx_T = (gy - 1) * w + gx
			var idx_B = gy * w + gx
			
			var h_T = h[idx_T]
			var h_B = h[idx_B]
			var b_T = bed[idx_T]
			var b_B = bed[idx_B]
			
			var b_int = maxf(b_T, b_B)
			var h_T_star = maxf(0.0, h_T + b_T - b_int)
			var h_B_star = maxf(0.0, h_B + b_B - b_int)
			
			var u_T = u[idx_T]
			var u_B = u[idx_B]
			var v_T = v[idx_T]
			var v_B = v[idx_B]
			
			var qx_T_star = h_T_star * u_T
			var qx_B_star = h_B_star * u_B
			var qz_T_star = h_T_star * v_T
			var qz_B_star = h_B_star * v_B
			
			# Rotate coordinates for Z-direction: normal velocity is v, tangential is u
			var hll = _hll_flux_1d(h_T_star, qz_T_star, qx_T_star, v_T, u_T,
								   h_B_star, qz_B_star, qx_B_star, v_B, u_B)
								   
			_flux_h_z[f_idx] = hll.h
			_flux_qz_z[f_idx] = hll.qx # Normal flux is qz
			_flux_qx_z[f_idx] = hll.qz # Tangential flux is qx
			
			var s_T = 0.5 * gravity * (h_T_star * h_T_star - h_T * h_T)
			var s_B = 0.5 * gravity * (h_B * h_B - h_B_star * h_B_star)
			_source_bed_z[idx_T] += s_T
			_source_bed_z[idx_B] += s_B

## HLL Approximate Riemann Solver for a 1D interface.
func _hll_flux_1d(h_L: float, qn_L: float, qt_L: float, un_L: float, ut_L: float,
				  h_R: float, qn_R: float, qt_R: float, un_R: float, ut_R: float) -> Dictionary:
	# Both dry cells: zero flux
	if h_L <= h_dry and h_R <= h_dry:
		return {"h": 0.0, "qx": 0.0, "qz": 0.0}
		
	var c_L = sqrt(gravity * h_L) if h_L > 0.0 else 0.0
	var c_R = sqrt(gravity * h_R) if h_R > 0.0 else 0.0
	
	# Roe-averaged wave speeds
	var s_L: float
	var s_R: float
	
	if h_L <= h_dry:
		s_L = un_R - 2.0 * c_R
		s_R = un_R + c_R
	elif h_R <= h_dry:
		s_L = un_L - c_L
		s_R = un_L + 2.0 * c_L
	else:
		var sqrt_hL = sqrt(h_L)
		var sqrt_hR = sqrt(h_R)
		var u_roe = (sqrt_hL * un_L + sqrt_hR * un_R) / (sqrt_hL + sqrt_hR)
		var c_roe = sqrt(0.5 * gravity * (h_L + h_R))
		s_L = minf(un_L - c_L, u_roe - c_roe)
		s_R = maxf(un_R + c_R, u_roe + c_roe)
		
	# Physical fluxes at left and right states
	var fL_h = qn_L
	var fL_qn = qn_L * un_L + 0.5 * gravity * h_L * h_L
	var fL_qt = qn_L * ut_L
	
	var fR_h = qn_R
	var fR_qn = qn_R * un_R + 0.5 * gravity * h_R * h_R
	var fR_qt = qn_R * ut_R
	
	if s_L >= 0.0:
		return {"h": fL_h, "qx": fL_qn, "qz": fL_qt}
	elif s_R <= 0.0:
		return {"h": fR_h, "qx": fR_qn, "qz": fR_qt}
	else:
		var denom = s_R - s_L
		if absf(denom) < 1e-6:
			return {"h": 0.5 * (fL_h + fR_h), "qx": 0.5 * (fL_qn + fR_qn), "qz": 0.5 * (fL_qt + fR_qt)}
		var h_hll = (s_R * fL_h - s_L * fR_h + s_L * s_R * (h_R - h_L)) / denom
		var qn_hll = (s_R * fL_qn - s_L * fR_qn + s_L * s_R * (qn_R - qn_L)) / denom
		var qt_hll = (s_R * fL_qt - s_L * fR_qt + s_L * s_R * (qt_R - qt_L)) / denom
		return {"h": h_hll, "qx": qn_hll, "qz": qt_hll}

func _physical_flux_x(hi: float, qxi: float, qzi: float, ui: float) -> Dictionary:
	return {
		"h": qxi,
		"qx": qxi * ui + 0.5 * gravity * hi * hi,
		"qz": qzi * ui
	}

func _physical_flux_z(hi: float, qxi: float, qzi: float, vi: float) -> Dictionary:
	return {
		"h": qzi,
		"qx": qxi * vi,
		"qz": qzi * vi + 0.5 * gravity * hi * hi
	}

# -----------------------------------------------------------------------------
# Finite Volume State Integration
# -----------------------------------------------------------------------------

## Integrates flux divergence and source terms into the cell state buffers.
func _integrate_state(dt: float) -> void:
	var w = grid_res.x
	var h_res = grid_res.y
	var dtdx = dt / dx
	var dtdz = dt / dz
	
	var total_outflow_this_step = 0.0
	
	for gy in range(h_res):
		var row_offset = gy * w
		var fx_offset = gy * (w + 1)
		var fz_top = gy * w
		var fz_bot = (gy + 1) * w
		
		for gx in range(w):
			var idx = row_offset + gx
			
			# X-fluxes
			var f_x_left = fx_offset + gx
			var f_x_right = fx_offset + gx + 1
			
			var flux_diff_h_x = _flux_h_x[f_x_right] - _flux_h_x[f_x_left]
			var flux_diff_qx_x = _flux_qx_x[f_x_right] - _flux_qx_x[f_x_left]
			var flux_diff_qz_x = _flux_qz_x[f_x_right] - _flux_qz_x[f_x_left]
			
			# Z-fluxes
			var f_z_top_idx = fz_top + gx
			var f_z_bot_idx = fz_bot + gx
			
			var flux_diff_h_z = _flux_h_z[f_z_bot_idx] - _flux_h_z[f_z_top_idx]
			var flux_diff_qx_z = _flux_qx_z[f_z_bot_idx] - _flux_qx_z[f_z_top_idx]
			var flux_diff_qz_z = _flux_qz_z[f_z_bot_idx] - _flux_qz_z[f_z_top_idx]
			
			# Track outflow volume along open boundary edges
			if gx == 0 and boundary_west == BoundaryType.OUTFLOW and _flux_h_x[f_x_left] < 0.0:
				total_outflow_this_step += absf(_flux_h_x[f_x_left]) * dz * dt
			if gx == w - 1 and boundary_east == BoundaryType.OUTFLOW and _flux_h_x[f_x_right] > 0.0:
				total_outflow_this_step += _flux_h_x[f_x_right] * dz * dt
			if gy == 0 and boundary_north == BoundaryType.OUTFLOW and _flux_h_z[f_z_top_idx] < 0.0:
				total_outflow_this_step += absf(_flux_h_z[f_z_top_idx]) * dx * dt
			if gy == h_res - 1 and boundary_south == BoundaryType.OUTFLOW and _flux_h_z[f_z_bot_idx] > 0.0:
				total_outflow_this_step += _flux_h_z[f_z_bot_idx] * dx * dt
				
			# 1. Update depth h
			var new_h = h[idx] - dtdx * flux_diff_h_x - dtdz * flux_diff_h_z
			if new_h < 0.0: new_h = 0.0 # Positivity enforcement
			h[idx] = new_h
			
			# 2. Update discharge qx & qz with flux divergence and bed source terms
			if new_h > h_dry:
				var new_qx = qx[idx] - dtdx * (flux_diff_qx_x - _source_bed_x[idx]) - dtdz * flux_diff_qx_z
				var new_qz = qz[idx] - dtdx * flux_diff_qz_x - dtdz * (flux_diff_qz_z - _source_bed_z[idx])
				qx[idx] = new_qx
				qz[idx] = new_qz
			else:
				qx[idx] = 0.0
				qz[idx] = 0.0
				
	cumulative_outflow_vol += total_outflow_this_step

# -----------------------------------------------------------------------------
# Weather & Point Source Management
# -----------------------------------------------------------------------------

func _apply_sources_and_sinks(dt: float) -> void:
	# 1. Uniform Rainfall
	if rain_rate > 0.0:
		var d_rain = rain_rate * dt
		var added_vol = 0.0
		for i in range(total_cells):
			h[i] += d_rain
			added_vol += d_rain * cell_area
		cumulative_rain_vol += added_vol
		
	# 2. Uniform Soil Infiltration
	if infiltration_rate > 0.0:
		var d_infil = infiltration_rate * dt
		var infil_vol = 0.0
		for i in range(total_cells):
			if h[i] > 0.0:
				var actual = minf(h[i], d_infil)
				h[i] -= actual
				infil_vol += actual * cell_area
		cumulative_infil_vol += infil_vol
		
	# 3. Uniform Evaporation
	if evaporation_rate > 0.0:
		var d_evap = evaporation_rate * dt
		var evap_vol = 0.0
		for i in range(total_cells):
			if h[i] > 0.0:
				var actual = minf(h[i], d_evap)
				h[i] -= actual
				evap_vol += actual * cell_area
		cumulative_evap_vol += evap_vol
		
	# 4. Discrete Point Inflow Sources (River springs / tributaries)
	for src in point_sources:
		var gx = int(src.get("gx", 0))
		var gy = int(src.get("gy", 0))
		var q_in = float(src.get("discharge", 0.0)) # m³/s
		if gx >= 0 and gx < grid_res.x and gy >= 0 and gy < grid_res.y:
			var idx = gy * grid_res.x + gx
			var dh = (q_in * dt) / cell_area
			h[idx] += dh
			cumulative_inflow_vol += q_in * dt
			
	# 5. Discrete Point Sinks (Culverts / Outlets)
	for snk in point_sinks:
		var gx = int(snk.get("gx", 0))
		var gy = int(snk.get("gy", 0))
		var max_rate = float(snk.get("max_rate", 10.0)) # m³/s
		if gx >= 0 and gx < grid_res.x and gy >= 0 and gy < grid_res.y:
			var idx = gy * grid_res.x + gx
			var cur_vol = h[idx] * cell_area
			var drain_vol = minf(cur_vol, max_rate * dt)
			h[idx] -= drain_vol / cell_area
			cumulative_outflow_vol += drain_vol

# -----------------------------------------------------------------------------
# Semi-Implicit Manning Bed Friction
# -----------------------------------------------------------------------------

## Applies semi-implicit quadratic Manning friction dampening to discharges.
## Semi-implicit formulation prevents numerical flow reversal or stiffness when h -> 0.
func _apply_bottom_friction(dt: float) -> void:
	if manning_n <= 0.0:
		return
		
	var gn2 = gravity * manning_n * manning_n
	
	for i in range(total_cells):
		var hi = h[i]
		if hi > h_dry:
			var u_val = qx[i] / hi
			var v_val = qz[i] / hi
			var spd = sqrt(u_val * u_val + v_val * v_val)
			if spd > 1e-5:
				var h_pow = pow(hi, 4.0 / 3.0)
				var cf = (gn2 * spd) / maxf(1e-4, h_pow)
				var denom = 1.0 + dt * cf
				qx[i] /= denom
				qz[i] /= denom
		else:
			qx[i] = 0.0
			qz[i] = 0.0

# -----------------------------------------------------------------------------
# Derived Fields & Diagnostics
# -----------------------------------------------------------------------------

func _update_derived_fields() -> void:
	for i in range(total_cells):
		var hi = h[i]
		if hi > h_dry:
			u[i] = qx[i] / hi
			v[i] = qz[i] / hi
		else:
			u[i] = 0.0
			v[i] = 0.0
			qx[i] = 0.0
			qz[i] = 0.0
		eta[i] = bed[i] + hi

## Computes total integrated stored water volume in m³.
func compute_total_water_volume() -> float:
	var total_vol: float = 0.0
	for i in range(total_cells):
		total_vol += h[i] * cell_area
	return total_vol

## Computes instantaneous mass conservation error:
## Error = V(t) - [ V(0) + Cumulative_In - Cumulative_Out + Rain - Infil - Evap ]
func compute_mass_balance_error() -> Dictionary:
	var current_vol = compute_total_water_volume()
	var expected_vol = initial_volume + cumulative_inflow_vol - cumulative_outflow_vol + cumulative_rain_vol - cumulative_infil_vol - cumulative_evap_vol
	var abs_error = absf(current_vol - expected_vol)
	var denom = maxf(1.0, maxf(current_vol, expected_vol))
	var rel_error = abs_error / denom
	
	return {
		"current_volume": current_vol,
		"expected_volume": expected_vol,
		"absolute_error_m3": abs_error,
		"relative_error": rel_error,
		"initial_volume": initial_volume,
		"cumulative_inflow": cumulative_inflow_vol,
		"cumulative_outflow": cumulative_outflow_vol
	}

## Returns maximum velocity magnitude across the grid.
func get_max_velocity() -> float:
	var max_v = 0.0
	for i in range(total_cells):
		if h[i] > h_dry:
			var spd = sqrt(u[i] * u[i] + v[i] * v[i])
			if spd > max_v: max_v = spd
	return max_v

## Returns maximum water depth across the grid.
func get_max_depth() -> float:
	var max_h = 0.0
	for i in range(total_cells):
		if h[i] > max_h: max_h = h[i]
	return max_h

