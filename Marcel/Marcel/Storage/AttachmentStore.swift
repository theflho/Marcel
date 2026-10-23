import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Keeps attachment bytes on the device so messages stay viewable offline.
nonisolated enum AttachmentStore {
    /// Photos are resized to this many pixels on the long side before upload.
    static let maxImageDimension = 2048
    /// Same limit as the backend.
    static let maxBytes = 20 * 1024 * 1024

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appending(path: "Attachments", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func url(for attachment: Attachment) -> URL {
        directory.appending(path: attachment.storageName)
    }

    static func data(for attachment: Attachment) throws -> Data {
        try Data(contentsOf: url(for: attachment))
    }

    /// Re-encodes a photo (HEIC, PNG, huge JPEG…) as a reasonably sized JPEG and stores it.
    @concurrent
    static func storeImage(_ data: Data) async throws -> Attachment {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxImageDimension,
              ] as CFDictionary)
        else { throw AttachmentError.unreadableImage }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw AttachmentError.unreadableImage }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw AttachmentError.unreadableImage }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let id = UUID()
        let suffix = id.uuidString.prefix(4).lowercased()
        let attachment = Attachment(id: id, kind: .image, filename: "Photo-\(formatter.string(from: .now))-\(suffix).jpg",
                                    mimeType: "image/jpeg", byteCount: output.length)
        try (output as Data).write(to: url(for: attachment), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return attachment
    }

    /// Copies a file picked in Files. `url` must already be security-scope accessible.
    @concurrent
    static func storeFile(at source: URL) async throws -> Attachment {
        let values = try source.resourceValues(forKeys: [.fileSizeKey])
        let size = values.fileSize ?? 0
        guard size <= maxBytes else { throw AttachmentError.tooLarge }
        let filename = source.lastPathComponent
        let mime = Attachment.mimeType(forFilename: filename)
        let isImage = UTType(mimeType: mime)?.conforms(to: .image) ?? false
        if isImage {
            return try await storeImage(Data(contentsOf: source))
        }
        let attachment = Attachment(kind: .file, filename: filename, mimeType: mime, byteCount: size)
        let destination = url(for: attachment)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
        return attachment
    }

    static func delete(_ attachments: [Attachment]) {
        for attachment in attachments {
            try? FileManager.default.removeItem(at: url(for: attachment))
        }
    }
}

nonisolated enum AttachmentError: LocalizedError {
    case unreadableImage, tooLarge

    var errorDescription: String? {
        switch self {
        case .unreadableImage: "Impossible de lire cette image."
        case .tooLarge: "Fichier trop volumineux (20 Mo maximum)."
        }
    }
}
