// 1914 轻量中继服务器 — 按房间转发的字节管道，不理解游戏内容
// 协议文档：docs/server-relay-protocol.md
// 运行：npm install ws && node relay-server.js   （默认端口 24566）

import { WebSocketServer } from 'ws';

const PORT = process.env.RELAY_PORT || 24566;
const rooms = new Map(); // room -> Set<ws>

const wss = new WebSocketServer({ port: PORT });
console.log(`[1914-relay] listening on :${PORT}`);

wss.on('connection', ws => {
  ws.room = null;
  ws.on('message', raw => {
    let m;
    try { m = JSON.parse(raw); } catch { return; }
    if (m.t === 'join') {
      const set = rooms.get(m.room) ?? new Set();
      if (set.size >= 2) {
        ws.send(JSON.stringify({ t: 'error', msg: 'room full' }));
        ws.close();
        return;
      }
      set.add(ws);
      ws.room = m.room;
      rooms.set(m.room, set);
      const peers = set.size;
      for (const c of set) c.send(JSON.stringify({ t: 'joined', peers }));
      console.log(`[join] room=${m.room} peers=${peers}`);
    } else if (m.t === 'data' && ws.room) {
      // 整条透传（不看游戏语义），房间内另一人原样收到
      for (const c of rooms.get(ws.room)) {
        if (c !== ws && c.readyState === 1) c.send(raw.toString());
      }
    } else if (m.t === 'leave' && ws.room) {
      leave(ws);
    }
  });
  ws.on('close', () => { if (ws.room) leave(ws); });
  ws.on('error', () => { if (ws.room) leave(ws); });
});

function leave(ws) {
  const set = rooms.get(ws.room);
  if (!set) return;
  set.delete(ws);
  for (const c of set) c.send(JSON.stringify({ t: 'peer_left' }));
  if (set.size === 0) rooms.delete(ws.room);
  console.log(`[leave] room=${ws.room} remaining=${set.size}`);
  ws.room = null;
}
