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
            Tab("Account", systemImage: "person.crop.circle", value: 2) { AccountView() }
            // Wider screens keep Buddy in the right-hand column instead.
            if sizeClass == .compact {
              if #available(iOS 27.0, *) {
                Tab("Buddy", systemImage: "sparkles", value: 1, role: .prominent) { ChatView() }
              } else {
                Tab("Buddy", systemImage: "sparkles", value: 1, role: .search) { ChatView() }
              }
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
  @Environment(AppStore.self) private var store
  func body(content: Content) -> some View {
    @Bindable var store = store
    content.overlay {
      if let busy = store.busy {
        ZStack {
          Color.black.opacity(0.12).ignoresSafeArea()
          VStack(spacing: 16) {
            ProgressView()
            Text(busy).font(.callout).multilineTextAlignment(.center)
          }.padding(28).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
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
  func fullSheet() -> some View {
    #if os(macOS)
      self.frame(minWidth: 560, idealWidth: 640, minHeight: 560, idealHeight: 600).frame(
        maxWidth: .infinity, maxHeight: .infinity)
    #else
      self.presentationDetents([.large]).presentationDragIndicator(.visible)
    #endif
  }
}
struct AccountView: View {
  @Environment(AppStore.self) private var store
  @State private var confirm = false
  var body: some View {
    NavigationStack {
      Form {
        Section("Your account") {
          LabeledContent("Name", value: store.auth.currentUser?.name ?? "RxLab account")
          Text(store.auth.currentUser?.email ?? "").foregroundStyle(.secondary)
        }
        Section("Connected storage") {
          LabeledContent("Server", value: store.baseURL.host ?? "")
          Text(
            "Groups and documents sync through your Lumik account. PDFs are stored privately."
          ).font(.footnote).foregroundStyle(.secondary)
        }
        Section {
          Button("Sign out", role: .destructive) {
            Haptics.tap()
            confirm = true
          }
        }
      }.formStyle(.grouped).navigationTitle("Account").confirmationDialog(
        "Sign out of Lumik?", isPresented: $confirm
      ) {
        Button("Sign out", role: .destructive) {
          Task { await store.perform("Signing out…") { await store.logout() } }
        }
      }
    }
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
