# TencentDB-Agent-Memory 纯 Ubuntu 容器/裸机源码部署（无 Docker）

本目录是仓库内置的 Linux 源码直跑部署套件（`deploy/linux-native`），面向**容器内没有
Docker** 的纯 Ubuntu 环境。等价于 Windows 套件 `deploy/windows-local`，区别：

- 服务监听 `BIND_HOST`（默认 `0.0.0.0`），容器外可经端口映射访问
- 对外地址用 `PUBLIC_HOST` 拼接（默认自动取容器 IP；NAT 映射场景需显式指定宿主机地址）
- 进程管理用 Linux 原生 `nohup`/`kill`，端口清理用 `fuser`/`ss`（无任何 powershell）

## 前置要求（容器内）

- Ubuntu 20.04+（glibc 发行版均可）
- Node.js ≥ 22（容器内通常已是 root，无需 sudo）：
  ```bash
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && apt-get install -y nodejs
  ```
- git、curl（wiki/codegraph 要 clone 仓库；健康检查用）
- 无需 Docker、无需 build-essential：better-sqlite3（≥12）自带 linux 预编译二进制

## 部署步骤

```bash
# 1. 克隆（用 windows-local-deploy 分支：含全部跨平台修复）
git clone -b windows-local-deploy https://github.com/cstarc/TencentDB-Agent-Memory.git
cd TencentDB-Agent-Memory/deploy/linux-native

# 2. 安装依赖 + 构建（一次性，约 3-5 分钟）
./setup.sh

# 3. 填配置
cp .env.example .env
vi .env    # MEMORY_LLM_API_KEY 和 PROXY_UPSTREAM_API_KEY 必填

# 4. 启动
./start-all.sh
```

启动完成后（约 30–45 秒）：

- Panel UI：`http://<PUBLIC_HOST>:8125/`
- Knowledge Swagger：`http://<PUBLIC_HOST>:8424/docs`
- Proxy（coding agent 接入）：`http://<PUBLIC_HOST>:8096/<agent>/<spaceId>`
  （如 Claude Code：`ANTHROPIC_BASE_URL=http://<host>:8096/claude-code/default`）
- admin user_key 保存在 `.admin-key`（Panel 登录 / API 鉴权用）

停止：`./stop-all.sh`（数据保留在 `data/`，重启不丢）。

## 容器端口映射说明

服务在容器内监听 `0.0.0.0`。两种暴露方式：

1. **直接用容器 IP**：什么都不用改，`PUBLIC_HOST` 自动取容器 IP。
2. **NAT 端口映射**（如 `docker run -p 8420:8420 ...` 或 k8s Service）：
   在 `.env` 里显式设置 `PUBLIC_HOST=<宿主机IP或域名>`，否则面板上展示的
   接入地址会是容器内 IP（外部不可达）。

## 与 Windows 套件的差异

| 项 | windows-local | linux-native |
|---|---|---|
| 监听地址 | 127.0.0.1 | 0.0.0.0（可改 BIND_HOST） |
| 对外地址 | 固定 127.0.0.1 | PUBLIC_HOST 自动探测/显式指定 |
| 进程管理 | proc.mjs（detached spawn） | nohup + kill（pid 文件） |
| 端口清理 | kill-ports.mjs（netstat/taskkill） | fuser / ss |
| 图形控制台 | 网页控制台 :8127 | 无（用 Panel 网页即可） |

核心行为（配置生成、init-admin、健康检查、服务间接线）与 Windows 套件完全一致，
`.env` 变量名两边通用。

## 注意

- 容器通常没有 systemd，本套件不依赖任何 init 系统；进程崩溃不会自动拉起，
  需要的话可自行加 `restart: always` 类的监督（或后续加 watch 脚本）。
- 数据目录：`data/core`（memory-core SQLite）与 `data/knowledge`（知识库）。
  容器重建想保留数据，把这两个目录做成挂载卷。
- 公网/跨团队暴露前：替换 `.admin-key`、设置 `TDAI_GATEWAY_API_KEY`（当前本地
  体验按官方默认关闭网关 Bearer，仅 v2/v3 数据面要求任意非空 Bearer 值）。
