import AppKit

// Regular app (Dock + hub window); AppDelegate also adds a menu-bar item.
MainActor.assumeIsolated {
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
        _ = NSApplication.shared
        Snapshot.run(to: URL(fileURLWithPath: args[i + 1]))
        exit(0)
    }
    if let i = args.firstIndex(of: "--icon"), i + 1 < args.count {
        _ = NSApplication.shared
        AppIconView.writeIconset(to: URL(fileURLWithPath: args[i + 1]))
        exit(0)
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
