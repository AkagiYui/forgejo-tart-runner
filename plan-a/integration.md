# 接入已有的 Forgejo 实例

本文面向「**已经有一个在运行的 Forgejo**」的用户，介绍如何把 forgejo-tart-runner
接上去，让该实例的 Actions job 都在干净、即用即弃的 macOS 虚拟机里运行。

> 如果你只是想在本机起一套全新的 Forgejo 做实验，看仓库根目录 `README.md` 的
> 「快速开始」(`dev/setup.sh` 会顺带帮你起 Forgejo)。本文不依赖那套，
> 只对接**你自己的** Forgejo。

接好之后你会得到：

- 宿主 Mac 上一个 **orchestrator 进程**(可做成开机自启)；
- 它向你的 Forgejo 注册了一个(或多个) runner，label 形如 `macos`；
- 任何 `runs-on: macos` 的 job，都会被分配到一台**全新克隆的 macOS VM** 里执行，
  跑完即销毁。

---

## 0. 架构回顾(一句话)

宿主上的 orchestrator 循环：`tart clone` 干净基础镜像 → 无头启动 → 在 VM 内跑
**stock `forgejo-runner one-job`**(host 后端，原生执行) → `tart delete`。runner
本身不感知 tart；它只是用一份 `.runner` 身份连上你的 Forgejo 拉一个任务。

---

## 1. 前提条件

| 项 | 要求 |
|---|---|
| 硬件 | Apple Silicon Mac(M 系列)。单机最多同时跑 **2 台 macOS VM**(Apple 限制)。 |
| 宿主系统 | macOS(VM 的 guest 版本需 ≤ 宿主版本) |
| tart | `brew install cirruslabs/cli/tart` |
| 基础镜像 | 一个含 **git + node** 的 macOS tart 镜像(详见第 3 步) |
| Go | 1.25+(仅用于编译 runner 二进制；也可用别处编好的) |
| 你的 Forgejo | 已启用 **Actions**；建议版本接近 runner(本项目基于 runner v12，已在 Forgejo **15.0.3** 实测)。Ephemeral 注册需 Forgejo **15+**。 |

---

## 2. 网络可达性 ⚠️(最容易踩坑，先读这节)

VM 通过 tart 的 NAT 网络访问外部。一个 job 全程有**三处**网络请求，**都必须从 VM 内可达**：

1. **拉任务 / 回传日志**(gRPC)→ 连接的是注册时填的 `--instance` 地址(写在 `.runner` 里)。
2. **`actions/checkout` 克隆你的仓库**(git)→ 用的是 **Forgejo 的 `ROOT_URL`** 推导出来的地址，**不是** `--instance`。
3. **下载 action 本身**(如 checkout)→ 来自 Forgejo 的 `DEFAULT_ACTIONS_URL`(默认 `https://data.forgejo.org`，需公网)。

由此得出关键规则：

- **`--instance` 和 Forgejo 的 `ROOT_URL` 必须是「VM 能访问到」的同一个地址。**
  - 绝不能是 `localhost` / `127.0.0.1`——VM 访问不到宿主的 loopback。
- 按你的 Forgejo 部署位置选地址：

| 你的 Forgejo 在哪 | 用什么地址 | 备注 |
|---|---|---|
| **公网域名**(如 `https://git.example.com`) | 直接用该域名 | 最省事，VM 经 NAT 出公网即可 |
| **局域网**另一台机器 | 该机器的 LAN IP/域名 | 确认 VM 能路由到该网段(NAT 通常可达 LAN) |
| **就在这台 Mac 上**(本地) | tart 网关 IP **`192.168.64.1`** | 且 Forgejo 要监听该网卡、`ROOT_URL` 也设成它 |

> 「就在本机」的情况下，确保 Forgejo 的 `ROOT_URL=http://192.168.64.1:3000/` 且端口
> 发布在 `0.0.0.0`(VM 才连得上宿主的 `192.168.64.1`)。

### 先验证一遍(强烈建议)

随便克隆一台基础镜像启动，从 VM 内 curl 一下你的 Forgejo：

```bash
tart clone <你的基础镜像> netcheck
tart run --no-graphics netcheck >/tmp/netcheck.log 2>&1 &
until tart exec netcheck true 2>/dev/null; do sleep 2; done

# 把下面 URL 换成你打算用的 --instance / ROOT_URL
FORGEJO_URL="https://git.example.com"
tart exec netcheck bash -lc "curl -s -o /dev/null -w 'api=%{http_code}\n' $FORGEJO_URL/api/v1/version"
tart exec netcheck bash -lc "curl -s -o /dev/null -w 'actions=%{http_code}\n' https://data.forgejo.org"

tart stop netcheck; tart delete netcheck
```

两个都应是 `200`/可达。否则先解决网络再继续。

---

## 3. 准备宿主 Mac

### 3.1 安装 tart 并准备基础镜像

基础镜像必须含 **git** 和 **node**(`actions/checkout` 等 JS action 要用)。
cirruslabs 的官方镜像通常已自带这两者和 tart guest agent：

```bash
brew install cirruslabs/cli/tart

# 拉一个与宿主匹配的 macOS 基础镜像(示例：Tahoe/macOS 26)
tart pull ghcr.io/cirruslabs/macos-tahoe-base:latest
tart clone ghcr.io/cirruslabs/macos-tahoe-base:latest forgejo-tart-base
```

如需确保/补齐 git+node，并产出一个干净的「黄金镜像」，用本仓库脚本：

```bash
./dev/provision.sh ghcr.io/cirruslabs/macos-tahoe-base:latest forgejo-tart-base
```

> 验证镜像具备工具链：
> `tart run --no-graphics forgejo-tart-base & ; tart exec forgejo-tart-base bash -lc 'git --version; node --version'`

### 3.2 获取本仓库并编译 runner 二进制

```bash
git clone <本仓库> forgejo-tart-runner
cd forgejo-tart-runner

# 编译 darwin/arm64 runner(注意 GOTOOLCHAIN=local，避免联网拉特定 toolchain)
( cd sucai/forgejo-runner && GOTOOLCHAIN=local go build -o ../../dist/forgejo-runner . )
file dist/forgejo-runner   # 应为 Mach-O arm64
```

> `sucai/forgejo-runner` 是被编译的 runner 源码。如果你的仓库里没有 `sucai/`，
> 用任意同版本的 `forgejo/runner` 源码编译出 `dist/forgejo-runner` 即可。

---

## 4. 在 Forgejo 取一个 runner 注册 token

按你想让这个 runner 服务的范围选一种：

- **整个实例**(管理员)：站点管理 → Actions → Runners → 「创建 Runner」，复制 token。
  API：`GET /api/v1/admin/runners/registration-token`(需管理员 token)。
- **某组织**：组织设置 → Actions → Runners。
  API：`GET /api/v1/orgs/{org}/actions/runners/registration-token`。
- **某仓库**：仓库设置 → Actions → Runners。
  API：`GET /api/v1/repos/{owner}/{repo}/actions/runners/registration-token`。

例(实例级，用管理员 token)：

```bash
curl -s -H "Authorization: token <ADMIN_API_TOKEN>" \
  https://git.example.com/api/v1/admin/runners/registration-token
# => {"token":"xxxxxxxx..."}
```

---

## 5. 注册 runner(生成 `runtime/.runner`)

在仓库根目录执行(**`--instance` 用第 2 节确定的、VM 可达的地址**)：

```bash
mkdir -p runtime
( cd runtime && ../dist/forgejo-runner register --no-interactive \
    --instance https://git.example.com \
    --token   <第 4 步拿到的 REGISTRATION_TOKEN> \
    --name    mac-tart-1 \
    --labels  'macos:host' )
```

说明：

- `--labels 'macos:host'`：label **名字**是 `macos`(workflow 里 `runs-on: macos` 用它)，
  **scheme** 是 `host`(选用 host 后端 = 在 VM 上原生执行，无 docker)。
  可注册多个，如 `'macos:host,macos-arm64:host'`。
- 成功后生成 `runtime/.runner`(含 uuid/token/address/labels)。**这是 runner 的身份，
  里面有密钥，已被 `.gitignore` 忽略，别提交、别外泄。**
- 这一步只做**一次**；之后每次跑 job 都复用这份身份(详见 README 的 Q&A)。

---

## 6. 配置并启动 orchestrator

### 6.1 检查 `plan-a/config.yaml`

这是 **VM 内** runner 用的配置，通常无需改。注意：

- `host.workdir_parent`：job 工作目录的父目录，默认 `/Users/admin/.cache/...`。
  cirruslabs 镜像的用户是 `admin`；**如果你的基础镜像用户不是 `admin`，改成对应家目录**。
- `cache.enabled: false`：v1 关闭了 actions 缓存。要开需保证 cache server 在 VM 内可达。

### 6.2 启动

```bash
FTR_BASE_IMAGE=forgejo-tart-base ./plan-a/orchestrator.sh
```

常用环境变量：

| 变量 | 默认 | 说明 |
|---|---|---|
| `FTR_BASE_IMAGE` | `tahoe-base` | 要克隆的基础镜像(需含 git+node) |
| `FTR_LOOP` | `1` | `1` 持续循环；`0` 跑一个 job 后退出 |
| `FTR_BOOT_TIMEOUT` | `120` | 等 guest agent 就绪的秒数 |

启动后它会拉起一台 VM 等任务。去 Forgejo 后台 Runners 列表，应能看到 `mac-tart-1`
上线(VM 运行时 online，销毁后 offline)。

---

## 7. 在你的仓库里写 workflow

把 job 指到 `macos` label：

```yaml
# .forgejo/workflows/ci.yml
name: macOS CI
on: [push]
jobs:
  build:
    runs-on: macos          # 对应注册的 label 名字
    steps:
      - uses: actions/checkout@v4
      - run: |
          sw_vers
          uname -m
          node --version
```

push 后即触发；orchestrator 会克隆一台干净 VM 来跑它。
完整示例见 `plan-a/ci.yml`。

---

## 8.（可选）做成开机自启服务(launchd)

让 orchestrator 随登录自动运行。新建
`~/Library/LaunchAgents/com.forgejo.tart-runner.plist`：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>            <string>com.forgejo.tart-runner</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>/Users/你的用户名/forgejo-tart-runner/plan-a/orchestrator.sh</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>FTR_BASE_IMAGE</key> <string>forgejo-tart-base</string>
    <key>PATH</key>           <string>/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>WorkingDirectory</key> <string>/Users/你的用户名/forgejo-tart-runner</string>
  <key>RunAtLoad</key>        <true/>
  <key>KeepAlive</key>        <true/>
  <key>StandardOutPath</key>  <string>/tmp/forgejo-tart-runner.log</string>
  <key>StandardErrorPath</key><string>/tmp/forgejo-tart-runner.err</string>
</dict>
</plist>
```

```bash
launchctl load  ~/Library/LaunchAgents/com.forgejo.tart-runner.plist   # 启用
launchctl unload ~/Library/LaunchAgents/com.forgejo.tart-runner.plist  # 停用
tail -f /tmp/forgejo-tart-runner.log
```

> 注意：tart 运行 VM 需要图形会话(Aqua)。建议这台 Mac **自动登录到桌面**后由
> LaunchAgent 拉起；用纯 LaunchDaemon(无会话)可能无法启动 VM。

---

## 9. 排错速查

| 现象 | 可能原因 / 处理 |
|---|---|
| Forgejo 后台 runner 一直 offline | orchestrator 没在跑；或 `--instance` 地址 VM 连不上(见第 2 节)；或 token/版本不对 |
| `actions/checkout` 失败、连不上 git | **Forgejo `ROOT_URL` 不是 VM 可达地址**(常见是设成了 localhost)；按第 2 节改 |
| 下载 action 超时 | VM 无公网，或 `DEFAULT_ACTIONS_URL`(data.forgejo.org)不可达 |
| job 报找不到 git/node | 基础镜像缺工具链，用 `dev/provision.sh` 补 |
| orchestrator 启动即报缺文件 | 没编译 `dist/forgejo-runner`、没注册出 `runtime/.runner`、或基础镜像名不对 |
| 第 3 台 VM 起不来 | Apple 单机 2 台 macOS VM 上限 |
| 编译 runner 卡在下载 toolchain | 用 `GOTOOLCHAIN=local go build` |
| guest agent 一直不就绪 | 这台 Mac 不在图形会话里跑(见第 8 节注意) |

排查时可直接看某次 job 的 runner 日志：orchestrator 会把 VM 内 `one-job` 的输出
打到自己的 stdout(launchd 模式见 `/tmp/forgejo-tart-runner.log`)。

---

## 10.（可选）并发与 Ephemeral

- **并发**：当前模型「一台 VM 一个 job」，并发就是同时跑多台 VM，**每台一份独立注册**。
  例如再注册一个 `mac-tart-2`，用另一份 `.runner` 起第二个 orchestrator 循环
  (`FTR_RUNNER_FILE=.../runtime/.runner-2`)。受 Apple 2-VM 上限约束。
- **Ephemeral**(Forgejo 15+)：注册时加 `--ephemeral`，每个 runner 跑完一个 job 后
  Forgejo 自动注销，更贴合「即用即弃」语义、并发时也更干净。代价是每个 job 需重新
  注册一次。详细权衡见仓库 README 的 Q&A。
```
