# Phase 3: 卡牌扩展 + 新单位 + 新词条 — 设计文档

**日期：** 2026-08-06
**状态：** 已确认
**范围：** 中大型 — 4 种新单位（坦克/战斗机/轰炸机）+ 6 个新词条 + 15 张卡 + 简化迷雾

---

## 1. 设计目标

在 Phase 2 的本地完整对战基础上，扩展卡池从 3 张到 15 张，引入全部 6 种单位类型（步兵/骑兵/火炮/坦克/战斗机/轰炸机），实现非暂缓词条的完整集合，并加入简化迷雾系统使对方单位信息部分隐藏。

**核心原则不变：** BattleState 唯一数据源 → GameLogic 纯函数 → TurnManager 信号驱动 UI。

---

## 2. 资源系统重整

Phase 2 的资源分配为：K 和 Z 都用于部署，K 还用于移动/攻击。Phase 3 重新划分职责，并为后续指令卡做准备。

### 2.1 三种资源

| 资源 | 用途 | 获取方式 | 上限 | 回合结束 |
|------|------|----------|------|----------|
| **经济 G** | 购买单位 | 每回合 +150 | 无上限 | 累积 |
| **战争点 Z** | 部署单位 / 移动 / 攻击 | 先手: `1 + 2×(turn−1)` → 1→3→5→7… / 后手: `2 + 2×(turn−1)` → 2→4→6→8… | 25 | **清空** |
| **指挥点 K** | 使用指令卡（Phase 5+） | 每回合 K = 当前回合数 | 10 | **清空** |

### 2.2 卡牌费用语义

| JSON 字段 | 含义 | 消耗资源 |
|-----------|------|----------|
| `cost_g` | 购买所需经济 | G |
| `cost_k` | 部署所需战争点 | Z |

> **注意：** `cost_k` 字段名保留不变（避免破坏 Phase 2 的 CardData 结构和 JSON 格式），但其消耗的资源从 K 改为 Z。未来指令卡新增 `cost_k_real` 或其他字段用于指挥点消耗。

### 2.3 操作消耗

| 操作 | 消耗 |
|------|------|
| 购买单位 | G = card.cost_g |
| 部署单位 | Z = card.cost_k |
| 移动一格 | Z = 1 |
| 攻击一次 | Z = 1 |
| 使用指令卡 | K（Phase 5+） |

### 2.4 start_turn 公式

```
func _start_turn_resources(state, player_idx):
    player = state.players[player_idx]
    player.G += 150
    player.Z = _calc_z(player_idx, state.turn)  # 先手1+2x / 后手2+2x, cap 25
    player.K = min(state.turn, 10)               # 回合数, cap 10
```

### 2.5 Phase 2 兼容

Phase 2 实现计划中的 `start_turn()` 使用旧公式（K = turn, Z = turn）。Phase 3 实现时需修改为上述新公式。此变更作为 Phase 3 Task 1 的一部分。

---

## 3. 新单位类型

Phase 2 已有 3 种单位（步兵/骑兵/火炮），Phase 3 新增 3 种（工事推迟）。

### 3.1 坦克 (Tank)

| 属性 | 值 |
|------|-----|
| 视野 | `adjacent_8_forward` — 周围八格 + 向前额外一格 |
| 攻击范围 | `adjacent_8` — 周围八格 |
| 入场规则 | 同步兵：友方后方（P1 行 0 / P2 行 4）；若占领前线，可部署在友方阵地 |
| 移动规则 | 每友方回合可攻击**一次**，移动**无限制**（攻击前后均可移动） |
| 特殊规则 | 默认**坚守 1**，坦克的坚守上限提升至 **4**（其他单位坚守上限 3） |

Phase 2 的坚守词条固定减伤 1。Phase 3 需改为坚守等级参数化：
- 卡牌 JSON 中 `abilities` 可写 `"坚守2"` 表示坚守等级 2
- UnitData 存储 `firm_level: int = 0`
- 坦克默认 `firm_level = 1`，可通过 buff 叠加到 4

### 3.2 战斗机 (Fighter)

| 属性 | 值 |
|------|-----|
| 视野 | `front_3x2` — 前方横向 3 列 × 2 行 |
| 攻击范围 | `column_and_neighbors` — 单位所在列 + 相邻两列 |
| 入场规则 | 同步兵 |
| 移动规则 | 每友方回合可移动**和**攻击**各一次** |
| 特殊规则 | 可攻击空军单位；**防空**词条可反击空军 |

### 3.3 轰炸机 (Bomber)

| 属性 | 值 |
|------|-----|
| 视野 | `front_3x2` — 前方横向 3 列 × 2 行 |
| 攻击范围 | `column_and_neighbors` — 单位所在列 + 相邻两列 |
| 入场规则 | 同步兵 |
| 移动规则 | 每友方回合可移动**和**攻击**各一次** |
| 特殊规则 | **仅能攻击陆军**；**无法反击**；非战斗机单位无法反击轰炸机 |

### 3.4 空战规则

GameLogic 攻击结算需增加空战判定：

1. 陆军（步兵/骑兵/坦克/火炮）攻击空军（战斗机/轰炸机）→ 无效，返回原 state
2. 轰炸机攻击空军 → 无效（轰炸机只能打陆军）
3. 战斗机攻击轰炸机 → 正常结算，轰炸机不反击
4. 战斗机攻击战斗机 → 正常结算，双方各反击
5. 非战斗机单位被轰炸机攻击 → 无法反击（轰炸机不会被非战斗机反击）
6. 拥有**防空**词条的单位与空军交战时 → 可以正常反击
7. 火炮攻击空军 → 无效（火炮虽全图射程，但陆军无法攻击空军）

在 CardData 中通过 `unit_class` 字段区分空中/地面：
- `unit_class` 为 `"fighter"` 或 `"bomber"` → 空军
- 其余 → 陆军

### 3.5 移动规则差异

Phase 2 所有单位共用一套移动规则（移动或攻击共一次，消耗 1 Z）。Phase 3 需区分：

| 单位类别 | 移动 | 攻击 | 关系 |
|----------|------|------|------|
| 步兵/骑兵/火炮 | 1 次 | 1 次 | 移动或攻击**共一次** |
| 坦克 | **无限制** | 1 次 | 攻击前后可任意移动 |
| 战斗机/轰炸机 | 1 次 | 1 次 | 移动**和**攻击**各一次** |

需要在 UnitData 中追踪 `move_count` 和 `attack_count`（或保持 `has_acted` + 新增 `has_attacked` / `move_limit` / `attack_limit`）。

**简化方案：** UnitData 新增字段：
- `has_attacked: bool = false` — 本回合是否已攻击
- `move_count: int = 0` — 本回合已移动次数
- `move_limit: int = 1` — 本回合移动上限（坦克 = 99 表示无限制）
- `can_move_after_attack: bool = false` — 攻击后是否仍可移动（坦克 = true）

---

## 4. 新词条

Phase 2 已有：突击、坚守、冲锋、收缴（4 个）。

Phase 3 新增 6 个。推迟：爆破（依赖工事）、策反/掩护/巡逻/钳击/工程（暂缓）。

### 4.1 守护 / 被守护 (Guard / Guarded)

**守护：** 部署后，为所有相邻八格的友方单位添加"被守护"词条，指向本守护单位。

**被守护：** 受到周围八格敌方单位的攻击时，伤害转移到守护单位。

**GameLogic 变更：**
- `deploy_unit()` 后调用 `_apply_guard(state, unit)`：遍历相邻八格，给每个友方单位添加 `guarded_by: Vector2i` 指向守护单位位置
- `attack_unit()` 攻击前检查：如果目标有 `guarded_by`，且守护单位仍在场 → 攻击目标改为守护单位
- `_counter_attack()` 同理：被守护单位被攻击时的反击也转移到守护单位
- 守护单位死亡/移动时调用 `_clear_guard(state, unit)`：清除所有指向它的"被守护"

**UnitData 新增字段：**
- `is_guarded: bool = false`
- `guarded_by: Vector2i = Vector2i(-1, -1)` — 指向守护单位的位置

### 4.2 响应 (Response)

拥有此词条的单位，购买的**同一回合**即可部署（正常情况下需等到下回合）。

**PlayerData 新增字段：**
- `hand_card_purchase_turn: Dictionary = {}` — `{card_id: turn_number}`，记录每张手牌是在第几回合购买的

**GameLogic 变更：**
- `purchase_card()` 购买成功时，记录 `player.hand_card_purchase_turn[card_id] = state.turn`
- `deploy_unit()` 中检查：如果 `hand_card_purchase_turn[card_id] == state.turn`（本回合购买），且单位没有"响应"词条 → 拒绝部署

### 4.3 防空 (Anti-Air)

拥有此词条的单位与空军交战时可以正常反击。

**GameLogic 变更：**
- `_counter_attack()` 中：反击方是陆军 + 攻击方是空军 + 反击方没有"防空"词条 → 跳过反击
- 此处与空战规则（第 3.4 节）配合使用

### 4.4 补给 (Supply)

友方回合开始时，自动修复一个相邻八格中已受伤的友方单位。

**GameLogic 变更：**
- `start_turn()` 末尾调用 `_apply_supply(state, player_idx)`：
  - 遍历己方有"补给"词条的单位
  - 检查其相邻八格，找一个 `defense < max_defense` 的己方单位
  - 恢复 `min(max_defense, defense + supply_level)`（默认 supply_level = 1）
  - 补给等级从 abilities 中解析，如 `"补给2"` 表示恢复 2 点

**abilities 格式约定：**
- 坚守、补给、爆破等带等级的词条，在 abilities 数组中存储为 `"坚守2"` 或 `"坚守"`（默认等级 1）
- 解析时统一处理：`_parse_ability_level(abilities, "坚守")` 返回等级数值

### 4.5 修复 (Repair) — 后方规则

单位处于己方后方时，每回合开始自动恢復 1 点防御力。这不是一个显式词条，而是位置规则。

**GameLogic 变更：**
- `start_turn()` 末尾调用 `_apply_rear_repair(state, player_idx)`：
  - 遍历己方后方行（P1: 行 0，P2: 行 4）的所有己方单位
  - `defense = min(max_defense, defense + 1)`

### 4.6 潜行 / 被发现 (Stealth / Revealed)

拥有"潜行"词条的单位，敌方无法观察其信息。处于敌方步兵或战斗机视野范围内时，潜行失效（"被发现"）。

**UnitData 新增字段：**
- `stealthed: bool = false` — 部署时根据 CardData 初始化
- `revealed: bool = false` — 每回合重新计算

**GameLogic 变更：**
- `start_turn()` / `move_unit()` / `deploy_unit()` 后调用 `_update_stealth_reveal(state)`：
  - 遍历所有有"潜行"词条的单位
  - 检查是否处于**敌方**步兵或战斗机的视野范围内
  - 如果在 → `revealed = true`，否则 `revealed = false`

**Board 变更（迷雾配合）：**
- 潜行且未被发现的敌方单位 → 完全不显示（或在格子上显示极简标记）
- 潜行但被发现的敌方单位 → 按正常迷雾规则处理（在视野内可见，视野外灰色）

---

## 5. 简化迷雾系统

### 5.1 规则

1. 对方单位默认显示为灰色迷雾方块（隐藏攻防/词条/具体类型）
2. 进入**我方任意单位视野范围**后 → 移除迷雾，正常显示全部信息
3. 离开所有我方单位视野 → 重新蒙上迷雾
4. 简化版不实现"残影"记忆——离开视野就完全重新隐藏

### 5.2 视野范围定义

视野字符串映射为判定函数：

| 视野字符串 | 范围 |
|-----------|------|
| `adjacent_4` | 周围四格（上下左右） |
| `adjacent_8` | 周围八格 |
| `adjacent_8_forward` | 周围八格 + 向前额外一格 |
| `front_3x2` | 前方横向 3 列 × 2 行 |
| `front_3x3` | 前方横向 3 列 × 3 行 |
| `frontline_only` | 仅所在阵线 |
| `none` | 无视野 |

### 5.3 实现方式

**Board 层负责计算可见性：**
- `board.gd` 新增 `_update_visibility(state: BattleState)` 方法
- 在 `_on_state_changed` 中调用
- 对每个有敌方单位的格子，检查是否处于任何己方单位的视野内
- 传入 CardDisplay 的 `visible_to_enemy: bool` 参数

**CardDisplay 修改：**
- 新增 `set_visible_to_enemy(v: bool)` 方法
- `true` → 正常显示
- `false` → 覆盖灰色方块（类似 Phase 2 的 `_fog_display`）

---

## 6. 卡池（15 张）

### 6.1 步兵 (Infantry) ×3

| ID | 名称 | G | Z(cost_k) | 攻 | 防 | 视野 | 射程 | 词条 | 稀有度 |
|----|------|---|-----------|----|----|------|------|------|--------|
| `infantry_01` | 步兵 | 30 | 1 | 3 | 4 | adjacent_4 | adjacent_4 | — | common |
| `infantry_02` | 近卫步兵 | 40 | 1 | 3 | 5 | adjacent_4 | adjacent_4 | 守护 | common |
| `infantry_03` | 突击步兵 | 40 | 1 | 2 | 3 | adjacent_4 | adjacent_4 | 响应 | common |

### 6.2 骑兵 (Cavalry) ×2

| ID | 名称 | G | Z(cost_k) | 攻 | 防 | 视野 | 射程 | 词条 | 稀有度 |
|----|------|---|-----------|----|----|------|------|------|--------|
| `cavalry_01` | 骑兵 | 40 | 2 | 4 | 2 | adjacent_4 | adjacent_4 | 冲锋 | common |
| `cavalry_02` | 哥萨克骑兵 | 50 | 2 | 3 | 3 | adjacent_4 | adjacent_4 | 冲锋、收缴 | silver |

### 6.3 火炮 (Artillery) ×2

| ID | 名称 | G | Z(cost_k) | 攻 | 防 | 视野 | 射程 | 词条 | 稀有度 |
|----|------|---|-----------|----|----|------|------|------|--------|
| `artillery_01` | 火炮 | 50 | 1 | 5 | 2 | front_3x3 | global | 突击 | common |
| `artillery_02` | 重型火炮 | 70 | 2 | 7 | 1 | front_3x3 | global | — | silver |

### 6.4 坦克 (Tank) ×3

| ID | 名称 | G | Z(cost_k) | 攻 | 防 | 视野 | 射程 | 词条 | 稀有度 |
|----|------|---|-----------|----|----|------|------|------|--------|
| `tank_01` | 轻型坦克 | 60 | 2 | 4 | 4 | adjacent_8_forward | adjacent_8 | 坚守 | common |
| `tank_02` | 装甲坦克 | 80 | 3 | 5 | 6 | adjacent_8_forward | adjacent_8 | 坚守、补给 | silver |
| `tank_03` | 突击坦克 | 70 | 2 | 6 | 3 | adjacent_8_forward | adjacent_8 | 坚守、突击 | silver |

### 6.5 战斗机 (Fighter) ×3

| ID | 名称 | G | Z(cost_k) | 攻 | 防 | 视野 | 射程 | 词条 | 稀有度 |
|----|------|---|-----------|----|----|------|------|------|--------|
| `fighter_01` | 战斗机 | 50 | 2 | 4 | 2 | front_3x2 | column_and_neighbors | 防空 | common |
| `fighter_02` | 侦察机 | 40 | 1 | 2 | 1 | front_3x2 | column_and_neighbors | 防空、潜行 | silver |
| `fighter_03` | 王牌飞行员 | 70 | 3 | 6 | 3 | front_3x2 | column_and_neighbors | 防空、冲锋 | gold |

### 6.6 轰炸机 (Bomber) ×2

| ID | 名称 | G | Z(cost_k) | 攻 | 防 | 视野 | 射程 | 词条 | 稀有度 |
|----|------|---|-----------|----|----|------|------|------|--------|
| `bomber_01` | 轰炸机 | 60 | 2 | 6 | 1 | front_3x2 | column_and_neighbors | — | common |
| `bomber_02` | 重型轰炸机 | 80 | 3 | 8 | 2 | front_3x2 | column_and_neighbors | 响应 | gold |

### 6.7 卡组更新

`player_default.json` 更新为 15 张：

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

共 15 张，含 1 金卡 (fighter_03) 和 1 金卡 (bomber_02) 不放入默认卡组（可后续通过卡组编辑加入）。

---

## 7. 数据结构变更

### 7.1 UnitData 新增字段

```
UnitData (BattleState 内类)
├── (Phase 2 已有字段不变)
├── stealthed: bool = false           # 是否有潜行词条
├── revealed: bool = false            # 是否被敌方发现
├── has_attacked: bool = false        # 本回合是否已攻击
├── move_count: int = 0               # 本回合已移动次数
├── move_limit: int = 1               # 本回合移动上限（坦克 = 99）
├── can_move_after_attack: bool = false  # 攻击后是否仍可移动
├── is_guarded: bool = false          # 是否有守护单位保护
├── guarded_by: Vector2i = (-1, -1)   # 守护单位位置
├── firm_level: int = 0               # 坚守等级（0 = 无坚守）
└── supply_level: int = 0             # 补给等级（0 = 无补给）
```

### 7.2 PlayerData 新增字段

```
PlayerData
├── (Phase 2 已有字段不变)
└── hand_card_purchase_turn: Dictionary = {}  # {card_id: turn}
```

### 7.3 BoardData

不变。

---

## 8. GameLogic 方法变更

### 8.1 新增方法

| 方法 | 说明 |
|------|------|
| `_parse_ability_level(abilities, name) -> int` | 解析带等级词条，如"坚守2"→2，"坚守"→1 |
| `_apply_guard(state, unit)` | 部署/移动后给相邻友方加"被守护" |
| `_clear_guard(state, unit)` | 守护单位离场/移动前清除"被守护" |
| `_apply_supply(state, player_idx)` | 补给词条：修复相邻受伤单位 |
| `_apply_rear_repair(state, player_idx)` | 后方修复规则 |
| `_update_stealth_reveal(state)` | 重新计算所有潜行单位的 revealed 状态 |
| `_is_air_unit(unit_class) -> bool` | 判断是否空军（fighter/bomber） |
| `_can_counter(attacker, defender) -> bool` | 判断反击方能否反击攻击方（空战规则） |
| `_get_vision_cells(unit, row, col) -> Array[Vector2i]` | 获取单位视野覆盖的格子列表 |
| `_in_vision_range(vision_str, from_row, from_col, to_row, to_col) -> bool` | 视野判定函数 |

### 8.2 修改方法

| 方法 | 变更 |
|------|------|
| `deploy_unit()` | 响应词条检查；守护词条触发；初始化 stealthed/firm_level/move_limit |
| `move_unit()` | 坦克无限制移动；清除/重新应用守护；移动计数 |
| `attack_unit()` | 空战规则检查；守护转移伤害；has_attacked 标记；坦克攻击后仍可移动 |
| `_counter_attack()` | 空战反击规则；防空词条；被守护单位反击转移 |
| `start_turn()` | 调用补给、后方修复、潜行重新计算；重置 has_attacked/move_count |

---

## 9. Board 变更

### 9.1 迷雾与可见性

`board.gd` 新增：

```
func _update_visibility(state: BattleState) -> void:
    # 1. 收集己方所有单位的视野覆盖格子
    # 2. 对每个敌方单位格子判断是否在视野内
    # 3. 对每个敌方单位格子判断潜行/被发现状态
    # 4. 调用对应 CardDisplay 的 set_visible_to_enemy()
```

### 9.2 CardDisplay 变更

```
func set_visible_to_enemy(v: bool) -> void:
    # true: 移除迷雾覆盖，显示全部信息
    # false: 添加灰色方块覆盖，隐藏攻防/词条
    # 如果 unit.stealthed and not unit.revealed: 完全不显示（或显示极简标记）
```

---

## 10. 不做的事项

- 工事（Fortification）— 需要独立阵线系统，推迟到 Phase 5
- 爆破词条 — 依赖工事
- 策反、掩护、巡逻、钳击、工程 — 游戏机制文档标记为暂缓
- 完整迷雾残影记忆 — 留到 Phase 4
- 国家/阵营系统（沙俄→苏俄转换）
- 卡组编辑器 UI
- 卡牌 JSON 校验工具（Phase 5）
- 网络同步（Phase 4）

---

## 11. 文件变更清单

| 文件 | 操作 | 说明 |
|------|------|------|
| `scripts/core/battle_state.gd` | 修改 | UnitData/PlayerData 新增字段 |
| `scripts/core/game_logic.gd` | 修改 | 新方法 + 修改现有方法 |
| `scripts/core/turn_manager.gd` | 不改 | Action 路由不变 |
| `scripts/ui/board.gd` | 修改 | 迷雾可见性计算 |
| `scripts/ui/card_display.gd` | 修改 | 迷雾显示/隐藏切换 |
| `scripts/ui/hand_manager.gd` | 不改 | 手牌 UI 无需变更 |
| `scripts/autoload/game_manager.gd` | 修改 | 加载新卡组 |
| `data/cards/units/infantry_02.json` | 新建 | 近卫步兵 |
| `data/cards/units/infantry_03.json` | 新建 | 突击步兵 |
| `data/cards/units/cavalry_02.json` | 新建 | 哥萨克骑兵 |
| `data/cards/units/artillery_02.json` | 新建 | 重型火炮 |
| `data/cards/units/tank_01.json` | 新建 | 轻型坦克 |
| `data/cards/units/tank_02.json` | 新建 | 装甲坦克 |
| `data/cards/units/tank_03.json` | 新建 | 突击坦克 |
| `data/cards/units/fighter_01.json` | 新建 | 战斗机 |
| `data/cards/units/fighter_02.json` | 新建 | 侦察机 |
| `data/cards/units/fighter_03.json` | 新建 | 王牌飞行员 |
| `data/cards/units/bomber_01.json` | 新建 | 轰炸机 |
| `data/cards/units/bomber_02.json` | 新建 | 重型轰炸机 |
| `data/decks/player_default.json` | 修改 | 更新卡组含新卡 |
| `scripts/network/network_manager.gd` | 不改 | Phase 4 |
