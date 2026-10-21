import AppKit
import Foundation

// Build the release test bundle first, then pass its .xctest directory to this host.
// This process briefly opens synthetic graph windows; it never launches Gleanary.app.
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
    print("Cannot load graph input fixture: \(error)")
    exit(2)
}

guard let probe = NSClassFromString("GleanaryGraphInputProbe") as? NSObject.Type else {
    print("The release test bundle does not contain GleanaryGraphInputProbe")
    exit(2)
}

DispatchQueue.main.asyncAfter(deadline: .now() + 45) {
    print("GRAPH INPUT PROBE TIMEOUT")
    exit(2)
}

probe.perform(NSSelectorFromString("start"))
application.run()
