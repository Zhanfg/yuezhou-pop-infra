# 通用 VPS 控制平面

这一目录为 Ubuntu / Debian VPS 提供可审计的 SSH 引导、自托管 GitHub Actions Runner 安装和基础诊断工具。它与具体项目解耦，可以服务多个仓库。

## 安全模型

- 仓库只能保存脚本、模板和公钥；不得保存私钥、密码、Cloudflare Token、GitHub Token 或真实 `.env`。
- SSH 使用独立非 root 账户，默认没有 sudo 权限。
- SSH Match 规则关闭密码登录、端口转发、Agent 转发、X11 和隧道。
- GitHub Runner 注册 Token 必须写入 VPS 上 mode `600` 的临时文件；安装成功后默认销毁。
- Cloudflare 生产凭据应保存在 GitHub `production` Environment secrets 中，不写入 VPS 控制仓库。
- 自托管 Runner 会执行仓库代码。只允许受信任仓库和受信任分支使用对应标签。

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

然后安装：

```bash
sudo bash vps-control/install-github-runner.sh \
  --url https://github.com/OWNER/REPOSITORY \
  --token-file /root/github-runner-registration-token \
  --name primary-vps-01 \
  --labels axymorrsen-vps,build
```

安装器会：

1. 创建 `github-runner` 服务账户；
2. 从 GitHub 官方 Release API 获取当前 Runner；
3. 校验 Release API 提供的 SHA-256 摘要；
4. 注册 Runner；
5. 用 Runner 自带的 `svc.sh` 安装 systemd 服务；
6. 默认销毁一次性 Token 文件；
7. 避免 `needrestart` 擅自重启正在执行任务的 Runner。

检查：

```bash
sudo bash vps-control/doctor.sh
systemctl list-units 'actions.runner.*'
```

## 3. 网站编译与 Cloudflare 部署

示例工作流见：

```text
examples/axymorrsen-site-self-hosted.yml
```

推荐边界：

- PR：在 VPS 上安装依赖、构建和执行 QA，不注入 Cloudflare 或内容仓生产凭据；
- `main`：引用 GitHub `production` Environment，构建通过后才执行 Wrangler；
- `production` Environment：启用 Required reviewers；
- Secrets：`CLOUDFLARE_API_TOKEN`、`CLOUDFLARE_ACCOUNT_ID`、`CONTENT_REPO_TOKEN`。

Wrangler 在非交互式 CI 中使用：

```text
CLOUDFLARE_API_TOKEN
CLOUDFLARE_ACCOUNT_ID
```

## 4. 2 GB VPS 建议

Astro、npm 解包和浏览器 QA 可能同时占用较多内存。建议至少配置 4 GB Swap：

```bash
sudo fallocate -l 4G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

重复执行前先通过 `swapon --show` 检查，避免重复写入 `/etc/fstab`。

## 5. 操作审计

建议每次操作都保留：

- GitHub PR 或 Commit SHA；
- Actions Run ID 和 Job 日志；
- Cloudflare Deployment Version ID；
- VPS 上 `journalctl -u 'actions.runner.*'` 的时间范围；
- SSH 公钥启用与撤销时间。

不要把日志中的 Token、Cookie、授权头或 `.env` 内容提交到 Issue、PR 或 Artifact。
