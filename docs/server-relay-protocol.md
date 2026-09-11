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
| `data` | `b64: string` | 游戏数据（base64），原样转发给房内另一人；房内只有自己时丢弃 |
| `leave` | — | 离开房间 |

服务器 → 客户端：

| t | 字段 | 说明 |
|---|---|---|
| `joined` | `peers: int` | join 应答：1=已入房等待，2=配对成功 |
| `peer_left` | — | 另一人断开/离开 |
| `data` | `b64: string` | 转发的游戏数据 |
| `error` | `msg: string` | 房间满(3人)/其他错误，随后可断开 |

## 行为规则

1. 房间上限 2 人；第 3 个 join 回 `error` 并关闭
2. `join` 成功后必须回 `joined`；第二人加入时向房内**所有**成员广播 `peers:2`
3. 一方断开 → 向另一人发 `peer_left`
4. 空房间保留 10 分钟后可回收
5. 不限速不缓存不做语义校验（一期）；后续可加每秒帧数上限防滥用

## 参考实现（Node.js，约 40 行，可换任意语言）

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
      for (const c of rooms.get(ws.room)) if (c !== ws) c.send(JSON.stringify({ t: 'data', b64: m.b64 }));
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
