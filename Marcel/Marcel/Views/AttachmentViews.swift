import SwiftUI
import QuickLook

/// Attachments inside a message bubble: photos as thumbnails, files as cards.
/// Tapping either opens the system Quick Look preview.
struct MessageAttachmentsView: View {
    let attachments: [Attachment]
    @State private var previewURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let images = attachments.filter { $0.kind == .image }
            if !images.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 6)], spacing: 6) {
                    ForEach(images) { attachment in
                        Button { previewURL = AttachmentStore.url(for: attachment) } label: {
                            AttachmentImage(attachment: attachment)
                                .frame(minWidth: 110, maxWidth: .infinity)
                                .frame(height: images.count == 1 ? 200 : 110)
                                .clipShape(.rect(cornerRadius: 14))
                        }
                        .accessibilityLabel("Photo \(attachment.filename)")
                    }
                }
            }
            ForEach(attachments.filter { $0.kind == .file }) { attachment in
                Button { previewURL = AttachmentStore.url(for: attachment) } label: {
                    FileCard(attachment: attachment)
                }
                .buttonStyle(.plain)
            }
        }
        .quickLookPreview($previewURL)
    }
}

/// Card for a document, in the spirit of the PDF card in Mail or Messages.
struct FileCard: View {
    let attachment: Attachment
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(attachment.isPDF ? Color.red : Color.accentColor)
                    .frame(width: 34, height: 42)
                Text(fileBadge)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.filename)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(attachment.formattedSize)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let onRemove {
                Button("Retirer", systemImage: "xmark.circle.fill", action: onRemove)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Theme.surface, in: .rect(cornerRadius: 14))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Fichier \(attachment.filename), \(attachment.formattedSize)")
    }

    private var fileBadge: String {
        let ext = (attachment.filename as NSString).pathExtension.uppercased()
        return ext.isEmpty ? "FICH" : String(ext.prefix(4))
    }
}

/// Loads a local photo off the main thread.
struct AttachmentImage: View {
    let attachment: Attachment
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(.secondary.opacity(0.15))
                    .overlay { Image(systemName: "photo").foregroundStyle(.secondary) }
            }
        }
        .task(id: attachment.id) {
            let url = AttachmentStore.url(for: attachment)
            image = await Task.detached(priority: .userInitiated) {
                UIImage(contentsOfFile: url.path)?.preparingThumbnail(of: CGSize(width: 600, height: 600))
            }.value
        }
    }
}

/// Strip above the text field listing what will be sent with the next message.
struct PendingAttachmentsStrip: View {
    @Environment(ChatStore.self) private var store

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(store.pendingAttachments) { attachment in
                    if attachment.kind == .image {
                        AttachmentImage(attachment: attachment)
                            .frame(width: 64, height: 64)
                            .clipShape(.rect(cornerRadius: 12))
                            .overlay(alignment: .topTrailing) {
                                Button("Retirer", systemImage: "xmark.circle.fill") { store.removePending(attachment) }
                                    .labelStyle(.iconOnly)
                                    .font(.system(size: 18))
                                    .foregroundStyle(.white, .black.opacity(0.55))
                                    .padding(3)
                            }
                    } else {
                        FileCard(attachment: attachment) { store.removePending(attachment) }
                            .frame(width: 220)
                    }
                }
                if store.isPreparingAttachment {
                    ProgressView()
                        .frame(width: 64, height: 64)
                        .background(Theme.assistantBubble, in: .rect(cornerRadius: 12))
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
        }
    }
}
