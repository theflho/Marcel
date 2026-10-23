import SwiftUI

/// A project in the sidebar list: its own Marcel on a coloured square, name and count.
struct ProjectRow: View {
    let project: Project
    let count: Int
    let isExpanded: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(project.displayMood.imageName)
                .resizable()
                .scaledToFill()
                .frame(width: 30, height: 30)
                .clipShape(.circle)
                .padding(4)
                .background(project.tint, in: .rect(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 1) {
                Text(project.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(count == 0 ? "Vide" : count == 1 ? "1 conversation" : "\(count) conversations")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
        }
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Projet \(project.name), \(count) conversations")
        .accessibilityValue(isExpanded ? "Ouvert" : "Fermé")
        .accessibilityAddTraits(.isButton)
    }
}

extension Project {
    private static let tints: [Color] = [
        Color(light: Color(red: 1.00, green: 0.93, blue: 0.84), dark: Color(red: 0.30, green: 0.22, blue: 0.14)),
        Color(light: Color(red: 0.88, green: 0.95, blue: 0.88), dark: Color(red: 0.15, green: 0.26, blue: 0.17)),
        Color(light: Color(red: 0.87, green: 0.92, blue: 1.00), dark: Color(red: 0.14, green: 0.20, blue: 0.32)),
        Color(light: Color(red: 0.98, green: 0.89, blue: 0.93), dark: Color(red: 0.30, green: 0.16, blue: 0.22)),
        Color(light: Color(red: 0.93, green: 0.90, blue: 1.00), dark: Color(red: 0.22, green: 0.18, blue: 0.32)),
        Color(light: Color(red: 1.00, green: 0.97, blue: 0.82), dark: Color(red: 0.30, green: 0.27, blue: 0.12)),
    ]

    /// Stable per-project number used to pick a colour and a fallback illustration.
    fileprivate var seed: Int {
        withUnsafeBytes(of: id.uuid) { $0.reduce(0) { $0 &+ Int($1) } }
    }

    var tint: Color { Self.tints[seed % Self.tints.count] }

    var displayMood: MarcelMood {
        MarcelMood.guess(from: name) ?? MarcelMood.allCases[seed % MarcelMood.allCases.count]
    }
}

#Preview {
    List {
        ProjectRow(project: Project(name: "Sortie scolaire"), count: 3, isExpanded: true)
        ProjectRow(project: Project(name: "Recettes"), count: 0, isExpanded: false)
    }
}
