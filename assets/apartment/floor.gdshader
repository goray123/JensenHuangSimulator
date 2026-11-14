shader_type spatial;

uniform vec4 floor_color : source_color = vec4(0.74, 0.625, 0.49, 1.0);
uniform vec2 plank_size = vec2(2.25, 0.48);
uniform float row_offset = 0.5;
uniform float color_variation = 0.08;

varying vec2 floor_position;

void vertex() {
	floor_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
}

void fragment() {
	vec2 cell = floor_position / plank_size;
	cell.x += mod(floor(cell.y), 2.0) * row_offset;
	vec2 local_position = fract(cell);
	vec2 edge = min(local_position, 1.0 - local_position) * plank_size;
	float distance_to_edge = min(edge.x, edge.y);
	float joint = 1.0 - smoothstep(0.006, 0.006 + fwidth(distance_to_edge) + 0.001, distance_to_edge);
	float shade = fract(sin(dot(floor(cell), vec2(127.1, 311.7))) * 43758.5453) - 0.5;

	ALBEDO = floor_color.rgb * (1.0 + color_variation * shade - 0.15 * joint);
	ROUGHNESS = 0.94;
}
