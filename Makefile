.DEFAULT_GOAL := help
COMPOSE ?= docker compose

help:  ## show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	 | awk 'BEGIN{FS=":.*?## "}{printf "  \033[1m%-16s\033[0m %s\n", $$1, $$2}'

install:  ## create the local virtualenv and install dependencies
	python3 -m venv .venv
	.venv/bin/pip install -q --upgrade pip
	.venv/bin/pip install -q -r requirements-dev.txt
	@echo "done: activate with  source .venv/bin/activate"

dev:  ## start the dashboard locally with auto-reload
	.venv/bin/uvicorn app.main:app --reload --port $${LAB_PORT:-8500}

mock:  ## start the simulated engine locally on port 9000
	.venv/bin/uvicorn mock.server:app --port 9000

test:  ## run the tests
	.venv/bin/pytest -q

lint:  ## check code style
	.venv/bin/ruff check .

up:  ## start the dashboard in Docker
	$(COMPOSE) up -d --build

demo:  ## start dashboard + simulated engine (no real server required)
	MOCK_ENABLED=true $(COMPOSE) --profile demo up -d --build
	@echo "dashboard: http://localhost:$${LAB_PORT:-8500}"

gpu:  ## start in Docker with access to the graphics card
	$(COMPOSE) -f docker-compose.yml -f docker-compose.gpu.yml up -d --build

down:  ## stop everything
	$(COMPOSE) --profile demo down

logs:  ## follow the logs
	$(COMPOSE) logs -f lab

bench:  ## command-line benchmark (use ARGS="--runs 5")
	.venv/bin/python -m cli.bench $(ARGS)

.PHONY: help install dev mock test lint up demo gpu down logs bench
