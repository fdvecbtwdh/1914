# Phase 2: 本地完整对战 — 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 实现两玩家同设备完整对战：抽牌 → 购买 → 部署 → 行动（移动/攻击）→ 回合交替 → 胜负判定

**Architecture:** BattleState (Resource) 作唯一数据源，GameLogic (RefCounted 静态纯函数) 执行规则，TurnManager (Node) 编排回合 + 信号驱动 UI 刷新，HandManager (Node2D) 渲染手牌/购买区/资源

**Tech Stack:** Godot 4.7.1, GDScript, JSON

## Global Constraints

- Godot 4.7.1，纯 2D
- 卡牌数据 JSON 文件存储，非程序员可编辑
- 本地同屏双人对战，手牌回合切换时隐藏/显示
- 三种资源：G（经济，可累积）、K（指挥点，移动/攻击消耗）、Z（战争点，部署消耗）
- 步兵/骑兵/火炮三种单位，核心词条（突击、坚守、冲锋、收缴）
- 战场：5×5 棋盘，P1 行 0-1，P2 行 3-4，行 2 中立
- 胜利：占领对方全部 5 条阵线（每列至少一个己方单位）
- 不实现迷雾、空军、坦克、工事

---

### Task 1: BattleState 数据结构

**Files:**
- Modify: `scripts/core/battle_state.gd`

**Interfaces:**
- Produces:
  - `BattleState` — `extends Resource`，顶层状态容器，含 `players: Array`, `board: BoardData`, `turn: int`, `phase: String`, `active_player_index: int`, `winner: int`
  - `BattleState.PlayerData` — 内类 `extends Resource`，字段 `resources: Dictionary` (`{"G": 0, "K": 0, "Z": 0}`), `hand: Array[String]`, `purchase_zone: Array[String]`, `deck: Array[String]`, `discard: Array[String]`, `hand_limit: int = 7`, `starter_card_id: String`
  - `BattleState.BoardData` — 内类 `extends Resource`，字段 `rows: int = 5`, `cols: int = 5`, `slots: Array`（rows×cols 的 `UnitData` 或 null 二维数组）
  - `BattleState.UnitData` — 内类 `extends Resource`，字段 `card_id: String`, `owner_index: int`, `attack: int`, `defense: int`, `max_defense: int`, `has_acted: bool`, `abilities: Array[String]`, `row: int`, `col: int`, `deployed_this_turn: bool`

- [ ] **Step 1: 重写 battle_state.gd — UnitData 内类**

```gdscript
extends Resource
class_name BattleState

## 运行时单位实例（区别于 CardData 模板）
class UnitData:
    extends Resource

    var card_id: String = ""
    var owner_index: int = -1
    var attack: int = 0
    var defense: int = 0
    var max_defense: int = 0
    var has_acted: bool = false
    var abilities: Array[String] = []
    var row: int = -1
    var col: int = -1
    var deployed_this_turn: bool = false
```

- [ ] **Step 2: 追加 PlayerData 内类**

```gdscript
class PlayerData:
    extends Resource

    var resources: Dictionary = {"G": 0, "K": 0, "Z": 0}
    var hand: Array[String] = []
    var purchase_zone: Array[String] = []
    var deck: Array[String] = []
    var discard: Array[String] = []
    var hand_limit: int = 7
    var starter_card_id: String = ""
```

- [ ] **Step 3: 追加 BoardData 内类**

```gdscript
class BoardData:
    extends Resource

    var rows: int = 5
    var cols: int = 5
    var slots: Array = []  # Array[Array]，元素为 UnitData 或 null

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
```

- [ ] **Step 4: 追加 BattleState 顶层字段和 init/reset 方法**

```gdscript
var players: Array[PlayerData] = []
var board: BoardData = BoardData.new()
var turn: int = 1
var phase: String = "draw"
var active_player_index: int = 0
var winner: int = -1
var round_count: int = 0
var action_log: Array[Dictionary] = []

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
```

- [ ] **Step 5: 验证 — 在 Godot 编辑器内运行确认无语法错误**

按 F5，预期无报错。BattleState 此时还没被使用，但 Godot 解析器应能通过。

- [ ] **Step 6: Commit**

```bash
git add scripts/core/battle_state.gd
git commit -m "feat: add BattleState resource with UnitData, PlayerData, BoardData inner classes"
```

---

### Task 2: 卡牌与卡组 JSON 数据

**Files:**
- Create: `data/cards/units/infantry_01.json`
- Create: `data/cards/units/cavalry_01.json`
- Create: `data/cards/units/artillery_01.json`
- Create: `data/decks/player_default.json`

**Interfaces:**
- Consumes: CardDataLoader 的 JSON 加载机制（已有）
- Produces: 3 张单位卡 JSON + 1 个卡组 JSON

- [ ] **Step 1: 创建 infantry_01.json**

`data/cards/units/infantry_01.json`：
```json
{
  "id": "infantry_01",
  "name": "步兵",
  "nation": "neutral",
  "type": "unit",
  "unit_class": "infantry",
  "cost_g": 30,
  "cost_k": 1,
  "attack": 3,
  "defense": 4,
  "vision_range": "adjacent_4",
  "attack_range": "adjacent_4",
  "abilities": [],
  "rarity": "common",
  "art": "",
  "flavor_text": "堑壕中的士兵。"
}
```

- [ ] **Step 2: 创建 cavalry_01.json**

`data/cards/units/cavalry_01.json`：
```json
{
  "id": "cavalry_01",
  "name": "骑兵",
  "nation": "neutral",
  "type": "unit",
  "unit_class": "cavalry",
  "cost_g": 40,
  "cost_k": 2,
  "attack": 4,
  "defense": 2,
  "vision_range": "adjacent_4",
  "attack_range": "adjacent_4",
  "abilities": ["冲锋"],
  "rarity": "common",
  "art": "",
  "flavor_text": "马蹄声震彻战场。"
}
```

- [ ] **Step 3: 创建 artillery_01.json**

`data/cards/units/artillery_01.json`：
```json
{
  "id": "artillery_01",
  "name": "火炮",
  "nation": "neutral",
  "type": "unit",
  "unit_class": "artillery",
  "cost_g": 50,
  "cost_k": 1,
  "attack": 5,
  "defense": 2,
  "vision_range": "front_3x3",
  "attack_range": "global",
  "abilities": ["突击"],
  "rarity": "common",
  "art": "",
  "flavor_text": "远程火力支援。"
}
```

- [ ] **Step 4: 创建 player_default.json**

`data/decks/player_default.json`：
```json
{
  "name": "默认卡组",
  "starter": "infantry_01",
  "cards": [
    "infantry_01", "infantry_01", "infantry_01",
    "cavalry_01", "cavalry_01", "cavalry_01",
    "artillery_01", "artillery_01", "artillery_01"
  ]
}
```

- [ ] **Step 5: 验证 — F5 运行，检查控制台**

预期：`[CardDataLoader] Loaded 4 cards`（test_infantry + 3 张新卡）

- [ ] **Step 6: Commit**

```bash
git add data/cards/units/infantry_01.json data/cards/units/cavalry_01.json data/cards/units/artillery_01.json data/decks/
git commit -m "feat: add infantry, cavalry, artillery cards and default deck JSON"
```

---

### Task 3: GameLogic 纯函数引擎

**Files:**
- Modify: `scripts/core/game_logic.gd`

**Interfaces:**
- Consumes: `BattleState` (Task 1), `CardDataLoader.CardData` (已有)
- Produces: `GameLogic` — `extends RefCounted`，全部静态方法，接收 `BattleState` 返回 `BattleState`
  - `static func init_game(state, deck_p1, deck_p2) -> BattleState`
  - `static func draw_card(state, player_idx) -> BattleState`
  - `static func purchase_card(state, player_idx, card_id) -> BattleState`
  - `static func deploy_unit(state, player_idx, card_id, row, col) -> BattleState`
  - `static func move_unit(state, player_idx, from_row, from_col, to_row, to_col) -> BattleState`
  - `static func attack_unit(state, player_idx, from_row, from_col, target_row, target_col) -> BattleState`
  - `static func start_turn(state) -> BattleState`
  - `static func end_turn(state) -> BattleState`
  - `static func check_victory(state) -> int`（-1 未结束 / 0 或 1 胜者）

- [ ] **Step 1: 重写 game_logic.gd — 类声明 + init_game**

```gdscript
extends RefCounted
class_name GameLogic

## 核心游戏逻辑 — 纯函数，无状态，无 Godot 节点依赖
## 每个方法接收 BattleState，深拷贝后修改并返回新 state

static func init_game(p1_deck: Array[String], p2_deck: Array[String], p1_starter: String, p2_starter: String) -> BattleState:
    var state := BattleState.new()
    state.setup(p1_deck, p2_deck, p1_starter, p2_starter)
    # 洗牌
    _shuffle_deck(state.players[0].deck)
    _shuffle_deck(state.players[1].deck)
    # 初始抽 3 张
    for i in range(3):
        _draw_one(state, 0)
        _draw_one(state, 1)
    # 首发牌加入购买区
    state.players[0].purchase_zone.append(state.players[0].starter_card_id)
    state.players[1].purchase_zone.append(state.players[1].starter_card_id)
    return state


static func _shuffle_deck(deck: Array) -> void:
    var n := deck.size()
    while n > 1:
        n -= 1
        var k := randi() % (n + 1)
        var tmp = deck[k]
        deck[k] = deck[n]
        deck[n] = tmp


static func _draw_one(state: BattleState, player_idx: int) -> void:
    var player = state.players[player_idx]
    if player.deck.is_empty():
        return
    var card_id: String = player.deck.pop_front()
    player.purchase_zone.append(card_id)
```

- [ ] **Step 2: 实现 draw_card（公开方法）**

```gdscript
static func draw_card(state: BattleState, player_idx: int) -> BattleState:
    var new_state := state.duplicate(true)
    _draw_one(new_state, player_idx)
    return new_state
```

- [ ] **Step 3: 实现 purchase_card**

```gdscript
static func purchase_card(state: BattleState, player_idx: int, card_id: String) -> BattleState:
    var new_state := state.duplicate(true)
    var player = new_state.players[player_idx]
    if not player.purchase_zone.has(card_id):
        return new_state  # 待购买区无此卡
    if player.hand.size() >= player.hand_limit:
        return new_state  # 手牌已满
    var card_data := CardDataLoader.cards.get(card_id)
    if card_data == null:
        return new_state
    if player.resources["G"] < card_data.cost_g:
        return new_state  # G 不够
    player.resources["G"] -= card_data.cost_g
    player.purchase_zone.erase(card_id)
    player.hand.append(card_id)
    return new_state
```

- [ ] **Step 4: 实现 deploy_unit**

```gdscript
static func deploy_unit(state: BattleState, player_idx: int, card_id: String, row: int, col: int) -> BattleState:
    var new_state := state.duplicate(true)
    var player = new_state.players[player_idx]
    if not player.hand.has(card_id):
        return new_state
    var card_data := CardDataLoader.cards.get(card_id)
    if card_data == null:
        return new_state
    if player.resources["Z"] < card_data.cost_k:
        return new_state  # Z 不够
    # 检查格子在己方后方/前线
    if not _can_deploy_at(player_idx, row, col, card_data):
        return new_state
    # 目标格子为空
    if new_state.board.get_unit(row, col) != null:
        return new_state
    player.resources["Z"] -= card_data.cost_k
    player.hand.erase(card_id)
    var unit := BattleState.UnitData.new()
    unit.card_id = card_id
    unit.owner_index = player_idx
    unit.attack = card_data.attack
    unit.defense = card_data.defense
    unit.max_defense = card_data.defense
    unit.abilities = card_data.abilities.duplicate()
    unit.deployed_this_turn = true
    new_state.board.set_unit(row, col, unit)
    new_state.action_log.append({"type": "deploy", "player": player_idx, "card_id": card_id, "row": row, "col": col})
    return new_state


static func _can_deploy_at(player_idx: int, row: int, col: int, _card_data: Resource) -> bool:
    var board_rows := 5  # default
    if player_idx == 0:
        return row == 0 or row == 1  # P1 后方+前线
    else:
        return row == 3 or row == 4  # P2 后方+前线
```

- [ ] **Step 5: 实现 move_unit**

```gdscript
static func move_unit(state: BattleState, player_idx: int, from_row: int, from_col: int, to_row: int, to_col: int) -> BattleState:
    var new_state := state.duplicate(true)
    var unit := new_state.board.get_unit(from_row, from_col)
    if unit == null or unit.owner_index != player_idx:
        return new_state
    if unit.has_acted:
        return new_state
    # 八方向移动一格
    var dr := abs(to_row - from_row)
    var dc := abs(to_col - from_col)
    if dr > 1 or dc > 1 or (dr == 0 and dc == 0):
        return new_state
    # 禁止向后方移动
    if player_idx == 0 and to_row < from_row:
        return new_state
    if player_idx == 1 and to_row > from_row:
        return new_state
    # 目标格为空
    if new_state.board.get_unit(to_row, to_col) != null:
        return new_state
    # K 消耗
    var player = new_state.players[player_idx]
    if player.resources["K"] < 1:
        return new_state
    player.resources["K"] -= 1
    new_state.board.set_unit(from_row, from_col, null)
    new_state.board.set_unit(to_row, to_col, unit)
    unit.has_acted = true
    new_state.action_log.append({"type": "move", "player": player_idx, "from": [from_row, from_col], "to": [to_row, to_col]})
    return new_state
```

- [ ] **Step 6: 实现 attack_unit（含完整攻击-反击 + 词条）**

```gdscript
static func attack_unit(state: BattleState, player_idx: int, from_row: int, from_col: int, target_row: int, target_col: int) -> BattleState:
    var new_state := state.duplicate(true)
    var attacker := new_state.board.get_unit(from_row, from_col)
    var defender := new_state.board.get_unit(target_row, target_col)
    if attacker == null or defender == null:
        return new_state
    if attacker.owner_index != player_idx:
        return new_state
    if defender.owner_index == player_idx:
        return new_state  # 不能打友方
    if attacker.has_acted:
        return new_state
    # 射程检查（简化：相邻四格 + 火炮全图）
    if not _in_attack_range(attacker, from_row, from_col, target_row, target_col):
        return new_state
    # K 消耗
    var player = new_state.players[player_idx]
    if player.resources["K"] < 1:
        return new_state
    player.resources["K"] -= 1

    # 伤害计算
    var damage := attacker.attack
    # 防守方坚守词条减伤
    if defender.abilities.has("坚守"):
        var firm_level := 1  # 默认坚守1
        # 坦克坚守上限4由 CardData 设定，这里统一取1
        damage = max(1, damage - firm_level)
    # 施加伤害
    defender.defense -= damage

    # 战斗记录
    new_state.action_log.append({"type": "attack", "player": player_idx, "from": [from_row, from_col], "to": [target_row, target_col], "damage": damage})

    # 是否消灭
    if defender.defense <= 0:
        var card_data := CardDataLoader.cards.get(defender.card_id)
        var reward_g := 0
        if card_data != null:
            reward_g = int(card_data.cost_g * 0.25)
        # 收缴词条：50%
        if attacker.abilities.has("收缴"):
            reward_g = int(card_data.cost_g * 0.50) if card_data != null else 0
        player.resources["G"] += reward_g
        new_state.board.set_unit(target_row, target_col, null)
        new_state.action_log.append({"type": "destroy", "card_id": defender.card_id, "reward_g": reward_g})
    else:
        # 反击（攻击者未被消灭时）
        _counter_attack(attacker, defender, from_row, from_col, target_row, target_col, new_state)

    attacker.has_acted = true
    return new_state


static func _in_attack_range(attacker: BattleState.UnitData, from_row: int, from_col: int, target_row: int, target_col: int) -> bool:
    var card_data := CardDataLoader.cards.get(attacker.card_id)
    if card_data == null:
        return false
    var range_str: String = card_data.attack_range
    var dr := abs(target_row - from_row)
    var dc := abs(target_col - from_col)
    match range_str:
        "adjacent_4":
            return dr <= 1 and dc <= 1 and not (dr == 0 and dc == 0)
        "global":
            return true
        _:
            return dr <= 1 and dc <= 1 and not (dr == 0 and dc == 0)


static func _counter_attack(attacker: BattleState.UnitData, defender: BattleState.UnitData, atk_row: int, atk_col: int, def_row: int, def_col: int, state: BattleState) -> void:
    # 攻击者有"突击" + 首次攻击 → 免反击
    if attacker.abilities.has("突击") and attacker.deployed_this_turn:
        return
    # 攻击者有"冲锋" + 首次攻击 → 免反击（此处用 deployed_this_turn 近似）
    if attacker.abilities.has("冲锋") and attacker.deployed_this_turn:
        return
    # 火炮不可被反击
    var attacker_card := CardDataLoader.cards.get(attacker.card_id)
    if attacker_card != null and attacker_card.unit_class == "artillery":
        return
    # 防守方反击
    var counter_dmg := defender.attack
    if attacker.abilities.has("坚守"):
        counter_dmg = max(1, counter_dmg - 1)
    attacker.defense -= counter_dmg
    state.action_log.append({"type": "counter", "damage": counter_dmg})
    if attacker.defense <= 0:
        state.board.set_unit(atk_row, atk_col, null)
        state.action_log.append({"type": "destroy", "card_id": attacker.card_id, "reward_g": 0})
```

- [ ] **Step 7: 实现 start_turn + end_turn + check_victory**

```gdscript
static func start_turn(state: BattleState) -> BattleState:
    var new_state := state.duplicate(true)
    var player = new_state.players[new_state.active_player_index]
    # G +150
    player.resources["G"] += 150
    # K = 回合数, Z = 回合数
    player.resources["K"] = new_state.turn
    player.resources["Z"] = new_state.turn
    # 抽 1 张
    _draw_one(new_state, new_state.active_player_index)
    # 重置单位行动标记
    for r in range(new_state.board.rows):
        for c in range(new_state.board.cols):
            var unit := new_state.board.get_unit(r, c)
            if unit != null and unit.owner_index == new_state.active_player_index:
                unit.has_acted = false
                unit.deployed_this_turn = false
    new_state.phase = "purchase"
    return new_state


static func end_turn(state: BattleState) -> BattleState:
    var new_state := state.duplicate(true)
    # 清空 K/Z
    new_state.players[new_state.active_player_index].resources["K"] = 0
    new_state.players[new_state.active_player_index].resources["Z"] = 0
    # 检测胜利
    var result := check_victory(new_state)
    if result != -1:
        new_state.winner = result
        new_state.phase = "game_over"
        return new_state
    # 切换玩家
    new_state.active_player_index = 1 - new_state.active_player_index
    if new_state.active_player_index == 0:
        new_state.turn += 1
    new_state.phase = "draw"
    return new_state


static func check_victory(state: BattleState) -> int:
    # 占领对方全部5条阵线（每列至少一个己方单位在敌方区域内）
    # P1 胜：P1 单位在 P2 区域（行3-4）每列都有
    var p1_cols := {}
    var p2_cols := {}
    for r in range(state.board.rows):
        for c in range(state.board.cols):
            var unit := state.board.get_unit(r, c)
            if unit == null:
                continue
            if unit.owner_index == 0 and r >= 3:
                p1_cols[c] = true
            elif unit.owner_index == 1 and r <= 1:
                p2_cols[c] = true
    if p1_cols.size() == state.board.cols:
        return 0
    if p2_cols.size() == state.board.cols:
        return 1
    return -1
```

- [ ] **Step 8: 验证 — F5 运行，确认无语法错误**

- [ ] **Step 9: Commit**

```bash
git add scripts/core/game_logic.gd
git commit -m "feat: add GameLogic pure-function engine (draw, purchase, deploy, move, attack, turn)"
```

---

### Task 4: CardDisplay 已知问题修复

**Files:**
- Modify: `scripts/ui/card_display.gd`
- Modify: `scripts/ui/board.gd`（仅 `range(5)` → `range(GRID_SIZE)`）

**Interfaces:**
- Consumes: 现有 `CardDisplay` 类
- Produces: 修复后的 `CardDisplay`：`_gui_input` 替代 `_input`，`setup()` 幂等

- [ ] **Step 1: CardDisplay 改为 Control 节点 + _gui_input**

修改 `scripts/ui/card_display.gd`：

```gdscript
extends Control
class_name CardDisplay

## 单张卡牌的显示与拖拽行为

var card_data: Resource = null

var is_dragging: bool = false
var drag_offset: Vector2 = Vector2.ZERO
var original_position: Vector2 = Vector2.ZERO
var original_parent: Node = null
var _initialized: bool = false

const CARD_SIZE: Vector2 = Vector2(80, 100)


func setup(data: Resource) -> void:
    if _initialized:
        return  # 幂等保护
    _initialized = true
    card_data = data
    mouse_filter = Control.MOUSE_FILTER_STOP
    custom_minimum_size = CARD_SIZE
    # 背景
    var bg := ColorRect.new()
    bg.size = CARD_SIZE
    bg.color = Color(0.3, 0.4, 0.5, 1.0)
    add_child(bg)
    # 名称标签
    var label := Label.new()
    label.text = data.card_name
    label.add_theme_font_size_override("font_size", 12)
    label.position = Vector2(4, 4)
    add_child(label)
    # 攻防标签
    var stats := Label.new()
    stats.text = "%d/%d" % [data.attack, data.defense]
    stats.add_theme_font_size_override("font_size", 10)
    stats.position = Vector2(4, 80)
    add_child(stats)

    print("[CardDisplay] Setup: %s" % data.card_name)


func _gui_input(event: InputEvent) -> void:
    if event is InputEventMouseButton:
        if event.button_index == MOUSE_BUTTON_LEFT:
            if event.pressed:
                _start_drag(event.position)
            else:
                _end_drag(event.position)
    if is_dragging and event is InputEventMouseMotion:
        global_position = get_global_mouse_position() - drag_offset


func _start_drag(mouse_pos: Vector2) -> void:
    is_dragging = true
    original_position = global_position
    original_parent = get_parent()
    drag_offset = mouse_pos
    # 提升到场景根
    var root := get_tree().current_scene
    var old_global := global_position
    var parent := get_parent()
    parent.remove_child(self)
    if parent.has_method("remove_card"):
        parent.remove_card()
    root.add_child(self)
    global_position = old_global


func _end_drag(mouse_pos: Vector2) -> void:
    if not is_dragging:
        return
    is_dragging = false
    var dropped := false
    var slots := get_tree().get_nodes_in_group("board_slot")
    for slot in slots:
        var slot_rect := Rect2(slot.global_position, CARD_SIZE)
        if slot_rect.has_point(get_global_mouse_position()) and slot.can_accept_card():
            var root := get_tree().current_scene
            root.remove_child(self)
            slot.place_card(self)
            dropped = true
            break
    if not dropped:
        var root := get_tree().current_scene
        root.remove_child(self)
        original_parent.add_child(self)
        global_position = original_position
```

- [ ] **Step 2: 更新 card.tscn 根节点类型**

在 Godot 编辑器中打开 `scenes/ui_components/card.tscn`，将根节点从 `Node2D` 改为 `Control`。如果编辑器操作不顺手，直接编辑 `.tscn` 文本：

将 `[node name="..." type="Node2D"]` 改为 `[node name="..." type="Control"]`。

- [ ] **Step 3: 修复 board.gd 的 range(5)**

修改 `scripts/ui/board.gd` 第 56 行附近：

```gdscript
# 原：for col in range(5):
# 改为：
for col in range(GRID_SIZE):
```

- [ ] **Step 4: 验证 — F5 确认卡牌仍可拖拽，无控制台报错**

- [ ] **Step 5: Commit**

```bash
git add scripts/ui/card_display.gd scenes/ui_components/card.tscn scripts/ui/board.gd
git commit -m "fix: CardDisplay uses Control+_gui_input, setup is idempotent, board uses GRID_SIZE"
```

---

### Task 5: TurnManager 回合编排

**Files:**
- Modify: `scripts/core/turn_manager.gd`

**Interfaces:**
- Consumes: `BattleState` (Task 1), `GameLogic` (Task 3)
- Produces: `TurnManager` — `extends Node`
  - `var battle_state: BattleState`
  - `func start_game(p1_deck, p2_deck, p1_starter, p2_starter) -> void`
  - `func submit_action(action: Dictionary) -> void`
  - `func get_state() -> BattleState`
  - 信号：`state_changed(new_state: BattleState)`, `game_over(winner: int)`, `phase_changed(new_phase: String)`

- [ ] **Step 1: 重写 turn_manager.gd**

```gdscript
extends Node
class_name TurnManager

## 回合流转管理 — 持有 BattleState，编排 GameLogic 调用，发信号驱动 UI

signal state_changed(new_state: BattleState)
signal phase_changed(new_phase: String)
signal game_over(winner: int)
signal action_failed(reason: String)

var battle_state: BattleState = null


func start_game(p1_deck: Array[String], p2_deck: Array[String], p1_starter: String, p2_starter: String) -> void:
    battle_state = GameLogic.init_game(p1_deck, p2_deck, p1_starter, p2_starter)
    battle_state = GameLogic.start_turn(battle_state)
    _emit_all()


func submit_action(action: Dictionary) -> void:
    if battle_state == null:
        return
    if battle_state.winner != -1:
        return  # 游戏已结束

    var action_type: String = action.get("type", "")
    var player_idx: int = action.get("player_idx", battle_state.active_player_index)

    # 只允许当前活跃玩家操作
    if player_idx != battle_state.active_player_index:
        action_failed.emit("不是你的回合")
        return

    var new_state: BattleState = null

    match action_type:
        "purchase":
            new_state = GameLogic.purchase_card(battle_state, player_idx, action.get("card_id", ""))
        "deploy":
            new_state = GameLogic.deploy_unit(battle_state, player_idx, action.get("card_id", ""), action.get("row", -1), action.get("col", -1))
        "move":
            new_state = GameLogic.move_unit(battle_state, player_idx, action.get("from_row", -1), action.get("from_col", -1), action.get("to_row", -1), action.get("to_col", -1))
        "attack":
            new_state = GameLogic.attack_unit(battle_state, player_idx, action.get("from_row", -1), action.get("from_col", -1), action.get("target_row", -1), action.get("target_col", -1))
        "end_turn":
            new_state = GameLogic.end_turn(battle_state)
            if new_state.winner == -1:
                # 开始新回合
                new_state = GameLogic.start_turn(new_state)
        "skip_phase":
            new_state = _skip_phase(battle_state)
        _:
            action_failed.emit("未知操作类型: " + action_type)
            return

    if new_state == null or new_state == battle_state:
        return  # 操作无效，状态未变

    battle_state = new_state
    _emit_all()

    if battle_state.winner != -1:
        game_over.emit(battle_state.winner)


func _skip_phase(state: BattleState) -> BattleState:
    var ns := state.duplicate(true)
    match ns.phase:
        "purchase":
            ns.phase = "deploy"
        "deploy":
            ns.phase = "action"
        "action":
            pass  # 用 end_turn 跳过
        _:
            pass
    return ns


func get_state() -> BattleState:
    return battle_state


func _emit_all() -> void:
    state_changed.emit(battle_state)
    phase_changed.emit(battle_state.phase)
```

- [ ] **Step 2: 验证 — F5，确认无语法报错**

- [ ] **Step 3: Commit**

```bash
git add scripts/core/turn_manager.gd
git commit -m "feat: add TurnManager with submit_action and state-changed signals"
```

---

### Task 6: Board 改为从 BattleState 渲染

**Files:**
- Modify: `scripts/ui/board.gd`

**Interfaces:**
- Consumes: `BattleState` (Task 1), `TurnManager` (Task 5)
- Produces: `Board.render_from_state(state)` 替换原有硬编码，删除 `_spawn_test_card()`，连接 `TurnManager.state_changed` 信号

- [ ] **Step 1: 重写 board.gd**

```gdscript
extends Node2D
class_name Board

## 棋盘渲染 — 从 BattleState 读取数据，渲染格子和单位

const GRID_SIZE: int = 5
const SLOT_SPACING: Vector2 = Vector2(90, 115)
const SLOT_SIZE: Vector2 = Vector2(80, 100)
const GRID_OFFSET: Vector2 = Vector2(200, 50)

var max_rows: int = 5
var turn_manager: TurnManager = null
var _unit_displays: Dictionary = {}  # {(row,col): CardDisplay}


func _ready() -> void:
    print("[Board] Ready — waiting for TurnManager")
    _create_board()


func setup(tm: TurnManager) -> void:
    turn_manager = tm
    turn_manager.state_changed.connect(_on_state_changed)


func _create_board() -> void:
    var slot_scene = load("res://scenes/ui_components/board_slot.tscn")
    for row in range(GRID_SIZE):
        for col in range(GRID_SIZE):
            var slot = slot_scene.instantiate()
            slot.slot_row = row
            slot.slot_col = col
            slot.position = GRID_OFFSET + Vector2(col * SLOT_SPACING.x, row * SLOT_SPACING.y)
            add_child(slot)
    print("[Board] Created %d slots" % (GRID_SIZE * GRID_SIZE))


func _on_state_changed(new_state: BattleState) -> void:
    _clear_unit_displays()
    if new_state == null:
        return
    _render_units(new_state)


func _clear_unit_displays() -> void:
    for display in _unit_displays.values():
        if is_instance_valid(display):
            display.queue_free()
    _unit_displays.clear()


func _render_units(state: BattleState) -> void:
    for row in range(state.board.rows):
        for col in range(state.board.cols):
            var unit: BattleState.UnitData = state.board.get_unit(row, col)
            if unit == null:
                continue
            var card_data := CardDataLoader.cards.get(unit.card_id)
            if card_data == null:
                continue
            var display := spawn_card(card_data)
            display.position = GRID_OFFSET + Vector2(col * SLOT_SPACING.x, row * SLOT_SPACING.y)
            # 只有己方可见详细信息；对方单位显示为灰色迷雾方块
            if unit.owner_index != state.active_player_index:
                _fog_display(display)
            add_child(display)
            _unit_displays[Vector2i(row, col)] = display


func _fog_display(display: CardDisplay) -> void:
    # 用灰色覆盖隐藏对方单位信息
    var fog := ColorRect.new()
    fog.size = Vector2(80, 100)
    fog.color = Color(0.15, 0.15, 0.15, 1.0)
    fog.mouse_filter = Control.MOUSE_FILTER_IGNORE
    display.add_child(fog)


func spawn_card(card_data: Resource) -> Node2D:
    var card_scene = load("res://scenes/ui_components/card.tscn")
    var card = card_scene.instantiate()
    card.setup(card_data)
    return card
```

- [ ] **Step 2: 验证 — F5，确认棋盘格子正常显示（暂无单位）**

- [ ] **Step 3: Commit**

```bash
git add scripts/ui/board.gd
git commit -m "feat: Board renders from BattleState, connects to TurnManager signals"
```

---

### Task 7: HandManager 手牌 UI

**Files:**
- Modify: `scripts/ui/hand_manager.gd`

**Interfaces:**
- Consumes: `BattleState` (Task 1), `TurnManager` (Task 5)
- Produces: `HandManager` — `extends Node2D`
  - 显示购买区 + 手牌 + 资源 + 结束回合按钮
  - 连接 `TurnManager.state_changed` 信号刷新
  - 发出 `card_purchased(card_id)`, `card_deployed(card_id, row, col)`, `end_turn_pressed()`

- [ ] **Step 1: 重写 hand_manager.gd**

```gdscript
extends Node2D
class_name HandManager

## 手牌/购买区/资源 UI — 从 BattleState 读取，响应 TurnManager 信号

signal card_purchased(card_id: String)
signal card_deployed(card_id: String, row: int, col: int)
signal end_turn_pressed()
signal skip_phase_pressed()

var turn_manager: TurnManager = null
var _purchase_buttons: Dictionary = {}   # {card_id: Button}
var _hand_buttons: Dictionary = {}       # {card_id: Button}
var _g_label: Label = null
var _k_label: Label = null
var _z_label: Label = null
var _phase_label: Label = null
var _player_label: Label = null
var _turn_label: Label = null


func setup(tm: TurnManager) -> void:
    turn_manager = tm
    turn_manager.state_changed.connect(_on_state_changed)
    _build_ui()


func _build_ui() -> void:
    # 玩家/回合/阶段信息
    _turn_label = Label.new()
    _turn_label.position = Vector2(10, 10)
    _turn_label.add_theme_font_size_override("font_size", 16)
    add_child(_turn_label)

    _player_label = Label.new()
    _player_label.position = Vector2(10, 30)
    _player_label.add_theme_font_size_override("font_size", 14)
    add_child(_player_label)

    _phase_label = Label.new()
    _phase_label.position = Vector2(10, 50)
    _phase_label.add_theme_font_size_override("font_size", 12)
    add_child(_phase_label)

    # 资源显示
    _g_label = _make_resource_label(Vector2(10, 80), "G: 0")
    _k_label = _make_resource_label(Vector2(110, 80), "K: 0")
    _z_label = _make_resource_label(Vector2(210, 80), "Z: 0")

    # 结束回合按钮
    var end_btn := Button.new()
    end_btn.text = "结束回合"
    end_btn.position = Vector2(600, 10)
    end_btn.pressed.connect(func(): end_turn_pressed.emit())
    add_child(end_btn)

    # 跳过阶段按钮
    var skip_btn := Button.new()
    skip_btn.text = "跳过阶段"
    skip_btn.position = Vector2(600, 50)
    skip_btn.pressed.connect(func(): skip_phase_pressed.emit())
    add_child(skip_btn)


func _make_resource_label(pos: Vector2, text: String) -> Label:
    var lbl := Label.new()
    lbl.position = pos
    lbl.text = text
    lbl.add_theme_font_size_override("font_size", 14)
    add_child(lbl)
    return lbl


func _on_state_changed(new_state: BattleState) -> void:
    if new_state == null:
        return
    _clear_dynamic_ui()
    _update_info(new_state)
    _update_resources(new_state)
    _render_purchase_zone(new_state)
    _render_hand(new_state)


func _update_info(state: BattleState) -> void:
    _turn_label.text = "回合 %d" % state.turn
    _player_label.text = "玩家 %d" % (state.active_player_index + 1)
    _phase_label.text = "阶段: %s" % state.phase


func _update_resources(state: BattleState) -> void:
    var player = state.players[state.active_player_index]
    _g_label.text = "G: %d" % player.resources["G"]
    _k_label.text = "K: %d" % player.resources["K"]
    _z_label.text = "Z: %d" % player.resources["Z"]


func _render_purchase_zone(state: BattleState) -> void:
    var player = state.players[state.active_player_index]
    var x := 10.0
    var y := 110.0
    var title := Label.new()
    title.text = "— 待购买区 —"
    title.position = Vector2(x, y)
    title.add_theme_font_size_override("font_size", 12)
    add_child(title)
    y += 20
    for card_id in player.purchase_zone:
        var card_data := CardDataLoader.cards.get(card_id)
        if card_data == null:
            continue
        var btn := Button.new()
        btn.text = "%s (G:%d)" % [card_data.card_name, card_data.cost_g]
        btn.position = Vector2(x, y)
        btn.pressed.connect(_make_purchase_handler(card_id))
        add_child(btn)
        _purchase_buttons[card_id] = btn
        x += 130


func _render_hand(state: BattleState) -> void:
    var player = state.players[state.active_player_index]
    var x := 10.0
    var y := 160.0
    var title := Label.new()
    title.text = "— 手牌 (%d/%d) —" % [player.hand.size(), player.hand_limit]
    title.position = Vector2(x, y)
    title.add_theme_font_size_override("font_size", 12)
    add_child(title)
    y += 20
    for card_id in player.hand:
        var card_data := CardDataLoader.cards.get(card_id)
        if card_data == null:
            continue
        var btn := Button.new()
        btn.text = "%s (Z:%d) %d/%d" % [card_data.card_name, card_data.cost_k, card_data.attack, card_data.defense]
        btn.position = Vector2(x, y)
        btn.pressed.connect(_make_deploy_handler(card_id))
        add_child(btn)
        _hand_buttons[card_id] = btn
        x += 150


func _make_purchase_handler(card_id: String) -> Callable:
    return func(): card_purchased.emit(card_id)


func _make_deploy_handler(card_id: String) -> Callable:
    return func(): card_deployed.emit(card_id, -1, -1)  # row/col by click on board


func _clear_dynamic_ui() -> void:
    for btn in _purchase_buttons.values():
        if is_instance_valid(btn):
            btn.queue_free()
    _purchase_buttons.clear()
    for btn in _hand_buttons.values():
        if is_instance_valid(btn):
            btn.queue_free()
    _hand_buttons.clear()
    # 清除标题 Label（简单遍历子节点清理）
    # 注意：不清理 _turn_label 等持久 UI
```

- [ ] **Step 2: 验证 — F5，确认 UI 组件无语法错误**

- [ ] **Step 3: Commit**

```bash
git add scripts/ui/hand_manager.gd
git commit -m "feat: add HandManager UI for purchase zone, hand, resources display"
```

---

### Task 8: 集成 — GameManager 初始化 + BattleScene 布线

**Files:**
- Modify: `scripts/autoload/game_manager.gd`
- Modify: `scenes/battle.tscn`（或通过 Godot 编辑器）

**Interfaces:**
- Consumes: 所有前述 Task
- Produces: 可运行的完整对战循环 — F5 进入 BattleScene 后双方轮流抽牌/购买/部署/攻击

- [ ] **Step 1: 重写 game_manager.gd 作为游戏入口**

```gdscript
extends Node

## 全局游戏管理 — 持有 TurnManager，加载卡组，初始化游戏

var turn_manager: TurnManager = null


func _ready() -> void:
    print("[GameManager] Initialized")
    # 延迟一帧等场景树就绪后自动开始
    call_deferred("_start_local_game")


func _start_local_game() -> void:
    # 加载卡组
    var deck_data := _load_deck("res://data/decks/player_default.json")
    if deck_data.is_empty():
        printerr("[GameManager] Failed to load deck!")
        return
    var cards: Array[String] = deck_data["cards"]
    var starter: String = deck_data["starter"]

    # 创建 TurnManager
    turn_manager = TurnManager.new()
    turn_manager.name = "TurnManager"
    get_tree().current_scene.add_child(turn_manager)

    # 连接 Board 和 HandManager
    var board: Board = _find_node_of_type(get_tree().current_scene, "Board")
    if board:
        board.setup(turn_manager)

    var hand: HandManager = _find_node_of_type(get_tree().current_scene, "HandManager")
    if hand:
        hand.setup(turn_manager)
        hand.card_purchased.connect(func(card_id: String):
            turn_manager.submit_action({"type": "purchase", "card_id": card_id})
        )
        hand.card_deployed.connect(func(card_id: String, row: int, col: int):
            # 部署到点击位置（-1,-1 表示需手动选格，此处先用固定位置）
            var player_idx := turn_manager.get_state().active_player_index
            var deploy_row := 0 if player_idx == 0 else 4
            turn_manager.submit_action({"type": "deploy", "card_id": card_id, "row": deploy_row, "col": 0})
        )
        hand.end_turn_pressed.connect(func():
            turn_manager.submit_action({"type": "end_turn"})
        )
        hand.skip_phase_pressed.connect(func():
            turn_manager.submit_action({"type": "skip_phase"})
        )

    # 开始游戏
    turn_manager.start_game(cards.duplicate(), cards.duplicate(), starter, starter)
    print("[GameManager] Local game started")


func _load_deck(path: String) -> Dictionary:
    var file := FileAccess.open(path, FileAccess.READ)
    if file == null:
        printerr("[GameManager] Cannot read deck: %s" % path)
        return {}
    var json_text := file.get_as_text()
    file.close()
    var json := JSON.new()
    if json.parse(json_text) != OK:
        printerr("[GameManager] JSON parse error in deck: %s" % path)
        return {}
    return json.get_data()


func _find_node_of_type(root: Node, type_name: String) -> Node:
    if root.script and root.script.resource_path.ends_with(type_name.to_case_snake() + ".gd"):
        return root
    for child in root.get_children():
        var found := _find_node_of_type(child, type_name)
        if found:
            return found
    return null
```

- [ ] **Step 2: 在 Godot 编辑器中更新 BattleScene**

打开 `scenes/battle.tscn`，确保场景结构如下：

```
BattleScene (Node2D, 挂 board.gd)
├── HandManager (Node2D, 挂 hand_manager.gd)
└── [BoardSlot 子节点由 board.gd 动态创建]
```

在场景根节点下新增 `HandManager` 子节点（Node2D），挂载 `scripts/ui/hand_manager.gd`。

- [ ] **Step 3: 验证 — F5 运行**

预期行为：
1. 控制台输出初始化信息
2. 左侧显示待购买区（含首发卡）+ 手牌（初始 3 张）
3. 显示 G/K/Z 资源值和回合/阶段信息
4. 可点击"跳过阶段"推进到部署阶段
5. 可点击"结束回合"切换到对手

- [ ] **Step 4: Commit**

```bash
git add scripts/autoload/game_manager.gd scenes/battle.tscn
git commit -m "feat: integrate GameManager, TurnManager, Board, HandManager for local battle loop"
```

---

## 验证清单

全部 Task 完成后，确认：

1. ✅ F5 运行无报错
2. ✅ 待购买区显示首发卡 + 初始 3 张
3. ✅ 可购买卡牌（花费 G），进入手牌
4. ✅ 可部署单位（花费 Z），出现在棋盘
5. ✅ 单位显示攻防属性
6. ✅ 对方回合时对方单位显示为灰色迷雾
7. ✅ 点击"结束回合"切换玩家，资源刷新
8. ✅ 攻击/移动/反击按规则结算
9. ✅ 一方占领全部 5 列敌方阵地时游戏结束
10. ✅ JSON 卡牌数据可编辑
