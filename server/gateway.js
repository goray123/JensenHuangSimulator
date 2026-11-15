// Demo gateway: serves the Godot web export, forwards /ws to the `--web-host` game on this PC,
// shows a QR page at /qr, and (with --tunnel) opens a free Cloudflare quick tunnel to the internet.
// Usage: node server/gateway.js [--web <dir>] [--port 8090] [--game-port 9080] [--tunnel]
const http = require('http');
const net = require('net');
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');
const { spawn, exec } = require('child_process');
const QRCode = require('qrcode');

const args = process.argv.slice(2);
const opt = (name, fallback) => {
  const i = args.indexOf(name);
  return i >= 0 && args[i + 1] ? args[i + 1] : fallback;
};
const WEB_DIR = path.resolve(opt('--web', path.join(__dirname, '..', '..', 'webout')));
const PORT = Number(opt('--port', 8090));
const GAME_PORT = Number(opt('--game-port', 9080));
const CLOUDFLARED = opt('--cloudflared', path.join(__dirname, 'bin', 'cloudflared.exe'));
let publicUrl = '';

const TYPES = {
  '.html': 'text/html; charset=utf-8', '.js': 'application/javascript', '.wasm': 'application/wasm',
  '.pck': 'application/octet-stream', '.png': 'image/png', '.svg': 'image/svg+xml', '.ico': 'image/x-icon',
  '.json': 'application/json',
};

// Gzip the big files once so each visitor downloads less through this PC's upload.
for (const name of fs.existsSync(WEB_DIR) ? fs.readdirSync(WEB_DIR) : []) {
  const file = path.join(WEB_DIR, name);
  if (!/\.(wasm|pck|js|html)$/.test(name) || fs.existsSync(file + '.gz') && fs.statSync(file + '.gz').mtimeMs >= fs.statSync(file).mtimeMs) continue;
  console.log(`gzip ${name} ...`);
  fs.writeFileSync(file + '.gz', zlib.gzipSync(fs.readFileSync(file), { level: 6 }));
}

async function qrPage(res) {
  const body = publicUrl
    ? `${await QRCode.toString(publicUrl, { type: 'svg', margin: 1 })}<p class="url">${publicUrl}</p><p>QR을 찍거나 주소를 열고 START를 누르세요. 먼저 들어온 사람이 남편, 다음 사람이 아내입니다.</p>`
    : `<p>${args.includes('--tunnel') ? '인터넷 주소를 여는 중…' : '터널 없이 실행 중: http://localhost:' + PORT}</p>`;
  res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' });
  res.end(`<!doctype html><html lang="ko"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>EXTREME DIVORCE QR</title><meta http-equiv="refresh" content="${publicUrl ? 30 : 2}">
<style>:root{color-scheme:light}body{margin:0;min-height:100vh;display:flex;flex-direction:column;align-items:center;justify-content:center;
background:#ff3d8b;font-family:system-ui,sans-serif;color:#111;text-align:center;padding:16px;box-sizing:border-box}
h1{font-size:clamp(28px,6vw,64px);margin:0 0 16px;color:#fff;-webkit-text-stroke:2px #111}
svg{width:min(70vh,80vw);height:auto;background:#fff;border:8px solid #111;border-radius:16px}
.url{font-size:clamp(14px,2.4vw,24px);font-weight:700;word-break:break-all}p{font-size:clamp(14px,2vw,22px)}</style></head>
<body><h1>EXTREME DIVORCE</h1>${body}</body></html>`);
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://x');
  if (url.pathname === '/qr') return void qrPage(res).catch(() => res.end());
  const rel = url.pathname === '/' ? 'index.html' : decodeURIComponent(url.pathname).replace(/^\/+/, '');
  const file = path.join(WEB_DIR, rel);
  if (!file.startsWith(WEB_DIR) || !fs.existsSync(file) || !fs.statSync(file).isFile()) {
    res.writeHead(404);
    return void res.end('not found');
  }
  // Revalidate every time: a re-export keeps the same file names, and an old .pck would speak the old protocol.
  const modified = fs.statSync(file).mtime.toUTCString();
  if (req.headers['if-modified-since'] === modified) {
    res.writeHead(304);
    return void res.end();
  }
  const headers = {
    'Content-Type': TYPES[path.extname(file)] || 'application/octet-stream',
    'Cache-Control': 'no-cache',
    'Last-Modified': modified,
  };
  let send = file;
  if (fs.existsSync(file + '.gz') && /gzip/.test(req.headers['accept-encoding'] || '')) {
    send = file + '.gz';
    headers['Content-Encoding'] = 'gzip';
  }
  headers['Content-Length'] = fs.statSync(send).size;
  res.writeHead(200, headers);
  fs.createReadStream(send).pipe(res);
});

// Hand the browser's WebSocket upgrade straight to the Godot host (raw TCP pipe, no re-framing).
server.on('upgrade', (req, socket, head) => {
  if (!req.url.startsWith('/ws')) return socket.destroy();
  const game = net.connect(GAME_PORT, '127.0.0.1', () => {
    let lines = `${req.method} ${req.url} HTTP/1.1\r\n`;
    for (let i = 0; i < req.rawHeaders.length; i += 2) lines += `${req.rawHeaders[i]}: ${req.rawHeaders[i + 1]}\r\n`;
    game.write(lines + '\r\n');
    if (head && head.length) game.write(head);
    socket.setNoDelay(true);
    game.setNoDelay(true);
    socket.pipe(game).pipe(socket);
    console.log(`guest connected from ${req.headers['cf-connecting-ip'] || socket.remoteAddress}`);
  });
  game.on('error', () => socket.destroy());
  socket.on('error', () => game.destroy());
  socket.on('close', () => game.destroy());
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`gateway: http://localhost:${PORT}  (QR page: http://localhost:${PORT}/qr, web files: ${WEB_DIR})`);
  if (args.includes('--tunnel')) startTunnel();
  if (!args.includes('--no-open')) exec(`start "" "http://127.0.0.1:${PORT}/qr"`);
});

function startTunnel() {
  // 127.0.0.1, not localhost: another app may hold [::1] on the same port.
  const tunnel = spawn(CLOUDFLARED, ['tunnel', '--no-autoupdate', '--url', `http://127.0.0.1:${PORT}`]);
  const scan = (chunk) => {
    const found = String(chunk).match(/https:\/\/[a-z0-9-]+\.trycloudflare\.com/);
    if (found && !publicUrl) {
      publicUrl = found[0];
      console.log(`PUBLIC URL: ${publicUrl}`);
    }
  };
  tunnel.stdout.on('data', scan);
  tunnel.stderr.on('data', scan);
  tunnel.on('exit', (code) => console.log(`cloudflared exited (${code})`));
  process.on('exit', () => tunnel.kill());
  process.on('SIGINT', () => process.exit());
}
