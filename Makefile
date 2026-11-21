.PHONY: build test install

build:
	swift build -c release
	mkdir -p build
	bin_dir="$$(swift build -c release --show-bin-path)" && \
	rm -f build/agy-cs && \
	cp -f "$$bin_dir/agy-cs" build/agy-cs && \
	codesign --force --sign - build/agy-cs && \
	rm -rf build/agy-cs_AgyAccount.bundle && \
	cp -R "$$bin_dir/agy-cs_AgyAccount.bundle" build/agy-cs_AgyAccount.bundle

test:
	swift test --disable-sandbox

install: build
	mkdir -p "$(HOME)/.local/bin"
	ln -sfn "$(CURDIR)/build/agy-cs" "$(HOME)/.local/bin/agy-cs"
