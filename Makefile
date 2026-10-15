# NightKeys: `make` builds .build/NightKeys.app (hidden, so Spotlight does not list the build copy), `make install` copies it to /Applications and opens it.
# `make dmg` builds the disk image; `make release` builds, notarizes and staples it (Developer ID required).
VERSION  := 1.0.0
BUILD    ?= .build
APP      := $(BUILD)/NightKeys.app
STAGE    := $(BUILD)/stage/NightKeys.app
CONTENTS := $(STAGE)/Contents
AGENT_ID := io.github.fratayaydn.nightkeys.agent
MIN_OS   := 13.0
ARCH     := $(shell uname -m)
CFLAGS   := -O2 -fobjc-arc -Wall -mmacosx-version-min=$(MIN_OS)

# Code signing identity. The default is a self-signed certificate created once per Mac by
# scripts/create-signing-identity.sh: a fixed signature keeps Input Monitoring permission and the login item
# working across rebuilds (an ad-hoc signature changes with every build). For distribution use Developer ID:
#   make SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
SIGN_IDENTITY ?= Local Code Signing
TIMESTAMP     ?=
SIGN_FLAGS    := --force --options runtime $(TIMESTAMP) --sign "$(SIGN_IDENTITY)"

# Release builds go to their own folder, signed with Developer ID and a secure timestamp (notarization needs both).
# Set RELEASE_IDENTITY (and NOTARY_PROFILE if yours differs) on the command line or in release.local.mk, which is
# not committed:
#   RELEASE_IDENTITY := Developer ID Application: Your Name (TEAMID)
-include release.local.mk
RELEASE_DIR      := .build/release
RELEASE_IDENTITY ?=
NOTARY_PROFILE   ?= nightkeys-notary
DMG              := $(RELEASE_DIR)/NightKeys-$(VERSION).dmg

AGENT_SRC := Sources/Agent/nightkeysd.m
APP_SRC   := Sources/App/NightKeysApp.swift
BRIDGE    := Sources/App/NightKeysBridge

.PHONY: all clean install uninstall signing-identity release-app dmg release

all: $(APP)

signing-identity:
	@if [ "$(SIGN_IDENTITY)" = "Local Code Signing" ]; then ./scripts/create-signing-identity.sh "$(SIGN_IDENTITY)"; fi

# signing-identity is order-only (after |): it must exist, but checking for it must not force a rebuild.
$(APP): $(AGENT_SRC) $(APP_SRC) $(BRIDGE).h $(BRIDGE).m Resources/Info.plist Resources/$(AGENT_ID).plist $(wildcard Resources/AppIcon.icns) | signing-identity
	rm -rf $(STAGE)
	mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources $(CONTENTS)/Library/LaunchAgents
	clang $(CFLAGS) -framework Foundation -framework IOKit $(AGENT_SRC) -o $(CONTENTS)/MacOS/nightkeysd
	clang $(CFLAGS) -c $(BRIDGE).m -o $(BUILD)/NightKeysBridge.o
	swiftc -O -swift-version 5 -parse-as-library -target $(ARCH)-apple-macos$(MIN_OS) -import-objc-header $(BRIDGE).h \
		$(APP_SRC) $(BUILD)/NightKeysBridge.o -o $(CONTENTS)/MacOS/NightKeys
	sed -e 's/VERSION/$(VERSION)/' -e "s/BUILD_ID/$$(date +%Y%m%d%H%M%S)/" Resources/Info.plist > $(CONTENTS)/Info.plist
	cp Resources/$(AGENT_ID).plist $(CONTENTS)/Library/LaunchAgents/
	if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns $(CONTENTS)/Resources/; fi
	codesign $(SIGN_FLAGS) --identifier $(AGENT_ID) $(CONTENTS)/MacOS/nightkeysd
	codesign $(SIGN_FLAGS) $(STAGE)
	rm -rf $(APP)
	mv $(STAGE) $(APP)

# scripts/install.sh replaces the app and keeps the background agent working across updates.
install: $(APP)
	./scripts/install.sh $(APP)

release-app:
	@if [ -z "$(RELEASE_IDENTITY)" ]; then echo "Set RELEASE_IDENTITY (see the Makefile)."; exit 1; fi
	rm -rf $(RELEASE_DIR)
	$(MAKE) BUILD=$(RELEASE_DIR) SIGN_IDENTITY="$(RELEASE_IDENTITY)" TIMESTAMP=--timestamp

# Disk image only, without notarization: for checking the window layout.
dmg: release-app
	./scripts/make-dmg.sh $(RELEASE_DIR)/NightKeys.app $(DMG) "$(RELEASE_IDENTITY)"

release: release-app
	./scripts/release.sh $(RELEASE_DIR)/NightKeys.app $(DMG) "$(RELEASE_IDENTITY)" $(NOTARY_PROFILE)

uninstall:
	-pkill -x NightKeys
	-/Applications/NightKeys.app/Contents/MacOS/NightKeys --unregister
	-launchctl bootout gui/$$(id -u)/$(AGENT_ID) 2>/dev/null
	rm -rf /Applications/NightKeys.app
	defaults delete io.github.fratayaydn.nightkeys 2>/dev/null || true
	@echo "NightKeys removed. Also remove it from System Settings > Privacy & Security > Input Monitoring."

clean:
	rm -rf .build
