//
//  SessionAudio.swift
//  Artemis
//
//  Sound for a session with the microphone on, and Settings' Test microphone.
//
//  With the microphone on, the PC's audio and the microphone share one AVAudioEngine running
//  Apple's voice processing: the echo canceller knows what the iPhone's speaker plays, so the
//  PC doesn't hear its own audio back, and noise is suppressed. The microphone's audio goes
//  through MicFrameAssembler (48 kHz mono, 20 ms) and MicrophoneEncoder (Opus) to the PC as
//  soon as each frame is complete. With the microphone off, sessions play through SDL as
//  before (Connection.m) and nothing here runs.
//
//  The audio session is set before LiStartConnection (playAndRecord: the speaker by default,
//  Bluetooth headphones over A2DP; the iPhone's own microphone unless the user picked another,
//  so AirPods keep their full-quality sound).
//
//  Threads: `queue` owns the engine and the session; the engine's render thread hands audio
//  over through lock-free rings; the encoder thread converts, encodes and sends.
//

import AVFAudio
import Synchronization

extension Notification.Name {
    /// The session's microphone started or stopped sending, or was muted (main thread).
    static let artemisMicrophoneChanged = Notification.Name("ArtemisMicrophoneChanged")
}

@objc(ArtemisSessionAudio)
final class SessionAudio: NSObject, @unchecked Sendable {
    @objc static let shared = SessionAudio()

    /// UI tests and the end-to-end check (-ArtemisTestMicTone YES): a test tone (TestTone) takes
    /// the microphone's place; no microphone is opened, so no permission is needed.
    static var usesTestTone: Bool { UserDefaults.standard.bool(forKey: "ArtemisTestMicTone") }

    /// Whether a session starting now sends the microphone: turned on in Settings and allowed.
    @objc static var microphoneWanted: Bool {
        MicSettings.current.enabled && (usesTestTone || SystemMicPermission.shared.status == .granted)
    }

    /// What the microphone test or session listens to.
    struct Listening {
        /// The input's name ("iPhone Microphone", a headset's), or "the test tone".
        var name: String
        /// The chosen input isn't connected: this is the iPhone's instead.
        var fellBack: Bool
    }

    private enum Capture {
        case none, microphone, tone
    }

    private let queue = DispatchQueue(label: "Artemis session audio", qos: .userInteractive)

    // Owned by `queue`
    private var engine: AVAudioEngine?
    private var sessionActive = false
    private var wantsCapture = Capture.none
    private var playback: (rate: Double, channels: Int)?
    private var input = MicInputChoice.iPhone
    private var listening: Listening?
    private var toneTimer: DispatchSourceTimer?
    private var encoderThread: Thread?
    private var encoderDone: DispatchSemaphore?
    private var observers: [NSObjectProtocol] = []
    private var interrupted = false

    // Between threads
    /// The PC's audio, interleaved, from the decoder to the render thread (0.5 s at most).
    private let gameRing = AudioRing<Int16>(capacity: 48000)
    private let gameChannels = Atomic<Int>(2)
    /// The microphone, one channel at its own rate, from the render thread to the encoder.
    private let captureRing = AudioRing<Float>(capacity: 96000)
    private let captureSignal = DispatchSemaphore(value: 0)
    private let stopEncoder = Atomic<Bool>(false)
    private let sendingFlag = Atomic<Bool>(false)
    private let mutedFlag = Atomic<Bool>(false)
    /// Held while a packet is being sent: stopMicrophone() waits it out.
    private let sendLock = NSLock()
    /// The loudest sample since the meter last looked.
    private let peak = Atomic<Int>(0)
    /// Audio callbacks from the input since it opened (0: nothing is arriving).
    private let captureCallbacks = Atomic<Int>(0)
    private let encoderStats = Mutex<(encoded: Int, sent: Int, samples: Int)>((0, 0, 0))

    // MARK: Session (Connection.m)

    /// Before LiStartConnection. With the microphone wanted, the session's audio runs here.
    @objc func prepare(microphone: Bool) {
        queue.sync {
            teardown()
            wantsCapture = microphone ? (Self.usesTestTone ? .tone : .microphone) : .none
            guard microphone else { return }
            input = MicSettings.current.input
            configureSession()
        }
    }

    /// The PC's audio plays here (not through SDL) for this session.
    @objc var playsGameAudio: Bool {
        queue.sync { wantsCapture != .none }
    }

    /// ArInit: the PC's audio format. Starts the engine (and the microphone with it).
    @objc func startPlayback(sampleRate: Int32, channels: Int32) -> Bool {
        queue.sync {
            playback = (Double(sampleRate), Int(channels))
            gameChannels.store(Int(channels), ordering: .releasing)
            gameRing.clear()
            return startEngine()
        }
    }

    /// ArDecodeAndPlaySample: decoded samples, interleaved. Dropped when 40 ms are waiting already.
    @objc func play(_ samples: UnsafePointer<Int16>, frames: Int32) {
        let channels = gameChannels.load(ordering: .acquiring)
        guard gameRing.count < 48 * 40 * channels else { return }
        gameRing.write(UnsafeBufferPointer(start: samples, count: Int(frames) * channels))
    }

    /// ArCleanup.
    @objc func stopPlayback() {
        queue.sync {
            playback = nil
            stopEngine()
        }
    }

    /// The connection is up: the microphone goes to the PC if the PC set up its side.
    @objc func connectionStarted() {
        guard queue.sync(execute: { wantsCapture != .none }) else { return }
        guard LiIsMicrophoneStreamActive() else {
            logInfo("Host did not negotiate microphone streaming; leaving client microphone disabled")
            return
        }
        mutedFlag.store(false, ordering: .releasing)
        sendingFlag.store(true, ordering: .releasing)
        logInfo("Microphone capture streaming started; negotiated mic stream is active")
        notifyChanged()
    }

    /// Before LiStopConnection (moonlight-common-c's socket must not be in use when it closes):
    /// returns once no packet is being sent.
    @objc func stopMicrophone() {
        guard sendingFlag.exchange(false, ordering: .acquiringAndReleasing) else { return }
        sendLock.lock()
        sendLock.unlock()
        notifyChanged()
    }

    /// After LiStopConnection: everything stops, the audio session is handed back.
    @objc func end() {
        stopMicrophone()
        queue.sync {
            teardown()
        }
    }

    // MARK: The control bar

    /// The microphone is going to the PC in this session.
    var isSending: Bool { sendingFlag.load(ordering: .acquiring) }

    /// Muted: nothing is sent (the microphone stays open, so unmuting is instant).
    var muted: Bool {
        get { mutedFlag.load(ordering: .acquiring) }
        set {
            mutedFlag.store(newValue, ordering: .releasing)
            logInfo(newValue ? "Microphone muted" : "Microphone unmuted")
            notifyChanged()
        }
    }

    // MARK: Test microphone (Settings) and the demo session

    /// Opens the chosen input (or the test tone) without a session; `done` on the main thread
    /// with what it listens to, or nil if it couldn't.
    func startTest(input: MicInputChoice, done: @escaping (Listening?) -> Void) {
        queue.async {
            self.teardown()
            self.wantsCapture = Self.usesTestTone ? .tone : .microphone
            self.input = input
            self.configureSession()
            let started = self.startEngine()
            let listening = started ? self.listening : nil
            if !started { self.teardown() }
            DispatchQueue.main.async { done(listening) }
        }
    }

    func stopTest() {
        queue.async {
            self.teardown()
        }
    }

    /// The demo mode's session (-ArtemisDemo YES with the microphone on): the test tone encoded
    /// as in a session, counted instead of sent, so the UI tests see the control bar's button
    /// and the frames.
    func startDemoSession() {
        queue.sync {
            teardown()
            wantsCapture = .tone
            _ = startEngine(sendsToHost: false)
        }
        mutedFlag.store(false, ordering: .releasing)
        sendingFlag.store(true, ordering: .releasing)
        notifyChanged()
    }

    /// The meter's reading since the last call (0…32767).
    func takePeak() -> Int {
        peak.exchange(0, ordering: .acquiringAndReleasing)
    }

    var inputCallbacks: Int { captureCallbacks.load(ordering: .acquiring) }

    /// Opus packets encoded and sent, and the last one's length in 48 kHz samples.
    var packetStats: (encoded: Int, sent: Int, samples: Int) {
        encoderStats.withLock { $0 }
    }

    // MARK: Audio session

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        // Speaker by default (not the earpiece), Bluetooth headphones in full quality; the call
        // link (HFP) only when the user picked a Bluetooth microphone. Mixing with other apps'
        // audio, as sessions without the microphone do.
        var options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers]
        if wantsCapture == .microphone && input.usesBluetoothCallLink {
            options.insert(.allowBluetoothHFP)
        }
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: options)
            try? session.setPreferredSampleRate(48000)
            try? session.setPreferredIOBufferDuration(0.005)
            try session.setActive(true)
            sessionActive = true
        } catch {
            logInfo("Couldn't set up the audio session for the microphone: \(error.localizedDescription)")
        }
        applyPreferredInput()
        observeSession()
    }

    /// The chosen input if it's connected, else the iPhone's own microphone.
    private func applyPreferredInput() {
        guard wantsCapture == .microphone else {
            listening = Listening(name: "the test tone", fellBack: false)
            return
        }
        let session = AVAudioSession.sharedInstance()
        let inputs = session.availableInputs ?? []
        let wanted: [AVAudioSession.Port] = switch input {
        case .iPhone: [.builtInMic]
        case .headset: [.headsetMic, .usbAudio]
        case .bluetooth: [.bluetoothHFP]
        }
        let port = inputs.first { wanted.contains($0.portType) } ?? inputs.first { $0.portType == .builtInMic }
        if let port {
            do {
                try session.setPreferredInput(port)
            } catch {
                logInfo("Couldn't choose \(port.portName) as the microphone: \(error.localizedDescription)")
            }
        }
        let name = port?.portName ?? session.currentRoute.inputs.first?.portName ?? "the microphone"
        listening = Listening(name: name, fellBack: port.map { !wanted.contains($0.portType) } ?? (input != .iPhone))
        logInfo("Microphone input: \(name)\(listening?.fellBack == true ? " (the chosen input isn't connected)" : "")")
    }

    private func observeSession() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: nil) { [weak self] note in
            let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap { AVAudioSession.InterruptionType(rawValue: $0) } == .began
            self?.queue.async { self?.interruption(began: began) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: nil) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap { AVAudioSession.RouteChangeReason(rawValue: $0) }
            guard reason == .newDeviceAvailable || reason == .oldDeviceUnavailable else { return }
            // A headset came or went: keep the chosen microphone (or the iPhone's)
            self?.queue.async { if self?.sessionActive == true { self?.applyPreferredInput() } }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: nil) { [weak self] _ in
            self?.queue.async { self?.restart(reason: "media services were reset") }
        })
    }

    /// A call or Siri took the audio: the engine stopped. Afterwards it starts again.
    private func interruption(began: Bool) {
        guard engine != nil || interrupted else { return }
        if began {
            logInfo("Audio interrupted (a call or Siri); the microphone pauses")
            interrupted = true
            return
        }
        interrupted = false
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            logInfo("Couldn't take the audio back after an interruption: \(error.localizedDescription)")
        }
        restart(reason: "the interruption ended")
    }

    /// The input or output changed under the engine (AVAudioEngineConfigurationChange): build it again.
    private func restart(reason: String) {
        guard engine != nil else { return }
        logInfo("Restarting session audio: \(reason)")
        let sends = encoderSendsToHost
        stopEngine()
        _ = startEngine(sendsToHost: sends)
    }

    // MARK: Engine

    private var encoderSendsToHost = true
    private var configurationObserver: NSObjectProtocol?

    @discardableResult
    private func startEngine(sendsToHost: Bool = true) -> Bool {
        stopEngine()
        encoderSendsToHost = sendsToHost
        let engine = AVAudioEngine()
        var captureFormat: AVAudioFormat?
        var voiceProcessing = false

        if wantsCapture == .microphone {
            let inputNode = engine.inputNode
            do {
                try inputNode.setVoiceProcessingEnabled(true)
                voiceProcessing = true
                // Other apps' audio stays at its level; the PC's plays through this engine,
                // so the echo canceller hears it
                inputNode.voiceProcessingOtherAudioDuckingConfiguration =
                    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
            } catch {
                logInfo("Voice processing unavailable (\(error.localizedDescription)); the microphone goes without echo cancellation")
            }
            let format = inputNode.outputFormat(forBus: 0)
            if format.sampleRate > 0, format.channelCount > 0, format.commonFormat == .pcmFormatFloat32, !format.isInterleaved {
                captureFormat = format
                let sink = makeSink(channels: Int(format.channelCount), firstOnly: voiceProcessing)
                engine.attach(sink)
                engine.connect(inputNode, to: sink, format: format)
            } else {
                logInfo("No microphone input (format \(format))")
            }
        }

        if let playback {
            let format = AVAudioFormat(standardFormatWithSampleRate: playback.rate, channels: AVAudioChannelCount(playback.channels))!
            let source = makeSource(channels: playback.channels)
            engine.attach(source)
            engine.connect(source, to: engine.mainMixerNode, format: format)
        } else {
            // Voice processing runs input and output together: the output needs a graph too
            _ = engine.mainMixerNode
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            logInfo("Couldn't start session audio: \(error.localizedDescription)")
            return false
        }
        self.engine = engine
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.queue.async { self?.restart(reason: "the audio route changed") }
        }

        switch wantsCapture {
        case .microphone where captureFormat != nil:
            startEncoder(inputRate: captureFormat!.sampleRate, sendsToHost: sendsToHost)
            logInfo(String(format: "Microphone capture: %.0f Hz, %d channel(s), voice processing %@",
                           captureFormat!.sampleRate, captureFormat!.channelCount, voiceProcessing ? "on" : "off"))
        case .tone:
            let tone = TestTone(sampleRate: 44100, channels: 1)
            startEncoder(inputRate: tone.format.sampleRate, sendsToHost: sendsToHost)
            startTone(tone)
            logInfo("Microphone capture: the test tone")
        default:
            break
        }
        return true
    }

    private func stopEngine() {
        toneTimer?.cancel()
        toneTimer = nil
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
        if let engine {
            engine.stop()
            if wantsCapture == .microphone {
                try? engine.inputNode.setVoiceProcessingEnabled(false)
            }
        }
        engine = nil
        stopEncoderThread()
    }

    /// Everything off; the audio session handed back to other apps.
    private func teardown() {
        stopEngine()
        playback = nil
        interrupted = false
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        if sessionActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            sessionActive = false
        }
        wantsCapture = .none
        listening = nil
    }

    /// Plays the PC's audio from gameRing (render thread: no locks, no allocation).
    private func makeSource(channels: Int) -> AVAudioSourceNode {
        let ring = gameRing
        let scratch = Scratch<Int16>(count: 8192 * channels)
        return AVAudioSourceNode { isSilence, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let frames = min(Int(frameCount), 8192)
            let read = ring.read(into: UnsafeMutableBufferPointer(start: scratch.pointer, count: frames * channels)) / channels
            for (c, buffer) in buffers.enumerated() {
                guard let out = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let channel = min(c, channels - 1)
                for i in 0..<read {
                    out[i] = Float(scratch.pointer[i * channels + channel]) / 32768
                }
                for i in read..<Int(frameCount) {
                    out[i] = 0
                }
            }
            if read == 0 { isSilence.pointee = true }
            return noErr
        }
    }

    /// Takes the microphone into captureRing (render thread): voice processing's first channel,
    /// or the channels' average.
    private func makeSink(channels: Int, firstOnly: Bool) -> AVAudioSinkNode {
        let ring = captureRing
        let signal = captureSignal
        let scratch = Scratch<Float>(count: 8192)
        // The shared instance lives as long as the app: the block holds it without a count
        return AVAudioSinkNode { [unowned self] _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
            let frames = min(Int(frameCount), 8192)
            let used = firstOnly ? 1 : min(channels, buffers.count)
            guard used > 0 else { return noErr }
            let scale = 1 / Float(used)
            for i in 0..<frames {
                var sum: Float = 0
                for c in 0..<used {
                    if let data = buffers[c].mData?.assumingMemoryBound(to: Float.self) { sum += data[i] }
                }
                scratch.pointer[i] = sum * scale
            }
            ring.write(UnsafeBufferPointer(start: scratch.pointer, count: frames))
            self.captureCallbacks.add(1, ordering: .relaxed)
            signal.signal()
            return noErr
        }
    }

    /// The test tone in the microphone's place, in real time (10 ms at a time).
    private func startTone(_ tone: TestTone) {
        var tone = tone
        let ring = captureRing
        let signal = captureSignal
        let rate = tone.format.sampleRate
        let start = DispatchTime.now()
        var produced = 0
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "Artemis test tone", qos: .userInteractive))
        timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(1))
        timer.setEventHandler { [unowned self] in
            let due = Int(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9 * rate) - produced
            guard due > 0 else { return }
            let buffer = tone.next(frames: due)
            ring.write(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: due))
            produced += due
            self.captureCallbacks.add(1, ordering: .relaxed)
            signal.signal()
        }
        timer.resume()
        toneTimer = timer
    }

    // MARK: Encoder thread

    private func startEncoder(inputRate: Double, sendsToHost: Bool) {
        captureRing.clear()
        captureCallbacks.store(0, ordering: .releasing)
        peak.store(0, ordering: .releasing)
        encoderStats.withLock { $0 = (0, 0, 0) }
        stopEncoder.store(false, ordering: .releasing)
        guard let encoder = MicrophoneEncoder(sendingToHost: sendsToHost) else { return }
        let assembler = MicFrameAssembler(inputFormat: AVAudioFormat(standardFormatWithSampleRate: inputRate, channels: 1)!)
        let done = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            encoderLoop(assembler: assembler, encoder: encoder, inputRate: inputRate)
            done.signal()
        }
        thread.name = "Artemis microphone"
        thread.qualityOfService = .userInteractive
        encoderThread = thread
        encoderDone = done
        thread.start()
    }

    private func stopEncoderThread() {
        guard encoderThread != nil else { return }
        stopEncoder.store(true, ordering: .releasing)
        captureSignal.signal()
        encoderDone?.wait()
        encoderThread = nil
        encoderDone = nil
    }

    private func encoderLoop(assembler: MicFrameAssembler, encoder: MicrophoneEncoder, inputRate: Double) {
        let format = AVAudioFormat(standardFormatWithSampleRate: inputRate, channels: 1)!
        let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2048)!
        while !stopEncoder.load(ordering: .acquiring) {
            _ = captureSignal.wait(timeout: .now() + .milliseconds(100))
            while !stopEncoder.load(ordering: .acquiring) {
                let read = captureRing.read(into: UnsafeMutableBufferPointer(start: chunk.floatChannelData![0], count: 2048))
                guard read > 0 else { break }
                chunk.frameLength = AVAudioFrameCount(read)
                for frame in assembler.append(chunk) {
                    let loudest = frame.reduce(0) { max($0, abs(Int($1))) }
                    var current = peak.load(ordering: .relaxed)
                    while loudest > current {
                        let (exchanged, original) = peak.compareExchange(expected: current, desired: loudest, ordering: .acquiringAndReleasing)
                        if exchanged { break }
                        current = original
                    }
                    send(frame, encoder: encoder)
                }
            }
        }
    }

    private func send(_ frame: [Int16], encoder: MicrophoneEncoder) {
        guard sendingFlag.load(ordering: .acquiring), !mutedFlag.load(ordering: .acquiring) else { return }
        sendLock.lock()
        defer { sendLock.unlock() }
        // Checked again under the lock: stopMicrophone() may have just run
        guard sendingFlag.load(ordering: .acquiring) else { return }
        _ = frame.withUnsafeBufferPointer { encoder.encodeAndSend($0.baseAddress!) }
        encoderStats.withLock { $0 = (encoder.packetsEncoded, encoder.packetsSent, Int(encoder.lastPacketSamples)) }
    }

    private func notifyChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .artemisMicrophoneChanged, object: nil)
        }
    }
}

/// Memory for a render block, allocated up front (the render thread can't allocate).
private final class Scratch<Element>: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<Element>

    init(count: Int) {
        pointer = .allocate(capacity: count)
    }

    deinit {
        pointer.deallocate()
    }
}
