# 413 repro: intermittent PAYLOAD_TOO_LARGE behind Spring Cloud Gateway (MVC)

Reproduces a production report: file uploads through a Spring Cloud Gateway
Server MVC gateway intermittently return `413 PAYLOAD_TOO_LARGE` when the
gateway runs 3 pods, never with 1 pod. Gateway pods freshly deployed and
homogeneous; the upload backend at 3 pods.

## ROOT CAUSE (confirmed in kind, deterministic)

Three ingredients, all present in the production setup:

1. **The upload backend has h2c enabled**: `SERVER_HTTP2_ENABLED: "true"`
   injected via the environment ConfigMap — HTTP/2 cleartext upgrade on the
   plain in-cluster port.
2. **The gateway's downstream client is the JDK HttpClient** — SCG-MVC picks
   by classpath (Apache HC5 > Jetty > Reactor Netty > JDK; verified in
   `GatewayHttpClientEnvironmentPostProcessor` bytecode) and the gateway pom
   has none of the first three. JDK HttpClient defaults to HTTP/2, so on a
   **cold connection** the first request carries `Upgrade: h2c` +
   `HTTP2-Settings` headers.
3. **Tomcat rejects an h2c upgrade request whose body exceeds
   `maxSavePostSize` (default 4096 bytes) with a connector-level 413** — it
   would have to buffer the body to replay it on HTTP/2 stream 1. The
   rejection happens before any servlet/Spring code; the backend logs
   NOTHING for these requests.

So: **any request with a body >4KB (every real file upload) that lands on a
cold gateway→backend connection gets a 413.** Uploads that land on a warm
HTTP/2 connection stream through fine. That's the intermittency.

**Why gateway pod count modulates it:** each gateway pod has its own
connection pool, and Tomcat closes idle h2 connections after ~20s. With 1
gateway pod, all traffic funnels through one pool that virtually never
goes idle → uploads always ride warm connections → "1 pod never fails".
With 3 pods, each pool sees ~1/3 of the traffic → per-pod idle gaps are
common → uploads regularly land on cold connections → intermittent 413.
Backend pod count and gateway image homogeneity are irrelevant — no "bad
pod" is needed anywhere.

**Why the log line was misleading:** the gateway *proxies* the connector-level
413, and the gateway's own `DispatcherServlet` then logs
`Completed 413 PAYLOAD_TOO_LARGE` — the exact reported line. In the repro the
gateway pods logged 30/30 of these while all backend pods logged zero.

## Reproduction evidence (`hetero-bff-repro.sh` + manual sequence)

Topology: 3 **identical** backend pods (10MB limit, h2c enabled, mirroring
the production backend), 1-3 gateway pods (JDK client, mirroring the
production gateway). Same 3MB file throughout:

```
a) cold gateway pod, FIRST request = 3MB upload   -> 413   (upgrade + big body)
b) 2KB upload                                     -> 200, HTTP/2.0   (upgrade OK, fits 4KB)
c) 3MB upload immediately after                   -> 200, HTTP/2.0   (warm conn, multiplexed)
d) 3MB again                                      -> 200, HTTP/2.0
e) idle 45s, then 3MB                             -> 413   (Tomcat closed idle h2 conn)
f) idle 95s, then 3MB                             -> 413
```

Direct-to-backend controls (bypassing the gateway):

```
--http1.1  3MB  -> 200 (or Spring-level 413 only from an intentionally strict pod)
--http2    3MB  -> 413, Tomcat HTML error page  (connector-level)
--http2    2KB  -> 200 over HTTP/2
```

Earlier experiments that FAILED to reproduce (`run-repro.sh`, both with and
without pod heterogeneity) differed in exactly one variable: the stand-in
backend didn't have `server.http2.enabled=true`. Adding that single flag —
straight from the production environment ConfigMap — flipped cold-connection
3MB uploads from 200 to 413 across the board.

## Two-command confirmation in the real cluster

The connector rejects **before auth**, so no token is needed. From any pod
in the target namespace (substitute your backend Service name):

```bash
head -c 3000000 /dev/urandom > /tmp/big.bin
# what the gateway's JDK client does on a cold connection:
curl -s -o /tmp/r -w '%{http_code} %{http_version}\n' --http2 \
  -F module=DEPOSIT -F 'file=@/tmp/big.bin;type=image/png' \
  http://<upload-backend-svc>.<namespace>.svc.cluster.local/api/file/upload
# expect: 413 1.1, /tmp/r = Tomcat HTML error page  -> root cause confirmed

# control — plain HTTP/1.1, no upgrade:
curl -s -o /dev/null -w '%{http_code}\n' --http1.1 \
  -F module=DEPOSIT -F 'file=@/tmp/big.bin;type=image/png' \
  http://<upload-backend-svc>.<namespace>.svc.cluster.local/api/file/upload
# expect: 401/400 (auth), NOT 413 -> the 413 is purely the h2c upgrade path
```

## Fix options (either alone suffices)

1. **Config-only, immediate:** remove `SERVER_HTTP2_ENABLED: "true"` from
   the backends the gateway proxies to. h2c between in-cluster services buys
   little here and is what arms the trap.
2. **Gateway-side, proper:** make the gateway talk HTTP/1.1 downstream —
   add `org.apache.httpcomponents.client5:httpclient5` to the gateway pom
   (SCG-MVC auto-prefers Apache HC5, which does not attempt h2c upgrades),
   or register a `JdkClientHttpRequestFactory` built with
   `HttpClient.Version.HTTP_1_1`.
3. *Not recommended:* raising `maxSavePostSize` on the backend — it buffers
   the whole body in memory for replay and just moves the cliff.

Note the blast radius is wider than file uploads: **any** gateway→backend
request with a body >4KB (large JSON POSTs included) hitting a cold
connection is exposed. Symptoms concentrate on uploads because they're
reliably large.

## Repo layout

- `gateway/`, `backend/` — the two stand-in Spring Boot apps
  (backend has `server.http2.enabled=true` + echoes `servedBy`/`protocol`).
- `k8s/` — kind cluster config, Deployments/Services, strict-peer pod
  (used by the earlier heterogeneity experiment).
- `run-repro.sh` — experiment 1: homogeneous pods, no h2c → no repro;
  proves pod count alone changes nothing and the 10MiB threshold belongs to
  the backend's own multipart limit.
- `hetero-repro.sh` — experiment 2: env-drift heterogeneity (envFrom is
  resolved at container start; the production deployment hashes the ConfigMap
  but not the Secret; scale-down survivor is heuristic). Reproduces a
  *different* class of intermittent 413; kept as documentation of that
  mechanism.
- `hetero-bff-repro.sh` — experiment 3 rig (h2c + JDK client). The a-f
  sequence above was driven manually; see git history.
- `verify-h2c-413.sh` — **automated verification with PASS/FAIL asserts
  (9/9 PASS)**: the T1-T4 cold/warm sequence, direct-to-backend controls,
  and the fix control group (gateway built with `mvn -Phc5` → Apache HC5 →
  cold 3MB upload succeeds over HTTP/1.1).
- Full root-cause writeup with connection-pool source analysis:
  [`docs/gateway-413-h2c-upgrade.md`](../docs/gateway-413-h2c-upgrade.md)

Cleanup: `kind delete cluster --name h2c-413-repro`
