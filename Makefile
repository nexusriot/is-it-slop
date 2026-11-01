# Build and packaging entry points for the is-it-slop CLI.
#
#   make                      # list targets
#   make build                # native release binary
#   make deb rpm              # Linux packages for the host target
#   make deb-static           # fully static (musl) .deb with no runtime dependencies
#   make archive TARGET=aarch64-unknown-linux-gnu BUILDER=zigbuild

SHELL := bash
.DEFAULT_GOAL := help

TARGET   ?= $(shell rustc -vV | sed -n 's/^host: //p')
PROFILE  ?= release
BUILDER  ?= cargo
DIST_DIR ?= $(CURDIR)/dist
TARGETS  ?=
PACKAGES ?= archive deb rpm

export PROFILE BUILDER DIST_DIR

VERSION := $(shell awk '/^\[package\]/{p=1;next} /^\[/{p=0} p&&/^version/{gsub(/.*= *"|".*/,"");print;exit}' is-it-slop/Cargo.toml)

.PHONY: help
help: ## Show this help
	@echo "is-it-slop $(VERSION) — host target: $(TARGET)"
	@echo
	@awk 'BEGIN{FS=":.*## "} /^[a-zA-Z0-9_-]+:.*## /{printf "  \033[36m%-15s\033[0m %s\n",$$1,$$2}' $(MAKEFILE_LIST)
	@echo
	@echo "Variables: TARGET=<triple> PROFILE=$(PROFILE) BUILDER=cargo|cross|zigbuild DIST_DIR=dist"
	@echo "           TARGETS=\"<triple> ...\" PACKAGES=\"$(PACKAGES)\" (for 'make all')"

.PHONY: build
build: ## Build the CLI binary for TARGET
	cargo build --locked -p is-it-slop --bin is-it-slop --profile $(PROFILE) --target $(TARGET)

.PHONY: archive
archive: ## Build TARGET and pack dist/is-it-slop-<version>-<target>.tar.gz (.zip on Windows)
	scripts/build-archive.sh $(TARGET)

.PHONY: archive-static
archive-static: ## Pack a fully static (musl) binary for TARGET's arch
	STATIC=1 scripts/build-archive.sh $(TARGET)

.PHONY: deb
deb: ## Build a .deb for TARGET into dist/ (Depends computed from the binary)
	scripts/build-deb.sh $(TARGET)

.PHONY: deb-static
deb-static: ## Build a fully static (musl) .deb with no dependencies (rust:alpine container if no musl-gcc)
	STATIC=1 scripts/build-deb.sh $(TARGET)

.PHONY: rpm
rpm: ## Build an .rpm for TARGET into dist/ (uses docker/podman if rpmbuild is missing)
	scripts/build-rpm.sh $(TARGET)

.PHONY: rpm-static
rpm-static: ## Build a fully static (musl) .rpm for TARGET's arch
	STATIC=1 scripts/build-rpm.sh $(TARGET)

.PHONY: packages
packages: deb rpm ## Build both .deb and .rpm for TARGET

.PHONY: all
all: ## Build PACKAGES for every target in TARGETS (default: this OS's usual targets)
	PACKAGES="$(PACKAGES)" scripts/build-all.sh $(TARGETS)

.PHONY: linux-x86_64 linux-aarch64 macos-aarch64 macos-x86_64 windows-x86_64 windows-aarch64
linux-x86_64: ## Archive + deb + rpm for x86_64-unknown-linux-gnu
	PACKAGES="$(PACKAGES)" scripts/build-all.sh x86_64-unknown-linux-gnu
linux-aarch64: ## Archive + deb + rpm for aarch64-unknown-linux-gnu (needs BUILDER=cross|zigbuild off-arch)
	PACKAGES="$(PACKAGES)" scripts/build-all.sh aarch64-unknown-linux-gnu
macos-aarch64: ## Archive for aarch64-apple-darwin (run on macOS)
	PACKAGES=archive scripts/build-all.sh aarch64-apple-darwin
macos-x86_64: ## Archive for x86_64-apple-darwin (run on macOS)
	PACKAGES=archive scripts/build-all.sh x86_64-apple-darwin
windows-x86_64: ## Zip for x86_64-pc-windows-msvc (run on Windows / Git Bash)
	PACKAGES=archive scripts/build-all.sh x86_64-pc-windows-msvc
windows-aarch64: ## Zip for aarch64-pc-windows-msvc (run on Windows / Git Bash)
	PACKAGES=archive scripts/build-all.sh aarch64-pc-windows-msvc

.PHONY: install
install: ## Install the CLI into ~/.cargo/bin from source
	cargo install --locked --path is-it-slop --force

.PHONY: clean
clean: ## Remove dist/ (cargo artifacts stay; use 'cargo clean' for those)
	rm -rf $(DIST_DIR)
