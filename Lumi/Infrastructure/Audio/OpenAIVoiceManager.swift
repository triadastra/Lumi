import Combine
import Foundation
@preconcurrency import AVFoundation

@MainActor
final class OpenAIVoiceManager: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var isProcessing = false
    @Published var lastError: String?

#if os(macOS)
    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var recordingURL: URL?
    private var audioEngine: AVAudioEngine?
    private var realtimeSocket: URLSessionWebSocketTask?

    func startRecording() async throws {
        guard !isRecording else { return }
        guard try await requestMicrophoneAccessIfNeeded() else {
            throw VoiceError.microphonePermissionDenied
        }

        let temp = FileManager.default.temporaryDirectory
        let url = temp.appendingPathComponent("lumi_voice_\(UUID().uuidString).m4a")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder?.isMeteringEnabled = true
        guard recorder?.record() == true else {
            throw VoiceError.recordingFailed
        }

        recordingURL = url
        isRecording = true
        lastError = nil
    }

    func stopRecordingAndTranscribe() async throws -> String {
        guard isRecording else { return "" }
        recorder?.stop()
        recorder = nil
        isRecording = false

        guard let url = recordingURL else {
            throw VoiceError.recordingNotFound
        }

        isProcessing = true
        defer { isProcessing = false }

        do {
            let text = try await transcribeAudio(at: url)
            try? FileManager.default.removeItem(at: url)
            recordingURL = nil
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    /// One-tap voice capture: start recording, auto-stop on silence or max duration,
    /// then transcribe and return text.
    func recordAndTranscribeAutomatically(
        maxDuration: TimeInterval = 18.0,
        silenceThresholdDB: Float = -42.0,
        silenceDuration: TimeInterval = 1.2,
        minimumSpeechDuration: TimeInterval = 0.8
    ) async throws -> String {
        do {
            // Preferred path: realtime streaming transcription with OpenAI server VAD.
            return try await transcribeWithRealtimeVAD(maxDuration: maxDuration)
        } catch {
            // Fallback path: local recording + local silence detector + upload.
            try await startRecording()
            try await waitForAutoStop(
                maxDuration: maxDuration,
                silenceThresholdDB: silenceThresholdDB,
                silenceDuration: silenceDuration,
                minimumSpeechDuration: minimumSpeechDuration
            )
            return try await stopRecordingAndTranscribe()
        }
    }

    func speak(text: String) async throws {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }

        isProcessing = true
        defer { isProcessing = false }

        do {
            let audioData = try await synthesizeSpeech(from: content)
            player?.stop()
            player = try AVAudioPlayer(data: audioData)
            player?.prepareToPlay()
            player?.play()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    private func requestMicrophoneAccessIfNeeded() async throws -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func transcribeAudio(at fileURL: URL) async throws -> String {
        let apiKey = try openAIKey()
        let boundary = "Boundary-\(UUID().uuidString)"
        guard let url = URL(string: "https://api.openai.com/v1/audio/transcriptions") else {
            throw VoiceError.invalidRequest
        }

        let fileData = try Data(contentsOf: fileURL)
        var body = Data()
        appendField("model", value: "whisper-1", to: &body, boundary: boundary)
        appendField("response_format", value: "json", to: &body, boundary: boundary)
        appendFile("file", filename: "voice.m4a", mimeType: "audio/m4a", data: fileData, to: &body, boundary: boundary)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        try checkHTTP(response: response, data: data)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else {
            throw VoiceError.invalidResponse
        }
        return text
    }

    private func synthesizeSpeech(from text: String) async throws -> Data {
        let apiKey = try openAIKey()
        guard let url = URL(string: "https://api.openai.com/v1/audio/speech") else {
            throw VoiceError.invalidRequest
        }

        let payload: [String: Any] = [
            "model": "gpt-4o-mini-tts",
            "voice": "alloy",
            "format": "mp3",
            "input": String(text.prefix(3500))
        ]

        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        try checkHTTP(response: response, data: data)
        return data
    }

    private func openAIKey() throws -> String {
        let repo = AIProviderRepository()
        guard let key = try repo.getAPIKey(for: .openai), !key.isEmpty else {
            throw VoiceError.missingOpenAIKey
        }
        return key
    }

    private func appendField(_ name: String, value: String, to body: inout Data, boundary: String) {
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(value)\r\n".data(using: .utf8)!)
    }

    private func appendFile(
        _ name: String,
        filename: String,
        mimeType: String,
        data: Data,
        to body: inout Data,
        boundary: String
    ) {
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n".data(using: .utf8)!)
    }

    private func checkHTTP(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw VoiceError.network
        }
        guard (200..<300).contains(http.statusCode) else {
            let payload = String(data: data, encoding: .utf8) ?? "unknown error"
            throw VoiceError.apiError("HTTP \(http.statusCode): \(payload)")
        }
    }

    private func waitForAutoStop(
        maxDuration: TimeInterval,
        silenceThresholdDB: Float,
        silenceDuration: TimeInterval,
        minimumSpeechDuration: TimeInterval
    ) async throws {
        guard let recorder else { throw VoiceError.recordingFailed }

        let start = Date()
        var silenceStart: Date?

        while isRecording {
            try await Task.sleep(nanoseconds: 150_000_000)
            recorder.updateMeters()
            let level = recorder.averagePower(forChannel: 0)
            let elapsed = Date().timeIntervalSince(start)

            if elapsed >= maxDuration {
                break
            }

            if elapsed < minimumSpeechDuration {
                continue
            }

            if level < silenceThresholdDB {
                if silenceStart == nil {
                    silenceStart = Date()
                } else if Date().timeIntervalSince(silenceStart!) >= silenceDuration {
                    break
                }
            } else {
                silenceStart = nil
            }
        }
    }

    private func transcribeWithRealtimeVAD(maxDuration: TimeInterval) async throws -> String {
        guard try await requestMicrophoneAccessIfNeeded() else {
            throw VoiceError.microphonePermissionDenied
        }

        isProcessing = true
        isRecording = true
        lastError = nil
        defer {
            isRecording = false
            isProcessing = false
        }

        let apiKey = try openAIKey()
        guard let url = URL(string: "wss://api.openai.com/v1/realtime?model=gpt-realtime") else {
            throw VoiceError.invalidRequest
        }

        var req = URLRequest(url: url, timeoutInterval: 120)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")

        let socket = URLSession.shared.webSocketTask(with: req)
        realtimeSocket = socket
        socket.resume()

        let engine = AVAudioEngine()
        audioEngine = engine
        let inputFormat = engine.inputNode.inputFormat(forBus: 0)
        guard let pcm24kMono = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: inputFormat, to: pcm24kMono) else {
            throw VoiceError.recordingFailed
        }

        try await sendRealtimeEvent([
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": 24000
                        ],
                        "transcription": [
                            "model": "gpt-4o-mini-transcribe"
                        ],
                        "turn_detection": [
                            "type": "server_vad",
                            "threshold": 0.5,
                            "prefix_padding_ms": 300,
                            "silence_duration_ms": 500
                        ]
                    ]
                ]
            ]
        ], on: socket)

        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            guard let outBuffer = self.convertBuffer(buffer, with: converter, to: pcm24kMono),
                  let pcmData = self.pcm16Data(from: outBuffer) else { return }
            Task {
                do {
                    try await self.sendRealtimeEvent([
                        "type": "input_audio_buffer.append",
                        "audio": pcmData.base64EncodedString()
                    ], on: socket)
                } catch {
                    self.lastError = error.localizedDescription
                }
            }
        }

        engine.prepare()
        try engine.start()

        var deltaTranscript = ""
        let timeoutDate = Date().addingTimeInterval(maxDuration + 10)

        do {
            while Date() < timeoutDate {
                let msg = try await socket.receive()
                guard case .string(let text) = msg,
                      let data = text.data(using: .utf8),
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let type = json["type"] as? String else { continue }

                if type == "conversation.item.input_audio_transcription.delta",
                   let delta = json["delta"] as? String {
                    deltaTranscript += delta
                }

                if type == "conversation.item.input_audio_transcription.completed",
                   let transcript = json["transcript"] as? String {
                    stopRealtimeCapture()
                    return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                }

                if type == "error",
                   let err = json["error"] as? [String: Any],
                   let msg = err["message"] as? String {
                    throw VoiceError.apiError(msg)
                }
            }
        } catch {
            stopRealtimeCapture()
            throw error
        }

        stopRealtimeCapture()
        let cleaned = deltaTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw VoiceError.invalidResponse }
        return cleaned
    }

    private func stopRealtimeCapture() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        realtimeSocket?.cancel(with: .normalClosure, reason: nil)
        realtimeSocket = nil
    }

    private func sendRealtimeEvent(_ event: [String: Any], on socket: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: event)
        guard let text = String(data: data, encoding: .utf8) else {
            throw VoiceError.invalidRequest
        }
        try await socket.send(.string(text))
    }

    private func convertBuffer(
        _ inputBuffer: AVAudioPCMBuffer,
        with converter: AVAudioConverter,
        to outputFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = outputFormat.sampleRate / inputBuffer.format.sampleRate
        let outFrames = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 32
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outFrames) else {
            return nil
        }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            } else {
                consumed = true
                outStatus.pointee = .haveData
                return inputBuffer
            }
        }

        guard status != .error, error == nil else { return nil }
        return outputBuffer
    }

    private func pcm16Data(from buffer: AVAudioPCMBuffer) -> Data? {
        guard let channelData = buffer.int16ChannelData else { return nil }
        let channels = Int(buffer.format.channelCount)
        let samples = Int(buffer.frameLength) * channels
        return Data(bytes: channelData.pointee, count: samples * MemoryLayout<Int16>.size)
    }
#else
    // iOS Stubs to allow compilation of shared state
    func startRecording() async throws { }
    func stopRecordingAndTranscribe() async throws -> String { "" }
    func recordAndTranscribeAutomatically() async throws -> String { "" }
    func speak(text: String) async throws { }
#endif
}

enum VoiceError: LocalizedError {
    case missingOpenAIKey
    case microphonePermissionDenied
    case recordingFailed
    case recordingNotFound
    case invalidRequest
    case invalidResponse
    case network
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .missingOpenAIKey:
            return "OpenAI API key not found. Add it in Settings -> API Keys."
        case .microphonePermissionDenied:
            return "Microphone permission denied. Enable Lumi Agent in System Settings -> Privacy & Security -> Microphone."
        case .recordingFailed:
            return "Failed to start recording."
        case .recordingNotFound:
            return "Recorded audio file not found."
        case .invalidRequest:
            return "Failed to build voice API request."
        case .invalidResponse:
            return "Voice API returned an invalid response."
        case .network:
            return "Voice network request failed."
        case .apiError(let details):
            return details
        }
    }
}
