import Foundation
import Carbon
let args = CommandLine.arguments
let action = args.count > 1 ? args[1] : "list"
if action == "current" {
    let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
    if let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) {
        print(Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue())
    }
    exit(0)
}
if action == "register", args.count > 2 {
    print("register:", TISRegisterInputSource(URL(fileURLWithPath: args[2], isDirectory: true) as CFURL))
    RunLoop.current.run(until: Date().addingTimeInterval(1)); exit(0)
}
let sources = TISCreateInputSourceList(nil, true).takeRetainedValue() as! [TISInputSource]
var matched = false
func prop(_ s: TISInputSource, _ key: CFString) -> String {
    guard let raw = TISGetInputSourceProperty(s, key) else { return "" }
    return String(describing: Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue())
}
for source in sources {
    let id = prop(source, kTISPropertyInputSourceID)
    if action == "list" { print(id, prop(source, kTISPropertyLocalizedName), "enabled=" + prop(source, kTISPropertyInputSourceIsEnabled), "selected=" + prop(source, kTISPropertyInputSourceIsSelected)) }
    else if args.count > 2 && id == args[2] {
        matched = true
        switch action {
        case "enable":
            if prop(source, kTISPropertyInputSourceIsEnabled) != "1" { print(TISEnableInputSource(source)) }
            else { print("already enabled") }
        case "select":
            guard prop(source, kTISPropertyInputSourceIsEnabled) == "1" else { fputs("Input source is not enabled; enable it once in System Settings.\n", stderr); exit(2) }
            print(TISSelectInputSource(source))
        case "disable": print(TISDisableInputSource(source))
        default: break
        }
    }
}
if action != "list", !matched { fputs("Input source not found. Register the installed bundle first.\n", stderr); exit(3) }
CFPreferencesAppSynchronize("com.apple.HIToolbox" as CFString)
RunLoop.current.run(until: Date().addingTimeInterval(1))
