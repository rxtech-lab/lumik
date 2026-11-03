import RxAuthSwiftUI
import SwiftUI
#if os(macOS)
import Sparkle
#endif

@main struct LumikApp: App {
  #if os(macOS)
  private let updater = SPUStandardUpdaterController(
    startingUpdater: Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String != nil
      && !(Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? "").isEmpty,
    updaterDelegate: nil, userDriverDelegate: nil)
  #endif
  @State private var store = AppStore()
  var body: some Scene {
    WindowGroup {
      RootView().environment(store).tint(.buddyGreen)
        .onOpenURL { url in if url.isFileURL { store.pendingImport = url } }
        .task { if !store.isPreview { await store.auth.checkExistingAuth() } }
    }
    #if os(macOS)
    .commands {
      CommandGroup(after: .appInfo) {
        UpdateCheckButton(controller: updater)
      }
    }
    #endif
    #if os(macOS)
    Settings {
      TabView {
        AccountView().tabItem { Label("Account", systemImage: "person.crop.circle") }
        RemoteMCPView().tabItem { Label("Remote MCP", systemImage: "network") }
      }.frame(width: 660, height: 600)
        .environment(store).tint(.buddyGreen).actionFeedback()
    }
    #endif
  }
}
extension Color {
  static let buddyGreen: Color = {
    #if os(macOS)
      Color(
        NSColor(name: nil) { appearance in
          appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.30, green: 0.72, blue: 0.59, alpha: 1)
            : NSColor(red: 0.12, green: 0.37, blue: 0.31, alpha: 1)
        })
    #else
      Color(
        UIColor { traits in
          traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.30, green: 0.72, blue: 0.59, alpha: 1)
            : UIColor(red: 0.12, green: 0.37, blue: 0.31, alpha: 1)
        })
    #endif
  }()
  static let buddyPaper = Color(red: 0.96, green: 0.96, blue: 0.93)
}
struct RootView: View {
  @Environment(AppStore.self) private var store
  @State private var tab = 0
  #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
  #endif
  var body: some View {
    Group {
      if !store.configured && !store.isPreview {
        ContentUnavailableView(
          "Connect Lumik", systemImage: "doc.viewfinder",
          description: Text(
            "Your workspace is not connected yet. Contact your administrator to finish setting up Lumik."
          ))
      } else if store.auth.authState == .authenticated || store.isPreview {
        #if os(macOS)
          MacRootView()
        #else
          TabView(selection: $tab) {
            Tab("Library", systemImage: "square.stack.3d.up", value: 0) { LibraryView() }
            Tab("Signing", systemImage: "signature", value: 3) {
              NavigationStack { SigningRequestsView() }
            }
            .badge(store.signingRequests.filter(\.isPending).count)
            Tab("Account", systemImage: "person.crop.circle", value: 2) { AccountView() }
            // Wider screens keep Lumik in the right-hand column instead.
            if sizeClass == .compact {
              #if compiler(>=6.4)
              if #available(iOS 27.0, *) {
                Tab("Lumik", systemImage: "sparkles", value: 1, role: .prominent) { ChatView() }
              } else {
                Tab("Lumik", systemImage: "sparkles", value: 1, role: .search) { ChatView() }
              }
              #else
              Tab("Lumik", systemImage: "sparkles", value: 1, role: .search) { ChatView() }
              #endif
            }
          }.onChange(of: tab) { Haptics.tap() }
            .onChange(of: sizeClass) { if sizeClass != .compact && tab == 1 { tab = 0 } }
        #endif
      } else if store.auth.authState == .unknown {
        ProgressView("Restoring your session…")
      } else {
        RxSignInView(
          manager: store.auth,
          appearance: .init(
            title: "Lumik", subtitle: "A little order for all your paperwork.",
            signInButtonTitle: "Sign in with RxLab", accentColor: .buddyGreen), style: .native,
          onAuthSuccess: { Task { await store.refresh() } })
      }
    }.actionFeedback()
  }
}
struct ActionFeedback: ViewModifier {
  @State private var activityHeight: CGFloat = 0
  @Environment(AppStore.self) private var store
  func body(content: Content) -> some View {
    @Bindable var store = store
    content.overlay {
      if let busy = store.busy {
        ZStack {
          Color.black.opacity(0.12).ignoresSafeArea()
          VStack(spacing: 16) {
            ProgressView()
            Text(busy).font(.callout).multilineTextAlignment(.center).lineLimit(3)
            if !store.actionActivity.isEmpty {
              ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(store.actionActivity.enumerated().suffix(5)), id: \.offset) { index, activity in
                  Label(activity, systemImage: index == store.actionActivity.count - 1 ? "arrow.triangle.2.circlepath" : "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                }
                }.frame(maxWidth: .infinity, alignment: .leading)
                  .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { activityHeight = $0 }
              }.frame(maxWidth: 340)
                .frame(height: min(activityHeight, 200), alignment: .topLeading)
                .defaultScrollAnchor(.bottom)
              if let started = store.actionStartedAt {
                HStack(spacing: 4) {
                  Text("Elapsed")
                  Text(started, style: .timer).monospacedDigit()
                }.font(.caption).foregroundStyle(.secondary)
              }
            }
          }.padding(28).frame(maxWidth: 396, maxHeight: 400)
            .fixedSize(horizontal: false, vertical: true)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
            .padding(16)
        }.allowsHitTesting(true)
      }
    }.overlay(alignment: .top) {
      if let notice = store.notice, store.busy == nil {
        Label(notice, systemImage: "checkmark.circle.fill").font(.callout.weight(.medium)).padding()
          .background(.regularMaterial, in: Capsule()).padding().allowsHitTesting(false)
      }
    }.alert(
      "Something needs attention",
      isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })
    ) {
      Button("OK", role: .cancel) { store.error = nil }
    } message: {
      Text(store.error ?? "")
    }
  }
}
extension View {
  func actionFeedback() -> some View { modifier(ActionFeedback()) }
  /// Room for a form beside its PDF. On macOS the content must fill the sheet, or the title bar collapses.
  func wideSheet() -> some View {
    #if os(macOS)
      self.frame(minWidth: 980, idealWidth: 1120, minHeight: 680, idealHeight: 780).frame(
        maxWidth: .infinity, maxHeight: .infinity)
    #else
      self.presentationSizing(.page).presentationDetents([.large]).presentationDragIndicator(.visible)
    #endif
  }
  func fullSheet() -> some View {
    #if os(macOS)
      self.frame(minWidth: 560, idealWidth: 640, minHeight: 560, idealHeight: 600).frame(
        maxWidth: .infinity, maxHeight: .infinity)
    #else
      self.presentationDetents([.large]).presentationDragIndicator(.visible)
    #endif
  }
}
private struct AccountSummary: Decodable {
  let usedBytes: Int64
  let limitBytes: Int64?
  let deleteAt: Double?
}
struct AccountView: View {
  @Environment(AppStore.self) private var store
  @State private var summary: AccountSummary?
  @State private var confirm = false
  @State private var deletion = false
  @State private var legal: String?
  @State private var remoteMCP = false
  var body: some View {
    NavigationStack {
      Form {
        Section {
          HStack(spacing: 16) {
            Text(String((store.auth.currentUser?.name ?? "L").prefix(1)).uppercased())
              .font(.largeTitle.bold()).frame(width: 64, height: 64)
              .background(Color.buddyGreen.opacity(0.15), in: Circle())
              .accessibilityLabel("Account avatar")
            VStack(alignment: .leading) {
              Text(store.auth.currentUser?.name ?? "RxLab account").font(.headline)
              Text(store.auth.currentUser?.email ?? "").foregroundStyle(.secondary)
            }
          }.padding(.vertical, 8)
        }
        Section("Storage") {
          if let summary {
            LabeledContent("Used", value: ByteCountFormatter.string(fromByteCount: summary.usedBytes, countStyle: .file))
            if let limit = summary.limitBytes, limit > 0 {
              ProgressView(value: min(Double(summary.usedBytes) / Double(limit), 1))
              Text("of " + ByteCountFormatter.string(fromByteCount: limit, countStyle: .file))
            }
            Text("Includes documents in the Recycle Bin.").font(.footnote).foregroundStyle(.secondary)
          } else { Button("Load storage usage") { Task { await reload() } } }
        }
        Section("Integrations") {
          Button { Haptics.tap(); remoteMCP = true } label: {
            HStack {
              Label("Remote MCP", systemImage: "network")
              Spacer()
              Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }.contentShape(Rectangle())
          }.buttonStyle(.plain)
        }
        Section("Legal") {
          Button("Terms of Use") { Haptics.tap(); legal = "terms" }
          Button("Privacy Policy") { Haptics.tap(); legal = "privacy" }
        }
        Section {
          if let timestamp = summary?.deleteAt {
            LabeledContent("Deletion scheduled", value: Date(timeIntervalSince1970: timestamp / 1000).formatted(date: .abbreviated, time: .shortened))
            Button("Undo deletion request") { changeDeletion("DELETE") }
          } else {
            Button("Delete my account", role: .destructive) { Haptics.tap(); deletion = true }
              .disabled(summary == nil)
          }
          Button("Sign out", role: .destructive) { Haptics.tap(); confirm = true }
        }
      }.formStyle(.grouped)
        #if os(macOS)
        .frame(maxWidth: 680)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        #endif
        .navigationTitle("Account")
        .sheet(isPresented: $remoteMCP) {
          RemoteMCPView(showsClose: true).fullSheet().actionFeedback()
        }
        .task { await reload() }
        .refreshable { await reload() }
        .confirmationDialog("Sign out of Lumik?", isPresented: $confirm) {
          Button("Sign out", role: .destructive) { Task { await store.perform("Signing out…") { await store.logout() } } }
        }
        .sheet(isPresented: $deletion) {
          NavigationStack {
            Form {
              Section("Delete your Lumik account") {
                Text("Your documents, groups, and chat history will be deleted after seven days. You can undo this request from Account before that deadline. Your RxLab sign-in account will remain.")
                Button("Request deletion in 7 days", role: .destructive) { changeDeletion("POST") }
              }
            }.formStyle(.grouped).navigationTitle("Delete Account")
              .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { deletion = false } } }
          }.fullSheet().actionFeedback()
        }
        .sheet(isPresented: Binding(get: { legal != nil }, set: { if !$0 { legal = nil } })) {
          LegalDocumentView(document: legal ?? "terms").fullSheet()
        }
    }
  }
  private func reload() async {
    await store.perform("Loading account…") {
      summary = try JSONDecoder().decode(AccountSummary.self, from: await store.request("account"))
    }
  }
  private func changeDeletion(_ method: String) {
    Haptics.tap()
    Task {
      await store.perform(method == "POST" ? "Scheduling deletion…" : "Canceling deletion…") {
        summary = try JSONDecoder().decode(AccountSummary.self, from: await store.request("account", method: method))
        deletion = false
      }
    }
  }
}
private struct LegalDocumentView: View {
  let document: String
  @Environment(AppStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  @State private var markdown = ""
  @State private var failure: String?
  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          if let failure { Text(failure); Button("Retry") { Task { await load() } } }
          else if markdown.isEmpty { ProgressView("Loading document…") }
          else {
            ForEach(Array(markdown.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, block in
              if block.hasPrefix("# ") { Text(String(block.dropFirst(2))).font(.title.bold()) }
              else if block.hasPrefix("## ") { Text(String(block.dropFirst(3))).font(.headline) }
              else { Text((try? AttributedString(markdown: block)) ?? AttributedString(block)) }
            }
          }
        }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(24)
      }.navigationTitle(document == "terms" ? "Terms of Use" : "Privacy Policy")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { Haptics.tap(); dismiss() } } }
        .task { await load() }
    }
  }
  private func load() async {
    struct Document: Decodable { let markdown: String }
    failure = nil
    do { markdown = try JSONDecoder().decode(Document.self, from: await store.request("legal/" + document)).markdown }
    catch { if !isSilentCancellation(error) { failure = error.localizedDescription } }
  }
}

#if os(macOS)
private struct UpdateCheckButton: View {
  let controller: SPUStandardUpdaterController
  @State private var canCheck = false
  var body: some View {
    Button("Check for Updates…") { controller.checkForUpdates(nil) }
      .disabled(!canCheck)
      .onReceive(controller.updater.publisher(for: \.canCheckForUpdates)) { canCheck = $0 }
  }
}
#endif
