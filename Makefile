SHELL := /bin/bash
.DEFAULT_GOAL := help

.PHONY: help check test build universal run

help:
	@printf '%s\n' 'make check      Compile the native app' 'make test       Run Swift tests' 'make build      Package a release app for this Mac' 'make universal  Package Apple Silicon + Intel' 'make run        Package and open a debug app'

check:
	swift build

test:
	swift test --disable-xctest --enable-swift-testing

build:
	./scripts/package-app.sh

universal:
	./scripts/package-app.sh --universal

run:
	./scripts/package-app.sh --debug
	open build/ElegantClipbar.app
