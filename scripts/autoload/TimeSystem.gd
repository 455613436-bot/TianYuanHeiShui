extends Node
## TimeSystem
## 游戏时钟 autoload：分钟计数 → 时段（period）。
## - 时间推进的唯一入口是 advance_minutes()；一次玩家发言 = 1 轮 = +10 分钟，
##   由 DialogueUI 在收到 LLM 回答后调用 on_dialogue_turn_completed()。
## - 玩家在两个不同地点之间移动时同样推进 10 分钟；单纯打开/关闭地图不计时。
## - 时段边界供 F7「NPC 主动预告离场」使用。
##
## 数据随 GameState.save_game() / load_game() 持久化。

signal minute_changed(day: int, minute_of_day: int)
signal period_changed(new_period: String, day: int)
signal day_changed(new_day: int)

const MINUTES_PER_DAY := 1440
## 19:00 后在完成当前整轮对话时触发“回宿舍休息”流程；不改变 night 的原有时段定义。
const NIGHT_OUTING_START_MINUTE := 19 * 60
const NIGHT_OUTING_END_MINUTE := 22 * 60
const NIGHT_WRAP_UP_MINUTE := 18 * 60 + 50
const REST_LOCK_START_MINUTE := NIGHT_OUTING_END_MINUTE
## night 不在表里：>= 1320 或 < 360 都视为 night（22:00 - 次日 06:00）
const PERIODS := [
	{"id": "morning", "start": 360, "end": 660}, # 06:00-11:00
	{"id": "noon", "start": 660, "end": 840}, # 11:00-14:00
	{"id": "afternoon", "start": 840, "end": 1080}, # 14:00-18:00
	{"id": "evening", "start": 1080, "end": 1320}, # 18:00-22:00
]
const PERIOD_ORDER := ["morning", "noon", "afternoon", "evening", "night"]
const PERIOD_LABELS := {
	"morning": "上午",
	"noon": "中午",
	"afternoon": "下午",
	"evening": "傍晚",
	"night": "夜晚",
}
const NIGHT_START := 1320
const NIGHT_END := 360 # 次日 06:00

var current_day: int = 1
var minute_of_day: int = 540 # 09:00 起始
var minutes_per_dialogue_turn: int = 10
var minutes_per_location_change: int = 10


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


## 唯一推进入口
func advance_minutes(n: int) -> void:
	if n <= 0:
		return
	var old_period := current_period()
	var old_day := current_day
	var total := minute_of_day + n
	while total >= MINUTES_PER_DAY:
		total -= MINUTES_PER_DAY
		current_day += 1
		day_changed.emit(current_day)
	minute_of_day = total
	minute_changed.emit(current_day, minute_of_day)
	var new_period := current_period()
	if new_period != old_period or current_day != old_day:
		period_changed.emit(new_period, current_day)


## 仅能消磨至当天更晚的时间；成功时通过统一入口刷新时钟与 NPC 日程。
func advance_to_today(target_minute: int) -> bool:
	var target := clampi(target_minute, 0, MINUTES_PER_DAY - 1)
	if target <= minute_of_day:
		return false
	advance_minutes(target - minute_of_day)
	return true


## 无论当前何时，都休息到下一天的指定时间；默认次日 09:00。
func rest_until_next_day(hour: int = 9, minute: int = 0) -> void:
	var target_hour := clampi(hour, 0, 23)
	var target_minute := clampi(minute, 0, 59)
	var next_day_target := target_hour * 60 + target_minute
	advance_minutes((MINUTES_PER_DAY - minute_of_day) + next_day_target)


## DialogueUI / GroupChatCoordinator 每轮对话结束调一次
func on_dialogue_turn_completed() -> void:
	advance_minutes(minutes_per_dialogue_turn)


## GameState 在确认已成功切换到另一个地点后调用。
func on_location_changed() -> void:
	advance_minutes(minutes_per_location_change)


func is_rest_lock_time() -> bool:
	return minute_of_day >= REST_LOCK_START_MINUTE


func is_night_outing_time() -> bool:
	return minute_of_day >= NIGHT_OUTING_START_MINUTE and minute_of_day < NIGHT_OUTING_END_MINUTE


func is_night_wrap_up_time() -> bool:
	return minute_of_day >= NIGHT_WRAP_UP_MINUTE and minute_of_day < NIGHT_OUTING_START_MINUTE


func current_period() -> String:
	for p in PERIODS:
		if minute_of_day >= int(p["start"]) and minute_of_day < int(p["end"]):
			return String(p["id"])
	return "night"


func current_period_label() -> String:
	return String(PERIOD_LABELS.get(current_period(), "夜晚"))


func next_period() -> String:
	var idx := PERIOD_ORDER.find(current_period())
	if idx < 0:
		return "morning"
	return String(PERIOD_ORDER[(idx + 1) % PERIOD_ORDER.size()])


## 距离当前时段结束还剩多少分钟（night 的结束边界是次日 06:00）
func minutes_until_next_period() -> int:
	var cur := current_period()
	if cur == "night":
		if minute_of_day >= NIGHT_START:
			return (MINUTES_PER_DAY - minute_of_day) + NIGHT_END
		return NIGHT_END - minute_of_day
	for p in PERIODS:
		if String(p["id"]) == cur:
			return int(p["end"]) - minute_of_day
	return 0


## F7 用：当前是否处于「距离时段切换 <= threshold_min」的窗口
func is_near_period_boundary(threshold_min: int = 10) -> bool:
	return minutes_until_next_period() <= threshold_min


## 推进 within_minutes 之后是否会跨过时段边界（对话 tick 预判用）
func will_cross_period_boundary(within_minutes: int) -> bool:
	return minutes_until_next_period() <= within_minutes


## 跨存档/规则系统使用的绝对分钟数（第 1 天 00:00 起算）
func total_minutes() -> int:
	return (current_day - 1) * MINUTES_PER_DAY + minute_of_day


func format_clock() -> String:
	var hour := minute_of_day / 60
	var minute := minute_of_day % 60
	return "第 %d 天 · %s %02d:%02d" % [current_day, current_period_label(), hour, minute]


func format_clock_short() -> String:
	return "%s %02d:%02d" % [current_period_label(), minute_of_day / 60, minute_of_day % 60]


func reset_to_start() -> void:
	current_day = 1
	minute_of_day = 540
	minute_changed.emit(current_day, minute_of_day)


# ─── 持久化 ────────────────────────────────────────────────────────────────

func to_dict() -> Dictionary:
	return {
		"current_day": current_day,
		"minute_of_day": minute_of_day,
	}


func load_from_dict(data: Variant) -> void:
	if data is not Dictionary:
		return
	var d: Dictionary = data
	var day_raw: Variant = d.get("current_day", 1)
	var minute_raw: Variant = d.get("minute_of_day", 540)
	current_day = maxi(1, int(day_raw)) if (day_raw is int or day_raw is float) else 1
	if minute_raw is int or minute_raw is float:
		minute_of_day = clampi(int(minute_raw), 0, MINUTES_PER_DAY - 1)
	else:
		minute_of_day = 540
	minute_changed.emit(current_day, minute_of_day)
