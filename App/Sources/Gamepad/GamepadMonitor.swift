import AppKit
import FaugusCore
import Foundation
import GameController

/// GameController wiring for `gamepad.py`: A confirm, B back, X kill, Y menu, LB add, RB
/// settings, Menu power; left-stick gate 0.7/0.3; hold-repeat 0.5 then 0.1; right-stick
/// scroll; ignored while a game is running.
@MainActor
final class GamepadMonitor {
    private weak var model: AppModel?
    private let cursor = CursorHider()
    private var stickGate = GamepadStickGate()
    private var repeater = GamepadHoldRepeater()
    private var rightStickX = 0.0
    private var rightStickY = 0.0
    private var previousButtons: Set<GamepadRole> = []
    private var tick: Timer?
    private var lastTick: TimeInterval = 0
    private var keyMonitor: Any?
    private var connectToken: NSObjectProtocol?
    private var disconnectToken: NSObjectProtocol?

    init(model: AppModel) {
        self.model = model
        cursor.start()
        observeControllers()
        installKeyMonitor()
        GCController.startWirelessControllerDiscovery()
        tick = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        lastTick = ProcessInfo.processInfo.systemUptime
    }

    func stop() {
        tick?.invalidate()
        tick = nil
        cursor.stop()
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
        if let connectToken {
            NotificationCenter.default.removeObserver(connectToken)
        }
        if let disconnectToken {
            NotificationCenter.default.removeObserver(disconnectToken)
        }
        GCController.stopWirelessControllerDiscovery()
    }

    private func observeControllers() {
        let center = NotificationCenter.default
        connectToken = center.addObserver(
            forName: .GCControllerDidConnect, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.bindHandlers() }
        }
        disconnectToken = center.addObserver(
            forName: .GCControllerDidDisconnect, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                _ = self?.repeater.setHeld(nil, now: ProcessInfo.processInfo.systemUptime)
                self?.previousButtons = []
            }
        }
        bindHandlers()
    }

    private func bindHandlers() {
        for controller in GCController.controllers() {
            controller.extendedGamepad?.valueChangedHandler = { [weak self] pad, _ in
                DispatchQueue.main.async { self?.handle(pad) }
            }
        }
    }

    private func handle(_ pad: GCExtendedGamepad) {
        guard let model, model.isGamepadUsable else {
            _ = repeater.setHeld(nil, now: ProcessInfo.processInfo.systemUptime)
            return
        }
        cursor.hide()
        readButtons(pad)
        readDpadAndStick(pad)
        rightStickX = GamepadScroll.filteredAxis(Double(pad.rightThumbstick.xAxis.value))
        rightStickY = GamepadScroll.filteredAxis(Double(pad.rightThumbstick.yAxis.value))
    }

    private func readButtons(_ pad: GCExtendedGamepad) {
        var pressed: Set<GamepadRole> = []
        if pad.buttonA.isPressed {
            pressed.insert(.confirm)
        }
        if pad.buttonB.isPressed {
            pressed.insert(.back)
        }
        if pad.buttonX.isPressed {
            pressed.insert(.kill)
        }
        if pad.buttonY.isPressed {
            pressed.insert(.menu)
        }
        if pad.leftShoulder.isPressed {
            pressed.insert(.add)
        }
        if pad.rightShoulder.isPressed {
            pressed.insert(.settings)
        }
        if pad.buttonMenu.isPressed {
            pressed.insert(.power)
        }
        let newly = pressed.subtracting(previousButtons)
        previousButtons = pressed
        guard let model else { return }
        for role in newly {
            switch role {
            case .confirm: model.handleGamepadConfirm()
            case .back: model.handleGamepadBack()
            case .kill: model.handleGamepadKill()
            case .menu: model.handleGamepadMenu()
            case .add: model.handleGamepadAdd()
            case .settings: model.handleGamepadSettings()
            case .power: model.handleGamepadPower()
            }
        }
    }

    private func readDpadAndStick(_ pad: GCExtendedGamepad) {
        let now = ProcessInfo.processInfo.systemUptime
        let dpadDirection: GamepadDirection? =
            if pad.dpad.up.isPressed {
                .upward
            } else if pad.dpad.down.isPressed {
                .downward
            } else if pad.dpad.left.isPressed {
                .left
            } else if pad.dpad.right.isPressed {
                .right
            } else {
                nil
            }

        if let dpadDirection {
            if repeater.setHeld(dpadDirection, now: now) {
                model?.handleGamepadDirection(dpadDirection)
            }
            return
        }

        let fired = stickGate.process(
            x: Double(pad.leftThumbstick.xAxis.value),
            y: -Double(pad.leftThumbstick.yAxis.value)
        )
        if let fired {
            if repeater.setHeld(fired, now: now) {
                model?.handleGamepadDirection(fired)
            }
        } else if dpadDirection == nil, abs(Double(pad.leftThumbstick.xAxis.value)) < GamepadStickGate.resetThreshold,
                  abs(Double(pad.leftThumbstick.yAxis.value)) < GamepadStickGate.resetThreshold
        {
            _ = repeater.setHeld(nil, now: now)
        }
    }

    private func step() {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - lastTick
        lastTick = now
        guard let model else { return }
        if !model.isGamepadUsable {
            _ = repeater.setHeld(nil, now: now)
            return
        }
        if repeater.tick(now: now), let held = repeater.held {
            cursor.hide()
            model.handleGamepadDirection(held)
        }
        if rightStickX != 0 || rightStickY != 0 {
            cursor.hide()
            model.handleGamepadScroll(
                deltaX: GamepadScroll.delta(axis: rightStickX, elapsed: elapsed),
                deltaY: GamepadScroll.delta(axis: -rightStickY, elapsed: elapsed)
            )
        }
    }

    /// Alt+Enter toggles fullscreen; Escape in fullscreen opens the power menu.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let keyCode = event.keyCode
            let optionHeld = event.modifierFlags.contains(.option)
            var swallow = false
            MainActor.assumeIsolated {
                swallow = self.handleKeyCode(keyCode, optionHeld: optionHeld)
            }
            return swallow ? nil : event
        }
    }

    private func handleKeyCode(_ keyCode: UInt16, optionHeld: Bool) -> Bool {
        guard let model else { return false }
        if optionHeld, keyCode == 36, model.interfaceMode != .list {
            NSApp.keyWindow?.toggleFullScreen(nil)
            return true
        }
        if keyCode == 53, shouldOpenPowerMenu(model: model) {
            model.openPowerMenu()
            return true
        }
        return false
    }

    private func shouldOpenPowerMenu(model: AppModel) -> Bool {
        guard let window = NSApp.keyWindow else { return false }
        guard window.styleMask.contains(.fullScreen) else { return false }
        if model.showGamepadOverlay || model.showSettings || model.runningGameWarning != nil {
            return false
        }
        if window.isSheet || window.sheetParent != nil || !window.sheets.isEmpty {
            return false
        }
        return true
    }
}
