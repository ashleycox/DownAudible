import SwiftUI

enum HelpTags {
    static let preferenceKey = "ShowsHelpTags"
}

private struct HelpTag: ViewModifier {
    @AppStorage(HelpTags.preferenceKey) private var showsHelpTags = true
    let message: String

    func body(content: Content) -> some View {
        content.help(showsHelpTags ? message : "")
    }
}

extension View {
    func appHelp(_ message: String) -> some View {
        modifier(HelpTag(message: message))
    }
}
