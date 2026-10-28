help:
	@echo ""
	@echo "AI-BankApp commands:"
	@echo "  make setup   create your .env file (first time only)"
	@echo "  make up      build and start everything"
	@echo "  make down    stop everything"
	@echo "  make logs    watch the logs"
	@echo "  make ps      show what is running"
	@echo "  make reset   wipe the database and start fresh"
	@echo "  make smoke   quick check that everything works"
	@echo "  make test    run the Maven test suite"
	@echo ""

setup:
	@test -f .env || cp .env.example .env
	@echo ".env is ready"

up: setup
	docker compose up --build

down:
	docker compose down

logs:
	docker compose logs -f

ps:
	docker compose ps

reset:
	docker compose down -v
	docker compose up --build

smoke:
	@echo "mysql:"
	docker exec bankapp-mysql mysqladmin ping -h localhost 2>/dev/null || echo "  mysql not running (make up)"
	@echo "app health:"
	curl -s http://localhost:8080/actuator/health || echo "  app not running (make up)"
	@echo ""
	@echo "app page:"
	curl -s -o /dev/null -w "  HTTP %{http_code}\n" http://localhost:8080/ || true

test:
	./mvnw -B test

.PHONY: help setup up down logs ps reset smoke test
