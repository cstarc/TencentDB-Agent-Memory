#!/usr/bin/env bash
# 停止由 start-all.sh 启动的四个服务。
# 用 kill-ports.mjs（netstat+taskkill）按端口杀监听进程 —— 不用 powershell
# （无控制台的 detached 上下文里 powershell 启动会挂起）；pid 文件仅作清理。
set -uo pipefail
RUN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "$RUN_DIR/.env" ]]; then
  set -a; source "$RUN_DIR/.env"; set +a
fi

node "$RUN_DIR/kill-ports.mjs" \
  "${PROXY_PORT:-8096}" "${MEMORY_CORE_PORT:-8420}" "${KNOWLEDGE_PORT:-8424}" "${PANEL_PORT:-8125}"

rm -f "$RUN_DIR"/pids/*.pid
echo "[done] 全部端口已清理"
