import SwiftUI

struct LibraryGraphContext {
    let store: DocumentStore
    let refreshToken: Int
    let explore: (UUID) -> Void
}

extension EnvironmentValues {
    @Entry var libraryGraphContext: LibraryGraphContext?
}
