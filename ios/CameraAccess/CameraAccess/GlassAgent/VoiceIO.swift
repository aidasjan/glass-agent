//
// VoiceIO.swift
//
// Hands-free voice for Glass Agent:
// - SpeechListener: on-device speech recognition from the glasses mic (Bluetooth HFP),
//   ending automatically when the technician pauses.
// - Speaker: text-to-speech routed to the glasses speakers (A2DP via the .playback category).
//

import AVFoundation
import Speech

enum VoiceError: LocalizedError {
  case notAuthorized
  case recognizerUnavailable
  case noAudioInput

  var errorDescription: String? {
    switch self {
    case .notAuthorized: return "Allow microphone and speech recognition in Settings to ask by voice."
    case .recognizerUnavailable: return "Speech recognition isn't available right now. Type your question instead."
    case .noAudioInput: return "No microphone input found."
    }
  }
}

@MainActor
final class SpeechListener {
  /// Live transcript while listening.
  var onPartial: ((String) -> Void)?
  private(set) var usingGlassesMic = false

  private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
  private var engine: AVAudioEngine?
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  private var continuation: CheckedContinuation<String, Never>?
  private var transcript = ""
  private var silenceTimer: Task<Void, Never>?
  private var maxTimer: Task<Void, Never>?

  /// Pause after speech that ends the question.
  private let endOfSpeechPause: Duration = .milliseconds(1600)
  /// Give up if nothing is said at all.
  private let noSpeechTimeout: Duration = .seconds(7)

  var isListening: Bool { continuation != nil }

  static func requestAuthorization() async -> Bool {
    let speechOK = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
      SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
    }
    let micOK = await AVAudioApplication.requestRecordPermission()
    return speechOK && micOK
  }

  /// Listens until the technician pauses, `stop()` is called, or `maxDuration` passes.
  /// Returns the transcript (possibly empty).
  func listen(maxDuration: Duration = .seconds(25)) async throws -> String {
    guard await Self.requestAuthorization() else { throw VoiceError.notAuthorized }
    guard let recognizer, recognizer.isAvailable else { throw VoiceError.recognizerUnavailable }
    stop()

    try configureAudioSession()
    let engine = AVAudioEngine()
    let format = engine.inputNode.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else { throw VoiceError.noAudioInput }

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    request.taskHint = .dictation
    if recognizer.supportsOnDeviceRecognition {
      request.requiresOnDeviceRecognition = true
    }

    Self.installTap(on: engine.inputNode, format: format, request: request)
    engine.prepare()
    try engine.start()

    self.engine = engine
    self.request = request
    transcript = ""
    task = Self.startRecognition(recognizer: recognizer, request: request) { [weak self] text, isFinal, failed in
      Task { @MainActor in self?.handle(text: text, isFinal: isFinal, failed: failed) }
    }

    restartSilenceTimer(after: noSpeechTimeout)
    maxTimer = Task { [weak self] in
      try? await Task.sleep(for: maxDuration)
      guard !Task.isCancelled else { return }
      self?.stop()
    }

    return await withCheckedContinuation { continuation = $0 }
  }

  /// Ends listening now and delivers what was heard so far.
  func stop() {
    silenceTimer?.cancel()
    maxTimer?.cancel()
    if let engine {
      engine.stop()
      engine.inputNode.removeTap(onBus: 0)
    }
    request?.endAudio()
    task?.cancel()
    engine = nil
    request = nil
    task = nil
    if let continuation {
      self.continuation = nil
      continuation.resume(returning: transcript.trimmingCharacters(in: .whitespacesAndNewlines))
    }
  }

  private func handle(text: String?, isFinal: Bool, failed: Bool) {
    guard isListening else { return }
    if let text, !text.isEmpty {
      transcript = text
      onPartial?(text)
      restartSilenceTimer(after: endOfSpeechPause)
    }
    if isFinal || failed {
      stop()
    }
  }

  private func restartSilenceTimer(after delay: Duration) {
    silenceTimer?.cancel()
    silenceTimer = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled else { return }
      self?.stop()
    }
  }

  private func configureAudioSession() throws {
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP, .defaultToSpeaker])
    try session.setActive(true)
    // Prefer the glasses mic (Bluetooth HFP). Falls back to the phone mic if the glasses aren't connected.
    if let glasses = session.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) {
      try session.setPreferredInput(glasses)
      usingGlassesMic = true
    } else {
      usingGlassesMic = false
    }
  }

  // Audio and recognition callbacks run off the main thread, so build them in nonisolated
  // contexts; closures created inside @MainActor code would trap when called elsewhere.
  private nonisolated static func installTap(
    on input: AVAudioInputNode,
    format: AVAudioFormat,
    request: SFSpeechAudioBufferRecognitionRequest
  ) {
    nonisolated(unsafe) let request = request
    input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
      request.append(buffer)
    }
  }

  private nonisolated static func startRecognition(
    recognizer: SFSpeechRecognizer,
    request: SFSpeechAudioBufferRecognitionRequest,
    onUpdate: @escaping @Sendable (String?, Bool, Bool) -> Void
  ) -> SFSpeechRecognitionTask {
    recognizer.recognitionTask(with: request) { result, error in
      onUpdate(result?.bestTranscription.formattedString, result?.isFinal ?? false, error != nil)
    }
  }
}

@MainActor
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
  private let synthesizer = AVSpeechSynthesizer()
  private var current: (id: ObjectIdentifier, continuation: CheckedContinuation<Void, Never>)?

  override init() {
    super.init()
    synthesizer.delegate = self
  }

  var isSpeaking: Bool { current != nil }

  /// Speaks the text and returns when done (or when stopped).
  func speak(_ text: String) async {
    stop()
    let session = AVAudioSession.sharedInstance()
    // .playback routes to the glasses speakers over A2DP when they're connected.
    try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
    try? session.setActive(true)

    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      current = (ObjectIdentifier(utterance), continuation)
      synthesizer.speak(utterance)
    }
  }

  func stop() {
    if synthesizer.isSpeaking {
      synthesizer.stopSpeaking(at: .immediate)
    }
    finish(nil)
  }

  /// Resumes the waiting `speak` call. `id == nil` finishes whatever is current.
  private func finish(_ id: ObjectIdentifier?) {
    guard let current, id == nil || id == current.id else { return }
    self.current = nil
    current.continuation.resume()
  }

  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    let id = ObjectIdentifier(utterance)
    Task { @MainActor in self.finish(id) }
  }

  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    let id = ObjectIdentifier(utterance)
    Task { @MainActor in self.finish(id) }
  }
}
