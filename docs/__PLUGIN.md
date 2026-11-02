# ScopeSentry-Scan 插件机制

扫描能力全部以插件形式提供：**模块（`module.go`）负责编排**——什么时候调、并发多少、结果送哪；**插件负责扫描**——具体怎么打。两者之间只有 `interfaces.Plugin` 一个契约，插件以服务端下发的 MD5 hash 作为 ID 标识。

设计上分三层：

```
              ┌─────────────────────────────────────────────┐
              │  模块 modules/<模块>/module.go               │
              │  只认 pluginId，不 import 具体插件实现        │
              └───────────────┬─────────────────────────────┘
                              │ GetPlugin(module, id)
              ┌───────────────▼─────────────────────────────┐
              │  注册中心 internal/plugins.PluginManager     │
              │  map[module]map[id]Plugin + RWMutex          │
              └───────┬──────────────────────────┬──────────┘
                      │ 编译期                    │ 运行期
          ┌───────────▼──────────┐   ┌───────────▼──────────────┐
          │ 内置插件              │   │ 自定义插件                │
          │ 手写 struct 实现接口   │   │ .go 源码 → yaegi 解释执行 │
          │ modules/<模块>/<插件>/ │   │ customplugin 适配器包装    │
          └──────────────────────┘   └──────────────────────────┘
```

## 目录

- [1. 契约层](#1-契约层)
- [2. 内置插件](#2-内置插件编译期静态)
- [3. 自定义插件](#3-自定义插件运行期yaegi-解释执行)
- [4. 注册中心](#4-注册中心)
- [5. 取用：懒加载与 Clone](#5-取用懒加载与-clone)
- [6. 一次插件执行的完整链路](#6-一次插件执行的完整链路)
- [7. 远程装卸与生命周期](#7-远程装卸与生命周期)
- [8. 内置插件清单](#8-内置插件清单)
- [9. 自定义插件开发约定](#9-自定义插件开发约定)
- [10. 已知薄弱点](#10-已知薄弱点)

涉及的核心文件：

| 文件 | 作用 |
|---|---|
| `internal/interfaces/plugin.go` | 插件接口定义 |
| `internal/options/plugin.go` | 插件运行时上下文 `PluginOption` |
| `internal/plugins/plugins.go` | 注册中心、内置插件注册、懒加载、状态上报 |
| `internal/plugins/custom.go` | yaegi 解释器加载 `.go` 源码插件 |
| `modules/customplugin/customplugin.go` | 脚本插件 → `interfaces.Plugin` 适配器 |
| `internal/symbols/` | 解释器可用的内部包白名单（`yaegi extract` 生成） |
| `internal/configupdater/plugin.go` | 远程安装 / 删除 / 重装 / 重检 / 卸载 |

---

## 1. 契约层

### 1.1 Plugin 接口

`internal/interfaces/plugin.go:10-32`：

```go
type Plugin interface {
	GetName() string
	SetName(name string)
	GetModule() string
	SetModule(name string)
	GetPluginId() string
	SetPluginId(id string)
	SetCustom(cu interface{})
	GetCustom() interface{}
	SetResult(ch chan interface{})
	SetParameter(args string)
	GetParameter() string
	SetTaskId(id string)
	GetTaskId() string
	SetTaskName(name string)
	GetTaskName() string
	Execute(input interface{}) (interface{}, error)
	Install() error
	Check() error
	UnInstall() error
	Clone() Plugin
	Log(msg string, tp ...string)
}
```

按用途可分为五组：

| 分组 | 方法 | 说明 |
|---|---|---|
| 元信息 | `GetName/SetName`、`GetModule/SetModule`、`GetPluginId/SetPluginId` | 注册表的 key 与展示名 |
| 上下文注入 | `SetTaskId/GetTaskId`、`SetTaskName/GetTaskName` | 让插件能区分任务、写日志与进度 |
| 参数 | `SetParameter/GetParameter` | 服务端下发的字符串参数，由插件自行解析 |
| 数据 | `SetResult(chan)`、`SetCustom/GetCustom`、`Execute(input)` | 结果出口、旁路数据通道、主执行入口 |
| 生命周期 | `Install/Check/UnInstall` | 依赖安装、可用性自检、卸载清理 |
| 并发 | `Clone()` | 返回副本，供多 goroutine 独立使用 |

`Execute(input)` 的入参类型是 `interface{}`，由各模块约定：多数模块传单条资产，`AssetMapping` 传 `[]interface{}`，`PassiveScan` 传 `""` 作为“启动常驻”信号。

### 1.2 PluginOption

内置插件能直接访问自己的字段，脚本插件不行，所以脚本侧改用 `options.PluginOption` 传参：

`internal/options/plugin.go:12-23`：

```go
type PluginOption struct {
	Name       string
	Module     string
	Parameter  string
	PluginId   string
	ResultFunc func(interface{})
	Custom     interface{}
	TaskId     string
	TaskName   string
	Log        func(msg string, tp ...string)
	Ctx        context.Context
}
```

`ResultFunc` 是脚本唯一的产出方式，`Ctx` 让脚本能响应任务取消。该结构由 `customplugin.Plugin.Execute` 组装后传入脚本。

---

## 2. 内置插件（编译期，静态）

位于 `modules/<模块>/<插件名>/`，一个文件内定义自己的 `type Plugin struct` 并逐条实现接口所有方法。以 httpx 为例：

`modules/assetmapping/httpx/httpx.go:32-38`：

```go
func NewPlugin() *Plugin {
	return &Plugin{
		Name:     "httpx",
		Module:   "AssetMapping",
		PluginId: "3a0d994a12305cb15a5cb7104d819623",
	}
}
```

其特征：

- `Module` 与 `PluginId` 在 `NewPlugin()` 里硬编码，必须与注册中心的 key 完全一致；
- 十余个 setter/getter 是纯字段读写，属于模板化重复代码；
- SDK 类插件（httpx、nuclei、fingerprintx、trufflehog）的 `Install/Check/UnInstall` 通常直接 `return nil`；
- 外部二进制类插件（rustscan、katana、rad、ksubdomain）在 `Install()` 里下载二进制到 `ext/` 并 `chmod 0755`，`Check()` 校验文件存在，这是“Install/Check”真正起作用的场景；
- 结果直接写模块给的通道：`p.Result <- asset`。

内置插件的 `Clone()` 一般只复制少数字段，例如 httpx 只带 `Name/Module/PluginId/Custom/TaskId`，不复制 `Result` 与 `Parameter`——因此模块侧必须遵循“先 `Clone`，再 `SetResult`/`SetParameter`”的顺序。

---

## 3. 自定义插件（运行期，yaegi 解释执行）

服务端把 Go 源码存进 MongoDB `plugins` 集合（`{module, hash, source}`），节点落盘到 `plugin/<module>/<hash>.go` 后用 [yaegi](https://github.com/traefik/yaegi) **解释执行**，全程不编译、不重启。

### 3.1 加载过程

`internal/plugins/custom.go:65-126` 的 `LoadCustomPlugin(path, module, plgId)`：

1. `interp.New(interp.Options{})` 创建解释器；
2. `interp.Use(stdlib.Symbols)` 注入标准库；
3. `interp.Use(symbols.Symbols)` 注入本项目 14 个内部包的符号表；
4. 额外补注册 `os/exec`；
5. `interp.EvalPath(path)` 执行脚本文件；
6. 依次 `interp.Eval("plugin.Execute")`、`plugin.GetName`、`plugin.Install`、`plugin.Check`、`plugin.Uninstall`、`plugin.SetCustom`，用类型断言取出函数值；
7. 交给 `customplugin.NewPlugin(...)` 包装成 `interfaces.Plugin`。

其中 `plugin` 是脚本里的一个包级变量名，脚本必须提供如下符号：

```go
var plugin = &MyPlugin{}          // 名字固定为 plugin

func (p *MyPlugin) Execute(input interface{}, op options.PluginOption) (interface{}, error)
func (p *MyPlugin) GetName() string
func (p *MyPlugin) Install() error
func (p *MyPlugin) Check() error
func (p *MyPlugin) Uninstall() error   // 注意拼写是 Uninstall，全小写 n
func (p *MyPlugin) SetCustom(v interface{})  // 可选
```

`SetCustom` 缺失时不报错，`customplugin` 会把它退化成空函数，代价是旁路数据（PassiveScan）无法送达脚本。

### 3.2 适配器

`modules/customplugin/customplugin.go` 用函数指针字段补全接口：`InstallFunc/CheckFunc/UnInstallFunc/ExecuteFunc/GetNameFunc/SetCustomFunc`。`Execute` 时把宿主能力封装进 `PluginOption`：

`modules/customplugin/customplugin.go:125-146`：

```go
func (p *Plugin) Execute(input interface{}) (interface{}, error) {
	resultFunc := func(res interface{}) {
		p.Result <- res
	}
	op := options.PluginOption{
		Name:       p.GetName(),
		Module:     p.GetModule(),
		Parameter:  p.GetParameter(),
		PluginId:   p.GetPluginId(),
		ResultFunc: resultFunc,
		Custom:     p.Custom,
		TaskId:     p.TaskId,
		TaskName:   p.GetTaskName(),
		Log:        p.Log,
		Ctx:        contextmanager.GlobalContextManagers.GetContext(p.GetTaskId()),
	}
	if p.ExecuteFunc == nil {
		p.Log("error exec is nil", "e")
		return nil, nil
	}
	return p.ExecuteFunc(input, op)
}
```

于是脚本里 `op.ResultFunc(asset)` 与内置插件的 `p.Result <- asset` 完全等价，日志统一走 `op.Log`（内部转 `logger.PluginsLog`，批量推 Redis）。

### 3.3 可用的内部包

`internal/symbols/symbols.go` 顶部用 `go:generate yaegi extract` 声明白名单，覆盖：

`logger`、`utils`、`options`、`bigcache`、`config`、`contextmanager`、`global`、`interfaces`、`mongodb`、`notification`、`pool`、`redis`、`results`、`types`

共 14 个包，对应 14 个自动生成的 `github_com-Autumn-27-ScopeSentry-Scan-*.go` 符号表文件。**新增内部包供插件使用时，必须重新执行 `go generate ./internal/symbols` 并提交生成文件**，否则脚本 `import` 会失败。标准库默认全部可用，但 `os/exec` 需要额外显式注册。

---

## 4. 注册中心

`internal/plugins/plugins.go:42-47`：

```go
type PluginManager struct {
	plugins map[string]map[string]interfaces.Plugin // 存储插件，按模块和名称索引
	mu      sync.RWMutex
}

var GlobalPluginManager *PluginManager
```

### 4.1 初始化

`main.go:111` 调用 `plugins.GlobalPluginManager.InitializePlugins()`，函数内部做三件事：

**(1) 硬编码注册 17 个内置插件**

```go
targetparserPlugin := targetparser.NewPlugin()
pm.RegisterPlugin("TargetHandler", targetparserPlugin.PluginId, targetparserPlugin)
subfinderPlugin := subfinder.NewPlugin()
pm.RegisterPlugin(subfinderPlugin.Module, subfinderPlugin.PluginId, subfinderPlugin)
// ... 共 17 个
```

**(2) 扫描 `plugin/` 目录加载自定义插件**

`GetCustomPlugin()` 用 `filepath.WalkDir` 遍历 `global.PluginDir`，对每个文件取「父目录名 = module」「去扩展名的文件名 = pluginId」，逐个 `LoadCustomPlugin` 后注册。这就是自定义插件必须放在 `plugin/<module>/<hash>.go` 的原因。

**(3) 统一 Install → Check 并上报状态**

`internal/plugins/plugins.go:206-240`：

```go
	nodePlgInfokey := fmt.Sprintf("NodePlg:%v", global.AppConfig.NodeName)
	for module, plugins := range pm.plugins {
		for name, plugin := range plugins {
			plgInfo := map[string]interface{}{
				plugin.GetPluginId() + "_install": 0,
				plugin.GetPluginId() + "_check":   0,
			}
			if err := plugin.Install(); err != nil {
				redis.RedisClient.HMSet(context.Background(), nodePlgInfokey, plgInfo)
				continue
			}
			plgInfo[plugin.GetPluginId()+"_install"] = 1
			if err := plugin.Check(); err != nil {
				redis.RedisClient.HMSet(context.Background(), nodePlgInfokey, plgInfo)
				continue
			}
			plgInfo[plugin.GetPluginId()+"_check"] = 1
			redis.RedisClient.HMSet(context.Background(), nodePlgInfokey, plgInfo)
		}
	}
```

状态写入 Redis Hash `NodePlg:<nodeName>`，字段为 `<pluginId>_install` 与 `<pluginId>_check`。实际只会出现三种组合：

| install / check | 含义 |
|---|---|
| `0 / 0` | 安装失败（或未安装） |
| `1 / 0` | 安装成功，检查失败 |
| `1 / 1` | 安装且检查均成功 |

源码注释声明了 0~4 五种状态（含“安装成功未检查”等），但实现并未使用 2/3/4，服务端若按五态解析会与实际值不符。

---

## 5. 取用：懒加载与 Clone

模块从不 import 具体插件，只拿 ID 来要实例。这是整个机制的核心函数，`internal/plugins/plugins.go:74-107`：

```go
func (pm *PluginManager) GetPlugin(module, id string) (interfaces.Plugin, bool) {
	pm.mu.RLock()
	defer pm.mu.RUnlock()

	if modPlugins, ok := pm.plugins[module]; ok {
		plugin, ok := modPlugins[id]
		if ok {
			return plugin.Clone(), ok // 返回新实例
		} else {
			// 插件未注册成功
			plg, err := LoadCustomPlugin(filepath.Join(global.PluginDir, module, fmt.Sprintf("%v.go", id)), module, id)
			if err != nil {
				err = LoadPlugFromDB(id)
				if err != nil {
					logger.SlogErrorLocal(err.Error())
					return nil, false
				}
				plg, err = LoadCustomPlugin(filepath.Join(global.PluginDir, module, fmt.Sprintf("%v.go", id)), module, id)
				if err != nil {
					logger.SlogErrorLocal(err.Error())
					return nil, false
				}
			}
			pm.UnSafeRegisterPlugin(module, id, plg)
			err = plg.Install()
			if err != nil {
				logger.SlogErrorLocal(err.Error())
				return nil, false
			}
			return plg.Clone(), true
		}
	}
	return nil, false
}
```

三个要点：

**（1）三级降级取插件**

```
内存注册表
  └ 未命中 → plugin/<module>/<id>.go 本地加载
      └ 失败 → MongoDB plugins 集合按 hash 取源码写盘 → 再加载
```

所以服务端新增插件后，即使没有下发安装指令，节点执行到该 ID 时也会自行补齐。

**（2）`module` 键必须已存在**

外层 `if modPlugins, ok := pm.plugins[module]; ok` 不成立时直接返回 `(nil, false)`，连懒加载都不会尝试。这解释了两条硬约束：自定义插件必须建在 `plugin/<已注册模块名>/` 子目录下；模块名必须是那 17 个之一。

**（3）`Clone()` 是并发隔离手段**

同一个插件会被成百上千个目标并发使用。返回副本后，每个 goroutine 各自持有独立的 `Result` 通道、`Parameter`、`TaskId`，结果不会串到别的任务。代价是副本不带运行时状态，**必须"先 Clone，再 Set 参数与通道"**，顺序反了就是向 nil channel 写入、永久阻塞。

`Clone` 未复制 `Result`/`Parameter`/`TaskName` 这一点，对 `PassiveScan` 尤其微妙：该模块每推一条数据都重新 `GetPlugin` 拿新副本再 `SetCustom(data)`，而常驻循环是在另一个副本上 `Execute("")` 启动的。因此脚本插件若要在 `SetCustom` 与常驻逻辑之间共享状态，只能把它放在包级变量或全局单例里，不能依赖实例字段。

---

## 6. 一次插件执行的完整链路

以 `AssetMapping`（httpx）为例，模块每收到一批数据，遍历任务下发的插件列表：

`modules/assetmapping/module.go:159-199`（节选）：

```go
for _, pluginId := range r.Option.AssetMapping {
	var plgWg sync.WaitGroup
	plg, flag := plugins.GlobalPluginManager.GetPlugin(r.GetName(), pluginId)
	if flag {
		plgWg.Add(1)
		args, argsFlag := utils.Tools.GetParameter(r.Option.Parameters, r.GetName(), plg.GetPluginId())
		if argsFlag {
			plg.SetParameter(args)
		} else {
			plg.SetParameter("")
		}
		plg.SetResult(resultChan)
		plg.SetTaskId(r.Option.ID)
		plg.SetTaskName(r.Option.TaskName)
		pluginFunc := func(assets interface{}) func() {
			return func() {
				defer plgWg.Done()
				select {
				case <-contextmanager.GlobalContextManagers.GetContext(r.Option.ID).Done():
					return
				default:
					_, err := plg.Execute(assets)
					...
				}
			}
		}(data)
		err := pool.PoolManage.SubmitTask(r.GetName(), pluginFunc)
		...
		plgWg.Wait()
	}
}
```

串成时序：

```
服务端任务 JSON
  │  含各模块 pluginId 列表 + Parameters
  ▼
TaskOptions{ AssetMapping []string, PassiveScan []string, Parameters map[module]map[pluginID]string }
  ▼
模块 ModuleRun 收到一条数据
  ├ 按任务类型直通或丢弃（switch data.(type)）
  ├ 遍历本模块的 pluginId 列表
  │   ├ GetPlugin(module, pluginID) → Clone 副本
  │   ├ GetParameter(Parameters, module, pluginID) → SetParameter
  │   ├ SetResult(resultChan) / SetTaskId / SetTaskName
  │   ├ pool.SubmitTask(module, fn)   ← ants 池，按模块限流
  │   │    └ plg.Execute(input)
  │   │         ├ 内置插件：p.Result <- 结果
  │   │         └ 脚本插件：op.ResultFunc(结果)
  │   └ plgWg.Wait()   ← 每个插件之间串行等待
  └ resultChan → 结果 goroutine → 去重/加工 → NextModule.GetInput()
```

几个关键设计：

- **参数外置**：`Parameters` 是 `map[module]map[pluginID]string`，随任务下发，插件代码本身不含配置。同一份插件可被不同任务用不同线程数、超时、字典驱动。
- **按模块限流**：`pool.PoolManage` 为每个模块名单独建 ants 池，池大小来自 `config/modules.yaml` 的 `goroutineCount`，服务端可热更新。
- **两级并发**：模块级 goroutine 处理单条数据，插件调用再进池；`plgWg.Wait()` 使同一批内的多个插件串行，避免 SDK 并发冲突。
- **取消传播**：每次 `Execute` 前 select 任务 context，任务停止后不再发起新的插件调用；插件内部也可通过 `op.Ctx` 主动退出。
- **结果回传**：统一写模块内共享的 `resultChan`（容量 500），由独立 goroutine 消费并投给下游，插件与模块之间没有任何直接依赖。

`PassiveScan` 是例外，它用另一套约定：

`modules/passivescan/module.go:44-71`、`90-99`：

```go
plg, flag := plugins.GlobalPluginManager.GetPlugin(r.GetName(), pluginId)
go func() {
	plg.SetTaskId(r.Option.ID)
	plg.SetTaskName(r.Option.TaskName)
	_, err := plg.Execute("")     // "" 表示启动常驻
}()

// 收尾
plg.SetCustom("close task")

// 数据推送
plg.SetCustom(data)
```

即“`Execute("")` 启动常驻 → `SetCustom(data)` 灌数据 → `SetCustom("close task")` 结束”，复用 `SetCustom` 而不新增接口方法。

---

## 7. 远程装卸与生命周期

服务端通过 Redis 列表 `refresh_config:<node>` 下发指令，`configupdater.RefreshConfig()` 每 3 秒 `BatchGetAndDelete` 消费并分发到 `internal/configupdater/plugin.go`：

| 指令 | 函数 | 行为 | 是否动注册表 |
|---|---|---|---|
| 安装 | `InstallPlugin(id)` | Mongo 按 ObjectID 取源码 → 写 `plugin/<module>/<hash>.go` → yaegi 加载 → `RegisterPlugin` → `Install`/`Check` → 回写 `NodePlg` | 是（新增） |
| 删除 | `DeletePlugin(hash_module)` | `UnInstall()` → 删除本地 `.go` → `HDel` 状态位 | **否** |
| 重装 | `ReInstall(hash_module)` | 仅重跑 `Install()`，不重新拉源码 | 否 |
| 重检 | `ReCheck(hash_module)` | 仅重跑 `Check()` | 否 |
| 卸载 | `Uninstall(hash_module)` | 仅调 `UnInstall()`，保留文件与注册 | 否 |

插件分发全程走数据面，节点无需重启、无需重新编译、无需重新部署。但要注意 `DeletePlugin` 只删文件与 Redis 字段，并未 `delete(pm.plugins[module], hash)`，内存中的旧实例仍然可被 `GetPlugin` 取到并执行，直到进程重启。

`InstallPlugin` 的幂等性由调用方保证：重复下发同一 ID 时，`RegisterPlugin` 会直接覆盖旧 map 项，但旧实例的 `UnInstall` 不会被调用。

---

## 8. 内置插件清单

`InitializePlugins()` 注册的 17 个插件，PluginId 为服务端识别用的固定 hash：

| 模块（注册名） | 插件 | PluginId | 说明 |
|---|---|---|---|
| `TargetHandler` | targetparser | `7bbaec6487f51a9aafeff4720c7643f0` | 目标规范化 |
| `SubdomainScan` | subfinder | `d60ba73c70aac430a0a54e796e7e19b8` | 被动子域名 |
| `SubdomainScan` | ksubdomain | `e8f55f5e0e9f4af1ca40eb19048b8c82` | 子域名爆破（外部二进制） |
| `SubdomainSecurity` | subdomaintakeover | `c0c71c101271f38b8be1767f3626d291` | 子域名接管 |
| `PortScanPreparation` | skipcdn | `9b91e0f18ac9043ec9fe250a39b4a2d9` | CDN/WAF 跳过 |
| `PortScan` | rustscan | `66b4ddeb983387df2b7ee7726653874d` | 端口扫描（外部二进制） |
| `PortFingerprint` | fingerprintx | `648a6f49eed57b1737ac702e02985b00` | TCP 协议指纹 |
| `AssetMapping` | httpx | `3a0d994a12305cb15a5cb7104d819623` | HTTP 存活与信息提取 |
| `AssetHandle` | webfingerprint | `80718cc3fcb4827d942e6300184707e2` | Web 指纹（不入库，仅打标） |
| `URLScan` | katana | `9669d0dcc52a5ca6dbbe580ffc99c364` | 主动爬取（外部二进制） |
| `URLScan` | wayback | `ef244b3462744dad3040f9dcf3194eb1` | 历史 URL 三源 |
| `WebCrawler` | rad | `4b292861d3228af0e4da8e7ef979497c` | 爬虫（外部二进制） |
| `URLSecurity` | sensitive | `2949994c04a4e124b9c98383489510f0` | 敏感信息正则 |
| `URLSecurity` | trufflehog | `1aa212b9578dc3fb1409ee8de8ed005e` | 密钥泄露 |
| `URLSecurity` | pagemonitoring | `e52b8b16d49912ca564c22319c495403` | 页面变动监控 |
| `DirScan` | sentrydir | `920546788addc6d29ea63e4a314a1b85` | 自研目录扫描 |
| `VulnerabilityScan` | nuclei | `ed93b8af6b72fe54a60efdb932cf6fbc` | 漏洞扫描 |

命名上有一处不一致需要留意：**模块注册名是全大写的 `URLScan` / `URLSecurity`**（`NewPlugin()` 的 `Module` 字段与 `Runner.GetName()` 均为全大写），而流水线 `InputChan` 的 key 用的是 `"UrlScan"` / `"UrlSecurity"`（`modules/manage.go:51` 等）。两者用途不同——前者用于插件查找，后者仅作通道索引——因此不会冲突，但排查时容易混淆。

---

## 9. 自定义插件开发约定

| 项 | 约定 |
|---|---|
| 存放位置 | `plugin/<模块名>/<插件ID>.go`，模块名必须是上表 17 个之一 |
| 文件名 | 即插件 ID，服务端以 hash 命名 |
| 包级变量 | 必须为 `plugin`，是 yaegi 的 `Eval` 目标 |
| 必须实现 | `Execute(input interface{}, op options.PluginOption) (interface{}, error)`、`GetName() string`、`Install() error`、`Check() error`、`Uninstall() error` |
| 可选实现 | `SetCustom(interface{})`，缺失时退化为空函数 |
| 结果输出 | 只能通过 `op.ResultFunc(v)`，没有其他出口 |
| 日志 | 用 `op.Log(msg, "i"/"w"/"e")`，会带模块与插件 ID 批量进 Redis |
| 取消 | `op.Ctx.Done()`，任务停止后应尽快返回 |
| 参数 | `op.Parameter` 为原始字符串，自行 parse |
| 可 import | 标准库 + 第 3.3 节列出的 14 个内部包 |

注意 `Uninstall` 的方法名是全小写 `n`，与内置插件接口里的 `UnInstall`（大写 I）不同——`LoadCustomPlugin` 是按字符串 `"plugin.Uninstall"` 取值的，拼错会导致整个插件加载失败。

---

## 10. 已知薄弱点

读代码可见的几处问题，当前能跑但脆弱：

1. **`GetPlugin` 在读锁里写 map**
   `pm.mu.RLock()` 持有期间调用 `UnSafeRegisterPlugin` 增删 `pm.plugins[module]`。并发场景下可能触发 `fatal error: concurrent map read and map write`（不可 recover）。正确做法是加载与 Install 完成后释放读锁、改用写锁注册。

2. **`DeletePlugin` 不清理注册表**
   只 `HDel` Redis 并删文件，`pm.plugins[module][hash]` 仍在内存，旧实例继续可被取到执行。

3. **安装失败不阻断调用**
   `InitializePlugins` 中 `Install()` 失败仅 `continue`，插件仍留在表内；`GetPlugin` 返回的 `Clone` 也不会重跑 `Install`，运行期可能缺依赖或外部二进制。

4. **状态位注释与实现不符**
   注释声明 0~4 五态，实际只写 `0/0`、`1/0`、`1/1`，服务端按五态解析会误判。

5. **`Clone` 语义依赖调用顺序**
   副本不带 `Result`/`Parameter`，必须“先 Clone 再 Set”。`PassiveScan` 每次取新副本 `SetCustom` 的设计，使脚本插件只能靠包级变量共享状态，实例字段会被丢弃。

6. **`LoadCustomPlugin` 的遮蔽与错误吞没**
   `interp := interp.New(interp.Options{})` 让局部变量遮蔽了包名；`interp.Use(...)` 的返回值被后续语句覆盖，符号加载失败会被静默忽略。

7. **解释执行的性能与共享函数**
   每次 `GetPlugin` 返回的副本共享同一个 `ExecuteFunc`（解释器里的函数值），高并发下同一脚本函数被多 goroutine 同时调用。yaegi 对此不提供强保证，自定义插件应避免在函数内使用闭包级可变状态，或自行加锁。

8. **`Execute` 错误被吞**
   多数模块写成 `_, err := plg.Execute(...)` 后不做任何处理（`modules/assetmapping/module.go:183-186` 即空分支），插件内部错误不会上报服务端，只能从日志侧观察。
