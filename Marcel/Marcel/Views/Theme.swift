import SwiftUI

/// Soft, light palette inspired by messaging apps; every colour adapts to dark mode.
enum Theme {
    static let background = Color(light: Color(red: 0.97, green: 0.97, blue: 0.98), dark: Color(red: 0.07, green: 0.07, blue: 0.08))
    static let surface = Color(light: .white, dark: Color(red: 0.16, green: 0.16, blue: 0.18))
    static let assistantBubble = Color(light: Color(red: 0.91, green: 0.91, blue: 0.93), dark: Color(red: 0.19, green: 0.19, blue: 0.21))
    static let userBubble = Color(light: Color(red: 0.82, green: 0.91, blue: 1.0), dark: Color(red: 0.14, green: 0.30, blue: 0.50))
}

extension Color {
    init(light: Color, dark: Color) {
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light) })
    }
}
