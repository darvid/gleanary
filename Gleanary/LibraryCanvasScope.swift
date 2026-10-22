import Foundation

/// Canvas memories belong to a collection, not a search string or database revision.
struct LibraryCanvasScope: Hashable {
    let scope: LibraryScope
    let kind: LibraryKindFilter
}
