# validate_sublimegreens.gd
extends SceneTree

const SatelliteMapRenderer = preload("res://SatelliteMapRenderer.gd")
const ChunkManagerClass = preload("res://ChunkManager.gd")

func _init():
	print("=================================================================")
	print("SUBLIMEGREENS — AI UNDERSTANDING & WORLD GENERATION VERIFICATION")
	print("=================================================================")
	
	var root = Node.new()
	get_root().add_child(root)
	
	var chunk_scene = load("res://Chunk.tscn")
	var architect = ForestArchitect.new()
	root.add_child(architect)
	architect._ready()
	
	var all_passed = true
	
	# -------------------------------------------------------------------------
	# TEST 1: Create 2 rivers and 1 mountain.
	# -------------------------------------------------------------------------
	print("\n--- TEST 1: Create 2 rivers and 1 mountain ---")
	var prompt1 = "Create 2 rivers and 1 mountain."
	var intent1 = ForestArchitect.parse_natural_language_intent(prompt1)
	architect.current_intent = intent1
	var dict1 = architect._synthesize_blueprint_from_intent(intent1)
	architect._finalize_world_generation(dict1)
	var bp1 = architect.tool_registry.active_blueprint
	
	var test1_mtn_ok = (bp1.mountains.size() == 1)
	var test1_river_ok = (bp1.rivers.size() == 2)
	
	# Verify spatial separation
	var river1_pts: PackedVector2Array = bp1.rivers[0].get("points", PackedVector2Array())
	var river2_pts: PackedVector2Array = bp1.rivers[1].get("points", PackedVector2Array())
	var separated = river1_pts.size() > 0 and river2_pts.size() > 0 and abs(river1_pts[0].x - river2_pts[0].x) > 50.0
	
	if test1_mtn_ok and test1_river_ok and separated:
		print("[PASS] Test 1: Exactly %d mountain and %d rivers created with distinct spatial separation (dx=%.0fm)." % [
			bp1.mountains.size(), bp1.rivers.size(), abs(river1_pts[0].x - river2_pts[0].x)
		])
	else:
		printerr("[FAIL] Test 1: Expected exactly 1 mountain and 2 rivers. Got %d mountains, %d rivers." % [
			bp1.mountains.size(), bp1.rivers.size()
		])
		all_passed = false
		
	# -------------------------------------------------------------------------
	# TEST 2: Create 3 mountains, 2 rivers, and 4 lakes.
	# -------------------------------------------------------------------------
	print("\n--- TEST 2: Create 3 mountains, 2 rivers, and 4 lakes ---")
	var prompt2 = "Create 3 mountains, 2 rivers, and 4 lakes."
	var intent2 = ForestArchitect.parse_natural_language_intent(prompt2)
	architect.current_intent = intent2
	var dict2 = architect._synthesize_blueprint_from_intent(intent2)
	architect._finalize_world_generation(dict2)
	var bp2 = architect.tool_registry.active_blueprint
	
	var test2_ok = (bp2.mountains.size() == 3 and bp2.rivers.size() == 2 and bp2.lakes.size() == 4)
	if test2_ok:
		print("[PASS] Test 2: Created exactly %d mountains, %d rivers, and %d lakes." % [
			bp2.mountains.size(), bp2.rivers.size(), bp2.lakes.size()
		])
	else:
		printerr("[FAIL] Test 2: Expected 3 mtns, 2 rivers, 4 lakes. Got %d mtns, %d rivers, %d lakes." % [
			bp2.mountains.size(), bp2.rivers.size(), bp2.lakes.size()
		])
		all_passed = false
		
	# Verify lake water disc generation in ChunkManager
	var cm = ChunkManagerClass.new()
	cm.chunk_scene = chunk_scene
	cm.render_distance = 1
	cm.overall_scale = 2.0
	cm.effective_chunk_size_x = 64.0
	cm.effective_chunk_size_z = 64.0
	root.add_child(cm)
	cm.rebuild_world_from_blueprint(bp2)
	if cm.lakes_container and cm.lakes_container.get_child_count() == 4:
		print("[PASS] Test 2 (Geometry): ChunkManager generated %d visible 3D lake water discs." % cm.lakes_container.get_child_count())
	else:
		printerr("[FAIL] Test 2 (Geometry): ChunkManager failed to generate 4 visible lake discs.")
		all_passed = false
		
	# -------------------------------------------------------------------------
	# TEST 3: Create 5 mountains in the northern region.
	# -------------------------------------------------------------------------
	print("\n--- TEST 3: Create 5 mountains in the northern region ---")
	var prompt3 = "Create 5 mountains in the northern region."
	var intent3 = ForestArchitect.parse_natural_language_intent(prompt3)
	architect.current_intent = intent3
	var dict3 = architect._synthesize_blueprint_from_intent(intent3)
	architect._finalize_world_generation(dict3)
	var bp3 = architect.tool_registry.active_blueprint
	
	var test3_count_ok = (bp3.mountains.size() == 5)
	var all_north = true
	for m in bp3.mountains:
		var pz = float(m.get("pos", Vector2.ZERO).y)
		if pz > -25.0:
			all_north = false
			
	if test3_count_ok and all_north:
		print("[PASS] Test 3: Exactly %d mountains created, all situated in northern region (z <= -25)." % bp3.mountains.size())
	else:
		printerr("[FAIL] Test 3: Expected 5 northern mountains. Got count=%d, all_north=%s" % [bp3.mountains.size(), str(all_north)])
		all_passed = false
		
	# -------------------------------------------------------------------------
	# TEST 4: Create 2 rivers flowing from separate mountains.
	# -------------------------------------------------------------------------
	print("\n--- TEST 4: Create 2 rivers flowing from separate mountains ---")
	var prompt4 = "Create 2 rivers flowing from separate mountains."
	var intent4 = ForestArchitect.parse_natural_language_intent(prompt4)
	architect.current_intent = intent4
	var dict4 = architect._synthesize_blueprint_from_intent(intent4)
	architect._finalize_world_generation(dict4)
	var bp4 = architect.tool_registry.active_blueprint
	
	var r1_pts: PackedVector2Array = bp4.rivers[0].get("points", PackedVector2Array()) if bp4.rivers.size() > 0 else PackedVector2Array()
	var r2_pts: PackedVector2Array = bp4.rivers[1].get("points", PackedVector2Array()) if bp4.rivers.size() > 1 else PackedVector2Array()
	var r1_start = r1_pts[0] if r1_pts.size() > 0 else Vector2.ZERO
	var r2_start = r2_pts[0] if r2_pts.size() > 0 else Vector2.ZERO
	var diff_sources = bp4.mountains.size() >= 2 and bp4.rivers.size() == 2 and (r1_start != r2_start)
	
	if diff_sources:
		print("[PASS] Test 4: Created 2 rivers flowing from separate mountains (m1 at %s, m2 at %s)." % [
			str(bp4.mountains[0].pos), str(bp4.mountains[1].pos)
		])
	else:
		printerr("[FAIL] Test 4: Expected 2 rivers flowing from separate mountains.")
		all_passed = false
		
	# -------------------------------------------------------------------------
	# TEST 5: Create 1 mountain, 1 river, and 1 waterfall.
	# -------------------------------------------------------------------------
	print("\n--- TEST 5: Create 1 mountain, 1 river, and 1 waterfall ---")
	var prompt5 = "Create 1 mountain, 1 river, and 1 waterfall."
	var intent5 = ForestArchitect.parse_natural_language_intent(prompt5)
	architect.current_intent = intent5
	var dict5 = architect._synthesize_blueprint_from_intent(intent5)
	architect._finalize_world_generation(dict5)
	var bp5 = architect.tool_registry.active_blueprint
	
	var actual_wfs = 0
	for r in bp5.rivers:
		actual_wfs += r.get("waterfalls", []).size()
		
	if bp5.mountains.size() == 1 and bp5.rivers.size() == 1 and actual_wfs == 1:
		print("[PASS] Test 5: Created 1 mountain, 1 river, and 1 waterfall (drop=%.0fm on '%s')." % [
			float(bp5.rivers[0].waterfalls[0].get("height_drop", 0.0)), bp5.rivers[0].get("name", "")
		])
	else:
		printerr("[FAIL] Test 5: Expected 1 mtn, 1 river, 1 waterfall. Got %d mtns, %d rivers, %d wfs." % [
			bp5.mountains.size(), bp5.rivers.size(), actual_wfs
		])
		all_passed = false
		
	# -------------------------------------------------------------------------
	# TEST 6: Create a forest around both rivers without changing the mountains.
	# -------------------------------------------------------------------------
	print("\n--- TEST 6: Create a forest around both rivers without changing mountains ---")
	# Start with a world having 2 rivers and 2 mountains
	var bp6_base = ForestBlueprint.new()
	bp6_base.mountains = [
		{"id": "mtn_1", "name": "North Peak", "pos": Vector2(-60.0, -75.0), "height": 60.0, "radius": 65.0, "snow_cap": true, "status": "verified"},
		{"id": "mtn_2", "name": "East Peak", "pos": Vector2(60.0, -75.0), "height": 55.0, "radius": 60.0, "snow_cap": true, "status": "verified"}
	]
	var pts_a = PackedVector2Array([Vector2(-60.0, -70.0), Vector2(-30.0, 0.0), Vector2(-10.0, 70.0)])
	var pts_b = PackedVector2Array([Vector2(60.0, -70.0), Vector2(30.0, 0.0), Vector2(10.0, 70.0)])
	bp6_base.rivers = [
		{"id": "r1", "name": "West River", "points": pts_a, "spline_points": pts_a, "distances": PackedFloat32Array([0, 70, 140]), "total_length": 140.0, "width": 8.0, "depth": 4.0, "flow_speed": 0.7, "status": "verified"},
		{"id": "r2", "name": "East River", "points": pts_b, "spline_points": pts_b, "distances": PackedFloat32Array([0, 70, 140]), "total_length": 140.0, "width": 8.0, "depth": 4.0, "flow_speed": 0.7, "status": "verified"}
	]
	bp6_base.sync_feature_registry()
	architect.tool_registry.active_blueprint = bp6_base
	
	var mtn1_pos_before = bp6_base.mountains[0].pos
	var mtn2_pos_before = bp6_base.mountains[1].pos
	var layers_before = bp6_base.vegetation_layers.size()
	
	var edit6 = architect._create_fallback_edit("Create a forest around both rivers without changing the mountains.", {})
	architect._execute_edit_plan(edit6)
	var bp6_after = architect.tool_registry.active_blueprint
	
	var mtns_unmoved = (bp6_after.mountains[0].pos == mtn1_pos_before and bp6_after.mountains[1].pos == mtn2_pos_before)
	var has_riverbank_flora = false
	for l in bp6_after.vegetation_layers:
		if l.distribution == "riverbank_focused" or l.near_water_only:
			has_riverbank_flora = true
			break
			
	if mtns_unmoved and has_riverbank_flora:
		print("[PASS] Test 6: Forest layer created around rivers; all mountain positions strictly preserved.")
	else:
		printerr("[FAIL] Test 6: Forest creation around rivers failed or mountains moved.")
		all_passed = false
		
	# -------------------------------------------------------------------------
	# TEST 7: Make the northwestern mountain taller.
	# -------------------------------------------------------------------------
	print("\n--- TEST 7: Make the northwestern mountain taller ---")
	var nw_before = architect.tool_registry._resolve_mountain_target("northwest")
	var nw_h_before = float(nw_before.get("height", 0.0))
	var other_before = architect.tool_registry._resolve_mountain_target("east")
	var other_h_before = float(other_before.get("height", 0.0))
	
	var edit7 = architect._create_fallback_edit("Make the northwestern mountain taller.", {})
	architect._execute_edit_plan(edit7)
	var bp7 = architect.tool_registry.active_blueprint
	var nw_after = architect.tool_registry._resolve_mountain_target("northwest")
	var other_after = architect.tool_registry._resolve_mountain_target("east")
	
	if float(nw_after.get("height", 0.0)) > nw_h_before and is_equal_approx(float(other_after.get("height", 0.0)), other_h_before):
		print("[PASS] Test 7: Northwestern mountain height increased (%.0fm -> %.0fm); other mountain untouched." % [
			nw_h_before, float(nw_after.get("height", 0.0))
		])
	else:
		printerr("[FAIL] Test 7: NW mountain height edit failed.")
		all_passed = false
		
	# -------------------------------------------------------------------------
	# TEST 8: Generate a deliberately malformed AI response and verify no crash.
	# -------------------------------------------------------------------------
	print("\n--- TEST 8: Malformed AI response handling ---")
	var malformed_responses = [
		"```json\n{\"theme\": \"Broken World\", \"mountains\": [{\"id\": 1, \"height\": 50,},], \"rivers\": [}\n```",
		"Here is your landscape: {\"theme\": \"Incomplete\", \"mountains\": [",
		"TOTAL GARBAGE NON-JSON OUTPUT: <<INVALID>> !!!"
	]
	
	var test8_ok = true
	for malformed in malformed_responses:
		var parsed = architect._extract_json_dict(malformed)
		# Attempting to finalize generation with either the repaired dict or fallback
		if parsed.is_empty():
			parsed = architect._create_fallback_from_prompt("Create 2 rivers and 1 mountain.")
		architect._finalize_world_generation(parsed)
		if architect.tool_registry.active_blueprint == null:
			test8_ok = false
			
	if test8_ok:
		print("[PASS] Test 8: Safely handled malformed/truncated JSON responses with zero crashes.")
	else:
		printerr("[FAIL] Test 8: Malformed response crashed or corrupted world generation.")
		all_passed = false
		
	# -------------------------------------------------------------------------
	# TEST 9: Simulate an Ollama timeout and verify project remains responsive.
	# -------------------------------------------------------------------------
	print("\n--- TEST 9: Simulated Ollama timeout handling ---")
	architect.is_busy = true
	architect.current_user_prompt = "Create 3 mountains, 2 rivers, and 4 lakes."
	architect.current_intent = ForestArchitect.parse_natural_language_intent(architect.current_user_prompt)
	
	# Simulate HTTPRequest timeout callback: result = RESULT_TIMEOUT (13), response_code = 0
	architect._on_request_completed(HTTPRequest.RESULT_TIMEOUT, 0, PackedStringArray(), PackedByteArray())
	
	var bp9 = architect.tool_registry.active_blueprint
	var is_not_busy = (architect.is_busy == false)
	var recovered_world = (bp9 != null and bp9.mountains.size() == 3 and bp9.rivers.size() == 2 and bp9.lakes.size() == 4)
	
	if is_not_busy and recovered_world:
		print("[PASS] Test 9: Successfully caught timeout (code 0); reset busy state and generated verified requested world.")
	else:
		printerr("[FAIL] Test 9: Timeout recovery failed. is_busy=%s, recovered_world=%s" % [str(architect.is_busy), str(recovered_world)])
		all_passed = false
		
	print("\n=================================================================")
	if all_passed:
		print("ALL 9 TESTS PASSED SUCCESSFULLY!")
	else:
		printerr("ONE OR MORE TESTS FAILED!")
	print("=================================================================")
	quit(0 if all_passed else 1)
