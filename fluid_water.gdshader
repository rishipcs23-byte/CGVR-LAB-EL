shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_disabled, diffuse_burley, specular_schlick_ggx;

// Physically Based Fluid Simulation Water Shader
// Directly driven by Shallow Water Equations (SWE) state fields:
// Depth (h), Velocity (u, v), Speed, and Hydraulic Foam.

uniform vec4 shallow_color : source_color = vec4(0.12, 0.65, 0.78, 0.82);
uniform vec4 deep_color : source_color = vec4(0.02, 0.18, 0.42, 0.94);
uniform vec4 foam_color : source_color = vec4(0.95, 0.98, 1.0, 1.0);

uniform float max_depth_ref : hint_range(0.5, 30.0) = 8.0;
uniform float foam_speed_threshold : hint_range(0.2, 10.0) = 1.8;
uniform float wave_ripple_scale : hint_range(1.0, 50.0) = 16.0;
uniform float normal_strength : hint_range(0.0, 2.0) = 0.75;
uniform float roughness : hint_range(0.0, 1.0) = 0.05;
uniform float metallic : hint_range(0.0, 1.0) = 0.12;

// SWE Simulation Textures
uniform sampler2D depth_texture : hint_default_black, filter_linear;
uniform sampler2D elevation_texture : hint_default_black, filter_linear;
uniform sampler2D vel_u_texture : hint_default_black, filter_linear;
uniform sampler2D vel_v_texture : hint_default_black, filter_linear;
uniform sampler2D velocity_texture : hint_default_black, filter_linear; // Backward compatibility

varying vec2 v_uv;
varying vec3 v_world_pos;

void vertex() {
	v_uv = UV;
	float surface_y = textureLod(elevation_texture, UV, 0.0).r;
	VERTEX.y = surface_y;
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	// Sample SWE depth and velocity fields
	float h = texture(depth_texture, v_uv).r;
	float u = texture(vel_u_texture, v_uv).r;
	float v = texture(vel_v_texture, v_uv).r;
	vec2 vel = vec2(u, v);
	float speed = length(vel);
	
	// If cell is virtually dry, discard fragment so terrain underneath is cleanly visible
	if (h < 0.005) {
		discard;
	}
	
	// Normalize depth factor
	float depth_ratio = clamp(h / max_depth_ref, 0.0, 1.0);
	vec4 base_water = mix(shallow_color, deep_color, depth_ratio);
	
	// Animate ripples along the actual SWE velocity direction
	vec2 flow_dir = (speed > 0.05) ? normalize(vel) : vec2(0.707, 0.707);
	float flow_time = TIME * clamp(speed * 0.8, 0.25, 3.5);
	
	vec2 uv_flow1 = v_uv * wave_ripple_scale - flow_dir * flow_time;
	vec2 uv_flow2 = v_uv * (wave_ripple_scale * 1.4) + vec2(-flow_dir.y, flow_dir.x) * (flow_time * 0.6);
	
	float w1 = sin(uv_flow1.x * 6.28 + uv_flow1.y * 3.14);
	float w2 = cos(uv_flow2.x * 8.0 - uv_flow2.y * 4.0);
	vec3 ripple_normal = normalize(vec3(-w1 * 0.15 + w2 * 0.08, -w1 * 0.1 - w2 * 0.18, 1.0));
	
	NORMAL = normalize(mix(NORMAL, ripple_normal, normal_strength));
	
	// Foam calculation: triggers in high velocity rapids, spillways, and steep drops
	float speed_foam = smoothstep(foam_speed_threshold, foam_speed_threshold * 2.2, speed);
	float shallow_foam = smoothstep(0.12, 0.01, h); // Edge shoreline foam
	float foam_pattern = sin(uv_flow1.x * 12.0 + flow_time * 4.0) * cos(uv_flow2.y * 10.0);
	float foam_factor = clamp((speed_foam * 1.2 + shallow_foam * 0.5) * (0.8 + foam_pattern * 0.2), 0.0, 1.0);
	
	vec3 final_albedo = mix(base_water.rgb, foam_color.rgb, foam_factor);
	
	ALBEDO = final_albedo;
	ROUGHNESS = mix(roughness, 0.5, foam_factor);
	METALLIC = mix(metallic, 0.0, foam_factor);
	SPECULAR = 0.7;
	ALPHA = mix(base_water.a, 0.98, foam_factor);
}

