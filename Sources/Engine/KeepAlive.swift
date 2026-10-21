import AVFoundation

/// Instant mode: a silent, mixable audio session keeps Logline running in the background
/// so it can check on its own schedule. It never interrupts other audio.
@MainActor
final class KeepAlive {
    private var player: AVAudioPlayer?
    private var observers: [NSObjectProtocol] = []

    var isPlaying: Bool {
        player?.isPlaying ?? false
    }

    @discardableResult
    func start() -> Bool {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            if player == nil {
                let silence = try AVAudioPlayer(contentsOf: SilentTrack.url())
                silence.numberOfLoops = -1
                silence.volume = 0.01
                silence.prepareToPlay()
                player = silence
            }
            guard player?.play() == true else {
                Log.shared.add("Instant mode: the silent track wouldn't start", level: .error)
                return false
            }
            installObservers()
            return true
        } catch {
            Log.shared.add("Instant mode couldn't start its audio session: \(error.localizedDescription)", level: .error)
            return false
        }
    }

    func stop() {
        player?.stop()
        player = nil
        removeObservers()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func installObservers() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            MainActor.assumeIsolated {
                self?.interrupted(typeValue: raw)
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.rebuild()
            }
        })
    }

    private func removeObservers() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }

    private func interrupted(typeValue: UInt?) {
        guard let typeValue, let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        switch type {
        case .began:
            Log.shared.add("Instant mode: audio was interrupted (a call or Siri)")
        case .ended:
            try? AVAudioSession.sharedInstance().setActive(true)
            let resumed = player?.play() ?? false
            Log.shared.add(resumed ? "Instant mode resumed after an interruption" : "Instant mode couldn't resume yet",
                           level: resumed ? .info : .warning)
        @unknown default:
            break
        }
    }

    private func rebuild() {
        player = nil
        removeObservers()
        Log.shared.add("Instant mode: media services restarted, rebuilding the audio session")
        start()
    }
}

/// Two seconds of 8 kHz silence, written once to the temporary directory.
enum SilentTrack {
    static func url() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("logline-silence.wav")
        if !FileManager.default.fileExists(atPath: url.path) {
            try makeWAV().write(to: url, options: .atomic)
        }
        return url
    }

    static func makeWAV(seconds: Int = 2, sampleRate: Int = 8000) -> Data {
        let dataSize = UInt32(seconds * sampleRate * 2)
        var data = Data()
        func append(_ text: String) {
            data.append(contentsOf: Array(text.utf8))
        }
        func append32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func append16(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        append("RIFF")
        append32(36 + dataSize)
        append("WAVE")
        append("fmt ")
        append32(16)
        append16(1)
        append16(1)
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate * 2))
        append16(2)
        append16(16)
        append("data")
        append32(dataSize)
        data.append(Data(count: Int(dataSize)))
        return data
    }
}
