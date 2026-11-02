import SwiftUI

/// A saved statistics view: its spec, drawn over the group's live query results.
struct StatisticDetailView: View {
  let view: GroupView
  @Environment(AppStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  @State private var state: JSONRenderState?
  @State private var problem: String?
  @State private var deleting = false
  var body: some View {
    Group {
      if let state {
        ScrollView {
          JSONRenderView(spec: view.spec, state: state).padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
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
      .toolbar {
        ToolbarItem(placement: .primaryAction) { AgentToolbarButton() }
        ToolbarItem(placement: .primaryAction) {
          Menu {
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await load() } }
            Button("Change with Buddy", systemImage: "sparkles") {
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
  private func load() async {
    problem = nil
    do {
      state = JSONRenderState(try await store.viewState(view))
    } catch {
      if !Task.isCancelled { problem = error.localizedDescription }
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
          } catch { problem = error.localizedDescription }
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
        } catch { problem = error.localizedDescription }
      }
  }
}
