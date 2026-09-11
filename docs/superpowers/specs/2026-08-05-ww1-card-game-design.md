# WW1 双人卡牌对战游戏 — 设计文档

**日期：** 2026-08-05
**状态：** 待审阅
**团队：** 学生团队（1 名程序员 + 多人负责机制/美术/考据）

---

## 1. 项目概述

一款以第一次世界大战为题材的双人卡牌对战游戏，玩法参考《Kards》。支持本地同屏对战和在线 P2P 直连对战，优先在 PC 和移动端可玩。

### 核心约束

- **团队配置：** 仅 1 名略懂编程的成员，其余为机制设计、美术、考据人员
- **优先级：** 快速出可玩原型，保持团队信心
- **平台：** PC（Windows/Mac/Linux）+ 移动端（iOS/Android）
- **画面：** 纯 2D

### 成功标准

1. 两名玩家能从各自的设备完成一局完整对战
2. 非程序员队友能通过编辑 JSON 文件新增/调整卡牌
3. 项目可在 Godot 编辑器内一键运行和导出

---

## 2. 技术选型

| 项 | 选择 | 理由 |
|---|---|---|
| 引擎 | Godot 4.x | 原生 2D 引擎、轻量（~50MB）、GDScript 易学、多平台一键导出、完全免费开源 |
| 语言 | GDScript | 类 Python 语法，学习曲线最低 |
| 版本控制 | Git | Godot 项目天然适合 Git |
| 卡牌数据 | JSON | 非程序员可用文本编辑器或表格软件编辑 |
| 网络 | ENetMultiplayerPeer (P2P) | 直连，无需额外服务器 |

---

## 3. 架构设计

### 3.1 场景划分

```
MainMenu ──────▶ BattleScene ◀────── DeckEditor
(大厅/创建房间)    (核心玩法)         (卡组管理)
```

三个独立场景，BattleScene 是核心。

### 3.2 BattleScene 内部结构

```
BattleScene (Node2D)
├── Board                        # 棋盘 — 默认 5×5，特殊卡牌可扩展至最大 7×5
│   ├── BoardSlot                # 单个格子（支持拖放） ×25–35
│   └── FortificationSlot        # 工事槽（与阵线关联）
├── HandManager                  # 手牌显示与管理
├── PlayerManager
│   ├── Player (本地玩家)
│   └── Player (远程玩家 / 本地玩家2)
├── TurnManager                  # 回合流转
├── NetworkManager               # 仅在线模式激活
└── UILayer
    ├── EndTurnButton
    ├── ResourceDisplay           # 经济G / 指挥点K / 战争点Z
    └── CardPreview
```

棋盘为 6×6 格子阵，格子上可放置单位。工事与阵线关联，不占用单位格子。

### 3.3 本地 / 在线模式统一

**关键设计：** 同一套游戏逻辑同时服务本地和在线模式。差异仅在输入来源：

| 模式 | 玩家1 输入 | 玩家2 输入 |
|---|---|---|
| 本地 | 本地鼠标/触屏 | 本地鼠标/触屏（同设备轮流） |
| 在线 | 本地鼠标/触屏 | 通过网络 RPC 接收 |

游戏逻辑层不关心输入来源——它只接收 `Action`（出牌、攻击、结束回合等），执行游戏规则，产出新的状态。

---

## 4. 卡牌数据系统

### 4.1 存储方式

每张卡牌为一个 JSON 文件，存放在 `data/cards/` 下，按类型分目录：

```
data/cards/
├── units/           # 单位卡 JSON
└── orders/          # 命令卡 JSON
```

### 4.2 卡牌数据结构

```json
{
  "id": "british_infantry_01",
  "name": "英国步兵",
  "nation": "britain",
  "type": "unit",
  "unit_class": "infantry",
  "cost_g": 3,
  "cost_k": 1,
  "attack": 2,
  "defense": 3,
  "vision_range": "adjacent_4",
  "attack_range": "adjacent_4",
  "abilities": ["entrench"],
  "rarity": "common",
  "art": "assets/card_art/british_infantry.png",
  "flavor_text": "他们不惧怕机枪，只惧怕没有茶喝。"
}
```

字段说明：

| 字段 | 类型 | 说明 |
|---|---|---|
| id | string | 唯一标识符 |
| name | string | 显示名称 |
| nation | string | 所属国家/阵营 |
| type | string | 卡牌类型：unit（单位）、order（指令） |
| unit_class | string | 单位类别：cavalry / infantry / tank / fighter / bomber / artillery / fortification（仅 unit 类型需要） |
| cost_g | int | 生产所需经济 G |
| cost_k | int | 部署所需指挥点 K |
| attack | int | 攻击力 |
| defense | int | 防御力/生命值 |
| vision_range | string | 视野范围（如 adjacent_4 / adjacent_8_forward / front_3x2 / front_3x3 / frontline_only / none） |
| attack_range | string | 攻击范围（如 adjacent_4 / adjacent_8 / column_and_neighbors / global / none） |
| abilities | string[] | 特殊能力词条列表（如守护、突击、坚守、潜行、防空 等，参见游戏机制文档） |
| rarity | string | 稀有度：common（铜）/ silver（银）/ gold（金） |
| art | string | 卡面图片路径 |
| flavor_text | string | 风味文字 |

### 4.3 加载方式

`CardData` 单例在游戏启动时扫描 `data/cards/` 目录，将所有 JSON 反序列化为 `CardData` 资源对象，存入字典 `{id → CardData}`。游戏运行时通过 ID 查询卡牌数据。

---

## 5. 网络架构

### 5.1 连接流程

```
玩家A                              玩家B
  │                                  │
  ├─ 点击「创建房间」               │
  │  生成房间码 "X7K2M9"             │
  │                                  │
  │               输入房间码 "X7K2M9" ┤
  │                                  │
  │◀──────── ENet 建立连接 ────────▶│
  │                                  │
  ├─ 双方准备完毕 ───────────────────┤
  │                                  │
  ├─ 游戏开始                         ├─ 游戏开始
```

房间码为 6 位大写字母+数字，由创建方口头/消息告知加入方。

### 5.2 同步策略：确定型锁步

- **同步内容：** 仅玩家操作（出牌、攻击、结束回合等），不传动画或视觉状态
- **游戏逻辑：** 双方各运行完全相同的核心规则引擎
- **一致性保证：** 相同的初始状态 + 相同的操作序列 = 相同的结果状态

```
玩家操作 → Action { type, card_id, target_slot, ... }
                │
                ▼
         rpc("receive_action", action)
                │
        ┌───────┴───────┐
        ▼               ▼
    主机执行         客户端执行
    GameLogic       GameLogic
    .execute()      .execute()
```

### 5.3 不同步的内容

- 卡牌拖动动画
- UI 高亮、悬停效果
- 手牌排列动画
- 粒子/特效
- 音效

这些纯视觉内容各自在本地播放，不影响游戏状态。

### 5.4 断开处理

- 一方断线 → 对方收到通知，显示"对手已断开"
- 提供「等待重连」和「返回主菜单」两个选项
- 不做更复杂的中途重连（超出学生项目范围）

---

## 6. 项目文件结构

```
ww1-card-game/
├── project.godot
├── data/
│   ├── cards/
│   │   ├── units/
│   │   └── orders/
│   └── nations.json               # 阵营/国家元数据
├── assets/
│   ├── card_art/
│   ├── icons/
│   ├── fonts/
│   └── sounds/
├── scenes/
│   ├── main_menu.tscn
│   ├── battle.tscn
│   ├── deck_editor.tscn
│   └── ui_components/
│       ├── card.tscn
│       ├── hand.tscn
│       └── board_slot.tscn
├── scripts/
│   ├── core/
│   │   ├── game_logic.gd
│   │   ├── card_data.gd
│   │   ├── turn_manager.gd
│   │   └── battle_state.gd
│   ├── network/
│   │   └── network_manager.gd
│   ├── ui/
│   │   ├── card_display.gd
│   │   ├── hand_manager.gd
│   │   └── board.gd
│   └── autoload/
│       └── game_manager.gd
└── themes/
    └── ww1_theme.tres
```

---

## 7. 开发路线

### 阶段 1：单卡原型
**目标：** 一张可拖拽的卡牌，能放到棋盘格子上
**产出：** 验证 Godot 2D 拖拽交互可行

### 阶段 2：本地完整对战
**目标：** 两玩家同设备完成一局（抽牌 → 出牌 → 战斗结算 → 回合交替 → 胜负判定）
**产出：** 核心游戏逻辑跑通，不涉及网络

### 阶段 3：卡牌数据系统
**目标：** JSON 加载器 + 10-20 张测试卡牌
**产出：** 队友可开始独立填写卡牌数据

### 阶段 4：联网对战
**目标：** 房间创建 + 房间码加入 + P2P 操作同步 + 断线处理
**产出：** 两台设备可远程对战

### 阶段 5：完善打磨
**目标：** 主菜单 UI、卡组编辑器、动画、音效、移动端适配
**产出：** 接近可发布状态

每个阶段结束后均可展示和试玩。

---

## 8. 边界与约束

### 明确不做（当前版本）

- 服务器端游戏逻辑（全部在客户端执行）
- 账号系统 / 排行榜 / 匹配系统
- AI 对手（单人模式）
- 卡牌收藏 / 开包 / 经济系统
- 复杂的中途重连机制
- 游戏内聊天系统

### 机制相关

具体游戏机制已由团队讨论产出，详见：

> 📄 **[游戏机制设计文档](../game-mechanics.md)**

涵盖内容：
- 单位类型与属性（骑兵 / 步兵 / 坦克 / 战斗机 / 轰炸机 / 火炮 / 工事）
- 基础词条系统（守护、突击、坚守、潜行、防空、收缴、爆破 等 18 个关键词条）
- 交战规则（攻击-反击机制、陆空关系、结算顺序）
- 战争迷雾系统
- 卡牌与资源系统（经济 G / 指挥点 K / 战争点 Z）
- 待定事项

---

## 9. 风险与应对

| 风险 | 影响 | 应对 |
|---|---|---|
| 唯一程序员时间不足 | 项目停滞 | 按阶段交付，每阶段可展示，降低"全有或全无"风险 |
| P2P 直连不通（NAT 问题） | 在线模式不可用 | 优先确保局域网可用；在线作为加分项 |
| 机制设计持续变动 | 代码频繁返工 | 数据驱动架构——改卡牌不改代码；核心逻辑稳定后再填卡 |
| 美术资源不足 | 游戏视觉效果差 | 一战历史照片/海报属公共领域，大量可用素材 |
