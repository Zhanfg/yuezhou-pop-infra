# 在 1Panel 中使用

本仓库使用服务器已有的 Docker Engine 和 Docker Compose，不接管 1Panel 本身，也不会修改 1Panel 的数据库。

## 1. 克隆与安装

在 1Panel 的“终端”中执行：

```bash
cd /opt
git clone https://github.com/Zhanfg/yuezhou-pop-infra.git
cd yuezhou-pop-infra
sudo bash stack.sh install
```

启用 Adminer 和 Valkey：

```bash
sudo bash stack.sh install tools,cache
```

## 2. 检查运行状态

```bash
sudo bash stack.sh status
sudo bash stack.sh doctor
```

数据库密码保存在仓库目录下的 `.env`。不要截图、复制到公开聊天或提交到 Git。

## 3. 接入业务应用

推荐让业务应用加入 `.env` 中配置的共享 Docker 网络，而不是把 PostgreSQL 端口开放到公网。

业务 Compose 文件需要包含：

```yaml
networks:
  data_net:
    external: true
    name: onepanel-data-net
```

对应服务中加入：

```yaml
services:
  app:
    networks:
      - data_net
```

数据库主机名使用 `postgres`，端口使用 `5432`。

## 4. Adminer

Adminer 默认绑定：

```text
127.0.0.1:8080
```

推荐通过 SSH 隧道临时访问：

```bash
ssh -L 8080:127.0.0.1:8080 root@YOUR_VPS_IP
```

然后在本地浏览器打开 `http://127.0.0.1:8080`。

不要直接把 Adminer 暴露到公网。确实需要通过域名访问时，应在 1Panel 中配置 HTTPS、访问认证和 IP 白名单。

## 5. 备份

手动备份：

```bash
sudo bash stack.sh backup
```

默认备份目录：

```text
/opt/onepanel-data-stack/backups
```

建议在 1Panel 的“计划任务”中定时执行：

```bash
cd /opt/yuezhou-pop-infra && sudo bash stack.sh backup
```

备份不能只保存在同一台 VPS。应再同步到另一个受控位置。

## 6. 更新

```bash
cd /opt/yuezhou-pop-infra
git pull --ff-only
sudo bash stack.sh update
```

`update` 会先创建数据库备份，再拉取镜像并重建容器。
