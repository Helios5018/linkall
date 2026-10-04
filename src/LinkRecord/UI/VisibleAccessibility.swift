import AppKit
import ApplicationServices
import Carbon
import LinkRecordCore

enum VisibleAccessibility {
    struct Result: Sendable {
        var blocks: [ScreenTextBlock] = []
        var status = "unavailable"
        var windowTextBounds: ScreenRect? = nil
    }
    /// Bounded, read-only AX traversal. A screenshot grant is checked by the caller as well.
    static func read(pid: pid_t, windowID: CGWindowID, windowFrame: CGRect, displayFrame: CGRect) -> Result {
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled() else { return .init() }
        guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]],
              let targetIndex = windows.firstIndex(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID }) else { return .init() }
        let above = windows.prefix(targetIndex).compactMap { window -> (CGRect, Int)? in
            guard (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary else { return nil }
            guard let rect = CGRect(dictionaryRepresentation: bounds) else { return nil }
            return (rect, window[kCGWindowLayer as String] as? Int ?? 0)
        }
        let occluders = above.filter { $0.1 == 0 }.map { $0.0 }
        let overlays = above.filter { $0.1 != 0 }.map { $0.0 }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.02)
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.02)
        let started = ProcessInfo.processInfo.systemUptime
        let deadline = started + 0.25
        func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            AXUIElementSetMessagingTimeout(element, 0.02)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
            return value
        }
        func frame(_ element: AXUIElement) -> CGRect? {
            guard let position = attribute(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
                  let size = attribute(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
            var p = CGPoint.zero, s = CGSize.zero
            guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &p), AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &s) else { return nil }
            return CGRect(origin: p, size: s)
        }
        guard let focused = attribute(app, kAXFocusedWindowAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() else { return .init() }
        let window = unsafeBitCast(focused, to: AXUIElement.self)
        guard let bounds = frame(window), abs(bounds.minX - windowFrame.minX) < 2, abs(bounds.minY - windowFrame.minY) < 2,
              abs(bounds.width - windowFrame.width) < 2, abs(bounds.height - windowFrame.height) < 2 else { return .init() }
        func permitted(_ rect: CGRect, viewport: CGRect) -> Bool {
            guard ScreenVisibility.permits(rect, inside: viewport, occluders: occluders) else { return false }
            guard overlays.contains(where: { $0.intersects(rect) }) else { return true }
            // Non-interactive overlays (e.g. desktop watermarks) can have opaque window bounds.
            // Require system AX hit tests to resolve to this exact window at all five points.
            let inset = rect.insetBy(dx: min(1, rect.width / 4), dy: min(1, rect.height / 4))
            for point in [CGPoint(x: inset.minX, y: inset.minY), CGPoint(x: inset.maxX, y: inset.minY), CGPoint(x: inset.minX, y: inset.maxY), CGPoint(x: inset.maxX, y: inset.maxY), CGPoint(x: rect.midX, y: rect.midY)] {
                guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
                var hit: AXUIElement?
                guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success, let hit else { return false }
                var owner: pid_t = 0
                guard AXUIElementGetPid(hit, &owner) == .success, owner == pid else { return false }
                if !CFEqual(hit, window) {
                    guard let hitWindow = attribute(hit, kAXWindowAttribute), CFEqual(hitWindow, window) else { return false }
                }
            }
            return true
        }
        func parameter(_ element: AXUIElement, _ key: String, _ value: CFTypeRef) -> CFTypeRef? {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            var result: CFTypeRef?
            return AXUIElementCopyParameterizedAttributeValue(element, key as CFString, value, &result) == .success ? result : nil
        }
        var result = Result(status: "available"), nodes = 0, characters = 0
        let visibleWindow = bounds.intersection(displayFrame)
        if permitted(visibleWindow, viewport: displayFrame) {
            result.windowTextBounds = .init(x: (visibleWindow.minX - displayFrame.minX) / displayFrame.width,
                y: (visibleWindow.minY - displayFrame.minY) / displayFrame.height,
                width: visibleWindow.width / displayFrame.width, height: visibleWindow.height / displayFrame.height)
        }
        func append(_ text: String, rect: CGRect, role: String, path: String) {
            guard !text.isEmpty, text.count <= min(2400, 12000 - characters) else { return }
            result.blocks.append(.init(text: text, bounds: .init(x: (rect.minX - displayFrame.minX) / displayFrame.width, y: (rect.minY - displayFrame.minY) / displayFrame.height, width: rect.width / displayFrame.width, height: rect.height / displayFrame.height), source: .accessibility, role: role, path: path))
            characters += text.count
        }
        var visited = Set<CFHashCode>()
        func walk(_ element: AXUIElement, viewport: CGRect, path: String, depth: Int) {
            guard depth <= 18, nodes < 300, characters < 12000, ProcessInfo.processInfo.systemUptime < deadline else { result.status = "limited"; return }
            guard visited.insert(CFHash(element)).inserted else { return }
            nodes += 1
            guard attribute(element, "AXHidden") as? Bool != true, attribute(element, "AXProtectedContent") as? Bool != true else { return }
            let role = attribute(element, kAXRoleAttribute) as? String ?? ""
            let subrole = attribute(element, kAXSubroleAttribute) as? String ?? ""
            guard subrole != kAXSecureTextFieldSubrole else { return }
            let elementFrame = frame(element)
            var clipped = viewport
            if let elementFrame {
                clipped = viewport.intersection(elementFrame)
                guard !clipped.isNull, !clipped.isEmpty else { return }
            }
            if role == kAXTextAreaRole || role == kAXTextFieldRole {
                // Never fetch AXValue: request only visible line ranges, after checking their bounds.
                if let visible = attribute(element, kAXVisibleCharacterRangeAttribute), CFGetTypeID(visible) == AXValueGetTypeID() {
                    var range = CFRange()
                    if AXValueGetValue(unsafeBitCast(visible, to: AXValue.self), .cfRange, &range), range.location >= 0, range.length > 0, range.location <= Int.max - range.length {
                        let end = range.location + min(range.length, min(2400, 12000 - characters))
                        var index = range.location, lines = 0
                        while index < end, lines < 80, ProcessInfo.processInfo.systemUptime < deadline {
                            var lineRange = CFRange(location: index, length: end - index)
                            if let line = parameter(element, kAXLineForIndexParameterizedAttribute, NSNumber(value: index)),
                               let lineValue = parameter(element, kAXRangeForLineParameterizedAttribute, line), CFGetTypeID(lineValue) == AXValueGetTypeID() {
                                var candidate = CFRange()
                                if AXValueGetValue(unsafeBitCast(lineValue, to: AXValue.self), .cfRange, &candidate), candidate.location >= 0, candidate.length > 0, candidate.location <= Int.max - candidate.length {
                                    let lower = max(index, candidate.location), upper = min(end, candidate.location + candidate.length)
                                    if upper > lower { lineRange = CFRange(location: lower, length: upper - lower) }
                                }
                            }
                            guard let value = AXValueCreate(.cfRange, &lineRange) else { break }
                            if let boxValue = parameter(element, kAXBoundsForRangeParameterizedAttribute, value), CFGetTypeID(boxValue) == AXValueGetTypeID() {
                                var box = CGRect.zero
                                if AXValueGetValue(unsafeBitCast(boxValue, to: AXValue.self), .cgRect, &box), permitted(box, viewport: clipped),
                                   let text = parameter(element, kAXStringForRangeParameterizedAttribute, value) as? String {
                                    append(text.trimmingCharacters(in: .newlines), rect: box, role: role, path: path + "/range/" + String(lineRange.location))
                                }
                            }
                            index = lineRange.location + lineRange.length; lines += 1
                        }
                        if index < range.location + range.length { result.status = "limited" }
                    }
                }
                return
            } else if [kAXStaticTextRole, kAXButtonRole, "AXLink", kAXCheckBoxRole, kAXRadioButtonRole].contains(role),
                      let elementFrame, permitted(elementFrame, viewport: viewport),
                      let text = attribute(element, role == kAXStaticTextRole ? kAXValueAttribute : kAXTitleAttribute) as? String {
                append(text, rect: elementFrame, role: role, path: path)
                return
            }
            // Copy bounded child slices, never request a whole document's accessibility tree.
            var children: CFArray?
            guard ProcessInfo.processInfo.systemUptime < deadline else { result.status = "limited"; return }
            var error = AXUIElementCopyAttributeValues(element, kAXVisibleChildrenAttribute as CFString, 0, min(80, 300 - nodes), &children)
            if error == .attributeUnsupported || error == .noValue {
                guard ProcessInfo.processInfo.systemUptime < deadline else { result.status = "limited"; return }
                error = AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, min(80, 300 - nodes), &children)
            }
            if error == .success, let items = children as? [AXUIElement] {
                for (index, child) in items.enumerated() {
                    guard ProcessInfo.processInfo.systemUptime < deadline else { result.status = "limited"; break }
                    walk(child, viewport: clipped, path: path + "/" + String(index), depth: depth + 1)
                }
            }
        }
        walk(window, viewport: windowFrame.intersection(displayFrame), path: "window", depth: 0)
        if IsSecureEventInputEnabled() { return .init() }
        // Do not attribute text to a different window after a same-application focus change.
        var finalWindow: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &finalWindow) == .success,
              let finalWindow, CFEqual(finalWindow, window) else { return .init() }
        return result
    }
}
