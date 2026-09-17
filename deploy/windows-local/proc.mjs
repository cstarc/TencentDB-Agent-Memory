#!/usr/bin/env node
// Windows 下可靠的进程管理辅助：bash 的 nohup+disown 无法让子进程脱离
// MSYS 控制台，父 shell（如工具调用的临时 shell）退出时后台服务可能被
// CTRL_CLOSE 连带杀掉。Node 的 spawn(detached: true) 在 Windows 上使用
// DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP，与父控制台完全解耦。
//
// 用法：
//   node proc.mjs start <name> <pidfile> <logfile> <cwd> -- <cmd> [args...]
//   node proc.mjs stop <name> <pidfile>
import { spawn } from "node:child_process";
import { openSync, writeFileSync, existsSync, readFileSync, unlinkSync } from "node:fs";
import { dirname, resolve } from "node:path";

const [, , action, name, pidfile, logfile, cwd] = process.argv;
const sep = process.argv.indexOf("--");
const cmd = process.argv.slice(sep + 1);

if (action === "start") {
  if (!cmd?.length) { console.error(`[proc] ${name}: no command`); process.exit(1); }
  const out = openSync(resolve(logfile), "a");
  const child = spawn(cmd[0], cmd.slice(1), {
    cwd: resolve(cwd),
    detached: true,
    stdio: ["ignore", out, out],
    windowsHide: true,
  });
  child.unref();
  writeFileSync(resolve(pidfile), String(child.pid));
  console.log(`[proc] ${name} started pid=${child.pid}`);
  process.exit(0);
}

if (action === "stop") {
  const pf = resolve(pidfile);
  if (!existsSync(pf)) { console.log(`[proc] ${name}: no pidfile`); process.exit(0); }
  const pid = parseInt(readFileSync(pf, "utf8").trim(), 10);
  try {
    // Windows 无 POSIX signal；taskkill /F 终止整个进程树（/T 连子进程）
    const r = spawn("taskkill", ["/PID", String(pid), "/T", "/F"], { stdio: "ignore", windowsHide: true });
    r.on("exit", (code) => {
      console.log(code === 0 ? `[proc] ${name} (pid=${pid}) killed` : `[proc] ${name} (pid=${pid}) not running`);
    });
  } catch {
    console.log(`[proc] ${name} (pid=${pid}) kill failed`);
  }
  unlinkSync(pf);
  process.exit(0);
}

console.error("usage: proc.mjs start|stop ...");
process.exit(1);
