import Foundation

/// One bounded control for density; zoom and graph membership remain independent.
struct GraphSpacing: Equatable, Sendable {
    static let standard = GraphSpacing(0.5)
    let value: Double

    init(_ value: Double) {
        self.value = value.isFinite ? min(1, max(0, value)) : 0.5
    }

    var linkLength: Double {
        80 + 110 * value
    }

    var repulsion: Double {
        -(80 + 200 * value)
    }

    var collisionRadius: Double {
        36 + 16 * value
    }

    var label: String {
        if value < 0.33 {
            return "Compact"
        }
        if value > 0.67 {
            return "Spacious"
        }
        return "Balanced"
    }
}
