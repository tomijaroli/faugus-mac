.PHONY: bootstrap project build test run clean

bootstrap:
	@command -v xcodegen >/dev/null || brew install xcodegen
	git submodule update --init --recursive

project:
	xcodegen generate

build: project
	xcodebuild -project FaugusForMac.xcodeproj -scheme Faugus -configuration Debug \
		-derivedDataPath build CODE_SIGNING_ALLOWED=NO build

test:
	cd Packages/FaugusCore && swift test

run: build
	open "build/Build/Products/Debug/Faugus for Mac.app"

clean:
	rm -rf build .build Packages/FaugusCore/.build FaugusForMac.xcodeproj
