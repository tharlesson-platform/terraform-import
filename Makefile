SHELL := bash
.DEFAULT_GOAL := help

CONFIG ?= config/import-config.json
BACKEND_CONFIG ?= config/backend-config.json
MODULE ?=
ONLY ?=
CONTINUE_ON_ERROR ?= 0
TF_MODULES_CONFIG ?= config/terraform-modules-config.json
IMPORT_MAP ?= config/import-map.json
SYNC_BACKEND ?= 0
AUTO_APPROVE ?= 0

BUCKET ?=
REGION ?= us-east-1
PROFILE ?=
STATE_PREFIX ?= terraform-import
DISABLE_VERSIONING ?= 0

CONTINUE_FLAG := $(if $(filter 1 true yes,$(CONTINUE_ON_ERROR)),--continue-on-error,)
VERSIONING_FLAG := $(if $(filter 1 true yes,$(DISABLE_VERSIONING)),--disable-versioning,)
SYNC_BACKEND_FLAG := $(if $(filter 1 true yes,$(SYNC_BACKEND)),--sync-backend-from-config,)
AUTO_APPROVE_FLAG := $(if $(filter 1 true yes,$(AUTO_APPROVE)),--auto-approve,)

.PHONY: help import-module import-module-with-backend import-all import-all-with-backend dry-run-all backend-create modules-plan modules-apply modules-import modules-dry-run check-unix

help:
	@echo "Targets:"
	@echo "  make import-module MODULE=vpc"
	@echo "  make import-module-with-backend MODULE=vpc"
	@echo "  make import-all [ONLY=vpc,eks]"
	@echo "  make import-all-with-backend [ONLY=vpc,eks]"
	@echo "  make dry-run-all [ONLY=vpc,eks]"
	@echo "  make backend-create BUCKET=<bucket> [REGION=us-east-1] [PROFILE=default]"
	@echo "  make modules-plan [ONLY=vpc,rds] [TF_MODULES_CONFIG=config/terraform-modules-config.json]"
	@echo "  make modules-apply [ONLY=vpc,rds] [AUTO_APPROVE=1] [SYNC_BACKEND=1]"
	@echo "  make modules-import IMPORT_MAP=config/import-map.json [ONLY=vpc,iam-role]"
	@echo "  make check-unix"

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
	@test -n "$(BUCKET)" || (echo "BUCKET is required. Example: make backend-create BUCKET=my-tf-state" && exit 1)
	@bash ./scripts/create-remote-backend.sh \
		--bucket "$(BUCKET)" \
		--region "$(REGION)" \
		$(if $(PROFILE),--profile "$(PROFILE)",) \
		--state-prefix "$(STATE_PREFIX)" \
		--backend-config "$(BACKEND_CONFIG)" \
		--write-config \
		$(VERSIONING_FLAG)

modules-plan:
	@bash ./scripts/run-terraform-modules.sh \
		--config "$(TF_MODULES_CONFIG)" \
		--backend-config "$(BACKEND_CONFIG)" \
		--action plan \
		$(if $(ONLY),--only "$(ONLY)",) \
		$(SYNC_BACKEND_FLAG) \
		$(CONTINUE_FLAG)

modules-apply:
	@bash ./scripts/run-terraform-modules.sh \
		--config "$(TF_MODULES_CONFIG)" \
		--backend-config "$(BACKEND_CONFIG)" \
		--action apply \
		$(if $(ONLY),--only "$(ONLY)",) \
		$(SYNC_BACKEND_FLAG) \
		$(AUTO_APPROVE_FLAG) \
		$(CONTINUE_FLAG)

modules-import:
	@bash ./scripts/run-terraform-modules.sh \
		--config "$(TF_MODULES_CONFIG)" \
		--backend-config "$(BACKEND_CONFIG)" \
		--import-map "$(IMPORT_MAP)" \
		--action import \
		$(if $(ONLY),--only "$(ONLY)",) \
		$(SYNC_BACKEND_FLAG) \
		$(CONTINUE_FLAG)

modules-dry-run:
	@bash ./scripts/run-terraform-modules.sh \
		--config "$(TF_MODULES_CONFIG)" \
		--backend-config "$(BACKEND_CONFIG)" \
		--action plan \
		$(if $(ONLY),--only "$(ONLY)",) \
		$(SYNC_BACKEND_FLAG) \
		$(CONTINUE_FLAG) \
		--dry-run

check-unix:
	@bash ./scripts/check-unix-compat.sh
