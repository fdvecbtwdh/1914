# Phase 2: 本地完整对战 — 设计文档

**日期：** 2026-08-06
**状态：** 已确认
**范围：** 中等 — 步兵/骑兵/火炮 + 核心词条 + 完整资源系统

---

## 1. 架构总览

```
                  ┌─────────────┐
                  │ TurnManager │  回合流转、资源刷新、胜负检测
                  └──────┬──────┘
                         │ 读写
                  ┌──────▼──────┐
                  │ BattleState │  唯一的真实数据源（Resource）
                  └──────┬──────┘
                         │ 只读传入
                  ┌──────▼──────┐
                  │  GameLogic  │  纯函数：execute(state, action) → new_state
                  └──────┬──────┘
                         │ 返回新状态
                  ┌──────▼──────┐
                  │ BattleState │  更新为新状态
                  └──────┬──────┘
                         │ 信号通知
              ┌──────────┼──────────┐
              ▼          ▼          ▼
        Board        HandManager   UI层
        (重新渲染)   (重新渲染)    (资源显示等)
```

三条核心原则：
1. **唯一数据源** — BattleState 是所有状态的唯一归属，UI 只读不写
2. **纯函数逻辑** — GameLogic 不依赖 Godot 节点/场景，输入状态 → 输出新状态，保证确定型锁步
3. **信号驱动 UI** — 状态变化后发信号，UI 响应信号刷新

---

## 2. BattleState（`scripts/core/battle_state.gd`）

`extends Resource`，用 `duplicate(true)` 实现不可变更新。

### 2.1 顶层结构

```
BattleState
├── players: Array[PlayerData]          # [P1, P2]
├── board: BoardData                    # 棋盘矩阵
├── turn: int                          # 当前回合数（从 1 开始）
├── phase: String                      # "draw" | "purchase" | "deploy" | "action" | "end"
├── active_player_index: int           # 0 或 1
├── winner: int                        # -1 = 未结束, 0/1 = 胜方
├── round_count: int                   # 大回合计数（双方各动一次 = 一回合）
└── action_log: Array[Dictionary]      # 本局所有操作记录
```

### 2.2 PlayerData（内类）

```
PlayerData
├── resources: {G: int, K: int, Z: int}
├── hand: Array[String]                # 手牌 card_id 列表
├── purchase_zone: Array[String]       # 待购买区 card_id 列表
├── deck: Array[String]                # 卡组（抽牌堆）
├── discard: Array[String]             # 弃牌堆
├── hand_limit: int = 7
├── purchase_limits: {common: -1, silver: 3, gold: 2}  # -1 = 无上限
└── starter_card_id: String            # 首发牌 ID
```

### 2.3 BoardData（内类）

```
BoardData
├── rows: int = 5
├── cols: int = 5
└── slots: Array[Array]               # rows × cols，每个元素为 UnitData 或 null
```

### 2.4 UnitData（内类）

```
UnitData
├── card_id: String                   # 对应 CardData 模板
├── owner_index: int                  # 0 或 1
├── attack: int                       # 当前攻击力
├── defense: int                      # 当前防御力/剩余血量
├── max_defense: int                  # 最大防御力
├── has_acted: bool                   # 本回合是否已行动
├── abilities: Array[String]          # 词条列表
├── position: {row, col}
└── deployed_this_turn: bool          # 本回合刚部署（突击词条判定用）
```

**设计要点：**
- UnitData 是 CardData 的"运行时实例"——CardData 是模板（不变），UnitData 会受伤/buff
- 手牌存 card_id（String），不是 CardData 对象，避免复制开销
- `hand_limit` 和 `purchase_limits` 存 PlayerData 中，方便后续扩展

---

## 3. GameLogic（`scripts/core/game_logic.gd`）

`extends RefCounted`，所有方法为静态纯函数。每个方法接收 `BattleState` + 参数，返回新的 `BattleState`（通过 `duplicate(true)` 深拷贝后修改）。

### 3.1 核心方法

| 方法 | 说明 |
|------|------|
| `draw_card(state, player_idx)` | 从卡组顶抽一张到待购买区，检查稀有度上限 |
| `purchase_card(state, player_idx, card_id)` | 花费 G，从待购买区移到手牌 |
| `deploy_unit(state, player_idx, card_id, row, col)` | 花费 Z，从手牌部署到棋盘指定格子 |
| `move_unit(state, player_idx, from_row, from_col, to_row, to_col)` | 移动一格（八方向），标记 has_acted |
| `attack_unit(state, player_idx, from_row, from_col, target_row, target_col)` | 攻击 + 反击结算 |
| `start_turn(state)` | 回合开始：G += 150，K = 回合数，Z = 回合数，抽牌 |
| `end_turn(state)` | 清空 K/Z，切换 active_player，检测胜负 |
| `init_game(state, deck_p1, deck_p2, starter_p1, starter_p2)` | 游戏初始化 |

### 3.2 攻击结算流程

1. **攻击方造成伤害** — `target.defense -= attacker.attack`
2. **反击判定** — 以下情况不反击：
   - 攻击者有"突击"词条且这是其首次攻击
   - 攻击者是火炮（火炮无法被反击）
   - 攻击者是轰炸机且防守方非战斗机
3. **坚守减伤** — 防守方有"坚守 N"，实际伤害 = 原伤害 − N（最小 1）
4. **消灭处理** — 防御力 ≤ 0 则移除单位，攻击方获得 25% 生产 G（"收缴"词条改 50%）
5. **坦克** — 默认坚守 1，坚守上限 4

### 3.3 部署规则

- Player 1 后方 = 行 0，前线 = 行 1
- Player 2 后方 = 行 4，前线 = 行 3
- 行 2 为中立/争夺区，双方均可部署（若已占领前线则可）
- 骑兵：可部署在任意友方有占领度的阵线任意位置
- 步兵/火炮：可部署在友方后方；若占领前线，可部署在友方阵地

### 3.4 胜负判定

对方每条阵线（5 列）都有己方单位占领 → 己方胜利。

---

## 4. TurnManager（`scripts/core/turn_manager.gd`）

`extends Node`，挂载到 BattleScene。

### 4.1 职责

- 持有 `battle_state: BattleState` 实例
- 暴露 `submit_action(action: Dictionary)` — 玩家操作的统一入口
- 调用 `GameLogic.xxx()` 得到新 state，替换旧 state
- 发出信号：
  - `state_changed(new_state: BattleState)` — 任何状态变化
  - `phase_changed(new_phase: String)` — 阶段切换
  - `game_over(winner: int)` — 游戏结束

### 4.2 阶段流转

```
draw → purchase → deploy → action → end → (对方) draw → ...
                                                    ↓
                                              game_over（如满足胜负条件）
```

- **draw** — 自动抽牌进待购买区
- **purchase** — 玩家可购买待购买区卡牌（花费 G）或跳过
- **deploy** — 玩家可部署手牌单位（花费 Z）或跳过
- **action** — 玩家可移动/攻击（花费 K）或跳过
- **end** — 自动结算，清 K/Z，切换玩家

### 4.3 本地双人对战切换

- 回合切换时发出 `state_changed` 信号
- UI 层收到信号后切换手牌显示（隐藏对方手牌，显示己方手牌）
- 可在切换时弹出遮罩提示"轮到 Player X"

---

## 5. HandManager（`scripts/ui/hand_manager.gd`）

`extends Node2D`，挂载到 BattleScene。

### 5.1 职责

- 读取 `battle_state.players[active_player].hand` 和 `purchase_zone`
- 渲染当前活跃玩家的手牌 + 待购买区卡牌
- 显示 G/K/Z 资源数值
- 回合切换时切换显示

### 5.2 UI 布局

```
┌─────────────────────────────────────────────────┐
│  [待购买区]                                      │
│  ┌────┐ ┌────┐ ┌────┐                           │
│  │卡牌│ │卡牌│ │卡牌│  ...   [购买] 按钮          │
│  └────┘ └────┘ └────┘                           │
│                                                  │
│  [手牌]  上限 7                                   │
│  ┌────┐ ┌────┐ ┌────┐ ┌────┐                   │
│  │卡牌│ │卡牌│ │卡牌│ │卡牌│  ...  [部署] 按钮    │
│  └────┘ └────┘ └────┘ └────┘                   │
│                                                  │
│  G: 150   K: 3   Z: 3     [结束回合]             │
└─────────────────────────────────────────────────┘
```

---

## 6. 卡组预设

### 6.1 文件结构

```
data/
├── cards/units/
│   ├── test_infantry.json       # 已有
│   ├── infantry_01.json         # 步兵 ×3
│   ├── cavalry_01.json          # 骑兵 ×3
│   └── artillery_01.json        # 火炮 ×3
└── decks/
    └── player_default.json      # 预设卡组
```

### 6.2 预设卡组（`player_default.json`）

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

双方使用相同卡组，初始各抽 3 张 + 首发牌恒定加入第一回合购买区。

---

## 7. CardDisplay 修复

Phase 1 的已知问题：

1. `_input()` 事件广播 — 改为 `Control` 节点 + `_gui_input()` 方案，或切到 `_unhandled_input`
2. `setup()` 非幂等 — 加 `_initialized` 标记
3. `range(5)` 应改为 `range(GRID_SIZE)` in `add_extra_row`

Phase 2 统一修复。

---

## 8. 不做的事项

- 迷雾系统（留到 Phase 4 联网对战）
- 战斗机、轰炸机、坦克、工事（Phase 3 加卡时引入）
- 复杂词条（策反、掩护、巡逻、钳击、工程 — 暂缓）
- 卡组编辑器 UI
- 网络同步
- 回合切换动画/遮罩（仅做文本提示）

---

## 9. 文件变更清单

| 文件 | 操作 | 说明 |
|------|------|------|
| `scripts/core/battle_state.gd` | 重写 | BattleState + UnitData + BoardData + PlayerData |
| `scripts/core/game_logic.gd` | 重写 | 所有 Action 纯函数 |
| `scripts/core/turn_manager.gd` | 重写 | 回合编排 + 信号 |
| `scripts/ui/hand_manager.gd` | 重写 | 手牌/购买区/资源 UI |
| `scripts/ui/board.gd` | 修改 | 从 BattleState 渲染，移除硬编码测试 |
| `scripts/ui/card_display.gd` | 修改 | 修复 _input 多卡问题 + 非幂等 setup |
| `scripts/autoload/game_manager.gd` | 修改 | 游戏初始化入口 |
| `data/cards/units/infantry_01.json` | 新建 | 正式步兵卡 |
| `data/cards/units/cavalry_01.json` | 新建 | 骑兵卡 |
| `data/cards/units/artillery_01.json` | 新建 | 火炮卡 |
| `data/decks/player_default.json` | 新建 | 预设卡组 |
| `scripts/network/network_manager.gd` | 不改 | Phase 4 |
