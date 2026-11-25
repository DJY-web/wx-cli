# wx-cli Linux 移植版

目标：读取现有 `wechat-selkies` 容器中的 Linux 微信数据，保留查询、搜索、联系人、会话、REST 和 SSE 功能。**本项目仍然是读取工具，没有新增发送微信消息的能力。**

源码基于 `DJY-web/wx-cli`，上游提交 `2abe708f55bfe135539a385df856fdc58f97fc74`，原版本 0.7.4。Linux 移植发布在 [`codex/linux-port` 分支](https://github.com/DJY-web/wx-cli/tree/codex/linux-port)。

## 平台与进度

- 已在 Linux ARM64 / Debian bookworm 的真实 Docker 环境编译发行版。
- 798 项 Rust 工作区测试、Clippy `-D warnings` 已通过；另有 6 项 Python 入口定位/捕获校验测试通过。
- Linux 进程、版本、账号目录、XDG 路径、只读内存读取与服务进程回收已适配。
- 修复 ARM64 Linux `c_char` 类型导致的分词器静态检查问题。
- 新增 `server foreground`，供 Docker/systemd 前台管理，不依赖后台进程存活容器。
- 已构建 `wx-cli-linux:local` 运行镜像，以及独立的 `wx-cli-linux-capture:local` 调试采集镜像。
- 当前 Docker 微信 4.1.13.29 已通过 ARM64 GDB 登录捕获获得并验证密钥，真实联系人、会话和历史消息查询已成功；仅内存模式扫描仍未获得有效密钥。
- 本机只读 API 已启动，认证、查询和 SSE 连接已验证；尚未用新收到的测试消息验证实时推送，也未接通代购助手接单桥。
- 没有降低 Mac SIP 设置，没有修改 Mac 微信，没有自动退出用户微信。

不要把 Linux 编译和人工测试数据通过，理解为所有微信版本都能自动取到密钥。

## Linux 账号目录与环境变量

自动搜索：

```text
~/xwechat_files
~/Documents/xwechat_files
~/.local/share/WeChat/xwechat_files
/config/xwechat_files
```

可显式指定：

```sh
export WX_CLI_WECHAT_DATA_ROOT=/config/xwechat_files
```

它指向 `xwechat_files` 根目录，须为绝对路径。必要时可用 `WX_CLI_WECHAT_PID` 指定当前 PID 命名空间中的微信主进程，`WX_CLI_WECHAT_VERSION` 指定已核实的安装包版本。默认从 `/proc` 识别主进程，再从其根目录或本环境的 Debian 包状态读取微信版本。

配置/密钥、缓存、服务状态分别遵循 `XDG_CONFIG_HOME`、`XDG_CACHE_HOME`、`XDG_STATE_HOME`；没有有效绝对路径覆盖时，使用解析出的真实用户目录的标准 XDG 路径。非 macOS 环境不再要求 SIP、DevToolsSecurity 或 Xcode。

## 先构建

原生 Linux：

```sh
# Debian / Ubuntu 构建依赖；Rust 版本使用 1.95 或兼容新版
sudo apt-get install cmake pkg-config libclang-dev
cargo build --release --locked -p wx-cli
./target/release/wx-cli --help
```

完整源码 Docker 构建：

```sh
sh scripts/selkies.sh build
```

本机已经有测试过的 ARM64 二进制 `dist/wx-cli`，可快速重新打包：

```sh
docker build -f docker/Dockerfile.runtime -t wx-cli-linux:local .
docker build -f docker/Dockerfile.capture -t wx-cli-linux-capture:local .
```

`dist/wx-cli` 是 Linux ARM64 ELF，不能直接双击在 macOS 运行。AMD64 需要在相应架构重新编译；本轮未做 AMD64 实机验证。不要把 ARM64 专用 GDB 定位器当成 AMD64 捕获实现。

## 对接现有 Docker 微信

`scripts/selkies.sh` 默认使用：

```text
微信容器：wechat-mercari-assistant-wechat-1
微信数据卷：wechat-mercari-assistant_wechat-config（只读挂载 /config）
wx-cli 私有卷：wx-cli-linux-state（挂载 /state）
```

可通过 `WX_CLI_WECHAT_CONTAINER`、`WX_CLI_WECHAT_VOLUME`、`WX_CLI_STATE_VOLUME` 覆盖。脚本自动寻找 Docker Desktop 内置 CLI，不要求 Mac 安装全局命令软链接。

### 方式一：不暂停微信的只读扫描

```sh
sh scripts/selkies.sh scan
```

短期辅助容器共享指定微信容器的 PID 命名空间，仅增加该辅助容器的 `SYS_PTRACE` 权限，微信数据卷只读、网络关闭，不重启、不 ptrace-attach 微信。

扫描既有的 SQL 十六进制密钥模式，也尝试识别 SQLCipher/WCDB 上下文。所有候选都必须匹配数据库 salt 并通过第一页 HMAC 校验。扫描失败会明确报错，不会保存猜测的密钥。当前 4.1.13.29 未通过这条路径。

### 方式二：ARM64 登录时显式捕获

**先征得用户同意：此方式临时附加 GDB，断点会短暂停顿微信，需要用户手动退出账号并重新登录。正常后台服务不会自动运行它。**

```sh
sh scripts/selkies.sh capture
```

等出现 `Debugger ready` 后，在容器微信中退出当前账号并重新扫码登录同一账号。不要停止 Docker 或关闭容器。

原理是从实际 ELF 的 WCDB 特征字符串、GOT 引用和 unwind 表定位唯一的 ARM64 `setCipherKey` 函数；不硬编码运行时 ASLR 地址。入口不唯一、架构不支持或已有其他调试器时拒绝猜测。读取 `UnsafeData` 的 32 字节参数，先在辅助脚本验证，再由 Rust 核心独立 HMAC 校验，成功才保存到私有密钥库。

采集超时会请求 GDB 中断和解除调试连接，不自动重启/退出微信。默认最多等待 600 秒。中间密钥文件位于私有目录、权限 0600，正常退出清理；Linux 最终密钥库 `/state/config/wx-cli/keys.toml` 也以 0600 原子写入，不跟随既有临时文件符号链接。

本轮针对调试器的操作已取得用户明确授权，但这不代表任何以后会话都可以任意附加其他进程或修改权限。不要扫描 Mac 进程，不改变宿主 ptrace 参数，不使用 `--privileged` 或宿主 PID 命名空间。

### 方式三：已有密钥

已有原始数据库密钥时可沿用 `key set`。避免将真实密钥直接写进共享聊天、命令历史或日志。不要把数据库原始密钥与按 salt 派生的 encryption key 混用。

Linux `key scan` 和 `key extract` 不打印原始密钥。原有 `key list` 功能会显示密钥值，**不要把它的输出贴进对话或公开日志**。

## 获得并校验密钥后查询

```sh
sh scripts/selkies.sh run sessions --limit 10 --format json --no-server
sh scripts/selkies.sh run contacts --limit 10 --format json --no-server
sh scripts/selkies.sh run query '联系人标识' --limit 10 --format json --no-server
sh scripts/selkies.sh run search '关键词' --limit 10 --format json --no-server
```

查询容器运行在 UID 1000 下，微信卷只读，不授予调试权限，网络关闭。采集成功后脚本只调整独立 `/state` 卷的所有者，使查询用户能访问私有密钥。

查询容器通常不共享微信 PID 命名空间，因此 `status` 中的进程检测不能作为微信本体是否运行的唯一依据；账号目录和密钥/查询结果应分别核实。

## REST / SSE 服务

密钥验证通过后：

```sh
sh scripts/selkies.sh server
```

服务名 `wx-cli-linux-api`，仅向 Mac 本机发布 `127.0.0.1:9100`。容器内使用 `server foreground`，REST 与 SSE 都要求 Bearer token。token 自动保存在私有卷 `/state/config/wx-cli/api-token`，不会打印。

本机当前已经启动该服务。重复执行 `server` 会启动或复用现有容器，`stop` 后可再次用 `server` 启动。已有容器会保留创建时的镜像、端口和卷设置。直接在浏览器打开 API 而不带 token 会返回 401，这是预期行为。

服务没有 `SYS_PTRACE` 权限，也不共享微信进程空间；仅只读挂载微信数据，用私有卷保存必要缓存和状态。收到 SIGTERM/SIGINT 会按原服务逻辑清理。

```sh
sh scripts/selkies.sh stop
```

不要删除 `wx-cli-linux-state`、原微信数据卷或原订单助手的数据卷。

现有代购助手的 `assistant/bridge.py` 支持本机 `9100` 的 SSE，但还需要正确配置服务 token、客人内部会话标识并验证消息格式。本轮不默认开启接单桥、不向任何联系人发消息。

## 测试

```sh
cargo fmt --all -- --check
cargo test --locked --workspace
cargo clippy --locked --workspace -- -D warnings
python3 -m unittest discover -s tests/linux -v
```

测试包含 Linux 进程过滤、账号目录、XDG 路径、失效/僵尸服务进程识别、只读上下文候选校验及跨块扫描、ARM64 引用定位、捕获时拒绝无效密钥、私有文件权限、临时符号链接保护和不打印密钥。

## 实现参考

代码主要复用原仓库的解密与查询核心。Linux `/proc` 的访问遵循[内核权限检查](https://www.man7.org/linux/man-pages/man5/proc_pid_mem.5.html)。ARM64 ELF 静态定位为本移植新增，实现思路参考 [wcdb-key-tool 的 Linux 调试捕获说明](https://github.com/TANGandXUE/wcdb-key-tool)，没有直接采用其仅支持 x86_64 的定位器。

配置及上下文字段的依据包括 [Tencent WCDB CipherConfig](https://github.com/Tencent/wcdb/blob/master/src/common/core/config/CipherConfig.cpp) 和 [Tencent SQLCipher wcdb 分支](https://github.com/Tencent/sqlcipher/blob/wcdb/src/crypto_impl.c)。不依赖网络微信协议，不上传密钥或聊天数据库。

## 本机验证记录

2026-11-25（Asia/Tokyo）：目标为现有 Docker Linux 微信 4.1.13.29 / ARM64。用户明确同意临时调试和私有密钥保存，并手动退出后扫码登录同一账号。

- 登录时捕获的密钥通过 Python 和 Rust 两次数据库 HMAC 校验，保存到独立 `wx-cli-linux-state` 私有卷；日志没有打印密钥。
- 捕获结束后检查 `TracerPid: 0`，调试器已解除。
- 真实 CLI 验证：联系人 10 条、会话 10 条、历史消息 3 条成功返回；检查只输出数量和字段，没有在对话展示聊天内容。
- 本机 API：无 token 请求返回 401；带 token 的健康检查返回 200 且 ready=true，联系人和会话查询成功。
- SSE `/api/v1/events` 返回 200、`text/event-stream` 并收到事件帧；未发送测试消息，不将其表述为新消息完整链路已验收。
- 只读内存扫描仍失败，需要密钥时应使用已授权的登录捕获或人工导入，不能把扫描报错忽略。
- 自动微信发送、代购桥接接单和 Mercari 自动购买尚未实现或联调。本轮交付完成的是 Linux 读取移植及上述真实验证。
