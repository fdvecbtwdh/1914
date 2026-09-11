extends Resource
class_name BattleState

## 运行时单位实例（区别于 CardData 模板）
class UnitData:
	extends Resource

	@export var card_id: String = ""
	@export var owner_index: int = -1
	@export var attack: int = 0
	@export var defense: int = 0
	@export var max_defense: int = 0
	@export var has_acted: bool = false
	@export var abilities: Array[String] = []
	@export var row: int = -1
	@export var col: int = -1
	@export var deployed_this_turn: bool = false

	## Phase 3 新增字段
	@export var stealthed: bool = false              # 是否有潜行词条
	@export var revealed: bool = false               # 是否被敌方发现（每回合重新计算）
	@export var has_attacked: bool = false           # 本回合是否已攻击
	@export var attack_count: int = 0                # 累计攻击次数（冲锋：首次攻击免反击）
	@export var move_count: int = 0                  # 本回合已移动次数
	@export var move_limit: int = 1                  # 本回合移动上限（坦克 = 99）
	@export var can_move_after_attack: bool = false  # 攻击后是否仍可移动（坦克 = true）
	@export var is_guarded: bool = false             # 是否有守护单位保护
	@export var guarded_by: Vector2i = Vector2i(-1, -1)  # 守护单位位置
	@export var firm_level: int = 0                  # 坚守等级（0 = 无坚守）
	@export var supply_level: int = 0                # 补给等级（0 = 无补给）


class PlayerData:
	extends Resource

	@export var resources: Dictionary = {"G": 0, "K": 0, "Z": 0}
	@export var hand: Array[String] = []
	@export var purchase_zone: Array[String] = []
	@export var deck: Array[String] = []
	@export var discard: Array[String] = []
	@export var hand_limit: int = 7
	@export var starter_card_id: String = ""

	## Phase 3 新增：记录每张手牌的购买回合（用于响应词条判定）
	@export var hand_card_purchase_turn: Dictionary = {}  # {card_id: turn_number}


class BoardData:
	extends Resource

	@export var rows: int = 5
	@export var cols: int = 5
	@export var slots: Array = []  # Array[Array]，元素为 UnitData 或 null

	func _init() -> void:
		_init_slots()

	func _init_slots() -> void:
		slots.clear()
		for r in range(rows):
			var row_array: Array = []
			for c in range(cols):
				row_array.append(null)
			slots.append(row_array)

	func get_unit(row: int, col: int) -> UnitData:
		if row < 0 or row >= rows or col < 0 or col >= cols:
			return null
		return slots[row][col]

	func set_unit(row: int, col: int, unit: UnitData) -> void:
		if row >= 0 and row < rows and col >= 0 and col < cols:
			slots[row][col] = unit
			if unit != null:
				unit.row = row
				unit.col = col


@export var players: Array[PlayerData] = []
@export var board: BoardData = BoardData.new()
@export var turn: int = 1
@export var phase: String = "draw"
@export var active_player_index: int = 0
@export var winner: int = -1
@export var round_count: int = 0
@export var action_log: Array[Dictionary] = []

func setup(p1_deck: Array[String], p2_deck: Array[String], p1_starter: String, p2_starter: String) -> void:
	players.clear()
	var p1 := PlayerData.new()
	p1.deck = p1_deck.duplicate()
	p1.starter_card_id = p1_starter
	var p2 := PlayerData.new()
	p2.deck = p2_deck.duplicate()
	p2.starter_card_id = p2_starter
	players = [p1, p2]
	board = BoardData.new()
	turn = 1
	phase = "draw"
	active_player_index = 0
	winner = -1
	round_count = 0
	action_log.clear()
