# 双 Runner 快速安装

本流程为同一 GitHub 仓库安装两个互相隔离的自托管 Runner：

```text
github-ci      /srv/github-runner-ci      axymorrsen-ci
github-deploy  /srv/github-runner-deploy  axymorrsen-deploy
```

## 1. 生成两个注册 Token

在目标 GitHub 仓库进入：

```text
Settings -> Actions -> Runners -> New self-hosted runner
```

分别生成两个一次性注册 Token。不要复用同一个 Token，也不要把 Token 粘贴到聊天、Issue 或 PR。

## 2. 写入 VPS 临时文件

```bash
sudo install -m 600 /dev/null /root/axymorrsen-ci-token
sudo install -m 600 /dev/null /root/axymorrsen-deploy-token

sudo nano /root/axymorrsen-ci-token
sudo nano /root/axymorrsen-deploy-token
```

每个文件只放对应 Token，不要添加引号、变量名或其他文字。

## 3. 一次安装两个 Runner

```bash
sudo bash vps-control/install-runner-pair.sh \
  --url https://github.com/ZhanfgBuild/axymorrsen-site \
  --ci-token-file /root/axymorrsen-ci-token \
  --deploy-token-file /root/axymorrsen-deploy-token \
  --name-prefix axymorrsen-vps
```

安装成功后，两个 Token 文件会被销毁。

## 4. 验证隔离

```bash
id github-ci
id github-deploy

systemctl list-units 'actions.runner.*'

sudo RUNNER_DIR=/srv/github-runner-ci \
  bash vps-control/doctor.sh

sudo RUNNER_DIR=/srv/github-runner-deploy \
  bash vps-control/doctor.sh
```

必须满足：

- 两个用户不同；
- 两个 Runner 目录不同；
- GitHub 标签不同；
- 用户组中不存在 `sudo`、`docker`、`lxd`、`libvirt`、`wheel` 或 `admin`；
- GitHub 页面中的两个 Runner 均显示 `Idle`。

然后手动运行主站仓库的 `VPS runner probe` 工作流。
