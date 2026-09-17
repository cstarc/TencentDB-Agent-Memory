#!/usr/bin/env node
// 按端口查杀监听进程 —— 替代 powershell Get-NetTCPConnection/Stop-Process。
// 只用 netstat + taskkill（原生 exe），在无控制台的 detached 上下文中不会挂起。
import { spawnSync } from "node:child_process";

const ports = process.argv.slice(2).map(Number).filter(Number.isFinite);
if (!ports.length) { console.error("usage: node kill-ports.mjs <port>..."); process.exit(1); }

const res = spawnSync("netstat", ["-ano"], { encoding: "utf8", windowsHide: true });
if (res.error || !res.stdout) { console.error("netstat failed:", res.error); process.exit(1); }

const wanted = new Set(ports);
const pids = new Set();
for (const line of res.stdout.split(/\r?\n/)) {
  const m = line.match(/^\s*TCP\s+\S+?:(\d+)\s+\S+\s+LISTENING\s+(\d+)\s*$/i);
  if (m && wanted.has(Number(m[1]))) pids.add(Number(m[2]));
}

if (!pids.size) { console.log("[info] 目标端口无监听进程"); process.exit(0); }
for (const pid of pids) {
  const k = spawnSync("taskkill", ["/PID", String(pid), "/T", "/F"], { encoding: "utf8", windowsHide: true });
  console.log(k.status === 0 ? `[ok] killed pid ${pid}` : `[warn] pid ${pid} kill failed (exit ${k.status})`);
}
