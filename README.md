# SublimeGreens — AI-Assisted Terrain Builder

> **"SublimeGreens — AI-assisted terrain builder. Unlimited combinations of biomes. Feel like a creator."**

SublimeGreens evolves procedural terrain generation into a creative, collaborative world-shaping experience powered by local creative AI (`qwen3:4b` via Ollama), a live TCP Model Context Protocol (MCP) bridge, and Godot 4.4 Forward+.

---

## 🌟 Key Features

1. **Realistic River Hydrology & Directional Flow Animation (`river.gdshader`)**:
   - **Catmull-Rom Spline Subdivision**: Rivers follow smooth hydraulic curves with parabolic channel excavation and cosine bank transitions (`ForestBlueprint.build_river_spline_data()`).
   - **Downstream Flow Shader**: `river.gdshader` uses arc-length UV coordinates (`UV.y` along flow path, `UV.x` across banks) to animate directional downstream currents, riverbank foam, depth gradients, and turbulent waterfall cascades.
   - **Tributaries & Waterfalls**: Supports headwater springs, merging tributaries, variable river widths/depths, and vertical waterfall drops (`create_waterfall`).

2. **Satellite-Style 2D World Map (`SatelliteMapRenderer.gd` & `WorldMap.gd`)**:
   - Procedurally rendered directly from the live world heightfield, river splines, lakes, snow caps, regional snow masks, and vegetation layers (~170 ms for 180×180 resolution).
   - Directional NW hillshading, hypsometric elevation coloring, forest canopy clustering, cleared-peak bare rock exposure, waterfall markers, and topographic contour lines.
   - Automatically regenerates whenever the AI or MCP server modifies the world.

3. **Context-Aware AI Editing Without Manual Selection (`ForestArchitect.gd` & `WorldToolRegistry.gd`)**:
   - No manual clicking required: the AI inspects the live World Registry (`list_world_features`, `find_feature_by_location`, `find_largest_feature`) and resolves spatial references (`"northwest"`, `"bottom left"`, `"eastern river"`, `"southern region"`), feature names (`"North Peak"`), or ranks (`"tallest mountain"`, `"all rivers"`).
   - Ambiguity Detection: If an instruction is genuinely ambiguous (e.g., *"Make that mountain taller"* when multiple peaks exist and none is selected), the agent asks for clarification rather than guessing.
   - Non-destructive undo history stack (`[UNDO]` button or `undo_last_edit`).

4. **Model Context Protocol (MCP) Server v3.0 (`mcp_forest_server.py`)**:
   - Implements JSON-RPC 2.0 over stdio and bridges directly to the running Godot engine via TCP (`127.0.0.1:23456`).
   - Exposes 16 tools: `get_world_status`, `list_world_features`, `find_feature_by_location`, `find_largest_feature`, `get_feature_catalog`, `generate_world`, `create_mountain_range`, `modify_mountain`, `clear_mountain_flora`, `create_or_modify_river`, `modify_river`, `modify_all_rivers`, `modify_water_flow`, `create_waterfall`, `modify_biome`, `set_regional_snow`, `distribute_flora`, `regenerate_world_map`, and `undo_last_edit`.

---

## 🚀 Quick Start & How to Run

### 1. Launching in Godot 4.4
```powershell
& "C:\Users\rishi\Desktop\CGVR\Godot_v4.4-stable_win64.exe\Godot_v4.4-stable_win64_console.exe" --path "C:\Users\rishi\Desktop\CGVR\Godot-3D-Infinite-Procedural-Terrain-With-Trees-and-Grass"
```

### 2. Running the Automated Acceptance Suite (Headless)
```powershell
& "C:\Users\rishi\Desktop\CGVR\Godot_v4.4-stable_win64.exe\Godot_v4.4-stable_win64_console.exe" --headless --path "C:\Users\rishi\Desktop\CGVR\Godot-3D-Infinite-Procedural-Terrain-With-Trees-and-Grass" -s validate_sublimegreens.gd
```

---

## 🎮 Controls

| Key | Action |
| :--- | :--- |
| **W, A, S, D** | Move player character |
| **Mouse Motion** | Look around (1st person view) |
| **Shift** | Sprint |
| **Space** | Jump |
| **M** | Toggle Satellite 2D World Map (Minimap $\leftrightarrow$ Expanded Survey) |
| **T / `** | Focus conversational AI World Edit bar |
| **Esc** | Close expanded map / release focus to explorer |

---

## 🧪 Validated Natural-Language Prompts & Edits

1. *"Create three mountain ranges with springs feeding two rivers that merge into one large river."*
2. *"Make the main river U-shaped and animate the water flowing downstream."*
3. *"Make the northwestern mountain taller and cover its peak with snow."*
4. *"Add dense vegetation around the riverbanks."*
5. *"Make all rivers wider without changing the mountain positions."*
6. *"Create a waterfall where the eastern river drops into the valley."*
7. *"Make the southern region snowy and leave the northern forest unchanged."*
