.PHONY: build test install app dist locked-build locked-test locked-dist

APP_NAME := Agy Switcher

# 编译缓存只有一份，放在主目录的 .build 里；git worktree 里执行时也用主目录的那一份，不各存一份。
# 主目录是 .git 所在的文件夹；不在 git 仓库里时就用当前文件夹。
MAIN_DIR := $(shell common="$$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" && dirname "$$common")
SCRATCH := $(if $(MAIN_DIR),$(MAIN_DIR),$(CURDIR))/.build
SWIFT_FLAGS := --scratch-path "$(SCRATCH)"

# 同一时间只让一个文件夹编译。几个 worktree 共用一份缓存，编译出来的文件也在同一个位置：
# 不排队的话，这边刚编完还没拷走，那边就把它换成了另一个分支的。
# 锁被占着时先说一声，再等前一个做完。$(1) 是拿到锁之后要执行的目标。
LOCK := $(SCRATCH)/agy-cs-make.lock
define queued
mkdir -p "$(SCRATCH)" && \
{ /usr/bin/lockf -k -t 0 "$(LOCK)" true 2>/dev/null || echo "另一个文件夹正在用 $(SCRATCH) 编译，等它做完…"; } && \
/usr/bin/lockf -k "$(LOCK)" $(MAKE) --no-print-directory $(1)
endef
# 签名身份。默认 ad-hoc；有 Developer ID 证书时用 make dist SIGN_IDENTITY="Developer ID Application: …"。
SIGN_IDENTITY ?= -

# 发布包的名字带版本号和平台。版本号只写在 Packaging/Info.plist 里。
VERSION := $(shell plutil -extract CFBundleShortVersionString raw Packaging/Info.plist)
DMG := Agy-Switcher-v$(VERSION)-macOS-universal.dmg
TARBALL := agy-cs-v$(VERSION)-macOS-universal.tar.gz

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
	@$(call queued,locked-build)

locked-build:
	swift build -c release $(SWIFT_FLAGS)
	mkdir -p build
	bin_dir="$$(swift build -c release $(SWIFT_FLAGS) --show-bin-path)" && \
	rm -f build/agy-cs && \
	cp -f "$$bin_dir/agy-cs" build/agy-cs && \
	codesign --force --sign - build/agy-cs

# 只跑一部分测试：make test FILTER=testPanelPicturesWhenEnabled。环境变量照常写在 make 前面。
test:
	@$(call queued,locked-test)

locked-test:
	swift test --disable-sandbox $(SWIFT_FLAGS) $(if $(FILTER),--filter '$(subst ','"'"',$(FILTER))')

install: build
	mkdir -p "$(HOME)/.local/bin"
	ln -sfn "$(CURDIR)/build/agy-cs" "$(HOME)/.local/bin/agy-cs"

app: build
	$(call bundle,build/agy-cs,build/$(APP_NAME).app)

# 两个架构分开编译再用 lipo 合并。一次传两个 --arch 时，Xcode 26.6 的 SwiftPM 换用另一套构建系统，
# 它不生成 embedInCode 的 PackageResources，编译不过（CI 实测）。每个架构编完就拷走，
# 因为有的版本两次编译用同一个输出目录。
dist:
	@$(call queued,locked-dist)

locked-dist:
	rm -rf dist
	mkdir -p dist/thin dist/cli dist/app
	for arch in arm64 x86_64; do \
		swift build -c release $(SWIFT_FLAGS) --arch $$arch && \
		cp "$$(swift build -c release $(SWIFT_FLAGS) --arch $$arch --show-bin-path)/agy-cs" dist/thin/$$arch || exit 1; \
	done
	lipo -create -output dist/cli/agy-cs dist/thin/arm64 dist/thin/x86_64
	rm -rf dist/thin
	codesign --force --sign "$(SIGN_IDENTITY)" dist/cli/agy-cs
	$(call bundle,dist/cli/agy-cs,dist/app/$(APP_NAME).app)
	tar --no-mac-metadata -czf "dist/$(TARBALL)" -C dist/cli agy-cs
	ln -s /Applications dist/app/Applications
	hdiutil create -quiet -volname "$(APP_NAME)" -srcfolder dist/app -fs HFS+ -format UDZO -ov "dist/$(DMG)"
	cd dist && for file in "$(DMG)" "$(TARBALL)"; do shasum -a 256 "$$file" > "$$file.sha256" || exit 1; done
