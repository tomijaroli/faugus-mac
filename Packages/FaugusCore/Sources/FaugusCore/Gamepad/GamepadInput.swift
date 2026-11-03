import Foundation

/// README / `BUTTON_ROLES` mapping: Xbox names, with the PlayStation names in comments.
public enum GamepadRole: String, Sendable {
    /// A / Cross
    case confirm
    /// B / Circle
    case back
    /// X / Square
    case kill
    /// Y / Triangle
    case menu
    /// LB / L1
    case add
    /// RB / R1
    case settings
    /// Menu / Options
    case power
}

public enum GamepadDirection: Equatable, Sendable {
    case upward, downward, left, right

    public var isHorizontal: Bool {
        self == .left || self == .right
    }

    public var isVertical: Bool {
        self == .upward || self == .downward
    }
}

/// Left-stick gate: a direction fires once past 0.7 and will not fire again until the axis
/// falls below 0.3 (`axis_threshold` / `reset_threshold`).
public struct GamepadStickGate: Equatable, Sendable {
    public static let pressThreshold = 0.7
    public static let resetThreshold = 0.3

    public var canMoveX = true
    public var canMoveY = true

    public init() {}

    /// Returns the direction that just crossed the press threshold, if any.
    public mutating func process(x: Double, y: Double) -> GamepadDirection? {
        var fired: GamepadDirection?
        if canMoveY {
            if y < -Self.pressThreshold {
                fired = .upward
                canMoveY = false
            } else if y > Self.pressThreshold {
                fired = .downward
                canMoveY = false
            }
        } else if abs(y) < Self.resetThreshold {
            canMoveY = true
        }

        if canMoveX {
            if x < -Self.pressThreshold {
                fired = .left
                canMoveX = false
            } else if x > Self.pressThreshold {
                fired = .right
                canMoveX = false
            }
        } else if abs(x) < Self.resetThreshold {
            canMoveX = true
        }
        return fired
    }
}

/// Hold-to-repeat for D-pad and a latched stick direction: first fire immediately, then after
/// 0.5 s, then every 0.1 s (`repeat_delay` / `repeat_interval`).
public struct GamepadHoldRepeater: Equatable, Sendable {
    public static let repeatDelay: TimeInterval = 0.5
    public static let repeatInterval: TimeInterval = 0.1

    public private(set) var held: GamepadDirection?

    private var holdStart: TimeInterval = 0
    private var lastRepeat: TimeInterval = 0

    public init() {}

    /// Starts, replaces or clears the held direction. Returns `true` when a navigation should
    /// fire right now (a newly held direction).
    public mutating func setHeld(_ direction: GamepadDirection?, now: TimeInterval) -> Bool {
        if let direction {
            if held != direction {
                held = direction
                holdStart = now
                lastRepeat = now
                return true
            }
            return false
        }
        held = nil
        return false
    }

    /// Returns `true` when the held direction should fire again.
    public mutating func tick(now: TimeInterval) -> Bool {
        guard held != nil else { return false }
        guard now - holdStart >= Self.repeatDelay else { return false }
        guard now - lastRepeat >= Self.repeatInterval else { return false }
        lastRepeat = now
        return true
    }
}

/// Right-stick scrolling: `delta * abs(delta) * 1600 * elapsed`, deadzone 0.2.
public enum GamepadScroll {
    public static let deadzone = 0.2
    public static let speed = 1600.0

    public static func filteredAxis(_ value: Double) -> Double {
        abs(value) > deadzone ? value : 0
    }

    public static func delta(axis: Double, elapsed: TimeInterval) -> Double {
        let filtered = filteredAxis(axis)
        guard filtered != 0 else { return 0 }
        return filtered * abs(filtered) * speed * elapsed
    }
}

/// Next selected index in the library for a D-pad / stick direction.
public enum GamepadLibraryNavigation {
    public static func nextIndex(
        current: Int, count: Int, direction: GamepadDirection, columns: Int, wraps: Bool = false
    ) -> Int? {
        guard count > 0, current >= 0, current < count else { return nil }
        let columnCount = max(1, columns)
        switch direction {
        case .upward:
            let next = current - columnCount
            return next >= 0 ? next : (wraps ? current - columnCount + count : nil)
        case .downward:
            let next = current + columnCount
            return next < count ? next : (wraps ? next - count : nil)
        case .left:
            if current > 0 {
                return current - 1
            }
            return wraps ? count - 1 : nil
        case .right:
            if current + 1 < count {
                return current + 1
            }
            return wraps ? 0 : nil
        }
    }
}
