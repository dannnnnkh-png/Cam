import AVFoundation
import Speech

/// 16 kHz 單聲道（C 核心輸出的格式）
let monoFormat16k = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

func makePCMBuffer(_ samples: UnsafePointer<Int16>, count: Int) -> (AVAudioPCMBuffer, Float)? {
    guard count > 0, let buf = AVAudioPCMBuffer(pcmFormat: monoFormat16k, frameCapacity: AVAudioFrameCount(count)),
          let ch = buf.floatChannelData?[0] else { return nil }
    var sum: Float = 0
    for i in 0..<count {
        let v = Float(samples[i]) / 32768
        ch[i] = v
        sum += v * v
    }
    buf.frameLength = AVAudioFrameCount(count)
    return (buf, (sum / Float(count)).squareRoot())
}

/// 播放攝影機聲音；值守模式時播放無聲音訊讓 App 能在背景持續運作
final class AudioOut {
    static let shared = AudioOut()
    private let engine = AVAudioEngine()
    private let voice = AVAudioPlayerNode()
    private let silence = AVAudioPlayerNode()
    private let queue = DispatchQueue(label: "homecam.audio")
    private var listeners = 0
    private var keepAlive = false
    private var pending = 0

    private init() {
        engine.attach(voice)
        engine.attach(silence)
        engine.connect(voice, to: engine.mainMixerNode, format: monoFormat16k)
        engine.connect(silence, to: engine.mainMixerNode, format: monoFormat16k)
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            self.queue.async { self.refresh(force: true) }        // 來電等中斷結束後自動恢復
        }
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.refresh(force: true) }
        }
    }

    func setListening(_ on: Bool) {
        queue.async {
            self.listeners = max(0, self.listeners + (on ? 1 : -1))
            self.refresh(force: false)
        }
    }

    func setKeepAlive(_ on: Bool) {
        queue.async {
            self.keepAlive = on
            self.refresh(force: false)
        }
    }

    private func refresh(force: Bool) {
        let need = listeners > 0 || keepAlive
        if !need {
            voice.stop(); silence.stop(); engine.stop()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            return
        }
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default, options: [.mixWithOthers])  // 不打斷你聽音樂
        try? s.setActive(true)
        if !engine.isRunning || force {
            engine.prepare()
            try? engine.start()
        }
        if !voice.isPlaying { voice.play() }
        if keepAlive {
            if !silence.isPlaying, let b = AVAudioPCMBuffer(pcmFormat: monoFormat16k, frameCapacity: 16000) {
                b.frameLength = 16000                                  // 預設全為 0 = 無聲
                silence.scheduleBuffer(b, at: nil, options: .loops)
                silence.play()
            }
        } else if silence.isPlaying {
            silence.stop()
        }
    }

    func play(_ buf: AVAudioPCMBuffer) {
        queue.async {
            guard self.listeners > 0, self.engine.isRunning else { return }
            if self.pending > 25 { return }                            // 落後太多就丟，維持低延遲
            self.pending += 1
            self.voice.scheduleBuffer(buf) { [weak self] in self?.queue.async { self?.pending -= 1 } }
        }
    }
}

/// 即時逐字稿：iPhone 內建語音辨識，預設「只在裝置上辨識」，聲音不會離開手機
final class Transcriber {
    var onText: ((String, Date) -> Void)?
    var onStatus: ((String) -> Void)?
    private let queue = DispatchQueue(label: "homecam.stt")
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-TW"))
    private var onDeviceOnly = true
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var tasks: [SFSpeechRecognitionTask] = []   // 保留到辨識完成
    private var preroll: [AVAudioPCMBuffer] = []
    private var noise: Float = 0.01
    private var silence: Double = 0
    private var speechLen: Double = 0
    private var segStart = Date()
    private(set) var speaking = false
    private var active = false

    static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
    }

    func start(onDeviceOnly: Bool) {
        queue.async {
            self.onDeviceOnly = onDeviceOnly
            guard let r = self.recognizer else { self.onStatus?("此裝置不支援中文語音辨識"); return }
            if onDeviceOnly && !r.supportsOnDeviceRecognition {
                self.onStatus?("此 iPhone 不支援離線中文辨識（可在設定允許使用 Apple 伺服器）")
                return
            }
            guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
                self.onStatus?("請在「設定 → 隱私權 → 語音辨識」允許 HomeCam")
                return
            }
            self.active = true
            self.onStatus?(onDeviceOnly ? "離線辨識中（不上傳）" : "辨識中")
        }
    }

    func stop() {
        queue.async {
            self.active = false
            self.finishSegment()
            self.preroll.removeAll()
        }
    }

    /// 由影音核心執行緒呼叫
    func feed(_ buf: AVAudioPCMBuffer, rms: Float) {
        queue.async { self.process(buf, rms: rms) }
    }

    private func process(_ buf: AVAudioPCMBuffer, rms: Float) {
        guard active else { return }
        let dur = Double(buf.frameLength) / 16000
        if !speaking && rms < noise * 3 { noise = noise * 0.97 + rms * 0.03 }   // 自適應噪音底線
        let isSpeech = rms > max(noise * 2.5, 0.008)
        if speaking {
            request?.append(buf)
            speechLen += dur
            silence = isSpeech ? 0 : silence + dur
            if silence >= 0.8 || speechLen >= 15 { finishSegment() }
        } else if isSpeech {
            beginSegment()
            for b in preroll { request?.append(b) }
            request?.append(buf)
            preroll.removeAll()
        } else {
            preroll.append(buf)
            var total = preroll.reduce(0.0) { $0 + Double($1.frameLength) / 16000 }
            while total > 0.4, !preroll.isEmpty { total -= Double(preroll.removeFirst().frameLength) / 16000 }
        }
    }

    private func beginSegment() {
        guard let r = recognizer else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = false
        req.requiresOnDeviceRecognition = onDeviceOnly
        req.taskHint = .dictation
        if #available(iOS 16.0, *) { req.addsPunctuation = true }
        request = req
        speaking = true
        silence = 0
        speechLen = 0
        segStart = Date()
        let start = segStart
        tasks.removeAll { $0.state == .completed || $0.state == .canceling }
        let t = r.recognitionTask(with: req) { [weak self] result, _ in
            guard let result, result.isFinal else { return }
            let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { self?.onText?(text, start) }
        }
        tasks.append(t)
    }

    private func finishSegment() {
        request?.endAudio()
        request = nil
        speaking = false
        silence = 0
        speechLen = 0
    }
}
