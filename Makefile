.PHONY: bootstrap project build test run clean lint format

bootstrap:
	@command -v xcodegen >/dev/null || brew install xcodegen
	@command -v swiftlint >/dev/null || brew install swiftlint
	@command -v swiftformat >/dev/null || brew install swiftformat
	git submodule update --init --recursive

project:
	xcodegen generate

build: project
	xcodebuild -project FaugusForMac.xcodeproj -scheme Faugus -configuration Debug \
		-derivedDataPath build build

test:
	cd Packages/FaugusCore && swift test

run: build
	open "build/Build/Products/Debug/Faugus for Mac.app"

# Check style without changing anything (what CI runs).
lint:
	swiftformat . --lint
	swiftlint lint --strict

# Rewrite the code to the project style (SwiftFormat, then SwiftLint's autocorrectable rules).
format:
	swiftformat .
	swiftlint lint --fix --quiet
	swiftformat .

clean:
	rm -rf build .build Packages/FaugusCore/.build FaugusForMac.xcodeproj
