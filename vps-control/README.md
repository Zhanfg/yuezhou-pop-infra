# 通用 VPS 控制平面

这一目录为 Ubuntu / Debian VPS 提供可审计的 SSH 引导、自托管 GitHub Actions Runner 安装和基础诊断工具。它与具体项目解耦，可以服务多个仓库。

## 安全模型

- 仓库只能保存脚本、模板和公钥；不得保存私钥、密码、Cloudflare Token、GitHub Token 或真实 `.env`。
- SSH 使用独立非 root 账户，默认没有 sudo 权限。
- SSH Match 规则关闭密码登录、端口转发、Agent 转发、X11 和隧道。
- GitHub Runner 注册 Token 必须写入 VPS 上 mode `400` 或 `600` 的临时文件；安装成功后默认销毁。
- Cloudflare 生产凭据应保存在 GitHub `production` Environment secrets 中，不写入 VPS 控制仓库。
- 自托管 Runner 会执行仓库代码。验证和生产部署必须使用不同 Linux 用户、不同安装目录和不同 Runner 标签。
- Runner 用户不得加入 `sudo`、`admin`、`wheel`、`docker`、`lxd` 或 `libvirt` 等高权限组。

## 1. 引导临时 SSH 访问

在 VPS 上克隆或更新本仓库，然后由现有管理员执行：

```bash
cd yuezhou-pop-infra
sudo bash vps-control/bootstrap-ssh-access.sh
sudo bash vps-control/doctor.sh
```

默认创建：

```text
用户：ci-bootstrap
公钥：vps-control/keys/chatgpt-vps-ci-2026-08-03.pub
权限：无 sudo
```

自定义账户或公钥：

```bash
sudo bash vps-control/bootstrap-ssh-access.sh \
  --user automation-control \
  --key-file /root/approved-control-key.pub
```

### 撤销访问

只撤销本次临时公钥：

```bash
sudo bash vps-control/revoke-ssh-access.sh \
  --user ci-bootstrap \
  --key-comment chatgpt-vps-ci-2026-08-03
```

撤销并锁定账户：

```bash
sudo bash vps-control/revoke-ssh-access.sh \
  --user ci-bootstrap \
  --key-comment chatgpt-vps-ci-2026-08-03 \
  --lock-account
```

完全删除账户和家目录属于破坏性操作：

```bash
sudo bash vps-control/revoke-ssh-access.sh \
  --user ci-bootstrap \
  --key-comment chatgpt-vps-ci-2026-08-03 \
  --purge-user
```

## 2. 安装 GitHub 自托管 Runner

在目标仓库或组织的 GitHub 页面生成一次性 Runner 注册 Token：

```text
Settings → Actions → Runners → New self-hosted runner
```

不要把 Token 写入命令历史。先在 VPS 本地创建临时文件：

```bash
sudo install -m 600 /dev/null /root/github-runner-registration-token
sudo nano /root/github-runner-registration-token
```

单个 Runner 的通用安装方式：

```bash
sudo bash vps-control/install-github-runner.sh \
  --url https://github.com/OWNER/REPOSITORY \
  --token-file /root/github-runner-registration-token \
  --user github-runner \
  --dir /srv/github-runner \
  --name primary-vps-01 \
  --labels project-ci
```

安装器会：

1. 创建或复用低权限服务账户；
2. 拒绝默认使用属于 `sudo/docker/lxd` 等高权限组的账户；
3. 从 GitHub 官方 Release API 获取当前 Runner；
4. 校验 Release API 提供的 SHA-256 摘要；
5. 注册 Runner；
6. 用 Runner 自带的 `svc.sh` 安装独立 systemd 服务；
7. 默认销毁一次性 Token 文件；
8. 避免 `needrestart` 擅自重启正在执行任务的 Runner。

检查：

```bash
sudo bash vps-control/doctor.sh
systemctl list-units 'actions.runner.*'
```

## 3. 为网站安装隔离的双 Runner

不要让 PR 验证任务与生产部署任务共用同一个 Runner 用户。推荐结构：

```text
/srv/github-runner-ci       用户 github-ci      标签 axymorrsen-ci
/srv/github-runner-deploy   用户 github-deploy  标签 axymorrsen-deploy
```

### 3.1 验证 Runner

生成第一个一次性注册 Token，写入：

```bash
sudo install -m 600 /dev/null /root/axymorrsen-ci-token
sudo nano /root/axymorrsen-ci-token
```

安装：

```bash
sudo bash vps-control/install-github-runner.sh \
  --url https://github.com/ZhanfgBuild/axymorrsen-site \
  --token-file /root/axymorrsen-ci-token \
  --user github-ci \
  --dir /srv/github-runner-ci \
  --name axymorrsen-ci-01 \
  --labels axymorrsen-ci
```

该账户只用于 `npm ci`、Astro 构建和浏览器 QA，不配置 Cloudflare 或内容仓生产凭据。

### 3.2 部署 Runner

回到 GitHub Runner 页面，重新生成第二个一次性注册 Token：

```bash
sudo install -m 600 /dev/null /root/axymorrsen-deploy-token
sudo nano /root/axymorrsen-deploy-token
```

安装：

```bash
sudo bash vps-control/install-github-runner.sh \
  --url https://github.com/ZhanfgBuild/axymorrsen-site \
  --token-file /root/axymorrsen-deploy-token \
  --user github-deploy \
  --dir /srv/github-runner-deploy \
  --name axymorrsen-deploy-01 \
  --labels axymorrsen-deploy
```

部署 Runner 只匹配 `push main` 的生产 Job。Cloudflare 与内容仓 Token 仍由 GitHub `production` Environment 在 Job 启动时注入，不保存到 Runner 目录。

### 3.3 浏览器系统依赖

Playwright 浏览器本体由 CI 用户安装到自己的缓存。Chromium 所需系统库应由管理员在正式启用 CI 前一次性安装。可以先在主站工作副本中执行：

```bash
cd /path/to/axymorrsen-site
npm ci
sudo npx playwright install-deps chromium
```

执行后不要把 root 创建的 `node_modules` 作为 Runner 工作目录；该命令只用于安装系统库。Runner Job 会重新执行 `npm ci` 并以低权限用户安装 Chromium 浏览器文件。

## 4. 网站编译与 Cloudflare 部署

示例工作流见：

```text
examples/axymorrsen-site-self-hosted.yml
```

边界：

- PR：只在 `axymorrsen-ci` Runner 上安装依赖、构建和执行 QA，不注入生产凭据；
- `main`：验证通过后，生产 Job 只在 `axymorrsen-deploy` Runner 上执行；
- `production` Environment：启用 Required reviewers；
- Secrets：`CLOUDFLARE_API_TOKEN`、`CLOUDFLARE_ACCOUNT_ID`、`CONTENT_REPO_TOKEN`；
- Wrangler：固定在当前受支持的 v4 主版本，先 dry-run，再部署。

Wrangler 在非交互式 CI 中使用：

```text
CLOUDFLARE_API_TOKEN
CLOUDFLARE_ACCOUNT_ID
```

## 5. 2 GB VPS 建议

Astro、npm 解包和浏览器 QA 可能同时占用较多内存。建议至少配置 4 GB Swap：

```bash
sudo fallocate -l 4G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

重复执行前先通过 `swapon --show` 检查，避免重复写入 `/etc/fstab`。

## 6. 操作审计

建议每次操作都保留：

- GitHub PR 或 Commit SHA；
- Actions Run ID 和 Job 日志；
- Cloudflare Deployment Version ID；
- VPS 上 `journalctl -u 'actions.runner.*'` 的时间范围；
- SSH 公钥启用与撤销时间。

不要把日志中的 Token、Cookie、授权头或 `.env` 内容提交到 Issue、PR 或 Artifact。
