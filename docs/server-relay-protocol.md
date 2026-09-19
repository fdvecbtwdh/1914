# 1914 轻量中继服务器协议（v1）

> 给运维/后端同学：在现有服务器上部署一个"按房间转发的字节管道"即可，**不需要理解游戏内容**。
> 客户端侧已实装（`scripts/network/network_manager.gd` 的 relay 模式）。

## 运行特征

- 传输：WebSocket（明文 ws:// 即可，后续可加 wss）
- 每局对战 = 1 个房间 = 2 个长连接；服务器只做转发
- 流量估算：每局 < 100 KB，每房峰值 ~10 条/分钟 → 1核512MB 可承载数千房间并发

## 消息定义（JSON，UTF-8，一帧一条）

客户端 → 服务器：

| t | 字段 | 说明 |
|---|---|---|
| `join` | `room: string(4-8位)` | 加入房间；不存在则创建并等待。重复 join 视为实现错误 |
| 任意其他 t（ready/start/action/check/...） | 任意字段 | 游戏数据，**整条原样转发**给房内另一人；房内只有自己时丢弃（服务器不理解内容） |
| `leave` | — | 离开房间 |

服务器 → 客户端：

| t | 字段 | 说明 |
|---|---|---|
| `joined` | `peers: int` | join 应答：1=已入房等待，2=配对成功 |
| `peer_left` | — | 另一人断开/离开 |
| `data` | 任意 JSON | 转发的游戏数据（原样） |
| `error` | `msg: string` | 房间满(3人)/其他错误，随后可断开 |

## 行为规则

1. 房间上限 2 人；第 3 个 join 回 `error` 并关闭
2. `join` 成功后必须回 `joined`；第二人加入时向房内**所有**成员广播 `peers:2`
3. 一方断开 → 向另一人发 `peer_left`
4. 空房间保留 10 分钟后可回收
5. 不限速不缓存不做语义校验（一期）；后续可加每秒帧数上限防滥用

## 参考实现（Node.js，约 40 行，可换任意语言）

> 与 `deploy/relay-server.js` 相同，以该文件为准。客户端实际透传的游戏消息类型：
> `{"t":"ready"}`、`{"t":"start","payload":{...}}`、`{"t":"action","action":{...}}`、`{"t":"check","fp":"..."}`（服务器均按 `data` 原样转发，不解析）。

```js
import { WebSocketServer } from 'ws';
const rooms = new Map(); // room -> Set<ws>
const wss = new WebSocketServer({ port: 24566 });
wss.on('connection', ws => {
  ws.room = null;
  ws.on('message', raw => {
    let m; try { m = JSON.parse(raw); } catch { return; }
    if (m.t === 'join') {
      const set = rooms.get(m.room) ?? new Set();
      if (set.size >= 2) return ws.send(JSON.stringify({ t: 'error', msg: 'room full' }));
      set.add(ws); ws.room = m.room; rooms.set(m.room, set);
      const peers = set.size;
      for (const c of set) c.send(JSON.stringify({ t: 'joined', peers }));
    } else if (m.t === 'data' && ws.room) {
      for (const c of rooms.get(ws.room)) if (c !== ws && c.readyState === 1) c.send(raw.toString());
    } else if (m.t === 'leave' && ws.room) {
      leave(ws, rooms);
    }
  });
  ws.on('close', () => { if (ws.room) { leave(ws, rooms); } });
});
function leave(ws, rooms) {
  const set = rooms.get(ws.room);
  if (!set) return;
  set.delete(ws);
  for (const c of set) c.send(JSON.stringify({ t: 'peer_left' }));
  if (set.size === 0) rooms.delete(ws.room);
  ws.room = null;
}
```

---

## 附录：对局录像存储 API（2026-09-19 增补）

中继服务器同时提供 HTTP 录像存储（与 WebSocket 同一进程、同一端口）。

### 端点

| 方法 | 路径 | 说明 |
|------|------|------|
| POST | `/replay` | 上传录像（body = 录像 JSON，含 `game_id`） |
| GET | `/replay/:game_id` | 下载录像；不存在或已过期返回 404 |

### 行为

- **先到为准**：同一 `game_id` 只保存第一份上传（后到者收到 `{ok:true, existed:true}`，内容被忽略）。双方各自上传自己的录像，服务器取第一份；未来可扩展为双份比对以检测篡改。
- **2 小时过期**：录像创建 2 小时后由服务器每 60 秒一次的清扫删除——异常结束（断线）的战局不会永久占用存储。TTL 可用环境变量 `REPLAY_TTL_MS` 覆盖（测试用），清扫对内存中的 Map 执行，无需持久化。
- **上限**：请求体 8MB，`game_id` 最长 128 字符。
- 服务器不可用时客户端静默降级：上传失败仅记日志；复盘下载失败在界面提示，不影响正常对局。

### 录像结构（v1）

```json
{
  "version": 1,
  "game_id": "房间码或 direct-<时间戳>",
  "mode": "local | net",
  "created_ms": 1726740000000,
  "winner": 0,
  "rounds": 5,
  "actions": [ {"type": "deploy", "turn": 1, "phase": "deploy", "player": 0, "card_id": "...", "row": 0, "col": 2}, ... ],
  "snapshots": [ {开局快照}, {第 1 步后}, ... ]
}
```

- `actions` 来自引擎 `action_log`（每条自动带 `turn` / `phase` / `player` 元数据；`destroy` 条目的 `player` 为**击杀方**）。
- 快照为精简棋盘状态（单位、资源、手牌/购买区、战线占领度、回合信息）。快照[0] 是开局局面，snapshots[i+1] 对应第 i 步操作后的局面——复盘界面点击操作条目即显示该局面（无迷雾，全图公开）。
- 防作弊考量：复盘数据取自服务器而非本端重新生成，且对局中迷雾信息从不进客户端渲染之外的通道；先到为准 + 未来双份比对可发现单端篡改。
