import AppKit
import Foundation

// Build the release test bundle first, then pass its .xctest directory to this host.
// This process briefly opens synthetic fixture windows; it never launches Gleanary.app.
// GLEANARY_INPUT_PROBE_CLASS selects another fixture; graph input is the default.
guard CommandLine.arguments.count == 2,
      let bundle = Bundle(path: CommandLine.arguments[1])
else {
    fputs("usage: swift scripts/graph-input-probe.swift /path/to/GleanaryTests.xctest\n", stderr)
    exit(2)
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
application.finishLaunching()
do { try bundle.loadAndReturnError() }
catch {
    print("Cannot load input fixture: \(error)")
    exit(2)
}

let probeName = ProcessInfo.processInfo.environment["GLEANARY_INPUT_PROBE_CLASS"] ?? "GleanaryGraphInputProbe"
guard let probe = NSClassFromString(probeName) as? NSObject.Type else {
    print("The test bundle does not contain \(probeName)")
    exit(2)
}

DispatchQueue.main.asyncAfter(deadline: .now() + 45) {
    print("INPUT PROBE TIMEOUT")
    exit(2)
}

probe.perform(NSSelectorFromString("start"))
application.run()
