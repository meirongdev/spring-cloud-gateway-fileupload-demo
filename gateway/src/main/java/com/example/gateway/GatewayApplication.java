package com.example.gateway;

import static org.springframework.cloud.gateway.server.mvc.filter.BeforeFilterFunctions.uri;
import static org.springframework.cloud.gateway.server.mvc.handler.GatewayRouterFunctions.route;
import static org.springframework.cloud.gateway.server.mvc.handler.HandlerFunctions.http;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.context.annotation.Bean;
import org.springframework.web.servlet.function.RouterFunction;
import org.springframework.web.servlet.function.ServerResponse;

@SpringBootApplication
public class GatewayApplication {

    public static void main(String[] args) {
        SpringApplication.run(GatewayApplication.class, args);
    }

    /**
     * Route: POST /upload  ->  http://localhost:8081/upload
     *
     * The gateway does NOT parse the body. It reads the inbound servlet
     * InputStream and copies it straight into the downstream request, which is
     * sent with chunked transfer-encoding (the gateway removes Content-Length
     * by default). Nothing larger than a small copy buffer is ever held in the
     * gateway's heap, so an upload can far exceed -Xmx.
     */
    @Bean
    public RouterFunction<ServerResponse> uploadRoute() {
        return route("upload_route")
                .POST("/upload", http())
                .before(uri("http://localhost:8081"))
                .build();
    }
}
