# Spring Cloud Gateway (MVC) 偶发 413 问题：根因、验证与连接池源码分析

> 状态：**已复现、已定位、已验证修复**（自动化断言 9/9 PASS）
> 验证脚本：`k8s-repro/verify-h2c-413.sh`（kind 本地集群，可重复运行）

## 1. 问题现象

生产/测试环境经网关（Spring Cloud Gateway Server MVC，servlet 栈）上传文件
（`POST /api/file/upload`，multipart/form-data）：

- 网关 **1 个 pod** 时：从不出现 413；
- 网关 **3 个 pod** 时：**偶发** `413 PAYLOAD_TOO_LARGE`，日志：
  `"logger": "o.s.web.servlet.DispatcherServlet", "message": "Completed 413 PAYLOAD_TOO_LARGE"`；
- 网关缩回 1 个 pod 后问题消失；
- 网关是全新部署（各 pod 同质），上传后端服务 3 个 pod，也同质。

## 2. 结论（TL;DR）

**这不是任何服务的 body 大小限制被触发，也与 pod 是否同质无关。**
它是三个各自合理的配置叠加出的连接器层（Tomcat connector）413：

| # | 配置事实 | 出处 |
|---|---------|------|
| 1 | 上传后端开了明文 HTTP/2（h2c）：`SERVER_HTTP2_ENABLED: "true"` | 生产 Helm chart 的环境 ConfigMap（对多数后端服务统一注入） |
| 2 | 网关下游 HTTP client 是 **JDK HttpClient**（classpath 上没有 Apache HC5 / Jetty / Reactor Netty），而 JDK HttpClient **默认优先 HTTP/2** | 网关 pom + SCG-MVC 按 classpath 选型 |
| 3 | Tomcat 对「带 body 的 h2c Upgrade 请求」必须先把 body 读完缓存（RFC 7230），缓存上限 `maxSavePostSize` 默认 **4096 字节**，超了直接回 **413** 并关连接 | Tomcat `Http11Processor` / `AbstractHttp11Protocol`，见 §4.3 |

组合起来的行为：

- JDK HttpClient 对同一个 origin（上传后端的 Service 地址）只在
  **连接池里没有可用 HTTP/2 连接**时，才会在「新连接的第一个请求」上附带
  `Upgrade: h2c` 头 —— **不管这个请求是不是一个 3MB 的文件上传**；
- 如果这第一个请求 body > 4KB → Tomcat 连接器 413（**发生在 auth/Spring 之前，
  后端什么日志都不会有**）；
- 如果第一个请求 body ≤ 4KB（普通 GET/小 POST）→ 升级成功，h2 连接入池，
  后续所有请求（包括大上传）在这条连接上多路复用，一切正常；
- Tomcat 侧空闲 **20 秒**（`Http2Protocol.DEFAULT_KEEP_ALIVE_TIMEOUT = 20000`）
  就会关掉 h2 连接 → 连接池重新变冷 → 陷阱重新上膛。

**为什么与网关 pod 数相关**：连接池是**每个 JVM（pod）一份**的。
1 个 pod 承接全部流量，池几乎永远是热的 → 上传总是搭上现成的 h2 连接；
3 个 pod 每个只分到 1/3 流量 → 单 pod 空闲超 20s 的窗口频繁出现 →
上传落在冷连接上的概率大增 → **偶发 413**。
后端有几个 pod、网关镜像新旧，都不影响这个机制。

**为什么日志有迷惑性**：连接器层 413 由后端的 Tomcat 直接回，
后端的 Spring 层无感知；网关把这个 413 **代理回去**时，网关自己的
`DispatcherServlet` 会打出 `Completed 413 PAYLOAD_TOO_LARGE` —— 与真正
「网关自己产生 413」的日志一字不差。

## 3. 自动化验证（9/9 PASS）

`k8s-repro/verify-h2c-413.sh` 在 kind 集群里对理论逐条断言
（3 个完全相同的 h2c backend pod 模拟生产后端；网关分别用
JDK client 版与 HC5 修复版镜像）：

```
T1  [PASS] 冷 gateway pod，第一个请求 = 3MB 上传        -> 413
T2  [PASS] 2KB 上传（≤ maxSavePostSize=4096）           -> 200，协议 HTTP/2.0
T3  [PASS] 紧接着 3MB 上传（热 h2 连接，多路复用）        -> 200，协议 HTTP/2.0
T4  [PASS] 空闲 45s（> Tomcat h2 超时 20s）后再传 3MB    -> 413
T5a [PASS] 绕过网关直连 backend，纯 HTTP/1.1 3MB         -> 200
T5b [PASS] 直连 + h2c upgrade + 3MB                      -> 413
T5b2[PASS] 且 413 响应体是 Tomcat 的 HTML 错误页（连接器层）
T5c [PASS] 直连 + h2c upgrade + 2KB                      -> 200，HTTP/2
T6  [PASS] 修复对照组：同一网关加 Apache HC5 依赖
           （mvn -Phc5），冷连接 3MB                     -> 200，协议 HTTP/1.1
```

T5a/T5b 互为对照：同一文件、同一后端，仅差一个 h2c upgrade 尝试，结果
200 vs 413 —— 把根因钉死在 upgrade 路径上。T6 证明修复有效。

## 4. 源码级分析：这个 413 是如何从连接池里长出来的

版本对应：spring-web 6.2.15、JDK 25（java.net.http）、tomcat-embed-core
10.1.55、spring-cloud-gateway-server-mvc 4.3.x（4.2.4 亦同，代码路径一致）。

### 4.1 起点：网关为什么用 JDK HttpClient，且偏好 HTTP/2

SCG-MVC 的 `GatewayHttpClientEnvironmentPostProcessor` 按 classpath 探测
顺序选择底层 client（字节码中依次探测）：

```
org.apache.hc.client5.http.impl.classic.HttpClients   (Apache HC5)
org.eclipse.jetty.client.HttpClient                    (Jetty)
reactor.netty.http.client.HttpClient                   (Reactor Netty)
java.net.http.HttpClient                               (JDK, 兜底)
```

网关的 pom 前三个都没有 → 走 JDK。Spring 侧构造（
`spring-web` `JdkClientHttpRequestFactory.java` L51-53）：

```java
public JdkClientHttpRequestFactory() {
    this(HttpClient.newHttpClient());
}
```

而 JDK `HttpClient.newHttpClient()` 的契约（`HttpClient.java` L179-181）：

> The default settings include: the "GET" request method, **a preference of
> HTTP/2**, a redirection policy of NEVER, ...

即：没有任何人显式选择 HTTP/2，它是三层默认值一路继承下来的。

### 4.2 JDK HttpClient 连接池：升级决策就发生在「池未命中」的那一刻

HTTP/2 连接池本体（`Http2ClientImpl.java` L69）——**每个 HttpClient 实例
（= 每个网关 JVM）一份，每个 origin 一条连接**：

```java
private final Map<String,Http2Connection> connections = new ConcurrentHashMap<>();
```

取连接的入口 `getConnectionFor(...)`，方法头注释直接写明了四种结局
（L89-99，注意第 3 条）：

```java
 * If negotiate/upgrade fails, then any opened connections remain open (as http/1.1)
 * ...
 * Specific CF behavior of this method.
 * 1. completes with ALPN exception: h2 negotiate failed for first time. failure recorded.
 * 2. completes with other exception: failure not recorded. Caller must handle
 * 3. completes normally with null: no connection in cache for h2c or h2 failed previously
 * 4. completes normally with connection: h2 or h2c connection in cache. Use it.
```

池未命中时（明文 http 场景）：

```java
if (!req.secure() || failures.contains(key)) {
    // secure: negotiate failed before. Use http/1.1
    // !secure: no connection available in cache. Attempt upgrade
    if (debug.on()) debug.log("not found in connection pool");
    return MinimalFuture.completedFuture(null);   // ← 返回 null = 让上层走升级
}
```

两个关键细节：

1. **`failures` 负缓存只记录 ALPN（https）失败**：
   `if (cause instanceof Http2Connection.ALPNException) failures.add(key);`
   —— h2c 升级被服务端拒绝（比如 413）**不会被记住**，下一条冷连接会
   原样再试一次。这就是为什么问题反复出现而不是只出现一次。
2. 升级成功后 `offerConnection(conn)` 才会把 h2 连接放进池；收到服务端
   GOAWAY/关闭则从池移除（`removeFromPool`）→ 回到冷态。

上层拿到 `null` 后的分支（`ExchangeImpl.createExchangeImpl(...)`）：

```java
if (c == null) {
    // no existing connection. Send request with HTTP 1 and then
    // upgrade if successful
    if (debug.on())
        debug.log("new Http1Exchange, try to upgrade");
    return createHttp1Exchange(exchange, connection)
            .thenApply((e) -> {
                exchange.h2Upgrade();     // ← 给当前这个请求打上升级标记
                return e;
            });
} else {
    if (debug.on()) debug.log("creating HTTP/2 streams");
    Stream<U> s = c.createStream(exchange);   // ← 热连接：直接开 h2 stream
    ...
}
```

`Exchange.h2Upgrade()`（L334-337）：

```java
public void h2Upgrade() {
    upgrading = true;
    request.setH2Upgrade(this);   // 请求头随后被加上
                                  // Connection: Upgrade, HTTP2-Settings
                                  // Upgrade: h2c
                                  // HTTP2-Settings: <base64>
}
```

**注意这里没有任何「这个请求是否带大 body」的判断** —— 升级请求就是业务
请求本身。第一个撞上冷连接的如果是 3MB multipart 上传，那么这 3MB 就会
作为 upgrade 请求的 body 发给服务端。

### 4.3 Tomcat 侧：升级请求的 body 必须整体缓存，超 4KB 即 413

`Http11Processor.service()`（tomcat-embed-core 10.1.55，L333-346）：

```java
// Has an upgrade been requested?
if (isConnectionToken(request.getMimeHeaders(), "upgrade")) {
    String requestedProtocol = request.getHeader("Upgrade");
    UpgradeProtocol upgradeProtocol = protocol.getUpgradeProtocol(requestedProtocol);
    if (upgradeProtocol != null) {
        if (upgradeProtocol.accept(request)) {
            // Create clone of request for upgraded protocol
            Request upgradeRequest = null;
            try {
                upgradeRequest = cloneRequest(request);
            } catch (ByteChunk.BufferOverflowException ioe) {
                response.setStatus(HttpServletResponse.SC_REQUEST_ENTITY_TOO_LARGE); // ← 413
                setErrorState(ErrorState.CLOSE_CLEAN, null);                          // ← 并关连接
            } ...
```

为什么必须 clone/缓存 body（`cloneRequest()` L519-529）：

```java
// Need to read and buffer the request body, if any. RFC 7230 requires
// that the request is fully read before the upgrade takes place.
ByteChunk body = new ByteChunk();
int maxSavePostSize = protocol.getMaxSavePostSize();
if (maxSavePostSize != 0) {
    body.setLimit(maxSavePostSize);          // ← 缓存上限
    ...
    while (source.getInputBuffer().doRead(buffer) >= 0) {
        body.append(buffer.getByteBuffer()); // ← 超限抛 BufferOverflowException
    }
}
```

上限默认值（`AbstractHttp11Protocol.java` L248）：

```java
private int maxSavePostSize = 4 * 1024;      // 4096 字节
```

语义：升级成功后连接切换为 HTTP/2，原请求要在 h2 stream 1 上「重放」，
所以 body 必须先整体缓存；Tomcat 不愿为此缓存任意大的 body（否则就是
OOM 攻击面），超限 → `BufferOverflowException` → **413 + 关连接**。
这发生在 servlet 分发之前 —— **认证过滤器、Spring MVC、业务代码全都没
运行**，所以后端侧零日志。

### 4.4 「偶发」的时钟：Tomcat 20 秒关掉空闲 h2 连接

`Http2Protocol.java` L49/L77：

```java
static final long DEFAULT_KEEP_ALIVE_TIMEOUT = 20000;
private long keepAliveTimeout = DEFAULT_KEEP_ALIVE_TIMEOUT;
```

串成完整时间线（与验证 T1-T4 一一对应）：

```
gateway pod 启动/连接被关       池冷
  └─ 第一个请求 = 大上传        → Upgrade + 3MB body → Tomcat 413 (T1)
  └─ 第一个请求 = 小请求(≤4KB)  → 101 升级成功 → h2 连接入池 (T2)
        └─ 后续大上传           → 同一 h2 连接多路复用 → 200 (T3)
        └─ 空闲 > 20s           → Tomcat 关闭 h2 连接 → 客户端 removeFromPool
              └─ 下一个请求 = 大上传 → 又是冷连接 → 413 (T4)
```

### 4.5 pod 数为什么成为放大器

先纠正一个直觉性的连接数模型：连接数**不是**「网关 pod 数 × 后端 pod
数」。JDK client 的 h2 池按 **origin（host:port，即后端 Service 的
VIP）** 存连接，每个 origin 只有 **1 条**（§4.2 的
`Map<String,Http2Connection>`，key 来自 `Http2Connection.keyFor`）。
后端有几个 pod 客户端完全不可见 —— kube-proxy 在 TCP 建连时决定这条
连接钉在哪个后端 pod 上（这也是验证输出里 `servedBy` 恒定的原因）。
所以网关 1 pod vs 3 pod 的连接数是 **1 条 vs 3 条**，与后端 pod 数无关。

真正起作用的是两个因素：

1. **流量稀释**：固定总流量 λ 拆成 N 份，每条连接的请求间隔拉长，
   超过 Tomcat 20s 空闲超时的概率按泊松模型指数上升：
   `P(冷) ≈ e^(−(λ/N)·20s)`。例：某 origin 总流量 0.2 req/s 时，
   1 pod → e⁻⁴ ≈ 1.8%；3 pods → e⁻¹·³³ ≈ 26%，差一个数量级以上。
2. **热度不跨 pod 共享**（更本质）：1 个 pod 时，**任何人**的任何小
   请求都在给唯一那条连接续命，大上传永远搭顺风车；3 个 pod 时，暖了
   pod A 对路由到 pod B 的上传毫无帮助。

实测演示（3 个后端 pod 不变，网关全冷后先发 1 个 2KB 暖机请求，再
连发 12 个 3MB 上传）：

| 网关 | 暖机 | 12 个上传结果 |
|------|------|--------------|
| 3 pods | 200（暖了其中一个 pod） | **1×200 / 11×413**（唯一的 200 与暖机同一 `servedBy`） |
| 1 pod  | 200 | **12×200**（`servedBy` 全程同一后端 pod = 一条连接） |

### 4.6 触发条件汇总

| 条件 | 值 | 改掉任意一个即可解除 |
|------|-----|---------------------|
| 下游 Tomcat 开 h2c | `SERVER_HTTP2_ENABLED=true` | ✔（建议） |
| 网关 client 偏好 HTTP/2 且做 h2c upgrade | JDK HttpClient 默认 | ✔（建议，加 HC5） |
| 升级请求 body > `maxSavePostSize` | 默认 4096B，上传必超 | ✘（调大 = 换一个悬崖 + 内存缓冲，不建议） |
| 请求落在冷连接上 | 池空闲 >20s / pod 新启 / 连接被关 | 无法根除，只能降低概率 |

注意波及面：**不只文件上传** —— 任何经网关、body > 4KB 的请求
（大 JSON POST 同样）落在冷连接上都会 413。

## 5. 修复建议

1. **网关加 Apache HttpClient 5 依赖（已验证，T6 PASS）**：

   ```xml
   <dependency>
       <groupId>org.apache.httpcomponents.client5</groupId>
       <artifactId>httpclient5</artifactId>
   </dependency>
   ```

   SCG-MVC 自动优先选用 HC5；HC5 classic 对下游只说 HTTP/1.1，永不发
   h2c upgrade。这也是生产网关更常规的连接池实现（超时/池参数可控）。
   替代写法：注册 `JdkClientHttpRequestFactory`，用
   `HttpClient.newBuilder().version(HttpClient.Version.HTTP_1_1)` 构造。

2. **摘除网关所服务后端的 `SERVER_HTTP2_ENABLED: "true"`**：
   集群内 hop 上 h2c 的收益（单连接多路复用）与这个坑相比不划算；
   上游入口层（nginx/ALB）到网关本来就是 HTTP/1.1。

   两条建议做任意一条即可根治；都做则互为保险。

3. 不建议调大 `server.tomcat.max-save-post-size`：Tomcat 会把整个上传
   body 缓存在内存里用于重放，等于自建 OOM 风险，且只是挪动阈值。

## 6. 在真实集群一键确认（无需 token —— 连接器拒绝先于 auth）

把 `<upload-backend-svc>.<namespace>` 换成实际的后端 Service：

```bash
head -c 3000000 /dev/urandom > /tmp/big.bin

# 复现网关 JDK client 在冷连接上的行为：
curl -s -o /tmp/r -w '%{http_code} %{http_version}\n' --http2 \
  -F module=DEPOSIT -F 'file=@/tmp/big.bin;type=image/png' \
  http://<upload-backend-svc>.<namespace>.svc.cluster.local/api/file/upload
# 预期：413 1.1，/tmp/r 为 Tomcat HTML 错误页 → 根因确认

# 对照组（不发 upgrade）：
curl -s -o /dev/null -w '%{http_code}\n' --http1.1 \
  -F module=DEPOSIT -F 'file=@/tmp/big.bin;type=image/png' \
  http://<upload-backend-svc>.<namespace>.svc.cluster.local/api/file/upload
# 预期：401/400（进到了 auth/业务层），不是 413
```

## 7. 相关文件

- 验证脚本（可重复运行）：`k8s-repro/verify-h2c-413.sh`
- 复现环境与历史实验：`k8s-repro/README.md`
  （实验 1：同质 pod 无法复现；实验 2：env 漂移可复现另一类偶发 413；
  实验 3 = 本文根因）
- 修复对照构建：`k8s-repro/gateway/pom.xml` 的 `hc5` profile
