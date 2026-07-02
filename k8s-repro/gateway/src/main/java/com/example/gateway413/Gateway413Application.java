package com.example.gateway413;

import static org.springframework.cloud.gateway.server.mvc.filter.BeforeFilterFunctions.uri;
import static org.springframework.cloud.gateway.server.mvc.handler.GatewayRouterFunctions.route;
import static org.springframework.cloud.gateway.server.mvc.handler.HandlerFunctions.http;
import static org.springframework.cloud.gateway.server.mvc.predicate.GatewayRequestPredicates.path;

import java.net.InetAddress;
import java.net.UnknownHostException;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.context.annotation.Bean;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.servlet.function.RouterFunction;
import org.springframework.web.servlet.function.ServerResponse;

@SpringBootApplication
public class Gateway413Application {

    public static void main(String[] args) {
        SpringApplication.run(Gateway413Application.class, args);
    }

    /**
     * Route: POST /api/file/upload -> {BACKEND_URL}/api/file/upload
     *
     * Mirrors the production gateway's upload route: a plain proxy, no path
     * rewriting needed since backend413 listens on the same path.
     */
    @Bean
    public RouterFunction<ServerResponse> uploadBackendRoute(
            @Value("${BACKEND_URL:http://localhost:8081}") String backendUrl) {
        return route("upload-backend")
                .route(path("/api/**"), http())
                .before(uri(backendUrl))
                .build();
    }

    @RestController
    static class WhoAmI {
        @GetMapping("/whoami")
        String whoami() {
            return hostname();
        }

        private static String hostname() {
            try {
                return InetAddress.getLocalHost().getHostName();
            } catch (UnknownHostException e) {
                return "unknown";
            }
        }
    }
}
