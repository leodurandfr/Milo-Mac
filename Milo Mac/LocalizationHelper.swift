import Foundation

/// Helper function for localized strings
/// Usage: L("key") instead of NSLocalizedString("key", comment: "")
func L(_ key: String, comment: String = "") -> String {
    return NSLocalizedString(key, comment: comment)
}

/// Helper function for localized strings with format arguments
/// Usage: L("key.with.param", 42, "text") for strings like "Value: %d, Name: %@"
///
/// The format is resolved with `Locale.current`: that is what expands the `%#@…@`
/// variables `Localizable.stringsdict` returns for pluralized keys
/// (`musicLibrary.search.albumsCount`). Without a locale, `String(format:)` would copy
/// `%#@albums@` through verbatim.
func L(_ key: String, _ args: CVarArg..., comment: String = "") -> String {
    let format = NSLocalizedString(key, comment: comment)
    return String(format: format, locale: .current, arguments: args)
}
