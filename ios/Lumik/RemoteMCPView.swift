import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Server settings are derived from the same environment as the app's API requests.
struct RemoteMCPView: View {
  var showsClose = false
  @Environment(AppStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  @State private var setup = false
  private var endpoint: String { store.baseURL.appendingPathComponent("api/mcp").absoluteString }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Label("Connect your AI tools to Lumik", systemImage: "network")
            .font(.headline)
          Text("Work with your PDFs, groups, summaries and statistics from a compatible remote MCP client.")
            .foregroundStyle(.secondary)
        }
        Section("Remote server") {
          LabeledContent("Transport", value: "Streamable HTTP")
          Text(endpoint).font(.callout.monospaced()).textSelection(.enabled)
          Button("Set Up a Client", systemImage: "plus") { Haptics.tap(); setup = true }
        }
        Section("Available tools") {
          Label("Browse groups and documents", systemImage: "folder")
          Label("Upload and download PDFs", systemImage: "arrow.up.arrow.down")
          Label("Read document summaries", systemImage: "text.alignleft")
          Label("Read and propose statistics", systemImage: "chart.bar")
          Label("Propose document moves", systemImage: "folder.badge.plus")
          Text("Moves and statistics changes require approval in Lumik.")
            .font(.footnote).foregroundStyle(.secondary)
        }
        Section("Connected clients") {
          Label("Client management is not available yet", systemImage: "info.circle")
          Text("This server currently requires a bearer token. OAuth sign-in, the connected-client list and disconnect controls are not yet supported.")
            .font(.footnote).foregroundStyle(.secondary)
        }
      }.formStyle(.grouped)
        .navigationTitle("Remote MCP")
        .toolbar {
          if showsClose {
            ToolbarItem(placement: .confirmationAction) {
              Button("Done") { Haptics.tap(); dismiss() }
            }
          }
        }
        .sheet(isPresented: $setup) { setupView.fullSheet().actionFeedback() }
    }
  }

  private var setupView: some View {
    NavigationStack {
      Form {
        Section("Add a remote server") {
          Text("In your MCP client, add a remote server named Lumik and use this URL.")
          Text(endpoint).font(.callout.monospaced()).textSelection(.enabled)
          Button("Copy Server URL", systemImage: "doc.on.doc") {
            Task { await store.perform("Copying server URL…", success: "Server URL copied") {
            #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(endpoint, forType: .string)
            #else
            UIPasteboard.general.string = endpoint
            #endif
            } }
          }
        }
        Section("Authentication") {
          Text("A valid Lumik bearer token is required. Copying the URL does not authorize access. Client authorization through OAuth is not available yet.")
        }
        #if DEBUG
        Section("Development server") {
          Text("This build uses your local server. The MCP client must be able to reach the same localhost address. Release builds use the production server.")
            .foregroundStyle(.secondary)
        }
        #endif
      }.formStyle(.grouped).navigationTitle("Set Up Remote MCP")
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") { Haptics.tap(); setup = false }
          }
        }
    }
  }
}
