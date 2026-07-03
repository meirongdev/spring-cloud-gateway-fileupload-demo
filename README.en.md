# Spring Cloud Gateway (Spring MVC) file upload: streaming-proxy demo + intermittent-413 root cause

*[中文](README.md) | English*

Two related threads, both about file uploads through a **servlet-stack**
(Spring MVC) Spring Cloud Gateway:

1. **Streaming-upload demo** (`gateway/` + `backend/`): proves the servlet gateway
   forwards uploads in a **streaming** fashion — the upload can be far larger than
   the process heap, and nothing buffers the whole file in memory at any point.
2. **Intermittent-413 root-cause analysis** (`k8s-repro/` + `docs/`): a full
   reproduction, diagnosis, and verification of a real production problem — file
   uploads through the gateway **intermittently** return `413 PAYLOAD_TOO_LARGE`,
   never with 1 gateway pod, only with 3. The root cause is
   **h2c upgrade + JDK HttpClient + Tomcat `maxSavePostSize`** stacked together,
   nothing to do with the file being "too big". See
   [§ Intermittent 413](#intermittent-413-h2c-upgrade).

> Why prove the MVC variant specifically: the servlet gateway has historically
> been more prone than the reactive one to "buffer the whole request body into
> memory before forwarding" (see [spring-cloud-gateway#3479](https://github.com/spring-cloud/spring-cloud-gateway/issues/3479),
> the `FastByteArrayOutputStream` OOM reported 2024-07). This demo shows the
> problem is gone on **Spring Boot 3.5 / Spring Cloud 2025.0.x**.

## Measured result

Both JVMs run with `-Xmx128m`; a **1 GB** upload (= 8× the heap) goes through the
gateway:

```
==> POST 1024 MB through the gateway (:8080) -> backend (:8081)
{"bytesReceived":1073741824,"megabytesReceived":"1024.0","elapsedMillis":1015,
 "jvmMaxHeapMB":128,"jvmUsedHeapMB":25,"bufferSizeKB":64,
 "note":"Streamed in 64KB chunks; bytesReceived may greatly exceed jvmMaxHeapMB."}
==> PASS: both JVMs survived with -Xmx128m while a 1024 MB body streamed through.
```

`bytesReceived = 1 GB` while `jvmUsedHeapMB = 25` and `jvmMaxHeapMB = 128` — the
whole run stays at the memory footprint of a single 64 KB copy buffer.

## Architecture

```
 curl -T file (streamed from disk)
        │  POST /upload   Content-Type: application/octet-stream
        ▼
 ┌──────────────────────┐   chunked (no Content-Length)   ┌──────────────────────┐
 │  gateway  :8080       │ ───────────────────────────────▶ │  backend  :8081       │
 │  Spring Cloud Gateway │   POST /upload                    │  Spring MVC           │
 │  Server MVC (servlet) │                                   │  reads InputStream,   │
 └──────────────────────┘                                   │  counts bytes         │
                                                             └──────────────────────┘
```

- **gateway**: `spring-cloud-starter-gateway-server-webmvc`. One route,
  `POST /upload -> http://localhost:8081`, pure proxy, never parses the body.
- **backend**: `spring-boot-starter-web`. Reads `request.getInputStream()` in
  64 KB chunks and discards them, accumulating only a byte count — it never buffers
  the whole body.

## Why it streams (source-level evidence, based on gateway 4.3.x / Spring Framework 6.2.x)

Nowhere along the path does the whole body land in a `byte[]`:

1. **No inbound multipart parsing**: the gateway proxies raw bytes, reading
   Tomcat's servlet `InputStream` directly (Tomcat reads chunked off the socket and
   never buffers the whole thing). The demo sends `application/octet-stream` raw
   binary, and both sides set `spring.servlet.multipart.enabled=false` to guarantee
   a plain streaming InputStream.
2. **The gateway writes the body downstream as a stream**: the default
   `RestClientProxyExchange` uses
   `restClient.body(outputStream -> StreamUtils.copy(servletInputStream, outputStream))`
   to copy the inbound stream straight into the downstream request's output stream.
3. **The underlying HTTP client does not buffer**: this demo has only the JDK on
   the classpath, so the gateway picks the JDK `HttpClient`. Spring's
   `JdkClientHttpRequest extends AbstractStreamingClientHttpRequest` bridges the
   write into a back-pressured `BodyPublishers.fromPublisher(...)` via
   `OutputStreamPublisher` — read-and-send, never materialized into an array.
4. **Content-Length is removed by default**: the gateway enables
   `RemoveContentLengthRequestHeadersFilter` by default, so the downstream request
   uses **chunked transfer-encoding** — no need to know the length up front,
   naturally streaming.
5. **Downstream consumption also streams**: the backend loops on `read(buffer)`
   and discards, so its memory use is independent of file size.

## Running

Requires JDK 25 and Maven (the build targets Java 25).

### One-shot verification (script)

```bash
./run-demo.sh
# customize: smaller heap / bigger file for a starker contrast
HEAP=96m SIZE_MB=2048 ./run-demo.sh
```

The script: builds → starts both services with
`-Xmx128m -XX:+ExitOnOutOfMemoryError` → generates a file much larger than the heap
→ uploads it through the gateway → prints the result → cleans up processes and temp
files. If anything buffered the whole body it would OOM and the JVM would exit, so
the script reports FAIL.

### Day-to-day with the Makefile

The `Makefile` wraps build, background start/stop, health checks, and actuator
probing (`make` or `make help` lists every target):

```bash
make build          # mvn -q -DskipTests package
make start          # start gateway(:8080) + backend(:8081) in the background; pids/logs under .run/
make status         # process status + /actuator/health
make logs           # tail both services' logs
make demo           # same as run-demo.sh (accepts HEAP=… SIZE_MB=…)
make env-gateway    # curl the gateway's /actuator/env
make stop           # stop both services
```

### Manual run

```bash
mvn -DskipTests package
java -Xmx128m -jar backend/target/backend-0.0.1-SNAPSHOT.jar   # :8081
java -Xmx128m -jar gateway/target/gateway-0.0.1-SNAPSHOT.jar   # :8080

# make a 1GB file and upload it through the gateway (-T lets curl stream from disk,
# so the client doesn't buffer either)
dd if=/dev/zero of=/tmp/big.bin bs=1048576 count=1024
curl -X POST -T /tmp/big.bin -H "Content-Type: application/octet-stream" \
     http://localhost:8080/upload
```

## Actuator endpoints

Both services include `spring-boot-starter-actuator` and expose a set of endpoints
(for the demo only — do NOT expose these to the public internet in production):

```bash
# gateway (:8080)
curl -s localhost:8080/actuator | python3 -m json.tool   # endpoint list
curl -s localhost:8080/actuator/env    | python3 -m json.tool
curl -s localhost:8080/actuator/beans  | python3 -m json.tool
# backend (:8081) is the same, swap the port to 8081
```

Exposed endpoints: `health,info,env,beans,mappings,configprops,conditions,metrics,loggers`.
`env` / `configprops` set `show-values: always` so real values show instead of
`******` (local-demo convenience only).

## Intermittent 413 (h2c upgrade)

`k8s-repro/` is a self-contained kind-cluster reproduction rig that pinned a real
production problem to its root cause and **verified the fix automatically**
(`verify-h2c-413.sh` asserts **9/9 PASS**).

**Symptom**: uploading files (multipart) through an SCG-MVC gateway,
**1 gateway pod never 413s**, **3 gateway pods intermittently return
413 PAYLOAD_TOO_LARGE**, and scaling back to 1 pod makes it vanish; gateway and
backend pods are all homogeneous.

**Root cause** (three individually reasonable settings stacked; changing any one
defuses it):

1. The upload backend has cleartext HTTP/2 (h2c) enabled: `SERVER_HTTP2_ENABLED=true`.
2. The gateway's downstream client is the **JDK HttpClient** (no Apache HC5 / Jetty /
   Reactor Netty on the classpath), and the JDK HttpClient **prefers HTTP/2 by
   default** → on a **cold connection's first request** it attaches `Upgrade: h2c`,
   without checking whether that request is a large upload.
3. When Tomcat handles an "h2c upgrade request that carries a body" it must buffer
   the whole body first so it can replay it on HTTP/2 stream 1 (RFC 7230); the cap
   `maxSavePostSize` defaults to **4096 bytes**, and going over it returns **413 and
   closes the connection** — this happens *before* auth / Spring MVC, so the backend
   logs nothing.

So: **any request with a body > 4KB (essentially every real upload) that lands on a
cold connection gets a 413**; one that lands on a warm h2 connection multiplexes
fine. Tomcat closes an idle h2 connection after **20s**, turning it cold again —
that is the "intermittency". The connection pool is **one per gateway pod**, so more
pods means each pool goes idle-and-cold more often; pod count is therefore only an
**amplifier**, unrelated to backend pod count or image freshness.

**Fix** (either one alone is a full fix; do both for defense in depth):

- Add `org.apache.httpcomponents.client5:httpclient5` to the gateway — SCG-MVC
  auto-prefers HC5, and HC5 classic only speaks HTTP/1.1 downstream, never sending an
  h2c upgrade (verified, T6 PASS);
- or remove `SERVER_HTTP2_ENABLED=true` from the backend.
- **Not recommended**: raising `maxSavePostSize` just moves the cliff and introduces
  an OOM risk from buffering the entire body in memory.

**Details**:

- Full root cause + connection-pool source-level analysis (line-by-line quotes from
  the JDK `Http2ClientImpl` / Tomcat `Http11Processor`, a Poisson dilution model, and
  a timeline): [`docs/gateway-413-h2c-upgrade.md`](docs/gateway-413-h2c-upgrade.md)
  (written in Chinese)
- The reproduction rig, history of experiments, and a "two-command confirmation in a
  real cluster": [`k8s-repro/README.md`](k8s-repro/README.md)

## Repository layout

```
.
├── gateway/            streaming demo gateway (SCG-MVC pure proxy)
├── backend/            streaming demo backend (reads InputStream, counts bytes)
├── k8s-repro/          kind reproduction rig for the intermittent 413 (separate Maven module)
│   ├── gateway/        stand-in gateway (has an hc5 profile as the fix control)
│   ├── backend/        stand-in backend (server.http2.enabled=true)
│   ├── k8s/            kind cluster config, Deployments/Services, loader scripts
│   ├── verify-h2c-413.sh   automated asserts (9/9 PASS)
│   └── *.sh            historical reproduction-experiment scripts
├── docs/
│   └── gateway-413-h2c-upgrade.md   root cause + source-level analysis
├── run-demo.sh         streaming-demo one-shot verification script
└── Makefile            build / start-stop / actuator convenience targets
```

## Notes and production advice

- **The HTTP client is swappable**: add Apache HttpClient 5
  (`org.apache.httpcomponents.client5:httpclient5`) or Jetty to the gateway's
  dependencies and it auto-prefers them (priority Apache > Jetty > Reactor Netty >
  JDK). All three support request-body streaming; Apache HC5 is the common production
  choice (and the recommended fix for the 413 above).
- **Want the "counter-example"**: change the backend to
  `public ... upload(@RequestBody byte[] body)` and Spring reads the whole body into
  a `byte[]` — sending 1GB with `-Xmx128m` OOMs immediately, the opposite of this
  demo.
- **Multipart uploads**: this demo uses a raw binary body (the cleanest proof of
  streaming). To forward `multipart/form-data`, the gateway side likewise doesn't
  parse it and streams it through as-is; the party that needs "true streaming"
  per-part parsing is the *downstream* service (use the Commons FileUpload streaming
  API or read the InputStream directly, avoiding `@RequestPart`/`MultipartResolver`
  spilling the file to disk or heap).
- **Don't introduce buffering**: any filter that reads the request body (the
  gateway's `cacheRequestBody`, `ContentCachingRequestWrapper`, or any body-rewriting
  filter) breaks streaming — don't enable them on this route.
- **Production items**: set connect/response timeouts as needed, a `RequestSize`
  filter to cap the max upload, and back-pressure/timeout strategy for slow clients.

## Versions

| Component | Version |
|-----------|---------|
| Spring Boot | 3.5.16 |
| Spring Cloud | 2025.0.3 |
| Gateway starter | `spring-cloud-starter-gateway-server-webmvc` (Gateway 4.3.x) |
| Java (build target) | 25 |
