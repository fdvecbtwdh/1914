# 阶段4：联网对战实现计划（6 任务）

前置阅读：`docs/superpowers/specs/2026-09-12-phase4-networking-design.md`

| 任务 | 内容 | 产出 | 状态 |
|---|---|---|---|
| Task 1 | TurnManager 加 `action_applied` 信号；GameLogic 增加 `state_fingerprint()` 纯函数 | 指令外发钩子 + 同步校验基础 | ✅ |
| Task 2 | NetworkManager 重写：ENet host/join、连接状态机、`net_start/net_action/net_check` 消息 | 局域网直连能力 | ✅ |
| Task 3 | UDP 局域网发现（host 侧监听 1914/udp，join 侧广播探测） | 免输 IP 入局 | ✅ |
| Task 4 | GameManager 三模式改造 + 本端输入过滤 + 远端指令接入 | 三模式可玩 | ✅ |
| Task 5 | 主菜单 UI（本地/创建/加入/发现）+ project.godot 主场景切换 | 用户入口 | ✅ |
| Task 6 | 测试：确定性回放、进程内双节点、双进程 localhost 冒烟 | 无头全绿 | ✅ |
| （二期） | WebSocket 中继客户端 `relay_join()` + 服务端脚本 | 互联网对战 | 协议已定 |

## 验证命令

```bash
GODOT="/d/SteamLibrary/steamapps/common/Godot Engine/godot.windows.opt.tools.64.exe"
"$GODOT" --headless --path . res://tests/test_network_scene.tscn        # 确定性+进程内双节点
# 双进程冒烟：两个终端或后台同时跑
"$GODOT" --headless --path . res://tests/net_host_check.tscn &
"$GODOT" --headless --path . res://tests/net_client_check.tscn
```
