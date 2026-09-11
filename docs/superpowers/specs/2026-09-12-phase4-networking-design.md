# 阶段4：联网对战设计 — 本地 / 局域网 P2P / 轻量服务器中继

**日期：** 2026-09-12
**状态：** 实现中（本仓库阶段4 首个可玩版本）
**前置：** 阶段1~3 已合并，全部测试绿

---

## 一、目标与约束

**目标：** 在不改动核心架构的前提下，让两名玩家在一台设备（已有）和局域网两台设备（本期新增）上完成完整对战；为互联网对战预留通道。

**约束（用户给定）：**

1. 服务器已有，但不能承受大压力 → **服务器只做信令/中继等轻量任务**，不承载游戏状态
2. 对战本体走 **P2P**（局域网直连为主）
3. 本地同屏模式继续保留，三种模式并存
4. 团队暂无人工测试条件 → 全部验证用 Godot 无头模式自动化

## 二、为什么动作同步就能保证两端一致

现有架构的三个事实（阶段2 设计即埋下的伏笔）：

1. **纯函数引擎：** `GameLogic` 所有方法都是 `state → action → new_state`，无隐藏状态、无随机分支（除开局洗牌）
2. **指令化操作：** 所有玩家操作都汇成 `submit_action(Dictionary)`，字典可直接序列化
3. **服务端校验已内建：** TurnManager 拒绝非活跃玩家的操作、非法阶段操作、引擎拒绝非法行动（返回原状态）

因此两端只需：**相同的初始随机种子 + 相同顺序的指令序列 = 完全相同的 BattleState**。不需要传输游戏状态，每步指令只有几十字节。

**唯一的随机源**是开局洗牌 `_shuffle_deck()`（全局 `randi()`）。方案：房主生成种子，开局时随 start 消息发给对方，双方各自 `seed(种子)` 后调用 `init_game`。

## 三、模式与拓扑

```
【本地】     单进程，现有流程不变

【局域网】   P2P 直连（ENet，默认端口 24565）
  玩家A(房主/P1) ◄──── UDP发现(1914/udp) + ENet ────► 玩家B(客机/P2)
  指令直接互发，无第三方

【互联网】   P2P + 轻量服务器中继（可选，二期）
  双方连 ws://服务器/中继，服务器只转发信令与指令字节流
  消息量：2人 × 每回合约10条 × 每条<200B ≈ 每局 <100KB，服务器零压力
```

**玩家编号约定：** 房主恒为 P1（先手），客机恒为 P2。

## 四、协议（ENet 直连）

传输层：Godot `ENetMultiplayerPeer`，端口 `24565/tcp`（发现 `1914/udp`）。

| 消息 | 方向 | 载荷 | 时机 |
|---|---|---|---|
| `net_start` | 房主→客机 | `{seed, p1_deck, p2_deck, p1_starter, p2_starter}` | 双方就绪后 |
| `net_action` | 双向 | `submit_action` 的字典原样 | 本端指令被引擎接受后 |
| `net_check` | 双向 | `{turn, phase, active, board_n, res, log_n, h}` 状态指纹 | 关键节点（测试/断线检测） |
| `net_rematch` | 双向 | 空 | 二期 |

**指令流转（本端玩家点 UI）：**

```
本地输入 → TurnManager.submit_action(a) 被接受
        → 发 signal action_applied(a)
        → NetworkManager.rpc_send_action(a) ──► 对端
对端收 → TurnManager.submit_action(a)（同样的校验链，同样的结果）
```

**指纹（防不同步）：** `h = hash(全部单位(位置,id,攻防,owner) + 资源 + 回合 + 阶段 + action_log长度)`。两端指纹不一致 → 立即报错断开（防沉默腐烂）。

## 五、轻量服务器中继协议（二期实现服务端，客户端本期就绪）

服务器只需实现"**按房间号转发的字节管道**"，不解析游戏语义：

```
C→S  {"t":"join","room":"AB12"}           # 加入/创建房间（room=4位码）
S→C  {"t":"joined","peers":1}             # 房间人数（1=等待,2=配对成功）
C→S  {"t":"data","b64":"..."}             # 游戏数据（base64，服务器不看内容）
S→C  {"t":"data","b64":"..."}             # 原样转发给房间内另一人
C→S  {"t":"leave"}                        # 离开
```

- 传输：WebSocket（Godot `WebSocketMultiplayerPeer` 作客户端）
- 服务器负载：每房间两个长连接，纯转发。一个 1核512MB 的机器可扛数千房间
- 客户端 `NetworkManager.relay_join(url, room)` 已实现，服务器端脚本示例见 `docs/server-relay-protocol.md`

## 六、模块改动

| 文件 | 改动 |
|---|---|
| `scripts/network/network_manager.gd` | 重写：ENet host/join、UDP 发现、start/action/check 消息、状态机（idle/hosting/joining/connected/ingame）、可选 WebSocket 中继客户端 |
| `scripts/autoload/game_manager.gd` | 三模式入口 `start_local_game / start_host_game / start_join_game`；按 `local_player_idx` 过滤本端输入；收到对端指令转交 TurnManager |
| `scripts/core/turn_manager.gd` | 新增 `action_applied(action)` 信号（2 行） |
| `scenes/main_menu.tscn` + `scripts/ui/main_menu.gd` | 主菜单：本地对战 / 创建游戏 / 加入游戏(IP) / 局域网发现 |
| `project.godot` | 主场景改为主菜单；注册 NetworkManager autoload |

**UI 输入隔离：** 网络模式下仅当 `active_player_index == local_player_idx` 才提交本端输入；对方回合界面照常显示（状态标签"玩家 X"），非法提交会被引擎拒绝。开局前的等待用菜单/打印提示。

## 七、测试方案（全部无头可跑）

1. **确定性回放测试**（单进程）：相同种子初始化两个 TurnManager，回放同一条指令序列，断言状态指纹一致 —— 验证"种子+指令=一致"的核心假设
2. **进程内双节点测试**（单进程，两个 SceneMultiplayer + 两个 ENet peer 走真实 localhost 回环）：连接、start 消息、指令互发、指纹一致
3. **双进程冒烟测试**：host 进程 + client 进程真实走完整开局→若干指令→指纹核对→退出码 0

## 八、本期不做

- WebRTC 打洞/STUN（国内 NAT 环境复杂，走服务器中继路线代替）
- 断线重连、 spectator、房间大厅页
- 中继服务端脚本部署（协议已定，部署到用户服务器是运维动作）
