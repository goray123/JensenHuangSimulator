shader_type spatial;

uniform float surface_roughness : hint_range(0.0, 1.0) = 0.62;
uniform float surface_specular : hint_range(0.0, 1.0) = 0.25;

vec3 vertex_linear_to_srgb(vec3 value) {
	vec3 low = value * 12.92;
	vec3 high = 1.055 * pow(max(value, vec3(0.0)), vec3(1.0 / 2.4)) - 0.055;
	return mix(low, high, step(vec3(0.0031308), value));
}

void fragment() {
	ALBEDO = OUTPUT_IS_SRGB ? vertex_linear_to_srgb(COLOR.rgb) : COLOR.rgb;
	ROUGHNESS = surface_roughness;
	SPECULAR = surface_specular;
}
