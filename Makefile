.DEFAULT_GOAL := help

.PHONY: help up down status logs

help:
	@echo "Generic LocalStack helper (S3, SQS, SNS, DynamoDB, Secrets,"
	@echo "EventBridge, Lambda, Kinesis)."
	@echo "Edit config.yml, then:"
	@echo "  make up      start LocalStack and create resources from config.yml"
	@echo "  make down    stop LocalStack"
	@echo "  make status  show configured and live resources"
	@echo "  make logs    follow LocalStack logs"

up:
	./scripts/up.sh

down:
	./scripts/down.sh

status:
	./scripts/status.sh

logs:
	./scripts/logs.sh
