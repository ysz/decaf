# Decaf — build + install
#
# Targets:
#   make app              Build the Swift menubar .app bundle (app/build/Decaf.app)
#                         with the bash engine embedded under Contents/Resources/cli/.
#   make install          Build the app + copy to /Applications and launch it.
#                         No sudo, no /usr/local/bin install — everything the
#                         app needs is inside the bundle.
#   make cli              OPTIONAL: also install bash decaf into /usr/local/bin
#                         so it's callable from the terminal (for SSH/headless
#                         use). The menubar app does NOT need this.
#   make uninstall        Remove .app, LaunchAgent, Claude Code hooks, any
#                         legacy /usr/local/bin install, and ~/.decaf.
#   make clean            Remove build artifacts (does not touch installed files)
#   make release VERSION=x.y.z
#                         Bump version everywhere, commit, tag vX.Y.Z (push it
#                         + create a GitHub release to surface the update to
#                         users — the in-app Updater polls Releases API).
#
# Requires: Xcode Command Line Tools (`xcode-select --install`).
# Targets host arch only (Apple Silicon for most users) — matches the engine's targeting.
# For a universal arm64+x86_64 build, install full Xcode and add
# `--arch arm64 --arch x86_64` to the swift build command.

SWIFT_DIR    := app
ENGINE_DIR   := engine
BUILD_DIR    := $(SWIFT_DIR)/build
APP_NAME     := Decaf
APP_BUNDLE   := $(BUILD_DIR)/$(APP_NAME).app
APP_BIN      := $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
APP_PLIST    := $(APP_BUNDLE)/Contents/Info.plist
INSTALL_DIR  := /Applications

.PHONY: all app cli install uninstall clean check-swift release icon

all: app

check-swift:
	@xcrun --find swift >/dev/null 2>&1 || { \
	  echo "ERROR: swift toolchain not available."; \
	  echo "Run: xcode-select --install"; exit 1; \
	}

app: check-swift
	@echo "→ Building $(APP_NAME).app"
	@cd $(SWIFT_DIR) && swift build -c release > /tmp/decaf-build.log 2>&1 \
	  || { cat /tmp/decaf-build.log; exit 1; }
	@grep -vE '^Building for production|^\[[0-9]+/[0-9]+\]|^Build complete' /tmp/decaf-build.log || true
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS $(APP_BUNDLE)/Contents/Resources $(APP_BUNDLE)/Contents/Resources/cli
	@cp $(SWIFT_DIR)/.build/release/$(APP_NAME) $(APP_BIN)
	@cp $(SWIFT_DIR)/Resources/Info.plist $(APP_PLIST)
	@cp $(SWIFT_DIR)/Sources/decaf/Resources/*.svg $(APP_BUNDLE)/Contents/Resources/ 2>/dev/null || true
	@cp $(SWIFT_DIR)/Resources/AppIcon.icns $(APP_BUNDLE)/Contents/Resources/ 2>/dev/null || true
	@# Embed bash engine inside the bundle so a dragged .app is fully self-contained
	@# (no /usr/local/bin install needed). Controller.swift looks here first.
	@cp $(ENGINE_DIR)/decaf $(ENGINE_DIR)/decaf-hook.sh \
	    $(ENGINE_DIR)/decaf-failsafe.sh $(ENGINE_DIR)/decaf-install-sudoers.sh \
	    $(APP_BUNDLE)/Contents/Resources/cli/
	@chmod +x $(APP_BUNDLE)/Contents/Resources/cli/*
	@codesign --force --deep --sign - $(APP_BUNDLE) 2>/dev/null
	@echo "✓ Built $(APP_BUNDLE)"

ICON_SRC := $(SWIFT_DIR)/Resources/AppIcon.png
ICON_OUT := $(SWIFT_DIR)/Resources/AppIcon.icns

# Regenerate AppIcon.icns from AppIcon.png. The PNG is the committed
# 1024×1024 master (already a Big Sur squircle); sips downscales to every
# size iconutil requires, then iconutil packs them into the .icns.
icon:
	@test -f $(ICON_SRC) || { echo "missing $(ICON_SRC)"; exit 1; }
	@tmp=$$(mktemp -d)/Decaf.iconset && mkdir -p $$tmp && \
	  for spec in 16:icon_16x16 32:icon_16x16@2x 32:icon_32x32 \
	              64:icon_32x32@2x 128:icon_128x128 256:icon_128x128@2x \
	              256:icon_256x256 512:icon_256x256@2x 512:icon_512x512 \
	              1024:icon_512x512@2x; do \
	    px=$${spec%:*}; name=$${spec#*:}; \
	    sips -z $$px $$px $(ICON_SRC) --out $$tmp/$$name.png >/dev/null; \
	  done && \
	  iconutil -c icns $$tmp -o $(ICON_OUT) && \
	  rm -rf $$(dirname $$tmp)
	@echo "✓ wrote $(ICON_OUT)"

cli:
	@cd $(ENGINE_DIR) && ./install.sh

install: app
	@pkill -f 'Decaf.app/Contents/MacOS' 2>/dev/null || true
	@rm -rf $(INSTALL_DIR)/$(APP_NAME).app
	@cp -R $(APP_BUNDLE) $(INSTALL_DIR)/
	@open $(INSTALL_DIR)/$(APP_NAME).app
	@echo "✓ Installed to $(INSTALL_DIR)/$(APP_NAME).app and launched"
	@echo ""
	@echo "  Look for the ☕ icon in your menubar (top-right of the screen)."
		@echo "  Click it → 'Set up auto-sleep for Claude Code / Codex' to finish setup."

uninstall:
	@cd $(ENGINE_DIR) && ./uninstall.sh

clean:
	@rm -rf $(BUILD_DIR)
	@cd $(SWIFT_DIR) && rm -rf .build

# Tag a new release. Bumps CFBundleShortVersionString in Info.plist and the
# bash decaf's VERSION line, commits the bump, tags vX.Y.Z, pushes both.
# Usage: make release VERSION=1.5.0
# The Updater in the menubar app polls api.github.com/repos/ysz/decaf and
# pings users when a newer tag appears here.
release:
	@test -n "$(VERSION)" || { echo "usage: make release VERSION=x.y.z"; exit 2; }
	@echo "$(VERSION)" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$$' \
	  || { echo "VERSION must be N.N.N (got '$(VERSION)')"; exit 2; }
	@test -z "$$(git status --porcelain)" \
	  || { echo "working tree dirty — commit or stash first"; exit 2; }
	@/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" \
	  $(SWIFT_DIR)/Resources/Info.plist
	@/usr/bin/sed -i '' -E 's/^VERSION="[^"]+"/VERSION="$(VERSION)"/' $(ENGINE_DIR)/decaf
	@git add $(SWIFT_DIR)/Resources/Info.plist $(ENGINE_DIR)/decaf
	@git commit -m "Release v$(VERSION)"
	@git tag "v$(VERSION)"
	@echo ""
	@echo "✓ Committed + tagged v$(VERSION). To publish:"
	@echo "    git push && git push --tags"
	@echo "    gh release create v$(VERSION) --generate-notes"
