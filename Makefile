APP_NAME  = JenaFile
MAC_DIR   = apps/macos
BUILD_DIR = build
BUNDLE    = $(BUILD_DIR)/$(APP_NAME).app
INSTALL_DIR = /Applications
DMG       = $(BUILD_DIR)/jenaFile.dmg

.PHONY: app run install uninstall dmg core test test-core test-app clean

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

## /Applications 에 설치. 실행 중이면 먼저 종료한다.
install: app
	@osascript -e 'tell application id "com.jenalab.jenafile" to quit' >/dev/null 2>&1 || true
	@mkdir -p $(INSTALL_DIR)
	@rm -rf $(INSTALL_DIR)/$(APP_NAME).app
	@cp -R $(BUNDLE) $(INSTALL_DIR)/
	@echo "✓ 설치 완료: $(INSTALL_DIR)/$(APP_NAME).app"

uninstall:
	@rm -rf $(INSTALL_DIR)/$(APP_NAME).app
	@echo "✓ 제거 완료: $(INSTALL_DIR)/$(APP_NAME).app (설정·서버 목록은 ~/Library/Application Support/jena-file 에 남아 있어요)"

## 배포용 디스크 이미지 → build/jenaFile.dmg (앱 + Applications 바로가기)
dmg: app
	@rm -rf $(BUILD_DIR)/dmg && mkdir -p $(BUILD_DIR)/dmg
	@cp -R $(BUNDLE) $(BUILD_DIR)/dmg/
	@ln -s /Applications $(BUILD_DIR)/dmg/Applications
	@xattr -cr $(BUILD_DIR)/dmg/$(APP_NAME).app
	@hdiutil create -volname "jena-file" -srcfolder $(BUILD_DIR)/dmg -ov -format UDZO $(DMG) >/dev/null
	@rm -rf $(BUILD_DIR)/dmg
	@echo "✓ DMG 생성: $(DMG)"

test: test-core test-app

test-core:
	cd core && cargo test

test-app: core
	cd $(MAC_DIR) && swift test

clean:
	@rm -rf $(BUILD_DIR) $(MAC_DIR)/.build $(MAC_DIR)/Vendor core/target
	@rm -f $(MAC_DIR)/Sources/JenaFileCore/*.swift
	@echo "✓ 정리 완료"
