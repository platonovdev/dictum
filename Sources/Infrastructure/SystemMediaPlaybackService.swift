import AppKit
import Application
import CoreAudio
import Foundation
import OSLog

/// Pauses the system's current media session only when Core Audio reports that
/// a known media application is actively producing output. This guard matters:
/// sending Play/Pause with no active media would start an already-paused track.
@MainActor
public final class SystemMediaPlaybackService: BackgroundMediaPlaybackService {
    typealias ActiveOutputProvider = () -> Set<String>
    typealias MediaKeySender = () -> Bool

    private let activeOutputProvider: ActiveOutputProvider
    private let mediaKeySender: MediaKeySender
    private let logger = Logger(subsystem: "com.dictator.app", category: "media-playback")
    private var pausedBundleIdentifiers: Set<String> = []

    public convenience init() {
        self.init(
            activeOutputProvider: Self.activeOutputBundleIdentifiers,
            mediaKeySender: Self.sendPlayPauseKey
        )
    }

    init(
        activeOutputProvider: @escaping ActiveOutputProvider,
        mediaKeySender: @escaping MediaKeySender
    ) {
        self.activeOutputProvider = activeOutputProvider
        self.mediaKeySender = mediaKeySender
    }

    @discardableResult
    public func pauseActivePlayback() -> Bool {
        guard pausedBundleIdentifiers.isEmpty else {
            return true
        }

        let activeMedia = activeOutputProvider().filter(Self.isMediaApplication)
        guard !activeMedia.isEmpty else {
            return false
        }
        guard mediaKeySender() else {
            logger.error("Could not post the system Play/Pause command")
            return false
        }

        pausedBundleIdentifiers = Set(activeMedia)
        logger.info(
            "Paused active media for \(activeMedia.sorted().joined(separator: ","), privacy: .public)"
        )
        return true
    }

    public func resumePausedPlayback() {
        guard !pausedBundleIdentifiers.isEmpty else {
            return
        }

        let pausedMedia = pausedBundleIdentifiers
        // Clear first so repeated teardown paths and app termination remain
        // idempotent even if event delivery fails.
        pausedBundleIdentifiers.removeAll()
        guard mediaKeySender() else {
            logger.error("Could not post the system Play/Pause resume command")
            return
        }
        logger.info(
            "Resumed media for \(pausedMedia.sorted().joined(separator: ","), privacy: .public)"
        )
    }

    static func isMediaApplication(_ bundleIdentifier: String) -> Bool {
        let identifier = bundleIdentifier.lowercased()
        return mediaBundlePrefixes.contains { identifier.hasPrefix($0) }
    }

    private static let mediaBundlePrefixes = [
        "com.apple.music",
        "com.apple.podcasts",
        "com.apple.tv",
        "com.apple.quicktimeplayerx",
        "com.apple.safari",
        "com.apple.webkit",
        "com.spotify",
        "com.google.chrome",
        "com.brave.browser",
        "com.microsoft.edgemac",
        "com.operasoftware.opera",
        "company.thebrowser.browser",
        "org.mozilla.firefox",
        "org.videolan.vlc",
        "com.colliderli.iina",
        "ru.yandex.desktop.yandex-browser"
    ]

    private static func activeOutputBundleIdentifiers() -> Set<String> {
        Set(processObjectIDs().compactMap { processObjectID in
            guard propertyUInt32(
                objectID: processObjectID,
                selector: kAudioProcessPropertyIsRunningOutput
            ) != 0 else {
                return nil
            }

            let pid = pid_t(bitPattern: propertyUInt32(
                objectID: processObjectID,
                selector: kAudioProcessPropertyPID
            ))
            guard pid != ProcessInfo.processInfo.processIdentifier else {
                return nil
            }
            return propertyString(
                objectID: processObjectID,
                selector: kAudioProcessPropertyBundleID
            ) ?? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        })
    }

    private static func processObjectIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let systemObject = AudioObjectID(bitPattern: kAudioObjectSystemObject)
        var byteCount: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            systemObject,
            &address,
            0,
            nil,
            &byteCount
        ) == noErr, byteCount > 0 else {
            return []
        }

        var values = [AudioObjectID](
            repeating: kAudioObjectUnknown,
            count: Int(byteCount) / MemoryLayout<AudioObjectID>.size
        )
        guard AudioObjectGetPropertyData(
            systemObject,
            &address,
            0,
            nil,
            &byteCount,
            &values
        ) == noErr else {
            return []
        }
        return values
    }

    private static func propertyUInt32(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var byteCount = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &byteCount,
            &value
        ) == noErr else {
            return 0
        }
        return value
    }

    private static func propertyString(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString?
        var byteCount = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(
                objectID,
                &address,
                0,
                nil,
                &byteCount,
                pointer
            )
        }
        guard status == noErr else {
            return nil
        }
        return value as String?
    }

    private static func sendPlayPauseKey() -> Bool {
        // NX_KEYTYPE_PLAY from Apple's IOKit ev_keymap.h.
        let playPauseKey = 16
        let keyDownState = 0xA
        let keyUpState = 0xB

        guard
            let keyDown = mediaEvent(key: playPauseKey, state: keyDownState),
            let keyUp = mediaEvent(key: playPauseKey, state: keyUpState),
            let keyDownEvent = keyDown.cgEvent,
            let keyUpEvent = keyUp.cgEvent
        else {
            return false
        }
        keyDownEvent.post(tap: .cghidEventTap)
        keyUpEvent.post(tap: .cghidEventTap)
        return true
    }

    private static func mediaEvent(key: Int, state: Int) -> NSEvent? {
        NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: (key << 16) | (state << 8),
            data2: -1
        )
    }
}
