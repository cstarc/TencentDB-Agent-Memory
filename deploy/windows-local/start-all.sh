#!/usr/bin/env bash
# TencentDB-Agent-Memory Windows/无 Docker 源码部署一键启动脚本。
# 等价于官方 deploy/global-images/start-all.sh，但直接用 node 拉起四个服务：
#   memory-core(8420) → knowledge(8424) → panel(8125) → proxy(8096)
#
# 用法：  ./start-all.sh     （配置读同目录 .env，LLM key 留空时服务可启动，
#                            但记忆抽取/wiki ingest/代理转发需填真实 key）
set -euo pipefail

RUN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$RUN_DIR/.." && pwd)/TencentDB-Agent-Memory"
ENV_FILE="$RUN_DIR/.env"

# ── 加载 .env ──
if [[ ! -f "$ENV_FILE" ]]; then
  echo "[error] 缺少 $ENV_FILE" >&2; exit 1
fi
set -a; source "$ENV_FILE"; set +a

MEMORY_CORE_PORT="${MEMORY_CORE_PORT:-8420}"
PANEL_PORT="${PANEL_PORT:-8125}"
KNOWLEDGE_PORT="${KNOWLEDGE_PORT:-8424}"
PROXY_PORT="${PROXY_PORT:-8096}"

# 与官方部署一致：本地体验把 gateway Bearer 关掉（proxy auth 不带 Bearer 的已知兼容问题）
CORE_GATEWAY_API_KEY=""

mkdir -p "$RUN_DIR/config" "$RUN_DIR/logs" "$RUN_DIR/pids" \
         "$RUN_DIR/data/core" "$RUN_DIR/data/knowledge"

winpath() { # E:\foo → E:/foo（node/yaml 用正斜杠最稳）
  echo "$1" | sed 's|\\|/|g'
}
RUN_W="$(winpath "$RUN_DIR")"
REPO_W="$(winpath "$REPO")"

wait_health() { # $1=url $2=名字
  local i
  for i in $(seq 1 90); do
    if curl -fsS --max-time 2 "$1" >/dev/null 2>&1; then
      echo "[ok] $2 就绪 → $1"; return 0
    fi
    # 注意：这里不做 kill -0 存活检查 —— MSYS bash 对 Windows 原生 pid 的
    # kill -0 恒为失败，会误判新启动的进程"已退出"。
    sleep 1
  done
  echo "[error] $2 90s 内未就绪，查看 $RUN_DIR/logs/ 排查" >&2; return 1
}

start_proc() { # $1=名字 $2=命令(在已 cd 好的目录里)  → node detached 后台 + pid 文件
  local name="$1"; shift
  # 用 proc.mjs 以 detached 模式拉起：Windows 上 bash nohup 无法让子进程脱离
  # MSYS 控制台，工具会话/shell 退出时服务会被连带杀掉；detached 则完全解耦。
  node "$RUN_DIR/proc.mjs" start "$name" "$RUN_DIR/pids/$name.pid" \
    "$RUN_DIR/logs/$name.log" "$PWD" -- "$@"
  echo "[info] $name 已启动 (log=logs/$name.log)"
}

# ══ 1. 生成 memory-core 配置 ════════════════════════════════
cat > "$RUN_DIR/config/tdai-gateway.yaml" <<YAML
deployMode: standalone
stateBackend: local

server:
  port: ${MEMORY_CORE_PORT}
  host: 127.0.0.1

data:
  baseDir: ${RUN_W}/data/core

llm:
  baseUrl: "${MEMORY_LLM_BASE_URL:-}"
  apiKey: "${MEMORY_LLM_API_KEY:-}"
  model: "${MEMORY_LLM_MODEL:-}"
  maxTokens: 32000
  timeoutMs: 300000

memory:
  promptMode: ${MEMORY_PROMPT_MODE:-code}
  capture: { enabled: true }
  extraction:
    enabled: true
    enableDedup: true
    maxMemoriesPerSession: 20
  persona:
    triggerEveryN: 50
    maxScenes: 15
  pipeline:
    everyNConversations: 5
    enableWarmup: true
    l1IdleTimeoutSeconds: 600
    l2DelayAfterL1Seconds: 90
    l2MinIntervalSeconds: 900
    l2MaxIntervalSeconds: 3600
  recall:
    enabled: true
    maxResults: 5
    scoreThreshold: 0.3
    strategy: hybrid
    timeoutMs: 5000
  storeBackend: sqlite
  embedding:
    provider: none

skill:
  enabled: true
  routing:
    mode: bm25
    searchTopK: 20
  extraction:
    enabled: true
    maxIterations: 16
    queue:
      backend: local
      keyPrefix: tdai
      resultTtlSeconds: 86400
      lockTtlMs: 600000
      maxRetries: 2
      retryBackoffsMs: [5000, 15000]
  resources:
    maxResourceSizeBytes: 5000000
YAML

# ══ 2. 生成 proxy 配置（完整流水线：auth + sessionInit + tdai 注入）══
cat > "$RUN_DIR/config/proxy-config.yaml" <<YAML
server:
  host: 127.0.0.1
  port: ${PROXY_PORT}
  forwardTimeoutMs: 600000

upstream:
  url: "${PROXY_UPSTREAM_URL:-}"
  apiKey: "${PROXY_UPSTREAM_API_KEY:-}"

log:
  file: ""
  level: info
  backend: console

tdai:
  enabled: true
  endpoint: "http://127.0.0.1:${MEMORY_CORE_PORT}"
  apiKey: "${CORE_GATEWAY_API_KEY}"
  serviceId: default
  memory:
    enabled: true
    inject: true
    writeL0: true
    recallL1: true
    injectL2L3: true

skill:
  endpoint: "http://127.0.0.1:${MEMORY_CORE_PORT}"
  serviceToken: "${CORE_GATEWAY_API_KEY}"

knowledge:
  enabled: true
  endpoint: "http://127.0.0.1:${MEMORY_CORE_PORT}"
  serviceToken: "${CORE_GATEWAY_API_KEY}"
  serviceId: default

auth:
  enabled: true
  url: "http://127.0.0.1:${MEMORY_CORE_PORT}"
  timeoutMs: 5000

sessionInit:
  enabled: true
  maxRetries: 3
  injectAgentContext: true
  injectTaskContext: true
  headerAutoSelect:
    enabled: true
    teamHeader: "x-team-id"
    agentHeader: "x-agent-id"
    taskHeader: "x-task-id"
    onMismatch: "form"

costGuard:
  enabled: false

injection:
  enabled: true
  injectors:
    - skill
    - knowledge
    - tdai-memory

redis:
  enabled: false
YAML

# ══ 3. 生成 Panel 多实例配置 ════════════════════════════════
cat > "$RUN_DIR/config/metadata-instances.json" <<JSON
{
  "instances": [
    {
      "id": "default",
      "name": "default",
      "gateway_endpoint": "http://127.0.0.1:${MEMORY_CORE_PORT}",
      "proxy_endpoint": "http://127.0.0.1:${PROXY_PORT}",
      "api_key": "local"
    }
  ]
}
JSON

# 端口预清理：残留监听（如上次异常退出）会导致新进程 EADDRINUSE，
# 而 wait_health 会误命中旧监听。启动前先杀掉占用目标端口的进程。
echo "[info] 端口预清理: $MEMORY_CORE_PORT $KNOWLEDGE_PORT $PANEL_PORT $PROXY_PORT"
powershell -NoProfile -Command "
foreach (\$port in $MEMORY_CORE_PORT,$KNOWLEDGE_PORT,$PANEL_PORT,$PROXY_PORT) {
  \$c = Get-NetTCPConnection -LocalPort \$port -State Listen -ErrorAction SilentlyContinue
  if (\$c) {
    foreach (\$procId in (\$c.OwningProcess | Sort-Object -Unique)) {
      try { Stop-Process -Id \$procId -Force -ErrorAction Stop; Write-Output \"[warn] 端口 \$port 被残留进程 \$procId 占用，已终止\" }
      catch { Write-Output \"[warn] 端口 \$port 进程 \$procId 终止失败: \$(\$_.Exception.Message)\" }
    }
  }
}
" || true
sleep 1

# ══ Step 1/4: memory-core ═══════════════════════════════════
echo "═══ Step 1/4: memory-core ═══════════════════════════════"
cd "$REPO/MemoryCore"
TDAI_GATEWAY_CONFIG="$RUN_W/config/tdai-gateway.yaml" \
TDAI_GATEWAY_HOST=127.0.0.1 \
TDAI_GATEWAY_PORT="$MEMORY_CORE_PORT" \
TDAI_DATA_DIR="$RUN_W/data/core" \
TDAI_GATEWAY_API_KEY="$CORE_GATEWAY_API_KEY" \
STORE_MODE=sqlite \
NODE_ENV=production \
  start_proc core node --import tsx src/gateway/server.ts
wait_health "http://127.0.0.1:${MEMORY_CORE_PORT}/health" "memory-core"

# ── init-admin：首次生成 admin user_key 并落盘 ──
ADMIN_KEY_FILE="$RUN_DIR/.admin-key"
gen_key() {
  local raw
  raw=$(openssl rand -base64 48 2>/dev/null | LC_ALL=C tr -dc 'A-Za-z0-9' | head -c 32) || true
  if [[ -z "$raw" ]]; then
    raw=$(head -c 256 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | head -c 32)
  fi
  echo "sk-mem-${raw}"
}
if [[ -s "$ADMIN_KEY_FILE" ]]; then
  ADMIN_KEY=$(cat "$ADMIN_KEY_FILE")
else
  ADMIN_KEY=$(gen_key)
fi
init_code=$(curl -sS -o /tmp/init-admin.$$ -w "%{http_code}" --max-time 10 \
  -X POST -H "Content-Type: application/json" -H "x-tdai-service-id: default" \
  "http://127.0.0.1:${MEMORY_CORE_PORT}/v3/internal/meta/user/init-admin" \
  -d "{\"username\":\"admin\",\"user_key\":\"$ADMIN_KEY\"}" 2>/dev/null || echo 000)
case "$init_code" in
  200) echo "$ADMIN_KEY" > "$ADMIN_KEY_FILE"; echo "[ok] admin user 已创建 (key → $ADMIN_KEY_FILE)";;
  409) [[ -s "$ADMIN_KEY_FILE" ]] && echo "[ok] admin 已存在，复用 $ADMIN_KEY_FILE";;
  *)   echo "[warn] init-admin HTTP=$init_code：$(cat /tmp/init-admin.$$ 2>/dev/null)";;
esac
rm -f /tmp/init-admin.$$

# ══ Step 2/4: knowledge ═════════════════════════════════════
echo "═══ Step 2/4: knowledge ═════════════════════════════════"
cd "$REPO/MemoryKnowledge"
PORT="$KNOWLEDGE_PORT" \
API_PREFIX=/v3 \
KNOWLEDGE_PUBLIC_BASE_URL="http://127.0.0.1:${KNOWLEDGE_PORT}/v3" \
TMC_CALLBACK_URL="http://127.0.0.1:${PANEL_PORT}" \
KNOWLEDGE_DATA_DIR="$RUN_W/data/knowledge" \
KNOWLEDGE_DB_PATH="$RUN_W/data/knowledge/knowledge.db" \
TDAI_AGENT_TEMPLATE_DIR="$RUN_W/data/knowledge/agent-templates" \
LLM_MODE=custom \
LLM_PROVIDER=custom \
LLM_PROTOCOL="${MEMORY_LLM_PROTOCOL:-openai}" \
LLM_API_KEY="${MEMORY_LLM_API_KEY:-}" \
LLM_BASE_URL="${MEMORY_LLM_BASE_URL:-}" \
LLM_MODEL="${MEMORY_LLM_MODEL:-Memory-Model}" \
LLM_MAX_TOKENS=32768 \
LLM_TIMEOUT_MS=1200000 \
LOG_LEVEL=info \
NODE_ENV=production \
  start_proc knowledge node dist/server.mjs
wait_health "http://127.0.0.1:${KNOWLEDGE_PORT}/health" "knowledge"

# ══ Step 3/4: panel ═════════════════════════════════════════
echo "═══ Step 3/4: panel ═════════════════════════════════════"
cd "$REPO/MemoryPanel"
HOST=127.0.0.1 \
PORT="$PANEL_PORT" \
UI_DIST_DIR="$REPO_W/MemoryPanel/web/dist" \
METADATA_INSTANCES_CONFIG="$RUN_W/config/metadata-instances.json" \
METADATA_REMOTE_TIMEOUT_MS=15000 \
KNOWLEDGE_SERVICE_URL="http://127.0.0.1:${KNOWLEDGE_PORT}" \
KNOWLEDGE_TIMEOUT_MS=15000 \
KNOWLEDGE_LLM_BINDING_SYNC=0 \
LOG_LEVEL=info \
LOG_FORMAT=json \
NODE_ENV=production \
  start_proc panel node dist/index.js
wait_health "http://127.0.0.1:${PANEL_PORT}/health" "panel"

# ══ Step 4/4: proxy ═════════════════════════════════════════
echo "═══ Step 4/4: proxy ═════════════════════════════════════"
cd "$REPO/MemoryProxy"
NODE_ENV=production \
  start_proc proxy node --import tsx/esm src/index.ts --config "$RUN_W/config/proxy-config.yaml"
wait_health "http://127.0.0.1:${PROXY_PORT}/health" "proxy"

echo
echo "════════════════ 全部服务已就绪 ═════════════════"
echo "  Panel UI        → http://localhost:${PANEL_PORT}/"
echo "  Knowledge API   → http://localhost:${KNOWLEDGE_PORT}/v3/  (Swagger: /docs)"
echo "  Memory Gateway  → http://localhost:${MEMORY_CORE_PORT}/"
echo "  Proxy           → http://localhost:${PROXY_PORT}/"
if [[ -s "$ADMIN_KEY_FILE" ]]; then
  echo
  echo "  Panel 登录用 admin user_key（已保存）: $(cat "$ADMIN_KEY_FILE")"
fi
echo
echo "  日志: $RUN_DIR/logs/*.log    停止: $RUN_DIR/stop-all.sh"
