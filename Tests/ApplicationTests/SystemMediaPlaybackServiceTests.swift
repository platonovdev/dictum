#if canImport(Testing)
@testable import Infrastructure
import Testing

@Test
@MainActor
func mediaPlaybackServiceDoesNothingWhenNoMediaIsPlaying() {
    var commandCount = 0
    let service = SystemMediaPlaybackService(
        activeOutputProvider: { [] },
        mediaKeySender: {
            commandCount += 1
            return true
        }
    )

    #expect(!service.pauseActivePlayback())
    service.resumePausedPlayback()

    #expect(commandCount == 0)
}

@Test
@MainActor
func mediaPlaybackServicePausesAndResumesSupportedPlayersExactlyOnce() {
    var commandCount = 0
    let service = SystemMediaPlaybackService(
        activeOutputProvider: { ["com.spotify.client"] },
        mediaKeySender: {
            commandCount += 1
            return true
        }
    )

    #expect(service.pauseActivePlayback())
    #expect(service.pauseActivePlayback())
    #expect(commandCount == 1)

    service.resumePausedPlayback()
    service.resumePausedPlayback()
    #expect(commandCount == 2)
}

@Test
@MainActor
func mediaPlaybackServiceDoesNotToggleCallOrSystemAudio() {
    var commandCount = 0
    let service = SystemMediaPlaybackService(
        activeOutputProvider: {
            ["com.microsoft.teams2", "com.apple.audio.coreaudiod"]
        },
        mediaKeySender: {
            commandCount += 1
            return true
        }
    )

    #expect(!service.pauseActivePlayback())
    service.resumePausedPlayback()

    #expect(commandCount == 0)
}

@Test
@MainActor
func supportedMediaApplicationsCoverPlayersAndBrowsers() {
    #expect(SystemMediaPlaybackService.isMediaApplication("com.apple.Music"))
    #expect(SystemMediaPlaybackService.isMediaApplication("com.spotify.client"))
    #expect(SystemMediaPlaybackService.isMediaApplication("com.google.Chrome.helper"))
    #expect(SystemMediaPlaybackService.isMediaApplication("org.videolan.vlc"))
    #expect(!SystemMediaPlaybackService.isMediaApplication("com.microsoft.teams2"))
}
#endif
