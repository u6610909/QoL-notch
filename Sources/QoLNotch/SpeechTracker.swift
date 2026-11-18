import AVFoundation
import Speech

/// Streams microphone audio into the system speech recogniser and reports the
/// words heard so far. Recognition is kept on-device whenever the Mac supports it.
final class SpeechTracker {
    var onWords: (([String], String) -> Void)?
    var onStatus: ((String) -> Void)?
    var onRestart: (() -> Void)?
    var onStopped: (() -> Void)?
    /// Loudness of the microphone, 0...1, reported a few times a second.
    var onLevel: ((Double) -> Void)?
    private var bufferCount = 0

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var running = false
    private var tapInstalled = false
    private let lock = NSLock()

    func start(localeID: String) {
        guard !running else { return }
        requestPermissions { [weak self] granted, message in
            guard let self else { return }
            guard granted else {
                self.onStatus?(message)
                self.onStopped?()
                return
            }
            self.begin(localeID: localeID)
        }
    }

    func stop() {
        guard running else { return }
        running = false
        task?.cancel()
        task = nil
        lock.lock(); request?.endAudio(); request = nil; lock.unlock()
        engine.stop()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        onStatus?("Paused")
        onLevel?(0)
        onStopped?()
    }

    // MARK: - Private

    private func requestPermissions(_ done: @escaping (Bool, String) -> Void) {
        SFSpeechRecognizer.requestAuthorization { speech in
            guard speech == .authorized else {
                DispatchQueue.main.async {
                    done(false, "Speech recognition is not allowed. Turn it on in System Settings → Privacy & Security.")
                }
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { mic in
                DispatchQueue.main.async {
                    done(mic, mic ? "" : "Microphone is not allowed. Turn it on in System Settings → Privacy & Security.")
                }
            }
        }
    }

    private func begin(localeID: String) {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID)) else {
            onStatus?("This language is not supported for speech recognition on this Mac.")
            onStopped?()
            return
        }
        guard recognizer.isAvailable else {
            onStatus?("Speech recognition is not available right now.")
            onStopped?()
            return
        }
        self.recognizer = recognizer

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            onStatus?("No microphone found.")
            onStopped?()
            return
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.lock.lock()
            self.request?.append(buffer)
            self.lock.unlock()

            self.bufferCount += 1
            guard self.bufferCount % 2 == 0, let samples = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            guard count > 0 else { return }
            var sum: Float = 0
            for i in 0..<count { sum += samples[i] * samples[i] }
            let level = min(1, Double((sum / Float(count)).squareRoot()) * 14)
            DispatchQueue.main.async { self.onLevel?(level) }
        }
        tapInstalled = true

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            tapInstalled = false
            onStatus?("Could not start the microphone: \(error.localizedDescription)")
            onStopped?()
            return
        }

        running = true
        startTask()
        let language = Locale.current.localizedString(forIdentifier: localeID) ?? localeID
        onStatus?(recognizer.supportsOnDeviceRecognition
            ? "Listening in \(language) (on-device)"
            : "Listening in \(language) (audio is processed by Apple's servers for this language)")
    }

    /// The recogniser ends a task after a stretch of silence or about a minute of audio,
    /// so a fresh one is started each time while the microphone keeps running.
    private func startTask() {
        guard running, let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        lock.lock(); self.request = request; lock.unlock()
        onRestart?()

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.running else { return }
                if let result {
                    let words = result.bestTranscription.segments.map(\.substring)
                    self.onWords?(words, result.bestTranscription.formattedString)
                }
                if error != nil || (result?.isFinal ?? false) {
                    self.task = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                        guard let self, self.running, self.task == nil else { return }
                        self.startTask()
                    }
                }
            }
        }
    }
}
