# forgejo-tart-runner — 方案 B：tart 作为 act 执行后端

> 本仓库提供 **两种** 为 Forgejo Actions 跑「干净 macOS 环境」的方案。
> **本页顶部是方案 B**（推荐用于并发 / 可能跑不可信代码的场景）；
> 分割线 `---` 下方是 **方案 A**（runner 跑在 VM 里 + 宿主编排器，零改码）。
> 两者可共用同一个 base 镜像。不知道选哪个？看 [方案 A 还是方案 B](#方案-a-还是方案-b)。

## 方案 B 是什么

把 tart 实现成 forgejo-runner 内嵌 act 引擎的**第四种执行后端**（在 `docker` /
`host` / `lxc` 之外新增 `tart`）。**runner 进程常驻宿主**，每来一个 job：

1. `tart clone` 一个干净 base 镜像 → 临时 VM
2. `tart run` 无头启动，把工作根目录挂载进 VM
3. 通过 `tart exec` 在 VM 内**原生**执行 step（`actions/checkout` 在 VM 里 `git clone`）
4. `tart stop` + `tart delete` 销毁 VM

相比方案 A 的优势：

- **原生并发**：一个 runner 进程 `capacity=N`，每个并发 job 各自一台专属 VM
  （受 Apple 单机最多 2 台 macOS VM 限制）。无需多份注册。
- **runner 身份不进 VM**：runner 进程留在宿主，`.runner` 注册凭据 job 代码读不到，
  因此**不需要 ephemeral 来止血**。
- **无外部编排器**：就是标准的 `forgejo-runner daemon`，只多一个 `tart` label scheme。

代价：这是对 forgejo-runner 的**改动**。上游因 tart 非自由软件**不会合入**
（[feature-requests#6](https://code.forgejo.org/forgejo/forgejo-actions-feature-requests/issues/6)），
故需自行维护——本仓库用「补丁 + 自动 rebase 发版」把成本降到最低（见
[升级/同步上游](#升级--同步上游自动-rebase--发版)）。

## 快速开始

前提：Apple Silicon Mac、`tart`（`brew install cirruslabs/cli/tart`）、含 **git + node**
的 base 镜像、Go 1.25+、一个已启用 Actions 的 Forgejo。
⚠️ Forgejo 的 `--instance` 与 `ROOT_URL` 必须 **VM 可达**（不能是 localhost），
详见 [docs/integration.md](docs/integration.md) 的「网络可达性」一节。

```bash
# 1) 构建带 tart 后端的 runner（把补丁 rebase 到上游 tag 再编译）
./plan-b/build.sh                       # 产出 dist/forgejo-runner-tart

# 2) 注册（label 用 tart scheme；身份留在宿主）
mkdir -p runtime-b && cd runtime-b
../dist/forgejo-runner-tart register --no-interactive \
  --instance http://<forgejo-地址>:3000 \
  --token <注册 token> \
  --name mac-tart \
  --labels 'tart-macos:tart://ghcr.io/cirruslabs/macos-tahoe-base:latest'

# 3) 运行（标准 daemon；每个 job 自动开/销毁一台干净 VM）
cat > config.yaml <<'EOF'
runner:
  capacity: 2          # 原生并发，最多 2（Apple 限制）
cache:
  enabled: false
EOF
../dist/forgejo-runner-tart daemon --config config.yaml
```

workflow 里把 job 指到该 label：

```yaml
jobs:
  build:
    runs-on: tart-macos          # = 注册的 label 名
    steps:
      - uses: actions/checkout@v4
      - run: sw_vers && node --version
```

label 格式：`<名字>:tart://<base 镜像>`。`<base 镜像>` 可为本地镜像名（如 `tahoe-base`）
或 OCI 引用（自动拉取）。完整示例见 [examples/workflows/tart.yml](examples/workflows/tart.yml)。

本地冒烟测试：`FTR_FORGEJO_URL=... FTR_REG_TOKEN=... ./plan-b/e2e.sh`。

## 升级 / 同步上游（自动 rebase + 发版）

tart 改动以**补丁系列**保存在 [`plan-b/patches/`](plan-b/patches)（基于上游 tag
`v12.12.0`）。`./plan-b/build.sh <tag>` 会 clone 上游该 tag、`git am` 补丁
（即把改动 **rebase** 到该 tag）、再编译。

[`.github/workflows/sync-and-release.yml`](.github/workflows/sync-and-release.yml)
每天自动：检测上游最新 stable tag → rebase 补丁 → 在 macOS arm64 上构建 + 测试 →
发 Release（`<tag>-tart`，附二进制）。补丁若不再干净套用（上游改了派发点 / 接口），
workflow 失败并开 issue 提示手动刷新。

手动刷新补丁（上游有破坏性变更时）：

```bash
git clone --branch <新tag> https://code.forgejo.org/forgejo/runner /tmp/u && cd /tmp/u
git am <repo>/plan-b/patches/*.patch      # 解决冲突后 git am --continue
git format-patch <新tag> -o <repo>/plan-b/patches
```

## 改动范围（便于审阅 / 评估冲突面）

- **新增** `act/container/tart.go` —— 后端实现本体（永不冲突）
- 改 `internal/pkg/labels/labels.go` —— 加 `tart` scheme
- 改 `act/runner/run_context.go` —— 加 tart 派发 + VM 生命周期挂载点
- 改 `act/container/host_environment.go` —— `exec` 走 `tart exec`，复用其文件处理

实现复用 `HostEnvironment`：把工作根目录挂载进 VM、并在 guest 内 symlink 成**同名绝对
路径**，于是 Copy/CopyDir 仍在宿主侧完成，仅命令执行经 `tart exec` 进入 VM——这把新增
逻辑压到最小，也缩小了与上游的冲突面。

## 已验证（方案 B，真机 e2e）

M4 / macOS 26.1、Forgejo 15.0.3、base `tahoe-base`(macOS 26.3)：

- ✅ `tart://` label 选中 tart 后端；宿主 runner 抓取 `runs-on: tart-macos` 的 job
- ✅ 后端 `tart clone`+`run` 开干净 VM，挂载工作根目录并 symlink 成同名路径
- ✅ `actions/checkout@v4` 在 VM 内 `git init` / `git fetch` / `git checkout` 真实克隆仓库
- ✅ step 原生跑在 macOS 26.3 / arm64 / node v24；干净环境断言通过；job `success`
- ✅ job 结束自动 `tart stop`+`delete`，宿主只剩 base 镜像
- ✅ `plan-b/build.sh` 从上游 `v12.12.0` clone + `git am` 补丁 + 编译 全程通过

## 方案 A 还是方案 B？

| | 方案 A（下方）| 方案 B（本节）|
|---|---|---|
| 改动 forgejo-runner | 否（stock 二进制）| 是（补丁，自动 rebase 维护）|
| 并发 | 多 VM × 多份注册 | 一个 runner、`capacity=N`、原生 |
| runner 身份是否进 VM | 是（建议配 ephemeral）| 否 |
| 外部编排器 | 需要（orchestrator.sh）| 不需要（标准 daemon）|
| 跟随上游 | 最省心（重编官方二进制）| 半自动（CI rebase + 发版）|
| 适合 | 简单 / 串行 / 不想维护 fork | 并发 / 可能跑不可信代码 / 要标准体验 |

---

# forgejo-tart-runner

为 **Forgejo Actions** 提供「每个 job 都在干净、可丢弃的 macOS 虚拟机里运行」的能力。
基于 [tart](https://github.com/cirruslabs/tart)（Apple Silicon 上的 macOS 虚拟化工具）。

实现采用 **方案 A：Runner 跑在 VM 里 + 宿主编排器**。宿主上的标准
`forgejo-runner` 二进制 **完全不改动**——它被烤进一个 macOS 基础镜像，每个 job
克隆一份全新 VM 来运行，跑完即销毁。

> 状态：本仓库内已端到端跑通并验证（见 [已验证](#已验证)）。
>
> 👉 **已经有自己的 Forgejo、想把它接上来？** 看 [docs/integration.md](docs/integration.md)（接入已有 Forgejo 实例指南）。下面的「快速开始」是在本机起一套全新 Forgejo 做实验用的。

---

## 工作原理

```
宿主 macOS (Apple Silicon)
┌────────────────────────────────────────────────────────────────────┐
│  orchestrator.sh  (本仓库)                                           │
│     每个 job 循环：                                                   │
│       1. tart clone  <base> ftr-job-XXXX     (写时复制，秒级)         │
│       2. tart run --no-graphics --dir=payload:…  (无头启动，挂载载荷) │
│       3. tart exec   ftr-job-XXXX  guest-run.sh                       │
│              └─ 在 VM 内运行: forgejo-runner one-job --wait           │
│                    （host 后端，原生执行；等到一个任务→执行→退出）     │
│       4. tart stop + tart delete  ftr-job-XXXX  (销毁，环境归零)      │
└───────────────┬────────────────────────────────────────────────────┘
                │ tart CLI                         ▲ poll/report (gRPC)
                ▼                                  │
        干净 macOS VM (clone)  ──────────────────►  Forgejo (OrbStack/Docker)
          forgejo-runner one-job                    http://192.168.64.1:3000
          actions/checkout → git clone ────────────►  (VM 经 NAT 网关访问宿主)
```

要点：

- **Runner 不感知 tart。** VM 内跑的是 stock `forgejo-runner`，用 `host` 后端
  （label `macos:host`）原生在 macOS 上执行 step。所有 VM 生命周期都由宿主
  编排器通过 `tart` 命令行驱动。
- **干净 / 可恢复。** 基础镜像是「黄金快照」；每个 job `tart clone` 出一份，
  跑完 `tart delete`。job 之间零残留（[已验证](#已验证)跨 job 不泄漏）。
- **`one-job` 一次性原语。** `forgejo-runner one-job --wait` 等到一个任务、执行、
  然后退出——天然契合「一台 VM 一个 job」。

---

## 仓库结构

```
orchestrator/
  orchestrator.sh   宿主编排循环：clone → run → one-job → destroy
  guest-run.sh      VM 内入口：把载荷拷到本地并运行 one-job
  config.yaml       VM 内 runner 配置（host 后端、workdir）
image/
  provision.sh      构建/确保基础镜像含 git+node（黄金镜像）
forgejo/
  docker-compose.yml  本地 Forgejo（ROOT_URL 绑定到 tart 网关，VM 可达）
scripts/
  setup.sh          一键搭好开发/测试环境（建库、注册、推 workflow）
examples/workflows/
  ci.yml            演示 workflow（checkout + 原生 step + 干净环境断言）
dist/               构建产物：forgejo-runner (darwin/arm64)   [git 忽略]
runtime/            运行态与密钥：.runner 注册文件             [git 忽略]
sucai/              参考源码：forgejo-runner / forgejo-act / tart [git 忽略]
```

---

## 前置条件

- Apple Silicon Mac（本项目在 **M4 / macOS 26.1** 上验证）。
- [`tart`](https://github.com/cirruslabs/tart)：`brew install cirruslabs/cli/tart`
- 一个 **macOS 基础 VM 镜像**，含 `git` 与 `node`。最简单：
  `tart pull ghcr.io/cirruslabs/macos-tahoe-base:latest`，或用 `image/provision.sh`
  产出 `forgejo-tart-base`。（cirruslabs 的 base 镜像已带 git/node 与 tart guest agent。）
- Docker（这里用 **OrbStack**）跑本地 Forgejo。
- Go 1.25+（仅用于构建 runner 二进制）。

---

## 快速开始

```bash
# 1) 一键搭环境：构建 runner、起 Forgejo、建管理员、建测试库、推 workflow、注册 runner
./scripts/setup.sh

# 2) 启动编排器（每个 job 一台干净 VM）。默认克隆基础镜像 tahoe-base：
./orchestrator/orchestrator.sh
# 或指定自建黄金镜像：
FTR_BASE_IMAGE=forgejo-tart-base ./orchestrator/orchestrator.sh
```

`setup.sh` 之后：

- Forgejo: <http://192.168.64.1:3000>（管理员 `forge` / `ForgeTart#2026`）
- 测试库: `forge/mac-ci`，推送时即触发 workflow。

编排器启动后会拉起一台 VM 等任务；在 Forgejo 里触发 `examples/workflows/ci.yml`
（push 或手动 `workflow_dispatch`），即可看到 job 在干净 macOS VM 中运行。

---

## 一个 job 是怎么在 VM 里跑起来的

以 `uses: actions/checkout@v4` 为例（已抓取真实执行日志验证）：

1. runner（VM 内，`host` 后端）从 `runs.using` 判断这是个 **JS action**，先把
   action 仓库 `git clone` 到 VM 本地的 action 缓存目录（默认从 Forgejo 的
   `DEFAULT_ACTIONS_URL`，本环境是 `data.forgejo.org`）。
2. 用 VM 里的 **node** 执行该 action（`node .../checkout/dist/index.js`）。
3. checkout 在 VM 内 `git init` → `git remote add origin
   http://192.168.64.1:3000/forge/mac-ci` → 注入 `AUTHORIZATION` 头（token 来自
   runner 注入的 `ACTIONS_RUNTIME_TOKEN`）→ `git fetch --depth=1 <SHA>` →
   `git checkout` —— **真正在 VM 内把仓库克隆下来**。
4. 普通 `run:` step 由 runner 写成脚本，在 VM 上原生 `bash` 执行。

因此 VM 镜像只需具备 **git + node + 能访问 Forgejo 的网络**（tart 默认 NAT，
VM 经 `192.168.64.1` 访问宿主上的 Forgejo）。

---

## 配置项（环境变量）

编排器 `orchestrator/orchestrator.sh`：

| 变量 | 默认 | 说明 |
|---|---|---|
| `FTR_BASE_IMAGE` | `tahoe-base` | 要克隆的基础镜像（需含 git+node） |
| `FTR_LOOP` | `1` | `1` 持续循环；`0` 跑一个 job 后退出 |
| `FTR_BOOT_TIMEOUT` | `120` | 等待 guest agent 就绪的秒数 |
| `FTR_BIN` | `dist/forgejo-runner` | runner 二进制路径 |
| `FTR_VM_PREFIX` | `ftr-job` | 临时 VM 名前缀 |

`scripts/setup.sh` 还支持 `FTR_HOST_IP`、`FTR_ADMIN_USER/PASS`、`FTR_TEST_REPO`、
`FTR_RUNNER_LABELS` 等（见脚本顶部）。

---

## 已验证

在 M4 / macOS 26.1 宿主、Forgejo `15.0.3`、基础镜像 `tahoe-base`(macOS 26.3) 上：

- ✅ `tart clone`（CoW，~0.1s）→ `tart run --no-graphics` 无头启动 → guest agent ~2s 就绪
- ✅ `--dir` 载荷挂载到 VM `/Volumes/My Shared Files/payload`，`tart exec` 远程执行并回传 stdout
- ✅ VM → Forgejo（`192.168.64.1:3000`）API 与 git smart-http 均 `200`
- ✅ runner 以 `one-job --wait` 抓取任务、`host` 后端原生执行、退出
- ✅ `actions/checkout@v4` 在 VM 内真实 `git clone` 出 `forge/mac-ci`
- ✅ `run:` step 原生跑在 `macOS 26.3 / arm64 / node v24.14.0`
- ✅ 连续 2 个 job：均 `success`，**job#1 写入 `/tmp/ftr-prev-job` 未泄漏到 job#2**
  （干净环境断言两次都通过）
- ✅ 每个 job 结束后 `tart delete` 销毁克隆，宿主只剩基础镜像

---

## 已知限制 / 下一步

- **并发。** 当前默认串行（capacity 1，单一 `.runner` 注册）。并发跑多个 VM 需
  给每台 VM 一份独立注册（多个 `.runner`）。注意 Apple Virtualization 单宿主
  **最多 2 台 macOS 客户机** 同时运行。
- **Docker 容器型 action / 服务容器。** 纯 macOS 客户机无 docker，`docker://`
  与 `services:` 跑不了（与 GitHub 官方 macOS runner 限制一致）。需要的话在镜像里
  装 colima/docker。
- **Ephemeral 注册。** Forgejo 15+ 支持 `register --ephemeral`，可让每个 runner
  跑完一个 job 后服务端自动注销。本版用持久注册以求简单稳健，后续可切换。
- **缓存。** v1 关闭了 actions cache（`cache.enabled: false`）。开启后需让 cache
  server 在 VM 内可达。
- **基础镜像构建。** 生产环境建议用 Packer/`image/provision.sh` 维护带工具链的
  黄金镜像，并推送到 OCI registry。

---

## 与现有项目的关系

`sucai/` 下是研究用源码：`forgejo-runner`（内嵌 act 引擎，本项目编译它）、
`forgejo-act`（act 上游 = nektos/act 分支，作参考）、`tart`。本项目本身不修改
runner/act 源码——这正是方案 A 的优势：用 stock runner，全部集成在编排层。
