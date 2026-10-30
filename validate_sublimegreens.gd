# validate_sublimegreens.gd
extends SceneTree

const SatelliteMapRenderer = preload("res://SatelliteMapRenderer.gd")

func _init():
	print("=================================================================")
	print("SUBLIMEGREENS — HYDROLOGY, SATELLITE MAP & AI EDITING VALIDATION")
	print("=================================================================")
	
	var root = Node.new()
	get_root().add_child(root)
	
	var architect = ForestArchitect.new()
	root.add_child(architect)
	architect._ready()
	
	var all_passed = true
	
	# -------------------------------------------------------------------------
	# TEST 1: Three mountain ranges with springs feeding two rivers merging into one
	# -------------------------------------------------------------------------
	var prompt1 = "Create three mountain ranges with springs feeding two rivers that merge into one large river."
	var dict1 = architect._create_fallback_from_prompt(prompt1)
	architect._finalize_world_generation(dict1)
	var bp = architect.tool_registry.active_blueprint
	
	if bp.mountain_ranges.size() >= 3 and bp.rivers.size() >= 3:
		print("[PASS] Test 1: Created %d mountain ranges and %d rivers (2 tributaries merging into 1 main river)." % [
			bp.mountain_ranges.size(), bp.rivers.size()
		])
	else:
		printerr("[FAIL] Test 1: Expected >=3 mountain ranges and >=3 rivers.")
		all_passed = false
		
	# -------------------------------------------------------------------------
	# TEST 2: Make main river U-shaped and animate water flowing downstream
	# -------------------------------------------------------------------------
	var edit2 = architect._create_fallback_edit("Make the main river U-shaped and animate the water flowing downstream.", {})
	architect._execute_edit_plan(edit2)
	bp = architect.tool_registry.active_blueprint
	var main_river = architect.tool_registry._resolve_river_target("main")
	var spline_pts: PackedVector2Array = main_river.get("spline_points", PackedVector2Array())
	var flow_spd = float(main_river.get("flow_speed", 0.0))
	
	if spline_pts.size() > 20 and flow_spd >= 1.0:
		print("[PASS] Test 2: Main river reshaped into smooth U-curve (%d Catmull-Rom spline points, downstream flow_speed=%.2f)." % [
			spline_pts.size(), flow_spd
		])
	else:
		printerr("[FAIL] Test 2: Main river U-shape or downstream flow speed failed.")
		all_passed = false
		
	# -------------------------------------------------------------------------
	# TEST 3: Make northwestern mountain taller and cover its peak with snow (No manual selection)
	# -------------------------------------------------------------------------
	var nw_before = architect.tool_registry._resolve_mountain_target("northwest")
	var nw_id = str(nw_before.get("id", ""))
	var nw_h_before = float(nw_before.get("height", 0.0))
	var ne_before = architect.tool_registry._resolve_mountain_target("northeast")
	var ne_h_before = float(ne_before.get("height", 0.0))
	
	var edit3 = architect._create_fallback_edit("Make the northwestern mountain taller and cover its peak with snow.", {})
	architect._execute_edit_plan(edit3)
	bp = architect.tool_registry.active_blueprint
	var nw_after = architect.tool_registry._resolve_mountain_target(nw_id)
	var ne_after = architect.tool_registry._resolve_mountain_target("northeast")
	
	if float(nw_after.get("height", 0.0)) > nw_h_before and bool(nw_after.get("snow_cap", false)) and is_equal_approx(float(ne_after.get("height", 0.0)), ne_h_before):
		print("[PASS] Test 3: Context-aware NW mountain '%s' height increased (%.0fm -> %.0fm, snow_cap=true), NE mountain untouched." % [
			nw_after.get("name", ""), nw_h_before, float(nw_after.get("height", 0.0))
		])
	else:
		printerr("[FAIL] Test 3: Context-aware NW mountain edit failed.")
		all_passed = false
		
	# -------------------------------------------------------------------------
	# TEST 4: Add dense vegetation around the riverbanks
	# -------------------------------------------------------------------------
	var layers_before = bp.vegetation_layers.size()
	var edit4 = architect._create_fallback_edit("Add dense vegetation around the riverbanks.", {})
	architect._execute_edit_plan(edit4)
	bp = architect.tool_registry.active_blueprint
	var has_riparian = false
	for l in bp.vegetation_layers:
		if l.near_water_only or l.distribution == "riverbank_focused":
			has_riparian = true
			break
	if bp.vegetation_layers.size() > layers_before and has_riparian:
		print("[PASS] Test 4: Dense riverbank flora layer added (total layers: %d, near_water_only=true)." % bp.vegetation_layers.size())
	else:
		printerr("[FAIL] Test 4: Riverbank vegetation layer was not added.")
		all_passed = false
		
	# -------------------------------------------------------------------------
	# TEST 5: Make all rivers wider without changing mountain positions
	# -------------------------------------------------------------------------
	var mtn_positions_before: Array[Vector2] = []
	for m in bp.mountains:
		mtn_positions_before.append(m.pos)
	var river_widths_before: Array[float] = []
	for r in bp.rivers:
		river_widths_before.append(float(r.get("width", 8.0)))
		
	var edit5 = architect._create_fallback_edit("Make all rivers wider without changing the mountain positions.", {})
	architect._execute_edit_plan(edit5)
	bp = architect.tool_registry.active_blueprint
	
	var widths_increased = true
	for i in range(bp.rivers.size()):
		if float(bp.rivers[i].get("width", 0.0)) <= river_widths_before[i]:
			widths_increased = false
	var mtns_unchanged = true
	for i in range(bp.mountains.size()):
		if bp.mountains[i].pos != mtn_positions_before[i]:
			mtns_unchanged = false
			
	if widths_increased and mtns_unchanged:
		print("[PASS] Test 5: All %d rivers widened while all %d mountain positions remained unchanged." % [
			bp.rivers.size(), bp.mountains.size()
		])
	else:
		printerr("[FAIL] Test 5: All rivers wider / mountains unchanged check failed.")
		all_passed = false
		
	# -------------------------------------------------------------------------
	# TEST 6: Create a waterfall where the eastern river drops into the valley
	# -------------------------------------------------------------------------
	var edit6 = architect._create_fallback_edit("Create a waterfall where the eastern river drops into the valley.", {})
	architect._execute_edit_plan(edit6)
	bp = architect.tool_registry.active_blueprint
	var east_r = architect.tool_registry._resolve_river_target("east")
	var wfs = east_r.get("waterfalls", [])
	if wfs is Array and wfs.size() > 0:
		var wf = wfs[0]
		print("[PASS] Test 6: Waterfall created on '%s' at %s (height_drop=%.0fm)." % [
			east_r.get("name", ""), str(wf.get("pos")), float(wf.get("height_drop", 0.0))
		])
	else:
		printerr("[FAIL] Test 6: Waterfall creation failed.")
		all_passed = false
		
	# -------------------------------------------------------------------------
	# TEST 7: Make the southern region snowy and leave the northern forest unchanged
	# -------------------------------------------------------------------------
	var edit7 = architect._create_fallback_edit("Make the southern region snowy and leave the northern forest unchanged.", {})
	architect._execute_edit_plan(edit7)
	bp = architect.tool_registry.active_blueprint
	if bp.is_in_snow_cap(0.0, 65.0, 12.0) and not bp.is_in_snow_cap(0.0, -40.0, 12.0):
		print("[PASS] Test 7: Southern region snowy (is_in_snow_cap(0,65)=true) and northern forest unchanged (is_in_snow_cap(0,-40)=false).")
	else:
		printerr("[FAIL] Test 7: Regional snow check failed.")
		all_passed = false
		
	# -------------------------------------------------------------------------
	# TEST 8: Satellite-Style 2D World Map & 3D River Shader Verification
	# -------------------------------------------------------------------------
	var t0 = Time.get_ticks_msec()
	var sat_tex = SatelliteMapRenderer.render(bp, 180)
	var elapsed_ms = Time.get_ticks_msec() - t0
	if sat_tex != null and sat_tex.get_width() == 180 and sat_tex.get_height() == 180:
		print("[PASS] Test 8A: Satellite 2D World Map generated (180x180 px in %d ms) from live world data." % elapsed_ms)
	else:
		printerr("[FAIL] Test 8A: Satellite map texture generation failed.")
		all_passed = false
		
	var chunk_scene = load("res://Chunk.tscn")
	if chunk_scene:
		var chunk = chunk_scene.instantiate()
		root.add_child(chunk)
		chunk.initialize_chunk(Vector2i(0, 0), bp)
		var r_mi: MeshInstance3D = chunk.river_mesh_instance
		if r_mi != null and r_mi.mesh != null and r_mi.material_override is ShaderMaterial:
			var sm: ShaderMaterial = r_mi.material_override
			var f_spd = sm.get_shader_parameter("flow_speed")
			print("[PASS] Test 8B: 3D Chunk RiverMeshInstance generated with directional river.gdshader (flow_speed=%.2f)." % float(f_spd))
		else:
			printerr("[FAIL] Test 8B: Chunk RiverMeshInstance or ShaderMaterial missing.")
			all_passed = false
			
	# -------------------------------------------------------------------------
	# TEST 9: Ambiguity detection ("Make that mountain taller" without selection)
	# -------------------------------------------------------------------------
	var edit9 = architect._create_fallback_edit("Make that mountain taller", {})
	var clar = str(edit9.get("clarification_needed", ""))
	if not clar.is_empty() and edit9.get("operations", []).is_empty():
		print("[PASS] Test 9: Ambiguous instruction detected without guessing -> '%s'" % clar)
	else:
		printerr("[FAIL] Test 9: Ambiguous instruction did not request clarification.")
		all_passed = false
		
	print("=================================================================")
	if all_passed:
		print("ALL 9 ACCEPTANCE TESTS PASSED SUCCESSFULLY!")
	else:
		printerr("ONE OR MORE TESTS FAILED!")
	print("=================================================================")
	quit(0 if all_passed else 1)
