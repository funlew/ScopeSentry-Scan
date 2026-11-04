# 扫描端本地开发（Docker Compose）

扫描端只消费 Redis 里的任务、从 MongoDB 拉配置，**没有服务端就跑不起来**：
`config/modules.yaml` 由服务端初始化数据库后下发，缺失时进程在 `ModulesInitialize()` 直接退出
（`Failed to init ModulesConfig: open /apps/config/modules.yaml: no such file or directory`）。

所以本地开发顺序是固定的：**先服务端栈，再扫描端**。

```bash
# 1) 服务端 + MongoDB + Redis（创建共享网络 scopesentry-dev）
cd ../ScopeSentry
docker compose -f docker-compose.dev.yml up -d --build

# 2) 扫描端
cd ../ScopeSentry-Scan
docker compose -f docker-compose.dev.yml up -d --build
```

文档：服务端侧见 `../ScopeSentry/docs/LOCAL-DEV.md`。

---

## 1. 组成

| 项 | 值 |
|---|---|
| 镜像 | 本仓库 `Dockerfile.dev`（golang:1.24 + chromium + uro + air + dlv） |
| 网络 | 外部网络 `scopesentry-dev`（由服务端 compose 创建） |
| 端口 | `6060` pprof、`2346` delve（宿主 2345 已被服务端占用） |
| 中间件 | 服务名 `mongodb:27017`、`redis:6379` |
| 节点名 | `NodeName`，默认 `local-docker-dev` |

启动成功的标志：

```bash
docker compose -f docker-compose.dev.yml logs -f scan | grep -E "Register Success|Task end"
# Register Success:local-docker-dev - version 1.9.1
```

此时服务端 Web 的节点列表会出现该节点，模块并发来自服务端下发的 `modules.yaml`。

---

## 2. 运行目录与卷

扫描端以**可执行文件所在目录**为运行根（`internal/config/config.go:128`），容器内固定 `/apps`：

| 卷 | 容器路径 | 内容 |
|---|---|---|
| `scopesentry-dev_scan-config` | `/apps/config` | `config.yaml`、`modules.yaml`（服务端下发）、`subfinderConfig.yaml` |
| `scopesentry-dev_scan-data` | `/apps/data` | PebbleDB 断点续扫 |
| `scopesentry-dev_scan-dictionaries` | `/apps/dictionaries` | 字典 |
| `scopesentry-dev_scan-ext` | `/apps/ext` | katana / ksubdomain / rad / rustscan |
| `scopesentry-dev_scan-poc` | `/apps/poc` | Nuclei POC |
| `scopesentry-dev_scan-plugin` | `/apps/plugin` | 自定义插件源码 |
| `scopesentry-dev_scan-tmp` | `/apps/tmp` | URL 暂存 |
| `scopesentry-dev_go-mod` / `_go-build` | `/go/pkg/mod`、`/root/.cache/go-build` | 依赖与编译缓存 |

全部清空：`docker compose -f docker-compose.dev.yml down -v`。

**不要把宿主目录挂到 `/apps`**，会覆盖镜像内的可执行文件。

---

## 3. 配置优先级（与服务端相反，最容易踩）

`internal/config/config.go` 只在 `config.yaml` **不存在时**才读环境变量：

```39:49:internal/config/config.go
		global.AppConfig = global.Config{
			NodeName:     getEnv("NodeName", ""),
			...
```

因此改了 compose 里的 `NodeName` / 连接信息后：

```bash
docker compose -f docker-compose.dev.yml exec scan rm /apps/config/config.yaml
docker compose -f docker-compose.dev.yml restart scan
```

`modules.yaml` 属于服务端下发产物，不要手改，重启后会重新拉取。

仓库根目录的 `ScopeSentryConfig.yaml` 是**大写 key 的失效模板**（结构体 tag 是 `NodeName` / `mongodb` / `redis`），不要用。

---

## 4. 热重载

`.air.toml`：源码变更 → `go build -o /apps/ScopeSentry-Scan ./cmd/ScopeSentry/main.go` → 重启进程。

- 监控：`cmd/`、`internal/`、`modules/`、`pkg/` 下的 `.go`、`.yaml`
- 排除：`libs/`、`test/`、`tools/`、`docs/` 等；**改 `libs/` 需手动重启**
- 必须指定单文件：`cmd/ScopeSentry/` 下 `main.go`、`restructure_cmd.go`、`test_yaegi.go` 各有 `func main()`
- `exclude_unchanged` 已开启，`touch` 不会触发重建

```bash
docker compose -f docker-compose.dev.yml restart scan          # 改了 .air.toml / libs 时
docker compose -f docker-compose.dev.yml exec scan air -c /src/.air.toml -b   # 手动编译一次
```

---

## 5. 调试

### 5.1 pprof

`DEBUG=true`（compose 默认）时监听 `0.0.0.0:6060`（`cmd/ScopeSentry/main.go:150`）：

```bash
go tool pprof http://127.0.0.1:6060/debug/pprof/heap
go tool pprof http://127.0.0.1:6060/debug/pprof/profile?seconds=30
```

### 5.2 Delve

```bash
docker compose -f docker-compose.dev.yml stop scan

docker compose -f docker-compose.dev.yml run --rm --service-ports scan \
  sh -c 'go build -gcflags="-N -l" -o /apps/ScopeSentry-Scan.dbg ./cmd/ScopeSentry/main.go \
         && exec dlv --headless --listen=:2345 --api-version=2 --accept-multiclient exec /apps/ScopeSentry-Scan.dbg'
```

`-gcflags="-N -l"` 只影响本项目包（约 10 秒，依赖复用缓存）；要单步进 `libs/` 里的第三方代码，
换成 `-gcflags="all=-N -l"`，首次会重编全部依赖，明显更慢。

宿主侧连 `127.0.0.1:2346`（容器内仍是 2345）。VS Code：

```json
{
  "version": "0.2.0",
  "configurations": [
    {
      "name": "Attach to scan (docker)",
      "type": "go",
      "request": "attach",
      "mode": "remote",
      "remotePath": "/src",
      "port": 2346,
      "host": "127.0.0.1",
      "substitutePath": [{ "from": "${workspaceFolder}", "to": "/src" }]
    }
  ]
}
```

调试完 `docker compose -f docker-compose.dev.yml start scan` 恢复热重载。

> 不要让 `dlv debug` / `go run` 直接跑：二进制会落在临时目录，运行根（config/data/ext）随之错位。

---

## 6. 常见问题

| 现象 | 原因 / 处理 |
|---|---|
| `network scopesentry-dev declared as external, but could not be found` | 服务端栈没起。先 `cd ../ScopeSentry && docker compose -f docker-compose.dev.yml up -d` |
| `Failed to init ModulesConfig: ... modules.yaml` | 服务端数据库尚未初始化完成，或指向了空的 Mongo。等 `Starting server` 出现后 `restart scan` |
| `exec format error`，ksubdomain/katana/rad 插件 `check=0` | `tools/linux` 全是 x86-64，原生 arm64 容器跑不了。需要时用 `-f docker-compose.dev-amd64.yml` 走模拟 |
| 切架构后插件仍报错 | `scan-ext` 卷残留上一架构二进制：`docker volume rm scopesentry-dev_scan-ext` |
| 改了 `.env` / compose 里的 IP 密码没反应 | 见第 3 节，`config.yaml` 已存在 |
| 节点在线但没有任务 | 服务端里没有项目/任务；在 8082 建任务后节点 3 秒内领取 |
| 任务结束进程直接退出（SIGSEGV） | 已知 P0：`HttpxClose()` 未判 nil（`pkg/utils/httpxrun.go:143`），任务跑完必崩，`restart: "no"` 便于保留现场 |
| 首次构建卡在 `go: downloading` | `GOPROXY=https://proxy.golang.org,direct docker compose -f docker-compose.dev.yml build --no-cache scan` |
| air 报 air/dlv 编译失败 | 版本需兼容 Go 1.24，构建参数 `--build-arg AIR_VERSION=vX.Y.Z` 覆盖 |

---

## 7. 发布前验证

容器内是宿主架构产物，上线前用线上 `dockerfile`：

```bash
GOTOOLCHAIN=go1.24.6 CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
  go build -o dist/ScopeSentry-Scan_linux_amd64_v1/ScopeSentry-Scan ./cmd/ScopeSentry/main.go

docker build --platform linux/amd64 -t scopesentry-scan:dev .
```

`dockerfile:24` 硬编码 goreleaser 产物路径 `dist/ScopeSentry-Scan_linux_amd64_v1/`。

---

## 8. 只用依赖、程序跑宿主（最快循环）

中间件仍用 compose 起（注意此时不启动服务端容器也可以，但扫描端需要服务端至少跑过一次以写入 `modules.yaml`）：

```bash
cd ../ScopeSentry
docker compose -f docker-compose.dev.yml up -d mongodb redis
```

```bash
mkdir -p /tmp/ss-run && cd ../ScopeSentry-Scan
GOTOOLCHAIN=go1.24.6 go build -o /tmp/ss-run/ScopeSentry-Scan ./cmd/ScopeSentry/main.go

cd /tmp/ss-run
MONGODB_IP=127.0.0.1 MONGODB_PORT=27017 MONGODB_DATABASE=ScopeSentry \
MONGODB_USER=admin MONGODB_PASSWORD=mongodb_password \
REDIS_IP=127.0.0.1 REDIS_PORT=6379 REDIS_PASSWORD=redis_password \
DEBUG=true NodeName=local-mac-dev ./ScopeSentry-Scan
```

`build/.env` 里的 `127.0.0.1` 只对宿主视角成立，容器内必须用服务名。
