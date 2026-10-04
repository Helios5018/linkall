import AppKit
import ApplicationServices
import Carbon

// Test-only HID driver: no Return, no clipboard, no network. Abort if foreground target changes.
let args = CommandLine.arguments
if args.contains("--request-permission") {
    let allowed = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    print("Accessibility:", allowed)
    exit(allowed ? 0 : 2)
}
guard args.count == 4, let targetPID = Int32(args[1]), let expectedBundle = NSRunningApplication(processIdentifier: targetPID)?.bundleIdentifier else {
    fputs("Usage: YiliuHIDDriver PID INPUT_SOURCE_ID ASCII_KEYS_WITH_<lcmd>_<esc>_<down>_<left>\n", stderr); exit(2)
}
let allowedApps = ["com.electron.lark", "com.apple.TextEdit", "com.linkall.reply-fixture", "com.openai.codex", "com.google.Chrome", "com.cmuxterm.app", "com.cmuxterm.app.staging.macos.local"]
guard allowedApps.contains(expectedBundle), AXIsProcessTrusted(), !IsSecureEventInputEnabled() else { fputs("Unsupported target or missing Accessibility permission\n", stderr); exit(3) }
let keyMap: [Character: CGKeyCode] = ["a":0,"s":1,"d":2,"f":3,"h":4,"g":5,"z":6,"x":7,"c":8,"v":9,"b":11,"q":12,"w":13,"e":14,"r":15,"y":16,"t":17,"1":18,"2":19,"3":20,"4":21,"6":22,"5":23,"=":24,"9":25,"7":26,"-":27,"8":28,"0":29,"]":30,"o":31,"u":32,"[":33,"i":34,"p":35,"l":37,"j":38,"'":39,"k":40,";":41,"\\":42,",":43,"/":44,"n":45,"m":46,".":47," ":49]
let text = args[3]
let specials: [String: CGKeyCode] = ["<lcmd>":55, "<esc>":53, "<down>":125, "<left>":123]
var sequence: [(CGKeyCode, CGEventFlags, Bool)] = []
var remaining = text[...]
while !remaining.isEmpty {
    if let marker = specials.keys.first(where: { remaining.hasPrefix($0) }) {
        sequence.append((specials[marker]!, marker == "<lcmd>" ? .maskCommand : [], marker == "<lcmd>"))
        remaining = remaining.dropFirst(marker.count)
    } else {
        let char = remaining.removeFirst()
        guard let code = keyMap[Character(char.lowercased())] else { fputs("Unsupported test key\n", stderr); exit(4) }
        sequence.append((code, char.isUppercase ? .maskShift : [], false))
    }
}
guard !sequence.isEmpty, sequence.count <= 100 else { fputs("Only up to 100 printable test keys are allowed; no Return\n", stderr); exit(4) }
func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? { var result: CFTypeRef?; return AXUIElementCopyAttributeValue(element,name as CFString,&result) == .success ? result : nil }
func focused() -> AXUIElement? {
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID,
          let value = attribute(AXUIElementCreateApplication(targetPID), kAXFocusedUIElementAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return unsafeBitCast(value,to:AXUIElement.self)
}
guard let target = focused(), let role = attribute(target,kAXRoleAttribute) as? String,
      ["AXTextArea","AXTextField","AXComboBox"].contains(role), !(attribute(target,kAXSubroleAttribute) as? String ?? "").lowercased().contains("secure") else { fputs("Focus a non-secure test editor first\n", stderr); exit(5) }
let filter = [kTISPropertyInputSourceID as String:args[2]] as CFDictionary
let sources = TISCreateInputSourceList(filter,false).takeRetainedValue() as! [TISInputSource]
guard let source = sources.first else { fputs("Input source unavailable\n",stderr);exit(6) }
let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
let currentID = TISGetInputSourceProperty(current, kTISPropertyInputSourceID).map { String(describing: Unmanaged<AnyObject>.fromOpaque($0).takeUnretainedValue()) }
if currentID != args[2], TISSelectInputSource(source) != noErr { fputs("Input source unavailable\n",stderr);exit(6) }
Thread.sleep(forTimeInterval:0.2)
for (code, flags, modifier) in sequence {
    guard let now = focused(), CFEqual(target,now), !IsSecureEventInputEnabled() else { fputs("Target changed; stopped before next key\n",stderr);exit(7) }
    for down in [true,false] {
        guard let event = CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:down) else {exit(8)}
        event.flags = modifier && !down ? [] : flags; event.post(tap:.cghidEventTap)
        if modifier && down { Thread.sleep(forTimeInterval: 0.08) }
    }
    Thread.sleep(forTimeInterval:0.12)
}
print("Dispatched \(sequence.count) test keys to \(expectedBundle); verify the host text separately.")
