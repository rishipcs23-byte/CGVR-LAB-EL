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
@export var request_timeout: float = 30.0

var http_request: HTTPRequest
var suggestions_http_request: HTTPRequest
var is_busy: bool = false
var current_user_prompt: String = ""
var is_edit_mode: bool = false
var selected_feature_context: Dictionary = {}

var tool_registry: WorldToolRegistry
var cached_suggestions: Array[String] = [
	"Create three mountain ranges with springs feeding two rivers that merge into one large river.",
	"Create three snowy peaks in the northwest, with two springs joining into a U-shaped river across the southern plains.",
	"Create a dense alien wetland with unusual flora clustered around several connected lakes.",
	"Imagine an alien wetland with floating root systems, crystalline ponds, and towering spiral vegetation.",
	"A crescent-shaped inland sea surrounded by dark forests and terraced basalt cliffs.",
	"Create a high-altitude meadow with sparse snowy peaks, dense flowering valleys, and waterfalls fed by glacial springs."
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
			"create_mountain_range", "modify_mountain", "create_or_modify_river",
			"modify_river", "modify_all_rivers", "modify_water_flow", "create_waterfall",
			"distribute_flora", "clear_mountain_flora", "modify_terrain_region",
			"set_biome_region", "modify_biome", "set_regional_snow",
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
	var sys_prompt = "You are a creative world-design assistant. Propose exactly 4 concise, visually evocative landscape creation prompts for an AI terrain studio. Return ONLY a JSON object with a single key 'prompts' containing an array of 4 distinct string prompts. Do not include markdown codeblocks or thinking tags."
	var payload = {
		"model": model_name,
		"messages": [
			{"role": "system", "content": sys_prompt},
			{"role": "user", "content": "Suggest 4 unique, diverse landscape concepts."}
		],
		"format": "json",
		"stream": false,
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


func generate_world(user_prompt: String) -> void:
	if is_busy:
		emit_signal("status_updated", "Architect is currently designing...")
		return
		
	is_busy = true
	is_edit_mode = false
	current_user_prompt = user_prompt
	emit_signal("started", user_prompt)
	emit_signal("status_updated", "01 — Interpreting your vision (Qwen3:4B)...")
	
	var system_prompt = """You are the SublimeGreens Creative World Architect.
Your task is to design a complete, structured 3D terrain and biome blueprint in JSON format.
Return ONLY valid JSON without markdown code fences or conversational text.

Schema:
{
  "theme": "string (e.g. Alpine Glacier Crest, Bioluminescent Xenomarch, Obsidian Rift)",
  "terrain": "alpine | mountainous | rolling | valleys | canyon | flat",
  "sky_color": "color name (e.g. violet, cyan, light blue, midnight blue, dark violet, crimson)",
  "horizon_color": "color name",
  "fog_density": 0.003,
  "fog_color": "color name",
  "light_color": "color name",
  "light_energy": 1.0,
  "terrain_tint": "color name",
  "special_event": "crystal_rain | floating_spores | fireflies | embers | none",
  "mountains": [
    {
      "id": "mtn_1",
      "name": "North Peak",
      "x": -60.0,
      "z": -80.0,
      "height": 55.0,
      "radius": 75.0,
      "snow_cap": true
    }
  ],
  "rivers": [
    {
      "id": "river_1",
      "name": "Silver Stream",
      "width": 8.0,
      "depth": 4.0,
      "flow_speed": 0.8,
      "points": [[-80, -60], [-20, -10], [30, 40], [90, 80]],
      "spring_sources": [[-80, -60]]
    }
  ],
  "lakes": [
    {
      "id": "lake_1",
      "name": "Luminous Basin",
      "x": 40.0,
      "z": 50.0,
      "radius": 35.0,
      "water_level": -1.5
    }
  ],
  "biome_regions": [
    {
      "id": "biome_1",
      "name": "Alien Grove",
      "x": 0.0,
      "z": 20.0,
      "radius": 60.0,
      "ground_tint": "purple",
      "foliage_color": "neon green",
      "boost": 1.4
    }
  ],
  "vegetation_layers": [
    {
      "archetype": "canopy_tree | small_tree | shrub | fern | flower | ground_cover | fallen_log",
      "name": "string",
      "distribution": "clustered | scattered | edge_dense | clearing_centered | riverbank_focused",
      "density": 0.008,
      "scale_min": 1.0,
      "scale_max": 2.0,
      "trunk_color": "string",
      "foliage_color": "string",
      "emissive": false,
      "min_height": 1.0,
      "max_height": 50.0,
      "max_slope": 0.85
    }
  ]
}"""

	var user_msg = "Create a world blueprint for: " + user_prompt
	_post_to_ollama(system_prompt, user_msg)


func edit_world(edit_prompt: String, selected_feature: Dictionary = {}) -> void:
	if is_busy:
		emit_signal("status_updated", "Architect is currently executing an edit...")
		return
		
	is_busy = true
	is_edit_mode = true
	current_user_prompt = edit_prompt
	selected_feature_context = selected_feature
	
	emit_signal("started", edit_prompt)
	emit_signal("status_updated", "Inspecting world registry & resolving spatial targets...")
	
	var features_info = tool_registry.execute_tool("list_world_features", {})
	var features_json = JSON.stringify({
		"mountains": features_info.get("mountains", []),
		"rivers": features_info.get("rivers", []),
		"regional_snow": features_info.get("regional_snow", {}),
		"selected_feature": selected_feature
	})
	
	var system_prompt = """You are the SublimeGreens Context-Aware Terrain Edit Agent.
You do NOT require manual user selection. Inspect the World Registry below, identify the target feature(s) by name, spatial location (northwest, southwest, east, south, etc.), or rank (tallest, largest, all rivers), and output tool operations.
If a request is genuinely ambiguous (e.g., "make that mountain taller" when no feature is selected and no direction/name is given), set "clarification_needed" to a concise question naming the candidate mountains and leave "operations" empty.

Current World Registry:
%s

Available Tools:
- modify_mountain: { target (ID, name, 'northwest', 'tallest', etc.), height_delta, new_height, new_radius, snow_cap, flora_cleared }
- create_mountain_range: { name, count, center_x, center_z, height, radius, snow_cap }
- clear_mountain_flora: { target }
- modify_river: { target (ID, name, 'main', 'east', 'west'), new_width, width_multiplier, new_depth, flow_speed, is_u_shaped, points }
- modify_all_rivers: { width_multiplier, depth_multiplier, speed_multiplier }
- modify_water_flow: { target, flow_speed }
- create_waterfall: { target ('east', 'main', or river ID), position_t (0.1..0.9), height_drop }
- create_or_modify_river: { name, width, depth, flow_speed, is_u_shaped, points: [[x, z], ...] }
- set_regional_snow: { south: bool, north: bool, east: bool, west: bool }
- set_biome_region: { name, center_x, center_z, radius, ground_tint, foliage_color, boost }
- modify_biome: { target, ground_tint, foliage_color, boost, radius_delta }
- distribute_flora: { target, density_multiplier, archetype, color, riverbank_only }
- regenerate_world_map: {}
- undo_last_edit: {}

Spatial Coordinates:
- Northwest: (-75, -75), Northeast: (75, -75), Southwest: (-75, 75), Southeast: (75, 75)
- North: (0, -75), South: (0, 75), West: (-75, 0), East: (75, 0), Center: (0, 0)

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
		"options": {
			"temperature": 0.4,
			"top_p": 0.9
		}
	}
	
	var error = http_request.request(ollama_url, ["Content-Type: application/json"], HTTPClient.METHOD_POST, JSON.stringify(payload))
	if error != OK:
		printerr("ForestArchitect: HTTPRequest failed: ", error)
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
	tool_registry.active_blueprint = bp
	emit_signal("status_updated", "World blueprint generated: " + bp.theme)
	emit_signal("blueprint_ready", bp, data_dict)


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


func _extract_json_dict(raw: String) -> Dictionary:
	var trimmed = raw.strip_edges()
	if "```" in trimmed:
		var start_idx = trimmed.find("{")
		var end_idx = trimmed.rfind("}")
		if start_idx != -1 and end_idx != -1 and end_idx > start_idx:
			trimmed = trimmed.substr(start_idx, end_idx - start_idx + 1)
			
	var parsed = JSON.parse_string(trimmed)
	if parsed is Dictionary:
		return parsed
		
	var first_brace = raw.find("{")
	var last_brace = raw.rfind("}")
	if first_brace != -1 and last_brace > first_brace:
		var sub = raw.substr(first_brace, last_brace - first_brace + 1)
		var second_attempt = JSON.parse_string(sub)
		if second_attempt is Dictionary:
			return second_attempt
			
	return {}


# Comprehensive Context-Aware Natural Language Spatial & Feature Resolver
func _create_fallback_edit(edit_prompt: String, selected_f: Dictionary) -> Dictionary:
	var p = edit_prompt.to_lower()
	var ops = []
	var expl = "Executed context-aware world modification."
	
	# Check for ambiguous pronoun reference ("that mountain", "this mountain") without spatial or name context
	if ("that mountain" in p or "this mountain" in p) and selected_f.is_empty():
		var has_dir = false
		for kw in ["north", "south", "east", "west", "tallest", "largest", "shadow", "bottom", "top", "left", "right"]:
			if kw in p:
				has_dir = true
				break
		if not has_dir and tool_registry.active_blueprint.mountains.size() > 1:
			var names = []
			for m in tool_registry.active_blueprint.mountains:
				names.append(str(m.get("name", "Peak")))
			return {
				"clarification_needed": "Multiple mountains exist (%s). Which mountain would you like to modify?" % ", ".join(names),
				"operations": []
			}

	# Case A: "Create three mountain ranges with springs feeding two rivers that merge into one large river"
	if ("three mountain" in p or "3 mountain" in p) and ("two river" in p or "merge" in p):
		ops.append({"tool": "create_mountain_range", "args": {"name": "Northwest Crest", "count": 2, "center_x": -75.0, "center_z": -85.0, "height": 68.0, "snow_cap": true}})
		ops.append({"tool": "create_mountain_range", "args": {"name": "Northeast Crest", "count": 2, "center_x": 75.0, "center_z": -85.0, "height": 64.0, "snow_cap": true}})
		ops.append({"tool": "create_mountain_range", "args": {"name": "Western Ridge", "count": 2, "center_x": -95.0, "center_z": -10.0, "height": 56.0, "snow_cap": true}})
		ops.append({"tool": "create_or_modify_river", "args": {"id": "river_west_trib", "name": "Western Spring Tributary", "width": 6.5, "depth": 3.5, "flow_speed": 0.85, "points": [[-75.0, -80.0], [-45.0, -35.0], [0.0, 0.0]], "spring_sources": [[-75.0, -80.0]]}})
		ops.append({"tool": "create_or_modify_river", "args": {"id": "river_east_trib", "name": "Eastern Spring Tributary", "width": 6.5, "depth": 3.5, "flow_speed": 0.85, "points": [[75.0, -80.0], [45.0, -35.0], [0.0, 0.0]], "spring_sources": [[75.0, -80.0]]}})
		ops.append({"tool": "create_or_modify_river", "args": {"id": "river_main", "name": "Great Confluence River", "width": 12.5, "depth": 5.0, "flow_speed": 0.95, "points": [[0.0, 0.0], [10.0, 45.0], [25.0, 95.0]], "spring_sources": [[0.0, 0.0]]}})
		return {"explanation": "Created three mountain ranges with headwater springs feeding two tributaries that merge at (0, 0) into one large river.", "operations": ops}

	# Case B: Regional snow ("Make the southern region snowy and leave the northern forest unchanged")
	if "snowy" in p and ("region" in p or "southern" in p or "south" in p or "northern" in p):
		var s_flag = "south" in p
		var n_flag = ("north" in p) and not ("unchanged" in p or "leave" in p)
		ops.append({
			"tool": "set_regional_snow",
			"args": {"south": s_flag, "north": n_flag, "enabled": true}
		})
		return {"explanation": "Applied snow cover to the southern region while preserving the northern forest.", "operations": ops}

	# Case C: Waterfall creation ("Create a waterfall where the eastern river drops into the valley" / "three additional waterfalls")
	if "waterfall" in p:
		if "three" in p or "3" in p:
			ops.append({"tool": "create_waterfall", "args": {"target": "main", "position_t": 0.30, "height_drop": 12.0}})
			ops.append({"tool": "create_waterfall", "args": {"target": "main", "position_t": 0.55, "height_drop": 15.0}})
			ops.append({"tool": "create_waterfall", "args": {"target": "main", "position_t": 0.80, "height_drop": 14.0}})
		else:
			var wf_target = "east" if "east" in p else ("west" if "west" in p else "main")
			ops.append({"tool": "create_waterfall", "args": {"target": wf_target, "position_t": 0.65, "height_drop": 16.0}})
		return {"explanation": "Created vertical waterfall cascade along the river course.", "operations": ops}

	# Case D: Riverbank vegetation ("Add dense vegetation around the riverbanks" / "Add more trees around the river" / "blue vegetation")
	if ("riverbank" in p or "around the river" in p or "along the river" in p) and ("vegetation" in p or "tree" in p or "flora" in p or "plant" in p or "dense" in p):
		var col = "cyan" if "blue" in p else ""
		var arch = "canopy_tree" if "tree" in p else "fern"
		ops.append({
			"tool": "distribute_flora",
			"args": {
				"archetype": arch,
				"color": col,
				"density_multiplier": 2.2,
				"riverbank_only": true
			}
		})
		return {"explanation": "Added dense riparian vegetation concentrated along the riverbanks.", "operations": ops}

	# Case E: All rivers wider ("Make all rivers wider without changing the mountain positions" / "Make all the rivers wider")
	if ("all river" in p or "all the river" in p) and ("wider" in p or "wide" in p):
		ops.append({
			"tool": "modify_all_rivers",
			"args": {"width_multiplier": 1.6, "depth_multiplier": 1.15}
		})
		return {"explanation": "Widened all rivers across the world while leaving all mountain positions unchanged.", "operations": ops}

	# Case F: U-shaped river & downstream animation ("Make the main river U-shaped and animate the water flowing downstream")
	if ("river" in p or "water" in p or "stream" in p) and not ("mountain" in p and not "river" in p):
		var is_u = "u-shape" in p or "u shape" in p or "loop" in p
		var wants_flow = "animate" in p or "flow" in p or "downstream" in p or "faster" in p
		var wider = "wider" in p or "wide" in p
		if is_u or wants_flow or wider:
			var r_args = {
				"target": "main",
				"is_u_shaped": is_u,
				"flow_speed": 1.25 if wants_flow else 0.85
			}
			if wider:
				r_args["width_multiplier"] = 1.5
			ops.append({"tool": "modify_river", "args": r_args})
			return {"explanation": "Reshaped main river into a smooth U-shaped channel with animated downstream flow.", "operations": ops}
		else:
			var cz = 45.0 if ("south" in p or "bottom" in p) else 0.0
			ops.append({
				"tool": "create_or_modify_river",
				"args": {
					"name": "Southern Meander" if cz > 0 else "Curving River",
					"is_u_shaped": is_u or cz > 0,
					"center_z": cz,
					"width": 9.5,
					"depth": 4.5,
					"flow_speed": 0.9
				}
			})
			return {"explanation": "Carved smooth flowing river bed across terrain.", "operations": ops}

	# Case G: Mountain modifications ("Make the northwestern mountain taller and cover its peak with snow" / "remove trees" / "create mountain in bottom left")
	if "mountain" in p or "peak" in p or "ridge" in p:
		if "remove" in p or "clear" in p or "reduce vegetation" in p:
			var target_name = "North Peak"
			if "shadow" in p: target_name = "Shadow Ridge"
			elif "northwest" in p: target_name = "northwest"
			elif not selected_f.is_empty(): target_name = selected_f.get("name", "North Peak")
			ops.append({"tool": "clear_mountain_flora", "args": {"target": target_name}})
			return {"explanation": "Cleared trees and vegetation from %s." % target_name, "operations": ops}
		elif "taller" in p or "higher" in p or "larger" in p or "bigger" in p or "snow" in p and not ("create" in p or "add" in p or "new" in p):
			var target_q = "northwest"
			if "northeast" in p or "shadow" in p: target_q = "Shadow Ridge"
			elif "southwest" in p or "bottom left" in p: target_q = "southwest"
			elif "southeast" in p or "bottom right" in p: target_q = "southeast"
			elif "tallest" in p or "largest" in p: target_q = "tallest"
			elif not selected_f.is_empty(): target_q = str(selected_f.get("id", selected_f.get("name", "northwest")))
			
			var m_args = {"target": target_q}
			if "taller" in p or "higher" in p or "larger" in p or "bigger" in p:
				m_args["height_delta"] = 24.0
			if "snow" in p:
				m_args["snow_cap"] = true
			ops.append({"tool": "modify_mountain", "args": m_args})
			return {"explanation": "Modified mountain (%s) elevation and snow cap." % target_q, "operations": ops}
		else:
			var pos = _resolve_spatial_position(p)
			var m_name = "Highland Crest"
			if pos.x < 0 and pos.y > 0: m_name = "Southwest Peak"
			elif pos.x < 0 and pos.y < 0: m_name = "Northwest Peak"
			elif pos.x > 0 and pos.y > 0: m_name = "Southeast Peak"
			elif pos.x > 0 and pos.y < 0: m_name = "Northeast Peak"
			elif pos.y > 0: m_name = "Southern Mountain"
			
			ops.append({
				"tool": "create_mountain_range",
				"args": {
					"name": m_name,
					"count": 1,
					"center_x": pos.x,
					"center_z": pos.y,
					"height": 65.0,
					"snow_cap": true
				}
			})
			return {"explanation": "Created %s at (%.0f, %.0f) with height 65m." % [m_name, pos.x, pos.y], "operations": ops}

	# Case H: Flora clearing or general density adjustment
	if "clear" in p or "remove" in p:
		var target_name = "North Peak"
		if "shadow" in p: target_name = "Shadow Ridge"
		elif not selected_f.is_empty(): target_name = selected_f.get("name", "North Peak")
		ops.append({"tool": "clear_mountain_flora", "args": {"target": target_name}})
		return {"explanation": "Cleared all trees and vegetation from %s." % target_name, "operations": ops}
		
	ops.append({
		"tool": "distribute_flora",
		"args": {"density_multiplier": 1.4}
	})
	return {
		"explanation": expl,
		"operations": ops
	}


func _resolve_spatial_position(text: String) -> Vector2:
	var t = text.to_lower()
	if "bottom left" in t or "southwest" in t or "south-west" in t or "lower left" in t:
		return Vector2(-75.0, 75.0)
	elif "bottom right" in t or "southeast" in t or "south-east" in t or "lower right" in t:
		return Vector2(75.0, 75.0)
	elif "top left" in t or "northwest" in t or "north-west" in t or "upper left" in t:
		return Vector2(-75.0, -75.0)
	elif "top right" in t or "northeast" in t or "north-east" in t or "upper right" in t:
		return Vector2(75.0, -75.0)
	elif "bottom" in t or "south" in t or "southern" in t:
		return Vector2(0.0, 75.0)
	elif "top" in t or "north" in t or "northern" in t:
		return Vector2(0.0, -75.0)
	elif "left" in t or "west" in t or "western" in t:
		return Vector2(-75.0, 0.0)
	elif "right" in t or "east" in t or "eastern" in t:
		return Vector2(75.0, 0.0)
	elif "center" in t or "middle" in t:
		return Vector2(0.0, 0.0)
	return Vector2(-75.0, 75.0)


func _create_fallback_from_prompt(prompt_text: String) -> Dictionary:
	var p = prompt_text.to_lower()
	var dict = {
		"theme": prompt_text if not prompt_text.is_empty() else "Temperate Wilderness",
		"terrain": "rolling",
		"sky_color": "light blue",
		"horizon_color": "silver",
		"light_color": "pale gold",
		"light_energy": 1.0,
		"fog_density": 0.002,
		"fog_color": "silver",
		"special_event": "none",
		"mountains": [],
		"rivers": [],
		"lakes": [],
		"biome_regions": []
	}
	
	if ("three mountain" in p or "3 mountain" in p) and ("two river" in p or "merge" in p):
		dict["theme"] = "Three Mountain Ranges & Twin River Confluence"
		dict["terrain"] = "alpine"
		dict["mountains"] = [
			{"id": "mtn_nw_1", "name": "Northwest Range Alpha", "x": -80.0, "z": -85.0, "height": 68.0, "radius": 70.0, "snow_cap": true},
			{"id": "mtn_nw_2", "name": "Northwest Range Beta", "x": -45.0, "z": -95.0, "height": 62.0, "radius": 65.0, "snow_cap": true},
			{"id": "mtn_ne_1", "name": "Northeast Range Alpha", "x": 75.0, "z": -85.0, "height": 64.0, "radius": 70.0, "snow_cap": true},
			{"id": "mtn_ne_2", "name": "Northeast Range Beta", "x": 45.0, "z": -95.0, "height": 58.0, "radius": 60.0, "snow_cap": true},
			{"id": "mtn_w_1", "name": "Western Highland Crest", "x": -95.0, "z": -15.0, "height": 56.0, "radius": 65.0, "snow_cap": true}
		]
		dict["mountain_ranges"] = [
			{"id": "range_nw", "name": "Northwest Range", "peak_ids": ["mtn_nw_1", "mtn_nw_2"]},
			{"id": "range_ne", "name": "Northeast Range", "peak_ids": ["mtn_ne_1", "mtn_ne_2"]},
			{"id": "range_w", "name": "Western Range", "peak_ids": ["mtn_w_1"]}
		]
		dict["rivers"] = [
			{
				"id": "river_west_trib",
				"name": "Western Headwater Stream",
				"width": 6.5,
				"depth": 3.5,
				"flow_speed": 0.85,
				"points": [[-75.0, -80.0], [-40.0, -35.0], [0.0, 0.0]],
				"spring_sources": [[-75.0, -80.0]]
			},
			{
				"id": "river_east_trib",
				"name": "Eastern Headwater Stream",
				"width": 6.5,
				"depth": 3.5,
				"flow_speed": 0.85,
				"points": [[75.0, -80.0], [40.0, -35.0], [0.0, 0.0]],
				"spring_sources": [[75.0, -80.0]]
			},
			{
				"id": "river_main",
				"name": "Great Confluence River",
				"width": 12.5,
				"depth": 5.0,
				"flow_speed": 0.95,
				"points": [[0.0, 0.0], [10.0, 45.0], [25.0, 95.0]],
				"spring_sources": [[0.0, 0.0]]
			}
		]
	elif "three" in p and "peak" in p or ("snowy" in p and "northwest" in p):
		dict["theme"] = "Northwest Alpine Peaks & Southern Meander"
		dict["terrain"] = "alpine"
		dict["sky_color"] = "light blue"
		dict["horizon_color"] = "white"
		dict["fog_density"] = 0.0025
		dict["mountains"] = [
			{"id": "mtn_nw_1", "name": "Northwest Peak Alpha", "x": -90.0, "z": -90.0, "height": 68.0, "radius": 70.0, "snow_cap": true, "flora_cleared": false},
			{"id": "mtn_nw_2", "name": "Northwest Peak Beta", "x": -50.0, "z": -110.0, "height": 62.0, "radius": 65.0, "snow_cap": true, "flora_cleared": false},
			{"id": "mtn_nw_3", "name": "Northwest Peak Gamma", "x": -20.0, "z": -75.0, "height": 58.0, "radius": 60.0, "snow_cap": true, "flora_cleared": false}
		]
		dict["rivers"] = [
			{
				"id": "river_u_loop",
				"name": "Glacial Confluence River",
				"width": 9.0,
				"depth": 4.5,
				"flow_speed": 0.85,
				"points": [
					[-80.0, -80.0],
					[-50.0, -20.0],
					[-70.0, 30.0],
					[0.0, 65.0],
					[70.0, 30.0],
					[90.0, -10.0]
				],
				"spring_sources": [[-90.0, -90.0], [-50.0, -110.0]]
			}
		]
	elif "alien" in p and "wetland" in p or ("wetland" in p and "lake" in p):
		dict["theme"] = "Alien Bioluminescent Wetland"
		dict["terrain"] = "valleys"
		dict["sky_color"] = "deep blue"
		dict["horizon_color"] = "neon green"
		dict["fog_density"] = 0.006
		dict["fog_color"] = "neon green"
		dict["light_color"] = "cyan"
		dict["light_energy"] = 0.75
		dict["special_event"] = "floating_spores"
		dict["lakes"] = [
			{"id": "lake_1", "name": "Lagoon Primus", "x": -30.0, "z": 20.0, "radius": 42.0, "water_level": -1.2},
			{"id": "lake_2", "name": "Lagoon Secundus", "x": 35.0, "z": 45.0, "radius": 38.0, "water_level": -1.2}
		]
		dict["rivers"] = [
			{
				"id": "river_wetland_channel",
				"name": "Interlake Channel",
				"width": 11.0,
				"depth": 3.0,
				"flow_speed": 0.55,
				"points": [[-30.0, 20.0], [5.0, 32.0], [35.0, 45.0]]
			}
		]
		dict["biome_regions"] = [
			{
				"id": "biome_wetland",
				"name": "Xenomarch Core",
				"x": 0.0,
				"z": 30.0,
				"radius": 80.0,
				"ground_tint": "purple",
				"foliage_color": "neon green",
				"boost": 1.6
			}
		]
	else:
		dict["mountains"] = [
			{"id": "mtn_1", "name": "North Peak", "x": -50.0, "z": -80.0, "height": 55.0, "radius": 75.0, "snow_cap": true, "flora_cleared": false},
			{"id": "mtn_2", "name": "Shadow Ridge", "x": 40.0, "z": -90.0, "height": 45.0, "radius": 65.0, "snow_cap": true, "flora_cleared": false}
		]
		dict["rivers"] = [
			{
				"id": "river_main",
				"name": "Silver River",
				"width": 8.0,
				"depth": 3.5,
				"flow_speed": 0.65,
				"points": [[-70.0, -70.0], [-40.0, -30.0], [-10.0, 0.0], [25.0, 35.0], [80.0, 75.0]],
				"spring_sources": [[-70.0, -70.0]]
			}
		]
	return dict
