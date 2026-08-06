# Phase 3: 卡牌扩展 — 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 Phase 2 本地对战基础上，扩展 3→15 张卡（含坦克/战斗机/轰炸机），实现 6 个新词条 + 简化迷雾 + 资源系统重整（Z 部署/移动/攻击，K 指令卡专用）

**Architecture:** 增量修改 BattleState (UnitData/PlayerData 新字段) + GameLogic (新方法 + 重写 attack/move/start_turn) + Board (迷雾可见性)，TurnManager/HandManager 不变

**Tech Stack:** Godot 4.7.1, GDScript, JSON

## Global Constraints

- Godot 4.7.1，纯 2D
- 卡牌 JSON 存储，非程序员可编辑
- BattleState 唯一数据源，GameLogic 纯函数，信号驱动 UI
- 三种资源：G（经济/+150/累积）、Z（战争点/部署移动攻击/先手1+2x后手2+2x/上限25）、K（指挥点/指令卡/回合数/上限10）
- 6 种单位：步兵/骑兵/火炮/坦克/战斗机/轰炸机（工事推迟）
- 10 个词条：Phase 2 的 4 个（突击/坚守/冲锋/收缴）+ Phase 3 的 6 个（守护/响应/防空/补给/修复/潜行）
- 棋盘 5×5，P1 行 0-1，P2 行 3-4，行 2 中立
- 简化迷雾：无残影记忆，视野外=灰色方块
- 不实现：工事/爆破/策反/掩护/巡逻/钳击/工程/卡组编辑器/网络

---

### Task 1: UnitData + PlayerData 新字段 + 资源公式重写

**Files:**
- Modify: `scripts/core/battle_state.gd` — UnitData 新增 10 字段，PlayerData 新增 1 字段
- Modify: `scripts/core/game_logic.gd` — `start_turn()` 资源公式改为新规则

**Interfaces:**
- Consumes: Phase 2 的 `BattleState.UnitData`, `BattleState.PlayerData`, `GameLogic.start_turn()`
- Produces:
  - `UnitData` 新字段：`stealthed: bool`, `revealed: bool`, `has_attacked: bool`, `move_count: int`, `move_limit: int`, `can_move_after_attack: bool`, `is_guarded: bool`, `guarded_by: Vector2i`, `firm_level: int`, `supply_level: int`
  - `PlayerData` 新字段：`hand_card_purchase_turn: Dictionary`
  - `GameLogic._calc_z(player_idx, turn) -> int` — 战争点公式
  - `GameLogic.start_turn()` 新资源公式

- [ ] **Step 1: 在 UnitData 内类末尾追加新字段**

修改 `scripts/core/battle_state.gd`，在 UnitData 类中 `deployed_this_turn` 之后追加：

```gdscript
## Phase 3 新增字段
var stealthed: bool = false              # 是否有潜行词条
var revealed: bool = false               # 是否被敌方发现（每回合重新计算）
var has_attacked: bool = false           # 本回合是否已攻击
var move_count: int = 0                  # 本回合已移动次数
var move_limit: int = 1                  # 本回合移动上限（坦克 = 99）
var can_move_after_attack: bool = false  # 攻击后是否仍可移动（坦克 = true）
var is_guarded: bool = false             # 是否有守护单位保护
var guarded_by: Vector2i = Vector2i(-1, -1)  # 守护单位位置
var firm_level: int = 0                  # 坚守等级（0 = 无坚守）
var supply_level: int = 0                # 补给等级（0 = 无补给）
```

- [ ] **Step 2: 在 PlayerData 内类末尾追加新字段**

修改 `scripts/core/battle_state.gd`，在 PlayerData 类末尾追加：

```gdscript
## Phase 3 新增：记录每张手牌的购买回合（用于响应词条判定）
var hand_card_purchase_turn: Dictionary = {}  # {card_id: turn_number}
```

- [ ] **Step 3: 修改 GameLogic.start_turn() 资源公式**

修改 `scripts/core/game_logic.gd`，将原有的资源分配逻辑替换为 Phase 3 公式。

找到 `start_turn()` 方法中设置资源的部分（原：`player.resources["G"] += 150`, `player.resources["K"] = new_state.turn`, `player.resources["Z"] = new_state.turn`），改为：

```gdscript
static func start_turn(state: BattleState) -> BattleState:
    var new_state := state.duplicate(true)
    var player = new_state.players[new_state.active_player_index]
    # G +150（不变）
    player.resources["G"] += 150
    # Z = 先手 1+2x / 后手 2+2x, 上限 25
    player.resources["Z"] = _calc_z(new_state.active_player_index, new_state.turn)
    # K = 回合数, 上限 10
    player.resources["K"] = min(new_state.turn, 10)
    # 抽 1 张
    _draw_one(new_state, new_state.active_player_index)
    # 重置单位行动标记（Phase 3 扩展：同时重置 has_attacked, move_count）
    for r in range(new_state.board.rows):
        for c in range(new_state.board.cols):
            var unit := new_state.board.get_unit(r, c)
            if unit != null and unit.owner_index == new_state.active_player_index:
                unit.has_acted = false
                unit.has_attacked = false
                unit.move_count = 0
                unit.deployed_this_turn = false
    new_state.phase = "purchase"
    return new_state
```

- [ ] **Step 4: 新增 _calc_z() 静态方法**

在 `game_logic.gd` 中 `_shuffle_deck` 附近追加：

```gdscript
## Phase 3: 战争点公式
## 先手 (player_idx=0): 1 + 2×(turn−1) → 1, 3, 5, 7, ...
## 后手 (player_idx=1): 2 + 2×(turn−1) → 2, 4, 6, 8, ...
## 上限 25
static func _calc_z(player_idx: int, turn: int) -> int:
    var base := 1 if player_idx == 0 else 2
    var z := base + 2 * (turn - 1)
    return min(z, 25)
```

- [ ] **Step 5: 修改所有消耗 K 的地方改为消耗 Z**

在 `game_logic.gd` 中搜索涉及 `player.resources["K"]` 的消耗逻辑。Phase 2 中 `move_unit()` 和 `attack_unit()` 消耗 K，`deploy_unit()` 消耗 Z。Phase 3 统一改为消耗 Z：

`move_unit()` 中的消耗检查：
```gdscript
# 原：if player.resources["K"] < 1: return new_state
# 改为：
if player.resources["Z"] < 1:
    return new_state
player.resources["Z"] -= 1
```

`attack_unit()` 中的消耗检查：
```gdscript
# 原：if player.resources["K"] < 1: return new_state
# 改为：
if player.resources["Z"] < 1:
    return new_state
player.resources["Z"] -= 1
```

`deploy_unit()` 中的消耗（原：`player.resources["Z"] < card_data.cost_k`，已正确，保持不变）。

- [ ] **Step 6: 更新 end_turn() 清空逻辑**

`end_turn()` 中清空资源时，确保 Z 和 K 都被清空：

```gdscript
# 原：new_state.players[new_state.active_player_index].resources["K"] = 0
#     new_state.players[new_state.active_player_index].resources["Z"] = 0
# 保持不变，Phase 3 继续清空两者
```

- [ ] **Step 7: 验证 — F5 运行确认无语法错误**

在 Godot 编辑器中按 F5，确认控制台无报错，游戏初始化正常。

- [ ] **Step 8: Commit**

```bash
git add scripts/core/battle_state.gd scripts/core/game_logic.gd
git commit -m "feat: add Phase 3 UnitData/PlayerData fields + resource formula rework (Z for actions, K for orders)"
```

---

### Task 2: 词条等级解析 + 单位属性初始化

**Files:**
- Modify: `scripts/core/game_logic.gd`

**Interfaces:**
- Consumes: UnitData 新字段（Task 1），CardDataLoader.abilities
- Produces:
  - `GameLogic._parse_ability_level(abilities: Array, prefix: String) -> int`
  - `GameLogic._init_unit_from_card(unit: UnitData, card_data: CardData)` — 部署时初始化所有 Phase 3 字段
  - `GameLogic._is_air_unit(unit_class: String) -> bool`

- [ ] **Step 1: 新增 _parse_ability_level()**

在 `game_logic.gd` 中追加：

```gdscript
## 从 abilities 数组中解析带等级的词条
## 如 ["坚守2", "冲锋"] → _parse_ability_level(abilities, "坚守") 返回 2
##    _parse_ability_level(abilities, "补给") 返回 0（无此词条）
## 不带数字的默认为等级 1
static func _parse_ability_level(abilities: Array, prefix: String) -> int:
    for ability in abilities:
        var a: String = ability
        if a == prefix:
            return 1
        if a.begins_with(prefix) and a.length() > prefix.length():
            var suffix := a.substr(prefix.length())
            if suffix.is_valid_int():
                return suffix.to_int()
    return 0
```

- [ ] **Step 2: 新增 _is_air_unit()**

```gdscript
## 判断单位类别是否为空军
static func _is_air_unit(unit_class: String) -> bool:
    return unit_class == "fighter" or unit_class == "bomber"
```

- [ ] **Step 3: 新增 _init_unit_from_card()**

在 `game_logic.gd` 中追加，用于 `deploy_unit()` 中初始化单位的所有 Phase 3 属性：

```gdscript
## 根据 CardData 初始化 UnitData 的 Phase 3 扩展字段
static func _init_unit_from_card(unit: BattleState.UnitData, card_data: Resource) -> void:
    # 坚守等级（坦克默认 1，其他从 abilities 解析）
    unit.firm_level = _parse_ability_level(card_data.abilities, "坚守")
    if card_data.unit_class == "tank" and unit.firm_level == 0:
        unit.firm_level = 1  # 坦克默认坚守 1
    # 补给等级
    unit.supply_level = _parse_ability_level(card_data.abilities, "补给")
    # 潜行
    unit.stealthed = card_data.abilities.has("潜行")
    unit.revealed = false
    # 移动规则
    match card_data.unit_class:
        "tank":
            unit.move_limit = 99              # 无限制
            unit.can_move_after_attack = true
        "fighter", "bomber":
            unit.move_limit = 1
            unit.can_move_after_attack = false
            # 空军：移动和攻击各一次（由 has_acted + has_attacked 分开控制）
        _:
            unit.move_limit = 1
            unit.can_move_after_attack = false
```

- [ ] **Step 4: 修改 deploy_unit() 调用 _init_unit_from_card()**

在 `deploy_unit()` 中，创建 UnitData 并赋值基本字段后，追加：

```gdscript
    # Phase 3: 初始化扩展字段
    _init_unit_from_card(unit, card_data)
```

- [ ] **Step 5: 验证 — F5 运行确认无语法错误**

- [ ] **Step 6: Commit**

```bash
git add scripts/core/game_logic.gd
git commit -m "feat: add ability level parser + unit init from CardData for Phase 3"
```

---

### Task 3: 移动规则差异化（坦克/空军/标准）

**Files:**
- Modify: `scripts/core/game_logic.gd` — `move_unit()`

**Interfaces:**
- Consumes: UnitData 的 `move_limit`, `can_move_after_attack`, `has_attacked`, `move_count`（Task 1）
- Produces: 重写的 `move_unit()` 支持三种移动模式

- [ ] **Step 1: 重写 move_unit()**

用以下代码替换 `game_logic.gd` 中的 `move_unit()` 方法：

```gdscript
static func move_unit(state: BattleState, player_idx: int, from_row: int, from_col: int, to_row: int, to_col: int) -> BattleState:
    var new_state := state.duplicate(true)
    var unit := new_state.board.get_unit(from_row, from_col)
    if unit == null or unit.owner_index != player_idx:
        return new_state

    # 检查移动次数
    if unit.move_count >= unit.move_limit:
        return new_state

    # 标准单位：移动或攻击共一次（has_acted 检查）
    # 坦克/空军：has_acted 不阻挡（由 move_count/has_attacked 分别控制）
    if unit.move_limit <= 1 and not unit.can_move_after_attack:
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

    # Z 消耗（Phase 3: 移动消耗 Z）
    var player = new_state.players[player_idx]
    if player.resources["Z"] < 1:
        return new_state
    player.resources["Z"] -= 1

    # 执行移动
    new_state.board.set_unit(from_row, from_col, null)
    new_state.board.set_unit(to_row, to_col, unit)
    unit.move_count += 1
    unit.has_acted = true
    new_state.action_log.append({"type": "move", "player": player_idx, "from": [from_row, from_col], "to": [to_row, to_col]})
    return new_state
```

- [ ] **Step 2: 重写 attack_unit() 的行动标记逻辑**

`attack_unit()` 中用 `has_attacked` 替代原有的 `has_acted` 检查（完整版在 Task 4 做空战规则时进一步修改）。先改行动标记部分：

找到 `attack_unit()` 中 `attacker.has_acted` 检查，改为：

```gdscript
    # 检查是否已攻击
    if attacker.has_attacked:
        return new_state
```

并在攻击成功后，将：
```gdscript
    attacker.has_acted = true
```
改为：
```gdscript
    attacker.has_acted = true
    attacker.has_attacked = true
```

- [ ] **Step 3: 验证 — F5 运行，确认三种单位移动规则正确**

预期行为：
- 步兵/骑兵/火炮：移动或攻击各一次
- 坦克：可多次移动 + 一次攻击（攻击前后均可移动）
- 战斗机/轰炸机：移动一次 + 攻击一次（各自独立）

- [ ] **Step 4: Commit**

```bash
git add scripts/core/game_logic.gd
git commit -m "feat: differentiate movement rules (tank unlimited, air move+attack separate)"
```

---

### Task 4: 空战规则

**Files:**
- Modify: `scripts/core/game_logic.gd` — `attack_unit()`, `_counter_attack()`, `_in_attack_range()`

**Interfaces:**
- Consumes: `_is_air_unit()` (Task 2), 新射程字符串 `column_and_neighbors`
- Produces: 修改后的 `attack_unit()` 含空战判定，修改后的 `_counter_attack()` 含空战反击规则，扩展的 `_in_attack_range()` 支持新射程

- [ ] **Step 1: 扩展 _in_attack_range() 支持 column_and_neighbors**

在 `_in_attack_range()` 的 match 中追加：

```gdscript
    match range_str:
        "adjacent_4":
            return dr <= 1 and dc <= 1 and not (dr == 0 and dc == 0)
        "adjacent_8":
            return dr <= 1 and dc <= 1 and not (dr == 0 and dc == 0)
        "column_and_neighbors":
            # 本列 + 相邻两列，任意行
            return abs(from_col - target_col) <= 1 and not (dr == 0 and dc == 0)
        "global":
            return true
        _:
            return dr <= 1 and dc <= 1 and not (dr == 0 and dc == 0)
```

- [ ] **Step 2: 在 attack_unit() 开头追加空战合法性检查**

在 `attack_unit()` 中，获取 attacker 和 defender 之后，Z 消耗检查之前，追加：

```gdscript
    # Phase 3: 空战规则 — 陆军不能攻击空军
    var attacker_card := CardDataLoader.cards.get(attacker.card_id)
    var defender_card := CardDataLoader.cards.get(defender.card_id)
    if attacker_card != null and defender_card != null:
        var atk_is_air := _is_air_unit(attacker_card.unit_class)
        var def_is_air := _is_air_unit(defender_card.unit_class)
        # 陆军攻击空军 → 无效
        if not atk_is_air and def_is_air:
            return new_state
        # 轰炸机攻击空军 → 无效（轰炸机只能打陆军）
        if attacker_card.unit_class == "bomber" and def_is_air:
            return new_state
```

- [ ] **Step 3: 重写 _counter_attack() 含空战反击规则**

用以下代码替换 `_counter_attack()` 方法：

```gdscript
static func _counter_attack(attacker: BattleState.UnitData, defender: BattleState.UnitData, atk_row: int, atk_col: int, def_row: int, def_col: int, state: BattleState) -> void:
    # Phase 2 规则：突击/冲锋首次攻击免反击
    if attacker.abilities.has("突击") and attacker.deployed_this_turn:
        return
    if attacker.abilities.has("冲锋") and attacker.deployed_this_turn:
        return

    # Phase 3: 空战反击规则
    var attacker_card := CardDataLoader.cards.get(attacker.card_id)
    var defender_card := CardDataLoader.cards.get(defender.card_id)
    if attacker_card != null and defender_card != null:
        # 火炮不可被反击（Phase 2 规则，保留）
        if attacker_card.unit_class == "artillery":
            return
        # 轰炸机无法反击
        if defender_card.unit_class == "bomber":
            return
        # 非战斗机单位无法反击轰炸机
        if attacker_card.unit_class == "bomber" and defender_card.unit_class != "fighter":
            return
        # 陆军被空军攻击：只有防空词条能反击
        var def_is_air := _is_air_unit(defender_card.unit_class)
        var atk_is_air := _is_air_unit(attacker_card.unit_class)
        if atk_is_air and not def_is_air:
            if not defender.abilities.has("防空"):
                return

    # 防守方反击
    var counter_dmg := defender.attack
    # 坚守减伤（Phase 3: 使用 firm_level 替代固定值）
    if attacker.firm_level > 0:
        counter_dmg = max(1, counter_dmg - attacker.firm_level)
    attacker.defense -= counter_dmg
    state.action_log.append({"type": "counter", "damage": counter_dmg})
    if attacker.defense <= 0:
        state.board.set_unit(atk_row, atk_col, null)
        state.action_log.append({"type": "destroy", "card_id": attacker.card_id, "reward_g": 0})
```

- [ ] **Step 4: 修改 attack_unit() 中的伤害计算使用 firm_level**

找到原 `attack_unit()` 中坚守减伤逻辑：
```gdscript
    if defender.abilities.has("坚守"):
        var firm_level := 1
        damage = max(1, damage - firm_level)
```

改为：
```gdscript
    if defender.firm_level > 0:
        damage = max(1, damage - defender.firm_level)
```

- [ ] **Step 5: 验证 — F5 运行确认无语法错误**

- [ ] **Step 6: Commit**

```bash
git add scripts/core/game_logic.gd
git commit -m "feat: add air combat rules + column_and_neighbors range + firm_level damage calc"
```

---

### Task 5: 守护 / 响应 / 防空 / 补给 / 修复 / 潜行 词条实现

**Files:**
- Modify: `scripts/core/game_logic.gd` — 新增 6 个词条方法 + 修改现有方法调用

**Interfaces:**
- Consumes: UnitData 新字段（Task 1），`_parse_ability_level()`（Task 2），空战规则（Task 4）
- Produces: 6 个词条的完整 GameLogic 实现

- [ ] **Step 1: 新增 _apply_guard() 和 _clear_guard()**

```gdscript
## 部署后有守护词条的单位，给相邻八格友方单位加"被守护"
static func _apply_guard(state: BattleState, unit: BattleState.UnitData) -> void:
    if not unit.abilities.has("守护"):
        return
    var row := unit.row
    var col := unit.col
    for dr in range(-1, 2):
        for dc in range(-1, 2):
            if dr == 0 and dc == 0:
                continue
            var nr := row + dr
            var nc := col + dc
            var neighbor := state.board.get_unit(nr, nc)
            if neighbor != null and neighbor.owner_index == unit.owner_index:
                neighbor.is_guarded = true
                neighbor.guarded_by = Vector2i(row, col)


## 守护单位离场/移动前，清除所有指向它的"被守护"
static func _clear_guard(state: BattleState, unit: BattleState.UnitData) -> void:
    for r in range(state.board.rows):
        for c in range(state.board.cols):
            var other := state.board.get_unit(r, c)
            if other != null and other.guarded_by == Vector2i(unit.row, unit.col):
                other.is_guarded = false
                other.guarded_by = Vector2i(-1, -1)
```

- [ ] **Step 2: 在 deploy_unit() 和 move_unit() 中调用守护逻辑**

`deploy_unit()` 中部署成功后追加：
```gdscript
    _apply_guard(new_state, unit)
```

`move_unit()` 中移动前调用 `_clear_guard`，移动后调用 `_apply_guard`：
```gdscript
    _clear_guard(new_state, unit)
    # ... 执行移动 ...
    _apply_guard(new_state, unit)
```

- [ ] **Step 3: 在 attack_unit() 中追加守护转移逻辑**

在 `attack_unit()` 中获取 defender 之后、伤害计算之前追加：

```gdscript
    # Phase 3: 被守护单位伤害转移
    if defender.is_guarded:
        var guard_pos: Vector2i = defender.guarded_by
        var guard_unit := new_state.board.get_unit(guard_pos.x, guard_pos.y)
        if guard_unit != null and guard_unit.owner_index == defender.owner_index:
            defender = guard_unit  # 攻击目标改为守护单位
```

- [ ] **Step 4: 新增 _apply_supply() 和 _apply_rear_repair()**

```gdscript
## 补给词条：友方回合开始时，修复相邻一个已受伤单位
static func _apply_supply(state: BattleState, player_idx: int) -> void:
    for r in range(state.board.rows):
        for c in range(state.board.cols):
            var unit := state.board.get_unit(r, c)
            if unit == null or unit.owner_index != player_idx:
                continue
            if unit.supply_level <= 0:
                continue
            # 找相邻八格中一个已受伤的友方单位
            for dr in range(-1, 2):
                for dc in range(-1, 2):
                    if dr == 0 and dc == 0:
                        continue
                    var neighbor := state.board.get_unit(r + dr, c + dc)
                    if neighbor != null and neighbor.owner_index == player_idx and neighbor.defense < neighbor.max_defense:
                        neighbor.defense = min(neighbor.max_defense, neighbor.defense + unit.supply_level)
                        state.action_log.append({"type": "supply", "from": [r, c], "to": [r + dr, c + dc], "amount": unit.supply_level})
                        return  # 只修复一个


## 后方修复规则：处于后方（P1 行 0 / P2 行 4）的单位每回合恢复 1 防御力
static func _apply_rear_repair(state: BattleState, player_idx: int) -> void:
    var rear_row := 0 if player_idx == 0 else 4
    for c in range(state.board.cols):
        var unit := state.board.get_unit(rear_row, c)
        if unit != null and unit.owner_index == player_idx and unit.defense < unit.max_defense:
            unit.defense = min(unit.max_defense, unit.defense + 1)
            state.action_log.append({"type": "rear_repair", "row": rear_row, "col": c})
```

- [ ] **Step 5: 在 start_turn() 中调用补给和后方修复**

在 `start_turn()` 末尾（`new_state.phase = "purchase"` 之前）追加：

```gdscript
    _apply_supply(new_state, new_state.active_player_index)
    _apply_rear_repair(new_state, new_state.active_player_index)
```

- [ ] **Step 6: 新增 _update_stealth_reveal()**

```gdscript
## 重新计算所有潜行单位的 revealed 状态
## 处于敌方步兵或战斗机视野范围内的潜行单位 → revealed = true
static func _update_stealth_reveal(state: BattleState) -> void:
    for r in range(state.board.rows):
        for c in range(state.board.cols):
            var unit := state.board.get_unit(r, c)
            if unit == null or not unit.stealthed:
                continue
            unit.revealed = false
            var enemy_idx := 1 - unit.owner_index
            # 检查是否有敌方步兵/战斗机能看到此位置
            for er in range(state.board.rows):
                for ec in range(state.board.cols):
                    var enemy := state.board.get_unit(er, ec)
                    if enemy == null or enemy.owner_index != enemy_idx:
                        continue
                    var enemy_card := CardDataLoader.cards.get(enemy.card_id)
                    if enemy_card == null:
                        continue
                    # 步兵或战斗机能发现潜行单位
                    if enemy_card.unit_class != "infantry" and enemy_card.unit_class != "fighter":
                        continue
                    if _in_vision_range(enemy_card.vision_range, er, ec, r, c, enemy_idx):
                        unit.revealed = true
                        break
                if unit.revealed:
                    break
```

- [ ] **Step 7: 新增 _in_vision_range() 视野判定函数**

```gdscript
## 视野范围判定（与攻击范围判定分开）
static func _in_vision_range(vision_str: String, from_row: int, from_col: int, to_row: int, to_col: int, owner_idx: int) -> bool:
    var dr := to_row - from_row  # 带符号的方向
    var adr := abs(dr)
    var adc := abs(to_col - from_col)
    # 确定"前方"方向：P1(owner=0) 前方是行号增大，P2(owner=1) 前方是行号减小
    var forward_dr := dr if owner_idx == 0 else -dr
    match vision_str:
        "adjacent_4":
            return (adr + adc) == 1  # 仅上下左右
        "adjacent_8":
            return adr <= 1 and adc <= 1 and not (adr == 0 and adc == 0)
        "adjacent_8_forward":
            # 周围八格 + 向前第二格（共 12 格）
            if adr <= 1 and adc <= 1 and not (adr == 0 and adc == 0):
                return true
            if forward_dr == 2 and adc == 0:
                return true
            return false
        "front_3x2":
            # 前方横向 3 列 × 2 行
            return forward_dr >= 1 and forward_dr <= 2 and adc <= 1
        "front_3x3":
            # 前方横向 3 列 × 3 行
            return forward_dr >= 1 and forward_dr <= 3 and adc <= 1
        "frontline_only":
            return dr == 0 and adc <= 1
        "none":
            return false
        _:
            return adr <= 1 and adc <= 1 and not (adr == 0 and adc == 0)
```

- [ ] **Step 8: 在 start_turn() 中调用 _update_stealth_reveal()**

在 start_turn() 末尾追加：
```gdscript
    _update_stealth_reveal(new_state)
```

- [ ] **Step 9: 在 deploy_unit() 中实现响应词条检查**

修改 `deploy_unit()` 中手牌检查逻辑。找到 `player.hand.has(card_id)` 检查之后，追加：

```gdscript
    # Phase 3: 响应词条检查 — 本回合购买的卡只能在有"响应"词条时部署
    var purchase_turn: int = player.hand_card_purchase_turn.get(card_id, -1)
    if purchase_turn == new_state.turn:
        if not card_data.abilities.has("响应"):
            return new_state  # 本回合购买但无响应词条，不能部署
```

- [ ] **Step 10: 在 purchase_card() 中记录购买回合**

在 `purchase_card()` 购买成功后（`player.hand.append(card_id)` 之后）追加：

```gdscript
    player.hand_card_purchase_turn[card_id] = new_state.turn
```

- [ ] **Step 11: 在 Board 的 _clear_unit_displays() 中也处理死亡时的守护清除**

在 `attack_unit()` 中单位被消灭时，调用 `_clear_guard`：

找到 `new_state.board.set_unit(target_row, target_col, null)`（消灭 defender 时），在前面追加：
```gdscript
        _clear_guard(new_state, defender)
```

同样，`_counter_attack()` 中消灭 attacker 时：
```gdscript
        _clear_guard(state, attacker)  # 在 set_unit(null) 之前
```

- [ ] **Step 12: 验证 — F5 运行确认无语法错误**

- [ ] **Step 13: Commit**

```bash
git add scripts/core/game_logic.gd
git commit -m "feat: implement 6 new abilities (guard, response, anti-air, supply, repair, stealth)"
```

---

### Task 6: 简化迷雾系统 — Board 可见性

**Files:**
- Modify: `scripts/ui/board.gd` — 新增 `_update_visibility()`
- Modify: `scripts/ui/card_display.gd` — 新增 `set_visible_to_enemy()`

**Interfaces:**
- Consumes: `_in_vision_range()` (Task 5), `BattleState` + `UnitData.stealthed/revealed` (Task 1)
- Produces: Board 迷雾可见性系统

- [ ] **Step 1: 在 CardDisplay 中新增 set_visible_to_enemy()**

修改 `scripts/ui/card_display.gd`，追加：

```gdscript
## Phase 3: 迷雾系统 — 控制敌方可见性
var _fog_overlay: ColorRect = null
var _is_fogged: bool = false
var _unit_stealthed: bool = false
var _unit_revealed: bool = false

func set_visible_to_enemy(v: bool, stealthed: bool = false, revealed: bool = false) -> void:
    _unit_stealthed = stealthed
    _unit_revealed = revealed
    # 潜行且未被发现 → 完全不显示
    if stealthed and not revealed:
        hide()
        return
    show()
    if v:
        # 可见：移除迷雾
        _is_fogged = false
        if _fog_overlay != null:
            _fog_overlay.queue_free()
            _fog_overlay = null
    else:
        # 不可见：添加灰色迷雾
        if _fog_overlay == null:
            _fog_overlay = ColorRect.new()
            _fog_overlay.size = CARD_SIZE
            _fog_overlay.color = Color(0.15, 0.15, 0.15, 1.0)
            _fog_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
            add_child(_fog_overlay)
        _is_fogged = true
```

- [ ] **Step 2: 在 Board 中新增 _update_visibility()**

修改 `scripts/ui/board.gd`，追加：

```gdscript
## Phase 3: 迷雾可见性计算
func _update_visibility(state: BattleState) -> void:
    if state == null:
        return
    var viewer_idx := state.active_player_index
    # 1. 收集本方所有单位的视野覆盖格子
    var visible_cells: Dictionary = {}  # {Vector2i: true}
    for r in range(state.board.rows):
        for c in range(state.board.cols):
            var unit := state.board.get_unit(r, c)
            if unit == null or unit.owner_index != viewer_idx:
                continue
            var card_data := CardDataLoader.cards.get(unit.card_id)
            if card_data == null:
                continue
            # 遍历棋盘所有格子，判定是否在此单位的视野内
            for tr in range(state.board.rows):
                for tc in range(state.board.cols):
                    if GameLogic._in_vision_range(card_data.vision_range, r, c, tr, tc, viewer_idx):
                        visible_cells[Vector2i(tr, tc)] = true
    # 2. 更新每个敌方单位的显示
    for r in range(state.board.rows):
        for c in range(state.board.cols):
            var unit := state.board.get_unit(r, c)
            if unit == null or unit.owner_index == viewer_idx:
                continue  # 跳过己方单位（始终可见）
            var key := Vector2i(r, c)
            var display := _unit_displays.get(key)
            if display == null or not is_instance_valid(display):
                continue
            var is_visible := visible_cells.has(key)
            display.set_visible_to_enemy(is_visible, unit.stealthed, unit.revealed)
```

- [ ] **Step 3: 在 Board._on_state_changed() 中调用 _update_visibility()**

在 `_on_state_changed()` 方法中 `_render_units()` 之后追加：

```gdscript
    _update_visibility(new_state)
```

- [ ] **Step 4: 在 Board._render_units() 中移除旧的 _fog_display() 调用**

Phase 2 的 `_render_units()` 中有 `_fog_display(display)` 调用。删除这一行，改为由 `_update_visibility()` 统一处理。

- [ ] **Step 5: 删除 Board 的旧 _fog_display() 方法**

删除或注释掉 `_fog_display()` 方法（功能已由 CardDisplay.set_visible_to_enemy() 取代）。

- [ ] **Step 6: 验证 — F5 运行，确认迷雾正常**

预期：
- 己方单位始终可见（完整信息）
- 敌方单位：在视野外 → 灰色方块覆盖；进入视野 → 正常显示；离开视野 → 恢复灰色
- 潜行敌方单位：未发现 → 完全不显示

- [ ] **Step 7: Commit**

```bash
git add scripts/ui/board.gd scripts/ui/card_display.gd
git commit -m "feat: add simplified fog-of-war visibility system (Board + CardDisplay)"
```

---

### Task 7: 12 张新卡 JSON + 更新卡组

**Files:**
- Create: `data/cards/units/infantry_02.json`
- Create: `data/cards/units/infantry_03.json`
- Create: `data/cards/units/cavalry_02.json`
- Create: `data/cards/units/artillery_02.json`
- Create: `data/cards/units/tank_01.json`
- Create: `data/cards/units/tank_02.json`
- Create: `data/cards/units/tank_03.json`
- Create: `data/cards/units/fighter_01.json`
- Create: `data/cards/units/fighter_02.json`
- Create: `data/cards/units/fighter_03.json`
- Create: `data/cards/units/bomber_01.json`
- Create: `data/cards/units/bomber_02.json`
- Modify: `data/decks/player_default.json`（更新卡组列表）

**Interfaces:**
- Consumes: CardDataLoader JSON 加载机制（已有）
- Produces: 12 张单位卡 JSON + 更新后的默认卡组

- [ ] **Step 1: 创建 infantry_02.json**

`data/cards/units/infantry_02.json`：
```json
{
  "id": "infantry_02",
  "name": "近卫步兵",
  "nation": "neutral",
  "type": "unit",
  "unit_class": "infantry",
  "cost_g": 40,
  "cost_k": 1,
  "attack": 3,
  "defense": 5,
  "vision_range": "adjacent_4",
  "attack_range": "adjacent_4",
  "abilities": ["守护"],
  "rarity": "common",
  "art": "",
  "flavor_text": "守护阵线，一步不退。"
}
```

- [ ] **Step 2: 创建 infantry_03.json**

`data/cards/units/infantry_03.json`：
```json
{
  "id": "infantry_03",
  "name": "突击步兵",
  "nation": "neutral",
  "type": "unit",
  "unit_class": "infantry",
  "cost_g": 40,
  "cost_k": 1,
  "attack": 2,
  "defense": 3,
  "vision_range": "adjacent_4",
  "attack_range": "adjacent_4",
  "abilities": ["响应"],
  "rarity": "common",
  "art": "",
  "flavor_text": "接到命令即刻出发。"
}
```

- [ ] **Step 3: 创建 cavalry_02.json**

`data/cards/units/cavalry_02.json`：
```json
{
  "id": "cavalry_02",
  "name": "哥萨克骑兵",
  "nation": "neutral",
  "type": "unit",
  "unit_class": "cavalry",
  "cost_g": 50,
  "cost_k": 2,
  "attack": 3,
  "defense": 3,
  "vision_range": "adjacent_4",
  "attack_range": "adjacent_4",
  "abilities": ["冲锋", "收缴"],
  "rarity": "silver",
  "art": "",
  "flavor_text": "来去如风，劫掠如火。"
}
```

- [ ] **Step 4: 创建 artillery_02.json**

`data/cards/units/artillery_02.json`：
```json
{
  "id": "artillery_02",
  "name": "重型火炮",
  "nation": "neutral",
  "type": "unit",
  "unit_class": "artillery",
  "cost_g": 70,
  "cost_k": 2,
  "attack": 7,
  "defense": 1,
  "vision_range": "front_3x3",
  "attack_range": "global",
  "abilities": [],
  "rarity": "silver",
  "art": "",
  "flavor_text": "一声巨响，地动山摇。"
}
```

- [ ] **Step 5: 创建 tank_01.json**

`data/cards/units/tank_01.json`：
```json
{
  "id": "tank_01",
  "name": "轻型坦克",
  "nation": "neutral",
  "type": "unit",
  "unit_class": "tank",
  "cost_g": 60,
  "cost_k": 2,
  "attack": 4,
  "defense": 4,
  "vision_range": "adjacent_8_forward",
  "attack_range": "adjacent_8",
  "abilities": ["坚守"],
  "rarity": "common",
  "art": "",
  "flavor_text": "钢铁巨兽初现战场。"
}
```

- [ ] **Step 6: 创建 tank_02.json**

`data/cards/units/tank_02.json`：
```json
{
  "id": "tank_02",
  "name": "装甲坦克",
  "nation": "neutral",
  "type": "unit",
  "unit_class": "tank",
  "cost_g": 80,
  "cost_k": 3,
  "attack": 5,
  "defense": 6,
  "vision_range": "adjacent_8_forward",
  "attack_range": "adjacent_8",
  "abilities": ["坚守", "补给"],
  "rarity": "silver",
  "art": "",
  "flavor_text": "移动的堡垒，兼具维修能力。"
}
```

- [ ] **Step 7: 创建 tank_03.json**

`data/cards/units/tank_03.json`：
```json
{
  "id": "tank_03",
  "name": "突击坦克",
  "nation": "neutral",
  "type": "unit",
  "unit_class": "tank",
  "cost_g": 70,
  "cost_k": 2,
  "attack": 6,
  "defense": 3,
  "vision_range": "adjacent_8_forward",
  "attack_range": "adjacent_8",
  "abilities": ["坚守", "突击"],
  "rarity": "silver",
  "art": "",
  "flavor_text": "突破防线，直插腹地。"
}
```

- [ ] **Step 8: 创建 fighter_01.json**

`data/cards/units/fighter_01.json`：
```json
{
  "id": "fighter_01",
  "name": "战斗机",
  "nation": "neutral",
  "type": "unit",
  "unit_class": "fighter",
  "cost_g": 50,
  "cost_k": 2,
  "attack": 4,
  "defense": 2,
  "vision_range": "front_3x2",
  "attack_range": "column_and_neighbors",
  "abilities": ["防空"],
  "rarity": "common",
  "art": "",
  "flavor_text": "制空权是胜利的保障。"
}
```

- [ ] **Step 9: 创建 fighter_02.json**

`data/cards/units/fighter_02.json`：
```json
{
  "id": "fighter_02",
  "name": "侦察机",
  "nation": "neutral",
  "type": "unit",
  "unit_class": "fighter",
  "cost_g": 40,
  "cost_k": 1,
  "attack": 2,
  "defense": 1,
  "vision_range": "front_3x2",
  "attack_range": "column_and_neighbors",
  "abilities": ["防空", "潜行"],
  "rarity": "silver",
  "art": "",
  "flavor_text": "悄无声息地掠过战场上空。"
}
```

- [ ] **Step 10: 创建 fighter_03.json**

`data/cards/units/fighter_03.json`：
```json
{
  "id": "fighter_03",
  "name": "王牌飞行员",
  "nation": "neutral",
  "type": "unit",
  "unit_class": "fighter",
  "cost_g": 70,
  "cost_k": 3,
  "attack": 6,
  "defense": 3,
  "vision_range": "front_3x2",
  "attack_range": "column_and_neighbors",
  "abilities": ["防空", "冲锋"],
  "rarity": "gold",
  "art": "",
  "flavor_text": "红色男爵的传说。"
}
```

- [ ] **Step 11: 创建 bomber_01.json**

`data/cards/units/bomber_01.json`：
```json
{
  "id": "bomber_01",
  "name": "轰炸机",
  "nation": "neutral",
  "type": "unit",
  "unit_class": "bomber",
  "cost_g": 60,
  "cost_k": 2,
  "attack": 6,
  "defense": 1,
  "vision_range": "front_3x2",
  "attack_range": "column_and_neighbors",
  "abilities": [],
  "rarity": "common",
  "art": "",
  "flavor_text": "从天而降的毁灭。"
}
```

- [ ] **Step 12: 创建 bomber_02.json**

`data/cards/units/bomber_02.json`：
```json
{
  "id": "bomber_02",
  "name": "重型轰炸机",
  "nation": "neutral",
  "type": "unit",
  "unit_class": "bomber",
  "cost_g": 80,
  "cost_k": 3,
  "attack": 8,
  "defense": 2,
  "vision_range": "front_3x2",
  "attack_range": "column_and_neighbors",
  "abilities": ["响应"],
  "rarity": "gold",
  "art": "",
  "flavor_text": "战略轰炸，摧毁一切。"
}
```

- [ ] **Step 13: 更新 player_default.json**

用以下内容替换 `data/decks/player_default.json`（覆盖 Phase 2 的 9 张卡组）：

```json
{
  "name": "默认卡组",
  "starter": "infantry_01",
  "cards": [
    "infantry_01", "infantry_01", "infantry_02", "infantry_03",
    "cavalry_01", "cavalry_01", "cavalry_02",
    "artillery_01", "artillery_02",
    "tank_01", "tank_02", "tank_03",
    "fighter_01", "fighter_02",
    "bomber_01"
  ]
}
```

> 共 15 张。金卡 `fighter_03` 和 `bomber_02` 不放入默认卡组，保留作后续卡组编辑器使用。

- [ ] **Step 14: 验证 — F5 运行，确认控制台输出 `[CardDataLoader] Loaded 17 cards`**

预期：15 张新卡 + test_infantry（已有）+ infantry_01/cavalry_01/artillery_01（Phase 2 创建）= 至少 17 张（如果 Phase 2 的三张已存在则是 16 张）。

- [ ] **Step 15: Commit**

```bash
git add data/cards/units/ data/decks/player_default.json
git commit -m "feat: add 12 new unit cards (tank/fighter/bomber variants) + update default deck to 15 cards"
```

---

### Task 8: 集成 — GameManager 更新 + 端到端验证

**Files:**
- Modify: `scripts/autoload/game_manager.gd` — 更新卡组路径（确保加载 15 张卡组）
- Modify: `scripts/core/turn_manager.gd` — 确认 Action 路由无需改动（不变）

**Interfaces:**
- Consumes: 所有 Task 1–7 的产出
- Produces: 完整的 Phase 3 可玩构建

- [ ] **Step 1: 确认 game_manager.gd 加载的是新卡组**

检查 `scripts/autoload/game_manager.gd` 中 `_load_deck()` 的路径是否为 `res://data/decks/player_default.json`（Phase 2 Task 8 设置）。如果是，无需修改——文件已更新。

如果路径指向旧版，改为：
```gdscript
    var deck_data := _load_deck("res://data/decks/player_default.json")
```

- [ ] **Step 2: 确认 TurnManager 无需修改**

`scripts/core/turn_manager.gd` 的 `submit_action()` 通过 Dictionary 路由到 GameLogic 方法。Phase 3 新增的词条/规则都是 GameLogic 内部逻辑，不改变 Action 接口。确认无需修改。

- [ ] **Step 3: 确认 Board 连接 HandManager 部署选格**

Phase 2 的 `game_manager.gd` 中 `hand.card_deployed` 信号连到固定部署位置（deploy_row=0/4, col=0）。确认此逻辑能工作。Phase 3 不做部署选格 UI（留到 Phase 5）。

- [ ] **Step 4: 端到端验证 — F5 运行完整对战流程**

手动测试以下流程（本地双人）：

1. **启动** → 控制台输出加载 15+ 张卡，棋盘显示 5×5 格子
2. **P1 回合** → 待购买区显示首发卡 + 初始 3 张，G=150, Z=1 (turn 1), K=1
3. **购买** → 点击购买按钮，花费 G，卡进入手牌
4. **跳过购买** → 点击"跳过阶段"进入部署阶段
5. **部署** → 点击手牌中的单位，出现在 P1 后方
6. **跳过部署** → 进入行动阶段
7. **结束回合** → P2 回合，Z=2 (后手 turn 1), K=1
8. **P2 回合** → 重复购买/部署流程
9. **P1 turn 2** → Z=3 (1+2×1), K=2
10. **移动** → 坦克可多次移动 + 攻击
11. **攻击** → 步兵打步兵正常结算；陆军打空军无效
12. **迷雾** → 对方单位在视野外显示灰色方块，进入视野正常显示
13. **守护** → 部署近卫步兵(infantry_02)，相邻己方单位受到攻击时伤害转移
14. **响应** → 突击步兵(infantry_03)购买当回合即可部署
15. **补给** → 装甲坦克(tank_02)回合开始时修复相邻受伤单位
16. **后方修复** → 后方单位每回合恢复 1 防御
17. **潜行** → 侦察机(fighter_02)在未被发现时不显示
18. **胜利** → 占领对方全部 5 列时游戏结束
19. **控制台** → 无报错，action_log 记录完整

- [ ] **Step 5: Commit**

```bash
git add scripts/autoload/game_manager.gd
git commit -m "feat: finalize Phase 3 integration — 15-card deck, complete battle loop with new units/abilities"
```

---

## 验证清单

全部 Task 完成后，逐项确认：

1. ✅ F5 运行无报错，加载 15+ 张卡
2. ✅ Z 公式正确：P1 turn1=1, turn2=3, turn3=5；P2 turn1=2, turn2=4
3. ✅ K 公式正确：= 回合数，上限 10
4. ✅ 移动消耗 Z（不是 K）
5. ✅ 攻击消耗 Z（不是 K）
6. ✅ 坦克可多次移动 + 一次攻击，攻击后可继续移动
7. ✅ 战斗机/轰炸机可分别移动和攻击各一次
8. ✅ 陆军攻击空军 → 无效
9. ✅ 轰炸机攻击轰炸机 → 无效
10. ✅ 战斗机攻击轰炸机 → 正常结算，轰炸机不反击
11. ✅ 防空词条单位可反击空军
12. ✅ 守护词条：相邻友方被攻击时伤害转移
13. ✅ 响应词条：购买当回合可部署
14. ✅ 补给词条：回合开始修复相邻受伤单位
15. ✅ 后方修复：后方单位每回合 +1 防御
16. ✅ 潜行词条：未被发现时不显示
17. ✅ 迷雾：视野外灰色方块，视野内正常
18. ✅ 坚守使用 firm_level（坦克默认 1，可叠加到 4）
19. ✅ 收缴词条（Phase 2 保留）正常工作
20. ✅ 突击/冲锋（Phase 2 保留）正常工作
21. ✅ 胜利条件：占领对方全部 5 列
22. ✅ 回合切换正常
