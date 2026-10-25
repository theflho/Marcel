import SwiftUI
import UIKit

/// A message opened to select any part of it (long press › Sélectionner le texte). In the bubble,
/// selection would swallow the long press that opens the menu; here iOS offers its own menu on
/// the selection: Copier, Traduire, Rechercher, Partager…
struct SelectableTextSheet: View {
    @Environment(\.dismiss) private var dismiss
    let text: String

    var body: some View {
        NavigationStack {
            SelectableText(text: Self.plain(text))
                .padding(.horizontal, 12)
                .navigationTitle("Sélectionner le texte")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Tout copier", systemImage: "doc.on.doc") { UIPasteboard.general.string = Self.plain(text) }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("OK") { dismiss() }
                    }
                }
        }
    }

    /// The reply as it reads: Markdown marks (**, `, #, links) taken out, blocks Marcel carries out removed.
    static func plain(_ markdown: String) -> String {
        let shown = AssistantDraft.split(AssistantProposal.split(AutoBlocks.strip(markdown)).text).text
        let lines = shown.components(separatedBy: "\n").map { line -> String in
            let unheaded = line.replacingOccurrences(of: "^#{1,6}\\s+", with: "", options: .regularExpression)
            let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            guard let parsed = try? AttributedString(markdown: unheaded, options: options) else { return unheaded }
            return String(parsed.characters)
        }
        return lines.joined(separator: "\n")
    }
}

/// Read-only text where any range can be selected (SwiftUI's Text only copies the whole thing).
private struct SelectableText: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .clear
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textColor = .label
        view.dataDetectorTypes = [.link, .phoneNumber, .address]
        view.textContainerInset = UIEdgeInsets(top: 12, left: 0, bottom: 24, right: 0)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
    }
}
