package com.example.backend;

import java.io.IOException;
import java.io.InputStream;
import java.util.LinkedHashMap;
import java.util.Map;

import jakarta.servlet.http.HttpServletRequest;

import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * Consumes the uploaded body as a stream and reports how many bytes went by.
 *
 * The key detail: we read {@code request.getInputStream()} in a fixed-size loop
 * and DISCARD each chunk. The body is never accumulated, so the amount of data
 * we can accept is unbounded by the heap. Note how {@code bytesReceived} in the
 * response can dwarf {@code jvmMaxHeapMB}.
 */
@RestController
public class UploadController {

    /** The only thing we ever hold in memory: one 64 KB copy buffer. */
    private static final int BUFFER_SIZE = 64 * 1024;

    @PostMapping("/upload")
    public Map<String, Object> upload(HttpServletRequest request) throws IOException {
        long total = 0;
        long startNanos = System.nanoTime();
        byte[] buffer = new byte[BUFFER_SIZE];

        try (InputStream in = request.getInputStream()) {
            int read;
            while ((read = in.read(buffer)) != -1) {
                total += read; // consume and drop on the floor — never buffer the whole body
            }
        }

        long elapsedMillis = (System.nanoTime() - startNanos) / 1_000_000;
        Runtime rt = Runtime.getRuntime();
        long maxHeapMB = rt.maxMemory() / (1024 * 1024);
        long usedHeapMB = (rt.totalMemory() - rt.freeMemory()) / (1024 * 1024);

        Map<String, Object> result = new LinkedHashMap<>();
        result.put("bytesReceived", total);
        result.put("megabytesReceived", String.format("%.1f", total / (1024.0 * 1024.0)));
        result.put("elapsedMillis", elapsedMillis);
        result.put("jvmMaxHeapMB", maxHeapMB);
        result.put("jvmUsedHeapMB", usedHeapMB);
        result.put("bufferSizeKB", BUFFER_SIZE / 1024);
        result.put("note", "Streamed in " + (BUFFER_SIZE / 1024)
                + "KB chunks; bytesReceived may greatly exceed jvmMaxHeapMB.");
        return result;
    }
}
