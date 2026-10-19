import AppKit
@testable import Gleanary
import SwiftUI
import Testing

@Suite(.serialized) struct WritingSettingsTests {
    @Test(arguments: WritingStyle.presets)
    func customizingCopiesEveryRuleAndSelectsTheCopy(style: WritingStyle) {
        var choice = WritingStyleChoice(defaultID: style.id)
        choice.customizeDefaultStyle()
        var expected = style
        expected.id = WritingStyle.customID
        expected.name = "Custom"
        #expect(choice.custom == expected)
        #expect(choice.defaultStyle == expected)
        #expect(choice.style(for: "Write a note") == expected)
        #expect(WritingStyle.presets.first { $0.id == style.id } == style)
    }

    @Test func customEditsSurviveSwitchingStylesAndRelaunch() throws {
        let suite = "writing-settings-" + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        var choice = WritingStyleChoice(defaultID: WritingStyle.blog.id)
        choice.customizeDefaultStyle()
        choice.custom.name = "House style"
        choice.custom.instructions = "First paragraph.\nSecond paragraph with more detail."
        let custom = choice.custom
        choice.defaultID = WritingStyle.referenceGuide.id
        choice.save(preferences)
        choice = WritingStyleChoice.current(preferences)
        #expect(choice.defaultStyle == .referenceGuide)
        #expect(choice.custom == custom)
        choice.defaultID = WritingStyle.customID
        choice.customizeDefaultStyle()
        #expect(choice.custom == custom)
        choice.save(preferences)
        #expect(WritingStyleChoice.current(preferences).defaultStyle == custom)
    }

    @Test @MainActor func openingWritingSettingsPreservesTheSavedSelectionAndCustomRules(
    ) async throws {
        let suite = "writing-settings-native-" + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        var saved = WritingStyleChoice(defaultID: WritingStyle.blog.id)
        saved.custom.name = "House style"
        saved.custom.instructions = "Keep these saved preferences."
        saved.save(preferences)
        let host = NSHostingView(rootView: WritingSettingsView(preferences: preferences)
            .frame(width: 632, height: 480))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 632, height: 480),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        host.display()
        #expect(WritingStyleChoice.current(preferences) == saved)
        #expect(host.fittingSize == NSSize(width: 632, height: 480))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["GLEANARY_WRITING_SCREENSHOTS"] == "1"))
    @MainActor func writingLayoutsFitAndRenderInBothAppearances() async throws {
        for width in [520.0, 632.0] {
            for dark in [false, true] {
                for custom in [false, true] {
                    try await render(width: width, dark: dark, custom: custom)
                }
            }
        }
    }

    @MainActor private func render(width: Double, dark: Bool, custom: Bool) async throws {
        let suite = "writing-settings-layout-" + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        var choice = WritingStyleChoice()
        if custom {
            choice.customizeDefaultStyle()
            choice.custom.instructions = String(
                repeating: "Preserve qualifications and explain technical terms. ",
                count: 12
            )
        }
        choice.save(preferences)
        let host = NSHostingView(rootView: WritingSettingsView(
            preferences: preferences,
            initiallyShowingRules: true
        )
        .environment(\.colorScheme, dark ? .dark : .light)
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(width: width, height: 480))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(x: 0, y: 0, width: width, height: 480)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = host.appearance
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        #expect(abs(host.bounds.width - width) < 1)
        #expect(abs(host.fittingSize.width - width) < 1)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let path = "/tmp/gleanary-writing-\(Int(width))-\(dark ? "dark" : "light")-\(custom ? "custom" : "preset").png"
        try png.write(to: URL(filePath: path))
    }
}
