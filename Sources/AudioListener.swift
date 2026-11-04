import AVFoundation
import CoreAudio
import NaturalLanguage
import Speech

// "listen = on" in config.txt: Crate listens to Spotify, and only Spotify, to time the lyrics to the words being sung.
// The audio is tapped from the Spotify app (Core Audio process tap, macOS 14.2+) and goes straight to macOS speech
// recognition (macOS 26), on this Mac. Nothing is recorded or sent anywhere: only the recognized words and their
// times are kept, to line them up with the lyrics (LyricsSync.swift).
// The first time, macOS asks to allow Crate to record the computer's audio. While Crate listens,
// macOS shows its recording indicator in the menu bar.

/// A word heard in Spotify's audio, timed on this Mac's clock (CACurrentMediaTime, s)
struct TimedWord {
    let text: String
    let start: Double
    let end: Double
}

// MARK: - Core Audio

private enum HAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func value<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T,
                       _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T {
        var addr = address(selector, scope)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value)
        return value
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    static func objects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var addr = address(selector, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ids)
        return ids
    }

    /// The Spotify app's audio processes (it may have helpers)
    static func spotifyProcesses() -> [AudioObjectID] {
        objects(system, kAudioHardwarePropertyProcessObjectList).filter {
            (string($0, kAudioProcessPropertyBundleID) ?? "").hasPrefix(Spotify.bundleID)
        }
    }

    static var defaultOutput: AudioDeviceID { value(system, kAudioHardwarePropertyDefaultSystemOutputDevice, AudioDeviceID(0)) }
}

/// Spotify's audio, as it plays. Muted for Crate's tests only: by default Spotify is heard as usual
@available(macOS 14.2, *)
private final class SpotifyTap {
    let format: AVAudioFormat
    let processes: [AudioObjectID]
    let output: AudioDeviceID
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "crate.listen.audio", qos: .userInitiated)
    /// Last time a buffer arrived (CACurrentMediaTime): a tap that stops delivering is rebuilt
    private(set) var lastBuffer = CACurrentMediaTime()

    /// `onBuffer` gets each buffer (a copy) and the time of its first frame on this Mac's clock, on an audio queue
    init?(onBuffer: @escaping (AVAudioPCMBuffer, Double) -> Void) {
        let processes = HAL.spotifyProcesses(), output = HAL.defaultOutput
        guard !processes.isEmpty, let outputUID = HAL.string(output, kAudioDevicePropertyDeviceUID) else { return nil }

        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.uuid = UUID()
        description.muteBehavior = ProcessInfo.processInfo.environment["CRATE_LISTEN_MUTED"] != nil ? .muted : .unmuted
        description.isPrivate = true
        description.name = "Crate"
        var tap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(description, &tap) == noErr else { return nil }
        var asbd = HAL.value(tap, kAudioTapPropertyFormat, AudioStreamBasicDescription())
        guard let format = AVAudioFormat(streamDescription: &asbd), format.commonFormat == .pcmFormatFloat32 else {
            AudioHardwareDestroyProcessTap(tap)
            return nil
        }
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Crate",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate) == noErr else {
            AudioHardwareDestroyProcessTap(tap)
            return nil
        }
        self.processes = processes
        self.output = output
        self.format = format
        self.tap = tap
        self.aggregate = aggregate
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, queue) { [weak self] _, input, inputTime, _, _ in
            guard let source = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil), source.frameLength > 0,
                  let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: source.frameLength) else { return }
            copy.frameLength = source.frameLength
            let from = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: source.audioBufferList))
            let to = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            for (f, t) in zip(from, to) where f.mData != nil && t.mData != nil { memcpy(t.mData, f.mData, Int(min(f.mDataByteSize, t.mDataByteSize))) }
            let host = inputTime.pointee.mFlags.contains(.hostTimeValid)
                ? Double(AudioConvertHostTimeToNanos(inputTime.pointee.mHostTime)) / 1e9 : CACurrentMediaTime()
            self?.lastBuffer = CACurrentMediaTime()
            onBuffer(copy, host)
        }
        guard status == noErr, AudioDeviceStart(aggregate, procID) == noErr else {
            stop()
            return nil
        }
    }

    /// Spotify restarted, or the sound now goes to other speakers / headphones
    var isStale: Bool {
        let now = Set(HAL.spotifyProcesses())
        return !processes.allSatisfy(now.contains) || HAL.defaultOutput != output || CACurrentMediaTime() - lastBuffer > 3
    }

    func stop() {
        if let procID {
            AudioDeviceStop(aggregate, procID)
            AudioDeviceDestroyIOProcID(aggregate, procID)
            self.procID = nil
        }
        if aggregate != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregate); aggregate = kAudioObjectUnknown }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap); tap = kAudioObjectUnknown }
    }

    deinit { stop() }
}

/// How long the sound takes to come out of the current speakers or headphones (s): a few ms built in, 0.1–0.3 s over Bluetooth
func currentOutputLatency() -> Double {
    let device = HAL.value(HAL.system, kAudioHardwarePropertyDefaultOutputDevice, AudioDeviceID(0))
    let rate = HAL.value(device, kAudioDevicePropertyNominalSampleRate, 0.0)
    guard device != 0, rate > 0 else { return 0 }
    let out = kAudioObjectPropertyScopeOutput
    let frames = HAL.value(device, kAudioDevicePropertyLatency, UInt32(0), out) + HAL.value(device, kAudioDevicePropertySafetyOffset, UInt32(0), out)
        + HAL.value(device, kAudioDevicePropertyBufferFrameSize, UInt32(0))
    let stream = HAL.objects(device, kAudioDevicePropertyStreams, out).first.map { HAL.value($0, kAudioStreamPropertyLatency, UInt32(0)) } ?? 0
    return min(0.5, Double(frames + stream) / rate)
}

// MARK: - Listening

@available(macOS 26, *)
final class AudioListener {
    let locale: Locale
    /// Recognized words, on the main thread. They come a few seconds after being sung (up to about 20 s)
    var onWords: ([TimedWord]) -> Void = { _ in }
    /// Spotify plays but Crate hears only silence: macOS hasn't allowed Crate to record the audio
    var onSilence: () -> Void = {}

    private var tap: SpotifyTap?
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var results: Task<Void, Never>?
    private var watchdog: Timer?
    private var speechFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    /// Audio sent to the recognizer (in its sample rate) -> when it was playing: to time the words
    private var checkpoints: [(sample: Double, host: Double)] = []
    private var samples = 0.0
    private var level = 0.02
    private var silentSince: Double?
    private let lock = NSLock()

    init(locale: Locale) { self.locale = locale }

    /// The recognizer's language for these lyrics, if macOS can recognize it (it may download it first)
    static func locale(for lyrics: [Line]) async -> Locale? {
        guard SpeechTranscriber.isAvailable else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(lyrics.map(\.text).joined(separator: "\n"))
        guard let language = recognizer.dominantLanguage?.rawValue else { return nil }
        let supported = await SpeechTranscriber.supportedLocales.filter { $0.language.languageCode?.identifier == language }
        guard !supported.isEmpty else { return nil }
        let installed = Set(await SpeechTranscriber.installedLocales.map(\.identifier))
        // The language's main accent (en_US, fr_FR, es_ES…): artists rarely sing with the listener's. Then this Mac's region;
        // already installed ones first
        let mine = Locale.current.region?.identifier
        let main = Locale.Language(identifier: language).maximalIdentifier.split(separator: "-").last.map(String.init)
        func rank(_ locale: Locale) -> Int {
            let region = locale.region?.identifier
            return (installed.contains(locale.identifier) ? 0 : 4) + (region == main ? 0 : region == mine ? 1 : 2)
        }
        return supported.sorted { rank($0) != rank($1) ? rank($0) < rank($1) : $0.identifier < $1.identifier }.first
    }

    /// Starts listening; false if it can't (Spotify not playing yet, language model missing…)
    func start() async -> Bool {
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        do {
            // First time for this language: macOS downloads its speech recognition
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        } catch {
            log("Listen: no speech recognition for \(locale.identifier): \(error)")
            return false
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { return false }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
        do { try await analyzer.start(inputSequence: stream) } catch {
            log("Listen: recognition didn't start: \(error)")
            return false
        }
        self.analyzer = analyzer
        self.input = input
        speechFormat = format

        results = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    var words: [TimedWord] = []
                    for run in result.text.runs {
                        guard let range = run.audioTimeRange else { continue }
                        let text = String(result.text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty, let start = self.host(range.start.seconds), let end = self.host(range.end.seconds) {
                            words.append(TimedWord(text: text, start: start, end: end))
                        }
                    }
                    let found = words
                    if !found.isEmpty { await MainActor.run { self.onWords(found) } }
                }
            } catch {}
        }
        await MainActor.run {
            self.connect()
            // Spotify restarts, the sound moves to AirPods…: tap again. If nothing comes at all after a few tries,
            // macOS most likely refused: say so, then only try again every 30 s
            var failures = 0, ticks = 0
            let watchdog = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                guard let self else { return }
                ticks += 1
                guard self.tap?.isStale ?? true else { failures = 0; return }
                failures += 1
                if failures == 3 { self.onSilence() }
                if failures < 3 || ticks % 15 == 0 { self.connect() }
            }
            RunLoop.main.add(watchdog, forMode: .common)
            self.watchdog = watchdog
        }
        log("Listen: listening to Spotify in \(locale.identifier)")
        return true
    }

    private func connect() {
        tap?.stop()
        tap = SpotifyTap { [weak self] buffer, host in self?.feed(buffer, host) }
        lock.lock()
        converter = tap.flatMap { tap in speechFormat.flatMap { AVAudioConverter(from: tap.format, to: $0) } }
        lock.unlock()
    }

    /// Audio thread: louder or quieter to a steady level whatever Spotify's volume, then to the recognizer
    private func feed(_ buffer: AVAudioPCMBuffer, _ host: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard let converter, let speechFormat, let input, let channels = buffer.floatChannelData else { return }
        let n = Int(buffer.frameLength), count = Int(buffer.format.channelCount)
        var energy: Float = 0
        for c in 0..<count { for i in 0..<n { energy += channels[c][i] * channels[c][i] } }
        let rms = Double((energy / Float(max(1, n * count))).squareRoot())
        if rms > 0.0005 { level = level * 0.995 + rms * 0.005 }
        watchSilence(rms, host)
        let gain = Float(min(30, max(1, 0.1 / max(level, 0.0001))))
        for c in 0..<count { for i in 0..<n { channels[c][i] = max(-1, min(1, channels[c][i] * gain)) } }

        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * speechFormat.sampleRate / buffer.format.sampleRate) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: speechFormat, frameCapacity: capacity) else { return }
        var given = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true
            status.pointee = .haveData
            return buffer
        }
        guard converted.frameLength > 0 else { return }
        checkpoints.append((samples, host))
        if checkpoints.count > 20_000 { checkpoints.removeFirst(10_000) }
        samples += Double(converted.frameLength)
        input.yield(AnalyzerInput(buffer: converted))
    }

    /// Digital silence for 10 s: Spotify paused or at volume 0, or macOS didn't allow the recording (onSilence checks)
    private func watchSilence(_ rms: Double, _ host: Double) {
        if rms > 0 { silentSince = nil; return }
        if silentSince == nil { silentSince = host }
        if let since = silentSince, host - since > 10 {
            silentSince = host
            DispatchQueue.main.async { self.onSilence() }
        }
    }

    /// Recognizer time (s from the start of listening) -> this Mac's clock
    private func host(_ audioTime: Double) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        guard let format = speechFormat else { return nil }
        let sample = audioTime * format.sampleRate
        guard let checkpoint = checkpoints.last(where: { $0.sample <= sample }) ?? checkpoints.first else { return nil }
        return checkpoint.host + (sample - checkpoint.sample) / format.sampleRate
    }

    /// Stops listening. Words still being recognized keep coming for a few seconds
    func stop() {
        watchdog?.invalidate()
        watchdog = nil
        tap?.stop()
        tap = nil
        lock.lock()
        input?.finish()
        input = nil
        lock.unlock()
        let analyzer = self.analyzer, results = self.results
        self.analyzer = nil
        // Keeps this listener alive until the last words are in (Crate already let go of it)
        Task { [self] in
            try? await analyzer?.finalizeAndFinishThroughEndOfInput()
            // The results don't always end on their own: give the last words 25 s, then let go
            try? await Task.sleep(for: .seconds(25))
            results?.cancel()
            _ = self
        }
    }
}
