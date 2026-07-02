# Convenience targets for building, running, and probing the gateway + backend demo.
# Run `make` or `make help` to list targets.

MVN     ?= mvn
HEAP    ?= 128m
SIZE_MB ?= 1024
RUN_DIR := .run

GATEWAY_JAR := gateway/target/gateway-0.0.1-SNAPSHOT.jar
BACKEND_JAR := backend/target/backend-0.0.1-SNAPSHOT.jar
GATEWAY_URL := http://localhost:8080
BACKEND_URL := http://localhost:8081

.DEFAULT_GOAL := help
.PHONY: help build package clean test \
        start stop restart status logs \
        demo \
        env-gateway env-backend beans-gateway beans-backend

help: ## Show this help
	@grep -E '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

build: ## Build both modules (mvn package, tests skipped)
	@echo "==> Building (mvn -q -DskipTests package)"
	@$(MVN) -q -DskipTests package

package: build ## Alias for build

clean: ## Remove all build output
	@echo "==> Cleaning (mvn clean)"
	@$(MVN) -q clean

test: ## Run the test suite
	@echo "==> Running tests (mvn test)"
	@$(MVN) test

start: build ## Start gateway (:8080) and backend (:8081) in the background
	@mkdir -p $(RUN_DIR)
	@if [ -f $(RUN_DIR)/backend.pid ] && kill -0 "$$(cat $(RUN_DIR)/backend.pid)" 2>/dev/null; then \
		echo "backend already running (pid $$(cat $(RUN_DIR)/backend.pid))"; \
	else \
		nohup java -jar $(BACKEND_JAR) > $(RUN_DIR)/backend.log 2>&1 & echo $$! > $(RUN_DIR)/backend.pid; \
		echo "backend starting (pid $$(cat $(RUN_DIR)/backend.pid), :8081)"; \
	fi
	@if [ -f $(RUN_DIR)/gateway.pid ] && kill -0 "$$(cat $(RUN_DIR)/gateway.pid)" 2>/dev/null; then \
		echo "gateway already running (pid $$(cat $(RUN_DIR)/gateway.pid))"; \
	else \
		nohup java -jar $(GATEWAY_JAR) > $(RUN_DIR)/gateway.log 2>&1 & echo $$! > $(RUN_DIR)/gateway.pid; \
		echo "gateway starting (pid $$(cat $(RUN_DIR)/gateway.pid), :8080)"; \
	fi

stop: ## Stop gateway and backend
	@for name in gateway backend; do \
		if [ -f $(RUN_DIR)/$$name.pid ]; then \
			pid=$$(cat $(RUN_DIR)/$$name.pid); \
			if kill $$pid 2>/dev/null; then echo "stopped $$name (pid $$pid)"; \
			else echo "$$name not running"; fi; \
			rm -f $(RUN_DIR)/$$name.pid; \
		else \
			echo "$$name not running"; \
		fi; \
	done

restart: stop start ## Restart both services

status: ## Show whether gateway/backend are running and healthy
	@for entry in "gateway:8080" "backend:8081"; do \
		name=$${entry%%:*}; port=$${entry##*:}; \
		if [ -f $(RUN_DIR)/$$name.pid ] && kill -0 "$$(cat $(RUN_DIR)/$$name.pid)" 2>/dev/null; then \
			health=$$(curl -s -o /dev/null -w '%{http_code}' http://localhost:$$port/actuator/health 2>/dev/null); \
			echo "$$name: running  (pid $$(cat $(RUN_DIR)/$$name.pid), :$$port, health=$$health)"; \
		else \
			echo "$$name: stopped"; \
		fi; \
	done

logs: ## Tail gateway and backend logs
	tail -f $(RUN_DIR)/gateway.log $(RUN_DIR)/backend.log

demo: stop ## Run the streaming-upload proof: heap-capped JVMs vs a file bigger than the heap
	@HEAP=$(HEAP) SIZE_MB=$(SIZE_MB) ./run-demo.sh

env-gateway: ## Dump gateway /actuator/env
	@curl -s $(GATEWAY_URL)/actuator/env | python3 -m json.tool

env-backend: ## Dump backend /actuator/env
	@curl -s $(BACKEND_URL)/actuator/env | python3 -m json.tool

beans-gateway: ## Dump gateway /actuator/beans
	@curl -s $(GATEWAY_URL)/actuator/beans | python3 -m json.tool

beans-backend: ## Dump backend /actuator/beans
	@curl -s $(BACKEND_URL)/actuator/beans | python3 -m json.tool
