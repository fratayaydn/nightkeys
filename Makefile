# NightKeys: `make` builds .build/NightKeys.app (hidden, so Spotlight does not list the build copy), `make install` copies it to /Applications and opens it.
# `make dmg` builds the disk image; `make release` builds, notarizes and staples it (Developer ID required).
VERSION  := 1.0.3
BUILD    ?= .build
APP      := $(BUILD)/NightKeys.app
STAGE    := $(BUILD)/stage/NightKeys.app
CONTENTS := $(STAGE)/Contents
AGENT_ID := io.github.fratayaydn.nightkeys.agent
UPDATER_ID := io.github.fratayaydn.nightkeys.updater
MIN_OS   := 13.0
ARCH     := $(shell uname -m)
CFLAGS   := -O2 -fobjc-arc -Wall -Werror -mmacosx-version-min=$(MIN_OS)
DIAGNOSTIC_LOG ?= 0
ifeq ($(DIAGNOSTIC_LOG),1)
AGENT_DIAGNOSTIC_FLAGS := -DNIGHTKEYS_DIAGNOSTIC_LOG
endif

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

AGENT_SRC := Sources/Agent/nightkeysd.m Sources/Agent/Updater.m
AGENT_HEADERS := Sources/Agent/Updater.h Sources/Agent/DiagnosticLog.h
APP_SRC   := Sources/App/NightKeysApp.swift
BRIDGE    := Sources/App/NightKeysBridge

.PHONY: all test clean install uninstall signing-identity release-app dmg release updater-test-agent diagnostic FORCE

all: $(APP)

# Local troubleshooting build with an in-memory diagnostic log.
diagnostic:
	$(MAKE) DIAGNOSTIC_LOG=1 all

FORCE:

$(BUILD)/agent-build-mode: FORCE
	@mkdir -p $(BUILD)
	@if [ ! -f $@ ] || [ "$$(cat $@)" != "$(DIAGNOSTIC_LOG)" ]; then echo "$(DIAGNOSTIC_LOG)" > $@; fi

signing-identity:
	@if [ "$(SIGN_IDENTITY)" = "Local Code Signing" ]; then ./scripts/create-signing-identity.sh "$(SIGN_IDENTITY)"; fi

# signing-identity is order-only (after |): it must exist, but checking for it must not force a rebuild.
$(APP): $(AGENT_SRC) $(AGENT_HEADERS) $(APP_SRC) $(BRIDGE).h $(BRIDGE).m Resources/Info.plist Resources/$(AGENT_ID).plist Resources/$(UPDATER_ID).plist $(wildcard Resources/AppIcon.icns) $(BUILD)/agent-build-mode Makefile | signing-identity
	rm -rf $(STAGE)
	mkdir -p $(BUILD)/module-cache $(CONTENTS)/MacOS $(CONTENTS)/Resources $(CONTENTS)/Library/LaunchAgents
	clang $(CFLAGS) $(AGENT_DIAGNOSTIC_FLAGS) -framework AppKit -framework Foundation -framework IOKit -framework Security $(AGENT_SRC) -o $(CONTENTS)/MacOS/nightkeysd
	clang $(CFLAGS) -c $(BRIDGE).m -o $(BUILD)/NightKeysBridge.o
	swiftc -O -warnings-as-errors -module-cache-path $(BUILD)/module-cache -swift-version 5 -parse-as-library -target $(ARCH)-apple-macos$(MIN_OS) -import-objc-header $(BRIDGE).h \
		$(APP_SRC) $(BUILD)/NightKeysBridge.o -o $(CONTENTS)/MacOS/NightKeys
	sed -e 's/VERSION/$(VERSION)/' -e "s/BUILD_ID/$$(date +%Y%m%d%H%M%S)/" Resources/Info.plist > $(CONTENTS)/Info.plist
ifeq ($(DIAGNOSTIC_LOG),1)
	/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion $(VERSION)d1' $(CONTENTS)/Info.plist
endif
	cp Resources/$(AGENT_ID).plist Resources/$(UPDATER_ID).plist $(CONTENTS)/Library/LaunchAgents/
	if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns $(CONTENTS)/Resources/; fi
	codesign $(SIGN_FLAGS) --identifier $(AGENT_ID) $(CONTENTS)/MacOS/nightkeysd
	codesign $(SIGN_FLAGS) $(STAGE)
	rm -rf $(APP)
	mv $(STAGE) $(APP)

updater-test-agent: $(BUILD)/nightkeysd-updater-test

$(BUILD)/nightkeysd-updater-test: $(AGENT_SRC) $(AGENT_HEADERS)
	mkdir -p $(BUILD)
	clang $(CFLAGS) -DUPDATER_TEST_FEED -framework AppKit -framework Foundation -framework IOKit -framework Security $(AGENT_SRC) -o $@

# scripts/install.sh replaces the app and keeps the background agent working across updates.
install: $(APP)
	./scripts/install.sh $(APP)

release-app:
	@if [ -z "$(RELEASE_IDENTITY)" ]; then echo "Set RELEASE_IDENTITY (see the Makefile)."; exit 1; fi
	rm -rf $(RELEASE_DIR)
	$(MAKE) BUILD=$(RELEASE_DIR) SIGN_IDENTITY="$(RELEASE_IDENTITY)" TIMESTAMP=--timestamp DIAGNOSTIC_LOG=0 AGENT_DIAGNOSTIC_FLAGS=

# Disk image only, without notarization: for checking the window layout.
dmg: release-app
	./scripts/make-dmg.sh $(RELEASE_DIR)/NightKeys.app $(DMG) "$(RELEASE_IDENTITY)"

release: release-app
	./scripts/release.sh $(RELEASE_DIR)/NightKeys.app $(DMG) "$(RELEASE_IDENTITY)" $(NOTARY_PROFILE)

uninstall:
	-pkill -x NightKeys
	-/Applications/NightKeys.app/Contents/MacOS/NightKeys --unregister
	-launchctl bootout gui/$$(id -u)/$(UPDATER_ID) 2>/dev/null
	-launchctl bootout gui/$$(id -u)/$(AGENT_ID) 2>/dev/null
	rm -rf /Applications/NightKeys.app
	defaults delete io.github.fratayaydn.nightkeys 2>/dev/null || true
	@echo "NightKeys removed. Also remove it from System Settings > Privacy & Security > Input Monitoring."

clean:
	rm -rf .build

# Checks use private fixtures and simulated notifications, without changing system settings.
test: $(BUILD)/updater-tests $(BUILD)/updater-tool-tests $(BUILD)/notification-tests $(BUILD)/backlight-tests $(BUILD)/nightkeysd-diagnostic-check $(BUILD)/diagnostic-tests
	$(BUILD)/updater-tests
	$(BUILD)/updater-tool-tests
	$(BUILD)/notification-tests
	$(BUILD)/backlight-tests
	$(BUILD)/diagnostic-tests

$(BUILD)/nightkeysd-diagnostic-check: $(AGENT_SRC) $(AGENT_HEADERS)
	mkdir -p $(BUILD)
	clang $(CFLAGS) -DNIGHTKEYS_DIAGNOSTIC_LOG -framework AppKit -framework Foundation -framework IOKit -framework Security $(AGENT_SRC) -o $@

$(BUILD)/diagnostic-tests: $(AGENT_SRC) $(AGENT_HEADERS) Tests/backlight.m Tests/diagnostic.m
	mkdir -p $(BUILD)
	clang $(CFLAGS) -DNIGHTKEYS_DIAGNOSTIC_LOG -framework AppKit -framework Foundation -framework IOKit -framework Security \
		Tests/diagnostic.m Sources/Agent/Updater.m -o $@

$(BUILD)/updater-tests: Sources/Agent/Updater.m $(AGENT_HEADERS) Tests/updater.m
	mkdir -p $(BUILD)
	clang $(CFLAGS) -Wextra -framework Foundation -framework Security Tests/updater.m Sources/Agent/Updater.m -o $@

$(BUILD)/updater-tool-tests: Sources/Agent/Updater.m $(AGENT_HEADERS) Tests/updater-tools.m
	mkdir -p $(BUILD)
	clang $(CFLAGS) -Wextra -framework Foundation -framework Security Tests/updater-tools.m -o $@

$(BUILD)/NightKeysBridge.o: $(BRIDGE).h $(BRIDGE).m
	mkdir -p $(BUILD)
	clang $(CFLAGS) -c $(BRIDGE).m -o $@

$(BUILD)/notification-tests: $(APP_SRC) $(BRIDGE).h $(BUILD)/NightKeysBridge.o Tests/notifications.swift
	mkdir -p $(BUILD)/module-cache
	swiftc -O -warnings-as-errors -module-cache-path $(BUILD)/module-cache -swift-version 5 -parse-as-library \
		-target $(ARCH)-apple-macos$(MIN_OS) -import-objc-header $(BRIDGE).h -DNOTIFICATION_TESTS \
		$(APP_SRC) $(BUILD)/NightKeysBridge.o Tests/notifications.swift -o $@

$(BUILD)/backlight-tests: $(AGENT_SRC) $(AGENT_HEADERS) Tests/backlight.m
	mkdir -p $(BUILD)
	clang $(CFLAGS) -framework AppKit -framework Foundation -framework IOKit -framework Security \
		Tests/backlight.m Sources/Agent/Updater.m -o $@
