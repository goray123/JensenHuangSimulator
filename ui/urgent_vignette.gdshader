shader_type canvas_item;
// Red edge glow for the last seconds of a round; the HUD tweens `intensity` once per second.

uniform vec4 tint : source_color = vec4(0.95, 0.05, 0.08, 1.0);
uniform float intensity : hint_range(0.0, 1.0) = 0.0;

void fragment() {
	// 0 at the centre, 1 at the middle of each edge, about 1.41 in the corners.
	float edge = length((UV - 0.5) * 2.0);
	COLOR = vec4(tint.rgb, tint.a * intensity * smoothstep(0.6, 1.35, edge));
}
