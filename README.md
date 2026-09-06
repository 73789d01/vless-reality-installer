# VLESS TCP Reality 一键安装脚本

这是一个面向**自有 VPS** 的固定流程安装脚本，配置协议为：

`VLESS + TCP + Reality + xtls-rprx-vision`

脚本在目标 VPS 上运行，不需要把 SSH 密码或私钥交给网站，也不包含任意命令执行功能。

## 使用方式

建议先下载、审阅，再执行：

```bash
curl -fL --proto '=https' --tlsv1.2 https://raw.githubusercontent.com/你的用户名/仓库名/main/install.sh -o install.sh
less install.sh
sudo bash install.sh
```

确认脚本内容后，也可以使用一行命令：

```bash
curl -fsSL https://raw.githubusercontent.com/你的用户名/仓库名/main/install.sh | sudo bash
```

脚本启动后进入交互式工具箱：

- 输入 `1`：安装或重新安装
- 输入 `2`：查看运行状态、配置和 VLESS 分享链接
- 输入 `3`：卸载
- 输入 `TZ`：进入修复、修改配置、重新生成密钥和查看日志菜单
- 输入 `0`：退出

默认端口会在 `20000-60000` 范围内随机选择，并自动跳过当前已监听的端口；也可以手动指定端口。Reality 的 `dest` 默认仍为 `www.cloudflare.com:443`，它不是本机监听端口。

也支持命令行模式：

```bash
sudo bash install.sh 1       # 安装
sudo bash install.sh 2       # 查看
sudo bash install.sh TZ      # 修复
sudo bash install.sh 3       # 卸载
```

```bash
sudo env SERVER_ADDRESS=203.0.113.10 SNI=www.cloudflare.com bash install.sh
```

需要固定端口时：

```bash
sudo env SERVER_ADDRESS=203.0.113.10 PORT=23456 SNI=www.cloudflare.com bash install.sh
```

## VPS 要求

- Linux VPS，root 或可用 sudo 的账号
- `curl`、`openssl`、`systemctl`、`mktemp`、`ss`
- 能访问 GitHub 下载 Xray 官方安装器
- 云安全组和系统防火墙放行服务端口（默认随机选择 TCP 高位端口）

请只在你拥有或获授权管理的服务器上运行，并遵守服务商、所在地法律和网络使用政策。

## 安全说明

- `config.json` 含私钥和 UUID，权限为 `0600`，不要公开提交。
- `client.env` 含公钥和服务器地址，权限为 `0600`，不要公开提交。
- 分享链接包含客户端凭据，请当作密码保管。
- 安装器 URL 默认指向 XTLS/Xray-install 官方仓库；如需固定版本，应在审阅后锁定 URL 或提交哈希校验。
- 脚本会自行创建 `/etc/systemd/system/xray.service`，并明确使用 `/usr/local/etc/xray/config.json`，兼容官方安装器未创建 service 文件的发行版。
- 脚本不会自动修改防火墙，也不会删除备份配置。

## 卸载

```bash
curl -fL https://raw.githubusercontent.com/你的用户名/仓库名/main/uninstall.sh | sudo bash
```

卸载脚本会停止 Xray 并删除主配置，但不会自动删除防火墙规则和备份文件。
