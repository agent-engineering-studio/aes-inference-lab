.DEFAULT_GOAL := help
COMPOSE ?= docker compose

help:  ## mostra questo aiuto
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	 | awk 'BEGIN{FS=":.*?## "}{printf "  \033[1m%-16s\033[0m %s\n", $$1, $$2}'

install:  ## crea il virtualenv locale e installa le dipendenze
	python3 -m venv .venv
	.venv/bin/pip install -q --upgrade pip
	.venv/bin/pip install -q -r requirements-dev.txt
	@echo "fatto: attiva con  source .venv/bin/activate"

dev:  ## avvia la dashboard in locale con ricarica automatica
	.venv/bin/uvicorn app.main:app --reload --port $${LAB_PORT:-8500}

mock:  ## avvia il motore simulato in locale sulla porta 9000
	.venv/bin/uvicorn mock.server:app --port 9000

test:  ## esegue i test
	.venv/bin/pytest -q

lint:  ## controlla lo stile del codice
	.venv/bin/ruff check .

up:  ## avvia la dashboard in Docker
	$(COMPOSE) up -d --build

demo:  ## avvia dashboard + motore simulato (nessun server reale richiesto)
	MOCK_ENABLED=true $(COMPOSE) --profile demo up -d --build
	@echo "dashboard: http://localhost:$${LAB_PORT:-8500}"

gpu:  ## avvia in Docker con accesso alla scheda video
	$(COMPOSE) -f docker-compose.yml -f docker-compose.gpu.yml up -d --build

down:  ## ferma tutto
	$(COMPOSE) --profile demo down

logs:  ## segue i log
	$(COMPOSE) logs -f lab

bench:  ## benchmark da riga di comando (usa ARGS="--runs 5")
	.venv/bin/python -m cli.bench $(ARGS)

.PHONY: help install dev mock test lint up demo gpu down logs bench
