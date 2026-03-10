SHELL := bash
.DEFAULT_GOAL := help

CONFIG ?= config/import-config.json
BACKEND_CONFIG ?= config/backend-config.json
MODULE ?=
ONLY ?=
CONTINUE_ON_ERROR ?= 0

BUCKET ?=
DYNAMODB_TABLE ?=
REGION ?= us-east-1
PROFILE ?=
STATE_PREFIX ?= terraform-import
DISABLE_VERSIONING ?= 0

CONTINUE_FLAG := $(if $(filter 1 true yes,$(CONTINUE_ON_ERROR)),--continue-on-error,)
VERSIONING_FLAG := $(if $(filter 1 true yes,$(DISABLE_VERSIONING)),--disable-versioning,)

.PHONY: help import-module import-module-with-backend import-all import-all-with-backend dry-run-all backend-create

help:
	@echo "Targets:"
	@echo "  make import-module MODULE=vpc"
	@echo "  make import-module-with-backend MODULE=vpc"
	@echo "  make import-all [ONLY=vpc,eks]"
	@echo "  make import-all-with-backend [ONLY=vpc,eks]"
	@echo "  make dry-run-all [ONLY=vpc,eks]"
	@echo "  make backend-create BUCKET=<bucket> DYNAMODB_TABLE=<table> [REGION=us-east-1] [PROFILE=default]"

import-module:
	@test -n "$(MODULE)" || (echo "MODULE is required. Example: make import-module MODULE=vpc" && exit 1)
	@bash ./scripts/import-module.sh \
		--module "$(MODULE)" \
		--config "$(CONFIG)" \
		--backend-config "$(BACKEND_CONFIG)"

import-module-with-backend:
	@test -n "$(MODULE)" || (echo "MODULE is required. Example: make import-module-with-backend MODULE=vpc" && exit 1)
	@bash ./scripts/import-module.sh \
		--module "$(MODULE)" \
		--config "$(CONFIG)" \
		--backend-config "$(BACKEND_CONFIG)" \
		--setup-backend

import-all:
	@bash ./scripts/import-all.sh \
		--config "$(CONFIG)" \
		--backend-config "$(BACKEND_CONFIG)" \
		$(if $(ONLY),--only "$(ONLY)",) \
		$(CONTINUE_FLAG)

import-all-with-backend:
	@bash ./scripts/import-all.sh \
		--config "$(CONFIG)" \
		--backend-config "$(BACKEND_CONFIG)" \
		$(if $(ONLY),--only "$(ONLY)",) \
		--setup-backend \
		$(CONTINUE_FLAG)

dry-run-all:
	@bash ./scripts/import-all.sh \
		--config "$(CONFIG)" \
		--backend-config "$(BACKEND_CONFIG)" \
		$(if $(ONLY),--only "$(ONLY)",) \
		--setup-backend \
		$(CONTINUE_FLAG) \
		--dry-run

backend-create:
	@test -n "$(BUCKET)" || (echo "BUCKET is required. Example: make backend-create BUCKET=my-tf-state DYNAMODB_TABLE=tf-locks" && exit 1)
	@test -n "$(DYNAMODB_TABLE)" || (echo "DYNAMODB_TABLE is required. Example: make backend-create BUCKET=my-tf-state DYNAMODB_TABLE=tf-locks" && exit 1)
	@bash ./scripts/create-remote-backend.sh \
		--bucket "$(BUCKET)" \
		--dynamodb-table "$(DYNAMODB_TABLE)" \
		--region "$(REGION)" \
		$(if $(PROFILE),--profile "$(PROFILE)",) \
		--state-prefix "$(STATE_PREFIX)" \
		--backend-config "$(BACKEND_CONFIG)" \
		--write-config \
		$(VERSIONING_FLAG)
