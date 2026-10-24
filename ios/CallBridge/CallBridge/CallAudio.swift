import Foundation
import AVFoundation

struct AudioStatistics {
    var droppedCapture: UInt64 = 0
    var droppedPlayback: UInt64 = 0
    var hardwareSampleRate: Double = 0
    var capturedBuffers: UInt64 = 0
    var microphonePackets: UInt64 = 0
    var playedBuffers: UInt64 = 0
    var renderedBuffers: UInt64 = 0
    var nonzeroRenderedBuffers: UInt64 = 0
    var renderedLevel: Double = 0
    var firstNonzeroRenderDelay: Double = -1
    var firstNonzeroRenderTime: Double = 0
    var nonzeroRenderedSamples: UInt64 = 0
}

/// Live conversion only. Buffers never leave RAM except through the authenticated Tailscale socket.
final class CallAudio {
    private let queue = DispatchQueue(label: "com.doitio.callbridge.audio", qos: .userInteractive)
    private let ingressLock = NSLock()
    private var inputBuffers: [AVAudioPCMBuffer] = []
    private var downlinkPackets: [Data] = []
    private var inputDrainScheduled = false
    private var playbackDrainScheduled = false
    private var accepting = false
    private var ingressGeneration: UInt64 = 0
    private var ingressCaptureDrops: UInt64 = 0
    private var ingressPlaybackDrops: UInt64 = 0
    private var engine: AVAudioEngine?
    private var tapInstalled = false
    private var mixerTapInstalled = false
    private var renderedBuffers: UInt64 = 0
    private var nonzeroRenderedBuffers: UInt64 = 0
    private var renderedLevel: Double = 0
    private var firstNonzeroRenderTime: TimeInterval = 0
    private var nonzeroRenderedSamples: UInt64 = 0
    private var startTime: TimeInterval = 0
    private var player: AVAudioPlayerNode?
    private var captureConverter: AVAudioConverter?
    private var playbackConverter: AVAudioConverter?
    private let wireFormat = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
    private var outputFormat: AVAudioFormat?
    private var micSamples: [Int16] = []
    private var observers: [NSObjectProtocol] = []
    private var sessionID: UUID?
    private var playbackGeneration: UInt64 = 0
    private var scheduledPlayback = 0
    private var statistics = AudioStatistics()
    private var lastStatistics: TimeInterval = 0
    private var onMicrophone: ((UUID, Data) -> Void)?
    private var onStatistics: ((UUID, AudioStatistics) -> Void)?
    private var onFailure: ((UUID, String) -> Void)?
    private var captureBuffers: UInt64 = 0
    private var microphonePackets: UInt64 = 0
    private var playbackPackets: UInt64 = 0
    private var reportedNonzeroPlayback = false
    private var onStarted: ((UUID, Bool) -> Void)?
    private var startupDeadline: TimeInterval?
    private var startupRebuilds = 0
    private var startupRebuildPending = false
    private var speakerOverrideActive = false
    private var ownsSessionActivation = false
    private var microphoneMuted = false
    private var startupRoute: [String] = [] // In-memory comparison only; never logged.

    static func prepareSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
        try session.setPreferredIOBufferDuration(0.02)
    }

    func setMicrophoneMuted(_ muted: Bool) { queue.async { self.microphoneMuted = muted } }

    func start(id: UUID, speakerphone: Bool = false, systemManagedSession: Bool = false,
               initiallyMuted: Bool = false, finiteTest: Bool = false,
               microphone: @escaping (UUID, Data) -> Void,
               statistics: @escaping (UUID, AudioStatistics) -> Void,
               failure: @escaping (UUID, String) -> Void,
               completion: @escaping (UUID, Bool) -> Void) {
        queue.async {
            self.stopOnQueue()
            self.microphoneMuted = initiallyMuted
            self.sessionID = id
            self.startTime = ProcessInfo.processInfo.systemUptime
            self.onMicrophone = microphone
            self.onStatistics = statistics
            self.onFailure = failure
            self.onStarted = completion
            self.startupDeadline = finiteTest ? ProcessInfo.processInfo.systemUptime + 3 : nil
            var startupStep = "category"
            do {
                let session = AVAudioSession.sharedInstance()
                // The wire is 16 kHz, not the hardware. Convert from the native route instead of
                // requesting another hardware-rate transition while voice processing starts.
                if !systemManagedSession {
                    try Self.prepareSession()
                    startupStep = "activate"
                    try session.setActive(true)
                    self.ownsSessionActivation = true
                }
                self.diagnostic("session_owner=\(systemManagedSession ? "callkit" : "app")")
                if speakerphone {
                    try session.overrideOutputAudioPort(.speaker)
                    self.speakerOverrideActive = true
                }
                self.startupRoute = self.routeSignature()
                startupStep = "engine"
                try self.configureEngineOnQueue(id: id)
                if finiteTest {
                    self.queue.asyncAfter(deadline: .now() + 3) {
                        guard self.sessionID == id, self.onStarted != nil else { return }
                        self.failOnQueue(reason: "startup_no_microphone_frames")
                    }
                }
            } catch {
                self.diagnosticError("startup_\(startupStep)", error)
                self.failOnQueue(reason: "startup_\(startupStep)")
            }
        }
    }

    private func configureEngineOnQueue(id: UUID, reusing existingEngine: AVAudioEngine? = nil) throws {
                let engine = existingEngine ?? AVAudioEngine()
                let player = AVAudioPlayerNode()
                ingressLock.lock()
                self.engine = engine
                ingressLock.unlock()
                self.player = player
                engine.attach(player)
                // Voice processing provides echo cancellation; it does not force speaker routing.
                if !engine.inputNode.isVoiceProcessingEnabled {
                    try engine.inputNode.setVoiceProcessingEnabled(true)
                }
#if DEBUG
                let arguments = ProcessInfo.processInfo.arguments
                if arguments.contains("--audio-self-test"), arguments.contains("--audio-acoustic-self-test") {
                    // AEC would deliberately remove our own tone from the microphone. Only this
                    // isolated, local-only fixture bypasses processing to check acoustic output.
                    engine.inputNode.isVoiceProcessingBypassed = true
                    self.diagnostic("local_acoustic_probe processing_bypassed=\(engine.inputNode.isVoiceProcessingBypassed) network_used=false")
                }
#endif
                let captureFormat = engine.inputNode.outputFormat(forBus: 0)
                let hardwareOutput = engine.outputNode.outputFormat(forBus: 0)
                let hardwareRate = hardwareOutput.sampleRate
                self.diagnostic("formats capture_rate=\(captureFormat.sampleRate) capture_channels=\(captureFormat.channelCount) hardware_rate=\(hardwareRate) hardware_channels=\(hardwareOutput.channelCount)")
                guard captureFormat.sampleRate > 0, captureFormat.channelCount > 0,
                      hardwareRate > 0, hardwareOutput.channelCount > 0,
                      let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: captureFormat.sampleRate, channels: 1),
                      let captureConverter = AVAudioConverter(from: captureFormat, to: self.wireFormat),
                      let playbackConverter = AVAudioConverter(from: self.wireFormat, to: playbackFormat) else {
                    throw BridgeProtocolError.audioUnavailable
                }
                self.captureConverter = captureConverter
                self.playbackConverter = playbackConverter
                self.outputFormat = playbackFormat
                self.reportedNonzeroPlayback = false
                self.statistics = AudioStatistics(hardwareSampleRate: hardwareRate)
                self.lastStatistics = ProcessInfo.processInfo.systemUptime
                engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
                // VoiceProcessingIO requires matching input-node output and output-node input
                // formats. Pin this connection on every startup/rebuild instead of allowing
                // the mixer to renegotiate to 44.1 kHz while microphone capture remains 48 kHz.
                engine.connect(engine.mainMixerNode, to: engine.outputNode, format: captureFormat)
                let outputInput = engine.outputNode.inputFormat(forBus: 0)
                guard outputInput == captureFormat else { throw BridgeProtocolError.audioUnavailable }
                self.diagnostic("output_graph rate=\(outputInput.sampleRate) channels=\(outputInput.channelCount) voice_processing=\(engine.outputNode.isVoiceProcessingEnabled) format_matches_capture=true")
                // Observe the actual post-mixer render path, not just scheduled/converted buffers.
                // Reduce samples immediately to numeric metadata; never retain or log PCM.
                engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self, weak engine] buffer, _ in
                    guard let self, let engine, let channels = buffer.floatChannelData,
                          buffer.frameLength > 0 else { return }
                    var power = 0.0
                    var nonzeroSamples: UInt64 = 0
                    for channel in 0..<Int(buffer.format.channelCount) {
                        for frame in 0..<Int(buffer.frameLength) {
                            let value = Double(channels[channel][frame])
                            power += value * value
                            if channel == 0, abs(value) > 0.0001 { nonzeroSamples += 1 }
                        }
                    }
                    let level = sqrt(power / Double(buffer.frameLength) / Double(buffer.format.channelCount))
                    self.ingressLock.lock()
                    if self.accepting, self.engine === engine {
                        self.renderedBuffers += 1
                        self.nonzeroRenderedSamples += nonzeroSamples
                        if level > 0.0001 {
                            self.nonzeroRenderedBuffers += 1
                            if self.firstNonzeroRenderTime == 0 {
                                self.firstNonzeroRenderTime = ProcessInfo.processInfo.systemUptime
                                let delay = self.firstNonzeroRenderTime - self.startTime
                                self.queue.async {
                                    guard self.sessionID == id else { return }
                                    self.diagnostic("first_nonzero_render delay=\(delay) rms=\(level)")
                                }
                            }
                        }
                        self.renderedLevel = level
                    }
                    self.ingressLock.unlock()
                }
                self.mixerTapInstalled = true
                self.ingressLock.lock()
                self.accepting = true
                let generation = self.ingressGeneration
                self.ingressLock.unlock()
                let tapFrames = AVAudioFrameCount(max(256, Int(captureFormat.sampleRate * 0.02)))
                engine.inputNode.installTap(onBus: 0, bufferSize: tapFrames, format: captureFormat) { [weak self, weak engine] buffer, _ in
                    guard let engine else { return }
                    self?.capture(buffer, engine: engine, generation: generation)
                }
                self.tapInstalled = true
                self.observeAudioChanges(id: id, engine: engine, generation: generation)
                engine.prepare()
                try engine.start()
                player.play()
                self.diagnostic("engine_started running=\(engine.isRunning) player=\(player.isPlaying)")
                let session = AVAudioSession.sharedInstance()
                self.diagnostic("output ports=\(session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")) system_volume=\(session.outputVolume) player_volume=\(player.volume) mixer_volume=\(engine.mainMixerNode.outputVolume) session_rate=\(session.sampleRate)")
                onStatistics?(id, self.statistics)
                if !engine.isRunning {
                    if startupDeadline != nil { scheduleStartupRebuild(id: id, reason: "engine_not_running") }
                    else { failOnQueue(reason: "engine_not_running") }
                }
    }

    func stop() { queue.async { self.stopOnQueue() } }

    func enqueueDownlink(id: UUID, pcm: Data) {
        guard pcm.count == PJZCallProtocol.pcmBytes else { return }
        ingressLock.lock()
        guard accepting else { ingressLock.unlock(); return }
        if downlinkPackets.count == 10 {
            downlinkPackets.removeFirst()
            ingressPlaybackDrops += 1
        }
        downlinkPackets.append(pcm)
        let needsDrain = !playbackDrainScheduled
        playbackDrainScheduled = true
        ingressLock.unlock()
        if needsDrain { queue.async { self.drainPlayback(id: id) } }
    }

    private func capture(_ source: AVAudioPCMBuffer, engine sourceEngine: AVAudioEngine, generation: UInt64) {
        ingressLock.lock()
        let canCapture = accepting && engine === sourceEngine && ingressGeneration == generation
        ingressLock.unlock()
        guard canCapture, let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else { return }
        copy.frameLength = source.frameLength
        let sourceList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: source.audioBufferList))
        let copyList = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard sourceList.count == copyList.count else { return }
        for index in 0..<sourceList.count {
            guard let from = sourceList[index].mData, let to = copyList[index].mData else { return }
            let count = Int(sourceList[index].mDataByteSize)
            guard count <= Int(copyList[index].mDataByteSize) else { return }
            memcpy(to, from, count)
        }
        ingressLock.lock()
        guard accepting, engine === sourceEngine, ingressGeneration == generation else { ingressLock.unlock(); return }
        if inputBuffers.count == 5 {
            inputBuffers.removeFirst()
            ingressCaptureDrops += 1
        }
        inputBuffers.append(copy)
        let needsDrain = !inputDrainScheduled
        inputDrainScheduled = true
        ingressLock.unlock()
        if needsDrain { queue.async { self.drainCapture() } }
    }

    private func drainCapture() {
        while true {
            ingressLock.lock()
            guard accepting, !inputBuffers.isEmpty else {
                inputDrainScheduled = false
                ingressLock.unlock()
                return
            }
            let input = inputBuffers.removeFirst()
            let dropped = ingressCaptureDrops
            ingressCaptureDrops = 0
            ingressLock.unlock()
            statistics.droppedCapture += dropped
            guard let converter = captureConverter, let id = sessionID else { return }
            captureBuffers += 1
            if captureBuffers == 1 {
                diagnostic("first_capture frames=\(input.frameLength) rate=\(input.format.sampleRate) channels=\(input.format.channelCount)")
            }
            do {
                let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 16000 / input.format.sampleRate) + 64)
                let converted = try convert(input, using: converter, to: wireFormat, capacity: capacity)
                guard let values = converted.floatChannelData?[0] else { throw BridgeProtocolError.audioUnavailable }
                var peak: Float = 0
                for index in 0..<Int(converted.frameLength) {
                    let value = values[index]
                    guard value.isFinite else { throw BridgeProtocolError.audioUnavailable }
                    peak = max(peak, abs(value))
                }
                let gain = MicrophonePCM.gain(forPeak: peak)
                for index in 0..<Int(converted.frameLength) {
                    micSamples.append(MicrophonePCM.encode(values[index], gain: gain))
                }
                while micSamples.count >= PJZCallProtocol.frameSamples {
                    var packet = Data(capacity: PJZCallProtocol.pcmBytes)
                    for sample in micSamples.prefix(PJZCallProtocol.frameSamples) {
                        let bits = UInt16(bitPattern: sample)
                        packet.append(UInt8(bits & 0xff))
                        packet.append(UInt8(bits >> 8))
                    }
                    micSamples.removeFirst(PJZCallProtocol.frameSamples)
                    microphonePackets += 1
                    if microphonePackets == 1 {
                        diagnostic("first_microphone_packet applied_gain=\(gain) target_gain=\(MicrophonePCM.targetGain) peak_ceiling=\(MicrophonePCM.peakCeiling)")
                    }
                    onMicrophone?(id, microphoneMuted ? Data(count: packet.count) : packet)
                    if let started = onStarted, engine?.isRunning == true {
                        onStarted = nil
                        diagnostic("audio_ready microphone_verified=true")
                        started(id, true)
                    }
                }
                publishStatistics(id: id)
            } catch { failOnQueue(reason: "capture_conversion", error: error); return }
        }
    }

    private func drainPlayback(id: UUID) {
        while true {
            ingressLock.lock()
            guard accepting, !downlinkPackets.isEmpty else {
                playbackDrainScheduled = false
                ingressLock.unlock()
                return
            }
            let packet = downlinkPackets.removeFirst()
            let dropped = ingressPlaybackDrops
            ingressPlaybackDrops = 0
            ingressLock.unlock()
            guard sessionID == id, let converter = playbackConverter,
                  let format = outputFormat, let player else { return }
            statistics.droppedPlayback += dropped
            playbackPackets += 1
            if playbackPackets == 1 { diagnostic("first_playback_packet") }
            do {
                guard let input = AVAudioPCMBuffer(pcmFormat: wireFormat, frameCapacity: 320),
                      let samples = input.floatChannelData?[0] else { throw BridgeProtocolError.audioUnavailable }
                input.frameLength = 320
                let bytes = [UInt8](packet)
                for index in 0..<320 {
                    let sample = Int16(bitPattern: UInt16(bytes[index * 2]) | UInt16(bytes[index * 2 + 1]) << 8)
                    samples[index] = Float(sample) / 32768.0
                }
                if scheduledPlayback >= 10 {
                    // AVAudioPlayerNode cannot selectively remove queued buffers. Drop the old backlog
                    // in one bounded reset and resume with the newest available packet.
                    statistics.droppedPlayback += UInt64(scheduledPlayback)
                    playbackGeneration += 1
                    player.stop()
                    scheduledPlayback = 0
                    converter.reset()
                    player.play()
                }
                let capacity = AVAudioFrameCount(ceil(320 * format.sampleRate / 16000) + 64)
                let converted = try convert(input, using: converter, to: format, capacity: capacity)
                if converted.frameLength == 0 { continue } // Converter priming can initially produce no frames.
                if !reportedNonzeroPlayback, PJZCallProtocol.pcmLevel(packet) > 0,
                   let values = converted.floatChannelData?[0] {
                    var sum = 0.0
                    for index in 0..<Int(converted.frameLength) { sum += Double(values[index]) * Double(values[index]) }
                    diagnostic("first_nonzero_playback wire_rms=\(PJZCallProtocol.pcmLevel(packet)) converted_rms=\(sqrt(sum / Double(converted.frameLength))) frames=\(converted.frameLength) engine_running=\(engine?.isRunning ?? false) startup_ready=\(onStarted == nil)")
                    reportedNonzeroPlayback = true
                }
                let generation = playbackGeneration
                scheduledPlayback += 1
                player.scheduleBuffer(converted, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    guard let self else { return }
                    self.queue.async {
                        guard self.sessionID == id, self.playbackGeneration == generation else { return }
                        self.scheduledPlayback = max(0, self.scheduledPlayback - 1)
                        self.statistics.playedBuffers += 1
                    }
                }
                publishStatistics(id: id)
            } catch { failOnQueue(reason: "playback_conversion", error: error); return }
        }
    }

    private func convert(_ source: AVAudioPCMBuffer, using converter: AVAudioConverter,
                         to format: AVAudioFormat, capacity: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        guard let result = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw BridgeProtocolError.audioUnavailable
        }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: result, error: &conversionError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return source
        }
        if let conversionError { throw conversionError }
        guard status != .error, status != .endOfStream else {
            diagnostic("converter_failed status=\(status.rawValue) source_rate=\(source.format.sampleRate) target_rate=\(format.sampleRate)")
            throw BridgeProtocolError.audioUnavailable
        }
        return result
    }

    private func observeAudioChanges(id: UUID, engine observedEngine: AVAudioEngine, generation: UInt64) {
        let names = [AVAudioSession.routeChangeNotification, AVAudioSession.interruptionNotification,
                     AVAudioSession.mediaServicesWereResetNotification, .AVAudioEngineConfigurationChange]
        for name in names {
            let object: AnyObject? = name == .AVAudioEngineConfigurationChange ? observedEngine : nil
            let observer = NotificationCenter.default.addObserver(forName: name, object: object, queue: nil) { [weak self, weak observedEngine] notification in
                guard let self else { return }
                let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue ?? 0
                let interruption = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue ?? 0
                self.queue.async {
                    guard self.sessionID == id, self.ingressGeneration == generation,
                          let observedEngine, self.engine === observedEngine else { return }
                    self.diagnostic("audio_notification name=\(name.rawValue) route_reason=\(reason) interruption_type=\(interruption) engine_running=\(self.engine?.isRunning ?? false)")
                    if name == .AVAudioEngineConfigurationChange, self.onStarted != nil {
                        self.scheduleStartupRebuild(id: id, reason: "initial_configuration_change")
                        return
                    }
                    if name == AVAudioSession.routeChangeNotification,
                       self.startupDeadline.map({ ProcessInfo.processInfo.systemUptime < $0 }) ?? true,
                       self.routeSignature() == self.startupRoute,
                       reason == AVAudioSession.RouteChangeReason.categoryChange.rawValue
                        || reason == AVAudioSession.RouteChangeReason.override.rawValue
                        || reason == AVAudioSession.RouteChangeReason.routeConfigurationChange.rawValue {
                        // Known setup notifications can arrive asynchronously after readiness.
                        // An unchanged physical route is harmless; actual route changes still stop.
                        // Only synthetic tests retain their finite startup window.
                        self.diagnostic("startup_same_route_notification")
                        return
                    }
                    self.failOnQueue(reason: "audio_notification_\(name.rawValue)")
                }
            }
            observers.append(observer)
        }
    }

    private func routeSignature() -> [String] {
        let route = AVAudioSession.sharedInstance().currentRoute
        return route.inputs.map { "in:\($0.portType.rawValue):\($0.uid)" }
            + route.outputs.map { "out:\($0.portType.rawValue):\($0.uid)" }
    }

    private func scheduleStartupRebuild(id: UUID, reason: String) {
        guard onStarted != nil, routeSignature() == startupRoute,
              startupDeadline.map({ ProcessInfo.processInfo.systemUptime < $0 && startupRebuilds < 2 }) ?? true else {
            failOnQueue(reason: "startup_configuration_unstable")
            return
        }
        guard !startupRebuildPending else { return }
        startupRebuildPending = true
        diagnostic("startup_rebuild_scheduled reason=\(reason) attempt=\(startupRebuilds + 1)")
        // Yield to the hardware's asynchronous configuration notification; never block the
        // real-time tap, and never extend this session or reconnect its authenticated socket.
        queue.asyncAfter(deadline: .now() + 0.15) {
            guard self.sessionID == id, self.onStarted != nil else { return }
            self.startupRebuildPending = false
            guard self.routeSignature() == self.startupRoute,
                  self.startupDeadline.map({ ProcessInfo.processInfo.systemUptime < $0 }) ?? true else {
                self.failOnQueue(reason: "startup_route_changed")
                return
            }
            self.startupRebuilds += 1
            let settledEngine = self.engine
            self.releaseEngineOnQueue()
            // Keep the voice-processing IO unit that has just settled. Creating another one
            // would request the same hardware transition again and reproduce the startup race.
            do { try self.configureEngineOnQueue(id: id, reusing: settledEngine) }
            catch { self.failOnQueue(reason: "startup_rebuild", error: error) }
        }
    }

    private func publishStatistics(id: UUID) {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastStatistics >= 1 {
            lastStatistics = now
            statistics.capturedBuffers = captureBuffers
            statistics.microphonePackets = microphonePackets
            ingressLock.lock()
            statistics.renderedBuffers = renderedBuffers
            statistics.nonzeroRenderedBuffers = nonzeroRenderedBuffers
            statistics.renderedLevel = renderedLevel
            statistics.firstNonzeroRenderDelay = firstNonzeroRenderTime == 0 ? -1 : firstNonzeroRenderTime - startTime
            statistics.firstNonzeroRenderTime = firstNonzeroRenderTime
            statistics.nonzeroRenderedSamples = nonzeroRenderedSamples
            ingressLock.unlock()
            onStatistics?(id, statistics)
        }
    }

    private func failOnQueue(reason: String, error: Error? = nil) {
        guard sessionID != nil else { return }
        let id = sessionID
        let failure = onFailure
        if let error { diagnosticError(reason, error) }
        else { diagnostic("failure reason=\(reason)") }
        stopOnQueue()
        if let id { failure?(id, reason) }
    }

    private func stopOnQueue() {
        if sessionID != nil {
            ingressLock.lock()
            let rendered = renderedBuffers
            let nonzero = nonzeroRenderedBuffers
            ingressLock.unlock()
            diagnostic("audio_summary capture_buffers=\(captureBuffers) microphone_packets=\(microphonePackets) playback_packets=\(playbackPackets) rendered_buffers=\(rendered) rendered_nonzero=\(nonzero)")
        }
        releaseEngineOnQueue()
        captureBuffers = 0
        microphonePackets = 0
        playbackPackets = 0
        sessionID = nil
        onMicrophone = nil
        onStatistics = nil
        onFailure = nil
        onStarted = nil
        startupDeadline = nil
        startupRebuilds = 0
        startupRebuildPending = false
        startupRoute = []
        if speakerOverrideActive {
            try? AVAudioSession.sharedInstance().overrideOutputAudioPort(.none)
            speakerOverrideActive = false
        }
        if ownsSessionActivation {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            ownsSessionActivation = false
        }
        microphoneMuted = false
        diagnostic("audio_released engine_present=false player_present=false taps_installed=false")
    }

    private func releaseEngineOnQueue() {
        ingressLock.lock()
        accepting = false
        ingressGeneration += 1
        inputBuffers.removeAll(keepingCapacity: false)
        downlinkPackets.removeAll(keepingCapacity: false)
        inputDrainScheduled = false
        playbackDrainScheduled = false
        ingressCaptureDrops = 0
        ingressPlaybackDrops = 0
        ingressLock.unlock()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        if let engine {
            if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
            if mixerTapInstalled { engine.mainMixerNode.removeTap(onBus: 0) }
            player?.stop()
            engine.stop()
            engine.reset()
            if let player { engine.detach(player) }
        }
        tapInstalled = false
        mixerTapInstalled = false
        ingressLock.lock()
        engine = nil
        ingressLock.unlock()
        player = nil
        captureConverter = nil
        playbackConverter = nil
        outputFormat = nil
        micSamples.removeAll(keepingCapacity: false)
        playbackGeneration += 1
        scheduledPlayback = 0
        ingressLock.lock()
        renderedBuffers = 0
        nonzeroRenderedBuffers = 0
        renderedLevel = 0
        firstNonzeroRenderTime = 0
        nonzeroRenderedSamples = 0
        ingressLock.unlock()
    }

    private func diagnosticError(_ reason: String, _ error: Error) {
        let value = error as NSError
        // Only error domain/code, not userInfo, descriptions, PCM, route IDs or device names.
        diagnostic("failure reason=\(reason) error_domain=\(value.domain) error_code=\(value.code)")
    }

    private func diagnostic(_ metadata: String) {
#if DEBUG
        print("PJZ_CALL_AUDIO uptime=\(ProcessInfo.processInfo.systemUptime) \(metadata)")
        fflush(stdout)
#endif
    }
}
