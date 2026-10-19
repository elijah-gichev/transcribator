.PHONY: setup build run cli clean

setup:
	./scripts/setup_backend.sh

build:
	./scripts/build_app.sh

run: build
	open build/Transcribator.app

cli:
	.venv/bin/python backend/cli.py $(FILE)

clean:
	rm -rf build macapp/.build
