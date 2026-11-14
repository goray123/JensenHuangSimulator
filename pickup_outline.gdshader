shader_type spatial;
render_mode unshaded, cull_front, shadows_disabled, world_vertex_coords;

uniform vec4 outline_color : source_color = vec4(0.04, 0.4, 1.0, 1.0);
uniform float outline_width = 0.035;

void vertex() {
	// World-space extrusion keeps the border consistent on scaled props.
	VERTEX += normalize(NORMAL) * outline_width;
}

void fragment() {
	ALBEDO = outline_color.rgb;
}
