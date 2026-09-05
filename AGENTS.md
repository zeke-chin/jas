# JAS

## 项目

JAS（Jackson's App Sensei）— 自托管的 AltServer 替代品。单个 Leptos 全栈二进制，用 Apple ID 签名 IPA 文件，通过 RSD-over-TCP 安装到 IP 可达的 iOS 设备上，并在 7 天开发者证书过期前自动刷新应用。README 详细且保持最新；代码库有意不包含 Rust 测试；Docker CI 包含启动、静态资源与密钥持久化检查。

## 构建与运行

前置条件：Rust、`cargo install --locked cargo-leptos`、`rustup target add wasm32-unknown-unknown`、宿主机上的 OpenSSL（或在 `isideload` 依赖中使用 `vendored-openssl` 特性）。

```bash
cargo leptos build --release   # 完整构建：服务端二进制 + WASM + 静态资源
cargo leptos watch             # 带热重载的开发服务器（"cargo leptos dev" 亦可）
cargo leptos serve             # 运行 release 构建
```

输出：`target/release/jas`（二进制）加上 `target/site/`（静态资源）。**运行时两者必须同时存在** —— 二进制从 `LEPTOS_SITE_ROOT`（默认 `target/site`，可在 `Cargo.toml` 的 `[package.metadata.leptos]` 中配置）加载资源。

生产运行：

```bash
JAS_SECRET_KEY=<32-byte-hex> ./jas
```

配置：`jas.toml`（路径可由 `JAS_CONFIG` 覆盖）；所有键见 README。`JAS_SECRET_KEY`（环境变量）优先于 `security.secret_key`。若两者均未设置，代码会调用 `tracing::warn!` 并使用全零密钥 —— 只能视为占位符，不是真正的部署配置。

## Docker 部署与配置

- 根目录 `jas.toml` 是受 Git 跟踪的部署配置，Compose 将其只读挂载到 `/etc/jas/jas.toml`；不需要 `.env`。镜像地址直接写在 `compose.yml` 的 `image` 中。
- `Config::load()` 在服务端启动时读取配置，默认相对于当前工作目录，Docker 通过 `JAS_CONFIG` 指定挂载路径。修改配置后重启服务。
- 根目录配置使用 `/data/jas.db`、`/data/ipas`。本地 `cargo run --features ssr` 或 `cargo leptos watch` 设置 `JAS_DATA_DIR=data/local` 即可复用同一份 `jas.toml`；网页仍需要构建静态资源。
- `docker/entrypoint.sh` 检查配置和数据目录，并生成或复用 `/data/.jas-secret-key`，以环境变量传给 JAS。已有数据库但缺少密钥时拒绝生成新密钥；原生运行不会执行该脚本，也不会自动读取密钥文件。不要向受跟踪的配置写入密钥。
- Compose 将 `./data` 挂载到 `/data`，容器以 UID/GID `10001:10001` 运行。提前准备 `jas.toml` 和可写数据目录；短格式挂载会把不存在的源路径创建为目录。
- Dockerfile 只打包二进制和静态资源，运行配置必须额外挂载；`.dockerignore` 排除运行配置和数据。Linux AMD64 / ARM64 镜像由 `.github/workflows/docker.yml` 构建，测试容器同样必须挂载 `jas.toml`。
- 修改部署文件后运行 `docker compose config --quiet`，修改入口脚本后运行 `sh -n docker/entrypoint.sh`。更改配置路径或镜像启动约定时，同步更新 Docker CI 和 `README.zh.md`。

## SQLx 离线缓存（关键）

`src/server/db/` 使用编译期检查的 `sqlx::query!`/`query_as!` 宏，编译时依赖 `.sqlx/` 中的离线缓存。**当你修改任何查询或新增迁移时，必须重新生成缓存**，否则构建失败：

```bash
just sqlx-prepare
```

该目标会构建一个一次性 SQLite 数据库（`/tmp/jas-sqlx-prepare.db`），对其执行 `sqlx migrate run`，然后以 `ssr` 特性运行 `sqlx prepare`。提交生成的 `.sqlx/*.json` 文件。（在 CI 中，迁移在运行时由 `create_pool` 通过 `sqlx::migrate!("./migrations")` 执行。）

## 架构

单 crate，按特性拆分：`ssr` 特性编译服务端（bin），`hydrate` 编译 WASM 前端（lib）。`src/lib.rs` 为 wasm 目标暴露 `hydrate()`；`src/main.rs` 是服务端入口并编排一切：

1. 加载 `Config` → 初始化 `tracing` → 创建 SQLite 连接池（执行迁移）→ 构建 `AppState`
2. 派生三个后台任务：`run_scheduler`、`run_workers`（任务池）、`run_mdns`
3. 在 Axum 服务器上挂载 Leptos 路由

### 前端（`src/app/`）

- 组件和页面是纯 Leptos SSR + WASM 水合；不存在独立的 REST API —— UI 直接调用服务器函数。
- 几乎所有服务器函数都位于 `src/app/mod.rs`，以 `#[server]` 标记。每个函数通过 `use_context::<AppState>()` 获取共享状态（在 `main.rs` 中通过 `leptos_routes_with_context` 提供）。路由组件位于 `src/app/pages/`；样式是 `style/main.scss`。
- **所有模型类型（如 `DeviceInfo`、`JobInfo`、`TwoFactorPrompt`）都定义在 `app/mod.rs`** —— 它是页面与服务端函数之间的数据契约层。

### 后端（`src/server/`）

- `state.rs` — `AppState`：DB 连接池、配置、`Crypto`、任务队列发送端（`mpsc::Sender<JobRequest>`）、挂起登录注册表、实时 `anisette_url`。到处克隆。
- `db/` — 所有 SQLite 访问。`jobs`/`devices`/`apps`/`apple_accounts` 表，外加 `sideload_storage`（通用键值存储，`isideload` 和 JAS 设置都使用它）。`db::storage::DbStorage` 在异步 sqlx 之上实现 `isideload` 的同步 `SideloadingStorage` trait（内存缓存 + 在派生线程上的写穿透）。
- `sideload/mod.rs` — 所有设备通信。这是项目的核心：
  - **每台设备都通过其 RPPairing 文件经 TCP 连接** —— 绝不用 usbmuxd。`open_cdtunnel` 连接端口 49152，执行 RPPairing 握手，建立 CDTunnel（TLS-PSK），然后通过它访问 RSD 服务以到达 `installation_proxy`、`afc`、`misagent` 和 `lockdown`。
  - `open_cdtunnel_preferring_mdns` / `tcp_ping` 优先尝试 mDNS 发现的局域网 IP，失败后回退到手动配置的 IP —— 过期的 `mdns_ip` 绝不能阻塞本来可用的手动 IP。
  - Apple ID 认证、证书签发和 IPA 签名全部委托给 `isideload`（`AppleAccount`、`DeveloperSession`、`SideloaderBuilder`）。密码从不存储；SPD 会话 plist 加密存储，铸出的 `xcode.auth` 令牌按每 Apple ID 缓存在 `sideload_storage` 中（以 `sha256(apple_id)` 十六进制前缀为作用域；见 `account_storage_prefix`）。
- `scheduler/mod.rs` — 刷新流水线：
  1. `run_scheduler` 每 `interval_hours` 触发一次，拉取到期需刷新的应用（`apps_needing_refresh`：由 `COALESCE(last_refreshed, installed_at)` + 固定的 7 天证书有效期推算，而不是证书数据库）。
  2. 验证每个应用是否仍存在于设备上（每台设备一次 instproxy browse）；失效应用从 DB 中清除。
  3. 将 `JobRequest` 入队到 mpsc 通道（容量 256）。`run_workers` 消费队列，用信号量限制并发（`worker_threads`）。
  4. `execute_job`：快路径是 `refresh_provisioning_profile`（获取新配置文件，通过 misagent 推送）；失败则回退到完整的签名 + 安装。
- `mdns.rs` — 浏览 `_remotepairing._tcp.local.`，当配对文件中的 peer `alt_irk` 验证通过 mDNS 的 `identifier`/`authTag` 时，将 `mdns_ip`/`mdns_seen_at` 写入设备。发现仅作为提示，绝不是注册路径。
- `config.rs` / `crypto.rs` — `Crypto` 是 AES-256-GCM，nonce 前置；用于加密配对文件、账户会话 blob。

### 需保留的已知行为

- `isideload` 签名时会在 bundle ID 后附上团队 ID，因此设备上的实际 bundle ID 与 IPA 中的不同。`db::mark_app_installed` 将行改写为实际 ID，并在冲突时合并重复行（这就是更新如何运作）；任务被重新指向存留的行。
- 临时安装（不存储 IPA）的 `ipa_path IS NULL`；调度器会跳过它们。
- 删除设备级联删除应用；删除账户将应用的 `account_id` 置为 NULL（应用继续运行直到证书过期）。
- 2FA 登录流程是阻塞同步回调与 Web UI 之间的编排：`begin_login` 派生一个带自有运行时的线程，停在回调的 `recv_timeout(300s)` 处，UI 通过 `poll_login` / `submit_two_factor` 针对 `state.pending_logins` 驱动它。不要把登录移到 tokio 运行时线程上 —— 注释说明了该回调会阻塞。

## 惯例

- 新增服务器函数：`#[server] pub async fn ... -> Result<T, ServerFnError>`，通过 `use_context::<AppState>()` 获取状态，并把行模型加到 `src/app/mod.rs`（与客户端共享）。
- 任务进度：worker 接收进度闭包；进度写入 `jobs` 表，UI 轮询 `job_status`/`list_jobs`。
- 验证设备通信改动需要真实硬件（已配对的 iPhone）—— 代码审查和编译检查是主要的安全网。
