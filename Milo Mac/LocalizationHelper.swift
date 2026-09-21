import Foundation

/// Helper function for localized strings
/// Usage: L("key") instead of NSLocalizedString("key", comment: "")
func L(_ key: String, comment: String = "") -> String {
    return NSLocalizedString(key, comment: comment)
}

/// Helper function for localized strings with format arguments
/// Usage: L("key.with.param", 42, "text") for strings like "Value: %d, Name: %@"
///
/// Le format est résolu avec `Locale.current` : c'est ce qui développe les variables
/// `%#@…@` que `Localizable.stringsdict` renvoie pour les clés à pluriel
/// (`musicLibrary.search.albumsCount`). Sans locale, `String(format:)` recopierait
/// `%#@albums@` tel quel.
func L(_ key: String, _ args: CVarArg..., comment: String = "") -> String {
    let format = NSLocalizedString(key, comment: comment)
    return String(format: format, locale: .current, arguments: args)
}
