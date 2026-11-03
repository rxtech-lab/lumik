import SwiftUI

/// "Move to Parent", when the group has one, and "Move to…" for anywhere else.
struct MoveDocumentButtons: View {
  let store: AppStore
  let document: ScanDocument
  @Binding var moving: ScanDocument?
  var movedToParent: () -> Void = {}
  private var parent: ScanGroup? {
    let group = store.groups.first { $0.id == document.groupId }
    return store.groups.first { $0.id == group?.parentId }
  }
  var body: some View {
    Group {
      if let parent {
        Button("Move to \(parent.name)", systemImage: "arrow.up") {
          Haptics.tap()
          // The sheet explains what happens when the parent's fields are different.
          if store.movePreservesDetails(document, to: parent) {
            Task {
              if await store.perform(
                "Moving PDF…", success: "Moved to \(parent.name)",
                { try await store.moveDocument(document, to: parent.id) })
              {
                movedToParent()
              }
            }
          } else {
            moving = document
          }
        }
      }
      Button("Move to…", systemImage: "folder") {
        Haptics.tap()
        moving = document
      }
    }.disabled(document.status == "processing")
  }
}
/// Picks the group or subgroup to file a PDF in.
struct MoveDocumentView: View {
  let document: ScanDocument
  @Environment(AppStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  @State private var confirming: ScanGroup?
  var body: some View {
    NavigationStack {
      List {
        Section {
          ForEach(store.groupTree) { row in
            Button {
              Haptics.tap()
              if store.movePreservesDetails(document, to: row.group) {
                move(to: row.group)
              } else {
                confirming = row.group
              }
            } label: {
              HStack(spacing: 10) {
                Image(systemName: "folder.fill").foregroundStyle(Color.buddyGreen)
                Text(row.group.name).foregroundStyle(.primary)
                Spacer()
                if row.group.id == document.groupId {
                  Image(systemName: "checkmark").foregroundStyle(.secondary)
                    .accessibilityLabel("Current group")
                }
              }.padding(.leading, CGFloat(min(row.depth, 6)) * 18).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(row.group.id == document.groupId || store.busy != nil)
          }
        } header: {
          Text(document.name).lineLimit(1).truncationMode(.middle)
        }
      }
      .overlay {
        if store.groupTree.isEmpty {
          ContentUnavailableView(
            "Create a group first", systemImage: "folder.badge.plus",
            description: Text("Close this sheet and create a group, or ask Buddy to organize this PDF."))
        }
      }
      .navigationTitle("Move PDF")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
      }
      .confirmationDialog(
        "Move to “\(confirming?.name ?? "")”?",
        isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
        titleVisibility: .visible, presenting: confirming
      ) { group in
        Button("Move and read again") { move(to: group) }
        Button("Cancel", role: .cancel) {}
      } message: { _ in
        Text(
          "This group has different fields, so the PDF will be read again and renamed to match it. Details you edited by hand will be replaced."
        )
      }
    }
  }
  private func move(to group: ScanGroup) {
    Task {
      if await store.perform(
        "Moving PDF…", success: "Moved to \(group.name)",
        { try await store.moveDocument(document, to: group.id) })
      {
        dismiss()
      }
    }
  }
}
