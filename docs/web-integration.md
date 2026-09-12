# 1914 游戏项目 × 1914.fun 网站 — 联动开发文档

> **面向 agent / 开发者**。网站仓库：`github.com/fdvecbtwdh/1914_website`（Flask + SQLite，
> 部署文档见该仓库 `AGENT_DEPLOY.md`）。本文件描述网页侧已就绪的接口、与游戏项目的
> 数据契约、以及游戏服务端（阶段 4+）需要实现/对接的事项。

---

## 1. 网站侧现状（已实现）

| 模块 | 说明 |
|------|------|
| 卡牌社区 | 官方卡从本项目 `data/cards/**/*.json` 自动导入；玩家投稿卡与官方卡分离（source 字段） |
| Bug/Issue | 5 状态工作流，可与 GitHub Issues 单向同步（网站 → GitHub，队列化） |
| 账号/评论/投票/举报 | 常规社区功能，均已在网站侧闭环，游戏无需参与 |
| 状态页 `/status` | 网站服务器真实指标 + 游戏服务器状态占位区（**待游戏服接入**，见第 2 节） |
| 导航页 `/nav` | 枢纽页，之后会挂其他服务入口（`app/nav.py` 的 NAV_ITEMS 列表追加即可） |

网站卡牌字段与本项目卡牌 JSON **一一对应**，映射表见第 3 节。网站侧
`app/gameconstants.py` 是字段枚举的唯一参照（兵种/稀有度/词条/范围文案）。

---

## 2. 游戏服务器状态上报（状态页联动）★ 阶段 4 对接点

状态页 `https://1914.fun/status` 的"游戏服务器"面板当前显示**不可用**。
游戏服务端完成后，按以下协议向网站推送心跳即可自动点亮，无需改网站代码。

### 2.1 前置条件（网站侧一次性配置）

网站 `.env` 中设置共享密钥（留空 = 功能关闭，心跳接口返回 403）：

```ini
GAME_SERVER_TOKEN=<随机长字符串>
```

### 2.2 心跳协议

```
POST https://1914.fun/api/game-server/heartbeat
Header:  X-Game-Token: <GAME_SERVER_TOKEN>
Body:    application/json
{
  "status":      "online",  # 可选，默认 online；小写字母，≤20 字符
  "matches":     3,         # 当前进行中的对局数
  "max_matches": 10,        # 可同时进行的对局上限（状态页显示 已占用/上限 百分比条）
  "players":     8,         # 当前在线人数
  "max_players": 50,        # 在线人数上限
  "cpu":         42.5,      # 游戏服进程/整机 CPU 占用 %，0-100
  "mem":         61,        # 内存占用 %
  "version":     "0.1.0"    # 游戏服版本，≤40 字符
}
成功: 200 {"ok": true}
失败: 403 (token 错误/未配置) · 400 (非 JSON)
```

- **频率**：建议每 30–60 秒一次（状态页每 30 秒刷新）。网站侧超过 **60 秒**未收到
  上报即判定"不可用"，之前上报的数据停止展示（不需要显式下线消息）。
- **max_matches / max_players**：容量上限，用于状态页渲染"已占用/上限"百分比条；
  不上报则状态页只显示数量、不显示百分比。
- **同机部署**：游戏服与网站在同一台设备，心跳走 `http://127.0.0.1:8000` 即可（不必绕公网）。
- **语义**：`matches`/`players` 由游戏服自行统计后上报；网站只做展示，不校验业务逻辑。
- **网站侧性能**：网站指标由后台线程每 30 秒采样缓存，与访客数量无关；
  状态页对游戏服数据的展示条按占用率变色（绿 <60% ≤ 黄 <85% ≤ 红）。
- 网站侧接口实现：`1914_website/app/serverstatus.py`（`/api/game-server/heartbeat`）。

### 2.3 参考实现（游戏服侧，可直接复制改造）

```python
# heartbeat.py —— 游戏服务端启动时调用 start() 即可，失败静默、绝不影响游戏逻辑
import threading, time, psutil, requests   # requests 可换成 urllib

SITE  = "http://127.0.0.1:8000"   # 同机部署走本地；公网则为 https://1914.fun
TOKEN = "<与网站 .env 相同的 GAME_SERVER_TOKEN>"

def _push():
    payload = {
        "status":      "online",
        "matches":     get_active_matches(),   # TODO: 游戏服实现
        "max_matches": get_max_matches(),      # TODO: 游戏服实现
        "players":     get_online_players(),   # TODO: 游戏服实现
        "max_players": get_max_players(),      # TODO: 游戏服实现
        "cpu":         psutil.cpu_percent(),
        "mem":         psutil.virtual_memory().percent,
        "version":     "0.1.0",
    }
    try:
        requests.post(f"{SITE}/api/game-server/heartbeat", json=payload,
                      headers={"X-Game-Token": TOKEN}, timeout=5)
    except Exception:
        pass  # 网站不可达时静默跳过

def _loop():
    while True:
        _push()
        time.sleep(30)   # 30–60 秒均可；超 60 秒未上报状态页判定不可用

def start():
    threading.Thread(target=_loop, daemon=True).start()
```

### 2.4 游戏服务端 TODO（阶段 4 实现时）

- [ ] 实现`get_active_matches / get_max_matches / get_online_players / get_max_players` 四个统计函数
- [ ] 接入上方心跳循环（失败静默重试，绝不影响游戏逻辑）
- [ ] 从网站 `.env` 或命令行读取同一 `GAME_SERVER_TOKEN`
- [ ] 联调：推送后访问 `/status` 确认面板变绿、数值一致

---

## 3. 卡牌数据同步契约（已实现，改动需遵守）

网站是本项目 `data/cards/**/*.json` 的**下游消费者**：

1. 网站后台「从游戏项目导入官方卡牌」→ 读取游戏 `data/cards/units|orders/*.json`；
   游戏项目不在同一台机器时，使用网站仓库内置副本 `seed/cards/`（需手动覆盖更新）。
2. **字段映射**（网站 `app/card_sync.py` 的 `ALLOWED_FIELDS` 为白名单，未知字段被丢弃）：

   | 游戏 JSON 字段 | 网站列 | 约定 |
   |---|---|---|
   | id | game_id | 唯一键，**发布后不可改名** |
   | name | name | 1–30 字符 |
   | type | type | `unit` / `order` |
   | unit_class | unit_class | infantry/cavalry/tank/fighter/bomber/artillery/fortification |
   | cost_g / cost_k / attack / defense | 同名 | 整数 |
   | vision_range / attack_range | 同名 | 枚举见 `app/gameconstants.py` RANGES |
   | abilities | abilities (JSON) | 词条名可带等级，如 `"坚守2"`；枚举见 ABILITIES |
   | rarity | rarity | common/silver/gold（铜/银/金） |
   | flavor_text | flavor_text | ≤200 字符 |
   | art | —（暂不导入） | 网站后台可单独上传卡面图 |

3. **卡牌性质（tag，网站侧字段）**：网站为每张卡自动判定"正式/测试"性质——
   游戏 `id` 含 `test` 或名称含 `测试` 即判为测试卡，其余为正式卡。该字段不在游戏 JSON 中，无需游戏侧维护。
4. **开发注意事项**：
   - 新增卡牌字段 → 必须同步更新网站 `ALLOWED_FIELDS`、`app/gameconstants.py` 枚举与
     卡面模板 `_gcard.html`，否则网站静默丢弃/显示缺字。
   - 词条改名/等级规则变更 → 同步改 `gameconstants.ABILITIES` 与解析函数 `ability_name/ability_level`。
   - 删除游戏内卡牌 JSON → 网站重导入**不会**删除对应卡（防误删），需在网站后台手动处理。

---

## 4. GitHub Issue 联动（可选）

网站 Issue 按"所属"分流单向推送（网站 → GitHub）：
- 所属 = **游戏本体** → 推送到本仓库 `fdvecbtwdh/1914`
- 所属 = **网页** → 推送到 `fdvecbtwdh/1914_website`
启用：网站 `.env` 设 `GITHUB_TOKEN`（classic PAT，repo 权限，两个仓库都要能访问）。
推送的 Issue 标题带 `[1914.fun #id]` 前缀，正文含网站回链。游戏侧无需任何配合。

---

## 5. 其他开发注意事项

- 文档政策（2026-09 起）：docs/ 已随仓库发布（PDF 除外）；`有关1914单位的一些设定.xlsx` 仍仅本地。
- 网站展示的游戏版本号来自网站 `.env` 的 `GAME_VERSION`/`GAME_VERSION_LABEL`，
  游戏发新版时提醒网站管理员同步更新。
- 状态页/导航页为网站附属功能，与游戏机制无关；游戏数据契约只有第 2、3 节两处。
