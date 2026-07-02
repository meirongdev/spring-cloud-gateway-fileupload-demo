# Spring Cloud Gateway (Spring MVC) 流式文件上传 Demo

一个最小的 demo，验证 **servlet 版**（Spring MVC）的 Spring Cloud Gateway 能以
**流式（streaming）**方式转发文件上传 —— 上传体积可以远超进程的堆内存，全程不会
把整个文件缓冲进内存。

> 之所以专门验证 MVC 版：servlet 网关历史上比 reactive 版更容易“把请求体整体缓冲
> 到内存再转发”（参见 [spring-cloud-gateway#3479](https://github.com/spring-cloud/spring-cloud-gateway/issues/3479)，
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

## 为什么是流式的（源码依据，基于 gateway 4.2.x / Spring Framework 6.2.x）

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

需要 JDK 17+（本机 JDK 25 亦可；工程按 Java 21 编译）与 Maven。

### 一键验证

```bash
./run-demo.sh
# 自定义：更小堆 / 更大文件，反差更明显
HEAP=96m SIZE_MB=2048 ./run-demo.sh
```

脚本会：编译 → 用 `-Xmx128m -XX:+ExitOnOutOfMemoryError` 启动两个服务 →
生成一个远大于堆的文件 → 经网关上传 → 打印结果 → 清理进程与临时文件。
只要有任何一处缓冲整个 body，就会 OOM 并让 JVM 退出，脚本报 FAIL。

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

## 说明与生产建议

- **HTTP 客户端可替换**：往 gateway 依赖里加入 Apache HttpClient 5
  （`org.apache.httpcomponents.client5:httpclient5`）或 Jetty，网关会自动优先选用
  （优先级 Apache > Jetty > Reactor Netty > JDK）。三者都支持请求体流式；Apache HC5
  是生产常见选择。
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
| Gateway starter | `spring-cloud-starter-gateway-server-webmvc` (Gateway 4.2.x) |
| Java (编译目标) | 21 |
