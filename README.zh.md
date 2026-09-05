# JAS：iOS 应用签名与自动续签

[English / 上游设计说明](README.md) · [详细部署说明](docs/部署说明.md)

在 NAS 或 Linux 服务器上通过 Apple 账号签名、安装 IPA，并在预计到期前自动续签。
需要设备有效的 RPPairing 文件。网页没有内置登录认证，请仅在可信网络使用。

## Docker 启动

需要安装 Docker 和 Docker Compose。镜像支持 Linux AMD64（x86_64）和 ARM64，
使用同一个镜像标签，Compose 自动选择宿主机架构。

```bash
mkdir jas && cd jas
wget https://raw.githubusercontent.com/zeke-chin/jas/master/compose.yml \
     https://raw.githubusercontent.com/zeke-chin/jas/master/jas.toml
mkdir -p data && sudo chown 10001:10001 data && sudo chmod 700 data
docker compose up -d
```

`data` 必须由容器用户 `10001:10001` 可写：绑定挂载不会继承镜像内权限，入口
脚本会检查该目录。`700` 避免宿主机其他用户读取密钥和数据库。以 root 操作时
可去掉 `sudo`。

打开 `http://服务器IP:3010`。需要改监听地址或端口时，编辑 `jas.toml` 的
`server.bind`，然后执行 `docker compose restart jas`。

## 本地启动

需要 Rust、OpenSSL。首次：

```bash
cargo install --locked cargo-leptos
rustup target add wasm32-unknown-unknown
mkdir -p data/local && (umask 077; set -C; openssl rand -hex 32 > data/local/.jas-secret-key)
```

启动时直接用仓库根目录的 `jas.toml`。`JAS_DATA_DIR` 把其中的 `/data/...`
改写到本地目录，避免写到容器路径，也避免和 Docker 的 `./data` 抢权限。
本地运行不会执行入口脚本，需要自行准备密钥。

```bash
JAS_DATA_DIR=data/local \
JAS_SECRET_KEY="$(cat data/local/.jas-secret-key)" \
cargo leptos watch
```

打开 `http://localhost:3010`。已有数据请保留原密钥。

## 注册设备、安装 IPA

### 注册 iPhone / iPad

1. 用支持 RPPairing 导出的工具（例如 iloader）为**这台设备**完成初次配对并导出
   `pairingFile.plist`。初次配对可能需要 USB 和设备上的信任确认；服务器不能绕过它。
2. 确认 NAS 能到达设备 IP；首次测试让设备解锁、亮屏并连接家庭 Wi-Fi。
3. 在网页 **Devices → Register Device by IP** 中填写设备 IP，上传 RPPairing 文件，
   点击 **Register**。看到设备注册成功及设备名称后再继续。

例如设备 IP 是 `192.168.31.150`，NAS 上可先检查 TCP 49152：

```bash
timeout 5 bash -c 'exec 3<>/dev/tcp/192.168.31.150/49152'
echo "退出码：$?"
```

退出码 0 只说明该端口可连接，不证明配对有效。后续还会建立动态端口的隧道，
只放行 49152 并不保证整个安装流程可用。路由器为设备保留 DHCP 地址通常更方便；
VPN 场景需要 NAS 真正能连接设备，单纯让浏览器访问 NAS 网页并不等于反向可达。

### 添加账号并安装

证书满额时可能自动撤销旧证书，影响同账号签名的其他 App；详见[部署说明](docs/部署说明.md#使用前须知)。

1. **Accounts → Add Apple ID** 登录账号，按提示完成双重认证。
2. **Devices → Manage → Install IPA**。
3. `Account` 选择账号，`IPA File` 选择 IPA。
4. 保持勾选 **Store IPA for auto-refresh**，否则后续不能自动续签。
5. 点击 **Install**，等待任务完成，再在设备上验证能打开应用。

IPA 由网页上传，部署者不需要手动复制到数据目录中。先安装没有重要数据的测试应用；
`queued` 仅表示排队，不是安装或续签成功。

## 自动续签

在设备的 **Installed Apps** 页面确认 **Auto-Refresh = ON**。
先点一次 **Refresh** 验证手动续签；**Refresh All** 可批量提交符合条件的应用。

`jas.toml` 的默认策略：

```toml
[scheduler]
interval_hours = 2
refresh_window_days = 3
worker_threads = 1
```

- 每 2 小时检查一次，不是每 2 小时无条件重签。
- 根据最后安装/续签时间加 7 天估算到期时间，进入到期前 3 天的窗口后安排刷新。
- 一次处理一个任务，适合性能较弱的 NAS；无需额外 cron，也无需一直打开网页。
- 需要 JAS 正在运行、账号会话有效、配对有效且设备可达。
- `interval_hours` 必须大于 0，`refresh_window_days` 建议为 1–6，
  `worker_threads` 至少为 1。当前程序并未对所有无效配置提供友好校验。

修改文件后重启容器使其生效。网页 **Settings** 中这些参数是只读展示。
应用需要保留在设备上，服务器需要保留 IPA；调度器不会自动接管 SideStore 的
全部现有应用，也不能保证断网、长期关机或失效配对情况下仍能续签。

## 部署与维护

镜像发布、自行构建、配置详解、备份迁移及常见问题见 [部署说明](docs/部署说明.md)。

## 许可证

依照上游 README：JAS 特定代码的非商业使用及修改按 MIT 条款授权；商业使用需要
Jackson Coxson 的明确书面许可。各依赖继续适用各自许可证。以原始授权说明为准。
