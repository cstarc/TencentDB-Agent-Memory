#!/usr/bin/env bash
# 停止由 start-all.sh 启动的四个服务。
# 先按 pid 文件 kill（优雅），再按端口兜底清理残留监听（fuser / ss）。
set -uo pipefail
RUN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "$RUN_DIR/.env" ]]; then
  set -a; source "$RUN_DIR/.env"; set +a
fi
MEMORY_CORE_PORT="${MEMORY_CORE_PORT:-8420}"
PANEL_PORT="${PANEL_PORT:-8125}"
KNOWLEDGE_PORT="${KNOWLEDGE_PORT:-8424}"
PROXY_PORT="${PROXY_PORT:-8096}"

for name in proxy panel knowledge core; do
  pidfile="$RUN_DIR/pids/$name.pid"
  if [[ -f "$pidfile" ]]; then
    pid=$(cat "$pidfile")
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null
      # 最多等 5 秒优雅退出，超时强杀
      for _ in $(seq 1 10); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.5
      done
      kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
      echo "[ok] $name (pid=$pid) 已停止"
    else
      echo "[info] $name (pid=$pid) 已不在运行"
    fi
    rm -f "$pidfile"
  else
    echo "[info] $name 无 pid 记录"
  fi
done

# 兜底：清掉仍占用目标端口的残留进程
for p in "$PROXY_PORT" "$MEMORY_CORE_PORT" "$KNOWLEDGE_PORT" "$PANEL_PORT"; do
  if command -v fuser >/dev/null 2>&1; then
    fuser -k "${p}/tcp" >/dev/null 2>&1 && echo "[ok] 端口 $p 残留监听已清理" || true
  elif command -v ss >/dev/null 2>&1; then
    for pid in $(ss -ltnp 2>/dev/null | awk -v pt=":${p}" '$4 ~ pt"$"' \
        | grep -oP 'pid=\K[0-9]+' | sort -u); do
      kill "$pid" 2>/dev/null && echo "[ok] 端口 $p 残留进程 $pid 已终止" || true
    done
  fi
done

echo "[done] 全部端口已清理"
