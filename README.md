# forgejo-tart-runner

为 **Forgejo Actions** 提供「每个 job 都在干净、可丢弃的 macOS 虚拟机里运行」的能力。
基于 [tart](https://github.com/cirruslabs/tart)（Apple Silicon 上的 macOS 虚拟化工具）。

提供 **两种接入方案**，都能做到「每个 job 一台全新 macOS VM、跑完即销毁」：

- **方案 B（推荐）** —— 把 tart 做成 runner 的**执行后端**。runner 常驻宿主，每来一个
  job 自动 `clone → run → exec → delete` 一台干净 VM。原生并发、无需外部编排器、runner
  身份不进 VM。用的是一个**改过的 runner**（本仓库以「补丁 + 自动 rebase 发版」维护，
  因为上游不收 tart）。
- **方案 A** —— runner **跑在 VM 里** + 宿主一个编排脚本。用 **stock runner 零改码**，
  但并发靠「多 VM + 多份注册」，且 runner 身份会进 VM（建议配 ephemeral）。

> 本页主要讲**如何为已有的 Forgejo 接入 tart runner**。如果你只想在本机起一套全新
> Forgejo 做实验，看文末[附录：从零搭本地测试环境](#附录从零搭一套本地测试环境)。

---

## 选哪个方案？

| | 方案 B（推荐） | 方案 A |
|---|---|---|
| 改动 forgejo-runner | 是（补丁，自动维护） | 否（stock 二进制） |
| 并发 | 一个 runner `capacity=N`，原生 | 多 VM × 多份注册 |
| runner 身份是否进 VM | **否**（更安全） | 是（建议配 ephemeral） |
| 外部编排器 | 不需要（标准 `daemon`） | 需要（`orchestrator.sh`） |
| 跟随上游更新 | 半自动（CI rebase 发版） | 最省心（重编官方二进制） |
| 适合 | 并发 / 可能跑不可信代码 / 想要标准体验 | 简单 / 串行 / 不想维护 fork |

---

## 前提条件（两方案通用）

- **Apple Silicon Mac**。单机同时最多跑 **2 台 macOS VM**（Apple 限制）。
- **tart**：`brew install cirruslabs/cli/tart`
- **一个 macOS base 镜像**（每个 job 克隆它运行）——镜像里装了什么，决定 job 能干什么。
  用 cirruslabs 官方镜像（完整列表：[macos-image-templates](https://github.com/cirruslabs/macos-image-templates)，
  实际包：[cirruslabs/packages](https://github.com/orgs/cirruslabs/packages)）。四种变体：
  - `*-vanilla`：纯净 macOS，几乎无软件
  - `*-base`：brew / git / node 等，**不含 Xcode**（本项目默认的 `tahoe-base` 即此类）→ 通用脚本 / Node CI
  - `*-xcode:N`：base + **Xcode N** + Flutter → **构建 / 打包 / 签名 Apple 应用用这个**
  - `*-runner`：多个 Xcode 版本 + xcodes 切换工具

  **必须提前 `tart pull`**（macOS 镜像很大：base ≈ 40 GB、xcode 60–100 GB，首次拉取很慢）：
  ```bash
  tart pull ghcr.io/cirruslabs/macos-tahoe-base:latest      # 通用 CI
  tart pull ghcr.io/cirruslabs/macos-tahoe-xcode:latest     # 构建 Apple 应用
  ```
  注册 label **不会**下载镜像；镜像是在「克隆 VM」时才拉取的。方案 B 的首个 job 会自动 pull
  （很慢、看着像卡住）；方案 A 的编排器要求镜像**已在本地**（否则 preflight 直接报错）。
  所以两种都建议先 pull 好。镜像需含 `git`+`node`（base/xcode 都自带）；缺工具可用
  `./dev/provision.sh <src> <dst>` 补齐并产出黄金镜像。
- **一个已启用 Actions 的 Forgejo**（方案 B 建议版本接近 runner，本仓库基于 runner
  v12 / 实测 Forgejo 15.0.3）。
- **Go 1.25+**（仅用于编译 runner 二进制）。

### ⚠️ 网络可达性（最容易踩坑，先读）

一个 job 全程有 **三处** 网络请求，**都必须从 VM 内可达**：

1. 拉任务 / 回传日志 → 注册时填的 `--instance` 地址
2. `actions/checkout` 克隆你的仓库 → **Forgejo 的 `ROOT_URL`**（不是 `--instance`）
3. 下载 action 本身（如 checkout）→ Forgejo 的 `DEFAULT_ACTIONS_URL`（默认公网 `data.forgejo.org`）

**规则：`--instance` 和 `ROOT_URL` 必须是 VM 能访问的同一地址，绝不能是 `localhost`。**

| 你的 Forgejo 在哪 | 用什么地址 |
|---|---|
| 公网域名 | 直接用该域名（VM 经 NAT 出公网即可） |
| 局域网另一台机器 | 该机器的 LAN IP / 域名 |
| **就在这台 Mac 上** | tart 网关 **`192.168.64.1`**（且 Forgejo 监听该网卡、`ROOT_URL` 也设成它） |

先验证（强烈建议）：

```bash
tart clone tahoe-base netcheck && tart run --no-graphics netcheck >/dev/null 2>&1 &
until tart exec netcheck true 2>/dev/null; do sleep 2; done
tart exec netcheck bash -lc 'curl -s -o /dev/null -w "forgejo=%{http_code}\n" http://<你的forgejo地址>:3000/api/v1/version'
tart exec netcheck bash -lc 'curl -s -o /dev/null -w "actions=%{http_code}\n" https://data.forgejo.org'
tart stop netcheck; tart delete netcheck
```

两个都应 `200`/可达，否则先解决网络再注册。

---

## 方案 B：为现有 Forgejo 接入（推荐）

runner 常驻宿主，每个 job 自动开一台干净 VM。

```bash
# 1) 构建带 tart 后端的 runner（clone 上游 tag + 打补丁 + 编译）
./plan-b/build.sh                       # 产出 dist/forgejo-runner-tart

# 2) 在 Forgejo 取注册 token
#    站点管理 / 组织 / 仓库 → Actions → Runners → 新建，复制 token

# 3) 注册（label 用 tart scheme；身份留在宿主）
mkdir -p runtime-b && cd runtime-b
../dist/forgejo-runner-tart register --no-interactive \
  --instance http://<你的forgejo地址>:3000 \
  --token   <注册 token> \
  --name    mac-tart \
  --labels  'macos:tart://ghcr.io/cirruslabs/macos-tahoe-base:latest'

# 4) 运行（标准 daemon；每个 job 自动 clone/run/exec/delete 一台 VM）
cat > config.yaml <<'EOF'
runner:
  capacity: 2          # 原生并发，最多 2（Apple 限制）
cache:
  enabled: false
EOF
../dist/forgejo-runner-tart daemon --config config.yaml
```

- label 格式：`<名字>:tart://<base 镜像>`。`<base 镜像>` 可为本地镜像名（如 `tahoe-base`）
  或 OCI 引用（自动拉取）。
- 本地冒烟测试：`FTR_FORGEJO_URL=... FTR_REG_TOKEN=... ./plan-b/e2e.sh`。

### 升级 / 同步上游（方案 B）

tart 改动以补丁系列存于 [`plan-b/`](plan-b)（`*.patch`，基于上游 tag `v12.12.0`）。
[`.github/workflows/sync-and-release.yml`](.github/workflows/sync-and-release.yml) 每天自动：
检测上游最新 stable tag → `git am` 补丁（= rebase 到该 tag）→ 在 macOS arm64 上
构建+测试 → 发 Release（`<tag>-tart`，附二进制）；补丁若不再干净套用则失败并开 issue。
手动重建某个版本：`./plan-b/build.sh <tag>`。

---

## 方案 A：为现有 Forgejo 接入

宿主一个编排脚本，每个 job 用 stock runner 在一台全新 VM 里跑。

```bash
# 1) 准备 stock runner 二进制（官方 darwin/arm64 发布版，或自行编译）
( cd sucai/forgejo-runner && GOTOOLCHAIN=local go build -o ../../dist/forgejo-runner . )

# 2) 取注册 token（同方案 B 第 2 步）

# 3) 注册（label 用 host scheme；产出 runtime/.runner）
mkdir -p runtime && cd runtime
../dist/forgejo-runner register --no-interactive \
  --instance http://<你的forgejo地址>:3000 \
  --token   <注册 token> \
  --name    mac-host --labels 'macos:host'
cd ..

# 4) 启动编排器（每个 job 一台干净 VM；默认克隆 tahoe-base）
FTR_BASE_IMAGE=forgejo-tart-base ./plan-a/orchestrator.sh
```

开机自启（launchd）、并发（多注册）、排错速查等详见
[plan-a/integration.md](plan-a/integration.md)。

---

## workflow 怎么写（两方案通用）

把 job 指到你**注册时用的 label 名**（上面两例都用了 `macos`）：

```yaml
# .forgejo/workflows/ci.yml
on: [push]
jobs:
  build:
    runs-on: macos
    steps:
      - uses: actions/checkout@v4
      - run: sw_vers && uname -m && node --version
```

完整示例：[plan-a/ci.yml](plan-a/ci.yml)（`runs-on: macos`）与
[plan-b/tart.yml](plan-b/tart.yml)（`runs-on: tart-macos`），仅 label 名不同。

---

## 构建 / 签名 / 公证 Apple 应用

默认的 `tahoe-base` **只有 Command Line Tools**（`swift` / `clang` / `codesign` / `notarytool`），
**没有 `xcodebuild`**——只能编 Swift 包和命令行工具，**不能** `xcodebuild` 打包 App。

要构建真正的 macOS / iOS 应用，把 base 镜像换成带 Xcode 的即可，其余机制（干净 VM、checkout、
原生执行）完全一样：

- 选 `*-xcode` 或 `*-runner` 镜像并**提前 pull**：`tart pull ghcr.io/cirruslabs/macos-tahoe-xcode:latest`
- 方案 A：`FTR_BASE_IMAGE=macos-tahoe-xcode ./plan-a/orchestrator.sh`（先把镜像 clone 成该本地名）
- 方案 B：注册 label `macos:tart://ghcr.io/cirruslabs/macos-tahoe-xcode:latest`
- 之后 workflow 里可正常 `xcodebuild` / `swift build` / `codesign` / `xcrun notarytool submit`。

签名 + 公证（凭据**不进镜像**，用 Forgejo secrets 注入）：

- 证书（`.p12`）、描述文件、公证凭据（App Store Connect API key 或 Apple ID app-专用密码）
  放进仓库/组织 secrets；step 里导入到**临时 keychain**，用 `xcrun notarytool submit` 公证。
- 干净 VM / job 模型天然适合签名：临时 keychain 随 VM 销毁，证书不会泄漏到别的 job。

---

## 磁盘 / 存储管理 ⚠️

每台 VM 的虚拟磁盘默认 **50 GB**（cirruslabs 镜像）。`tart clone` 是 APFS 写时复制：克隆
瞬间几乎不占空间，**随 VM 内写入而增长，上限 = 该 VM 的磁盘大小**。所有 VM、克隆和镜像
缓存都存在宿主的 `~/.tart`（可用 `$TART_HOME` 改）下，即宿主主盘。

**会不会占满宿主磁盘？会——如果不加管理：**

- 单台 VM 物理增长上限 ≈ 其磁盘大小（默认 50 GB）；并发 2 台 ≈ 最多 2×。
- **残留克隆**：job 正常结束时编排器（方案 A）/ 后端（方案 B）会 `tart delete` 回收；但进程
  被强杀 / 崩溃时克隆会残留（每个最多 ~50 GB）。
- **OCI 拉取缓存**（`~/.tart/cache`）随拉过的镜像累积（xcode 镜像单个就 60–100 GB）。
- 宿主盘一旦写满，tart 会失败、VM 崩溃，甚至影响 macOS 本身。

**限制手段：**

- **限制单台 VM**：`tart set <vm> --disk-size <GB>`（只能增大；要更小需用更小 `--disk-size`
  的 base 镜像重建）。guest 物理写不超过磁盘大小，即单台 VM 占用的硬上限。
- **定期清理残留 / 缓存**（建议挂每日 cron）：
  ```bash
  tart prune --entries vms    --older-than 1    # 删 1 天没用过的本地 VM（清残留克隆，并发安全）
  tart prune --entries caches --space-budget 50 # OCI 缓存压到 ≤50 GB（LRU 淘汰）
  ```
- **给宿主上硬保护（最稳）**：把 `$TART_HOME` 放到一个**带配额的独立 APFS 卷**，tart 再怎么
  涨也超不出该卷，主系统盘永远安全：
  ```bash
  diskutil apfs addVolume disk3 APFS tart-vms -quota 300g   # disk3 换成你的 APFS 容器
  export TART_HOME=/Volumes/tart-vms                         # 写进 shell / launchd 环境
  ```

## 仓库结构

```
plan-a/              方案 A：runner 跑在 VM 里 + 编排器
  orchestrator.sh    宿主编排循环（clone→run→one-job→delete）
  guest-run.sh       VM 内入口
  config.yaml        VM 内 runner 配置
  ci.yml             示例 workflow（runs-on: macos）
  integration.md     接入现有 Forgejo 的详细指南（launchd、排错）
plan-b/              方案 B：tart act 后端
  build.sh           clone 上游 tag → git am 补丁 → 编译
  e2e.sh             本地冒烟测试
  *.patch            tart 后端补丁系列（基于上游 tag）
  tart.yml           示例 workflow（runs-on: tart-macos）
dev/                 本地测试环境 + base 镜像构建（仅实验用）
  setup.sh           一键起本地 Forgejo + 注册 runner
  docker-compose.yml 本地 Forgejo
  provision.sh       构建含 git+node 的黄金 base 镜像
.github/workflows/   方案 B 的自动 rebase + 发版 CI
sucai/               参考源码：forgejo-runner / forgejo-act / tart（git 忽略）
```

---

## 已验证

M4 / macOS 26.1、Forgejo 15.0.3、base `tahoe-base`(macOS 26.3) 上，两方案均端到端跑通：

- **方案 A**：连续 2 个 job 均 `success`，`actions/checkout` 在 VM 内真实克隆仓库，
  step 原生跑在 macOS 26.3 / arm64 / node v24，跨 job 无残留，VM 自动销毁。
- **方案 B**：`tart://` label 选中后端；宿主 runner 抓取 job，后端 clone+boot 干净 VM，
  `actions/checkout` 在 VM 内 `git init`/`fetch`/`checkout`，step 原生执行，job
  `success`，VM 自动销毁；`plan-b/build.sh` 从上游 `v12.12.0` clone + `git am` + 编译通过。

### 已知限制

- macOS VM 无 docker，`uses: docker://` 容器型 action 与 `services:` 不支持
  （与 GitHub 官方 macOS runner 一致）。
- 方案 B 假设 VM 用户为 `admin`（cirruslabs 约定）；换用户名需调整。
- 单机并发上限 2（Apple Virtualization 限制）。

---

# 附录：从零搭一套本地测试环境

如果你**还没有 Forgejo**、只想在本机快速验证这套东西，用 `dev/setup.sh` 一键起一套
**全新的、用完即弃的** Forgejo（跑在 OrbStack/Docker 里）：

```bash
# 构建 runner、起 Forgejo、建管理员、建测试库、推 workflow、注册 runner，一条龙
./dev/setup.sh

# 然后启动编排器（方案 A），或参考上文方案 B 的 daemon
./plan-a/orchestrator.sh
```

`setup.sh` 之后：

- Forgejo：<http://192.168.64.1:3000>（管理员 `forge` / `ForgeTart#2026`）
- 测试库：`forge/mac-ci`，push 即触发 workflow

它做的事（仅用于实验，**不要用于生产**）：把 Forgejo 的 `ROOT_URL` 绑到 tart 网关
`192.168.64.1`（这样 VM 能 clone）、用 API 初始化、注册一个 `macos:host` 的 runner。
配置在 [dev/docker-compose.yml](dev/docker-compose.yml)。
