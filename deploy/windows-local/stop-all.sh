#!/usr/bin/env bash
# 停止由 start-all.sh 启动的四个服务。
# 以"按端口杀监听进程"为准（bash 的 kill -0 对 Windows 原生 pid 不可靠，
# 曾导致误报"已不在运行"而漏杀，后续重启 EADDRINUSE）；pid 文件仅作清理。
set -uo pipefail
RUN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "$RUN_DIR/.env" ]]; then
  set -a; source "$RUN_DIR/.env"; set +a
fi
PORTS="${PROXY_PORT:-8096},${MEMORY_CORE_PORT:-8420},${KNOWLEDGE_PORT:-8424},${PANEL_PORT:-8125}"

powershell -NoProfile -Command "
foreach (\$port in $PORTS) {
  \$c = Get-NetTCPConnection -LocalPort \$port -State Listen -ErrorAction SilentlyContinue
  if (\$c) {
    foreach (\$procId in (\$c.OwningProcess | Sort-Object -Unique)) {
      try { Stop-Process -Id \$procId -Force -ErrorAction Stop; Write-Output \"[ok] port \$port -> killed pid \$procId\" }
      catch { Write-Output \"[warn] port \$port -> pid \$procId kill failed: \$(\$_.Exception.Message)\" }
    }
  } else { Write-Output \"[info] port \$port -> no listener\" }
}
"

rm -f "$RUN_DIR"/pids/*.pid
echo "[done] 全部端口已清理"
