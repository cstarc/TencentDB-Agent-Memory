# TencentDB-Agent-Memory 本机源码部署（Windows / 无 Docker）

> 本目录是仓库内置的 Windows 无 Docker 部署套件（deploy/windows-local）。把整个目录复制到任意工作目录（本文以 E:/tam/run 为例）使用；
> 运行时生成的 .env、config/、data/、logs/ 均不入库，真实 API key 不要提交进 git。
参考 https://github.com/TencentCloud/TencentDB-Agent-Memory 搭建，在 Windows 上**不经 Docker、直接用 Node 从源码运行**全套服务。

## 服务与端口

| 服务 | 端口 | 说明 | 源码目录 |
|---|---|---|---|
| memory-core | 8420 | 记忆内核 gateway（L0-L3 数据面、skill、鉴权） | `TencentDB-Agent-Memory/MemoryCore` |
| knowledge | 8424 | 知识服务（LLM-Wiki / Code-Graph） | `TencentDB-Agent-Memory/MemoryKnowledge` |
| panel | 8125 | 管理面板 UI + 元数据代理 | `TencentDB-Agent-Memory/MemoryPanel`（web 子目录是 React 前端） |
| proxy | 8096 | coding agent 的 LLM 请求转发代理（记忆注入） | `TencentDB-Agent-Memory/MemoryProxy` |

## 常用命令（Git Bash）

```bash
cd /e/tam/run
./start-all.sh   # 启动全部四个服务（含端口预清理、init-admin）
./stop-all.sh    # 按端口停止全部服务
```

- 配置：编辑 `.env` 后重新 `./start-all.sh`
- 日志：`logs/{core,knowledge,panel,proxy}.log`
- admin user_key：`.admin-key`（Panel 登录 / API 鉴权用）

## 首次使用必填

`.env` 里的 LLM 配置**必须填真实 API key**，否则：记忆抽取不出 L1/L2、wiki ingest 失败、
proxy 转发上游返回 401（服务本身能正常启动）。

```ini
MEMORY_LLM_BASE_URL=https://api.deepseek.com/v1   # 任意 OpenAI 兼容端点
MEMORY_LLM_API_KEY=sk-xxxx
MEMORY_LLM_MODEL=deepseek-chat
PROXY_UPSTREAM_URL=https://api.deepseek.com/v1    # 可与 memory 组不同
PROXY_UPSTREAM_API_KEY=sk-xxxx
PROXY_UPSTREAM_MODEL=deepseek-chat
```

## 入口地址

- Panel UI：<http://localhost:8125/>（user_key 登录，key 见 `.admin-key`）
- Knowledge Swagger：<http://localhost:8424/docs>
- Memory Gateway：<http://localhost:8420/>（health: `/health`）
- Proxy 接入（coding agent 的 API base）：
  - Claude Code: `ANTHROPIC_BASE_URL=http://localhost:8096/claude-code/default`
  - OpenAI 协议: `OPENAI_BASE_URL=http://localhost:8096/opencode/default`（或 `/codebuddy/default` 等）
  - 客户端 API key 填 admin user_key

## 相比官方部署做的修改（均在仓库源码里，Windows 兼容）

1. `MemoryKnowledge/package.json`：better-sqlite3 `^11.10.0` → `^12`（v11 无 Node 24/Win 预编译，
   无 VS 构建环境时编译失败；v12 自带 win32-x64 预编译）。
2. `MemoryKnowledge/src/server.ts`、`src/mcp/server.ts`：入口 `import.meta.url ===
   \`file://${argv[1]}\`` 在 Windows 永远为假（三斜杠 vs 两斜杠），进程静默退出；
   改为 `pathToFileURL(argv[1]).href` 规范比较。
3. `MemoryProxy/src/index.ts`：Node 版本硬检查 `v22.` 放宽为 `>=22`（本机 v24 可跑）。
4. `MemoryCore/package.json`：与官方 Dockerfile 相同的补丁（删 openclaw/node-llama-cpp
   peer 依赖 + jimp override），npm 安装用 `--legacy-peer-deps`。
5. `MemoryProxy/package.json`：删除 `node-pty`（源码未引用，Windows 无谓的原生编译）。

## 运行目录结构

```
E:\tam\run\
├── .env                      # 全部配置（LLM key、端口、prompt 模式）
├── .admin-key                # admin user_key（自动生成）
├── start-all.sh / stop-all.sh
├── proc.mjs                  # Node detached 进程助手（Windows 可靠后台化）
├── config\
│   ├── tdai-gateway.yaml     # memory-core 配置（start-all 自动生成）
│   ├── proxy-config.yaml     # proxy 配置（start-all 自动生成）
│   └── metadata-instances.json  # panel → core/proxy 实例接线
├── data\core / data\knowledge   # SQLite 数据（sqlite-vec + FTS5）
├── logs\                     # 各服务日志
└── pids\                     # 进程 pid
```

## 验证过的链路（2026-09-17）

- memory-core `/health`、`/v3/conversation/add|query|search`（写入 + FTS 检索）
- init-admin 建号、`/v3/meta/auth/verify`
- Panel：user_key 登录、`/api/v1/meta/*` 转发 core、`/api/v1/knowledge/*` 转发 KS、前端资源
- Knowledge：`/health`、`/docs`（Swagger）、经 panel 的业务校验响应
- Proxy：auth verify（admin key）→ sessionInit 表单 → 转发上游（mock 上游 200 全链路；
  真实上游需在 `.env` 填 key）

## 注意

- 服务以 Node `detached` 进程常驻（脱离启动它的终端），日志写 `logs/`。
- 重启会保留数据（SQLite 在 `data/`）；`stop-all.sh` 不删数据。
- 生产/公网暴露前：替换 `.admin-key`、给 core 网关设 `TDAI_GATEWAY_API_KEY`（当前本地
  体验按官方脚本默认关闭 Bearer 校验，仅 v2/v3 数据面要求任意非空 Bearer 值）。
