#!/usr/bin/env bash
# 一次性安装依赖 + 构建四个组件（在纯 Ubuntu 容器/裸机上运行）。
# 产物：MemoryCore 可直跑（tsx）、MemoryKnowledge/dist、MemoryPanel/dist、
#       MemoryPanel/web/dist（前端静态资源）、MemoryProxy 可直跑。
set -euo pipefail

RUN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${REPO_DIR:-$(cd "$RUN_DIR/../.." && pwd)}"

echo "═══ [1/4] 环境检查 ═══════════════════════════════════════"
command -v node >/dev/null 2>&1 || { echo "[error] 未安装 node（需 ≥22）"; exit 1; }
NODE_MAJOR=$(node -p "process.versions.node.split('.')[0]")
[[ "$NODE_MAJOR" -ge 22 ]] || { echo "[error] node 版本需 ≥22，当前 $(node -v)"; exit 1; }
command -v git    >/dev/null 2>&1 || { echo "[error] 未安装 git（wiki/codegraph 需要）"; exit 1; }
command -v curl   >/dev/null 2>&1 || { echo "[error] 未安装 curl"; exit 1; }
echo "[ok] node $(node -v) / npm $(npm -v) / git $(git --version | awk '{print $3}')"

# 分支防呆：跨平台修复（better-sqlite3 ≥12 等）在 windows-local-deploy 分支。
# 上游 main + Node 22 在 Linux 也能跑；但 Node ≥24 时 v11 无预编译，需要
# build-essential/python3/make/g++ 现场编译，否则安装失败。
KS_BS3=$(node -p "require('$REPO_DIR/MemoryKnowledge/package.json').dependencies['better-sqlite3']")
KS_BS3_MAJOR=$(printf '%s' "$KS_BS3" | grep -oP '\d+' | head -n1)
if [[ "${KS_BS3_MAJOR:-0}" -ge 12 ]]; then
  echo "[ok] better-sqlite3=$KS_BS3（含 linux 预编译，免编译工具链）"
else
  if [[ "$NODE_MAJOR" -ge 24 ]]; then
    echo "[error] 当前是 Node ${NODE_MAJOR}，但 better-sqlite3=$KS_BS3 无对应预编译。" >&2
    echo "        请改用修复分支克隆：" >&2
    echo "        git clone -b windows-local-deploy https://github.com/cstarc/TencentDB-Agent-Memory.git" >&2
    exit 1
  fi
  echo "[warn] better-sqlite3=$KS_BS3 在 Node 22 上可用预编译，但建议改用修复分支" >&2
fi

echo "═══ [2/4] MemoryCore（记忆内核，依赖 + 补丁已在分支里） ══"
cd "$REPO_DIR/MemoryCore"
npm install --omit=dev --ignore-scripts --legacy-peer-deps --no-audit --no-fund

echo "═══ [3/4] MemoryKnowledge + MemoryPanel（需构建） ═════════"
cd "$REPO_DIR/MemoryKnowledge"
npm install --no-audit --no-fund
npm run build

cd "$REPO_DIR/MemoryPanel"
npm install --no-audit --no-fund
npm run build
cd web
npm install --no-audit --no-fund
npm run build

echo "═══ [4/4] MemoryProxy（tsx 直跑源码，保留 dev 依赖） ══════"
cd "$REPO_DIR/MemoryProxy"
npm install --no-audit --no-fund

echo
echo "[done] 全部依赖安装与构建完成"
echo "下一步："
echo "  cp .env.example .env   # 填好两组 LLM key"
echo "  ./start-all.sh"
