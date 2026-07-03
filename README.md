# Spring Cloud Gateway (Spring MVC) 文件上传：流式转发 Demo + 偶发 413 根因分析

*中文 | [English](README.en.md)*

围绕 **servlet 版**（Spring MVC）Spring Cloud Gateway 的文件上传，本仓库有两条
相互关联的线索：

1. **流式上传 demo**（`gateway/` + `backend/`）：证明 servlet 版网关能以
   **流式（streaming）**方式转发文件上传 —— 上传体积可以远超进程堆内存，全程不会
   把整个文件缓冲进内存。
2. **偶发 413 根因分析**（`k8s-repro/` + `docs/`）：一个真实生产问题的完整复现、
   定位与验证 —— 经网关的文件上传**偶发** `413 PAYLOAD_TOO_LARGE`，1 个网关 pod
   从不出现、3 个 pod 才出现。根因是 **h2c upgrade + JDK HttpClient +
   Tomcat `maxSavePostSize`** 三者叠加，与「文件太大」无关。见
   [§ 偶发 413 排查](#偶发-413-排查h2c-upgrade)。

> 之所以专门验证 MVC 版流式：servlet 网关历史上比 reactive 版更容易“把请求体整体
> 缓冲到内存再转发”（参见 [spring-cloud-gateway#3479](https://github.com/spring-cloud/spring-cloud-gateway/issues/3479)，
> 2024-07 报告的 `FastByteArrayOutputStream` OOM）。本 demo 证明在
> **Spring Boot 3.5 / Spring Cloud 2025.0.x** 上该问题已不复存在。

## 实测结果

两个 JVM 都用 `-Xmx128m`，通过网关上传 **1 GB**（=8× 堆）：

```
==> POST 1024 MB through the gateway (:8080) -> backend (:8081)
{"bytesReceived":1073741824,"megabytesReceived":"1024.0","elapsedMillis":1015,
 "jvmMaxHeapMB":128,"jvmUsedHeapMB":25,"bufferSizeKB":64,
 "note":"Streamed in 64KB chunks; bytesReceived may greatly exceed jvmMaxHeapMB."}
==> PASS: both JVMs survived with -Xmx128m while a 1024 MB body streamed through.
```

`bytesReceived = 1 GB` 而 `jvmUsedHeapMB = 25`、`jvmMaxHeapMB = 128` —— 全程只占用
了一个 64 KB 拷贝缓冲区级别的内存。

## 架构

```
 curl -T file (从磁盘流式读取)
        │  POST /upload   Content-Type: application/octet-stream
        ▼
 ┌──────────────────────┐   chunked (无 Content-Length)   ┌──────────────────────┐
 │  gateway  :8080       │ ───────────────────────────────▶ │  backend  :8081       │
 │  Spring Cloud Gateway │   POST /upload                    │  Spring MVC           │
 │  Server MVC (servlet) │                                   │  读 InputStream 计数   │
 └──────────────────────┘                                   └──────────────────────┘
```

- **gateway**：`spring-cloud-starter-gateway-server-webmvc`。一条路由
  `POST /upload -> http://localhost:8081`，纯代理，不解析请求体。
- **backend**：`spring-boot-starter-web`。按 64 KB 分块读取 `request.getInputStream()`
  并丢弃，只累加字节数，绝不缓存整个 body。

## 为什么是流式的（源码依据，基于 gateway 4.3.x / Spring Framework 6.2.x）

整条链路上没有任何一处会把整个 body 收进 `byte[]`：

1. **入站不解析 multipart**：网关按原始字节代理，直接读取 Tomcat 的 servlet
   `InputStream`（Tomcat 从 socket 分块读，不整体缓冲）。demo 里发送的是
   `application/octet-stream` 原始二进制，两端都设了
   `spring.servlet.multipart.enabled=false`，确保走纯流式 InputStream。
2. **网关向下游写 body 时是流式的**：默认的 `RestClientProxyExchange` 用
   `restClient.body(outputStream -> StreamUtils.copy(servletInputStream, outputStream))`
   把入站流直接拷给下游请求的输出流。
3. **底层 HTTP 客户端不缓冲**：本 demo classpath 上只有 JDK，网关选用 JDK
   `HttpClient`。Spring 的 `JdkClientHttpRequest extends AbstractStreamingClientHttpRequest`，
   通过 `OutputStreamPublisher` 把写入桥接成带背压的 `BodyPublishers.fromPublisher(...)`
   —— 边读边发，不落地成数组。
4. **默认移除 Content-Length**：网关默认启用 `RemoveContentLengthRequestHeadersFilter`，
   于是下游请求走 **chunked transfer-encoding**，无需预先知道长度，天然支持流式。
5. **下游消费也是流式的**：backend 循环 `read(buffer)` 后丢弃，内存占用与文件大小无关。

## 运行

需要 JDK 25 与 Maven（工程编译目标为 Java 25）。

### 一键验证（脚本）

```bash
./run-demo.sh
# 自定义：更小堆 / 更大文件，反差更明显
HEAP=96m SIZE_MB=2048 ./run-demo.sh
```

脚本会：编译 → 用 `-Xmx128m -XX:+ExitOnOutOfMemoryError` 启动两个服务 →
生成一个远大于堆的文件 → 经网关上传 → 打印结果 → 清理进程与临时文件。
只要有任何一处缓冲整个 body，就会 OOM 并让 JVM 退出，脚本报 FAIL。

### 用 Makefile 做日常操作

`Makefile` 封装了构建、后台起停、健康检查与 actuator 探查（`make` 或 `make help`
列出全部目标）：

```bash
make build          # mvn -q -DskipTests package
make start          # 后台启动 gateway(:8080) + backend(:8081)，pid/日志写入 .run/
make status         # 显示进程状态与 /actuator/health
make logs           # tail 两个服务的日志
make demo           # 等价于 run-demo.sh（可传 HEAP=… SIZE_MB=…）
make env-gateway    # curl 网关 /actuator/env
make stop           # 停止两个服务
```

### 手动运行

```bash
mvn -DskipTests package
java -Xmx128m -jar backend/target/backend-0.0.1-SNAPSHOT.jar   # :8081
java -Xmx128m -jar gateway/target/gateway-0.0.1-SNAPSHOT.jar   # :8080

# 造一个 1GB 文件并经网关上传（-T 让 curl 从磁盘流式发送，客户端也不占内存）
dd if=/dev/zero of=/tmp/big.bin bs=1048576 count=1024
curl -X POST -T /tmp/big.bin -H "Content-Type: application/octet-stream" \
     http://localhost:8080/upload
```

## Actuator 端点

两个服务都引入了 `spring-boot-starter-actuator`，并暴露了一组端点（demo 用，勿在生产
对公网开放）：

```bash
# 网关 (:8080)
curl -s localhost:8080/actuator | python3 -m json.tool   # 端点清单
curl -s localhost:8080/actuator/env    | python3 -m json.tool
curl -s localhost:8080/actuator/beans  | python3 -m json.tool
# 后端 (:8081) 同理，把端口换成 8081
```

暴露的端点：`health,info,env,beans,mappings,configprops,conditions,metrics,loggers`。
`env` / `configprops` 设了 `show-values: always`，直接显示真实值而非 `******`（仅
本地 demo 方便查看）。

## 偶发 413 排查（h2c upgrade）

`k8s-repro/` 是一套独立的 kind 集群复现装置，把一个真实生产问题定位到了根因并
**自动化验证了修复**（`verify-h2c-413.sh` 断言 **9/9 PASS**）。

**现象**：经 SCG-MVC 网关上传文件（multipart），网关 **1 个 pod 从不 413**、
**3 个 pod 偶发 413 PAYLOAD_TOO_LARGE**，缩回 1 pod 即消失；网关与后端各 pod 均同质。

**根因**（三个各自合理的配置叠加，改掉任意一个即可解除）：

1. 上传后端开了明文 HTTP/2：`SERVER_HTTP2_ENABLED=true`（h2c）。
2. 网关下游 client 是 **JDK HttpClient**（classpath 无 Apache HC5 / Jetty /
   Reactor Netty），而 JDK HttpClient **默认偏好 HTTP/2** → 在**冷连接的第一个
   请求**上附带 `Upgrade: h2c`，且不判断这个请求是不是一个大上传。
3. Tomcat 处理「带 body 的 h2c upgrade 请求」时必须先把 body 整体缓存以便在 h2
   stream 1 上重放（RFC 7230），上限 `maxSavePostSize` 默认 **4096 字节**，超限
   直接回 **413 并关连接** —— 发生在 auth / Spring MVC **之前**，后端零日志。

于是：**任何 body > 4KB（几乎所有真实上传）的请求落在冷连接上就会 413**；落在热
h2 连接上则多路复用一切正常。Tomcat 空闲 **20s** 关掉 h2 连接使连接重新变冷 ——
这就是「偶发」。连接池是**每个网关 pod 一份**，pod 越多单池越容易空闲变冷，因此
pod 数只是**放大器**，与后端 pod 数、镜像新旧无关。

**修复**（两条做任意一条即可根治，都做则互为保险）：

- 网关加 `org.apache.httpcomponents.client5:httpclient5` 依赖 —— SCG-MVC 自动优先
  选用 HC5，HC5 classic 对下游只说 HTTP/1.1，永不发 h2c upgrade（已验证，T6 PASS）；
- 或摘除后端的 `SERVER_HTTP2_ENABLED=true`。
- **不建议**调大 `maxSavePostSize`：只是把悬崖挪远，且引入把整个 body 缓存进内存的
  OOM 风险。

**详细内容**：

- 完整根因 + 连接池源码级分析（含 JDK `Http2ClientImpl` / Tomcat `Http11Processor`
  逐段引用、泊松稀释模型、时间线）：[`docs/gateway-413-h2c-upgrade.md`](docs/gateway-413-h2c-upgrade.md)
- 复现装置、历史实验记录与在真实集群「两条命令确认」的方法：
  [`k8s-repro/README.md`](k8s-repro/README.md)

## 目录结构

```
.
├── gateway/            流式 demo 的网关（SCG-MVC 纯代理）
├── backend/            流式 demo 的后端（读 InputStream 计数）
├── k8s-repro/          偶发 413 的 kind 复现装置（独立 Maven 模块）
│   ├── gateway/        stand-in 网关（含 hc5 profile 作为修复对照）
│   ├── backend/        stand-in 后端（server.http2.enabled=true）
│   ├── k8s/            kind 集群配置、Deployment/Service、加载脚本
│   ├── verify-h2c-413.sh   自动化断言（9/9 PASS）
│   └── *.sh            历史复现实验脚本
├── docs/
│   └── gateway-413-h2c-upgrade.md   根因 + 源码级分析
├── run-demo.sh         流式 demo 一键验证脚本
└── Makefile            构建 / 起停 / actuator 便捷目标
```

## 说明与生产建议

- **HTTP 客户端可替换**：往 gateway 依赖里加入 Apache HttpClient 5
  （`org.apache.httpcomponents.client5:httpclient5`）或 Jetty，网关会自动优先选用
  （优先级 Apache > Jetty > Reactor Netty > JDK）。三者都支持请求体流式；Apache HC5
  是生产常见选择（也是上面 413 问题的推荐修复）。
- **想看“反面教材”**：把 backend 换成 `public ... upload(@RequestBody byte[] body)`，
  Spring 会把整个 body 读进 `byte[]`，用 `-Xmx128m` 传 1GB 立即 OOM —— 与本 demo 形成对照。
- **multipart 上传**：本 demo 走原始二进制 body（最能干净地证明流式）。若要转发
  `multipart/form-data`，网关侧同样不解析、原样流式透传；需要“真流式”解析各 part 的是
  *下游* 服务（用 Commons FileUpload 流式 API 或直接读 InputStream，避免
  `@RequestPart`/`MultipartResolver` 把文件落盘或进堆）。
- **别引入缓冲**：任何读取请求体的过滤器（如网关的 `cacheRequestBody`、
  `ContentCachingRequestWrapper`、或对 body 做改写的 filter）都会破坏流式，请勿在该路由上启用。
- **生产项**：按需设置连接/响应超时、`RequestSize` 过滤器限制最大上传、以及针对
  慢客户端的背压与超时策略。

## 版本

| 组件 | 版本 |
|------|------|
| Spring Boot | 3.5.16 |
| Spring Cloud | 2025.0.3 |
| Gateway starter | `spring-cloud-starter-gateway-server-webmvc` (Gateway 4.3.x) |
| Java (编译目标) | 25 |
