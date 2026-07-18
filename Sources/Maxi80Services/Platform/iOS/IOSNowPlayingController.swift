import Foundation

#if !SKIP_BRIDGE

  #if SKIP
    // Android implementation is in AndroidNowPlayingController.swift
  #else

    #if os(iOS) || os(tvOS)
      import MediaPlayer
      import UIKit

      // MARK: - IOSNowPlayingController (iOS Implementation)

      extension NowPlayingController {

        // MARK: - Setup

        /// Configure remote command handlers on MPRemoteCommandCenter.
        private func setupRemoteCommands() {
          let commandCenter = MPRemoteCommandCenter.shared()

          commandCenter.playCommand.isEnabled = true
          commandCenter.playCommand.addTarget { [weak self] _ in
            self?.onRemoteCommand?("play")
            return .success
          }

          commandCenter.pauseCommand.isEnabled = true
          commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.onRemoteCommand?("pause")
            return .success
          }

          commandCenter.togglePlayPauseCommand.isEnabled = true
          commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.onRemoteCommand?("togglePlayPause")
            return .success
          }
        }

        // MARK: - Now Playing Info

        /// Update the now-playing info center with current metadata.
        func platformUpdateNowPlaying(
          artist: String, title: String, artworkURL: String?, isPlaying: Bool
        ) {
          setupRemoteCommands()

          var nowPlayingInfo: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: artist,
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: 0,
          ]

          MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo

          // Load artwork asynchronously if URL is provided
          if let urlString = artworkURL, let url = URL(string: urlString) {
            Task {
              do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let image = UIImage(data: data) {
                  let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                  nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
                  MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
                }
              } catch {
                // Artwork download failed — keep metadata without artwork
              }
            }
          }
        }

        // MARK: - Playback State

        /// Update only the playback rate in the now-playing info.
        func platformUpdatePlaybackState(isPlaying: Bool) {
          guard var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
          nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
          MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        }

        // MARK: - Tear Down

        /// Disable remote commands and clear now-playing info.
        func platformTearDown() {
          let commandCenter = MPRemoteCommandCenter.shared()
          commandCenter.playCommand.isEnabled = false
          commandCenter.pauseCommand.isEnabled = false
          commandCenter.togglePlayPauseCommand.isEnabled = false

          commandCenter.playCommand.removeTarget(nil)
          commandCenter.pauseCommand.removeTarget(nil)
          commandCenter.togglePlayPauseCommand.removeTarget(nil)

          MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }
      }

    #endif  // os(iOS)

  #endif

#endif  // !SKIP_BRIDGE
