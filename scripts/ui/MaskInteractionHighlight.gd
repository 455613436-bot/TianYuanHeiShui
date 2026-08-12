extends TextureRect
class_name MaskInteractionHighlight
## 通用遮罩交互高亮：以遮罩的透明通道绘制外轮廓与内部染色。

@export var highlight_color := Color(0.28, 0.86, 1.0, 1.0)
@export_range(0.0, 1.0, 0.01) var fill_opacity := 0.24
@export_range(1.0, 12.0, 1.0) var outline_width := 3.0

var _highlight_shader: Shader
var _highlight_material: ShaderMaterial


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	stretch_mode = TextureRect.STRETCH_SCALE
	if texture != null:
		_apply_highlight_material()
	visible = false


func configure(mask_texture: Texture2D, color: Color = Color(0.28, 0.86, 1.0, 1.0), opacity: float = 0.46, width: float = 3.0) -> void:
	texture = mask_texture
	highlight_color = color
	fill_opacity = clampf(opacity, 0.0, 1.0)
	outline_width = maxf(width, 1.0)
	_apply_highlight_material()
	visible = false


func show_highlight() -> void:
	visible = true


func hide_highlight() -> void:
	visible = false


func _apply_highlight_material() -> void:
	if texture == null:
		return
	if _highlight_shader == null:
		_highlight_shader = Shader.new()
		_highlight_shader.code = """
shader_type canvas_item;

uniform vec4 highlight_color : source_color;
uniform float fill_opacity : hint_range(0.0, 1.0) = 0.24;
uniform float outline_width : hint_range(1.0, 12.0) = 3.0;

void fragment() {
	vec4 mask_pixel = texture(TEXTURE, UV);
	float alpha = mask_pixel.a;
	vec2 sample_offset = TEXTURE_PIXEL_SIZE * outline_width;
	float nearby_alpha = max(
		max(texture(TEXTURE, UV + vec2(sample_offset.x, 0.0)).a, texture(TEXTURE, UV - vec2(sample_offset.x, 0.0)).a),
		max(texture(TEXTURE, UV + vec2(0.0, sample_offset.y)).a, texture(TEXTURE, UV - vec2(0.0, sample_offset.y)).a)
	);
	nearby_alpha = max(nearby_alpha, max(
		max(texture(TEXTURE, UV + sample_offset).a, texture(TEXTURE, UV - sample_offset).a),
		max(texture(TEXTURE, UV + vec2(sample_offset.x, -sample_offset.y)).a, texture(TEXTURE, UV + vec2(-sample_offset.x, sample_offset.y)).a)
	));
	float outer_outline = (1.0 - alpha) * nearby_alpha;
	vec3 tinted_door = mix(mask_pixel.rgb, highlight_color.rgb, 0.45);
	vec4 fill = vec4(tinted_door, alpha * fill_opacity);
	COLOR = vec4(mix(fill.rgb, vec3(1.0), outer_outline), max(fill.a, outer_outline));
}
"""
	if _highlight_material == null:
		_highlight_material = ShaderMaterial.new()
		_highlight_material.shader = _highlight_shader
	material = _highlight_material
	_highlight_material.set_shader_parameter("highlight_color", highlight_color)
	_highlight_material.set_shader_parameter("fill_opacity", fill_opacity)
	_highlight_material.set_shader_parameter("outline_width", outline_width)
