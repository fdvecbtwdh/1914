// 1914 轻量中继 + 录像存储服务器
// 协议文档：docs/server-relay-protocol.md
// 运行：npm install ws && node relay-server.js   （默认端口 24566）
//
// WebSocket：按房间转发的字节管道，不理解游戏内容（原有功能不变）
// HTTP 录像：POST /replay 上传对局录像；GET /replay/:game_id 下载；2 小时过期自动删除。
// 复盘数据存服务器而非客户端，双方赛后从服务器拉取，本地无法伪造；
// 同一 game_id 先到为准（后到的上传被忽略，未来可扩展为双方比对）。

import http from 'node:http';
import { WebSocketServer } from 'ws';

const PORT = process.env.RELAY_PORT || 24566;
const REPLAY_TTL_MS = parseInt(process.env.REPLAY_TTL_MS || '', 10) || 2 * 60 * 60 * 1000; // 2 小时
const MAX_BODY_BYTES = 8 * 1024 * 1024; // 8MB 上限（对局录像远小于此）

const rooms = new Map();    // room -> Set<ws>
const replays = new Map();  // game_id -> { replay, created_ms }

const server = http.createServer((req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Content-Type', 'application/json; charset=utf-8');

  if (req.method === 'POST' && req.url === '/replay') {
    const chunks = [];
    let size = 0;
    let aborted = false;
    req.on('data', c => {
      size += c.length;
      if (size > MAX_BODY_BYTES) {
        aborted = true;
        res.writeHead(413).end(JSON.stringify({ ok: false, error: 'body too large' }));
        req.destroy();
        return;
      }
      chunks.push(c);
    });
    req.on('end', () => {
      if (aborted) return;
      let replay;
      try { replay = JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch {
        res.writeHead(400).end(JSON.stringify({ ok: false, error: 'invalid json' }));
        return;
      }
      const gameId = replay && replay.game_id;
      if (!gameId || typeof gameId !== 'string' || gameId.length > 128) {
        res.writeHead(400).end(JSON.stringify({ ok: false, error: 'missing game_id' }));
        return;
      }
      const existed = replays.has(gameId);
      if (!existed) {
        replays.set(gameId, { replay, created_ms: Date.now() });
        console.log(`[replay] stored game_id=${gameId} (${replays.size} total)`);
      }
      res.writeHead(200).end(JSON.stringify({ ok: true, existed }));
    });
    return;
  }

  if (req.method === 'GET' && req.url.startsWith('/replay/')) {
    const id = decodeURIComponent(req.url.slice('/replay/'.length).split('?')[0]);
    const entry = replays.get(id);
    if (!entry) {
      res.writeHead(404).end(JSON.stringify({ ok: false, error: 'not found or expired' }));
      return;
    }
    res.writeHead(200).end(JSON.stringify(entry.replay));
    return;
  }

  res.writeHead(404).end(JSON.stringify({ ok: false, error: 'not found' }));
});

// 每 60 秒清扫过期录像：录像创建 2 小时后删除，避免异常结束的战局永远占着内存
setInterval(() => {
  const now = Date.now();
  for (const [id, entry] of replays) {
    if (now - entry.created_ms > REPLAY_TTL_MS) {
      replays.delete(id);
      console.log(`[replay] expired game_id=${id}`);
    }
  }
}, 60_000).unref();

const wss = new WebSocketServer({ server });
server.listen(PORT, () => {
  console.log(`[1914-relay] listening on :${PORT} (ws relay + http replay, ttl=${Math.round(REPLAY_TTL_MS / 60000)}min)`);
});

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
    } else if (ws.room) {
      // 除 join/leave 外的一切消息（ready/start/action/check/...）原样透传给房内另一人
      for (const c of rooms.get(ws.room)) {
        if (c !== ws && c.readyState === 1) c.send(raw.toString());
      }
    } else if (false) {
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
