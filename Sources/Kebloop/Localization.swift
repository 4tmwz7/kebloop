import Foundation

/// Resolve packaged translations; persisted identifiers and user text never pass through this function.
func L(_ key: String) -> String {
    Bundle.module.localizedString(forKey: key, value: key, table: nil)
}
