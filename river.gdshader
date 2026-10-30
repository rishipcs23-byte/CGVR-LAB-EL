shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled, diffuse_burley, specular_schlick_ggx;

// River Directional Flow & Water Surface Shader
uniform vec4 shallow_color : source_color = vec4(0.18, 0.65, 0.85, 0.85);
uniform vec4 deep_color : source_color = vec4(0.04, 0.22, 0.45, 0.95);
uniform vec4 foam_color : source_color = vec4(0.92, 0.96, 1.0, 1.0);
uniform float flow_speed : hint_range(0.0, 5.0) = 0.65;
uniform float wave_scale : hint_range(0.1, 20.0) = 4.0;
uniform float normal_strength : hint_range(0.0, 2.0) = 0.85;
uniform float roughness : hint_range(0.0, 1.0) = 0.08;
uniform float metallic : hint_range(0.0, 1.0) = 0.15;
uniform float foam_threshold : hint_range(0.0, 1.0) = 0.65;
uniform float waterfall_intensity : hint_range(0.0, 2.0) = 0.0;

// Textures
uniform sampler2D flow_normal_texture : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D foam_noise_texture : hint_default_white, filter_linear_mipmap, repeat_enable;

varying float v_slope;
varying vec2 v_spline_uv;

void vertex() {
	// UV.y is along river spline (downstream), UV.x is across river (0 to 1)
	v_spline_uv = UV;
	
	// Compute vertical slope along river segment to detect waterfall zones
	vec3 world_normal = (MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz;
	v_slope = 1.0 - clamp(abs(world_normal.y), 0.0, 1.0);
	
	// Subtle vertex ripple displacement
	float wave = sin(UV.y * 12.0 - TIME * flow_speed * 6.0) * cos(UV.x * 6.0);
	VERTEX.y += wave * 0.04;
}

void fragment() {
	// Downstream scrolling coordinates along river curve
	float downstream_time = TIME * flow_speed;
	vec2 uv_flow1 = vec2(v_spline_uv.x * 2.0, v_spline_uv.y * wave_scale - downstream_time);
	vec2 uv_flow2 = vec2(v_spline_uv.x * 3.0 + 0.35, v_spline_uv.y * (wave_scale * 1.5) - downstream_time * 1.35);
	
	// Bank proximity (0 at center, 1 at riverbanks)
	float bank_dist = abs(v_spline_uv.x - 0.5) * 2.0;
	
	// Fast flow in steep waterfall sections
	float effective_slope = max(v_slope, waterfall_intensity);
	if (effective_slope > 0.25) {
		float waterfall_mult = 1.0 + effective_slope * 2.5;
		uv_flow1.y -= TIME * flow_speed * waterfall_mult;
		uv_flow2.y -= TIME * flow_speed * waterfall_mult;
	}
	
	// Procedural normal mapping
	vec3 n1 = vec3(0.0, 0.0, 1.0);
	vec3 n2 = vec3(0.0, 0.0, 1.0);
	
	// Procedural ripple normals using analytical derivatives
	float w1 = sin(uv_flow1.y * 6.28 + uv_flow1.x * 3.14);
	float w2 = cos(uv_flow2.y * 9.42 - uv_flow2.x * 4.71);
	vec3 wave_normal = normalize(vec3(-w1 * 0.15 + w2 * 0.1, -w1 * 0.2 - w2 * 0.25, 1.0));
	
	NORMAL = normalize(mix(NORMAL, wave_normal, normal_strength));
	
	// Riverbed depth gradient & bank blending
	float depth_factor = clamp(1.0 - pow(bank_dist, 2.5), 0.0, 1.0);
	vec4 water_col = mix(shallow_color, deep_color, depth_factor);
	
	// Foam generation along riverbanks and turbulent waterfall drops
	float foam_noise = sin(uv_flow1.y * 10.0 + uv_flow1.x * 5.0) * cos(uv_flow2.y * 8.0);
	float bank_foam = smoothstep(0.72, 0.98, bank_dist + foam_noise * 0.12);
	float slope_foam = smoothstep(0.28, 0.75, effective_slope + foam_noise * 0.15);
	float total_foam = clamp(bank_foam + slope_foam * 1.2, 0.0, 1.0);
	
	vec3 final_color = mix(water_col.rgb, foam_color.rgb, total_foam);
	
	ALBEDO = final_color;
	ROUGHNESS = mix(roughness, 0.45, total_foam);
	METALLIC = mix(metallic, 0.0, total_foam);
	SPECULAR = 0.65;
	ALPHA = mix(water_col.a, 0.98, total_foam);
}

