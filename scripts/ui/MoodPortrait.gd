extends RefCounted
class_name MoodPortrait
## MoodPortrait
## NPC 表情差分工具。
## - normalize_mood(): 把 LLM 或本地启发式给出的字符串归一化为 3 种 canonical mood
## - detect_mood_from_text(): 关键词/标点启发式，用于 LLM 未输出 mood 时兜底
## - get_placeholder_texture(): 生成一张写着"开心/思考/惊讶"字样的占位贴图；
##   等真正的立绘 PNG 画好之后，直接换用 get_texture_for_npc() 从磁盘读取即可。

const MOOD_HAPPY := "happy"
const MOOD_THINKING := "thinking"
const MOOD_SURPRISED := "surprised"
const MOOD_WEARY := "weary"
const DEFAULT_MOOD := MOOD_HAPPY

## 全局 3 种 canonical mood（兜底用）；NPC 可通过数据文件 mood_map 扩展
const GLOBAL_CANONICAL_MOODS: Array[String] = [MOOD_HAPPY, MOOD_THINKING, MOOD_SURPRISED]

## LLM 输出 mood 的中文/英文别名（全局兜底）
const _ALIASES := {
	"happy": MOOD_HAPPY,
	"joy": MOOD_HAPPY,
	"joyful": MOOD_HAPPY,
	"cheerful": MOOD_HAPPY,
	"smile": MOOD_HAPPY,
	"smiling": MOOD_HAPPY,
	"pleased": MOOD_HAPPY,
	"开心": MOOD_HAPPY,
	"高兴": MOOD_HAPPY,
	"愉快": MOOD_HAPPY,
	"欢喜": MOOD_HAPPY,
	"喜悦": MOOD_HAPPY,
	"友好": MOOD_HAPPY,

	"thinking": MOOD_THINKING,
	"pondering": MOOD_THINKING,
	"contemplative": MOOD_THINKING,
	"hesitant": MOOD_THINKING,
	"neutral": MOOD_THINKING,
	"calm": MOOD_THINKING,
	"思考": MOOD_THINKING,
	"沉思": MOOD_THINKING,
	"犹豫": MOOD_THINKING,
	"迟疑": MOOD_THINKING,
	"平静": MOOD_THINKING,

	"surprised": MOOD_SURPRISED,
	"shocked": MOOD_SURPRISED,
	"astonished": MOOD_SURPRISED,
	"startled": MOOD_SURPRISED,
	"惊讶": MOOD_SURPRISED,
	"震惊": MOOD_SURPRISED,
	"吃惊": MOOD_SURPRISED,
	"意外": MOOD_SURPRISED,
	"愕然": MOOD_SURPRISED,

	"weary": MOOD_WEARY,
	"exhausted": MOOD_WEARY,
	"tired": MOOD_WEARY,
	"忧惧": MOOD_WEARY,
	"疲惫": MOOD_WEARY,
	"忧虑": MOOD_WEARY,
	"憔悴": MOOD_WEARY,
}

## 关键词到 mood 的映射，用于本地兜底判定
const _KEYWORD_HINTS := {
	MOOD_SURPRISED: [
		"！", "?！", "！？", "咦", "哎呀", "天哪", "老天", "什么？", "什么?！",
		"竟然", "居然", "怎么会", "不会吧", "真的假的", "真的吗", "警觉",
	],
	MOOD_THINKING: [
		"……", "唔", "嗯——", "让我想想", "这个嘛", "或许", "也许", "似乎",
		"我想想", "得想想", "怎么说", "不好说", "难说", "让我看看", "掂量",
		"(", "（", "沉思", "犹豫", "游离", "低语",
	],
	MOOD_HAPPY: [
		"哈哈", "呵呵", "嘿嘿", "哟", "欢迎", "好啊", "太好了", "真好",
		"客气", "请坐", "自便", "尽管", "掩饰", "笑意",
	],
	MOOD_WEARY: [
		"叹", "累", "疲惫", "忧惧", "憔悴", "力竭", "撑不住", "苍老",
		"叹息", "唉", "罢了",
	],
}

## 每个 NPC 自定义的 mood 映射缓存：npc_id -> {alias: mood_file_name}
static var _npc_mood_maps: Dictionary = {}
## 每个 NPC 可用的 canonical mood 列表缓存：npc_id -> Array[String]
static var _npc_mood_lists: Dictionary = {}


static func canonical_moods() -> Array[String]:
	return [MOOD_HAPPY, MOOD_THINKING, MOOD_SURPRISED, MOOD_WEARY]


## 返回某 NPC 可用的 mood 列表：优先 NPC 数据里的 mood_map 的 values，
## 没有则返回全局 3 种。
static func moods_for_npc(npc_id: String) -> Array[String]:
	if npc_id == "":
		return GLOBAL_CANONICAL_MOODS.duplicate()
	_ensure_npc_mood_map_loaded(npc_id)
	if _npc_mood_lists.has(npc_id):
		return (_npc_mood_lists[npc_id] as Array[String]).duplicate()
	return GLOBAL_CANONICAL_MOODS.duplicate()


## 把任意字符串规范化为 canonical mood；无法识别返回空串。
## 优先查 NPC 自己的 mood_map，没有再走全局别名表。
static func normalize_mood(raw: String, npc_id: String = "") -> String:
	if raw == null:
		return ""
	var key := raw.strip_edges().to_lower()
	if key == "":
		return ""
	# 1. NPC 自定义 mood_map（含该 NPC 特有的 mood，如 weary）
	if npc_id != "":
		_ensure_npc_mood_map_loaded(npc_id)
		var npc_map: Dictionary = _npc_mood_maps.get(npc_id, {})
		if not npc_map.is_empty():
			# 先精确匹配原始 key（保留中文）
			var raw_trim := raw.strip_edges()
			if npc_map.has(raw_trim):
				return String(npc_map[raw_trim])
			if npc_map.has(key):
				return String(npc_map[key])
	# 2. 全局别名表
	if _ALIASES.has(key):
		return _ALIASES[key]
	var raw_trim := raw.strip_edges()
	if _ALIASES.has(raw_trim):
		return _ALIASES[raw_trim]
	return ""


## 根据 NPC 正文做启发式匹配；若都不命中，返回 DEFAULT_MOOD。
## npc_id 用于决定该 NPC 可用的 mood 集合（如林德山有 weary）
static func detect_mood_from_text(text: String, npc_id: String = "") -> String:
	if text == null or text.strip_edges() == "":
		return DEFAULT_MOOD
	# 优先级：surprised > weary > thinking > happy（强烈情绪先判）
	var ordered: Array[String] = [MOOD_SURPRISED, MOOD_WEARY, MOOD_THINKING, MOOD_HAPPY]
	# 若该 NPC 不支持 weary，跳过
	if npc_id != "" and not moods_for_npc(npc_id).has(MOOD_WEARY):
		ordered.erase(MOOD_WEARY)
	for mood in ordered:
		var keywords: Array = _KEYWORD_HINTS.get(mood, [])
		for kw in keywords:
			if text.contains(String(kw)):
				return mood
	return DEFAULT_MOOD


## 决定最终 mood：LLM 输出优先，其次关键词兜底
static func resolve_mood(llm_mood_raw: String, npc_text: String, npc_id: String = "") -> String:
	var normalized := normalize_mood(llm_mood_raw, npc_id)
	if normalized != "":
		return normalized
	return detect_mood_from_text(npc_text, npc_id)


## 占位贴图缓存：cache_key(mood + size + npc_hue_index) -> ImageTexture
static var _placeholder_cache: Dictionary = {}
## 磁盘查找结果缓存：path -> Texture2D or null（避免每次 mood 切换都反复 ResourceLoader.exists）
static var _disk_cache: Dictionary = {}

## 占位色系（真图画好之前先用色块）
## 每个 mood 都有一个"色相偏移"数组，不同 NPC 会走到不同的偏移，使得视觉上能区分 NPC
const _PLACEHOLDER_STYLE := {
	MOOD_HAPPY:     {"bg": Color(0.98, 0.76, 0.35), "fg": Color(0.15, 0.08, 0.02), "label": "开心"},
	MOOD_THINKING:  {"bg": Color(0.42, 0.55, 0.72), "fg": Color(0.95, 0.95, 0.98), "label": "思考"},
	MOOD_SURPRISED: {"bg": Color(0.88, 0.42, 0.55), "fg": Color(0.98, 0.96, 0.90), "label": "惊讶"},
	MOOD_WEARY:     {"bg": Color(0.45, 0.40, 0.35), "fg": Color(0.92, 0.88, 0.80), "label": "疲惫"},
}


## 从 NpcRegistry 加载某 NPC 的 mood_map（数据文件里的 mood_map 字段）。
## mood_map 是 {alias: mood_file_name}，alias 可以是任意字符串（中文/英文），
## mood_file_name 对应 res://assets/portraits/<npc_id>_<mood_file_name>.png。
## 同时缓存该 NPC 可用的 canonical mood 列表（mood_map 的 values 去重）。
static func _ensure_npc_mood_map_loaded(npc_id: String) -> void:
	if npc_id == "" or _npc_mood_maps.has(npc_id):
		return
	var registry: Node = Engine.get_main_loop().root.get_node_or_null("/root/NpcRegistry")
	if registry == null or not registry.has_method("get_npc"):
		# NpcRegistry 还没就绪：先空着，下次再加载
		return
	var npc_data: Dictionary = registry.call("get_npc", npc_id)
	if npc_data.is_empty():
		_npc_mood_maps[npc_id] = {}
		_npc_mood_lists[npc_id] = GLOBAL_CANONICAL_MOODS.duplicate()
		return
	var mood_map_raw: Variant = npc_data.get("mood_map", {})
	var mood_map: Dictionary = {}
	var mood_list: Array[String] = []
	if mood_map_raw is Dictionary:
		for alias in mood_map_raw:
			var target := String(mood_map_raw[alias]).strip_edges()
			if target == "":
				continue
			mood_map[String(alias)] = target
			if not mood_list.has(target):
				mood_list.append(target)
	_npc_mood_maps[npc_id] = mood_map
	# 若 NPC 没声明 mood_map，回退到全局 3 种。
	if mood_list.is_empty():
		mood_list = GLOBAL_CANONICAL_MOODS.duplicate()
	_npc_mood_lists[npc_id] = mood_list


## 对外的统一入口：**优先加载真图，找不到再生成占位**
## 查找顺序：
##   1. res://assets/portraits/<npc_id>_<mood>.png   ← NPC 差分图（mood 已按 NPC mood_map 映射）
##   2. res://assets/portraits/default_<mood>.png    ← 全局差分
##   3. 动态生成的占位（按 npc_id hash 分色调）
static func load_or_generate(npc_id: String, mood: String, size: Vector2i = Vector2i(200, 240)) -> Texture2D:
	var canonical := normalize_mood(mood, npc_id)
	if canonical == "":
		canonical = DEFAULT_MOOD

	if npc_id != "":
		var tex := _try_load_disk("res://assets/portraits/%s_%s.png" % [npc_id, canonical])
		if tex != null:
			return tex
	var tex2 := _try_load_disk("res://assets/portraits/default_%s.png" % canonical)


	if tex2 != null:
		return tex2
	return get_texture_for(npc_id, canonical, size)


static func _try_load_disk(path: String) -> Texture2D:
	if _disk_cache.has(path):
		return _disk_cache[path]
	var result: Texture2D = null
	if ResourceLoader.exists(path):
		var res: Resource = load(path)
		if res is Texture2D:
			result = res
	_disk_cache[path] = result
	return result


## 生成一张按 (npc_id, mood, size) 唯一的占位贴图，可缓存。
static func get_texture_for(npc_id: String, mood: String, size: Vector2i = Vector2i(200, 240)) -> Texture2D:
	var canonical := normalize_mood(mood, npc_id)
	if canonical == "":
		canonical = DEFAULT_MOOD
	var hue_index := _hue_index_for_npc(npc_id)
	var cache_key := "%s_%s_%dx%d_h%d" % [canonical, npc_id, size.x, size.y, hue_index]
	if _placeholder_cache.has(cache_key):
		return _placeholder_cache[cache_key]

	var base_style: Dictionary = _PLACEHOLDER_STYLE.get(canonical, _PLACEHOLDER_STYLE[DEFAULT_MOOD])
	var style := base_style.duplicate(true)
	# 按 NPC 微调背景色相，让不同 NPC 的占位图能区分
	style["bg"] = _shift_hue(base_style.get("bg", Color(0.5, 0.5, 0.5)), hue_index)
	var texture := _build_placeholder_texture(style, size)
	_placeholder_cache[cache_key] = texture
	return texture


## 稳定地把 npc_id 映射到 0..5 的色相 index，同一 NPC 每次运行都相同
static func _hue_index_for_npc(npc_id: String) -> int:
	if npc_id == "":
		return 0
	return int(abs(npc_id.hash())) % 6


## 保持饱和度/明度不变，按 index 偏移色相
static func _shift_hue(color: Color, index: int) -> Color:
	if index == 0:
		return color
	var h: float = color.h + float(index) * (1.0 / 6.0)
	while h > 1.0:
		h -= 1.0
	return Color.from_hsv(h, color.s, color.v, color.a)


## 从 style + 尺寸生成一张 ImageTexture（纯色底 + 中心大字标签），全部离线绘制。
static func _build_placeholder_texture(style: Dictionary, size: Vector2i) -> ImageTexture:
	var image := Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
	var bg: Color = style.get("bg", Color(0.3, 0.3, 0.3))
	image.fill(bg)

	# 绘制一圈内边框，让色块更像"框住的头像"
	var border: Color = Color(bg.r * 0.6, bg.g * 0.6, bg.b * 0.6, 1.0)
	_draw_border(image, size, border, 4)

	# 中央区域画一个亮色圆盘作为"脸"的抽象占位
	var face: Color = style.get("fg", Color.WHITE)
	var center := Vector2i(size.x / 2, size.y / 2 - int(size.y * 0.05))
	var radius := mini(size.x, size.y) / 4
	_draw_filled_circle(image, center, radius, Color(face.r, face.g, face.b, 0.35))

	# 表情标志：不同 mood 用不同几何图形做区分（快速视觉辨识）
	var label: String = String(style.get("label", ""))
	match label:
		"开心":
			# 笑脸：两个眼点 + 弧形嘴
			_draw_filled_circle(image, Vector2i(center.x - int(radius * 0.35), center.y - int(radius * 0.2)), maxi(3, radius / 10), face)
			_draw_filled_circle(image, Vector2i(center.x + int(radius * 0.35), center.y - int(radius * 0.2)), maxi(3, radius / 10), face)
			_draw_smile_arc(image, center, int(radius * 0.6), face, false)
		"思考":
			# 平静：两个眼点 + 直线嘴
			_draw_filled_circle(image, Vector2i(center.x - int(radius * 0.35), center.y - int(radius * 0.2)), maxi(3, radius / 10), face)
			_draw_filled_circle(image, Vector2i(center.x + int(radius * 0.35), center.y - int(radius * 0.2)), maxi(3, radius / 10), face)
			_draw_horizontal_line(image, Vector2i(center.x - int(radius * 0.35), center.y + int(radius * 0.3)), int(radius * 0.7), 3, face)
		"惊讶":
			# 惊讶：两个大眼点 + 圆嘴
			_draw_filled_circle(image, Vector2i(center.x - int(radius * 0.35), center.y - int(radius * 0.15)), maxi(4, radius / 7), face)
			_draw_filled_circle(image, Vector2i(center.x + int(radius * 0.35), center.y - int(radius * 0.15)), maxi(4, radius / 7), face)
			_draw_filled_circle(image, Vector2i(center.x, center.y + int(radius * 0.4)), maxi(4, radius / 6), face)

	# 顶部彩带写上 "开心 / 思考 / 惊讶" 三个字（这里没有字体渲染 API，
	# 因此改用容易识别的色带 + 图形提示；真实文字标注由 UI Label 叠加显示）
	_draw_top_banner(image, size, face, 26)
	var texture := ImageTexture.create_from_image(image)
	return texture


static func _draw_border(image: Image, size: Vector2i, color: Color, thickness: int) -> void:
	for i in range(thickness):
		for x in range(size.x):
			image.set_pixel(x, i, color)
			image.set_pixel(x, size.y - 1 - i, color)
		for y in range(size.y):
			image.set_pixel(i, y, color)
			image.set_pixel(size.x - 1 - i, y, color)


static func _draw_filled_circle(image: Image, center: Vector2i, radius: int, color: Color) -> void:
	var r2 := radius * radius
	var x_min := maxi(0, center.x - radius)
	var x_max := mini(image.get_width() - 1, center.x + radius)
	var y_min := maxi(0, center.y - radius)
	var y_max := mini(image.get_height() - 1, center.y + radius)
	for y in range(y_min, y_max + 1):
		for x in range(x_min, x_max + 1):
			var dx := x - center.x
			var dy := y - center.y
			if dx * dx + dy * dy <= r2:
				image.set_pixel(x, y, color)


static func _draw_horizontal_line(image: Image, start: Vector2i, length: int, thickness: int, color: Color) -> void:
	var y_min := maxi(0, start.y - thickness / 2)
	var y_max := mini(image.get_height() - 1, start.y + thickness / 2)
	var x_min := maxi(0, start.x)
	var x_max := mini(image.get_width() - 1, start.x + length)
	for y in range(y_min, y_max + 1):
		for x in range(x_min, x_max + 1):
			image.set_pixel(x, y, color)


## 画一段简易笑脸弧线：向下弯（笑）或向上弯（哭）
static func _draw_smile_arc(image: Image, center: Vector2i, radius: int, color: Color, upside_down: bool) -> void:
	var thickness := 3
	var steps := radius * 4
	for i in range(steps):
		var t: float = float(i) / float(maxi(1, steps - 1))
		var angle: float = lerpf(PI * 0.15, PI * 0.85, t)
		var x: int = center.x + int(cos(angle) * float(radius))
		var sign_y: int = -1 if upside_down else 1
		var y: int = center.y + int(float(sign_y) * sin(angle) * float(radius) * 0.55)
		for ox in range(-thickness, thickness + 1):
			for oy in range(-thickness, thickness + 1):
				var px := x + ox
				var py := y + oy
				if px < 0 or px >= image.get_width() or py < 0 or py >= image.get_height():
					continue
				if ox * ox + oy * oy <= thickness * thickness:
					image.set_pixel(px, py, color)


static func _draw_top_banner(image: Image, size: Vector2i, color: Color, height: int) -> void:
	var banner := Color(color.r, color.g, color.b, 0.65)
	var band_h := mini(height, size.y - 2)
	for y in range(4, 4 + band_h):
		for x in range(6, size.x - 6):
			image.set_pixel(x, y, banner)
