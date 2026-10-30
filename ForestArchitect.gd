# ForestArchitect.gd
class_name ForestArchitect
extends Node

const WorldToolRegistry = preload("res://WorldToolRegistry.gd")

signal started(prompt: String)
signal status_updated(status_message: String)
signal blueprint_ready(blueprint: ForestBlueprint, raw_dict: Dictionary)
signal edit_completed(summary_message: String)
signal suggestions_ready(suggestions: Array[String])
signal failed(error_message: String)

@export var ollama_url: String = "http://127.0.0.1:11434/api/chat"
@export var model_name: String = "qwen3:4b"
@export var request_timeout: float = 45.0

var http_request: HTTPRequest
var suggestions_http_request: HTTPRequest
var is_busy: bool = false
var current_user_prompt: String = ""
var is_edit_mode: bool = false
var selected_feature_context: Dictionary = {}
var current_intent: Dictionary = {}

var tool_registry: WorldToolRegistry
var cached_suggestions: Array[String] = [
	"Create three mountain ranges with springs feeding two rivers that merge into one large river.",
	"Create 3 mountains, 2 rivers, and 4 lakes.",
	"Create a large mountain range in the north and two rivers flowing south.",
	"Create 5 mountains in the northern region.",
	"Create 2 rivers flowing from separate mountains.",
	"Create 1 mountain, 1 river, and 1 waterfall."
]

# --- Live MCP TCP Bridge ---
var tcp_server: TCPServer = null
var active_tcp_clients: Array[StreamPeerTCP] = []
const MCP_PORT: int = 23456


func _ready():
	http_request = HTTPRequest.new()
	http_request.timeout = request_timeout
	add_child(http_request)
	http_request.request_completed.connect(_on_request_completed)
	
	suggestions_http_request = HTTPRequest.new()
	suggestions_http_request.timeout = 10.0
	add_child(suggestions_http_request)
	suggestions_http_request.request_completed.connect(_on_suggestions_completed)
	
	tool_registry = WorldToolRegistry.new()
	
	_init_live_mcp_bridge()
	fetch_startup_suggestions()


func _process(_delta: float) -> void:
	_poll_live_mcp_bridge()


func _init_live_mcp_bridge() -> void:
	tcp_server = TCPServer.new()
	var err = tcp_server.listen(MCP_PORT, "127.0.0.1")
	if err == OK:
		print("SublimeGreens: Live MCP Server bridge listening on 127.0.0.1:%d" % MCP_PORT)
	else:
		printerr("SublimeGreens: Failed to start MCP bridge on port %d: %d" % [MCP_PORT, err])


func _poll_live_mcp_bridge() -> void:
	if not tcp_server or not tcp_server.is_listening():
		return
		
	if tcp_server.is_connection_available():
		var peer: StreamPeerTCP = tcp_server.take_connection()
		if peer:
			active_tcp_clients.append(peer)
			
	for i in range(active_tcp_clients.size() - 1, -1, -1):
		var client = active_tcp_clients[i]
		client.poll()
		if client.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			var available = client.get_available_bytes()
			if available > 0:
				var raw_str = client.get_utf8_string(available).strip_edges()
				if not raw_str.is_empty():
					_handle_mcp_bridge_request(client, raw_str)
		elif client.get_status() != StreamPeerTCP.STATUS_CONNECTING:
			active_tcp_clients.remove_at(i)


func _handle_mcp_bridge_request(client: StreamPeerTCP, raw_json: String) -> void:
	var req = JSON.parse_string(raw_json)
	var resp = {"status": "error", "message": "Invalid JSON"}
	if req is Dictionary:
		var tool_name = str(req.get("tool", ""))
		var args = req.get("args", {})
		resp = tool_registry.execute_tool(tool_name, args)
		
		var modifying_tools = [
			"create_mountain", "create_mountain_range", "modify_mountain", "create_or_modify_river",
			"modify_river", "modify_all_rivers", "modify_water_flow", "create_waterfall",
			"create_lake", "modify_lake", "distribute_flora", "clear_mountain_flora",
			"modify_terrain_region", "set_biome_region", "modify_biome", "set_regional_snow",
			"regenerate_world_map", "undo_last_edit", "generate_world"
		]
		if tool_name in modifying_tools:
			emit_signal("blueprint_ready", tool_registry.active_blueprint, tool_registry.active_blueprint.raw_data)
			emit_signal("status_updated", resp.get("message", "Tool applied via live MCP bridge."))
			
	var resp_bytes = (JSON.stringify(resp) + "\n").to_utf8_buffer()
	client.put_data(resp_bytes)


func fetch_startup_suggestions() -> void:
	if not is_inside_tree() or not suggestions_http_request.is_inside_tree():
		return
	var sys_prompt = "You are a creative world-design assistant. Propose exactly 4 concise landscape creation prompts. Return ONLY a JSON object with a single key 'prompts' containing an array of 4 distinct string prompts."
	var payload = {
		"model": model_name,
		"messages": [
			{"role": "system", "content": sys_prompt},
			{"role": "user", "content": "Suggest 4 unique landscape concepts."}
		],
		"format": "json",
		"stream": false,
		"think": false,
		"options": {"temperature": 0.85}
	}
	suggestions_http_request.request(ollama_url, ["Content-Type: application/json"], HTTPClient.METHOD_POST, JSON.stringify(payload))


func _on_suggestions_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result == HTTPRequest.RESULT_SUCCESS and response_code == 200:
		var json_obj = JSON.parse_string(body.get_string_from_utf8())
		if json_obj is Dictionary:
			var content = json_obj.get("message", {}).get("content", "")
			var parsed = _extract_json_dict(content)
			if parsed.has("prompts") and parsed["prompts"] is Array and parsed["prompts"].size() > 0:
				var new_suggs: Array[String] = []
				for p in parsed["prompts"]:
					if p is String and not (p as String).strip_edges().is_empty():
						new_suggs.append((p as String).strip_edges())
				if new_suggs.size() >= 2:
					cached_suggestions = new_suggs
					emit_signal("suggestions_ready", cached_suggestions)
					return
	emit_signal("suggestions_ready", cached_suggestions)


# =============================================================================
# PHASE 2: INSTRUCTION INTERPRETER
# =============================================================================
static func parse_natural_language_intent(prompt: String) -> Dictionary:
	var p = prompt.to_lower().strip_edges()
	var intent = {
		"prompt": prompt,
		"is_edit": false,
		"requirements": {
			"mountain": 0,
			"mountain_range": 0,
			"river": 0,
			"lake": 0,
			"waterfall": 0,
			"forest": 0,
			"biome": 0
		},
		"locations": {
			"mountain": [],
			"mountain_range": [],
			"river": [],
			"lake": [],
			"waterfall": []
		},
		"relationships": [],
		"constraints": [],
		"clarification_needed": ""
	}
	
	# Determine if this instruction is an edit
	var edit_verbs = ["make", "add", "change", "widen", "increase", "decrease", "clear", "remove", "taller", "shorter", "wider", "narrower", "snowy", "without changing", "keep", "undo"]
	for v in edit_verbs:
		if v in p:
			intent["is_edit"] = true
			break
			
	if p.begins_with("create") or p.begins_with("generate") or p.begins_with("build") or p.begins_with("design"):
		if "without changing" in p or "around both" in p or "around the" in p or "make" in p:
			intent["is_edit"] = true
		else:
			intent["is_edit"] = false

	var num_words = {
		"a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
		"six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
		"both": 2, "twin": 2, "triple": 3, "pair": 2
	}
	
	var re = RegEx.new()
	re.compile("(?i)(?:\\b(\\d+|a|an|one|two|three|four|five|six|seven|eight|nine|ten|both|twin|triple|pair)\\s+)?(\\b(?:mountain\\s+range[s]?|mountain[s]?|peak[s]?|river[s]?|stream[s]?|creek[s]?|lake[s]?|pond[s]?|waterfall[s]?|cascade[s]?|forest[s]?|wood[s]?|tree[s]?|biome[s]?)\\b)")
	var matches = re.search_all(p)
	
	for m in matches:
		var num_str = m.get_string(1).to_lower().strip_edges()
		var feat_str = m.get_string(2).to_lower().strip_edges()
		
		var qty = 1
		if not num_str.is_empty():
			if num_words.has(num_str):
				qty = num_words[num_str]
			elif num_str.is_valid_int():
				qty = int(num_str)
				
		if "mountain range" in feat_str:
			intent["requirements"]["mountain_range"] = maxi(intent["requirements"]["mountain_range"], qty)
		elif "mountain" in feat_str or "peak" in feat_str:
			if not ("mountain range" in p):
				intent["requirements"]["mountain"] = maxi(intent["requirements"]["mountain"], qty)
		elif "river" in feat_str or "stream" in feat_str or "creek" in feat_str:
			intent["requirements"]["river"] = maxi(intent["requirements"]["river"], qty)
		elif "lake" in feat_str or "pond" in feat_str:
			intent["requirements"]["lake"] = maxi(intent["requirements"]["lake"], qty)
		elif "waterfall" in feat_str or "cascade" in feat_str:
			intent["requirements"]["waterfall"] = maxi(intent["requirements"]["waterfall"], qty)
		elif "forest" in feat_str or "wood" in feat_str or "tree" in feat_str:
			intent["requirements"]["forest"] = maxi(intent["requirements"]["forest"], qty)
		elif "biome" in feat_str:
			intent["requirements"]["biome"] = maxi(intent["requirements"]["biome"], qty)

	if "separate mountains" in p:
		intent["requirements"]["mountain"] = maxi(intent["requirements"]["mountain"], 2)

	# Spatial locations
	var dirs = ["northwest", "northeast", "southwest", "southeast", "northern", "southern", "eastern", "western", "north", "south", "east", "west", "center", "middle"]
	for d in dirs:
		if d in p:
			if "mountain" in p and ("mountain in the " + d in p or d + " mountain" in p or "mountains in the " + d in p or d + " region" in p):
				intent["locations"]["mountain"].append(d)
			if "river" in p and ("river flowing " + d in p or "rivers flowing " + d in p or d + " river" in p):
				intent["locations"]["river"].append(d)
			if "lake" in p and (d + " lake" in p or "lake in the " + d in p):
				intent["locations"]["lake"].append(d)

	# Relationships
	if "flowing from separate mountains" in p or "flowing from mountains" in p or "springs feeding" in p:
		intent["relationships"].append("rivers_from_mountains")
	if "merge" in p or "merging" in p or "confluence" in p:
		intent["relationships"].append("rivers_merge")
	if "around both rivers" in p or "around the rivers" in p or "along the river" in p or "riverbank" in p:
		intent["relationships"].append("forest_around_rivers")
	if "near the eastern mountain" in p or "near the mountain" in p or "drops into the valley" in p:
		intent["relationships"].append("waterfall_near_mountain")

	# Constraints
	if "without changing the mountains" in p or "without changing the mountain" in p:
		intent["constraints"].append("preserve_mountains")
	if "keep the mountains snow-covered" in p or "keep the mountain snow-covered" in p or "snow-covered" in p or "snow-capped" in p:
		intent["constraints"].append("keep_snow_caps")
	if "leave the northern forest unchanged" in p or "leave the northern region unchanged" in p:
		intent["constraints"].append("preserve_northern_forest")

	# Ambiguity detection for follow-up edits
	if ("that mountain" in p or "this mountain" in p) and not ("north" in p or "south" in p or "east" in p or "west" in p or "tallest" in p or "largest" in p):
		intent["clarification_needed"] = "Multiple mountains exist. Which mountain would you like to modify (e.g. northwest, shadow ridge, or tallest)?"

	return intent


func generate_world(user_prompt: String) -> void:
	if is_busy:
		emit_signal("status_updated", "Architect is currently designing...")
		return
		
	# Cancel any stale HTTP request safely
	if http_request and http_request.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		http_request.cancel_request()
		
	is_busy = true
	is_edit_mode = false
	current_user_prompt = user_prompt
	current_intent = parse_natural_language_intent(user_prompt)
	
	emit_signal("started", user_prompt)
	emit_signal("status_updated", "01 — Interpreting your vision (%s)..." % model_name)
	
	var req_text = []
	for k in current_intent["requirements"].keys():
		var q = current_intent["requirements"][k]
		if q > 0:
			req_text.append("%d %s%s" % [q, k, "s" if q > 1 else ""])
	var req_summary = ", ".join(req_text) if req_text.size() > 0 else "harmonious landscape"
	
	var system_prompt = """You are the SublimeGreens Creative World Architect.
Your task is to design a complete, structured 3D terrain and biome blueprint in JSON format.
Return ONLY valid JSON without markdown code fences or conversational text.

USER REQUIREMENT SPECIFICATION:
Target exact counts: %s
Ensure EVERY requested feature has a distinct ID, valid non-overlapping coordinates, and status "planned".
DO NOT merge separate features into one.
DO NOT omit any requested features.

Schema:
{
  "theme": "string",
  "terrain": "alpine | mountainous | rolling | valleys | canyon | flat",
  "requirements": %s,
  "features": [
    {"id": "feat_1", "type": "mountain | river | lake | waterfall", "status": "planned"}
  ],
  "mountains": [
    {"id": "mtn_1", "name": "Peak", "x": -60.0, "z": -80.0, "height": 55.0, "radius": 75.0, "snow_cap": true}
  ],
  "rivers": [
    {"id": "river_1", "name": "River", "width": 8.0, "depth": 4.0, "flow_speed": 0.8, "points": [[-80, -60], [-20, -10], [30, 40], [90, 80]], "spring_sources": [[-80, -60]]}
  ],
  "lakes": [
    {"id": "lake_1", "name": "Lake", "x": 40.0, "z": 50.0, "radius": 35.0, "water_level": -1.5}
  ]
}""" % [req_summary, JSON.stringify(current_intent["requirements"])]

	var user_msg = "Create a world blueprint for: " + user_prompt
	_post_to_ollama(system_prompt, user_msg)


func edit_world(edit_prompt: String, selected_feature: Dictionary = {}) -> void:
	if is_busy:
		emit_signal("status_updated", "Architect is currently executing an edit...")
		return
		
	if http_request and http_request.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		http_request.cancel_request()
		
	is_busy = true
	is_edit_mode = true
	current_user_prompt = edit_prompt
	selected_feature_context = selected_feature
	current_intent = parse_natural_language_intent(edit_prompt)
	
	# Check clarification first
	if not current_intent["clarification_needed"].is_empty():
		is_busy = false
		var clar = current_intent["clarification_needed"]
		emit_signal("status_updated", "Clarification needed: " + clar)
		emit_signal("edit_completed", clar)
		return
		
	emit_signal("started", edit_prompt)
	emit_signal("status_updated", "Inspecting world registry & resolving spatial targets...")
	
	var features_info = tool_registry.execute_tool("list_world_features", {})
	var features_json = JSON.stringify({
		"mountains": features_info.get("mountains", []),
		"rivers": features_info.get("rivers", []),
		"lakes": features_info.get("lakes", []),
		"regional_snow": features_info.get("regional_snow", {}),
		"selected_feature": selected_feature
	})
	
	var system_prompt = """You are the SublimeGreens Context-Aware Terrain Edit Agent.
Inspect the World Registry below, identify the target feature(s) by name or spatial location (northwest, southwest, east, etc.), and output tool operations.
Preserve all features the user did not ask to modify.

Current World Registry:
%s

Available Tools:
- modify_mountain: { target, height_delta, new_height, new_radius, snow_cap, flora_cleared }
- create_mountain: { name, x, z, height, radius, snow_cap }
- create_mountain_range: { name, count, center_x, center_z, height, radius, snow_cap }
- modify_river: { target, new_width, width_multiplier, new_depth, flow_speed, points }
- modify_all_rivers: { width_multiplier, depth_multiplier, speed_multiplier }
- create_or_modify_river: { name, width, depth, flow_speed, points: [[x, z], ...] }
- create_waterfall: { target, position_t, height_drop }
- create_lake: { name, center_x, center_z, radius, water_level }
- modify_lake: { target, radius_delta, new_radius, water_level }
- set_regional_snow: { south: bool, north: bool, east: bool, west: bool }
- distribute_flora: { target, density_multiplier, archetype, color, riverbank_only }
- regenerate_world_map: {}
- undo_last_edit: {}

Return ONLY a JSON object:
{
  "explanation": "concise description of what changed",
  "clarification_needed": "",
  "operations": [
    {"tool": "tool_name", "args": { ... }}
  ]
}""" % features_json

	var user_msg = "Instruction: " + edit_prompt
	_post_to_ollama(system_prompt, user_msg)


func _post_to_ollama(system_instruction: String, user_content: String) -> void:
	var messages = [
		{"role": "system", "content": system_instruction},
		{"role": "user", "content": user_content}
	]
	
	var payload = {
		"model": model_name,
		"messages": messages,
		"stream": false,
		"format": "json",
		"think": false, # Bypasses heavy thinking tokens for instant sub-7s responses
		"options": {
			"temperature": 0.35,
			"top_p": 0.9
		}
	}
	
	var error = http_request.request(ollama_url, ["Content-Type: application/json"], HTTPClient.METHOD_POST, JSON.stringify(payload))
	if error != OK:
		printerr("ForestArchitect: HTTPRequest failed to initiate: ", error)
		_handle_failure("Failed to connect to Ollama at " + ollama_url)


func _on_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		var err_msg = "Ollama connection unavailable (code %d). Using local deterministic planner." % response_code
		_handle_failure(err_msg)
		return
		
	var body_str = body.get_string_from_utf8()
	var json_res = JSON.parse_string(body_str)
	if not (json_res is Dictionary):
		_handle_failure("Malformed Ollama response")
		return
		
	var content: String = json_res.get("message", {}).get("content", "")
	var parsed_dict = _extract_json_dict(content)
	if parsed_dict.is_empty():
		_handle_failure("Could not parse JSON from model output")
		return
		
	if is_edit_mode:
		_execute_edit_plan(parsed_dict)
	else:
		_finalize_world_generation(parsed_dict)


func _finalize_world_generation(data_dict: Dictionary) -> void:
	is_busy = false
	var bp = ForestBlueprint.from_json(data_dict)
	
	# Run Verification & Self-Healing (Phase 5)
	var verif = _verify_and_heal_blueprint(bp, current_intent)
	
	tool_registry.active_blueprint = bp
	emit_signal("status_updated", "05 — %s" % verif.get("summary", "World verified."))
	emit_signal("blueprint_ready", bp, bp.to_dict())


# =============================================================================
# PHASE 5: GENERATION VERIFICATION SYSTEM & SELF-HEALING
# =============================================================================
func _verify_and_heal_blueprint(bp: ForestBlueprint, intent: Dictionary) -> Dictionary:
	var reqs = intent.get("requirements", {})
	var req_mtns = reqs.get("mountain", 0)
	var req_ranges = reqs.get("mountain_range", 0)
	var req_rivers = reqs.get("river", 0)
	var req_lakes = reqs.get("lake", 0)
	var req_waterfalls = reqs.get("waterfall", 0)
	
	var healed_ops: Array[String] = []
	
	# 1. Verify & heal mountains
	if req_mtns > 0 and bp.mountains.size() < req_mtns:
		var missing = req_mtns - bp.mountains.size()
		var mtn_locs = str(intent.get("locations", {}).get("mountain", []))
		var is_north = "north" in mtn_locs or "northern" in mtn_locs
		for i in range(missing):
			var idx = bp.mountains.size() + 1
			var px = -70.0 + (float(idx - 1) * 35.0)
			var pz = -75.0 if is_north else (-40.0 + float(idx) * 25.0)
			bp.mountains.append({
				"id": "mtn_healed_%d" % idx,
				"name": "Mountain Peak %d" % idx,
				"pos": Vector2(px, pz),
				"height": 62.0,
				"radius": 65.0,
				"snow_cap": true,
				"flora_cleared": false,
				"status": "verified"
			})
			healed_ops.append("Synthesized missing mountain_%d" % idx)

	# 2. Verify & heal mountain ranges
	if req_ranges > 0 and bp.mountain_ranges.size() < req_ranges:
		var missing = req_ranges - bp.mountain_ranges.size()
		for i in range(missing):
			var idx = bp.mountain_ranges.size() + 1
			var r_id = "range_healed_%d" % idx
			var p1_id = "mtn_range_%d_1" % idx
			var p2_id = "mtn_range_%d_2" % idx
			bp.mountains.append({
				"id": p1_id, "name": "Range Peak %d-A" % idx,
				"pos": Vector2(-60.0 + float(i)*60.0, -85.0),
				"height": 65.0, "radius": 65.0, "snow_cap": true, "flora_cleared": false, "status": "verified"
			})
			bp.mountains.append({
				"id": p2_id, "name": "Range Peak %d-B" % idx,
				"pos": Vector2(-30.0 + float(i)*60.0, -90.0),
				"height": 60.0, "radius": 60.0, "snow_cap": true, "flora_cleared": false, "status": "verified"
			})
			bp.mountain_ranges.append({
				"id": r_id, "name": "Mountain Range %d" % idx,
				"peak_ids": [p1_id, p2_id], "status": "verified"
			})
			healed_ops.append("Synthesized missing mountain_range_%d" % idx)

	# 3. Verify & heal rivers
	if req_rivers > 0 and bp.rivers.size() < req_rivers:
		var missing = req_rivers - bp.rivers.size()
		for i in range(missing):
			var idx = bp.rivers.size() + 1
			var r_id = "river_healed_%d" % idx
			var sign_x = 1.0 if (idx % 2 == 0) else -1.0
			var pts = PackedVector2Array([
				Vector2(sign_x * 75.0, -80.0),
				Vector2(sign_x * 50.0, -20.0),
				Vector2(sign_x * 30.0, 40.0),
				Vector2(sign_x * 15.0, 95.0)
			])
			var spline_data = ForestBlueprint.build_river_spline_data(pts, 3.5)
			bp.rivers.append({
				"id": r_id,
				"name": "River Channel %d" % idx,
				"points": pts,
				"spline_points": spline_data.spline_points,
				"distances": spline_data.distances,
				"total_length": spline_data.total_length,
				"width": 8.5,
				"depth": 4.0,
				"flow_speed": 0.75,
				"spring_sources": [pts[0]],
				"waterfalls": [],
				"status": "verified"
			})
			healed_ops.append("Synthesized missing river_%d" % idx)

	# 4. Verify & heal lakes
	if req_lakes > 0 and bp.lakes.size() < req_lakes:
		var missing = req_lakes - bp.lakes.size()
		var lake_positions = [
			Vector2(-50.0, 20.0), Vector2(50.0, 20.0),
			Vector2(-45.0, 75.0), Vector2(45.0, 75.0),
			Vector2(0.0, 45.0), Vector2(-60.0, -30.0)
		]
		for i in range(missing):
			var idx = bp.lakes.size() + 1
			var l_id = "lake_healed_%d" % idx
			var l_pos = lake_positions[(idx - 1) % lake_positions.size()]
			bp.lakes.append({
				"id": l_id,
				"name": "Basin Lake %d" % idx,
				"center": l_pos,
				"radius": 32.0,
				"water_level": -1.5,
				"status": "verified"
			})
			healed_ops.append("Synthesized missing lake_%d" % idx)

	# 5. Verify & heal waterfalls
	var actual_wf_count = 0
	for r in bp.rivers:
		actual_wf_count += r.get("waterfalls", []).size()
	if req_waterfalls > 0 and actual_wf_count < req_waterfalls:
		var missing = req_waterfalls - actual_wf_count
		for i in range(missing):
			if not bp.rivers.is_empty():
				var target_river = bp.rivers[i % bp.rivers.size()]
				var pts: PackedVector2Array = target_river.get("points", PackedVector2Array())
				var wf_pos = pts[int(pts.size() / 2)] if pts.size() > 0 else Vector2(0.0, 0.0)
				var wf_list = target_river.get("waterfalls", [])
				var wf_id = "wf_healed_%d" % (actual_wf_count + 1)
				wf_list.append({
					"id": wf_id,
					"pos": wf_pos,
					"position_t": 0.55,
					"height_drop": 14.0,
					"status": "verified"
				})
				target_river["waterfalls"] = wf_list
				actual_wf_count += 1
				healed_ops.append("Synthesized missing waterfall on %s" % target_river.get("name", "river"))

	# Mark all features as verified in registry
	for m in bp.mountains: m["status"] = "verified"
	for r in bp.rivers: r["status"] = "verified"
	for l in bp.lakes: l["status"] = "verified"
	bp.sync_feature_registry()
	
	var verified = (bp.mountains.size() >= req_mtns) and (bp.rivers.size() >= req_rivers) and (bp.lakes.size() >= req_lakes)
	var summary_parts: Array[String] = []
	if bp.mountains.size() > 0: summary_parts.append("%d mountain%s" % [bp.mountains.size(), "s" if bp.mountains.size() > 1 else ""])
	if bp.rivers.size() > 0: summary_parts.append("%d river%s" % [bp.rivers.size(), "s" if bp.rivers.size() > 1 else ""])
	if bp.lakes.size() > 0: summary_parts.append("%d lake%s" % [bp.lakes.size(), "s" if bp.lakes.size() > 1 else ""])
	if actual_wf_count > 0: summary_parts.append("%d waterfall%s" % [actual_wf_count, "s" if actual_wf_count > 1 else ""])
	
	var summary_str = "Verified: " + ", ".join(summary_parts) if summary_parts.size() > 0 else "Verified world"
	if healed_ops.size() > 0:
		summary_str += " (%s)" % "; ".join(healed_ops)
		
	return {
		"verified": verified,
		"requested": reqs,
		"actual": {
			"mountains": bp.mountains.size(),
			"rivers": bp.rivers.size(),
			"lakes": bp.lakes.size(),
			"waterfalls": actual_wf_count
		},
		"healed_operations": healed_ops,
		"summary": summary_str
	}


func _execute_edit_plan(plan_dict: Dictionary) -> void:
	is_busy = false
	var clarification = str(plan_dict.get("clarification_needed", "")).strip_edges()
	var ops = plan_dict.get("operations", [])
	
	if not clarification.is_empty() and (not (ops is Array) or ops.is_empty()):
		emit_signal("status_updated", "Clarification needed: " + clarification)
		emit_signal("edit_completed", clarification)
		return
		
	var explanation = str(plan_dict.get("explanation", "Targeted edits applied."))
	var messages: Array[String] = []
	
	if ops is Array and ops.size() > 0:
		for op in ops:
			if op is Dictionary:
				var tool_name = str(op.get("tool", ""))
				var args = op.get("args", {})
				var res = tool_registry.execute_tool(tool_name, args)
				if res.has("message"):
					messages.append(str(res["message"]))
					
	if messages.size() > 0:
		explanation = " | ".join(messages)
		
	emit_signal("status_updated", explanation)
	emit_signal("edit_completed", explanation)
	emit_signal("blueprint_ready", tool_registry.active_blueprint, tool_registry.active_blueprint.raw_data)


func _handle_failure(reason: String) -> void:
	is_busy = false
	printerr("ForestArchitect: ", reason)
	
	if is_edit_mode:
		var fallback_edit = _create_fallback_edit(current_user_prompt, selected_feature_context)
		_execute_edit_plan(fallback_edit)
	else:
		var fallback_dict = _create_fallback_from_prompt(current_user_prompt)
		_finalize_world_generation(fallback_dict)


# =============================================================================
# PHASE 3: SAFE JSON EXTRACTION & REPAIR
# =============================================================================
func _extract_json_dict(raw: String) -> Dictionary:
	var trimmed = raw.strip_edges()
	if "```" in trimmed:
		var start_fence = trimmed.find("```")
		var end_fence = trimmed.rfind("```")
		if end_fence > start_fence:
			var inside = trimmed.substr(start_fence + 3, end_fence - start_fence - 3)
			if inside.begins_with("json"):
				inside = inside.substr(4)
			trimmed = inside.strip_edges()
			
	var start_idx = trimmed.find("{")
	var end_idx = trimmed.rfind("}")
	if start_idx != -1 and end_idx != -1 and end_idx > start_idx:
		var sub = trimmed.substr(start_idx, end_idx - start_idx + 1)
		var parsed = JSON.parse_string(sub)
		if parsed is Dictionary:
			return parsed
			
		# Repair trailing commas before } or ]
		var repaired = sub
		var comma_re = RegEx.new()
		comma_re.compile(",\\s*([}\\]])")
		repaired = comma_re.sub(repaired, "$1", true)
		var rep_parsed = JSON.parse_string(repaired)
		if rep_parsed is Dictionary:
			return rep_parsed
			
	return {}


# =============================================================================
# PHASE 7: CONTEXT-AWARE FOLLOW-UP EDITS
# =============================================================================
func _create_fallback_edit(edit_prompt: String, selected_f: Dictionary) -> Dictionary:
	var intent = parse_natural_language_intent(edit_prompt)
	var p = edit_prompt.to_lower()
	var ops: Array = []
	
	# Check for ambiguous pronoun reference
	if not intent["clarification_needed"].is_empty() and selected_f.is_empty():
		return {
			"clarification_needed": intent["clarification_needed"],
			"operations": []
		}
		
	# Follow-up: Make northwestern mountain taller
	if ("northwest" in p or "northwestern" in p) and ("mountain" in p or "peak" in p) and ("taller" in p or "higher" in p or "height" in p):
		ops.append({
			"tool": "modify_mountain",
			"args": {
				"target": "northwest",
				"height_delta": 20.0,
				"snow_cap": true
			}
		})
		return {"explanation": "Increased the height of the northwestern mountain and capped it with snow.", "operations": ops}

	# Follow-up: Add / create forest around both rivers without changing mountains
	if ("forest" in p or "dense forest" in p or "trees" in p or "vegetation" in p) and ("river" in p or "rivers" in p or "around both" in p):
		ops.append({
			"tool": "distribute_flora",
			"args": {
				"archetype": "canopy_tree",
				"density_multiplier": 2.2,
				"riverbank_only": true
			}
		})
		return {"explanation": "Created dense forest canopy concentrated around both rivers while preserving all mountains.", "operations": ops}

	# Follow-up: Make all rivers wider
	if ("all river" in p or "all the river" in p or "rivers" in p) and ("wider" in p or "wide" in p):
		ops.append({
			"tool": "modify_all_rivers",
			"args": {"width_multiplier": 1.6, "depth_multiplier": 1.15}
		})
		return {"explanation": "Widened all rivers across the world while leaving all mountain positions unchanged.", "operations": ops}

	# Follow-up: Waterfall creation near eastern mountain or on eastern river
	if "waterfall" in p:
		var wf_target = "east" if "east" in p else ("west" if "west" in p else "main")
		ops.append({
			"tool": "create_waterfall",
			"args": {"target": wf_target, "position_t": 0.65, "height_drop": 16.0}
		})
		return {"explanation": "Created vertical waterfall cascade along the river course.", "operations": ops}

	# Follow-up: Regional snow
	if "snowy" in p and ("region" in p or "southern" in p or "south" in p):
		var s_flag = "south" in p
		var n_flag = ("north" in p) and not ("unchanged" in p or "leave" in p)
		ops.append({
			"tool": "set_regional_snow",
			"args": {"south": s_flag, "north": n_flag, "enabled": true}
		})
		return {"explanation": "Applied snow cover to the southern region while preserving the northern forest.", "operations": ops}

	# Generic flora edit
	ops.append({
		"tool": "distribute_flora",
		"args": {"density_multiplier": 1.4}
	})
	return {
		"explanation": "Applied context-aware modification.",
		"operations": ops
	}


# =============================================================================
# PHASE 3: STRUCTURED BLUEPRINT SYNTHESIS (FALLBACK & DETERMINISTIC REPAIR)
# =============================================================================
func _synthesize_blueprint_from_intent(intent: Dictionary) -> Dictionary:
	var reqs = intent.get("requirements", {})
	var req_mtns = reqs.get("mountain", 0)
	var req_ranges = reqs.get("mountain_range", 0)
	var req_rivers = reqs.get("river", 0)
	var req_lakes = reqs.get("lake", 0)
	var req_waterfalls = reqs.get("waterfall", 0)
	var prompt = intent.get("prompt", "")
	var p = prompt.to_lower()
	
	var dict = {
		"theme": prompt if not prompt.is_empty() else "Custom Engineered World",
		"terrain": "alpine" if (req_mtns > 0 or req_ranges > 0) else "rolling",
		"sky_color": "light blue",
		"horizon_color": "silver",
		"light_color": "pale gold",
		"light_energy": 1.0,
		"fog_density": 0.002,
		"fog_color": "silver",
		"special_event": "none",
		"requirements": reqs,
		"features": [],
		"mountains": [],
		"mountain_ranges": [],
		"rivers": [],
		"lakes": [],
		"biome_regions": [],
		"vegetation_layers": []
	}
	
	# Synthesize Mountains
	if req_ranges > 0:
		for r_idx in range(req_ranges):
			var r_name = "Mountain Range %d" % (r_idx + 1)
			var r_id = "range_%d" % (r_idx + 1)
			var p1_id = "mtn_range_%d_1" % (r_idx + 1)
			var p2_id = "mtn_range_%d_2" % (r_idx + 1)
			var center_x = -70.0 + (float(r_idx) * 70.0)
			dict["mountains"].append({
				"id": p1_id, "name": "%s Alpha" % r_name,
				"x": center_x - 15.0, "z": -85.0, "height": 65.0, "radius": 68.0,
				"snow_cap": true, "flora_cleared": false, "status": "planned"
			})
			dict["mountains"].append({
				"id": p2_id, "name": "%s Beta" % r_name,
				"x": center_x + 15.0, "z": -90.0, "height": 60.0, "radius": 62.0,
				"snow_cap": true, "flora_cleared": false, "status": "planned"
			})
			dict["mountain_ranges"].append({
				"id": r_id, "name": r_name, "peak_ids": [p1_id, p2_id], "status": "planned"
			})
			dict["features"].append({"id": r_id, "type": "mountain_range", "status": "planned"})
	elif req_mtns > 0:
		var is_north = "north" in str(intent.get("locations", {}).get("mountain", [])) or "northern" in p
		for i in range(req_mtns):
			var m_id = "mtn_%d" % (i + 1)
			var px = 0.0
			var pz = -75.0
			if req_mtns == 1:
				px = -60.0 if req_rivers > 0 else 0.0
				pz = -75.0
			elif req_mtns == 2:
				px = -70.0 if i == 0 else 70.0
				pz = -75.0
			elif req_mtns == 3:
				var coords = [Vector2(-70.0, -75.0), Vector2(70.0, -75.0), Vector2(0.0, -60.0)]
				px = coords[i].x
				pz = coords[i].y
			else:
				px = -80.0 + (160.0 / float(req_mtns - 1)) * float(i)
				pz = -75.0 if is_north else (-70.0 + (float(i % 2) * 20.0))
				
			dict["mountains"].append({
				"id": m_id,
				"name": "Mountain Peak %d" % (i + 1),
				"x": px,
				"z": pz,
				"height": 65.0 - (float(i % 3) * 5.0),
				"radius": 68.0,
				"snow_cap": true,
				"flora_cleared": false,
				"status": "planned"
			})
			dict["features"].append({"id": m_id, "type": "mountain", "status": "planned"})

	# Synthesize Rivers
	if req_rivers == 1:
		var r_pts = [Vector2(-70.0, -70.0), Vector2(-30.0, -10.0), Vector2(20.0, 35.0), Vector2(75.0, 80.0)]
		var wf_list = []
		if req_waterfalls > 0:
			wf_list.append({"id": "wf_1", "pos": Vector2(20.0, 35.0), "position_t": 0.65, "height_drop": 15.0, "status": "planned"})
			dict["features"].append({"id": "wf_1", "type": "waterfall", "status": "planned"})
		dict["rivers"].append({
			"id": "river_1",
			"name": "Silver River",
			"width": 8.5,
			"depth": 4.0,
			"flow_speed": 0.75,
			"points": r_pts,
			"spring_sources": [r_pts[0]],
			"waterfalls": wf_list,
			"status": "planned"
		})
		dict["features"].append({"id": "river_1", "type": "river", "status": "planned"})
	elif req_rivers == 2:
		var flows_separate = "separate" in p or "rivers_from_mountains" in intent["relationships"]
		var r1_pts = [
			Vector2(-70.0, -75.0),
			Vector2(-55.0, -20.0),
			Vector2(-40.0, 35.0),
			Vector2(-20.0, 90.0)
		]
		var r2_pts = [
			Vector2(70.0, -75.0),
			Vector2(55.0, -20.0),
			Vector2(40.0, 35.0),
			Vector2(20.0, 90.0)
		]
		dict["rivers"].append({
			"id": "river_1",
			"name": "Western Stream",
			"width": 8.0,
			"depth": 3.8,
			"flow_speed": 0.75,
			"points": r1_pts,
			"spring_sources": [r1_pts[0]],
			"waterfalls": [],
			"status": "planned"
		})
		dict["rivers"].append({
			"id": "river_2",
			"name": "Eastern Stream",
			"width": 8.0,
			"depth": 3.8,
			"flow_speed": 0.75,
			"points": r2_pts,
			"spring_sources": [r2_pts[0]],
			"waterfalls": [],
			"status": "planned"
		})
		dict["features"].append({"id": "river_1", "type": "river", "status": "planned"})
		dict["features"].append({"id": "river_2", "type": "river", "status": "planned"})
	elif req_rivers > 2:
		for r_idx in range(req_rivers):
			var r_id = "river_%d" % (r_idx + 1)
			var sx = -75.0 + (150.0 / float(req_rivers - 1)) * float(r_idx)
			var ex = sx + (float(r_idx % 2 - 0.5) * 30.0)
			var r_pts = [Vector2(sx, -80.0), Vector2(sx * 0.7, -10.0), Vector2(ex * 0.8, 40.0), Vector2(ex, 90.0)]
			dict["rivers"].append({
				"id": r_id, "name": "River Channel %d" % (r_idx + 1),
				"width": 7.5, "depth": 3.5, "flow_speed": 0.7,
				"points": r_pts, "spring_sources": [r_pts[0]], "waterfalls": [],
				"status": "planned"
			})
			dict["features"].append({"id": r_id, "type": "river", "status": "planned"})

	# Synthesize Lakes
	if req_lakes > 0:
		var lake_coords = [
			Vector2(-55.0, 25.0), Vector2(55.0, 25.0),
			Vector2(-45.0, 75.0), Vector2(45.0, 75.0),
			Vector2(0.0, 45.0), Vector2(-60.0, -30.0)
		]
		for l_idx in range(req_lakes):
			var l_id = "lake_%d" % (l_idx + 1)
			var l_pos = lake_coords[l_idx % lake_coords.size()]
			dict["lakes"].append({
				"id": l_id,
				"name": "Basin Lake %d" % (l_idx + 1),
				"x": l_pos.x,
				"z": l_pos.y,
				"radius": 32.0,
				"water_level": -1.5,
				"status": "planned"
			})
			dict["features"].append({"id": l_id, "type": "lake", "status": "planned"})

	# Flora layer
	if "forest_around_rivers" in intent["relationships"] or req_rivers > 0:
		dict["vegetation_layers"].append({
			"archetype": "canopy_tree",
			"name": "Riparian Ancient Oak",
			"distribution": "riverbank_focused",
			"near_water_only": true,
			"density": 0.015,
			"scale_min": 1.2,
			"scale_max": 2.2,
			"foliage_color": "forest green",
			"trunk_color": "saddlebrown"
		})

	return dict


func _create_fallback_from_prompt(prompt_text: String) -> Dictionary:
	var intent = parse_natural_language_intent(prompt_text)
	return _synthesize_blueprint_from_intent(intent)
