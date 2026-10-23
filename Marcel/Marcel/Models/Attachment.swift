import Foundation
import UniformTypeIdentifiers

/// A photo or file attached to a message. The bytes live in `AttachmentStore`;
/// `remoteID` is set once the backend has received them.
nonisolated struct Attachment: Identifiable, Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case image, file
    }

    let id: UUID
    let kind: Kind
    let filename: String
    let mimeType: String
    let byteCount: Int
    var remoteID: String?

    init(id: UUID = UUID(), kind: Kind, filename: String, mimeType: String, byteCount: Int, remoteID: String? = nil) {
        self.id = id
        self.kind = kind
        self.filename = filename
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.remoteID = remoteID
    }

    /// Name of the local file inside the attachments directory.
    var storageName: String {
        let ext = (filename as NSString).pathExtension
        return ext.isEmpty ? id.uuidString : "\(id.uuidString).\(ext)"
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }

    var isPDF: Bool { mimeType == "application/pdf" }

    static func mimeType(forFilename filename: String) -> String {
        let ext = (filename as NSString).pathExtension
        return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
    }
}
