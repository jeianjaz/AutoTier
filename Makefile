.PHONY: help init fmt validate plan up down destroy checkov chaos

help:
	@echo "AutoTier — Makefile targets"
	@echo ""
	@echo "  make init      - terraform init"
	@echo "  make fmt       - terraform fmt (auto-format)"
	@echo "  make validate  - terraform validate + fmt check"
	@echo "  make plan      - terraform plan"
	@echo "  make up        - terraform apply (create/update infra)"
	@echo "  make down      - terraform destroy (tear down ALL infra)"
	@echo "  make checkov   - run Checkov security scan"
	@echo "  make chaos     - run chaos test (measures MTTR)"

init:
	cd terraform && terraform init

fmt:
	cd terraform && terraform fmt -recursive

validate:
	cd terraform && terraform fmt -check -recursive
	cd terraform && terraform validate

plan:
	cd terraform && terraform plan

up:
	cd terraform && terraform apply -auto-approve

down:
	cd terraform && terraform destroy -auto-approve

destroy: down

checkov:
	checkov -d terraform/ --framework terraform

chaos:
	python3 scripts/chaos_test.py
