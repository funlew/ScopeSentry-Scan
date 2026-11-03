# ScopeSentry-Scan 本地启动问题记录

> 记录时间：2026-10-23
> 环境：macOS arm64 / Go 1.24.6 / v1.9.1 (commit `cf9a46e1`)
> 用途：本地联调时发现的问题留档，**未修改任何仓库源码**

---

## P0 — 任务结束时空指针崩溃，导致进程退出

**严重级别**：P0（进程级崩溃，一次任务即可触发，服务不可用）

### 现象

服务端下发的真实任务 `TSRC`（task id `6ada519f795ab3892746567e`）执行完毕时，进程直接 SIGSEGV 退出：

```
[02:17:35] Task end: 6ada519f795ab3892746567e - TSRC
panic: runtime error: invalid memory address or nil pointer dereference
[signal SIGSEGV: segmentation violation code=0x2 addr=0xf8 pc=0x10196344c]

goroutine 335 [running]:
github.com/projectdiscovery/httpx/runner.(*Runner).Close(0x0)
        libs/httpx/runner/runner.go:733 +0x1c
github.com/Autumn-27/ScopeSentry-Scan/pkg/utils.HttpxClose(...)
        pkg/utils/httpxrun.go:144
github.com/Autumn-27/ScopeSentry-Scan/internal/task.OptionClose(...)
        internal/task/handler.go:137
github.com/Autumn-27/ScopeSentry-Scan/internal/task.RunRedisTask()
        internal/task/task.go:246 +0xdb4
```

关键点：`Runner.Close(0x0)` —— 接收者是 **nil**。

### 根因

`pkg/utils/httpxrun.go` 中全局变量 `HttpxRun *runner.Runner` 只在 `InitHttpx()` 成功时才被赋值：

```go
var HttpxRun *runner.Runner   // :17

func InitHttpx(...) {
    ...
    HttpxRun, err = runner.New(&options)
    if err != nil {
        logger.SlogErrorLocal(fmt.Sprintf("httpx get error: %v", err))
        // 注意：err != nil 时 HttpxRun 保持 nil，但函数继续执行完
    }
}

func HttpxClose() {
    HttpxRun.Close()   // :144  ← 无 nil 判断，直接解引用
}
```

而调用链在**每个任务结束时无条件执行**：

```go
// internal/task/task.go:246
OptionClose()          // → internal/task/handler.go:137
                       // → utils.HttpxClose()  ← 崩溃点
```

**关键不对称**：同一文件里的 `RunAnalyze()` 在 `:92` 有 `if HttpxRun == nil` 保护，但 `HttpxClose()` 没有。这是个明显的疏漏。

### 触发条件（实际踩到的那条）

`runner.New()` 初始化失败，本机日志里 **56 次**都是同一个原因：

```
httpx get error: can't find a browser binary for your OS,
the doc might help https://go-rod.github.io/#/compatibility?id=os
: mkdir /Users/getflag/.cache/rod: operation not permitted
```

因为 `InitHttpx` 传了 `Screenshot: true`（任务参数 `AssetMapping` 带 `-screenshot true`），httpx 会去初始化 go-rod 浏览器，而 `~/.cache/rod` 在本沙箱不可写 → `runner.New` 失败 → `HttpxRun == nil` → 任务结束时崩溃。

> **注意**：这不只是沙箱问题。任何导致 httpx 初始化失败的场景（无浏览器、目录不可写、headless 依赖缺失、CI 容器内无 Chrome）都会命中同一个崩溃。**属于代码缺陷，不是环境特有。**

### 复现步骤

1. 让 httpx 初始化失败（例如截图开启但 rod 缓存目录不可写 / 无浏览器内核）
2. 下发任意任务，等待其执行完毕
3. 任务 `Task end` 日志出现后，进程立即 panic 退出

本机实测：02:10:52 任务开始 → 02:17:35 任务结束 → 同一秒崩溃。

### 修复建议（未实施）

**最小修复** —— `pkg/utils/httpxrun.go:143`：

```go
func HttpxClose() {
    if HttpxRun == nil {
        return
    }
    HttpxRun.Close()
}
```

**建议一并处理** —— `InitHttpx` 失败时应显式保持/置空状态并上报，避免后续调用方误以为可用；或让 `runner.New` 失败时降级为 `Screenshot: false` 重试一次。

**根治** —— 截图能力应对浏览器缺失做优雅降级：`Screenshot: true` 但检测不到浏览器时，自动关闭截图而不是整个初始化失败。

---

## P1 — 仓库内 `cmd/ScopeSentry` 无法正常构建

**严重级别**：P1（影响开发/发布流程，但可绕过）

`cmd/ScopeSentry/` 下三个文件同属 `package main`，且**各自都有 `func main()`**：

| 文件 | `main()` 位置 | 性质 |
|---|---|---|
| `main.go` | :40 | 正式入口 |
| `restructure_cmd.go` | :36 | 旧版重构残留 |
| `test_yaegi.go` | :30 | yaegi 试验代码残留 |

直接构建必然报重复定义：

```bash
go build ./cmd/ScopeSentry          # ✗ multiple definition of main
```

`.goreleaser.yaml` 里写的是 `main: ./cmd/ScopeSentry/main.go`（单文件），所以**发布流程是对的**，但 `go build ./...` 和 IDE 会报错。

**建议**：给 `restructure_cmd.go`、`test_yaegi.go` 加 `//go:build ignore`，或移到 `test/` 目录。

**本地绕过方式**（当前采用）：

```bash
go build -o ScopeSentry-Scan ./cmd/ScopeSentry/main.go
```

---

## P1 — 依赖与本机 Go 版本不兼容

**严重级别**：P1（换环境即阻塞）

`github.com/bytedance/sonic v1.14.1` 在 **Go 1.27** 下编译失败：

```
github.com/bytedance/sonic@v1.14.1/internal/rt/stubs.go:33:22:
    undefined: GoMapIterator
```

`go.mod` 声明的是 `go 1.24.0` / `toolchain go1.24.6`。

**建议**：升级 sonic，或在 README/CONTRIBUTING 明确要求 Go 1.24.x。

**本地绕过方式**：

```bash
GOTOOLCHAIN=go1.24.6 go build ...
```

---

## P2 — 内置 darwin 工具为 x86_64，arm64 机器无法执行

**严重级别**：P2（仅影响子域名扫描/爬虫链路）

`tools/darwin/` 下二进制架构不一致：

| 工具 | 架构 | 在 arm64 上 |
|---|---|---|
| `ksubdomain` | **x86_64** | ✗ bad CPU type |
| `katana` | **x86_64** | ✗ bad CPU type |
| `rad` | **x86_64** | ✗ bad CPU type |
| `rustscan` | arm64 | ✓ 正常 |

本机未安装 Rosetta（`arch -x86_64 /usr/bin/true` → `Bad CPU type`）。

直接后果：`ksubdomain.Check()` 在启动时失败，插件状态上报为 `check=0`：

```
[Plugins ksubdomain] check error: KsubdomainVerify failed to start command:
    fork/exec .../ext/ksubdomain/ksubdomain: bad CPU type in executable
```

Redis `NodePlg:<node>` 实际状态（崩溃前实测快照）：**16 个插件中 15 个 check=1，仅 ksubdomain check=0**。

> 注：进程崩溃后 Redis 中的 `node:*` / `NodePlg:*` 键已被清空（疑似服务端或环境重置），上述为崩溃前读到的快照。

**建议**：`tools/darwin/` 换 arm64 版本，或提供 universal binary；README 注明 arm64 需 Rosetta。

---

## P2 — wayback 插件硬编码 `pip install`

**严重级别**：P2（可选依赖，不影响主流程）

`modules/urlscan/wayback/wayback.go:117` 在 `Install()` 里直接：

```go
cmd := exec.Command("pip", "install", "uro")
```

问题：
1. 硬编码 `pip`（很多系统只有 `pip3`）
2. 在无网/受限环境会阻塞或失败
3. 装到用户 site-packages，可能因权限失败

本机实测（沙箱禁写 `~/Library/Python`）：

```
install uro error: exit status 1
ERROR: Could not install packages due to an OSError: [Errno 1]
Operation not permitted: '/Users/getflag/Library/Python/3.9/lib/python/site-packages/uro'
```

代码本身有降级：`uro` 缺失时 `CommandExists("uro")` 为 false，`urlscan/module.go:112` 会跳过去重步骤，**不会崩**。

**建议**：改为 `pip3`、加超时、失败仅告警不阻断。

---

## P3 — 仓库根目录 `ScopeSentryConfig.yaml` 已失效

**严重级别**：P3（误导性，容易被踩）

根目录那份配置文件用的是**大写** key（`Mongodb`、`Redis`、`Username`），但结构体 tag 是**小写**：

```go
// internal/global/type.go
MongoDB  MongoDBConfig `yaml:"mongodb"`   // 小写
Redis    RedisConfig   `yaml:"redis"`     // 小写

type MongoDBConfig struct {
    User string `yaml:"user"`             // 是 user，不是 Username
}
```

YAML 解析是大小写敏感的，用根目录那份文件会**静默读到空值**，然后连不上 Mongo/Redis 且错误信息不明确。

正确格式（本次使用）：

```yaml
NodeName: local-mac-dev
state: 1
TimeZoneName: Asia/Shanghai
debug: true
mongodb:
  ip: 127.0.0.1
  port: "27017"
  user: admin
  password: mongodb_password
  database: ScopeSentry
redis:
  ip: 127.0.0.1
  port: "6379"
  password: redis_password
```

**建议**：删除根目录的 `ScopeSentryConfig.yaml`，或改成正确格式作为模板。

---

## P3 — 其他代码瑕疵（通读时发现，未触发）

| 位置 | 问题 |
|---|---|
| `pkg/utils/result.go:140` | `if old.ContentLength != old.ContentLength` —— 自己和自己比，永假，ContentLength 变化永远检测不到 |
| `modules/passivescan/module.go:62` | `closePlgFunc` 中先取 `plg, flag := GetPlugin(...)`，随后**未判 flag** 就 `plg.SetTaskId(...)`，插件不存在时 nil panic |
| `modules/urlsecurity/trufflehog/trufflehog.go:119,122` | `GetDictId("trufflehog","config")` 查不到记录时返回空串，`filepath.Join(global.DictPath, "")` 得到目录本身，`os.ReadFile` 报 `is a directory`（日志中确实出现该告警）。应在 `id == ""` 时跳过 |

---

## 附：本次可复现的完整启动环境

一切位于 `/tmp/ss-run/`（未污染仓库）：

```
/tmp/ss-run/
├── ScopeSentry-Scan        211MB arm64 二进制
├── start.sh                启动脚本（含 pip shim）
├── config/config.yaml      正确格式配置
├── ext/{katana,ksubdomain,rad,rustscan}/   从 tools/darwin 预拷
├── data/pebbledb/          断点续扫本地库
├── dictionaries/ poc/ plugin/ tmp/        运行时目录
└── run.log                 运行日志
```

构建方式：

```bash
export GOMODCACHE=/tmp/ss-gomod GOCACHE=/tmp/ss-gocache GOPATH=/tmp/ss-gopath
GOTOOLCHAIN=go1.24.6 go build -o /tmp/ss-run/ScopeSentry-Scan ./cmd/ScopeSentry/main.go
```

依赖的本地服务（**未修改**，均为已存在的容器）：

| 服务 | 容器 | 端口 | 凭据 |
|---|---|---|---|
| Redis | `ss-dev-redis` | 6379 | `redis_password` |
| MongoDB | `ss-dev-mongo` | 27017 | `admin` / `mongodb_password` |

`ScopeSentry` 库已有数据：13686 指纹、172 敏感规则、16 插件、1 项目（`ARTEX-TSRC`，`qq.com`/`tencent.com`）、2 字典。

### 已验证可用的部分

- 节点注册 + 20s 心跳（`node:local-mac-dev`）
- 配置全量拉取（字典/POC/指纹/项目/通知/插件）
- 15/16 插件 Install+Check 通过
- 任务全生命周期：`Get a new task` → `Task begin` → 被动扫描 → `Task end` → `Task clean end`
- 队列消费、上下文回收、PebbleDB 清理

### 唯一阻塞项

**P0 崩溃**：跑完一个任务进程就退出，无法持续服务。在修复前，本地只能验证"单个任务"级别的链路。
