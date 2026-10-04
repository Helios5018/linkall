/// Lock and sleep are independent: waking the display must not authorize capture before unlock.
public struct CaptureLifecycle: Sendable {
    public private(set) var isLocked = false
    public private(set) var isSleeping = false
    public private(set) var revision = 0
    public var isActive: Bool { !isLocked && !isSleeping }
    public init() {}
    public mutating func setLocked(_ value: Bool) { isLocked = value; invalidate() }
    public mutating func setSleeping(_ value: Bool) { isSleeping = value; invalidate() }
    public mutating func invalidate() { revision &+= 1 }
    public func accepts(_ ticket: Int) -> Bool { isActive && revision == ticket }
}
