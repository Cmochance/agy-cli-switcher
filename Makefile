.PHONY: build test install

build:
	swift build -c release
	mkdir -p build
	cp -f "$$(swift build -c release --show-bin-path)/agy-cs" build/agy-cs

test:
	swift test --disable-sandbox

install: build
	mkdir -p "$(HOME)/.local/bin"
	ln -sfn "$(CURDIR)/build/agy-cs" "$(HOME)/.local/bin/agy-cs"
