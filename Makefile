.PHONY: build test install app dist

APP_NAME := Agy Switcher
# 签名身份。默认 ad-hoc；有 Developer ID 证书时用 make dist SIGN_IDENTITY="Developer ID Application: …"。
SIGN_IDENTITY ?= -

# $(1) 是编译好的 agy-cs，$(2) 是要生成的 .app。先删掉旧的再拷，原因和 build 里一样。
define bundle
rm -rf "$(2)" && \
mkdir -p "$(2)/Contents/MacOS" "$(2)/Contents/Resources" && \
cp Packaging/Info.plist "$(2)/Contents/Info.plist" && \
cp Packaging/AppIcon.icns "$(2)/Contents/Resources/AppIcon.icns" && \
cp "$(1)" "$(2)/Contents/MacOS/agy-cs" && \
codesign --force --sign "$(SIGN_IDENTITY)" "$(2)"
endef

build:
	swift build -c release
	mkdir -p build
	bin_dir="$$(swift build -c release --show-bin-path)" && \
	rm -f build/agy-cs && \
	cp -f "$$bin_dir/agy-cs" build/agy-cs && \
	codesign --force --sign - build/agy-cs

test:
	swift test --disable-sandbox

install: build
	mkdir -p "$(HOME)/.local/bin"
	ln -sfn "$(CURDIR)/build/agy-cs" "$(HOME)/.local/bin/agy-cs"

app: build
	$(call bundle,build/agy-cs,build/$(APP_NAME).app)

# 两个架构分开编译再用 lipo 合并。一次传两个 --arch 时，Xcode 26.6 的 SwiftPM 换用另一套构建系统，
# 它不生成 embedInCode 的 PackageResources，编译不过（CI 实测）。每个架构编完就拷走，
# 因为有的版本两次编译用同一个输出目录。
dist:
	rm -rf dist
	mkdir -p dist/thin dist/cli dist/app
	for arch in arm64 x86_64; do \
		swift build -c release --arch $$arch && \
		cp "$$(swift build -c release --arch $$arch --show-bin-path)/agy-cs" dist/thin/$$arch || exit 1; \
	done
	lipo -create -output dist/cli/agy-cs dist/thin/arm64 dist/thin/x86_64
	rm -rf dist/thin
	codesign --force --sign "$(SIGN_IDENTITY)" dist/cli/agy-cs
	$(call bundle,dist/cli/agy-cs,dist/app/$(APP_NAME).app)
	tar --no-mac-metadata -czf dist/agy-cs-macos-universal.tar.gz -C dist/cli agy-cs
	ditto -c -k --norsrc --noextattr --keepParent "dist/app/$(APP_NAME).app" dist/Agy-Switcher.zip
	cd dist && shasum -a 256 agy-cs-macos-universal.tar.gz Agy-Switcher.zip > SHA256SUMS.txt
