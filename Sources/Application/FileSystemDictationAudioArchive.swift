import AVFoundation
import Domain
import Foundation

public final class FileSystemDictationAudioArchive: DictationAudioArchive, @unchecked Sendable {
    private let fileManager: FileManager
    private let archiveDirectoryURL: URL

    public convenience init(fileManager: FileManager = .default) {
        let applicationSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        self.init(
            fileManager: fileManager,
            archiveDirectoryURL: applicationSupportURL
                .appendingPathComponent("OneBtnVoice", isDirectory: true)
                .appendingPathComponent("Dictations", isDirectory: true)
        )
    }

    public init(fileManager: FileManager, archiveDirectoryURL: URL) {
        self.fileManager = fileManager
        self.archiveDirectoryURL = archiveDirectoryURL
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

    public func recoverArchivedRecordings() async -> [ArchivedAudio] {
        guard let files = try? fileManager.contentsOfDirectory(
            at: archiveDirectoryURL,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return files.compactMap { url in
            // Retained M4A files are always created after a durable source WAV.
            // Only source WAVs can represent the archive/history crash window.
            guard url.pathExtension.lowercased() == "wav",
                  let values = try? url.resourceValues(
                    forKeys: [.fileSizeKey, .isRegularFileKey]
                  ),
                  values.isRegularFile == true,
                  (values.fileSize ?? 0) > 44,
                  let file = try? AVAudioFile(forReading: url),
                  file.length > 0,
                  file.processingFormat.sampleRate > 0 else {
                return nil
            }
            return ArchivedAudio(
                fileURL: url,
                duration: Double(file.length) / file.processingFormat.sampleRate
            )
        }
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
