import SwiftUI

enum JournalPalette {
    static let purple = Color(red: 0.48, green: 0.30, blue: 0.80)
    static let blue = Color(red: 0.20, green: 0.46, blue: 0.91)
    static let orange = Color(red: 0.91, green: 0.45, blue: 0.13)
    static let green = Color(red: 0.12, green: 0.56, blue: 0.41)
    static func source(_ provider: JournalProvider) -> Color { provider == .codex ? blue : orange }
}
