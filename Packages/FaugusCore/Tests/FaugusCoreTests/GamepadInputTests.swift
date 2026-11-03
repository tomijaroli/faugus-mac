@testable import FaugusCore
import Testing

@Suite("Gamepad")
struct GamepadInputTests {
    @Test func stickFiresOnceUntilItReturnsBelowReset() {
        var gate = GamepadStickGate()
        let rest = gate.process(x: 0.2, y: -0.2)
        let firstUp = gate.process(x: 0, y: -0.8)
        let heldUp = gate.process(x: 0, y: -0.9)
        let stillHeld = gate.process(x: 0, y: -0.4)
        let reset = gate.process(x: 0, y: -0.2)
        let secondUp = gate.process(x: 0, y: -0.8)
        let right = gate.process(x: 0.8, y: 0)
        #expect(rest == nil)
        #expect(firstUp == .upward)
        #expect(heldUp == nil)
        #expect(stillHeld == nil)
        #expect(reset == nil)
        #expect(secondUp == .upward)
        #expect(right == .right)
    }

    @Test func holdRepeatsAfterHalfASecondThenEveryTenth() {
        var repeater = GamepadHoldRepeater()
        let started = repeater.setHeld(.downward, now: 1.0)
        let stillHeld = repeater.setHeld(.downward, now: 1.2)
        let beforeDelay = repeater.tick(now: 1.4)
        let firstRepeat = repeater.tick(now: 1.5)
        let tooSoon = repeater.tick(now: 1.55)
        let secondRepeat = repeater.tick(now: 1.6)
        let released = repeater.setHeld(nil, now: 1.7)
        let afterRelease = repeater.tick(now: 2.0)
        #expect(started)
        #expect(!stillHeld)
        #expect(!beforeDelay)
        #expect(firstRepeat)
        #expect(!tooSoon)
        #expect(secondRepeat)
        #expect(!released)
        #expect(!afterRelease)
    }

    @Test func replacingTheHeldDirectionFiresImmediately() {
        var repeater = GamepadHoldRepeater()
        let first = repeater.setHeld(.left, now: 0)
        let replaced = repeater.setHeld(.right, now: 0.1)
        #expect(first)
        #expect(replaced)
    }

    @Test func scrollUsesSquaredMagnitudeAndDeadzone() {
        #expect(GamepadScroll.filteredAxis(0.1) == 0)
        #expect(GamepadScroll.filteredAxis(0.5) == 0.5)
        #expect(GamepadScroll.delta(axis: 0.1, elapsed: 1) == 0)
        #expect(GamepadScroll.delta(axis: 0.5, elapsed: 0.1) == 0.5 * 0.5 * 1600 * 0.1)
        #expect(GamepadScroll.delta(axis: -0.5, elapsed: 0.1) == -0.5 * 0.5 * 1600 * 0.1)
    }

    @Test func libraryNavigationMovesByColumns() {
        #expect(GamepadLibraryNavigation.nextIndex(current: 5, count: 12, direction: .upward, columns: 4) == 1)
        #expect(GamepadLibraryNavigation.nextIndex(current: 1, count: 12, direction: .upward, columns: 4) == nil)
        #expect(GamepadLibraryNavigation.nextIndex(current: 5, count: 12, direction: .downward, columns: 4) == 9)
        #expect(GamepadLibraryNavigation.nextIndex(
            current: 9, count: 12, direction: .downward, columns: 4
        ) == nil)
        #expect(GamepadLibraryNavigation.nextIndex(current: 5, count: 12, direction: .left, columns: 4) == 4)
        #expect(GamepadLibraryNavigation.nextIndex(current: 0, count: 12, direction: .left, columns: 4) == nil)
        #expect(GamepadLibraryNavigation.nextIndex(current: 5, count: 12, direction: .right, columns: 4) == 6)
    }

    @Test func carrouselNavigationWrapsLeftAndRight() {
        #expect(GamepadLibraryNavigation.nextIndex(
            current: 0, count: 5, direction: .left, columns: 1, wraps: true
        ) == 4)
        #expect(GamepadLibraryNavigation.nextIndex(
            current: 4, count: 5, direction: .right, columns: 1, wraps: true
        ) == 0)
    }

    @Test func consoleModeOverridesAreRuntimeOnly() {
        #expect(ConsoleMode.interfaceMode(isConsole: true, stored: .list) == .carrousel)
        #expect(ConsoleMode.interfaceMode(isConsole: false, stored: .grid) == .grid)
        #expect(ConsoleMode.gamepadEnabled(isConsole: true, stored: false))
        #expect(!ConsoleMode.gamepadEnabled(isConsole: false, stored: false))
        #expect(ConsoleMode.startupWindowSize(isConsole: true, stored: "None") == "Fullscreen")
        #expect(ConsoleMode.startupWindowSize(isConsole: false, stored: "Remember") == "Remember")
    }
}
