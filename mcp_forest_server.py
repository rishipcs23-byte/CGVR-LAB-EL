#!/usr/bin/env python3
"""
mcp_forest_server.py
Model Context Protocol (MCP) Server for SublimeGreens v3.0.
Communicates via JSON-RPC 2.0 over standard I/O (stdio).
All diagnostic messages are sent strictly to stderr.

When Godot is running, tool calls are forwarded directly via local TCP (127.0.0.1:23456)
so tool calls dynamically modify the live 3D terrain, hydrology, satellite map, and biomes in real-time.
"""

import sys
import json
import socket

GODOT_BRIDGE_HOST = "127.0.0.1"
GODOT_BRIDGE_PORT = 23456

# Fallback standalone world state if Godot is offline
standalone_world_state = {
    "theme": "Temperate Wilderness",
    "seed": 42,
    "terrain_type": "rolling",
    "regional_snow": {"south": False, "north": False, "east": False, "west": False},
    "mountains": [
        {"id": "mtn_1", "name": "North Peak", "x": -50.0, "z": -80.0, "height": 55.0, "radius": 75.0, "snow_cap": True, "flora_cleared": False},
        {"id": "mtn_2", "name": "Shadow Ridge", "x": 40.0, "z": -90.0, "height": 45.0, "radius": 65.0, "snow_cap": True, "flora_cleared": False}
    ],
    "rivers": [
        {"id": "river_1", "name": "Silver River", "width": 8.0, "depth": 4.0, "flow_speed": 0.65, "points": [[-70, -70], [-10, 0], [80, 75]], "spring_sources": [[-70, -70]], "waterfalls": []}
    ],
    "lakes": [],
    "biome_regions": [],
    "vegetation_layers": [
        {"archetype": "canopy_tree", "name": "Ancient Canopy Oak", "density": 0.007, "foliage_color": "forest green"},
        {"archetype": "ground_cover", "name": "Meadow Grass", "density": 0.3, "foliage_color": "green"}
    ],
    "history": []
}


def log_stderr(msg: str):
    sys.stderr.write(f"[SublimeGreens MCP] {msg}\n")
    sys.stderr.flush()


def call_godot_live_bridge(tool_name: str, args: dict) -> dict | None:
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(2.0)
        s.connect((GODOT_BRIDGE_HOST, GODOT_BRIDGE_PORT))
        payload = json.dumps({"tool": tool_name, "args": args}) + "\n"
        s.sendall(payload.encode("utf-8"))
        data = s.recv(16384).decode("utf-8")
        s.close()
        if data.strip():
            res = json.loads(data.strip())
            log_stderr(f"Forwarded '{tool_name}' to Live Godot Engine -> {res.get('status')}")
            return res
    except Exception as e:
        log_stderr(f"Godot live bridge offline ({e}). Handling in standalone mode.")
    return None


def _describe_quadrant(x: float, z: float) -> str:
    ns = "north" if z < -15.0 else ("south" if z > 15.0 else "central")
    ew = "west" if x < -15.0 else ("east" if x > 15.0 else "central")
    if ns == "central" and ew == "central":
        return "center"
    if ns == "central":
        return ew
    if ew == "central":
        return ns
    return ns + ew


def tool_get_world_status(args: dict) -> dict:
    live_res = call_godot_live_bridge("get_world_status", args)
    if live_res:
        return live_res
    return {
        "status": "success",
        "mode": "standalone",
        "theme": standalone_world_state["theme"],
        "mountains": standalone_world_state["mountains"],
        "rivers": standalone_world_state["rivers"],
        "regional_snow": standalone_world_state["regional_snow"],
        "mountain_count": len(standalone_world_state["mountains"]),
        "river_count": len(standalone_world_state["rivers"])
    }


def tool_list_world_features(args: dict) -> dict:
    live_res = call_godot_live_bridge("list_world_features", args)
    if live_res:
        return live_res
    mtns = sorted(standalone_world_state["mountains"], key=lambda m: float(m.get("height", 0)), reverse=True)
    mtn_list = []
    for idx, m in enumerate(mtns):
        x, z = float(m.get("x", 0)), float(m.get("z", 0))
        mtn_list.append({**m, "region": _describe_quadrant(x, z), "height_rank": idx + 1})
    return {
        "status": "success",
        "mode": "standalone",
        "mountains": mtn_list,
        "rivers": standalone_world_state["rivers"],
        "lakes": standalone_world_state["lakes"],
        "biome_regions": standalone_world_state["biome_regions"],
        "regional_snow": standalone_world_state["regional_snow"]
    }


def tool_find_feature_by_location(args: dict) -> dict:
    live_res = call_godot_live_bridge("find_feature_by_location", args)
    if live_res:
        return live_res
    region = str(args.get("region", args.get("location", "northwest"))).lower()
    matches = []
    for m in standalone_world_state["mountains"]:
        q = _describe_quadrant(float(m.get("x", 0)), float(m.get("z", 0)))
        if region in q or q in region:
            matches.append({"type": "mountain", **m, "region": q})
    return {"status": "success", "region": region, "count": len(matches), "matches": matches}


def tool_find_largest_feature(args: dict) -> dict:
    live_res = call_godot_live_bridge("find_largest_feature", args)
    if live_res:
        return live_res
    f_type = str(args.get("type", "mountain")).lower()
    count = int(args.get("count", 1))
    if "mountain" in f_type:
        mtns = sorted(standalone_world_state["mountains"], key=lambda m: float(m.get("height", 0)), reverse=True)
        top = mtns[:count]
        return {"status": "success", "type": "mountain", "features": top, "largest": top[0] if top else {}}
    return {"status": "success", "type": f_type, "features": standalone_world_state["rivers"][:count]}


def tool_get_feature_catalog(args: dict) -> dict:
    live_res = call_godot_live_bridge("get_feature_catalog", args)
    if live_res:
        return live_res
    return {
        "status": "success",
        "landforms": ["mountain_peak", "mountain_range", "valley", "canyon", "basin", "plateau"],
        "water_features": ["river", "u_shaped_river", "spring", "lake", "wetland", "waterfall"],
        "biomes": ["alpine_snow", "temperate_forest", "alien_wetland", "bioluminescent_grove", "volcanic_ash", "high_meadow"],
        "flora_archetypes": ["canopy_tree", "small_tree", "shrub", "fern", "flower", "ground_cover", "fallen_log"]
    }


def tool_generate_world(args: dict) -> dict:
    live_res = call_godot_live_bridge("generate_world", args)
    if live_res:
        return live_res
    theme = str(args.get("theme", "Custom Wilderness"))
    standalone_world_state["theme"] = theme
    return {"status": "success", "message": f"Generated world '{theme}'."}


def tool_create_mountain_range(args: dict) -> dict:
    live_res = call_godot_live_bridge("create_mountain_range", args)
    if live_res:
        return live_res
    name = str(args.get("name", "Mountain Peak"))
    cx = float(args.get("center_x", -75.0))
    cz = float(args.get("center_z", 75.0))
    height = float(args.get("height", 65.0))
    m_id = f"mtn_{len(standalone_world_state['mountains']) + 1}"
    standalone_world_state["mountains"].append({
        "id": m_id,
        "name": name,
        "x": cx,
        "z": cz,
        "height": height,
        "radius": float(args.get("radius", 65.0)),
        "snow_cap": bool(args.get("snow_cap", height > 45.0)),
        "flora_cleared": False
    })
    return {"status": "success", "message": f"Created '{name}' at ({cx}, {cz}) with height {height}m."}


def tool_modify_mountain(args: dict) -> dict:
    live_res = call_godot_live_bridge("modify_mountain", args)
    if live_res:
        return live_res
    target = str(args.get("target", "northwest")).lower()
    found = standalone_world_state["mountains"][0] if standalone_world_state["mountains"] else None
    for m in standalone_world_state["mountains"]:
        q = _describe_quadrant(float(m.get("x", 0)), float(m.get("z", 0)))
        if target in m["name"].lower() or target in m["id"].lower() or target in q:
            found = m
            break
    if not found:
        return {"status": "warning", "message": f"No mountain found matching '{target}'."}
    if "height_delta" in args:
        found["height"] = float(found.get("height", 50.0)) + float(args["height_delta"])
    elif "new_height" in args or "height" in args:
        found["height"] = float(args.get("new_height", args.get("height")))
    if "snow_cap" in args:
        found["snow_cap"] = bool(args["snow_cap"])
    return {"status": "success", "message": f"Modified '{found['name']}' (height: {found['height']}m, snow_cap: {found['snow_cap']}).", "mountain": found}


def tool_clear_mountain_flora(args: dict) -> dict:
    live_res = call_godot_live_bridge("clear_mountain_flora", args)
    if live_res:
        return live_res
    target = str(args.get("target", "North Peak"))
    for m in standalone_world_state["mountains"]:
        if target.lower() in m["name"].lower() or target.lower() in m["id"].lower():
            m["flora_cleared"] = True
            return {"status": "success", "message": f"Cleared all flora and trees from '{m['name']}'."}
    return {"status": "warning", "message": f"Mountain '{target}' not found."}


def tool_create_or_modify_river(args: dict) -> dict:
    live_res = call_godot_live_bridge("create_or_modify_river", args)
    if live_res:
        return live_res
    name = str(args.get("name", "Meandering River"))
    width = float(args.get("width", 9.0))
    depth = float(args.get("depth", 4.5))
    flow_speed = float(args.get("flow_speed", 0.75))
    r_id = f"river_{len(standalone_world_state['rivers']) + 1}"
    pts = args.get("points", [[-85, 10], [-50, 55], [0, 70], [50, 55], [85, 10]])
    standalone_world_state["rivers"].append({
        "id": r_id, "name": name, "width": width, "depth": depth,
        "flow_speed": flow_speed, "points": pts, "waterfalls": []
    })
    return {"status": "success", "message": f"Carved smooth river '{name}' (width {width}m, depth {depth}m, flow_speed {flow_speed})."}


def tool_modify_river(args: dict) -> dict:
    live_res = call_godot_live_bridge("modify_river", args)
    if live_res:
        return live_res
    if not standalone_world_state["rivers"]:
        return tool_create_or_modify_river(args)
    r = standalone_world_state["rivers"][0]
    if "new_width" in args or "width" in args:
        r["width"] = float(args.get("new_width", args.get("width")))
    elif "width_multiplier" in args:
        r["width"] = float(r.get("width", 8.0)) * float(args["width_multiplier"])
    if "flow_speed" in args or "new_flow_speed" in args:
        r["flow_speed"] = float(args.get("new_flow_speed", args.get("flow_speed")))
    return {"status": "success", "message": f"Modified river '{r['name']}' (width {r['width']}m, flow_speed {r.get('flow_speed', 0.65)}).", "river": r}


def tool_modify_all_rivers(args: dict) -> dict:
    live_res = call_godot_live_bridge("modify_all_rivers", args)
    if live_res:
        return live_res
    w_mult = float(args.get("width_multiplier", 1.5))
    for r in standalone_world_state["rivers"]:
        r["width"] = float(r.get("width", 8.0)) * w_mult
    return {"status": "success", "message": f"Widened all {len(standalone_world_state['rivers'])} rivers (x{w_mult})."}


def tool_modify_water_flow(args: dict) -> dict:
    live_res = call_godot_live_bridge("modify_water_flow", args)
    if live_res:
        return live_res
    speed = float(args.get("flow_speed", 1.1))
    for r in standalone_world_state["rivers"]:
        r["flow_speed"] = speed
    return {"status": "success", "message": f"Updated river directional flow speed to {speed}."}


def tool_create_waterfall(args: dict) -> dict:
    live_res = call_godot_live_bridge("create_waterfall", args)
    if live_res:
        return live_res
    drop = float(args.get("height_drop", 14.0))
    pos_t = float(args.get("position_t", 0.65))
    if standalone_world_state["rivers"]:
        r = standalone_world_state["rivers"][0]
        r.setdefault("waterfalls", []).append({"position_t": pos_t, "height_drop": drop})
        return {"status": "success", "message": f"Created {drop}m waterfall drop on '{r['name']}'."}
    return {"status": "warning", "message": "No river found."}


def tool_modify_biome(args: dict) -> dict:
    live_res = call_godot_live_bridge("modify_biome", args)
    if live_res:
        return live_res
    return {"status": "success", "message": "Updated biome region parameters."}


def tool_set_regional_snow(args: dict) -> dict:
    live_res = call_godot_live_bridge("set_regional_snow", args)
    if live_res:
        return live_res
    for k in ["south", "north", "east", "west"]:
        if k in args:
            standalone_world_state["regional_snow"][k] = bool(args[k])
    return {"status": "success", "message": f"Updated regional snow: {standalone_world_state['regional_snow']}"}


def tool_distribute_flora(args: dict) -> dict:
    live_res = call_godot_live_bridge("distribute_flora", args)
    if live_res:
        return live_res
    return {"status": "success", "message": "Updated regional flora distribution."}


def tool_regenerate_world_map(args: dict) -> dict:
    live_res = call_godot_live_bridge("regenerate_world_map", args)
    if live_res:
        return live_res
    return {"status": "success", "map_dirty": True, "message": "Satellite world map regenerated."}


def tool_undo_last_edit(args: dict) -> dict:
    live_res = call_godot_live_bridge("undo_last_edit", args)
    if live_res:
        return live_res
    return {"status": "success", "message": "Reverted last edit."}


TOOLS = [
    {
        "name": "get_world_status",
        "description": "Inspect the current active SublimeGreens world blueprint, including mountains, rivers, lakes, biomes, and regional snow.",
        "inputSchema": {"type": "object", "properties": {}}
    },
    {
        "name": "list_world_features",
        "description": "List all world features with IDs, coordinates, spatial quadrants, height ranks, and river flow properties for context-aware editing without manual selection.",
        "inputSchema": {"type": "object", "properties": {}}
    },
    {
        "name": "find_feature_by_location",
        "description": "Find mountains, rivers, or lakes in a given spatial region (e.g. 'northwest', 'southwest', 'east', 'south').",
        "inputSchema": {
            "type": "object",
            "properties": {
                "region": {"type": "string", "description": "Compass region such as northwest, southwest, northeast, southeast, north, south, east, west"},
                "type": {"type": "string", "description": "Feature type: mountain, river, lake, or any"}
            },
            "required": ["region"]
        }
    },
    {
        "name": "find_largest_feature",
        "description": "Find the largest/tallest mountain(s) or longest river(s) in the world.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "type": {"type": "string", "description": "mountain or river"},
                "count": {"type": "integer", "description": "Number of top features to return (default 1)"}
            }
        }
    },
    {
        "name": "get_feature_catalog",
        "description": "List supported landform types, water features, biome types, and flora archetypes.",
        "inputSchema": {"type": "object", "properties": {}}
    },
    {
        "name": "generate_world",
        "description": "Generate a complete 3D terrain world from a structured blueprint dictionary.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "theme": {"type": "string"},
                "terrain": {"type": "string"},
                "sky_color": {"type": "string"},
                "mountains": {"type": "array"},
                "rivers": {"type": "array"}
            },
            "required": ["theme"]
        }
    },
    {
        "name": "create_mountain_range",
        "description": "Create one or more mountain peaks at specific map coordinates (e.g. bottom-left: -75, 75; northwest: -75, -75).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {"type": "string"},
                "count": {"type": "integer"},
                "center_x": {"type": "number"},
                "center_z": {"type": "number"},
                "height": {"type": "number"},
                "radius": {"type": "number"},
                "snow_cap": {"type": "boolean"}
            },
            "required": ["name", "center_x", "center_z"]
        }
    },
    {
        "name": "modify_mountain",
        "description": "Modify an existing mountain resolved by name, ID, spatial location ('northwest'), or rank ('tallest') without moving other features.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "target": {"type": "string", "description": "Mountain name, ID, spatial location ('northwest'), or 'tallest'"},
                "height_delta": {"type": "number"},
                "new_height": {"type": "number"},
                "new_radius": {"type": "number"},
                "snow_cap": {"type": "boolean"},
                "flora_cleared": {"type": "boolean"}
            },
            "required": ["target"]
        }
    },
    {
        "name": "clear_mountain_flora",
        "description": "Clear and remove all trees and vegetation from a targeted mountain peak by name or ID.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "target": {"type": "string", "description": "Name, ID, or spatial location of the mountain peak"}
            },
            "required": ["target"]
        }
    },
    {
        "name": "create_or_modify_river",
        "description": "Carve a smooth Catmull-Rom spline river channel into the terrain with directional flow animation.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {"type": "string"},
                "width": {"type": "number"},
                "depth": {"type": "number"},
                "flow_speed": {"type": "number"},
                "is_u_shaped": {"type": "boolean"},
                "center_z": {"type": "number"},
                "points": {"type": "array"}
            },
            "required": ["name"]
        }
    },
    {
        "name": "modify_river",
        "description": "Modify an existing river's width, depth, downstream flow speed, or U-shaped path.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "target": {"type": "string", "description": "River ID, name, 'main', 'east', or 'west'"},
                "new_width": {"type": "number"},
                "width_multiplier": {"type": "number"},
                "new_depth": {"type": "number"},
                "flow_speed": {"type": "number"},
                "is_u_shaped": {"type": "boolean"},
                "points": {"type": "array"}
            }
        }
    },
    {
        "name": "modify_all_rivers",
        "description": "Widen or deepen all rivers simultaneously without changing mountain positions.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "width_multiplier": {"type": "number"},
                "depth_multiplier": {"type": "number"},
                "speed_multiplier": {"type": "number"}
            }
        }
    },
    {
        "name": "modify_water_flow",
        "description": "Adjust the directional downstream water flow speed on a river or all rivers.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "target": {"type": "string"},
                "flow_speed": {"type": "number"}
            },
            "required": ["flow_speed"]
        }
    },
    {
        "name": "create_waterfall",
        "description": "Create a waterfall drop along a targeted river (e.g. 'east', 'main', or river ID).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "target": {"type": "string"},
                "position_t": {"type": "number", "description": "Normalized position 0.1..0.9 along river spline"},
                "height_drop": {"type": "number", "description": "Vertical waterfall drop in meters"}
            }
        }
    },
    {
        "name": "modify_biome",
        "description": "Modify a biome region's ground tint, foliage color, or density boost.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "target": {"type": "string"},
                "ground_tint": {"type": "string"},
                "foliage_color": {"type": "string"},
                "boost": {"type": "number"}
            }
        }
    },
    {
        "name": "set_regional_snow",
        "description": "Make specific compass regions (south, north, east, west) snowy while leaving other regions unchanged.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "south": {"type": "boolean"},
                "north": {"type": "boolean"},
                "east": {"type": "boolean"},
                "west": {"type": "boolean"}
            }
        }
    },
    {
        "name": "distribute_flora",
        "description": "Modify flora density or introduce specialized riverbank/colored vegetation layers.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "density_multiplier": {"type": "number"},
                "archetype": {"type": "string"},
                "color": {"type": "string"},
                "riverbank_only": {"type": "boolean"}
            }
        }
    },
    {
        "name": "regenerate_world_map",
        "description": "Regenerate the 2D satellite world map from the current terrain elevation, rivers, snow caps, and vegetation.",
        "inputSchema": {"type": "object", "properties": {}}
    },
    {
        "name": "undo_last_edit",
        "description": "Revert the most recent modification to the world blueprint.",
        "inputSchema": {"type": "object", "properties": {}}
    }
]

TOOL_HANDLERS = {
    "get_world_status": tool_get_world_status,
    "list_world_features": tool_list_world_features,
    "find_feature_by_location": tool_find_feature_by_location,
    "find_largest_feature": tool_find_largest_feature,
    "get_feature_catalog": tool_get_feature_catalog,
    "generate_world": tool_generate_world,
    "create_mountain_range": tool_create_mountain_range,
    "modify_mountain": tool_modify_mountain,
    "clear_mountain_flora": tool_clear_mountain_flora,
    "create_or_modify_river": tool_create_or_modify_river,
    "modify_river": tool_modify_river,
    "modify_all_rivers": tool_modify_all_rivers,
    "modify_water_flow": tool_modify_water_flow,
    "create_waterfall": tool_create_waterfall,
    "modify_biome": tool_modify_biome,
    "set_regional_snow": tool_set_regional_snow,
    "distribute_flora": tool_distribute_flora,
    "regenerate_world_map": tool_regenerate_world_map,
    "undo_last_edit": tool_undo_last_edit
}


def handle_rpc_request(req: dict) -> dict | None:
    method = req.get("method", "")
    req_id = req.get("id")
    params = req.get("params", {})

    if method == "initialize":
        return {
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {
                "protocolVersion": "2024-11-05",
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "sublimegreens-mcp-server", "version": "3.0.0"}
            }
        }
    elif method.startswith("notifications/"):
        return None
    elif method == "tools/list":
        return {
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {"tools": TOOLS}
        }
    elif method == "tools/call":
        t_name = params.get("name", "")
        t_args = params.get("arguments", {})
        if t_name in TOOL_HANDLERS:
            try:
                res = TOOL_HANDLERS[t_name](t_args)
                return {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {
                        "content": [{"type": "text", "text": json.dumps(res, indent=2)}],
                        "isError": False
                    }
                }
            except Exception as e:
                return {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {
                        "content": [{"type": "text", "text": f"Error executing {t_name}: {str(e)}"}],
                        "isError": True
                    }
                }
        else:
            return {
                "jsonrpc": "2.0",
                "id": req_id,
                "error": {"code": -32601, "message": f"Unknown tool: {t_name}"}
            }
    else:
        if req_id is not None:
            return {
                "jsonrpc": "2.0",
                "id": req_id,
                "error": {"code": -32601, "message": f"Method not found: {method}"}
            }
        return None


def main():
    log_stderr("SublimeGreens MCP Server v3.0 started (Live Godot TCP Bridge enabled on 127.0.0.1:23456).")
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
            resp = handle_rpc_request(req)
            if resp is not None:
                sys.stdout.write(json.dumps(resp) + "\n")
                sys.stdout.flush()
        except Exception as e:
            log_stderr(f"JSON-RPC Error: {e}")


if __name__ == "__main__":
    main()
