package com.example.backend413;

import java.net.InetAddress;
import java.net.UnknownHostException;
import java.util.LinkedHashMap;
import java.util.Map;

import jakarta.servlet.http.HttpServletRequest;

import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RequestPart;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.multipart.MultipartFile;

/**
 * Mirrors the production upload endpoint's contract
 * (POST /api/file/upload, "module" + "file" part) closely enough to
 * reproduce its multipart size handling.
 */
@RestController
public class FileUploadController {

    @PostMapping(value = "/api/file/upload", consumes = "multipart/form-data")
    public Map<String, Object> upload(@RequestParam("module") String module,
                                       @RequestPart("file") MultipartFile file,
                                       HttpServletRequest request) {
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("module", module);
        result.put("filename", file.getOriginalFilename());
        result.put("bytesReceived", file.getSize());
        result.put("servedBy", hostname());
        // Which protocol the gateway's HTTP client actually negotiated
        // (HTTP/2.0 = h2c upgrade happened -> one multiplexed conn per origin).
        result.put("protocol", request.getProtocol());
        return result;
    }

    private static String hostname() {
        try {
            return InetAddress.getLocalHost().getHostName();
        } catch (UnknownHostException e) {
            return "unknown";
        }
    }
}
