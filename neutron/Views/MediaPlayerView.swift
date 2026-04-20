//
//  MediaPlayerView.swift
//  neutron
//
//  Inline video/audio player similar to Finder's preview
//

import SwiftUI
import AVKit
import AppKit

// MARK: - File Type Detection

enum MediaType {
    case video
    case audio
    case image
    case other
    
    init(url: URL) {
        let ext = url.pathExtension.lowercased()
        
        let videoExtensions = ["mp4", "mov", "m4v", "avi", "mkv", "webm", "wmv", "flv", "ts"]
        let audioExtensions = ["mp3", "m4a", "wav", "aac", "flac", "ogg", "wma", "aiff"]
        let imageExtensions = ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tiff", "bmp", "svg"]
        
        if videoExtensions.contains(ext) {
            self = .video
        } else if audioExtensions.contains(ext) {
            self = .audio
        } else if imageExtensions.contains(ext) {
            self = .image
        } else {
            self = .other
        }
    }
}

// MARK: - Media Preview Panel

struct MediaPreviewPanel: View {
    let url: URL
    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var volume: Float = 1.0
    @State private var isMuted = false
    @State private var showControls = true
    @Binding var isPresented: Bool
    
    private var mediaType: MediaType {
        MediaType(url: url)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(url.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(Color(nsColor: .windowBackgroundColor))
            
            Divider()
            
            // Content
            Group {
                switch mediaType {
                case .video:
                    videoPlayer
                case .audio:
                    audioPlayer
                case .image:
                    imageViewer
                case .other:
                    unsupportedView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            // Controls for video/audio
            if mediaType == .video || mediaType == .audio {
                mediaControls
            }
        }
        .frame(minWidth: 400, minHeight: 300)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            setupPlayer()
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
    
    // MARK: - Video Player
    
    @ViewBuilder
    private var videoPlayer: some View {
        if let player = player {
            VideoPlayer(player: player)
                .onTapGesture(count: 2) {
                    toggleFullScreen()
                }
                .onTapGesture {
                    togglePlayPause()
                }
        } else {
            ProgressView("Loading...")
        }
    }
    
    // MARK: - Audio Player
    
    @ViewBuilder
    private var audioPlayer: some View {
        VStack(spacing: 20) {
            // Album art or waveform placeholder
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .frame(width: 200, height: 200)
                
                Image(systemName: "waveform")
                    .font(.system(size: 60))
                    .foregroundColor(.accentColor)
            }
            
            Text(url.deletingPathExtension().lastPathComponent)
                .font(.title2)
                .fontWeight(.semibold)
            
            Text(formatDuration(duration))
                .foregroundColor(.secondary)
        }
        .padding()
    }
    
    // MARK: - Image Viewer
    
    @ViewBuilder
    private var imageViewer: some View {
        if let nsImage = NSImage(contentsOf: url) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding()
        } else {
            Text("Unable to load image")
                .foregroundColor(.secondary)
        }
    }
    
    // MARK: - Unsupported
    
    private var unsupportedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.questionmark")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("Preview not available")
                .foregroundColor(.secondary)
            Button("Open with Default App") {
                NSWorkspace.shared.open(url)
            }
        }
    }
    
    // MARK: - Media Controls
    
    private var mediaControls: some View {
        VStack(spacing: 8) {
            // Progress bar
            HStack(spacing: 8) {
                Text(formatDuration(currentTime))
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 45, alignment: .trailing)
                
                Slider(value: $currentTime, in: 0...max(duration, 1)) { editing in
                    if !editing {
                        seekTo(currentTime)
                    }
                }
                
                Text(formatDuration(duration))
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 45, alignment: .leading)
            }
            
            // Playback controls
            HStack(spacing: 16) {
                // Skip backward
                Button {
                    skip(by: -10)
                } label: {
                    Image(systemName: "gobackward.10")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                
                // Play/Pause
                Button {
                    togglePlayPause()
                } label: {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 44))
                }
                .buttonStyle(.plain)
                
                // Skip forward
                Button {
                    skip(by: 10)
                } label: {
                    Image(systemName: "goforward.10")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                
                Spacer()
                
                // Volume
                Button {
                    isMuted.toggle()
                    player?.isMuted = isMuted
                } label: {
                    Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
                .buttonStyle(.plain)
                
                Slider(value: $volume, in: 0...1) { _ in
                    player?.volume = volume
                }
                .frame(width: 80)
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
    }
    
    // MARK: - Player Setup
    
    private func setupPlayer() {
        guard mediaType == .video || mediaType == .audio else { return }
        
        let avPlayer = AVPlayer(url: url)
        player = avPlayer
        
        // Observe playback time
        let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        avPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [self] time in
            currentTime = time.seconds
        }
        
        // Get duration
        Task {
            if let asset = avPlayer.currentItem?.asset {
                do {
                    let d = try await asset.load(.duration)
                    await MainActor.run {
                        duration = d.seconds
                    }
                } catch {
                    // Ignore
                }
            }
        }
    }
    
    private func togglePlayPause() {
        guard let player = player else { return }
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
    }
    
    private func seekTo(_ time: Double) {
        let cmTime = CMTime(seconds: time, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        player?.seek(to: cmTime)
    }
    
    private func skip(by seconds: Double) {
        let newTime = max(0, min(currentTime + seconds, duration))
        seekTo(newTime)
        currentTime = newTime
    }
    
    private func toggleFullScreen() {
        // For video, enter picture-in-picture or fullscreen
        if let window = NSApp.keyWindow {
            window.toggleFullScreen(nil)
        }
    }
    
    private func formatDuration(_ seconds: Double) -> String {
        guard seconds.isFinite && !seconds.isNaN else { return "0:00" }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - Quick Preview Sheet

struct QuickPreviewSheet: View {
    let urls: [URL]
    @Binding var isPresented: Bool
    @State private var currentIndex = 0
    
    var body: some View {
        VStack(spacing: 0) {
            if urls.indices.contains(currentIndex) {
                MediaPreviewPanel(url: urls[currentIndex], isPresented: $isPresented)
            }
            
            if urls.count > 1 {
                // Navigation for multiple files
                HStack {
                    Button {
                        if currentIndex > 0 {
                            currentIndex -= 1
                        }
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(currentIndex == 0)
                    
                    Text("\(currentIndex + 1) of \(urls.count)")
                        .font(.caption)
                    
                    Button {
                        if currentIndex < urls.count - 1 {
                            currentIndex += 1
                        }
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(currentIndex == urls.count - 1)
                }
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor))
            }
        }
        .frame(minWidth: 500, minHeight: 400)
    }
}

// MARK: - File Info with Media Duration

extension FileItem {
    var mediaDuration: String? {
        let type = MediaType(url: path)
        guard type == .video || type == .audio else { return nil }
        
        let asset = AVURLAsset(url: path)
        let seconds = CMTimeGetSeconds(asset.duration)
        guard seconds.isFinite && seconds > 0 else { return nil }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
