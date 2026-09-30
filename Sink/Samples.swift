import Foundation

extension MarkdownDocument {
    /// Hashes of the three fictional notes shipped before empty-library onboarding.
    /// Keep only their signatures so existing untouched copies can be retired safely.
    static let retiredSampleSignatures: Set<String> = [
        "01fe06465c9c9e0d4143751faa0efc90672edae8b6a1bbac1248e555fcd4d7e2",
        "73c084dfbbca6fe1ab20ee7381b52964a0310a2228306d3fd887aba2da5cd4a4",
        "e4bb953dd9c122fd412733b45d7ef0a04e33bb1266b03f30056eb8a674ebc2a2",
    ]

    var retiredSampleSignature: String {
        ContentHash.of(name + "\u{0}" + markdown)
    }
}
