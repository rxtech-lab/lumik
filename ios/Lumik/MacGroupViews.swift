#if os(macOS)
  import SwiftUI

  /// The top of a group's page: its instructions, then a tile for each thing it offers.
  struct MacGroupOverview: View {
    let fieldCount: Int
    let instructions: String
    let statistics: [GroupView]
    let subgroups: [ScanGroup]
    /// The Inbox has fixed fields, so it has nothing to edit.
    let showsFields: Bool
    let editFields: () -> Void
    private var fieldCountText: String { fieldCount == 1 ? "1 field" : "\(fieldCount) fields" }
    var body: some View {
      VStack(alignment: .leading, spacing: 12) {
        if !instructions.isEmpty {
          Text(instructions).foregroundStyle(.secondary).lineLimit(2)
        }
        if showsFields || !subgroups.isEmpty || !statistics.isEmpty {
          EqualHeightGrid(minimumWidth: 230, fillsRow: false) {
            ForEach(subgroups) { group in
              NavigationLink {
                GroupDetailView(group: group)
              } label: {
                MacTile(
                  title: group.name, subtitle: group.documentCountText, icon: "folder.fill",
                  tint: .buddyGreen)
              }.buttonStyle(MacTileButtonStyle())
            }
            if showsFields {
              Button(action: editFields) {
                MacTile(
                  title: "Extraction fields", subtitle: fieldCountText, icon: "list.bullet.rectangle",
                  tint: .buddyGreen)
              }.buttonStyle(MacTileButtonStyle()).accessibilityHint("Edit group")
            }
            ForEach(statistics) { view in
              NavigationLink {
                StatisticDetailView(view: view)
              } label: {
                MacTile(title: view.title, subtitle: "Statistics", icon: "chart.bar.xaxis", tint: .blue)
              }.buttonStyle(MacTileButtonStyle())
            }
          }
        }
      }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
    }
  }
  private struct MacTile: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    var body: some View {
      HStack(spacing: 10) {
        Image(systemName: icon).font(.body.weight(.medium)).foregroundStyle(tint)
          .frame(width: 32, height: 32)
          .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        VStack(alignment: .leading, spacing: 1) {
          Text(title).fontWeight(.medium).lineLimit(2).multilineTextAlignment(.leading)
          Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
        }
        Spacer(minLength: 4)
        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
      }.padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
  }
  private struct MacTileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
      Surface(configuration: configuration)
    }
    private struct Surface: View {
      let configuration: Configuration
      @State private var hovering = false
      private let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
      var body: some View {
        configuration.label
          .background(Color.primary.opacity(configuration.isPressed ? 0.08 : hovering ? 0.04 : 0), in: shape)
          .cardSurface(cornerRadius: 12)
          .contentShape(shape)
          .onHover { hovering = $0 }
          .animation(.easeOut(duration: 0.12), value: hovering)
      }
    }
  }
  /// Finder-style list: click selects, double-click or Return opens, and headers sort.
  struct MacDocumentTable<Actions: View>: View {
    let documents: [ScanDocument]
    @ViewBuilder let actions: (ScanDocument) -> Actions
    @State private var sortOrder = [KeyPathComparator(\ScanDocument.createdAt, order: .reverse)]
    @State private var selection: ScanDocument.ID?
    @State private var opened: ScanDocument?
    var body: some View {
      Table(documents.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder) {
        TableColumn("Name", value: \.name) { MacDocumentNameCell(document: $0) }
        TableColumn("Date Added", value: \.createdAt) { Text($0.addedDayText).foregroundStyle(.secondary) }
          .width(min: 100, ideal: 120, max: 160)
        TableColumn("Size", value: \.size) { document in
          Text(document.sizeText).monospacedDigit().foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }.width(min: 70, ideal: 80, max: 110).alignment(.trailing)
      }
      .alternatingRowBackgrounds(.disabled)
      .contextMenu(forSelectionType: ScanDocument.ID.self) { ids in
        if let document = document(in: ids) {
          Button("Open", systemImage: "doc.text") { opened = document }
          Divider()
          actions(document)
        }
      } primaryAction: { ids in
        opened = document(in: ids)
      }
      .navigationDestination(item: $opened) { DocumentDetailView(document: $0) }
    }
    private func document(in ids: Set<ScanDocument.ID>) -> ScanDocument? {
      documents.first { ids.contains($0.id) }
    }
  }
  /// Quiet when a PDF is ready; its status only appears when it needs attention.
  private struct MacDocumentNameCell: View {
    let document: ScanDocument
    var body: some View {
      HStack(spacing: 8) {
        Image(systemName: "doc.text.fill").foregroundStyle(Color.buddyGreen)
        Text(document.name).lineLimit(1).truncationMode(.middle)
        Spacer(minLength: 8)
        switch document.status {
        case "ready": EmptyView()
        case "processing":
          ProgressView().controlSize(.mini)
          Text("Reading…").font(.subheadline).foregroundStyle(.secondary)
        default:
          Label(document.statusText, systemImage: document.statusIcon).font(.subheadline)
            .foregroundStyle(document.statusColor)
        }
      }
    }
  }
#endif
