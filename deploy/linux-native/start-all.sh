#!/usr/bin/env bash
# TencentDB-Agent-Memory 纯 Ubuntu 容器/裸机源码部署一键启动（无 Docker）。
# 等价于 deploy/global-images/start-all.sh 的"源码直跑"版：
#   memory-core(8420) → knowledge(8424) → panel(8125) → proxy(8096)
#
# 用法：
#   cp .env.example .env    # 填好两组 LLM key
#   ./start-all.sh
#
# 容器注意：服务监听 BIND_HOST（默认 0.0.0.0）；KNOWLEDGE_PUBLIC_BASE_URL 与
# proxy_endpoint 用 PUBLIC_HOST 拼接（默认自动取容器 IP；NAT 映射场景在 .env
# 里显式指定宿主机地址）。
set -euo pipefail

RUN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${REPO_DIR:-$(cd "$RUN_DIR/../.." && pwd)}"
ENV_FILE="$RUN_DIR/.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "[error] 缺少 $ENV_FILE（cp .env.example .env 后填写）" >&2; exit 1
fi
set -a; source "$ENV_FILE"; set +a

MEMORY_CORE_PORT="${MEMORY_CORE_PORT:-8420}"
PANEL_PORT="${PANEL_PORT:-8125}"
KNOWLEDGE_PORT="${KNOWLEDGE_PORT:-8424}"
PROXY_PORT="${PROXY_PORT:-8096}"
BIND_HOST="${BIND_HOST:-0.0.0.0}"

# 对外可达地址：优先 .env 的 PUBLIC_HOST；否则取第一个非回环 IPv4（容器 IP）；
# 都失败回落 127.0.0.1（仅容器内可用）。
if [[ -z "${PUBLIC_HOST:-}" ]]; then
  PUBLIC_HOST=$(hostname -I 2>/dev/null | tr ' ' '\n' \
    | awk '/^[0-9]+\./ && $0 !~ /^127\./ && $0 !~ /^169\.254\./' | head -n1 || true)
  PUBLIC_HOST="${PUBLIC_HOST:-127.0.0.1}"
fi

# 与官方部署一致：本地体验把 gateway Bearer 关掉（proxy auth 不带 Bearer 的已知兼容问题）
CORE_GATEWAY_API_KEY=""

mkdir -p "$RUN_DIR/config" "$RUN_DIR/logs" "$RUN_DIR/pids" \
         "$RUN_DIR/data/core" "$RUN_DIR/data/knowledge"

# ── 端口预清理：残留监听会导致新进程 EADDRINUSE ──
kill_port_listeners() {
  local p pid
  for p in "$@"; do
    if command -v fuser >/dev/null 2>&1; then
      fuser -k "${p}/tcp" >/dev/null 2>&1 || true
    elif command -v ss >/dev/null 2>&1; then
      for pid in $(ss -ltnp 2>/dev/null | awk -v pt=":${p}" '$4 ~ pt"$"' \
          | grep -oP 'pid=\K[0-9]+' | sort -u); do
        kill "$pid" 2>/dev/null || true
      done
    fi
  done
}
echo "[info] 端口预清理: $MEMORY_CORE_PORT $KNOWLEDGE_PORT $PANEL_PORT $PROXY_PORT"
kill_port_listeners "$MEMORY_CORE_PORT" "$KNOWLEDGE_PORT" "$PANEL_PORT" "$PROXY_PORT"
sleep 1

wait_health() { # $1=url $2=名字 $3=pid文件
  local i
  for i in $(seq 1 90); do
    if curl -fsS --max-time 2 "$1" >/dev/null 2>&1; then
      echo "[ok] $2 就绪 → $1"; return 0
    fi
    if [[ -f "$3" ]] && ! kill -0 "$(cat "$3")" 2>/dev/null; then
      echo "[error] $2 进程已退出，查看 $RUN_DIR/logs/ 排查" >&2; return 1
    fi
    sleep 1
  done
  echo "[error] $2 90s 内未就绪" >&2; return 1
}

start_proc() { # $1=名字，其余=命令（在已 cd 好的目录里）
  local name="$1"; shift
  nohup "$@" > "$RUN_DIR/logs/$name.log" 2>&1 &
  echo "$!" > "$RUN_DIR/pids/$name.pid"
  echo "[info] $name 已启动 (pid=$(cat "$RUN_DIR/pids/$name.pid"), log=logs/$name.log)"
}

# ══ 1. 生成 memory-core 配置 ════════════════════════════════
cat > "$RUN_DIR/config/tdai-gateway.yaml" <<YAML
deployMode: standalone
stateBackend: local

server:
  port: ${MEMORY_CORE_PORT}
  host: ${BIND_HOST}

data:
  baseDir: ${RUN_DIR}/data/core

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
# 内部互调走 127.0.0.1（同容器），对外监听 BIND_HOST
cat > "$RUN_DIR/config/proxy-config.yaml" <<YAML
server:
  host: ${BIND_HOST}
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
# gateway_endpoint 用 127.0.0.1（panel → core 同容器内部互调）；
# proxy_endpoint 用 PUBLIC_HOST（Panel UI 上展示给客户端复制的接入地址）。
cat > "$RUN_DIR/config/metadata-instances.json" <<JSON
{
  "instances": [
    {
      "id": "default",
      "name": "default",
      "gateway_endpoint": "http://127.0.0.1:${MEMORY_CORE_PORT}",
      "proxy_endpoint": "http://${PUBLIC_HOST}:${PROXY_PORT}",
      "api_key": "local"
    }
  ]
}
JSON

# ══ Step 1/4: memory-core ═══════════════════════════════════
echo "═══ Step 1/4: memory-core ═══════════════════════════════"
cd "$REPO_DIR/MemoryCore"
TDAI_GATEWAY_CONFIG="$RUN_DIR/config/tdai-gateway.yaml" \
TDAI_GATEWAY_HOST="$BIND_HOST" \
TDAI_GATEWAY_PORT="$MEMORY_CORE_PORT" \
TDAI_DATA_DIR="$RUN_DIR/data/core" \
TDAI_GATEWAY_API_KEY="$CORE_GATEWAY_API_KEY" \
STORE_MODE=sqlite \
NODE_ENV=production \
  start_proc core node --import tsx src/gateway/server.ts
wait_health "http://127.0.0.1:${MEMORY_CORE_PORT}/health" "memory-core" "$RUN_DIR/pids/core.pid"

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
  200) echo "$ADMIN_KEY" > "$ADMIN_KEY_FILE"; chmod 600 "$ADMIN_KEY_FILE"; echo "[ok] admin user 已创建 (key → $ADMIN_KEY_FILE)";;
  409) [[ -s "$ADMIN_KEY_FILE" ]] && echo "[ok] admin 已存在，复用 $ADMIN_KEY_FILE";;
  *)   echo "[warn] init-admin HTTP=$init_code：$(cat /tmp/init-admin.$$ 2>/dev/null)";;
esac
rm -f /tmp/init-admin.$$

# ══ Step 2/4: knowledge ═════════════════════════════════════
echo "═══ Step 2/4: knowledge ═════════════════════════════════"
cd "$REPO_DIR/MemoryKnowledge"
PORT="$KNOWLEDGE_PORT" \
API_PREFIX=/v3 \
KNOWLEDGE_PUBLIC_BASE_URL="http://${PUBLIC_HOST}:${KNOWLEDGE_PORT}/v3" \
TMC_CALLBACK_URL="http://127.0.0.1:${PANEL_PORT}" \
KNOWLEDGE_DATA_DIR="$RUN_DIR/data/knowledge" \
KNOWLEDGE_DB_PATH="$RUN_DIR/data/knowledge/knowledge.db" \
TDAI_AGENT_TEMPLATE_DIR="$RUN_DIR/data/knowledge/agent-templates" \
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
wait_health "http://127.0.0.1:${KNOWLEDGE_PORT}/health" "knowledge" "$RUN_DIR/pids/knowledge.pid"

# ══ Step 3/4: panel ═════════════════════════════════════════
echo "═══ Step 3/4: panel ═════════════════════════════════════"
cd "$REPO_DIR/MemoryPanel"
HOST="$BIND_HOST" \
PORT="$PANEL_PORT" \
UI_DIST_DIR="$REPO_DIR/MemoryPanel/web/dist" \
METADATA_INSTANCES_CONFIG="$RUN_DIR/config/metadata-instances.json" \
METADATA_REMOTE_TIMEOUT_MS=15000 \
KNOWLEDGE_SERVICE_URL="http://127.0.0.1:${KNOWLEDGE_PORT}" \
KNOWLEDGE_TIMEOUT_MS=15000 \
KNOWLEDGE_LLM_BINDING_SYNC=0 \
LOG_LEVEL=info \
LOG_FORMAT=json \
NODE_ENV=production \
  start_proc panel node dist/index.js
wait_health "http://127.0.0.1:${PANEL_PORT}/health" "panel" "$RUN_DIR/pids/panel.pid"

# ══ Step 4/4: proxy ═════════════════════════════════════════
echo "═══ Step 4/4: proxy ═════════════════════════════════════"
cd "$REPO_DIR/MemoryProxy"
NODE_ENV=production \
  start_proc proxy node --import tsx/esm src/index.ts --config "$RUN_DIR/config/proxy-config.yaml"
wait_health "http://127.0.0.1:${PROXY_PORT}/health" "proxy" "$RUN_DIR/pids/proxy.pid"

echo
echo "════════════════ 全部服务已就绪 ═════════════════"
echo "  Panel UI        → http://${PUBLIC_HOST}:${PANEL_PORT}/"
echo "  Knowledge API   → http://${PUBLIC_HOST}:${KNOWLEDGE_PORT}/v3/  (Swagger: /docs)"
echo "  Memory Gateway  → http://${PUBLIC_HOST}:${MEMORY_CORE_PORT}/"
echo "  Proxy           → http://${PUBLIC_HOST}:${PROXY_PORT}/"
if [[ -s "$ADMIN_KEY_FILE" ]]; then
  echo
  echo "  Panel 登录用 admin user_key（已保存）: $(cat "$ADMIN_KEY_FILE")"
fi
echo
echo "  日志: $RUN_DIR/logs/*.log    停止: $RUN_DIR/stop-all.sh"
