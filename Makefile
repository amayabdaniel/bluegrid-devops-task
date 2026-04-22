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

help: ## List targets
	@awk 'BEGIN{FS=":.*?## "}/^[a-zA-Z0-9_.-]+:.*## /{printf "  \033[1m%-18s\033[0m %s\n",$$1,$$2}' $(MAKEFILE_LIST)

# ----- Image -----------------------------------------------------------------
build: ## Build the Docker image
	DOCKER_BUILDKIT=1 docker build -t $(IMAGE) .

run: stop ## Run the container locally with full hardening, exposed on :777
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

stop: ## Stop + remove local container
	-docker rm -f $(CONTAINER) 2>/dev/null

logs: ## Tail local container logs
	docker logs -f $(CONTAINER)

# ----- Tests / lint ----------------------------------------------------------
test-app: ## Run app unit tests in a throwaway container
	cd app && ./mvnw -B -e -ntp verify

lint: ## All local linters
	hadolint --config .hadolint.yaml Dockerfile
	actionlint .github/workflows/*.yml
	shellcheck scripts/*.sh
	cd infra && terraform fmt -check -recursive && terraform validate && tflint --recursive

lint-fix: ## Auto-fix the fixable lints
	cd infra && terraform fmt -recursive

# ----- Terraform -------------------------------------------------------------
tf-init: ## terraform init
	cd infra && terraform init

tf-validate: tf-init ## terraform validate + tflint + checkov
	cd infra && terraform validate
	cd infra && tflint --recursive
	cd infra && checkov -d . --quiet --compact --framework terraform

tf-fmt: ## terraform fmt (write)
	cd infra && terraform fmt -recursive

tf-plan: tf-init ## terraform plan (requires terraform.tfvars and AWS creds)
	cd infra && terraform plan -out=tfplan

tf-apply: ## terraform apply (uses saved tfplan if present, else fresh)
	cd infra && [ -f tfplan ] && terraform apply tfplan || terraform apply

tf-destroy: ## Tear everything down (end of demo)
	cd infra && terraform destroy

# ----- Deploy ----------------------------------------------------------------
deploy: ## Manual fallback deploy. Pass IMAGE=ghcr.io/<owner>/gs-rest-service:<tag>
ifndef IMAGE_REF
	$(error Pass IMAGE_REF=ghcr.io/...:tag)
endif
	scripts/deploy.sh $(IMAGE_REF)

# ----- Chaos -----------------------------------------------------------------
chaos: ## Kill the local container to verify recovery. See CHAOS.md for the real drill.
	docker kill $(CONTAINER) && sleep 2 && $(MAKE) run

# ----- Aggregate -------------------------------------------------------------
all-checks: lint ## Everything you can run locally without AWS
	@echo "All local checks green."

clean: stop ## Remove local image and build artifacts
	-docker rmi $(IMAGE) 2>/dev/null
	-rm -rf app/target infra/.terraform infra/tfplan
