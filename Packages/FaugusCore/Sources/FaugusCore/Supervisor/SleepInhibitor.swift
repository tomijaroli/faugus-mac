import Foundation
import IOKit.pwr_mgt

/// "No Sleep" (`NO_SLEEP=1` upstream): keeps the Mac and display awake while a game runs.
public final class SleepInhibitor: @unchecked Sendable {
    private var systemAssertion: IOPMAssertionID = 0
    private var displayAssertion: IOPMAssertionID = 0
    private let lock = NSLock()

    public init(reason: String) {
        IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &systemAssertion
        )
        IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &displayAssertion
        )
    }

    public var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return systemAssertion != 0 || displayAssertion != 0
    }

    public func release() {
        lock.lock()
        defer { lock.unlock() }
        if systemAssertion != 0 {
            IOPMAssertionRelease(systemAssertion)
            systemAssertion = 0
        }
        if displayAssertion != 0 {
            IOPMAssertionRelease(displayAssertion)
            displayAssertion = 0
        }
    }

    deinit { release() }
}
