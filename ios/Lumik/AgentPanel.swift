import SwiftUI

/// Places Lumik in the right-hand column on Mac, iPad, and an unfolded Duo, and in a sheet on
/// iPhone. Both stay attached so a size class change never rebuilds the navigation stack.
struct AgentPanelHost: ViewModifier {
  @Environment(AppStore.self) private var store
  #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
  #endif
  private var isRegular: Bool {
    #if os(macOS)
      true
    #else
      sizeClass != .compact
    #endif
  }
  func body(content: Content) -> some View {
    content.inspector(
      isPresented: Binding(
        get: { isRegular && store.agentPanelVisible }, set: { store.agentPanelVisible = $0 })
    ) {
      AgentPanel().inspectorColumnWidth(min: 320, ideal: 380, max: 560)
    }
    .sheet(
      isPresented: Binding(
        get: { !isRegular && store.agentSheetVisible }, set: { store.agentSheetVisible = $0 })
    ) {
      ChatView().fullSheet().actionFeedback()
    }
    .onChange(of: isRegular) { store.agentSheetVisible = false }
  }
}
extension View {
  func agentPanel() -> some View { modifier(AgentPanelHost()) }
}
struct AgentToolbarButton: View {
  @Environment(AppStore.self) private var store
  #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
  #endif
  var body: some View {
    Button("Ask Lumik", systemImage: "sparkles") {
      Haptics.tap()
      #if os(iOS)
        if sizeClass == .compact {
          store.agentSheetVisible = true
          return
        }
      #endif
      if store.agentPanelVisible && store.agentPanelTab == .buddy {
        store.agentPanelVisible = false
      } else {
        store.agentPanelTab = .buddy
        store.agentPanelVisible = true
      }
    }.accessibilityIdentifier("agent-toggle")
  }
}
enum AgentPanelTab: Hashable {
  case buddy
  case details
}
private struct AgentPanel: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(AppStore.self) private var store
  var body: some View {
    @Bindable var store = store
    VStack(spacing: 0) {
      if store.openDocument != nil {
        Picker("Panel", selection: $store.agentPanelTab) {
          Text("Lumik").tag(AgentPanelTab.buddy)
          Text("Details").tag(AgentPanelTab.details)
        }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 12).padding(.vertical, 8)
      }
      if let document = store.openDocument, store.agentPanelTab == .details {
        ZStack {
          if store.loadingDocumentID == document.id {
            Color.clear
          } else {
            DocumentDetailsForm(document: document, pageCount: store.openDocumentPages)
              .transition(.opacity)
          }
        }.animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: store.loadingDocumentID)
      } else {
        ChatThread()
      }
    }.onChange(of: store.composerDraft) {
      if !store.composerDraft.isEmpty { store.agentPanelTab = .buddy }
    }
  }
}
