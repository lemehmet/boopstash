import Foundation

/// Facts about the product that both apps and the tests share.
///
/// A placeholder until the note model lands in milestone 2; it exists so the
/// framework, its tests and the app's link against it are wired from day one.
/// Not named `Boopstash`: that is the app's module name, and a type of the same
/// name would shadow module-qualified lookups inside the app.
public enum ProductInfo {
    public static let name = "Boopstash"
}
