# Faugus for Mac

Unofficial macOS (Apple Silicon) port of [Faugus Launcher](https://github.com/Faugus/faugus-launcher)
2.5.6. Not affiliated with upstream.

Games run through Wine (Gcenx macOS builds, x86_64 under Rosetta 2) with DXVK-macOS
or WineD3D. See `docs/PLAN.md` for the full plan and `docs/parity.md` for status.

## Build

```sh
make bootstrap   # brew install xcodegen, init submodule
make test        # swift test for FaugusCore
make build       # generate the Xcode project and build the app
```

Requires macOS 14+, Xcode 16+, Apple Silicon.
