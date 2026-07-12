import Domain
import Foundation

public final class FileSystemDictationAudioArchive: DictationAudioArchive, @unchecked Sendable {
    private let fileManager: FileManager
    private let archiveDirectoryURL: URL

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager

        let applicationSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        archiveDirectoryURL = applicationSupportURL
            .appendingPathComponent("OneBtnVoice", isDirectory: true)
            .appendingPathComponent("Dictations", isDirectory: true)
    }

    public func archive(_ capturedAudio: CapturedAudio, for entryID: UUID) async throws -> ArchivedAudio {
        do {
            try ensureArchiveDirectoryExists()

            let destinationURL = archiveDirectoryURL
                .appendingPathComponent(entryID.uuidString)
                .appendingPathExtension("wav")

            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }

            try fileManager.moveItem(at: capturedAudio.fileURL, to: destinationURL)

            return ArchivedAudio(fileURL: destinationURL, duration: capturedAudio.duration)
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError.audioArchiveFailed(error.localizedDescription)
        }
    }

    public func loadArchivedAudio(at path: String, duration: TimeInterval) async throws -> CapturedAudio {
        let url = URL(fileURLWithPath: path)
        guard fileManager.fileExists(atPath: url.path) else {
            throw AppError.archivedAudioUnavailable(path)
        }

        return CapturedAudio(fileURL: url, duration: duration)
    }

    public func createRetainedAudioCopy(from archivedAudio: ArchivedAudio, for entryID: UUID) async throws -> ArchivedAudio {
        do {
            try ensureArchiveDirectoryExists()

            let destinationURL = archiveDirectoryURL
                .appendingPathComponent("\(entryID.uuidString)-retained")
                .appendingPathExtension("m4a")

            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }

            try AudioCompression.compressToM4A(sourceURL: archivedAudio.fileURL, outputURL: destinationURL)

            return ArchivedAudio(fileURL: destinationURL, duration: archivedAudio.duration)
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError.audioArchiveFailed(error.localizedDescription)
        }
    }

    public func deleteArchivedAudio(at path: String) async {
        let url = URL(fileURLWithPath: path)
        try? fileManager.removeItem(at: url)
    }

    public func cleanupUnreferencedAudio(keepingPaths: Set<String>, olderThan cutoff: Date) async {
        guard let files = try? fileManager.contentsOfDirectory(
            at: archiveDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let retainedPaths = Set(keepingPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        for fileURL in files where ["wav", "m4a"].contains(fileURL.pathExtension.lowercased()) {
            let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true,
                  let modifiedAt = values?.contentModificationDate,
                  modifiedAt < cutoff,
                  !retainedPaths.contains(fileURL.standardizedFileURL.path) else {
                continue
            }
            try? fileManager.removeItem(at: fileURL)
        }
    }

    private func ensureArchiveDirectoryExists() throws {
        if fileManager.fileExists(atPath: archiveDirectoryURL.path) {
            return
        }

        try fileManager.createDirectory(
            at: archiveDirectoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }
}
