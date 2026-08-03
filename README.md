# OnePanel Data Stack

A reusable, project-agnostic data-service stack for a VPS running 1Panel or plain Docker Compose.

一个可公开复用、与具体项目无关的数据服务部署模板。适合已经安装 1Panel 的 Ubuntu / Debian VPS，也可以直接在普通 Docker 主机上运行。

## 提供的服务

- PostgreSQL：默认启用，数据使用 Docker 命名卷持久化。
- Adminer：可选，仅绑定到 `127.0.0.1`，用于数据库管理。
- Valkey：可选的开源缓存服务，仅绑定到 `127.0.0.1`。
- 自动生成本地密码，不向终端打印密码。
- 数据库备份、恢复、更新、状态检查和日志查看。
- 默认不把数据库端口暴露到公网。
- 可供其他 Docker Compose 项目通过共享网络连接。
- 通用 VPS 控制平面：受限 SSH、公钥撤销、自托管 Runner 安装和网络/资源诊断。

## 安全边界

这个公开仓库只保存脚本和模板：

- 不保存真实域名、IP、密码、Token、Cookie、私钥或数据库凭据。
- 允许保存明确标记、可随时撤销的 SSH 公钥；私钥不得进入仓库。
- `.env` 会在服务器本地生成，并已被 Git 忽略。
- PostgreSQL、Adminer 和 Valkey 默认只监听 `127.0.0.1`。
- 项目专用配置应保存在项目自己的私有配置或服务器环境变量中。

## 快速开始

```bash
git clone https://github.com/Zhanfg/yuezhou-pop-infra.git
cd yuezhou-pop-infra
sudo bash stack.sh install
```

默认只启动 PostgreSQL。启用数据库管理工具和缓存：

```bash
sudo bash stack.sh install tools,cache
```

安装完成后，凭据位于服务器本地：

```text
<仓库目录>/.env
```

不要把 `.env` 上传到 GitHub，也不要把其中内容粘贴到公开日志或 Issue。

## 常用命令

```bash
sudo bash stack.sh status
sudo bash stack.sh logs postgres
sudo bash stack.sh backup
sudo bash stack.sh update
sudo bash stack.sh doctor
sudo bash stack.sh down
sudo bash stack.sh up tools,cache
```

恢复备份属于破坏性操作，必须显式确认：

```bash
sudo bash stack.sh restore /path/to/backup.dump --yes
```

## VPS 控制与编译 CI

控制入口位于 [`vps-control/`](vps-control/README.md)，包括：

- 创建无 sudo 的专用 SSH 控制账户；
- 安装和撤销指定 SSH 公钥；
- 安装带 Release 摘要校验的 GitHub self-hosted runner；
- 检查 SSH、Runner、磁盘、内存和 GitHub/npm/Cloudflare 网络连通性；
- `axymorrsen-site` 的 VPS 编译、浏览器 QA 与 Cloudflare 部署工作流模板。

首次启用临时控制公钥：

```bash
sudo bash vps-control/bootstrap-ssh-access.sh
sudo bash vps-control/doctor.sh
```

安装 Runner 的具体流程以及撤销方式见 [`vps-control/README.md`](vps-control/README.md)。仓库中的任何脚本都不会要求把私钥或长期 Token 提交到 GitHub。

## 让其他容器连接数据库

本仓库创建的共享 Docker 网络名称由 `.env` 中的 `DOCKER_NETWORK_NAME` 决定，默认是：

```text
onepanel-data-net
```

业务容器加入该外部网络后，可以使用下面的连接信息：

```text
Host: postgres
Port: 5432
Database: .env 中的 POSTGRES_DB
Username: .env 中的 POSTGRES_USER
Password: .env 中的 POSTGRES_PASSWORD
```

参考文件：[`examples/app-compose.fragment.yml`](examples/app-compose.fragment.yml)。

## 1Panel 使用方式

1. 在 1Panel 的“终端”中克隆仓库并执行安装命令。
2. 不要在 1Panel 中再次创建同名 PostgreSQL 容器。
3. 业务应用通过共享 Docker 网络访问 PostgreSQL。
4. Adminer 默认只在本机开放。需要临时访问时，优先使用 SSH 隧道；不要直接把 Adminer 暴露到公网。

详细说明见 [`docs/1panel.md`](docs/1panel.md)。

## 支持的系统

- Ubuntu 22.04 / 24.04 或相近版本
- Debian 12 或相近版本
- Docker Engine
- Docker Compose v2（`docker compose`）

脚本不会擅自替换 1Panel 已安装的 Docker。检测不到 Docker 或 Compose 时会停止并提示，而不是修改现有面板环境。

## License

MIT
