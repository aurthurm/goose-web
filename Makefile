PYTHON ?= python3
GOOSE ?= goose
ENTRY ?= $(if $(wildcard server.goose),server.goose,examples/hello/server.goose)
OUTPUT ?= build/server
PORT ?= 8080
ARGS ?=
export GOOSE

.DEFAULT_GOAL := help
.PHONY: help toolchain fetch check build release run dev test ci docs docs-serve new

help:
	@$(PYTHON) manage.py --help
	@echo "Make variables: ENTRY=$(ENTRY) OUTPUT=$(OUTPUT) PORT=$(PORT) GOOSE=$(GOOSE)"

toolchain fetch check:
	$(PYTHON) manage.py $@ $(if $(filter fetch check,$@),--entry "$(ENTRY)")

build:
	$(PYTHON) manage.py build --entry "$(ENTRY)" --output "$(OUTPUT)"

release:
	$(PYTHON) manage.py build --release --entry "$(ENTRY)" --output "$(OUTPUT)"

run:
	$(PYTHON) manage.py run --entry "$(ENTRY)" --output "$(OUTPUT)" -- $(ARGS)

dev:
	$(PYTHON) manage.py dev --entry "$(ENTRY)" --port "$(PORT)" -- $(ARGS)

test ci docs:
	$(PYTHON) manage.py $@

docs-serve:
	$(PYTHON) manage.py docs --serve --port "$(PORT)"

new:
	$(PYTHON) manage.py new "$(NAME)" $(if $(DIR),"$(DIR)") $(if $(SOURCE),--source "$(SOURCE)")
