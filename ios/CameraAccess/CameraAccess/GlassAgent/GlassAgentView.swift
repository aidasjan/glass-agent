//
// GlassAgentView.swift
//
// Job screen for technicians: pick customer, start job, ask hands-free, wrap up.
// Reuses the sample's CameraViewModel for the glasses session, stream, and photo capture.
//

import MWDATCore
import SwiftUI

// Accent: coffee brown in light mode, a lighter tan in dark mode so it stays legible on black.
private let brown = Color(uiColor: UIColor { traits in
  traits.userInterfaceStyle == .dark
    ? UIColor(red: 0.85, green: 0.62, blue: 0.43, alpha: 1)
    : UIColor(red: 0.48, green: 0.29, blue: 0.16, alpha: 1)
})
// Text on the accent: white on dark brown, near-black on light tan.
private let onBrown = Color(uiColor: UIColor { traits in
  traits.userInterfaceStyle == .dark ? UIColor(white: 0.1, alpha: 1) : .white
})

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
            HStack(spacing: 12) {
              Image(systemName: "building.2.fill")
                .font(.title3).foregroundStyle(brown)
                .frame(width: 32)
              VStack(alignment: .leading, spacing: 3) {
                Text(customer.company)
                  .font(.body.weight(.semibold)).foregroundStyle(Color(.label))
                Text((customer.equipment ?? []).map { "\($0.make) \($0.model)" }.joined(separator: " · "))
                  .font(.subheadline).foregroundStyle(Color(.secondaryLabel))
                  .lineLimit(2)
              }
              Spacer(minLength: 8)
              Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold)).foregroundStyle(Color(.tertiaryLabel))
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
          }
          // Plain style: the row text keeps full label colours instead of the button tint.
          .buttonStyle(.plain)
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
        JobHeader(customer: customer)
        GlassesPreview(camera: camera)
        TypedQuestion(vm: vm, camera: camera)
        if vm.exchanges.isEmpty {
          Text("Look at the machine, tap Ask, and say what's wrong. Say “wrap it up …” when you're done.")
            .font(.footnote).foregroundStyle(.secondary)
        }
        ForEach(vm.exchanges) { ExchangeCard(exchange: $0) }
        WrapUpCard(vm: vm)
      }
      .padding(16)
    }
    .scrollDismissesKeyboard(.interactively)
    // The main action stays pinned at the bottom, never on top of the camera preview.
    .safeAreaInset(edge: .bottom) {
      AskButton(vm: vm, camera: camera)
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 6)
        .background(.bar)
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
    // The black box sets the size; the frame is an overlay clipped to it, so a scaled-to-fill
    // image can never push the layout wider or taller than the box.
    RoundedRectangle(cornerRadius: 16).fill(Color.black)
      .frame(maxWidth: .infinity)
      .frame(height: 240)
      .overlay { content }
      .overlay(alignment: .topLeading) { statusPill.padding(10) }
      .clipShape(RoundedRectangle(cornerRadius: 16))
  }

  @ViewBuilder
  private var content: some View {
    if let frame = camera.currentVideoFrame, camera.hasReceivedFirstFrame {
      Image(uiImage: frame).resizable().scaledToFill()
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
  }

  private var statusPill: some View {
    HStack(spacing: 6) {
      Circle().fill(camera.isStreaming ? Color.red : Color.gray).frame(width: 7, height: 7)
      Text(camera.isStreaming ? "Glasses camera" : "Camera \(camera.streamStateText)")
    }
    .font(.caption.weight(.semibold)).foregroundStyle(.white)
    .padding(.horizontal, 10).padding(.vertical, 5)
    .background(.black.opacity(0.55), in: Capsule())
  }
}

private struct JobHeader: View {
  let customer: Customer

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("\(customer.contactName) · \(customer.address)")
        .font(.subheadline).foregroundStyle(.secondary)
      FlowChips(items: (customer.equipment ?? []).map { "\($0.make) \($0.model) · \($0.location)" })
    }
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

  /// One line above the button: live transcript while listening, otherwise a short status.
  private var caption: String? {
    switch vm.phase {
    case .listening:
      return vm.liveTranscript.isEmpty ? "Listening through your glasses…" : "“\(vm.liveTranscript)”"
    case .thinking where !vm.liveTranscript.isEmpty:
      return "“\(vm.liveTranscript)”"
    case .idle where !camera.isStreaming:
      return "No glasses camera: questions go without a photo."
    default:
      return nil
    }
  }

  var body: some View {
    VStack(spacing: 8) {
      if let caption {
        Text(caption)
          .font(.callout).foregroundStyle(.secondary).lineLimit(2)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      Button {
        vm.tapAsk(camera: camera)
      } label: {
        HStack(spacing: 10) {
          if vm.isWorking {
            ProgressView().tint(vm.phase == .listening ? .white : onBrown)
          } else {
            Image(systemName: icon).font(.title3)
          }
          Text(title).font(.headline)
        }
        .frame(maxWidth: .infinity, minHeight: 56)
        .foregroundStyle(vm.phase == .listening ? .white : onBrown)
        .background(vm.phase == .listening ? Color.red : brown, in: RoundedRectangle(cornerRadius: 14))
      }
      .disabled(vm.isWorking)
    }
    .animation(.easeInOut(duration: 0.15), value: vm.phase)
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
    FlowLayout(spacing: 6) {
      ForEach(Array(items.enumerated()), id: \.offset) { _, item in
        Text(item).font(.caption.weight(.medium)).lineLimit(1)
          .padding(.horizontal, 10).padding(.vertical, 4)
          .background(Color(.tertiarySystemFill), in: Capsule())
      }
    }
  }
}

/// Lays children out left to right, wrapping onto new lines when a row is full.
private struct FlowLayout: Layout {
  var spacing: CGFloat = 6

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let rows = arrange(subviews: subviews, width: proposal.width ?? .infinity)
    let height = rows.last.map { $0.y + $0.height } ?? 0
    let width = rows.map(\.width).max() ?? 0
    return CGSize(width: proposal.width ?? width, height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    for row in arrange(subviews: subviews, width: bounds.width) {
      var x = bounds.minX
      for index in row.indices {
        var size = subviews[index].sizeThatFits(.unspecified)
        size.width = min(size.width, bounds.width)
        subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
        x += size.width + spacing
      }
    }
  }

  private struct Row {
    var indices: [Int] = []
    var y: CGFloat = 0
    var width: CGFloat = 0
    var height: CGFloat = 0
  }

  private func arrange(subviews: Subviews, width: CGFloat) -> [Row] {
    var rows: [Row] = []
    var current = Row()
    for index in subviews.indices {
      var size = subviews[index].sizeThatFits(.unspecified)
      size.width = min(size.width, width)
      if !current.indices.isEmpty && current.width + spacing + size.width > width {
        rows.append(current)
        current = Row(y: current.y + current.height + spacing)
      }
      current.width += (current.indices.isEmpty ? 0 : spacing) + size.width
      current.height = max(current.height, size.height)
      current.indices.append(index)
    }
    if !current.indices.isEmpty { rows.append(current) }
    return rows
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
        if let backOffice = response.backOffice {
          Section("Back office") {
            Label("Omnara agent is drafting the customer follow-up", systemImage: "paperplane.fill")
            Text(backOffice.agentId).font(.caption.monospaced()).foregroundStyle(.secondary)
          }
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
          TextField("Type your backend URL", text: $vm.backendURL)
            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            .textContentType(.URL)
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
        } footer: {
          Text("For example https://glass-agent-yourname.style.dev, or http://192.168.1.23:3000 for a server on your Mac.")
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
