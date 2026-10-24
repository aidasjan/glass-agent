//
// GlassAgentView.swift
//
// Job screen for technicians: pick customer, start job, ask hands-free, wrap up.
// Reuses the sample's CameraViewModel for the glasses session, stream, and photo capture.
//

import MWDATCore
import SwiftUI

private let brown = Color(red: 0.48, green: 0.29, blue: 0.16)

struct GlassAgentView: View {
  @State private var camera: CameraViewModel
  @State private var vm = GlassAgentViewModel()
  @Bindable var wearablesVM: WearablesViewModel
  @State private var showSettings = false

  init(wearables: WearablesInterface, wearablesVM: WearablesViewModel) {
    self._camera = State(wrappedValue: CameraViewModel(wearables: wearables))
    self._wearablesVM = Bindable(wearablesVM)
  }

  var body: some View {
    NavigationStack {
      Group {
        if let customer = vm.customer, vm.job != nil {
          JobScreen(vm: vm, camera: camera, customer: customer)
        } else {
          CustomerPicker(vm: vm)
        }
      }
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button { showSettings = true } label: { Image(systemName: "gearshape") }
        }
      }
    }
    .tint(brown)
    .sheet(isPresented: $showSettings) {
      SettingsSheet(vm: vm, wearablesVM: wearablesVM)
    }
    .sheet(isPresented: Binding(get: { vm.report != nil }, set: { if !$0 { vm.newJob() } })) {
      if let report = vm.report { ReportSheet(response: report) { vm.newJob() } }
    }
    // Start the glasses stream as soon as the session is up, so a photo is ready when the tech asks.
    .onChange(of: camera.sessionState) { _, state in
      if state == .started && !camera.hasStream {
        Task { await camera.startStreaming() }
      }
    }
    .alert("Something went wrong", isPresented: $vm.showError) {
      Button("OK") {}
    } message: {
      Text(vm.errorMessage)
    }
    .alert("Glasses camera", isPresented: $camera.showError) {
      Button("OK") { camera.dismissError() }
    } message: {
      Text(camera.errorMessage)
    }
    .alert("Allow camera access", isPresented: $camera.showCameraPermissionRedirectConfirm) {
      Button("Continue") { Task { await camera.confirmCameraPermissionRedirect() } }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("You'll be taken to the Meta AI app to let Glass Agent use the glasses camera, then returned here.")
    }
    .task {
      if vm.backendURL.isEmpty { showSettings = true } else { await vm.loadCustomers() }
    }
  }
}

// MARK: - Customer picker

private struct CustomerPicker: View {
  var vm: GlassAgentViewModel

  var body: some View {
    List {
      Section {
        if vm.customers.isEmpty {
          if vm.isLoadingCustomers {
            ProgressView()
          } else {
            Button("Load customers") { Task { await vm.loadCustomers() } }
          }
        }
        ForEach(vm.customers) { customer in
          Button {
            Task { await vm.startJob(for: customer) }
          } label: {
            VStack(alignment: .leading, spacing: 4) {
              Text(customer.company).font(.headline).foregroundStyle(.primary)
              Text((customer.equipment ?? []).map { "\($0.make) \($0.model)" }.joined(separator: " · "))
                .font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
          }
        }
      } header: {
        Text("Start a job")
      } footer: {
        Text("Pick the customer you're visiting.")
      }
    }
    .refreshable { await vm.loadCustomers() }
    .navigationTitle("Glass Agent")
  }
}

// MARK: - Job screen

private struct JobScreen: View {
  var vm: GlassAgentViewModel
  var camera: CameraViewModel
  let customer: Customer

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        GlassesPreview(camera: camera)
        AskButton(vm: vm, camera: camera)
        TypedQuestion(vm: vm, camera: camera)
        ForEach(vm.exchanges) { ExchangeCard(exchange: $0) }
        WrapUpCard(vm: vm)
      }
      .padding(16)
    }
    .navigationTitle(customer.company)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Button("Jobs") { vm.newJob() }.disabled(vm.isBusy)
      }
    }
  }
}

private struct GlassesPreview: View {
  var camera: CameraViewModel

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 16).fill(Color.black)
      if let frame = camera.currentVideoFrame, camera.hasReceivedFirstFrame {
        Image(uiImage: frame).resizable().aspectRatio(contentMode: .fill)
          .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
          .clipShape(RoundedRectangle(cornerRadius: 16))
      } else if camera.isBusy {
        ProgressView().tint(.white)
      } else if !camera.hasActiveDevice {
        Label("Put on your glasses", systemImage: "eyeglasses").foregroundStyle(.white.opacity(0.8))
      } else if !camera.hasSession {
        Button {
          camera.startSession()
        } label: {
          Label("Connect glasses camera", systemImage: "video").padding(.horizontal, 8)
        }
        .buttonStyle(.borderedProminent)
      } else if !camera.hasStream {
        Button("Start camera") { Task { await camera.startStreaming() } }.buttonStyle(.borderedProminent)
      }
      VStack {
        HStack {
          Text(camera.isStreaming ? "● Glasses camera live" : "Glasses camera: \(camera.streamStateText)")
            .font(.caption.weight(.semibold)).foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.black.opacity(0.5), in: Capsule())
          Spacer()
        }
        Spacer()
      }
      .padding(10)
    }
    .frame(height: 220)
  }
}

private struct AskButton: View {
  var vm: GlassAgentViewModel
  var camera: CameraViewModel

  private var title: String {
    switch vm.phase {
    case .idle: return "Tap to ask"
    case .capturing: return "Taking photo…"
    case .listening: return "Listening… tap to send"
    case .thinking: return "Thinking…"
    case .speaking: return "Speaking… tap to stop"
    case .wrappingUp: return "Logging job…"
    }
  }

  private var icon: String {
    switch vm.phase {
    case .listening: return "waveform"
    case .speaking: return "speaker.wave.2.fill"
    case .thinking, .capturing, .wrappingUp: return "ellipsis"
    case .idle: return "mic.fill"
    }
  }

  var body: some View {
    VStack(spacing: 10) {
      Button {
        vm.tapAsk(camera: camera)
      } label: {
        HStack(spacing: 12) {
          if vm.isWorking {
            ProgressView().tint(.white)
          } else {
            Image(systemName: icon).font(.title2)
          }
          Text(title).font(.title3.weight(.semibold))
        }
        .frame(maxWidth: .infinity, minHeight: 64)
        .foregroundStyle(.white)
        .background(vm.phase == .listening ? Color.red : brown, in: RoundedRectangle(cornerRadius: 16))
      }
      .disabled(vm.isWorking)

      if vm.phase == .listening || (!vm.liveTranscript.isEmpty && vm.phase == .thinking) {
        Text(vm.liveTranscript.isEmpty ? "Ask about the machine you're looking at…" : "“\(vm.liveTranscript)”")
          .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
      } else if vm.phase == .idle {
        Text(camera.isStreaming
          ? "Look at the machine, tap, and ask. Say “wrap it up …” to finish the job."
          : "No glasses camera: questions are sent without a photo.")
          .font(.footnote).foregroundStyle(.secondary)
      }
    }
  }
}

private struct TypedQuestion: View {
  @Bindable var vm: GlassAgentViewModel
  var camera: CameraViewModel

  var body: some View {
    HStack {
      TextField("Or type a question", text: $vm.typedQuestion, axis: .vertical)
        .textFieldStyle(.roundedBorder)
        .submitLabel(.send)
        .onSubmit { vm.askTyped(camera: camera) }
      Button {
        vm.askTyped(camera: camera)
      } label: {
        Image(systemName: "arrow.up.circle.fill").font(.title)
      }
      .disabled(vm.isBusy || vm.typedQuestion.trimmingCharacters(in: .whitespaces).isEmpty)
    }
  }
}

private struct ExchangeCard: View {
  let exchange: Exchange

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if !exchange.question.isEmpty {
        Text("“\(exchange.question)”").font(.subheadline).foregroundStyle(.secondary)
      }
      Text(exchange.response.answer).font(.body)
      FlowChips(items: chips)
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(brown.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
  }

  private var chips: [String] {
    var items: [String] = []
    if exchange.hadPhoto { items.append("📷 photo") }
    if let e = exchange.response.equipment { items.append("Matched: \(e.make) \(e.model)") }
    if let issue = exchange.response.suspectedIssue { items.append(issue) }
    items += exchange.response.recommendedParts.map { "\(GlassAgentViewModel.spokenName($0.name)) · \(money($0.price))" }
    return items
  }
}

private struct FlowChips: View {
  let items: [String]

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(items, id: \.self) { item in
        Text(item).font(.caption.weight(.medium))
          .padding(.horizontal, 10).padding(.vertical, 4)
          .background(Color(.secondarySystemBackground), in: Capsule())
      }
    }
  }
}

private struct WrapUpCard: View {
  @Bindable var vm: GlassAgentViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Wrap up").font(.headline)
      TextField("Descaling kit, new water filter, half an hour of labor", text: $vm.wrapUpText, axis: .vertical)
        .textFieldStyle(.roundedBorder)
      Button {
        vm.wrapUpTapped()
      } label: {
        Text("Log job & create report").frame(maxWidth: .infinity, minHeight: 44)
      }
      .buttonStyle(.borderedProminent)
      .disabled(vm.isBusy)
    }
    .padding(14)
    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
  }
}

// MARK: - Report

private struct ReportSheet: View {
  let response: WrapUpResponse
  let onDone: () -> Void

  var body: some View {
    let r = response.report
    NavigationStack {
      List {
        Section("Customer") {
          Text(r.customer.company).font(.headline)
          Text("\(r.customer.contactName) · \(r.customer.email)").foregroundStyle(.secondary)
        }
        if let e = r.equipment {
          Section("Machine") {
            Text("\(e.make) \(e.model)")
            Text("\(e.location) · SN \(e.serial)").foregroundStyle(.secondary)
          }
        }
        Section("Work") {
          if !r.issue.isEmpty { LabeledContent("Issue", value: r.issue) }
          Text(r.fix)
        }
        Section("Charges") {
          ForEach(r.lines, id: \.sku) { line in
            LabeledContent(line.qty > 1 ? "\(line.name) × \(line.qty)" : line.name, value: money(line.amount))
          }
          if r.labor.hours > 0 {
            LabeledContent("Labor · \(formatHours(r.labor.hours)) at \(money(r.labor.rate))/h", value: money(r.labor.amount))
          }
          LabeledContent { Text(money(r.total)).bold() } label: { Text("Total").bold() }
        }
      }
      .navigationTitle("Job report")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) { Button("Done", action: onDone) }
      }
    }
  }
}

// MARK: - Settings

private struct SettingsSheet: View {
  @Bindable var vm: GlassAgentViewModel
  var wearablesVM: WearablesViewModel
  @Environment(\.dismiss) private var dismiss
  @State private var status = ""

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("https://your-backend.example.com", text: $vm.backendURL)
            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
          Button("Test connection") {
            Task {
              do {
                let h = try await GlassAgentAPI(baseURL: vm.backendURL).health()
                status = h.anthropicKey ? "Connected" : "Connected, but the server has no Anthropic key"
              } catch {
                status = error.localizedDescription
              }
            }
          }
          if !status.isEmpty { Text(status).font(.footnote).foregroundStyle(.secondary) }
        } header: {
          Text("Backend URL")
        }
        Section("Glasses") {
          Button("Disconnect glasses", role: .destructive) { wearablesVM.disconnectGlasses() }
        }
      }
      .navigationTitle("Settings")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") {
            dismiss()
            Task { await vm.loadCustomers() }
          }
        }
      }
    }
  }
}

// MARK: - Formatting

private func money(_ value: Double) -> String {
  value.formatted(.currency(code: "USD"))
}

private func formatHours(_ hours: Double) -> String {
  hours == hours.rounded() ? "\(Int(hours)) h" : "\(hours) h"
}
