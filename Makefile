APP_NAME  = JenaFile
MAC_DIR   = apps/macos
BUILD_DIR = build
BUNDLE    = $(BUILD_DIR)/$(APP_NAME).app

.PHONY: app run core test test-core test-app clean

## Rust core → xcframework + Swift bindings
core:
	@scripts/build-core.sh

## core + Swift app → build/JenaFile.app (ad-hoc signed)
app: core
	cd $(MAC_DIR) && swift build -c release --product $(APP_NAME)
	@rm -rf $(BUNDLE) && mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	@cp $(MAC_DIR)/.build/release/$(APP_NAME) $(BUNDLE)/Contents/MacOS/
	@cp $(MAC_DIR)/Resources/Info.plist $(BUNDLE)/Contents/
	@cp $(MAC_DIR)/Resources/JenaFile.icns $(BUNDLE)/Contents/Resources/
	@codesign -s - --force $(BUNDLE) >/dev/null 2>&1
	@echo "✓ 빌드 완료: $(BUNDLE)"

run: app
	@open $(BUNDLE)

test: test-core test-app

test-core:
	cd core && cargo test

test-app: core
	cd $(MAC_DIR) && swift test

clean:
	@rm -rf $(BUILD_DIR) $(MAC_DIR)/.build $(MAC_DIR)/Vendor core/target
	@rm -f $(MAC_DIR)/Sources/JenaFileCore/*.swift
	@echo "✓ 정리 완료"
