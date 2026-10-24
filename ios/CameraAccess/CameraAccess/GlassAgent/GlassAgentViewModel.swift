//
// GlassAgentViewModel.swift
//
// The job flow: pick customer -> start job -> ask (glasses photo + voice) -> wrap up.
// One tap runs the whole ask loop: capture photo, listen, send, speak the answer.
// Saying "wrap it up ..." routes straight to wrap-up.
//

import Foundation
import Observation

struct Exchange: Identifiable {
  let id = UUID()
  let question: String
  let response: AskResponse
  let hadPhoto: Bool
}

@Observable
@MainActor
final class GlassAgentViewModel {
  enum Phase: Equatable {
    case idle, capturing, listening, thinking, speaking, wrappingUp
  }

  // Settings
  var backendURL: String {
    didSet { UserDefaults.standard.set(backendURL, forKey: "backendURL") }
  }

  // Data
  var customers: [Customer] = []
  var isLoadingCustomers = false
  var job: Job?
  var customer: Customer?
  var exchanges: [Exchange] = []
  var recommendedParts: [Part] = []
  var report: WrapUpResponse?

  // Live UI state
  var phase: Phase = .idle
  var liveTranscript = ""
  var typedQuestion = ""
  var wrapUpText = ""
  var errorMessage = ""
  var showError = false

  @ObservationIgnored private let listener = SpeechListener()
  @ObservationIgnored private let speaker = Speaker()

  init() {
    backendURL = UserDefaults.standard.string(forKey: "backendURL") ?? ""
    listener.onPartial = { [weak self] text in self?.liveTranscript = text }
  }

  private var api: GlassAgentAPI { GlassAgentAPI(baseURL: backendURL) }
  var isBusy: Bool { phase != .idle }
  /// Waiting on capture or the server: the main button can't do anything useful.
  var isWorking: Bool { phase == .capturing || phase == .thinking || phase == .wrappingUp }

  // MARK: - Customers & jobs

  func loadCustomers() async {
    isLoadingCustomers = true
    defer { isLoadingCustomers = false }
    do {
      customers = try await api.customers()
    } catch {
      present(error)
    }
  }

  func startJob(for customer: Customer) async {
    do {
      let res = try await api.startJob(customerId: customer.id)
      job = res.job
      self.customer = customers.first { $0.id == customer.id } ?? res.customer
      exchanges = []
      recommendedParts = []
      wrapUpText = ""
      report = nil
    } catch {
      present(error)
    }
  }

  func newJob() {
    speaker.stop()
    listener.stop()
    job = nil
    customer = nil
    report = nil
    exchanges = []
    phase = .idle
  }

  // MARK: - Ask

  /// The main button. Idle: capture + listen + ask + speak. Listening: send now. Speaking: stop talking.
  func tapAsk(camera: CameraViewModel) {
    switch phase {
    case .idle:
      Task { await askHandsFree(camera: camera) }
    case .listening:
      listener.stop()
    case .speaking:
      speaker.stop()
    case .capturing, .thinking, .wrappingUp:
      break
    }
  }

  private func askHandsFree(camera: CameraViewModel) async {
    guard job != nil else { return }
    liveTranscript = ""

    // Grab the photo the moment the tech taps (they're looking at the machine), while listening.
    phase = .listening
    async let photo = camera.captureJPEG()

    let question: String
    do {
      question = try await listener.listen()
    } catch {
      _ = await photo
      phase = .idle
      present(error)
      return
    }

    if let wrapText = Self.wrapUpCommand(in: question) {
      _ = await photo
      await wrapUp(text: wrapText)
      return
    }

    let jpeg = await photo
    if question.isEmpty && jpeg == nil {
      phase = .speaking
      await speaker.speak("I didn't catch that. Tap and ask again.")
      phase = .idle
      return
    }
    await send(question: question, rawPhoto: jpeg)
  }

  func askTyped(camera: CameraViewModel) {
    let question = typedQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !isBusy, job != nil, !question.isEmpty else { return }
    typedQuestion = ""
    Task {
      if let wrapText = Self.wrapUpCommand(in: question) {
        await wrapUp(text: wrapText)
        return
      }
      phase = .capturing
      let jpeg = await camera.captureJPEG()
      await send(question: question, rawPhoto: jpeg)
    }
  }

  private func send(question: String, rawPhoto: Data?) async {
    guard let job else { return }
    phase = .thinking
    let jpeg = rawPhoto.flatMap(PhotoCompressor.prepare)
    do {
      let res = try await api.ask(jobId: job.id, question: question, jpeg: jpeg)
      exchanges.insert(Exchange(question: question, response: res, hadPhoto: jpeg != nil), at: 0)
      if !res.recommendedParts.isEmpty {
        recommendedParts = res.recommendedParts
        if wrapUpText.isEmpty {
          wrapUpText = res.recommendedParts.map { Self.spokenName($0.name) }.joined(separator: ", ") + ", half an hour of labor"
        }
      }
      phase = .speaking
      await speaker.speak(res.answer)
    } catch {
      phase = .speaking
      await speaker.speak("I couldn't reach the server. \(error.localizedDescription)")
    }
    phase = .idle
  }

  // MARK: - Wrap up

  func wrapUpTapped() {
    guard !isBusy else { return }
    Task { await wrapUp(text: wrapUpText) }
  }

  private func wrapUp(text: String) async {
    guard let job else { return }
    phase = .wrappingUp
    do {
      let res = try await api.wrapUp(jobId: job.id, text: text)
      report = res
      self.job = Job(id: job.id, customerId: job.customerId, status: "completed", notes: job.notes)
      phase = .speaking
      await speaker.speak(res.spoken)
    } catch {
      phase = .speaking
      await speaker.speak("Wrap-up failed. \(error.localizedDescription)")
    }
    phase = .idle
  }

  // MARK: - Helpers

  /// "Wrap it up: descaling kit, new filter, half an hour" -> "descaling kit, new filter, half an hour"
  static func wrapUpCommand(in text: String) -> String? {
    let lower = text.lowercased()
    for trigger in ["wrap it up", "wrap this up", "wrap up"] {
      if let range = lower.range(of: trigger), lower.distance(from: lower.startIndex, to: range.lowerBound) < 12 {
        let rest = text[range.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;-").union(.whitespaces))
        return rest
      }
    }
    return nil
  }

  static func spokenName(_ name: String) -> String {
    name.replacingOccurrences(of: #"\s*\(.*?\)"#, with: "", options: .regularExpression)
  }

  private func present(_ error: Error) {
    errorMessage = error.localizedDescription
    showError = true
  }
}
