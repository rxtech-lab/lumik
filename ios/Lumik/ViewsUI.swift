import SwiftUI

/// A saved statistics view: its spec, drawn over the group's live query results.
struct StatisticDetailView: View {
  let view: GroupView
  @Environment(AppStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  @State private var state: JSONRenderState?
  @State private var problem: String?
  @State private var refreshing = false
  @State private var deleting = false
  var body: some View {
    Group {
      if let state {
        ScrollView {
          JSONRenderView(spec: view.spec, state: state).padding(20)
            .frame(maxWidth: 1080, alignment: .leading).frame(maxWidth: .infinity)
        }.refreshable { await load() }
      } else if let problem {
        ContentUnavailableView {
          Label("Couldn’t load this view", systemImage: "chart.bar.xaxis")
        } description: {
          Text(problem)
        } actions: {
          Button("Try again") { Task { await load() } }
        }
      } else {
        ProgressView("Calculating…").frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }.navigationTitle(view.title)
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .task(id: view) { await load() }
      .task(id: inputValues) {
        guard state != nil else { return }
        do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
        await load()
      }
      .overlay { if refreshing { ProgressView("Updating…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
      .alert("Couldn’t update this view", isPresented: Binding(get: { problem != nil && state != nil }, set: { if !$0 { problem = nil } })) {
        Button("OK", role: .cancel) { problem = nil }
      } message: { Text(problem ?? "") }
      .toolbar {
        ToolbarItem(placement: .primaryAction) { AgentToolbarButton() }
        ToolbarItem(placement: .primaryAction) {
          Menu {
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await load() } }
            Button("Change with Lumik", systemImage: "sparkles") {
              store.askBuddy("Update the “\(view.title)” statistics view to ")
            }
            Divider()
            Button("Delete view", systemImage: "trash", role: .destructive) {
              Haptics.tap()
              deleting = true
            }
          } label: {
            Image(systemName: "ellipsis")
          }.menuIndicator(.hidden).accessibilityLabel("View actions")
        }
      }
      .sheet(
        isPresented: $deleting,
        onDismiss: { if !store.views.contains(where: { $0.id == view.id }) { dismiss() } }
      ) {
        DeleteView(title: view.title, message: "This removes the view. Your documents stay as they are.") {
          try await store.deleteView(view)
        }.fullSheet().actionFeedback()
      }
  }
  private var inputValues: [String: JSONValue] {
    (state?.root.object ?? [:]).filter { key, value in
      guard key != "queries" && key != "processed" else { return false }
      switch value { case .string, .number, .bool, .null: return true; default: return false }
    }
  }
  private func load() async {
    problem = nil
    let values = inputValues
    refreshing = state != nil
    defer { refreshing = false }
    do {
      let result = try await store.viewState(view, values: values)
      guard !Task.isCancelled, inputValues == values else { return }
      state = JSONRenderState(result)
    } catch {
      if !isSilentCancellation(error) { problem = error.localizedDescription }
    }
  }
}
/// A saved filter's form. Its query runs on the server with the values chosen here.
struct FilterSheet: View {
  let view: GroupView
  @Environment(AppStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  @State private var state: JSONRenderState?
  @State private var problem: String?
  @State private var deleting = false
  var body: some View {
    NavigationStack {
      Group {
        if let state {
          ScrollView {
            JSONRenderView(spec: view.spec, state: state).textFieldStyle(.roundedBorder).padding(20)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        } else if let problem {
          ContentUnavailableView(
            "Couldn’t load this filter", systemImage: "line.3.horizontal.decrease.circle",
            description: Text(problem))
        } else {
          ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }.frame(maxWidth: .infinity, maxHeight: .infinity).navigationTitle(view.title)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
          ToolbarItem(placement: .confirmationAction) {
            Button("Apply") { apply() }.disabled(state == nil || store.busy != nil)
          }
          ToolbarItem(placement: .secondaryAction) {
            Button("Delete filter", systemImage: "trash", role: .destructive) {
              Haptics.tap()
              deleting = true
            }
          }
        }
        .task {
          do {
            state = JSONRenderState(try await store.viewState(view))
          } catch { if !isSilentCancellation(error) { problem = error.localizedDescription } }
        }
        .sheet(
          isPresented: $deleting,
          onDismiss: { if !store.views.contains(where: { $0.id == view.id }) { dismiss() } }
        ) {
          DeleteView(title: view.title, message: "This removes the filter. Your documents stay as they are.") {
            try await store.deleteView(view)
          }.fullSheet().actionFeedback()
        }
    }
  }
  private func apply() {
    guard let state else { return }
    Task {
      if await store.perform("Filtering documents…", success: "Filter applied", {
        try await store.runFilter(view, values: state.root.object.filter { $0.key != "queries" })
      }) {
        dismiss()
      }
    }
  }
}
/// What an organize plan will create and move, by name.
struct OrganizeProposalPreview: View {
  let review: JSONValue
  private var newGroups: [JSONValue] { review.object["newGroups"]?.array ?? [] }
  private var moves: [JSONValue] { review.object["moves"]?.array ?? [] }
  private var rereads: Bool { moves.contains { $0.object["reread"]?.bool == true } }
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      if !newGroups.isEmpty {
        section("New groups") {
          ForEach(newGroups.indices, id: \.self) { index in
            let group = newGroups[index].object
            let fields = group["fields"]?.array.map(\.string) ?? []
            row(
              icon: "folder.badge.plus", title: group["path"]?.string ?? "",
              detail: fields.isEmpty ? "No fields" : fields.joined(separator: ", "))
          }
        }
      }
      if !moves.isEmpty {
        section(moves.count == 1 ? "Move 1 document" : "Move \(moves.count) documents") {
          ForEach(moves.indices, id: \.self) { index in
            let move = moves[index].object
            row(
              icon: "doc.text", title: move["document"]?.string ?? "",
              detail: "\(move["from"]?.string ?? "") → \(move["to"]?.string ?? "")")
          }
        }
        if rereads {
          Label(
            "PDFs moved to a group with different fields are read again and renamed to match it.",
            systemImage: "sparkles"
          ).font(.callout).foregroundStyle(.secondary)
        }
      }
    }
  }
  private func section<Content: View>(
    _ title: String, @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title).font(.headline)
      content()
    }.frame(maxWidth: .infinity, alignment: .leading).padding()
      .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
  }
  private func row(icon: String, title: String, detail: String) -> some View {
    Label {
      VStack(alignment: .leading, spacing: 2) {
        Text(title).textSelection(.enabled)
        Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
      }
    } icon: {
      Image(systemName: icon).foregroundStyle(Color.buddyGreen)
    }
  }
}
/// Shows what a proposed view will look like, using the group's real data, before it is approved.
struct ViewProposalPreview: View {
  let groupID: String
  let view: JSONValue
  @Environment(AppStore.self) private var store
  @State private var state: JSONRenderState?
  @State private var problem: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(view.object["title"]?.string ?? "Preview").font(.headline)
      if let state, let spec = view.object["spec"] {
        JSONRenderView(spec: spec, state: state).textFieldStyle(.roundedBorder).allowsHitTesting(false)
      } else if let problem {
        Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
      } else {
        ProgressView()
      }
    }.frame(maxWidth: .infinity, alignment: .leading).padding()
      .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
      .task {
        do {
          state = JSONRenderState(try await store.previewState(groupID: groupID, view: view))
        } catch { if !isSilentCancellation(error) { problem = error.localizedDescription } }
      }
  }
}

/// A quiet page skeleton keeps the resource layout recognizable while content arrives.
struct ResourceLoadingView: View {
  var title = "Loading PDF"
  var subtitle = "Preparing your document preview…"
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    VStack(spacing: 24) {
      TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
        let phase = reduceMotion ? 0.5 : context.date.timeIntervalSinceReferenceDate
          .truncatingRemainder(dividingBy: 2.4) / 2.4
        VStack(alignment: .leading, spacing: 12) {
          Image(systemName: "doc.text").font(.title2).foregroundStyle(.tint)
            .padding(.bottom, 12)
          skeletonLine(width: 0.65)
          skeletonLine(width: 1)
          skeletonLine(width: 0.88)
          skeletonLine(width: 1)
          skeletonLine(width: 0.55)
          RoundedRectangle(cornerRadius: 6)
            .fill(.primary.opacity(0.045)).frame(height: 42).padding(.top, 8)
        }
        .padding(24).frame(width: 200, height: 256)
        .background(colorScheme == .dark ? Color(white: 0.16) : .white,
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay {
          if !reduceMotion {
            GeometryReader { geometry in
              LinearGradient(colors: [.clear, .primary.opacity(0.06), .clear],
                             startPoint: .leading, endPoint: .trailing)
                .frame(width: geometry.size.width * 0.7)
                .offset(x: geometry.size.width * (phase * 2.4 - 0.7))
            }.clipShape(RoundedRectangle(cornerRadius: 12))
          }
        }
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.06)))
        .shadow(color: .black.opacity(0.08), radius: 16, y: 6)
      }.accessibilityHidden(true)
      VStack(spacing: 6) {
        Text(title).font(.headline)
        Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
    }
    .padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(title). \(subtitle)")
  }

  private func skeletonLine(width: CGFloat) -> some View {
    GeometryReader { geometry in
      Capsule().fill(.primary.opacity(0.09)).frame(width: geometry.size.width * width)
    }.frame(height: 7)
  }
}
