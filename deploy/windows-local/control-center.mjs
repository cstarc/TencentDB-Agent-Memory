#!/usr/bin/env node
// TAM 服务控制台 —— 本地网页版图形界面（127.0.0.1:8127）
// 状态灯 + 启动/停止全部服务 + 操作日志，浏览器渲染，不依赖任何桌面窗口机制
import http from "node:http";
import { spawn } from "node:child_process";
import { existsSync, readFileSync, appendFileSync } from "node:fs";
import { resolve } from "node:path";

const PORT = 8127;
const HOST = "127.0.0.1";
const RUN = "E:/tam/run";
const BASH = "D:/Program Files/Git/usr/bin/bash.exe";
const OPS_LOG = resolve(RUN, "logs/gui-ops.log");

const SERVICES = [
  { name: "memory-core", port: 8420, desc: "记忆内核" },
  { name: "knowledge", port: 8424, desc: "知识服务" },
  { name: "panel", port: 8125, desc: "管理面板" },
  { name: "proxy", port: 8096, desc: "代理入口" },
];

function checkPort(port) {
  return new Promise((res) => {
    const net = import("node:net");
    net.then(({ default: netMod }) => {
      const s = new netMod.Socket();
      const done = (ok) => { s.destroy(); res(ok); };
      s.setTimeout(500);
      s.once("connect", () => done(true));
      s.once("timeout", () => done(false));
      s.once("error", () => done(false));
      s.connect(port, "127.0.0.1");
    });
  });
}

async function status() {
  for (const s of SERVICES) s.up = await checkPort(s.port);
  return SERVICES;
}

let currentChild = null; // 进行中的启停操作；busy = 子进程尚未退出
function runScript(op) {
  if (currentChild && !currentChild.exited) return false;
  const rel = op === "start" ? "./start-all.sh" : "./stop-all.sh";
  try {
    appendFileSync(OPS_LOG, `\n===== ${op} ${new Date().toLocaleString()} =====\n`);
  } catch {}
  const child = spawn(BASH, ["-lc", `cd /e/tam/run && ${rel} >> logs/gui-ops.log 2>&1`], {
    cwd: RUN, detached: true, stdio: "ignore", windowsHide: true,
  });
  child.exited = false;
  child.once("exit", () => { child.exited = true; });
  child.unref();
  currentChild = child;
  return true;
}

function tailOps() {
  try {
    if (!existsSync(OPS_LOG)) return "(暂无操作日志)";
    const lines = readFileSync(OPS_LOG, "utf8").split(/\r?\n/);
    return lines.slice(-60).join("\n") || "(暂无操作日志)";
  } catch { return "(日志读取失败)"; }
}

const HTML = `<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8">
<title>TAM 服务控制台</title>
<style>
  body{font-family:"Microsoft YaHei UI",sans-serif;background:#14181f;color:#d8dee7;
       margin:0;display:flex;justify-content:center;padding:40px 16px}
  .card{background:#1c222c;border:1px solid #2a3342;border-radius:14px;padding:28px 32px;
        width:560px;box-shadow:0 8px 30px rgba(0,0,0,.4)}
  h1{font-size:19px;margin:0 0 4px}
  .sub{color:#8b96a5;font-size:12.5px;margin-bottom:20px}
  .svc{display:flex;align-items:center;gap:12px;padding:10px 14px;border-radius:9px;
       background:#151a23;margin-bottom:8px}
  .dot{width:12px;height:12px;border-radius:50%;background:#5a6472;flex:none;
       box-shadow:0 0 8px transparent}
  .dot.up{background:#2ecc71;box-shadow:0 0 8px #2ecc7188}
  .dot.down{background:#e74c3c}
  .dot.busy{background:#f1c40f}
  .svc b{width:130px;font-weight:600}
  .svc span{color:#8b96a5;font-size:12.5px;flex:1}
  .svc .st{font-size:12.5px;width:64px;text-align:right}
  .st.up{color:#2ecc71}.st.down{color:#e74c3c}.st.busy{color:#f1c40f}
  .btns{display:flex;gap:10px;margin:18px 0 14px}
  button{flex:1;padding:11px 0;border:0;border-radius:9px;font-size:14px;cursor:pointer;
         font-family:inherit;transition:filter .15s}
  button:hover{filter:brightness(1.15)}
  button:disabled{cursor:not-allowed;filter:brightness(.6)}
  #start{background:#2ecc71;color:#08240f;font-weight:600}
  #stop{background:#e74c3c;color:#2b0808;font-weight:600}
  pre{background:#10141b;border-radius:9px;padding:12px;font-size:11.5px;line-height:1.5;
      max-height:190px;overflow:auto;color:#9fb0c3;white-space:pre-wrap}
  .links{margin-top:14px;font-size:12.5px;color:#8b96a5}
  .links a{color:#5dade2;text-decoration:none;margin-right:14px}
</style></head><body>
<div class="card">
  <h1>TAM 服务控制台</h1>
  <div class="sub">TencentDB-Agent-Memory 本机服务 · 每 3 秒自动刷新状态</div>
  <div id="svcs"></div>
  <div class="btns">
    <button id="start">启动全部服务</button>
    <button id="stop">停止全部服务</button>
  </div>
  <pre id="log">加载中…</pre>
  <div class="links">
    <a href="http://localhost:8125/" target="_blank">管理面板</a>
    <a href="http://localhost:8424/docs" target="_blank">Knowledge Swagger</a>
    <a href="http://localhost:8096/health" target="_blank">Proxy 状态</a>
  </div>
</div>
<script>
const NAMES = {8420:'memory-core',8424:'knowledge',8125:'panel',8096:'proxy'};
const DESCS = {8420:'记忆内核 gateway',8424:'知识服务 (Wiki/CodeGraph)',8125:'管理面板 UI',8096:'coding agent 代理'};
async function refresh(){
  try{
    const r = await fetch('/status'); const d = await r.json();
    document.getElementById('svcs').innerHTML = d.services.map(s =>
      '<div class="svc"><div class="dot '+s.state+'"></div><b>'+NAMES[s.port]+
      ' (:'+s.port+')</b><span>'+DESCS[s.port]+'</span><div class="st '+s.state+'">'+
      (s.state==='up'?'运行中':'已停止')+'</div></div>').join('');
    document.getElementById('start').disabled = d.busy;
    document.getElementById('stop').disabled = d.busy;
  }catch(e){}
  try{
    const l = await fetch('/opslog'); document.getElementById('log').textContent = await l.text();
  }catch(e){}
}
async function op(name){
  const btns = document.querySelectorAll('button');
  btns.forEach(b=>b.disabled=true);
  await fetch('/'+name, {method:'POST'});
  setTimeout(refresh, 1500);
}
document.getElementById('start').onclick = ()=>op('start');
document.getElementById('stop').onclick = ()=>op('stop');
setInterval(refresh, 3000);
refresh();
</script></body></html>`;

http.createServer(async (req, res) => {
  const url = req.url.split("?")[0];
  if (url === "/") {
    res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
    return res.end(HTML);
  }
  if (url === "/status") {
    const svcs = await status();
    const busy = !!(currentChild && !currentChild.exited);
    for (const s of svcs) s.state = s.up ? "up" : "down";
    res.writeHead(200, { "Content-Type": "application/json; charset=utf-8" });
    return res.end(JSON.stringify({ busy, services: svcs }));
  }
  if (url === "/opslog") {
    res.writeHead(200, { "Content-Type": "text/plain; charset=utf-8" });
    return res.end(tailOps());
  }
  if (url === "/start" && req.method === "POST") {
    const ok = runScript("start");
    res.writeHead(200, { "Content-Type": "application/json" });
    return res.end(JSON.stringify({ accepted: ok }));
  }
  if (url === "/stop" && req.method === "POST") {
    const ok = runScript("stop");
    res.writeHead(200, { "Content-Type": "application/json" });
    return res.end(JSON.stringify({ accepted: ok }));
  }
  res.writeHead(404); res.end("not found");
}).listen(PORT, HOST, () => console.log(`TAM control console on http://${HOST}:${PORT}`));
