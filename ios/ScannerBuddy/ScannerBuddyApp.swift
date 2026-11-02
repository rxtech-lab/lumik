import RxAuthSwiftUI
import SwiftUI

@main struct ScannerBuddyApp: App {
  @State private var store = AppStore()
  var body: some Scene {
    WindowGroup {
      RootView().environment(store).tint(.buddyGreen)
        .onOpenURL { url in if url.isFileURL { store.pendingImport = url } }
        .task { if !store.isPreview { await store.auth.checkExistingAuth() } }
    }
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
  var body: some View {
    Group {
      if !store.configured && !store.isPreview {
        ContentUnavailableView(
          "Connect Scanner Buddy", systemImage: "doc.viewfinder",
          description: Text(
            "Your workspace is not connected yet. Contact your administrator to finish setting up Scanner Buddy."
          ))
      } else if store.auth.authState == .authenticated || store.isPreview {
        #if os(macOS)
          MacRootView()
        #else
          TabView(selection: $tab) {
            Tab("Library", systemImage: "square.stack.3d.up", value: 0) { LibraryView() }
            Tab("Account", systemImage: "person.crop.circle", value: 2) { AccountView() }
            if #available(iOS 27.0, *) {
              Tab("Buddy", systemImage: "sparkles", value: 1, role: .prominent) { ChatView() }
            } else {
              Tab("Buddy", systemImage: "sparkles", value: 1, role: .search) { ChatView() }
            }
          }.onChange(of: tab) { Haptics.tap() }
        #endif
      } else if store.auth.authState == .unknown {
        ProgressView("Restoring your session…")
      } else {
        RxSignInView(
          manager: store.auth,
          appearance: .init(
            title: "Scanner Buddy", subtitle: "A little order for all your paperwork.",
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
            "Groups and documents sync through your Scanner Buddy account. PDFs are stored privately."
          ).font(.footnote).foregroundStyle(.secondary)
        }
        Section {
          Button("Sign out", role: .destructive) {
            Haptics.tap()
            confirm = true
          }
        }
      }.formStyle(.grouped).navigationTitle("Account").confirmationDialog(
        "Sign out of Scanner Buddy?", isPresented: $confirm
      ) {
        Button("Sign out", role: .destructive) {
          Task { await store.perform("Signing out…") { await store.logout() } }
        }
      }
    }
  }
}
