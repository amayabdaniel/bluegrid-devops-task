SHELL        := /usr/bin/env bash
.SHELLFLAGS  := -eu -o pipefail -c
.ONESHELL:
.DEFAULT_GOAL := help

IMAGE        ?= gs-rest-service:dev
CONTAINER    ?= gs-rest-service
APP_PORT     ?= 777
INTERNAL_PORT := 8080

.PHONY: help build run stop logs test-app lint lint-fix \
        tf-init tf-fmt tf-plan tf-apply tf-destroy tf-validate \
        deploy chaos clean all-checks

help: ## list targets
	@awk 'BEGIN{FS=":.*?## "}/^[a-zA-Z0-9_.-]+:.*## /{printf "  \033[1m%-18s\033[0m %s\n",$$1,$$2}' $(MAKEFILE_LIST)

build: ## docker build
	DOCKER_BUILDKIT=1 docker build -t $(IMAGE) .

run: stop ## run container on :777
	docker run -d --name $(CONTAINER) \
	  --read-only --tmpfs /tmp \
	  --cap-drop=ALL --security-opt=no-new-privileges \
	  --memory=384m --pids-limit=200 \
	  -p $(APP_PORT):$(INTERNAL_PORT) $(IMAGE)
	@for _ in 1 2 3 4 5 6 7 8 9 10; do \
	  if curl -fsS http://127.0.0.1:$(APP_PORT)/greeting >/dev/null; then \
	    echo "ready: curl http://localhost:$(APP_PORT)/greeting"; exit 0; \
	  fi; sleep 2; done; \
	docker logs $(CONTAINER); exit 1

stop: ## remove container
	-docker rm -f $(CONTAINER) 2>/dev/null

logs: ## tail container logs
	docker logs -f $(CONTAINER)

test-app: ## mvn verify
	cd app && ./mvnw -B -e -ntp verify

lint: ## all local linters
	hadolint --config .hadolint.yaml Dockerfile
	actionlint .github/workflows/*.yml
	shellcheck scripts/*.sh
	cd infra && terraform fmt -check -recursive && terraform validate && tflint --recursive

lint-fix: ## auto-fix
	cd infra && terraform fmt -recursive

tf-init: ## terraform init
	cd infra && terraform init

tf-validate: tf-init ## validate + tflint + checkov
	cd infra && terraform validate
	cd infra && tflint --recursive
	cd infra && checkov -d . --quiet --compact --framework terraform

tf-fmt: ## terraform fmt
	cd infra && terraform fmt -recursive

tf-plan: tf-init ## terraform plan
	cd infra && terraform plan -out=tfplan

tf-apply: ## terraform apply
	cd infra && [ -f tfplan ] && terraform apply tfplan || terraform apply

tf-destroy: ## teardown
	cd infra && terraform destroy

deploy: ## IMAGE_REF=ghcr.io/...:tag make deploy
ifndef IMAGE_REF
	$(error Pass IMAGE_REF=ghcr.io/...:tag)
endif
	scripts/deploy.sh $(IMAGE_REF)

chaos: ## kill local container and restart
	docker kill $(CONTAINER) && sleep 2 && $(MAKE) run

all-checks: lint ## local checks (no aws)
	@echo "ok"

clean: stop ## nuke local artifacts
	-docker rmi $(IMAGE) 2>/dev/null
	-rm -rf app/target infra/.terraform infra/tfplan
